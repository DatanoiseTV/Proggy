import Foundation

// MARK: - SPI FRAM (FM25xxx / MB85RS series)
//
// SPI FRAM uses the same command set as SPI flash but:
// - No erase required (byte-addressable writes)
// - No write delay (writes complete instantly)
// - No page boundary limitation
// - Unlimited write endurance (10^12+ cycles)

extension CH341Device {

    // MARK: - SPI FRAM Commands
    // Same opcodes as SPI flash
    private static let framWREN: UInt8 = 0x06   // Write Enable
    private static let framWRDI: UInt8 = 0x04   // Write Disable
    private static let framRDSR: UInt8 = 0x05   // Read Status Register
    private static let framWRSR: UInt8 = 0x01   // Write Status Register
    private static let framREAD: UInt8 = 0x03   // Read Data
    private static let framWRITE: UInt8 = 0x02  // Write Data
    private static let framRDID: UInt8 = 0x9F   // Read Device ID

    // MARK: - SPI FRAM Operations

    /// Read SPI FRAM device ID (JEDEC format: manufacturer + product)
    func spiFramReadID() throws -> (manufacturer: UInt8, product: UInt16) {
        let cmd: [UInt8] = [CH341Device.framRDID, 0, 0, 0]
        let resp = try spiStream(cmd, length: 4)
        guard resp.count >= 4 else { throw CH341Error.chipNotDetected }
        let mfr = resp[1]
        let prod = (UInt16(resp[2]) << 8) | UInt16(resp[3])
        guard mfr != 0xFF && mfr != 0x00 else { throw CH341Error.chipNotDetected }
        return (mfr, prod)
    }

    /// Read SPI FRAM contents
    func spiFramRead(address: UInt32, length: Int,
                     progress: ((Double) -> Void)? = nil,
                     cancelled: (() -> Bool)? = nil) throws -> Data {
        let use3ByteAddr = address + UInt32(length) <= 0x10000
        let chunkSize = 256
        var result = Data(capacity: length)
        var currentAddr = address
        var remaining = length

        while remaining > 0 {
            if cancelled?() == true { throw CH341Error.cancelled }
            let toRead = min(remaining, chunkSize)

            var cmd: [UInt8] = [CH341Device.framREAD]
            if !use3ByteAddr {
                cmd.append(UInt8((currentAddr >> 16) & 0xFF))
            }
            cmd.append(UInt8((currentAddr >> 8) & 0xFF))
            cmd.append(UInt8(currentAddr & 0xFF))
            cmd.append(contentsOf: [UInt8](repeating: 0, count: toRead))

            let resp = try spiStream(cmd, length: cmd.count)
            let headerLen = use3ByteAddr ? 3 : 4
            if resp.count > headerLen {
                result.append(contentsOf: resp[headerLen...].prefix(toRead))
            }

            currentAddr += UInt32(toRead)
            remaining -= toRead
            progress?(Double(length - remaining) / Double(length))
        }
        return result
    }

    /// Write to SPI FRAM (no erase needed, no page boundary, no write delay)
    func spiFramWrite(address: UInt32, data: Data,
                      progress: ((Double) -> Void)? = nil,
                      cancelled: (() -> Bool)? = nil) throws {
        let use3ByteAddr = address + UInt32(data.count) <= 0x10000
        let chunkSize = 256  // Write in 256-byte chunks for progress reporting
        var currentAddr = address
        var offset = 0

        while offset < data.count {
            if cancelled?() == true { throw CH341Error.cancelled }
            let toWrite = min(chunkSize, data.count - offset)

            // Write enable
            _ = try spiStream([CH341Device.framWREN], length: 1)

            // Write data
            var cmd: [UInt8] = [CH341Device.framWRITE]
            if !use3ByteAddr {
                cmd.append(UInt8((currentAddr >> 16) & 0xFF))
            }
            cmd.append(UInt8((currentAddr >> 8) & 0xFF))
            cmd.append(UInt8(currentAddr & 0xFF))
            cmd.append(contentsOf: data[offset..<(offset + toWrite)])

            _ = try spiStream(cmd, length: cmd.count)
            // No write delay needed for FRAM!

            currentAddr += UInt32(toWrite)
            offset += toWrite
            progress?(Double(offset) / Double(data.count))
        }
    }

    /// Verify SPI FRAM contents
    func spiFramVerify(address: UInt32, data: Data,
                       progress: ((Double) -> Void)? = nil,
                       cancelled: (() -> Bool)? = nil) throws {
        let readData = try spiFramRead(address: address, length: data.count,
                                        progress: progress, cancelled: cancelled)
        for i in 0..<data.count {
            if readData[i] != data[i] {
                throw CH341Error.verifyFailed(address: address + UInt32(i))
            }
        }
    }
}

// MARK: - I2C FRAM (FM24xxx / MB85RC series)
//
// I2C FRAM is identical to I2C EEPROM protocol but:
// - No write delay (writes complete instantly during STOP condition)
// - Unlimited write endurance
// - Default address 0x50 (same as EEPROM)
// We reuse i2cEEPROM methods but skip the ACK polling wait.

extension CH341Device {

    /// Read I2C FRAM (same as EEPROM read, no differences)
    func i2cFramRead(address: UInt8, capacity: Int,
                     progress: ((Double) -> Void)? = nil,
                     cancelled: (() -> Bool)? = nil) throws -> Data {
        // Reuse EEPROM read — protocol is identical
        return try i2cEEPROMRead(address: address, capacity: capacity,
                                  progress: progress, cancelled: cancelled)
    }

    /// Write I2C FRAM — same as EEPROM but NO write cycle delay needed
    func i2cFramWrite(address: UInt8, data: Data, capacity: Int,
                      progress: ((Double) -> Void)? = nil,
                      cancelled: (() -> Bool)? = nil) throws {
        let twoByteAddr = capacity > 2048
        let pageSize = 32  // FRAM has no page limit but we chunk for progress
        var offset = 0

        while offset < data.count {
            if cancelled?() == true { throw CH341Error.cancelled }

            let toWrite = min(pageSize, data.count - offset)
            let memAddr = UInt16(offset)
            let writeAddr = address << 1

            var cmd = [UInt8]()
            cmd.append(CH341.cmdI2CStream)
            cmd.append(CH341.i2cStart)

            if twoByteAddr {
                cmd.append(CH341.i2cOut | UInt8(3 + toWrite))
                cmd.append(writeAddr)
                cmd.append(UInt8((memAddr >> 8) & 0xFF))
                cmd.append(UInt8(memAddr & 0xFF))
            } else {
                let devAddr = writeAddr | (UInt8((memAddr >> 7) & 0x0E))
                cmd.append(CH341.i2cOut | UInt8(2 + toWrite))
                cmd.append(devAddr)
                cmd.append(UInt8(memAddr & 0xFF))
            }

            for i in 0..<toWrite {
                cmd.append(data[offset + i])
            }

            cmd.append(CH341.i2cStop)
            cmd.append(CH341.i2cEnd)

            _ = try bulkWrite(cmd)
            _ = try? bulkRead(1)

            // NO write cycle delay for FRAM — writes complete at STOP

            offset += toWrite
            progress?(Double(offset) / Double(data.count))
        }
    }
}
