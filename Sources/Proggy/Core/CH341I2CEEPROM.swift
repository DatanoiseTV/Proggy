import Foundation

// MARK: - I2C EEPROM Read/Write (24Cxx series)

extension CH341Device {

    /// Whether the EEPROM uses 2-byte addressing (24C32 and above: capacity > 2048 bytes)
    private func uses2ByteAddr(capacity: Int) -> Bool {
        capacity > 2048
    }

    /// Page size for common 24Cxx EEPROMs
    private func eepromPageSize(capacity: Int) -> Int {
        switch capacity {
        case ...128: return 8         // 24C01
        case ...256: return 8         // 24C02
        case ...512: return 16        // 24C04
        case ...1024: return 16       // 24C08
        case ...2048: return 16       // 24C16
        case ...4096: return 32       // 24C32
        case ...8192: return 32       // 24C64
        case ...16384: return 64      // 24C128
        case ...32768: return 64      // 24C256
        case ...65536: return 128     // 24C512
        default: return 128
        }
    }

    // MARK: - Read I2C EEPROM

    /// Read the full contents of an I2C EEPROM.
    ///
    /// - Parameters:
    ///   - address: 7-bit I2C device address (typically 0x50)
    ///   - capacity: Total EEPROM size in bytes
    ///   - progress: Progress callback (0.0 to 1.0)
    ///   - cancelled: Cancellation check callback
    func i2cEEPROMRead(address: UInt8, capacity: Int,
                        progress: ((Double) -> Void)? = nil,
                        cancelled: (() -> Bool)? = nil) throws -> Data {
        let twoByteAddr = uses2ByteAddr(capacity: capacity)
        let chunkSize = 32  // Read 32 bytes at a time (max I2C stream)
        var result = Data(capacity: capacity)
        var memAddr: UInt16 = 0

        while result.count < capacity {
            if cancelled?() == true { throw CH341Error.cancelled }

            let toRead = min(chunkSize, capacity - result.count)
            let writeAddr = address << 1
            let readAddr = (address << 1) | 0x01

            var cmd = [UInt8]()
            cmd.append(CH341.cmdI2CStream)

            // Set address pointer
            cmd.append(CH341.i2cStart)
            if twoByteAddr {
                cmd.append(CH341.i2cOut | 3)
                cmd.append(writeAddr)
                cmd.append(UInt8((memAddr >> 8) & 0xFF))
                cmd.append(UInt8(memAddr & 0xFF))
            } else {
                // For 24C04/08/16, upper address bits are in the device address
                let devAddr = writeAddr | (UInt8((memAddr >> 7) & 0x0E))
                cmd.append(CH341.i2cOut | 2)
                cmd.append(devAddr)
                cmd.append(UInt8(memAddr & 0xFF))
            }

            // Repeated start + read
            cmd.append(CH341.i2cStart)
            if twoByteAddr {
                cmd.append(CH341.i2cOut | 1)
                cmd.append(readAddr)
            } else {
                let devAddr = readAddr | (UInt8((memAddr >> 7) & 0x0E))
                cmd.append(CH341.i2cOut | 1)
                cmd.append(devAddr)
            }

            // Read bytes
            var remaining = toRead
            while remaining > 0 {
                let chunk = min(remaining, Int(CH341.i2cMaxCmd))
                cmd.append(CH341.i2cIn | UInt8(chunk))
                remaining -= chunk
            }

            cmd.append(CH341.i2cStop)
            cmd.append(CH341.i2cEnd)

            _ = try bulkWrite(cmd)
            let response = try bulkRead(toRead + 1) // +1 for ACK byte

            // Skip the first byte (ACK from address phase)
            let dataBytes: [UInt8]
            if response.count > 1 {
                dataBytes = Array(response.suffix(from: 1).prefix(toRead))
            } else if response.count == toRead {
                dataBytes = Array(response.prefix(toRead))
            } else {
                dataBytes = response
            }
            result.append(contentsOf: dataBytes)

            memAddr += UInt16(dataBytes.count)
            progress?(Double(result.count) / Double(capacity))
        }

        return result.prefix(capacity)
    }

    // MARK: - Write I2C EEPROM

    /// Write data to an I2C EEPROM with proper page programming.
    ///
    /// - Parameters:
    ///   - address: 7-bit I2C device address (typically 0x50)
    ///   - data: Data to write
    ///   - capacity: Total EEPROM size (for address mode detection)
    ///   - progress: Progress callback
    ///   - cancelled: Cancellation check callback
    func i2cEEPROMWrite(address: UInt8, data: Data, capacity: Int,
                         progress: ((Double) -> Void)? = nil,
                         cancelled: (() -> Bool)? = nil) throws {
        let twoByteAddr = uses2ByteAddr(capacity: capacity)
        let pageSize = eepromPageSize(capacity: capacity)
        var offset = 0
        let total = data.count

        while offset < total {
            if cancelled?() == true { throw CH341Error.cancelled }

            // Calculate bytes to write in this page
            let memAddr = UInt16(offset)
            let pageOffset = offset % pageSize
            let bytesInPage = min(pageSize - pageOffset, total - offset)

            let writeAddr = address << 1

            var cmd = [UInt8]()
            cmd.append(CH341.cmdI2CStream)
            cmd.append(CH341.i2cStart)

            if twoByteAddr {
                // 2-byte address + data
                let headerLen = UInt8(3 + bytesInPage)
                cmd.append(CH341.i2cOut | headerLen)
                cmd.append(writeAddr)
                cmd.append(UInt8((memAddr >> 8) & 0xFF))
                cmd.append(UInt8(memAddr & 0xFF))
            } else {
                // 1-byte address (with upper bits in device addr for >256B EEPROMs)
                let devAddr = writeAddr | (UInt8((memAddr >> 7) & 0x0E))
                let headerLen = UInt8(2 + bytesInPage)
                cmd.append(CH341.i2cOut | headerLen)
                cmd.append(devAddr)
                cmd.append(UInt8(memAddr & 0xFF))
            }

            // Append page data
            for i in 0..<bytesInPage {
                cmd.append(data[offset + i])
            }

            cmd.append(CH341.i2cStop)
            cmd.append(CH341.i2cEnd)

            _ = try bulkWrite(cmd)
            _ = try? bulkRead(1) // Read ACK

            // Wait for write cycle (typically 5ms for most EEPROMs)
            // Poll with ACK polling: send start+address, check for ACK
            let deadline = Date().addingTimeInterval(0.05) // 50ms max
            while Date() < deadline {
                Thread.sleep(forTimeInterval: 0.002)

                var poll = [UInt8]()
                poll.append(CH341.cmdI2CStream)
                poll.append(CH341.i2cStart)
                poll.append(CH341.i2cOut | 1)
                poll.append(writeAddr)
                poll.append(CH341.i2cStop)
                poll.append(CH341.i2cEnd)

                _ = try bulkWrite(poll)
                let resp = try bulkRead(1)

                // ACK received = write complete
                if !resp.isEmpty && (resp[0] & 0x80) == 0 {
                    break
                }
            }

            offset += bytesInPage
            progress?(Double(offset) / Double(total))
        }
    }

    // MARK: - Verify I2C EEPROM

    func i2cEEPROMVerify(address: UInt8, data: Data, capacity: Int,
                          progress: ((Double) -> Void)? = nil,
                          cancelled: (() -> Bool)? = nil) throws {
        let readData = try i2cEEPROMRead(address: address, capacity: data.count,
                                          progress: progress, cancelled: cancelled)
        guard readData.count == data.count else {
            throw CH341Error.verifyFailed(address: 0)
        }
        for i in 0..<data.count {
            if readData[i] != data[i] {
                throw CH341Error.verifyFailed(address: UInt32(i))
            }
        }
    }
}
