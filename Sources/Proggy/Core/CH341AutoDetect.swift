import Foundation

// MARK: - Auto-detection for SPI and I2C devices

struct DetectedDevice {
    let type: DeviceType
    let manufacturer: String
    let name: String?
    let capacity: Int
    let rawID: String  // hex dump of raw ID bytes

    enum DeviceType: String {
        case spiFlash = "SPI Flash"
        case spiEEPROM = "SPI EEPROM"
        case i2cEEPROM = "I2C EEPROM"
    }
}

extension CH341Device {

    // MARK: - SPI Device Auto-Detection

    /// Try multiple SPI identification methods and return the best match.
    func spiAutoDetect() throws -> DetectedDevice? {
        // Method 1: JEDEC ID (0x9F) — standard for SPI flash
        if let result = try? spiDetectJEDEC() {
            return result
        }

        // Method 2: REMS - Read Electronic Manufacturer/Device ID (0x90)
        if let result = try? spiDetectREMS() {
            return result
        }

        // Method 3: RDID / Release from Deep Power-Down + ID (0xAB)
        if let result = try? spiDetectRDID() {
            return result
        }

        return nil
    }

    /// JEDEC ID (0x9F) — works for most SPI flash chips
    private func spiDetectJEDEC() throws -> DetectedDevice? {
        var cmd = [UInt8](repeating: 0, count: 4)
        cmd[0] = 0x9F
        let response = try spiStream(cmd, length: 4)
        guard response.count >= 4 else { return nil }

        let mfr = response[1]
        let memType = (UInt16(response[2]) << 8) | UInt16(response[3])
        let capBits = response[3]

        // Check for invalid responses
        guard mfr != 0xFF && mfr != 0x00 else { return nil }
        guard memType != 0xFFFF && memType != 0x0000 else { return nil }

        let rawID = response[1...3].map { String(format: "%02X", $0) }.joined(separator: " ")
        let mfrName = ChipDatabase.manufacturerName(for: mfr)

        // Try to match in chip library
        let chipKey = (UInt32(mfr) << 16) | UInt32(memType)
        let knownChip = ChipDatabase.knownChips[chipKey]

        // Also try to match in the ChipEntry library
        let capacity = knownChip?.capacity ?? (1 << Int(capBits))

        return DetectedDevice(
            type: .spiFlash,
            manufacturer: mfrName,
            name: knownChip?.name,
            capacity: capacity,
            rawID: rawID
        )
    }

    /// REMS - Read Electronic Manufacturer & Device ID (0x90 + 3 dummy + 2 read)
    /// Works for many SPI flash and some SPI EEPROM chips.
    private func spiDetectREMS() throws -> DetectedDevice? {
        var cmd: [UInt8] = [0x90, 0x00, 0x00, 0x00, 0x00, 0x00]
        let response = try spiStream(cmd, length: 6)
        guard response.count >= 6 else { return nil }

        let mfr = response[4]
        let devID = response[5]

        guard mfr != 0xFF && mfr != 0x00 else { return nil }
        guard devID != 0xFF && devID != 0x00 else { return nil }

        let rawID = String(format: "%02X %02X", mfr, devID)
        let mfrName = ChipDatabase.manufacturerName(for: mfr)

        // Try to identify capacity from device ID
        let capacity = spiEEPROMCapacity(mfr: mfr, devID: devID)

        return DetectedDevice(
            type: .spiEEPROM,
            manufacturer: mfrName,
            name: spiEEPROMName(mfr: mfr, devID: devID),
            capacity: capacity,
            rawID: rawID
        )
    }

    /// RDID / Release from Deep Power-Down + Read ID (0xAB + 3 dummy + 1 read)
    /// Returns a single device ID byte. Used by some older/smaller SPI devices.
    private func spiDetectRDID() throws -> DetectedDevice? {
        var cmd: [UInt8] = [0xAB, 0x00, 0x00, 0x00, 0x00]
        let response = try spiStream(cmd, length: 5)
        guard response.count >= 5 else { return nil }

        let devID = response[4]
        guard devID != 0xFF && devID != 0x00 else { return nil }

        let rawID = String(format: "%02X", devID)

        return DetectedDevice(
            type: .spiEEPROM,
            manufacturer: "Unknown",
            name: nil,
            capacity: spiLegacyCapacity(devID: devID),
            rawID: rawID
        )
    }

    // MARK: - I2C EEPROM Auto-Detection

    /// Scan I2C bus for EEPROMs at standard addresses (0x50-0x57)
    /// and attempt to determine capacity by address wrap-around detection.
    func i2cAutoDetect() throws -> [DetectedDevice] {
        var found = [DetectedDevice]()

        // Scan standard EEPROM addresses 0x50-0x57
        for addr: UInt8 in 0x50...0x57 {
            // Try to read 1 byte to see if device ACKs
            let addrByte = (addr << 1) | 0x01  // Read mode

            var cmd = [UInt8]()
            cmd.append(CH341.cmdI2CStream)
            cmd.append(CH341.i2cStart)
            cmd.append(CH341.i2cOut | 1)
            cmd.append(addrByte)
            cmd.append(CH341.i2cIn | 1)
            cmd.append(CH341.i2cStop)
            cmd.append(CH341.i2cEnd)

            _ = try bulkWrite(cmd)
            let response = try bulkRead(2)

            // First byte is the ACK status from the address phase
            // If the device responded, byte will have bit 7 clear
            guard response.count >= 1, (response[0] & 0x80) == 0 else { continue }

            // Device found! Try to determine capacity.
            let capacity = try i2cProbeCapacity(address: addr)
            let name = i2cEEPROMName(capacity: capacity)

            found.append(DetectedDevice(
                type: .i2cEEPROM,
                manufacturer: "Unknown",
                name: name,
                capacity: capacity,
                rawID: String(format: "0x%02X", addr)
            ))
        }

        return found
    }

    /// Probe I2C EEPROM capacity by reading byte at address 0 and comparing
    /// with reads at power-of-2 boundaries to detect wrap-around.
    private func i2cProbeCapacity(address: UInt8) throws -> Int {
        // Read byte at offset 0
        let byte0 = try i2cReadByte(deviceAddr: address, memAddr: 0x0000, twoByteAddr: false)

        // Try each common EEPROM size and check if reading at that offset
        // wraps back to offset 0 (returns same byte)
        let sizes = [128, 256, 512, 1024, 2048, 4096, 8192, 16384, 32768, 65536]

        for size in sizes {
            let twoByteAddr = size > 256

            // Read byte at the boundary
            let testByte: UInt8
            do {
                testByte = try i2cReadByte(deviceAddr: address, memAddr: UInt16(size), twoByteAddr: twoByteAddr)
            } catch {
                // If read fails, this might be beyond device capacity
                return size
            }

            // If reading at 'size' offset gives same as offset 0, we've wrapped
            // (This is a heuristic — not 100% reliable if data happens to match)
            if testByte == byte0 && size < 65536 {
                // Verify by checking a few more bytes
                let byte1 = try? i2cReadByte(deviceAddr: address, memAddr: 0x0001, twoByteAddr: false)
                let testByte1 = try? i2cReadByte(deviceAddr: address, memAddr: UInt16(size + 1), twoByteAddr: twoByteAddr)
                if byte1 == testByte1 {
                    return size  // Confirmed wrap-around
                }
            }
        }

        return 65536 // Default to max common size
    }

    /// Read a single byte from I2C EEPROM at the given memory address.
    private func i2cReadByte(deviceAddr: UInt8, memAddr: UInt16, twoByteAddr: Bool) throws -> UInt8 {
        let writeAddr = deviceAddr << 1
        let readAddr = (deviceAddr << 1) | 0x01

        var cmd = [UInt8]()
        cmd.append(CH341.cmdI2CStream)
        cmd.append(CH341.i2cStart)

        if twoByteAddr {
            cmd.append(CH341.i2cOut | 3)
            cmd.append(writeAddr)
            cmd.append(UInt8((memAddr >> 8) & 0xFF))
            cmd.append(UInt8(memAddr & 0xFF))
        } else {
            cmd.append(CH341.i2cOut | 2)
            cmd.append(writeAddr)
            cmd.append(UInt8(memAddr & 0xFF))
        }

        // Repeated start + read
        cmd.append(CH341.i2cStart)
        cmd.append(CH341.i2cOut | 1)
        cmd.append(readAddr)
        cmd.append(CH341.i2cIn | 1)
        cmd.append(CH341.i2cStop)
        cmd.append(CH341.i2cEnd)

        _ = try bulkWrite(cmd)
        let response = try bulkRead(2)
        guard response.count >= 2 else { throw CH341Error.transferFailed(-1) }
        return response[1]
    }

    // MARK: - SPI EEPROM identification tables

    private func spiEEPROMCapacity(mfr: UInt8, devID: UInt8) -> Int {
        // Microchip 25AA/25LC series device IDs
        switch (mfr, devID) {
        case (0x29, 0x11): return 128      // 25AA010A
        case (0x29, 0x12): return 256      // 25AA020A
        case (0x29, 0x13): return 512      // 25AA040A
        case (0x29, 0x14): return 1024     // 25AA080A/B/C/D
        case (0x29, 0x15): return 2048     // 25AA160A/B/C/D
        case (0x29, 0x16): return 4096     // 25AA320A
        case (0x29, 0x17): return 8192     // 25AA640A
        case (0x29, 0x18): return 16384    // 25AA128
        case (0x29, 0x19): return 32768    // 25AA256
        case (0x29, 0x1A): return 65536    // 25AA512
        case (0x29, 0x1B): return 131072   // 25AA1024
        default:
            // Generic capacity from device ID pattern
            if devID >= 0x10 && devID <= 0x1F {
                return 1 << Int(devID - 0x10 + 7)
            }
            return 256  // Default
        }
    }

    private func spiEEPROMName(mfr: UInt8, devID: UInt8) -> String? {
        switch (mfr, devID) {
        case (0x29, 0x11): return "25AA010A"
        case (0x29, 0x12): return "25AA020A"
        case (0x29, 0x13): return "25AA040A"
        case (0x29, 0x14): return "25AA080"
        case (0x29, 0x15): return "25AA160"
        case (0x29, 0x16): return "25AA320A"
        case (0x29, 0x17): return "25AA640A"
        case (0x29, 0x18): return "25AA128"
        case (0x29, 0x19): return "25AA256"
        case (0x29, 0x1A): return "25AA512"
        case (0x29, 0x1B): return "25AA1024"
        default: return nil
        }
    }

    private func spiLegacyCapacity(devID: UInt8) -> Int {
        // Legacy single-byte device IDs
        switch devID {
        case 0x10: return 65536     // Various 512Kbit parts
        case 0x11: return 131072    // Various 1Mbit parts
        case 0x12: return 262144    // 2Mbit
        case 0x13: return 524288    // 4Mbit
        case 0x14: return 1048576   // 8Mbit
        case 0x15: return 2097152   // 16Mbit
        case 0x16: return 4194304   // 32Mbit
        case 0x17: return 8388608   // 64Mbit
        default: return 0
        }
    }

    private func i2cEEPROMName(capacity: Int) -> String? {
        switch capacity {
        case 128:   return "24C01"
        case 256:   return "24C02"
        case 512:   return "24C04"
        case 1024:  return "24C08"
        case 2048:  return "24C16"
        case 4096:  return "24C32"
        case 8192:  return "24C64"
        case 16384: return "24C128"
        case 32768: return "24C256"
        case 65536: return "24C512"
        default: return nil
        }
    }
}
