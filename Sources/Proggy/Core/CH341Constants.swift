import Foundation

// MARK: - USB Device Identification

enum CH341 {
    static let usbVendorID: UInt16 = 0x1A86
    static let usbProductID: UInt16 = 0x5512
    static let usbTimeout: UInt32 = 1000

    static let bulkWriteEndpoint: UInt8 = 0x02
    static let bulkReadEndpoint: UInt8 = 0x82

    static let packetLength: Int = 0x20      // 32 bytes per USB packet
    static let maxPackets: Int = 256
    static let maxTransferSize: Int = 0x2000 // 32 * 256 = 8192

    // MARK: - Command Codes

    static let cmdSetOutput: UInt8 = 0xA1
    static let cmdIOAddr: UInt8 = 0xA2
    static let cmdPrintOut: UInt8 = 0xA3
    static let cmdSPIStream: UInt8 = 0xA8
    static let cmdSIOStream: UInt8 = 0xA9
    static let cmdI2CStream: UInt8 = 0xAA
    static let cmdUIOStream: UInt8 = 0xAB

    // MARK: - I2C Stream Sub-commands

    static let i2cStart: UInt8 = 0x74
    static let i2cStop: UInt8 = 0x75
    static let i2cOut: UInt8 = 0x80        // OR with byte count
    static let i2cIn: UInt8 = 0xC0         // OR with byte count
    static let i2cSet: UInt8 = 0x60        // OR with speed
    static let i2cDelayUS: UInt8 = 0x40
    static let i2cDelayMS: UInt8 = 0x50
    static let i2cEnd: UInt8 = 0x00
    static let i2cMaxCmd: Int = 0x20

    // MARK: - UIO Stream Sub-commands

    static let uioIn: UInt8 = 0x00
    static let uioDir: UInt8 = 0x40
    static let uioOut: UInt8 = 0x80
    static let uioDelayUS: UInt8 = 0xC0
    static let uioEnd: UInt8 = 0x20

    // MARK: - SPI Chip Select

    static let csAssert: [UInt8] = [cmdUIOStream, uioOut | 0x36, uioDir | 0x3F, uioEnd]
    static let csDeassert: [UInt8] = [cmdUIOStream, uioOut | 0x37, uioEnd]

    // MARK: - SPI Flash Commands

    static let spiReadData3B: UInt8 = 0x03
    static let spiReadData4B: UInt8 = 0x13
    static let spiPageProgram3B: UInt8 = 0x02
    static let spiPageProgram4B: UInt8 = 0x12
    static let spiReadStatus: UInt8 = 0x05
    static let spiWriteStatus: UInt8 = 0x01
    static let spiWriteEnable: UInt8 = 0x06
    static let spiWriteDisable: UInt8 = 0x04
    static let spiChipErase: UInt8 = 0xC7
    static let spiChipEraseAlt: UInt8 = 0x60  // Some chips (AMIC, older) use 0x60
    static let spiSectorErase: UInt8 = 0x20
    static let spiBlock32Erase: UInt8 = 0x52
    static let spiBlock64Erase: UInt8 = 0xD8
    static let spiReadJEDEC: UInt8 = 0x9F

    static let spiPageSize: Int = 256
    static let spiSectorSize: Int = 4096

    // MARK: - Status Register Bits

    static let statusWIP: UInt8 = 0x01     // Write In Progress
    static let statusWEL: UInt8 = 0x02     // Write Enable Latch
}

// MARK: - I2C/SPI Speed

enum CH341Speed: UInt8, CaseIterable, Identifiable {
    case i2c20k = 0x00
    case i2c100k = 0x01
    case i2c400k = 0x02
    case i2c750k = 0x03

    var id: UInt8 { rawValue }

    var description: String {
        switch self {
        case .i2c20k: return "20 kHz"
        case .i2c100k: return "100 kHz"
        case .i2c400k: return "400 kHz"
        case .i2c750k: return "750 kHz"
        }
    }
}

// MARK: - Bit Reversal Table (CH341 uses LSB-first for SPI)

let swapByte: [UInt8] = {
    var table = [UInt8](repeating: 0, count: 256)
    for i in 0..<256 {
        var val: UInt8 = 0
        for bit in 0..<8 {
            if i & (1 << bit) != 0 {
                val |= UInt8(1 << (7 - bit))
            }
        }
        table[i] = val
    }
    return table
}()

// MARK: - Error Types

enum CH341Error: LocalizedError {
    case notConnected
    case openFailed(String)
    case claimFailed
    case transferFailed(Int32)
    case chipNotDetected
    case eraseFailed
    case writeFailed
    case verifyFailed(address: UInt32)
    case timeout
    case cancelled

    var errorDescription: String? {
        switch self {
        case .notConnected: return "CH341A device not connected"
        case .openFailed(let msg): return "Failed to open device: \(msg)"
        case .claimFailed: return "Failed to claim USB interface"
        case .transferFailed(let code): return "USB transfer failed (error \(code))"
        case .chipNotDetected: return "No flash chip detected"
        case .eraseFailed: return "Chip erase failed or timed out"
        case .writeFailed: return "Write operation failed"
        case .verifyFailed(let addr): return String(format: "Verify failed at address 0x%08X", addr)
        case .timeout: return "Operation timed out"
        case .cancelled: return "Operation cancelled"
        }
    }
}

// MARK: - JEDEC Info

struct JEDECInfo: Equatable {
    let manufacturerID: UInt8
    let memoryType: UInt16
    let capacityBits: UInt8
    var capacityBytes: Int { 1 << Int(capacityBits) }

    var manufacturerName: String {
        ChipDatabase.manufacturerName(for: manufacturerID)
    }

    var description: String {
        let sizeStr: String
        let bytes = capacityBytes
        if bytes >= 1_048_576 {
            sizeStr = "\(bytes / 1_048_576) MB"
        } else if bytes >= 1024 {
            sizeStr = "\(bytes / 1024) KB"
        } else {
            sizeStr = "\(bytes) B"
        }
        return "\(manufacturerName) \(sizeStr) (ID: \(String(format: "%02X %04X", manufacturerID, memoryType)))"
    }
}
