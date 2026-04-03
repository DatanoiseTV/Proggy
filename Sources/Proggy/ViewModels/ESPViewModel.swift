import Foundation
import SwiftUI

@Observable
@MainActor
final class ESPViewModel {
    // Serial port
    var availablePorts: [(path: String, name: String)] = []
    var selectedPort: String = ""
    var baudRate: Int = 460800
    var selectedChip: String = ""  // empty = auto-detect

    // Main firmware
    var firmwareData: Data?
    var firmwareFileName: String?
    var flashOffset: String = "10000"

    // Optional images
    var bootloaderData: Data?
    var bootloaderFileName: String?
    var bootloaderOffset: String = "0"
    var partitionData: Data?
    var partitionFileName: String?
    var partitionOffset: String = "8000"

    // Options
    var eraseBeforeFlash: Bool = true
    var verifyAfterFlash: Bool = true
    var resetAfterFlash: Bool = true

    // Status
    var isFlashing = false
    var flashProgress: Double = 0
    var flashStatus: String = ""
    var detectedChip: String?

    // Serial monitor
    var monitorOutput: String = ""
    var monitorInput: String = ""
    var monitorBaud: Int = 115200
    var monitorHexMode: Bool = false
    var isMonitoring = false
    private var monitorTask: Task<Void, Never>?

    private var port: SerialPort?
    private var flasher: ESPFlasher?

    init() {
        refreshPorts()
    }

    // MARK: - Port Management

    func refreshPorts() {
        availablePorts = SerialPort.availablePorts()
        if selectedPort.isEmpty, let first = availablePorts.first {
            selectedPort = first.path
        }
    }

    // MARK: - Firmware Loading

    func loadFirmware(_ url: URL, manager: DeviceManager) {
        do {
            firmwareData = try Data(contentsOf: url)
            firmwareFileName = url.lastPathComponent
            manager.log(.info, "ESP firmware loaded: \(manager.formatSize(firmwareData!.count)) from \(url.lastPathComponent)")
        } catch {
            manager.log(.error, "Failed to load firmware: \(error.localizedDescription)")
        }
    }

    // MARK: - Flash

    func flash(manager: DeviceManager) {
        guard let firmware = firmwareData, !isFlashing, !selectedPort.isEmpty else { return }
        let offset = UInt32(flashOffset, radix: 16) ?? 0x10000
        let portPath = selectedPort
        let baud = baudRate

        isFlashing = true
        flashProgress = 0
        flashStatus = "Starting..."
        detectedChip = nil

        manager.log(.info, "ESP flash: \(manager.formatSize(firmware.count)) to 0x\(String(format: "%X", offset)) via \(portPath)")

        Task.detached { [weak self] in
            do {
                let serialPort = SerialPort(path: portPath)
                try serialPort.open(baudRate: 115200)

                let flasher = ESPFlasher(port: serialPort)

                let chip = try flasher.flashFirmware(
                    firmwareData: firmware,
                    offset: offset,
                    baudRate: baud,
                    progress: { status, pct in
                        Task { @MainActor [weak self] in
                            self?.flashStatus = status
                            self?.flashProgress = pct
                        }
                    },
                    cancelled: { false }
                )

                serialPort.close()

                await MainActor.run { [weak self] in
                    self?.detectedChip = chip.rawValue
                    self?.flashStatus = "Done! (\(chip.rawValue))"
                    self?.isFlashing = false
                    manager.log(.info, "ESP flash complete: \(chip.rawValue)")
                }
            } catch {
                await MainActor.run { [weak self] in
                    self?.flashStatus = "Error: \(error.localizedDescription)"
                    self?.isFlashing = false
                    manager.log(.error, "ESP flash failed: \(error.localizedDescription)")
                }
            }
        }
    }

    // MARK: - Serial Monitor

    func startMonitor(manager: DeviceManager) {
        guard !isMonitoring, !selectedPort.isEmpty else { return }
        isMonitoring = true
        monitorOutput = ""

        monitorTask = Task.detached { [weak self] in
            guard let self else { return }
            do {
                let port = SerialPort(path: await self.selectedPort)
                try port.open(baudRate: await self.baudRate)
                await MainActor.run { self.port = port }

                while !Task.isCancelled {
                    let data = port.readAvailable()
                    if !data.isEmpty {
                        let text = String(bytes: data, encoding: .utf8) ?? data.map { String(format: "%02X ", $0) }.joined()
                        await MainActor.run {
                            self.monitorOutput.append(text)
                            // Keep buffer manageable
                            if self.monitorOutput.count > 50000 {
                                self.monitorOutput = String(self.monitorOutput.suffix(40000))
                            }
                        }
                    }
                    try await Task.sleep(for: .milliseconds(10))
                }
            } catch {
                await MainActor.run {
                    manager.log(.error, "Monitor: \(error.localizedDescription)")
                }
            }
            await MainActor.run {
                self.port?.close()
                self.port = nil
                self.isMonitoring = false
            }
        }
    }

    func stopMonitor() {
        monitorTask?.cancel()
        monitorTask = nil
    }

    func sendMonitorText() {
        guard let port, !monitorInput.isEmpty else { return }
        let text = monitorInput + "\r\n"
        try? port.write(Array(text.utf8))
        monitorInput = ""
    }
}
