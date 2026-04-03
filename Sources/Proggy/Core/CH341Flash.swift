import Foundation

// MARK: - Flash Operations

extension CH341Device {

    /// Read the JEDEC ID from the SPI flash chip.
    func readJEDECID() throws -> JEDECInfo {
        var cmd = [UInt8](repeating: 0, count: 4)
        cmd[0] = CH341.spiReadJEDEC

        let response = try spiStream(cmd, length: 4)

        guard response.count >= 4 else { throw CH341Error.chipNotDetected }

        let mfr = response[1]
        let memType = (UInt16(response[2]) << 8) | UInt16(response[3])
        let capBits = response[3]

        guard mfr != 0xFF && mfr != 0x00 else { throw CH341Error.chipNotDetected }

        return JEDECInfo(manufacturerID: mfr, memoryType: memType, capacityBits: capBits)
    }

    /// Read the flash status register.
    func readStatus() throws -> UInt8 {
        let cmd: [UInt8] = [CH341.spiReadStatus, 0x00]
        let response = try spiStream(cmd, length: 2)
        guard response.count >= 2 else { throw CH341Error.transferFailed(-1) }
        return response[1]
    }

    /// Send Write Enable command.
    func writeEnable() throws {
        _ = try spiStream([CH341.spiWriteEnable], length: 1)
    }

    /// Send Write Disable command.
    func writeDisable() throws {
        _ = try spiStream([CH341.spiWriteDisable], length: 1)
    }

    /// Write the status register (used to unprotect chip).
    func writeStatus(_ status: UInt8) throws {
        try writeEnable()
        _ = try spiStream([CH341.spiWriteStatus, status], length: 2)
        try writeDisable()
    }

    /// Erase the entire chip. Blocks until erase completes or timeout.
    func chipErase(timeout: TimeInterval = 120, cancelled: (() -> Bool)? = nil) throws {
        try writeEnable()
        _ = try spiStream([CH341.spiChipErase], length: 1)
        try writeDisable()

        // Poll status register until WIP clears
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if cancelled?() == true { throw CH341Error.cancelled }
            Thread.sleep(forTimeInterval: 0.5)
            let status = try readStatus()
            if status & CH341.statusWIP == 0 {
                return
            }
        }
        throw CH341Error.eraseFailed
    }

    /// Erase a 4KB sector at the given address.
    func sectorErase(address: UInt32, timeout: TimeInterval = 5) throws {
        let use4B = address > 0xFFFFFF
        try writeEnable()

        var cmd: [UInt8] = [CH341.spiSectorErase]
        if use4B {
            cmd.append(UInt8((address >> 24) & 0xFF))
        }
        cmd.append(UInt8((address >> 16) & 0xFF))
        cmd.append(UInt8((address >> 8) & 0xFF))
        cmd.append(UInt8(address & 0xFF))

        _ = try spiStream(cmd, length: cmd.count)
        try writeDisable()

        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            Thread.sleep(forTimeInterval: 0.05)
            let status = try readStatus()
            if status & CH341.statusWIP == 0 { return }
        }
        throw CH341Error.eraseFailed
    }

    /// Read flash memory into a Data buffer.
    func readFlash(address: UInt32, length: Int,
                   progress: ((Double) -> Void)? = nil,
                   cancelled: (() -> Bool)? = nil) throws -> Data {
        let use4B = (address + UInt32(length)) > 0xFFFFFF
        let chunkSize = 256  // Read 256 bytes at a time for reliability

        var result = Data(capacity: length)
        var currentAddr = address
        var remaining = length

        while remaining > 0 {
            if cancelled?() == true { throw CH341Error.cancelled }

            let toRead = min(remaining, chunkSize)
            let readCmd = use4B ? CH341.spiReadData4B : CH341.spiReadData3B

            var cmd = [UInt8]()
            cmd.append(readCmd)
            if use4B {
                cmd.append(UInt8((currentAddr >> 24) & 0xFF))
            }
            cmd.append(UInt8((currentAddr >> 16) & 0xFF))
            cmd.append(UInt8((currentAddr >> 8) & 0xFF))
            cmd.append(UInt8(currentAddr & 0xFF))

            // Pad with dummy bytes for the data we want to read
            cmd.append(contentsOf: [UInt8](repeating: 0, count: toRead))

            let response = try spiStream(cmd, length: cmd.count)

            // Skip the command/address bytes in response
            let headerLen = use4B ? 5 : 4
            if response.count > headerLen {
                let dataSlice = Array(response[headerLen...])
                result.append(contentsOf: dataSlice.prefix(toRead))
            }

            currentAddr += UInt32(toRead)
            remaining -= toRead

            let pct = Double(length - remaining) / Double(length)
            progress?(pct)
        }

        return result
    }

    /// Write data to flash memory (page programming).
    func writeFlash(address: UInt32, data: Data,
                    progress: ((Double) -> Void)? = nil,
                    cancelled: (() -> Bool)? = nil) throws {
        let use4B = (address + UInt32(data.count)) > 0xFFFFFF
        let pageSize = CH341.spiPageSize

        var currentAddr = address
        var offset = 0
        let totalBytes = data.count

        while offset < totalBytes {
            if cancelled?() == true { throw CH341Error.cancelled }

            // Calculate bytes to write in this page
            let pageOffset = Int(currentAddr) % pageSize
            let bytesInPage = min(pageSize - pageOffset, totalBytes - offset)

            try writeEnable()

            let writeCmd = use4B ? CH341.spiPageProgram4B : CH341.spiPageProgram3B
            var cmd = [UInt8]()
            cmd.append(writeCmd)
            if use4B {
                cmd.append(UInt8((currentAddr >> 24) & 0xFF))
            }
            cmd.append(UInt8((currentAddr >> 16) & 0xFF))
            cmd.append(UInt8((currentAddr >> 8) & 0xFF))
            cmd.append(UInt8(currentAddr & 0xFF))

            // Append page data
            let pageData = data[offset..<(offset + bytesInPage)]
            cmd.append(contentsOf: pageData)

            _ = try spiStream(cmd, length: cmd.count)

            // Wait for write to complete
            for _ in 0..<100 {
                Thread.sleep(forTimeInterval: 0.001)
                let status = try readStatus()
                if status & CH341.statusWIP == 0 { break }
            }

            currentAddr += UInt32(bytesInPage)
            offset += bytesInPage

            let pct = Double(offset) / Double(totalBytes)
            progress?(pct)
        }
    }

    /// Verify flash contents against a data buffer.
    func verifyFlash(address: UInt32, data: Data,
                     progress: ((Double) -> Void)? = nil,
                     cancelled: (() -> Bool)? = nil) throws {
        let readData = try readFlash(address: address, length: data.count,
                                     progress: progress, cancelled: cancelled)

        guard readData.count == data.count else {
            throw CH341Error.verifyFailed(address: address)
        }

        for i in 0..<data.count {
            if readData[i] != data[i] {
                throw CH341Error.verifyFailed(address: address + UInt32(i))
            }
        }
    }

    /// Check if flash is blank (all 0xFF).
    func blankCheck(address: UInt32, length: Int,
                    progress: ((Double) -> Void)? = nil,
                    cancelled: (() -> Bool)? = nil) throws -> Bool {
        let data = try readFlash(address: address, length: length,
                                 progress: progress, cancelled: cancelled)
        return data.allSatisfy { $0 == 0xFF }
    }
}
