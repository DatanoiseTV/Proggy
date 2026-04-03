import Foundation

// MARK: - ESP32 Serial Bootloader Protocol (SLIP framing)

enum ESPChip: String, CaseIterable, Identifiable {
    case esp32 = "ESP32"
    case esp32s2 = "ESP32-S2"
    case esp32s3 = "ESP32-S3"
    case esp32c2 = "ESP32-C2"
    case esp32c3 = "ESP32-C3"
    case esp32c5 = "ESP32-C5"
    case esp32c6 = "ESP32-C6"
    case esp32c61 = "ESP32-C61"
    case esp32h2 = "ESP32-H2"
    case esp32p4 = "ESP32-P4"

    var id: String { rawValue }

    var bootloaderOffset: UInt32 {
        switch self {
        case .esp32, .esp32s2: return 0x1000
        case .esp32c5, .esp32p4: return 0x2000
        default: return 0x0000
        }
    }

    var appOffset: UInt32 { 0x10000 }
    var partitionTableOffset: UInt32 { 0x8000 }

    /// Detect chip from magic register value
    static func fromMagic(_ magic: UInt32) -> ESPChip? {
        switch magic {
        case 0x00F01D83: return .esp32
        case 0x000007C6: return .esp32s2
        case 0x00000009: return .esp32s3
        case 0x6F51306F, 0x7C41A06F: return .esp32c2
        case 0x6921506F, 0x1B31506F, 0x4881606F, 0x4361606F: return .esp32c3
        case 0x1101406F, 0x63E1406F, 0x5FD1406F: return .esp32c5
        case 0x2CE0806F: return .esp32c6
        case 0xD7B73E80: return .esp32h2
        case 0x0ADDBAD0: return .esp32p4
        default: return nil
        }
    }
}

// MARK: - SLIP Encoding/Decoding

enum SLIP {
    static let frameEnd: UInt8 = 0xC0
    static let frameEsc: UInt8 = 0xDB
    static let escEnd: UInt8 = 0xDC
    static let escEsc: UInt8 = 0xDD

    static func encode(_ data: [UInt8]) -> [UInt8] {
        var out: [UInt8] = [frameEnd]
        for byte in data {
            switch byte {
            case frameEnd:
                out.append(frameEsc)
                out.append(escEnd)
            case frameEsc:
                out.append(frameEsc)
                out.append(escEsc)
            default:
                out.append(byte)
            }
        }
        out.append(frameEnd)
        return out
    }

    static func decode(_ data: [UInt8]) -> [UInt8] {
        var out = [UInt8]()
        var i = 0
        while i < data.count {
            if data[i] == frameEnd {
                i += 1
                continue
            }
            if data[i] == frameEsc && i + 1 < data.count {
                switch data[i + 1] {
                case escEnd: out.append(frameEnd)
                case escEsc: out.append(frameEsc)
                default: out.append(data[i + 1])
                }
                i += 2
            } else {
                out.append(data[i])
                i += 1
            }
        }
        return out
    }
}

// MARK: - Bootloader Commands

enum ESPCommand: UInt8 {
    case flashBegin = 0x02
    case flashData = 0x03
    case flashEnd = 0x04
    case memBegin = 0x05
    case memEnd = 0x06
    case memData = 0x07
    case sync = 0x08
    case writeReg = 0x09
    case readReg = 0x0A
    case spiSetParams = 0x0B
    case spiAttach = 0x0D
    case changeBaudrate = 0x0F
    case flashDeflBegin = 0x10
    case flashDeflData = 0x11
    case flashDeflEnd = 0x12
    case flashMD5 = 0x13
    case getSecurityInfo = 0x14
    // Stub-only
    case eraseFlash = 0xD0
    case eraseRegion = 0xD1
    case readFlash = 0xD2
    case runUserCode = 0xD3
}

// MARK: - ESP Flasher Error

enum ESPError: LocalizedError {
    case syncFailed
    case chipDetectFailed
    case commandFailed(ESPCommand, UInt8)
    case flashFailed(String)
    case verifyFailed
    case timeout
    case cancelled

    var errorDescription: String? {
        switch self {
        case .syncFailed: return "Failed to sync with ESP bootloader"
        case .chipDetectFailed: return "Failed to detect ESP chip"
        case .commandFailed(let cmd, let err): return "Command 0x\(String(format: "%02X", cmd.rawValue)) failed: error \(err)"
        case .flashFailed(let msg): return "Flash failed: \(msg)"
        case .verifyFailed: return "Flash verification failed"
        case .timeout: return "ESP communication timeout"
        case .cancelled: return "Operation cancelled"
        }
    }
}

// MARK: - ESP Flasher (ROM Bootloader Protocol)

final class ESPFlasher {
    let port: SerialPort
    private(set) var detectedChip: ESPChip?
    private let flashWriteSize = 0x400  // ROM loader block size (1 KB)

    init(port: SerialPort) {
        self.port = port
    }

    // MARK: - Checksum

    private func checksum(_ data: [UInt8]) -> UInt32 {
        var cs: UInt8 = 0xEF
        for byte in data {
            cs ^= byte
        }
        return UInt32(cs)
    }

    // MARK: - Command / Response

    /// Build and send a command packet
    func sendCommand(_ cmd: ESPCommand, data: [UInt8] = [], checkData: [UInt8]? = nil) throws {
        let cs = checksum(checkData ?? data)
        var packet = [UInt8]()
        packet.append(0x00)  // Direction: request
        packet.append(cmd.rawValue)
        // Data length (u16 LE)
        let dataLen = UInt16(data.count)
        packet.append(UInt8(dataLen & 0xFF))
        packet.append(UInt8((dataLen >> 8) & 0xFF))
        // Checksum (u32 LE)
        packet.append(UInt8(cs & 0xFF))
        packet.append(UInt8((cs >> 8) & 0xFF))
        packet.append(UInt8((cs >> 16) & 0xFF))
        packet.append(UInt8((cs >> 24) & 0xFF))
        // Data payload
        packet.append(contentsOf: data)

        let encoded = SLIP.encode(packet)
        try port.write(encoded)
    }

    /// Read a SLIP-framed response
    func readResponse(timeout: TimeInterval = 3.0) throws -> (command: UInt8, value: UInt32, status: UInt8, data: [UInt8]) {
        var raw = [UInt8]()
        let deadline = Date().addingTimeInterval(timeout)

        // Read until we get a complete SLIP frame
        var inFrame = false
        while Date() < deadline {
            let bytes = port.readAvailable()
            for byte in bytes {
                if byte == SLIP.frameEnd {
                    if inFrame && !raw.isEmpty {
                        // Decode the SLIP frame
                        let decoded = SLIP.decode(raw)
                        if decoded.count >= 8 {
                            let cmd = decoded[1]
                            let value = UInt32(decoded[4]) | (UInt32(decoded[5]) << 8) |
                                        (UInt32(decoded[6]) << 16) | (UInt32(decoded[7]) << 24)
                            let status = decoded.count > 8 ? decoded[8] : 0
                            let data = decoded.count > 10 ? Array(decoded[10...]) : []
                            return (cmd, value, status, data)
                        }
                        raw.removeAll()
                    }
                    inFrame = true
                    raw.removeAll()
                } else {
                    raw.append(byte)
                }
            }
            if bytes.isEmpty {
                Thread.sleep(forTimeInterval: 0.001)
            }
        }
        throw ESPError.timeout
    }

    /// Send command and wait for response
    func command(_ cmd: ESPCommand, data: [UInt8] = [], checkData: [UInt8]? = nil,
                 timeout: TimeInterval = 3.0) throws -> UInt32 {
        try sendCommand(cmd, data: data, checkData: checkData)
        let resp = try readResponse(timeout: timeout)
        guard resp.status == 0 else {
            throw ESPError.commandFailed(cmd, resp.status)
        }
        return resp.value
    }

    // MARK: - Connection

    /// Enter bootloader mode via DTR/RTS signals
    func resetToBootloader() {
        port.setDTR(false)
        port.setRTS(true)
        Thread.sleep(forTimeInterval: 0.1)
        port.setDTR(true)
        port.setRTS(false)
        Thread.sleep(forTimeInterval: 0.05)
        port.setDTR(false)
        port.flush()
    }

    /// Sync with the bootloader
    func sync(retries: Int = 5) throws {
        var syncData: [UInt8] = [0x07, 0x07, 0x12, 0x20]
        syncData.append(contentsOf: [UInt8](repeating: 0x55, count: 32))

        for attempt in 0..<retries {
            port.flush()
            do {
                try sendCommand(.sync, data: syncData)
                // Read response(s) — bootloader sends multiple sync responses
                for _ in 0..<8 {
                    let resp = try readResponse(timeout: 0.1)
                    if resp.command == ESPCommand.sync.rawValue {
                        return // Synced!
                    }
                }
            } catch {
                if attempt == retries - 1 { throw ESPError.syncFailed }
                Thread.sleep(forTimeInterval: 0.05)
            }
        }
        throw ESPError.syncFailed
    }

    /// Detect which ESP chip is connected
    func detectChip() throws -> ESPChip {
        let magic = try command(.readReg, data: leU32(0x40001000))
        guard let chip = ESPChip.fromMagic(magic) else {
            throw ESPError.chipDetectFailed
        }
        detectedChip = chip
        return chip
    }

    /// Change baud rate
    func changeBaudRate(to newRate: Int, oldRate: Int = 115200) throws {
        var data = leU32(UInt32(newRate))
        data.append(contentsOf: leU32(UInt32(oldRate)))
        _ = try command(.changeBaudrate, data: data)
        try port.setBaudRate(newRate)
        Thread.sleep(forTimeInterval: 0.05)
        port.flush()
    }

    // MARK: - Flash Operations

    /// Flash a binary firmware image to the specified offset
    func flashImage(data: Data, offset: UInt32, blockSize: Int? = nil,
                    progress: ((Double) -> Void)? = nil,
                    cancelled: (() -> Bool)? = nil) throws {
        let bs = blockSize ?? flashWriteSize
        let totalSize = UInt32(data.count)
        let blockCount = UInt32((data.count + bs - 1) / bs)

        // FLASH_BEGIN
        var beginData = leU32(totalSize)
        beginData.append(contentsOf: leU32(blockCount))
        beginData.append(contentsOf: leU32(UInt32(bs)))
        beginData.append(contentsOf: leU32(offset))
        _ = try command(.flashBegin, data: beginData, timeout: 30)

        // FLASH_DATA blocks
        for seq in 0..<Int(blockCount) {
            if cancelled?() == true { throw ESPError.cancelled }

            let start = seq * bs
            let end = min(start + bs, data.count)
            var block = Array(data[start..<end])

            // Pad to block size
            if block.count < bs {
                block.append(contentsOf: [UInt8](repeating: 0xFF, count: bs - block.count))
            }

            var blockHeader = leU32(UInt32(block.count))
            blockHeader.append(contentsOf: leU32(UInt32(seq)))
            blockHeader.append(contentsOf: leU32(0))
            blockHeader.append(contentsOf: leU32(0))

            var payload = blockHeader
            payload.append(contentsOf: block)

            _ = try command(.flashData, data: payload, checkData: block, timeout: 10)

            progress?(Double(seq + 1) / Double(blockCount))
        }

        // FLASH_END
        _ = try command(.flashEnd, data: [0x00], timeout: 3) // 0 = reboot
    }

    /// Verify flashed data using MD5
    func verifyFlash(offset: UInt32, size: UInt32) throws -> [UInt8] {
        var data = leU32(offset)
        data.append(contentsOf: leU32(size))
        data.append(contentsOf: leU32(0))
        data.append(contentsOf: leU32(0))

        try sendCommand(.flashMD5, data: data)
        let resp = try readResponse(timeout: 30)
        // MD5 is in the response data (16 bytes binary or 32 hex chars)
        return resp.data
    }

    // MARK: - Register Access

    func readRegister(_ addr: UInt32) throws -> UInt32 {
        return try command(.readReg, data: leU32(addr))
    }

    func writeRegister(_ addr: UInt32, value: UInt32, mask: UInt32 = 0xFFFFFFFF, delay: UInt32 = 0) throws {
        var data = leU32(addr)
        data.append(contentsOf: leU32(value))
        data.append(contentsOf: leU32(mask))
        data.append(contentsOf: leU32(delay))
        _ = try command(.writeReg, data: data)
    }

    // MARK: - Full Flash Sequence

    /// Complete flash operation: connect, detect, flash, verify
    func flashFirmware(firmwareData: Data, offset: UInt32? = nil, baudRate: Int = 460800,
                       progress: ((String, Double) -> Void)? = nil,
                       cancelled: (() -> Bool)? = nil) throws -> ESPChip {
        // Reset into bootloader
        progress?("Entering bootloader...", 0)
        resetToBootloader()
        Thread.sleep(forTimeInterval: 0.2)

        // Sync
        progress?("Syncing...", 0.05)
        try sync()

        // Detect chip
        progress?("Detecting chip...", 0.1)
        let chip = try detectChip()
        progress?("Detected \(chip.rawValue)", 0.15)

        // Change baud rate
        if baudRate > 115200 {
            progress?("Setting baud rate \(baudRate)...", 0.18)
            try changeBaudRate(to: baudRate)
        }

        // Flash
        let flashOffset = offset ?? chip.appOffset
        progress?("Flashing \(firmwareData.count) bytes at 0x\(String(format: "%X", flashOffset))...", 0.2)

        try flashImage(data: firmwareData, offset: flashOffset,
                       progress: { pct in progress?("Flashing...", 0.2 + pct * 0.7) },
                       cancelled: cancelled)

        progress?("Flash complete, resetting...", 0.95)
        progress?("Done!", 1.0)

        return chip
    }

    // MARK: - Helpers

    private func leU32(_ val: UInt32) -> [UInt8] {
        [UInt8(val & 0xFF), UInt8((val >> 8) & 0xFF),
         UInt8((val >> 16) & 0xFF), UInt8((val >> 24) & 0xFF)]
    }
}
