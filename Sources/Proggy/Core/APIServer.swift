import Foundation
import Network

// MARK: - Embedded REST API Server (localhost only)
//
// Provides programmatic access to all Proggy operations.
// Enable in the app, then call from scripts:
//
//   curl http://localhost:8742/api/status
//   curl -X POST http://localhost:8742/api/read > dump.bin
//   curl -X POST -d @firmware.bin http://localhost:8742/api/write
//   curl -X POST http://localhost:8742/api/erase
//   curl http://localhost:8742/api/detect

@MainActor
final class APIServer {
    private var listener: NWListener?
    private(set) var isRunning = false
    var port: UInt16 = 8742

    weak var manager: DeviceManager?

    func start() throws {
        let params = NWParameters.tcp
        params.allowLocalEndpointReuse = true

        let nwPort = NWEndpoint.Port(rawValue: port)!
        listener = try NWListener(using: params, on: nwPort)

        listener?.newConnectionHandler = { [weak self] connection in
            Task { @MainActor in
                self?.handleConnection(connection)
            }
        }

        listener?.stateUpdateHandler = { [weak self] state in
            Task { @MainActor in
                switch state {
                case .ready:
                    self?.isRunning = true
                case .failed, .cancelled:
                    self?.isRunning = false
                default: break
                }
            }
        }

        listener?.start(queue: .main)
    }

    func stop() {
        listener?.cancel()
        listener = nil
        isRunning = false
    }

    // MARK: - Connection Handler

    private func handleConnection(_ connection: NWConnection) {
        connection.start(queue: .main)
        connection.receive(minimumIncompleteLength: 1, maximumLength: 1_048_576) { [weak self] data, _, _, error in
            guard let self, let data else {
                connection.cancel()
                return
            }

            let request = String(data: data, encoding: .utf8) ?? ""
            Task { @MainActor in
                let response = await self.handleRequest(request, body: data)
                let httpResponse = self.buildHTTPResponse(response)
                connection.send(content: httpResponse, completion: .contentProcessed { _ in
                    connection.cancel()
                })
            }
        }
    }

    // MARK: - Request Routing

    struct APIResponse {
        var status: Int = 200
        var contentType: String = "application/json"
        var body: Data

        static func json(_ dict: [String: Any], status: Int = 200) -> APIResponse {
            let data = (try? JSONSerialization.data(withJSONObject: dict, options: .prettyPrinted)) ?? Data()
            return APIResponse(status: status, contentType: "application/json", body: data)
        }

        static func binary(_ data: Data) -> APIResponse {
            APIResponse(contentType: "application/octet-stream", body: data)
        }

        static func error(_ msg: String, status: Int = 400) -> APIResponse {
            json(["error": msg], status: status)
        }

        static func ok(_ msg: String = "ok") -> APIResponse {
            json(["status": msg])
        }
    }

    private func handleRequest(_ raw: String, body: Data) async -> APIResponse {
        // Parse HTTP request line
        let lines = raw.components(separatedBy: "\r\n")
        guard let firstLine = lines.first else { return .error("Bad request") }
        let parts = firstLine.split(separator: " ")
        guard parts.count >= 2 else { return .error("Bad request") }

        let method = String(parts[0])
        let path = String(parts[1])

        // Extract body (after double CRLF)
        let requestBody: Data
        if let range = raw.range(of: "\r\n\r\n") {
            let bodyStart = raw.distance(from: raw.startIndex, to: range.upperBound)
            if bodyStart < body.count {
                requestBody = body.suffix(from: bodyStart)
            } else {
                requestBody = Data()
            }
        } else {
            requestBody = Data()
        }

        // Route
        switch (method, path) {
        case ("GET", "/api/status"):
            return statusResponse()

        case ("GET", "/api/detect"), ("POST", "/api/detect"):
            return await detectResponse()

        case ("POST", "/api/read"), ("GET", "/api/read"):
            return await readResponse()

        case ("POST", "/api/write"):
            return await writeResponse(requestBody)

        case ("POST", "/api/erase"):
            return await eraseResponse()

        case ("POST", "/api/verify"):
            return await verifyResponse(requestBody)

        case ("GET", "/api/chips"):
            return chipsResponse()

        case ("GET", "/api/ports"):
            return portsResponse()

        case ("GET", "/api/log"):
            return logResponse()

        case ("GET", "/api/buffer"):
            return bufferResponse()

        case ("GET", "/"):
            return helpResponse()

        default:
            return .error("Not found: \(method) \(path)", status: 404)
        }
    }

    // MARK: - Endpoint Implementations

    private func statusResponse() -> APIResponse {
        guard let m = manager else { return .error("Not ready", status: 503) }
        return .json([
            "connected": m.isConnected,
            "device": m.deviceInfo,
            "chip": m.chipName ?? NSNull(),
            "chipCapacity": m.chipCapacity,
            "busy": m.isBusy,
            "bufferSize": m.buffer.count,
            "bufferCRC32": String(format: "%08X", m.buffer.crc32),
            "autoProgramOnChange": m.autoProgramOnChange,
            "autoProgramCount": m.autoProgramCount,
            "watchedFile": m.watchedFileURL?.path ?? NSNull(),
        ])
    }

    private func detectResponse() async -> APIResponse {
        guard let m = manager else { return .error("Not ready", status: 503) }
        guard m.isConnected else { return .error("Not connected") }
        await m.detectChip()
        // Wait briefly for detection
        try? await Task.sleep(for: .milliseconds(500))
        return .json([
            "chip": m.chipName ?? "unknown",
            "capacity": m.chipCapacity,
            "jedec": m.chipInfo.map { [
                "manufacturer": $0.manufacturerID,
                "memoryType": $0.memoryType,
                "capacityBits": $0.capacityBits,
            ] as [String: Any] } ?? [:] as [String: Any],
        ])
    }

    private func readResponse() async -> APIResponse {
        guard let m = manager else { return .error("Not ready", status: 503) }
        guard m.isConnected, m.chipCapacity > 0 else { return .error("No chip") }

        m.readChip()
        // Wait for read to complete
        while m.isBusy { try? await Task.sleep(for: .milliseconds(100)) }

        guard !m.buffer.isEmpty else { return .error("Read failed") }
        return .binary(m.buffer.data)
    }

    private func writeResponse(_ body: Data) async -> APIResponse {
        guard let m = manager else { return .error("Not ready", status: 503) }
        guard m.isConnected else { return .error("Not connected") }
        guard !body.isEmpty else { return .error("Empty body") }

        m.buffer.load(body)
        m.writeChip()
        while m.isBusy { try? await Task.sleep(for: .milliseconds(100)) }

        return .ok("Written \(body.count) bytes")
    }

    private func eraseResponse() async -> APIResponse {
        guard let m = manager else { return .error("Not ready", status: 503) }
        guard m.isConnected else { return .error("Not connected") }

        m.eraseChip()
        while m.isBusy { try? await Task.sleep(for: .milliseconds(100)) }

        return .ok("Erased")
    }

    private func verifyResponse(_ body: Data) async -> APIResponse {
        guard let m = manager else { return .error("Not ready", status: 503) }
        guard m.isConnected, !body.isEmpty else { return .error("No data") }

        m.buffer.load(body)
        m.verifyChip()
        while m.isBusy { try? await Task.sleep(for: .milliseconds(100)) }

        let lastStatus = m.statusMessage
        let ok = lastStatus.contains("complete") || lastStatus.contains("OK")
        return .json(["verified": ok, "message": lastStatus])
    }

    private func chipsResponse() -> APIResponse {
        let chips = ChipLibrary.chips.map { chip -> [String: Any] in
            var d: [String: Any] = [
                "name": chip.name,
                "manufacturer": chip.manufacturer,
                "capacity": chip.capacity,
                "category": chip.category.rawValue,
            ]
            if let addr = chip.i2cAddress { d["i2cAddress"] = addr }
            return d
        }
        return .json(["count": chips.count, "chips": chips])
    }

    private func portsResponse() -> APIResponse {
        let ports = SerialPort.availablePorts().map { ["path": $0.path, "name": $0.name] }
        return .json(["ports": ports])
    }

    private func logResponse() -> APIResponse {
        guard let m = manager else { return .error("Not ready", status: 503) }
        let entries = m.logEntries.suffix(50).map { entry -> [String: String] in
            ["time": entry.timestampString, "level": entry.level.rawValue, "message": entry.message]
        }
        return .json(["entries": Array(entries)])
    }

    private func bufferResponse() -> APIResponse {
        guard let m = manager, !m.buffer.isEmpty else { return .error("Buffer empty") }
        return .binary(m.buffer.data)
    }

    private func helpResponse() -> APIResponse {
        .json([
            "name": "Proggy API",
            "version": "1.0",
            "endpoints": [
                "GET  /api/status  — Device & buffer status",
                "POST /api/detect  — Auto-detect chip",
                "POST /api/read    — Read chip → binary response",
                "POST /api/write   — Write binary body → chip",
                "POST /api/erase   — Erase chip",
                "POST /api/verify  — Verify binary body vs chip",
                "GET  /api/chips   — List all supported chips",
                "GET  /api/ports   — List serial ports",
                "GET  /api/buffer  — Download buffer as binary",
                "GET  /api/log     — Last 50 log entries",
            ]
        ])
    }

    // MARK: - HTTP Response Builder

    private func buildHTTPResponse(_ resp: APIResponse) -> Data {
        var header = "HTTP/1.1 \(resp.status) \(httpStatusText(resp.status))\r\n"
        header += "Content-Type: \(resp.contentType)\r\n"
        header += "Content-Length: \(resp.body.count)\r\n"
        header += "Access-Control-Allow-Origin: *\r\n"
        header += "Connection: close\r\n"
        header += "\r\n"

        var data = header.data(using: .utf8) ?? Data()
        data.append(resp.body)
        return data
    }

    private func httpStatusText(_ code: Int) -> String {
        switch code {
        case 200: return "OK"
        case 400: return "Bad Request"
        case 404: return "Not Found"
        case 503: return "Service Unavailable"
        default: return "Error"
        }
    }
}
