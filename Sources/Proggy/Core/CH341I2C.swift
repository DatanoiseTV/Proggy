import Foundation

// MARK: - I2C Operations

extension CH341Device {

    /// Write data to an I2C device at the given 7-bit address.
    func i2cWrite(address: UInt8, data: [UInt8]) throws {
        let addrByte = address << 1  // Write bit = 0

        var cmd = [UInt8]()
        cmd.append(CH341.cmdI2CStream)
        cmd.append(CH341.i2cStart)
        cmd.append(CH341.i2cOut | 1)
        cmd.append(addrByte)

        // Send data in chunks respecting max command length
        var offset = 0
        while offset < data.count {
            let chunkSize = min(data.count - offset, Int(CH341.i2cMaxCmd) - 1)
            cmd.append(CH341.i2cOut | UInt8(chunkSize))
            for i in 0..<chunkSize {
                cmd.append(data[offset + i])
            }
            offset += chunkSize
        }

        cmd.append(CH341.i2cStop)
        cmd.append(CH341.i2cEnd)

        _ = try bulkWrite(cmd)
    }

    /// Read bytes from an I2C device at the given 7-bit address.
    func i2cRead(address: UInt8, length: Int) throws -> [UInt8] {
        guard length > 0 else { return [] }
        let addrByte = (address << 1) | 0x01  // Read bit = 1

        var cmd = [UInt8]()
        cmd.append(CH341.cmdI2CStream)
        cmd.append(CH341.i2cStart)
        cmd.append(CH341.i2cOut | 1)
        cmd.append(addrByte)

        // Request read in chunks
        var remaining = length
        while remaining > 0 {
            let chunkSize = min(remaining, Int(CH341.i2cMaxCmd))
            cmd.append(CH341.i2cIn | UInt8(chunkSize))
            remaining -= chunkSize
        }

        cmd.append(CH341.i2cStop)
        cmd.append(CH341.i2cEnd)

        _ = try bulkWrite(cmd)
        let response = try bulkRead(length)
        return response
    }

    /// Write then read (common I2C register access pattern).
    /// Writes `writeData` then restarts and reads `readLength` bytes.
    func i2cWriteRead(address: UInt8, writeData: [UInt8], readLength: Int) throws -> [UInt8] {
        let writeAddr = address << 1
        let readAddr = (address << 1) | 0x01

        var cmd = [UInt8]()
        cmd.append(CH341.cmdI2CStream)

        // Start + write address + data
        cmd.append(CH341.i2cStart)
        cmd.append(CH341.i2cOut | UInt8(1 + writeData.count))
        cmd.append(writeAddr)
        cmd.append(contentsOf: writeData)

        // Repeated start + read address
        cmd.append(CH341.i2cStart)
        cmd.append(CH341.i2cOut | 1)
        cmd.append(readAddr)

        // Read
        var remaining = readLength
        while remaining > 0 {
            let chunkSize = min(remaining, Int(CH341.i2cMaxCmd))
            cmd.append(CH341.i2cIn | UInt8(chunkSize))
            remaining -= chunkSize
        }

        cmd.append(CH341.i2cStop)
        cmd.append(CH341.i2cEnd)

        _ = try bulkWrite(cmd)
        return try bulkRead(readLength)
    }

    /// Scan the I2C bus for responding devices. Returns list of 7-bit addresses.
    func i2cScan() throws -> [UInt8] {
        var found = [UInt8]()
        for addr: UInt8 in 0x03...0x77 {
            let addrByte = addr << 1

            var cmd = [UInt8]()
            cmd.append(CH341.cmdI2CStream)
            cmd.append(CH341.i2cStart)
            cmd.append(CH341.i2cOut | 1)
            cmd.append(addrByte)
            cmd.append(CH341.i2cStop)
            cmd.append(CH341.i2cEnd)

            _ = try bulkWrite(cmd)
            let response = try bulkRead(1)

            // If ACK received (response byte has bit 7 clear), device is present
            if !response.isEmpty && (response[0] & 0x80) == 0 {
                found.append(addr)
            }
        }
        return found
    }
}
