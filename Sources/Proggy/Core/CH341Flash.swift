import Foundation

// MARK: - Flash Operations

extension CH341Device {

    /// Read the JEDEC ID from the SPI flash chip.
    /// Retries with speed fallback if first attempt fails.
    /// Returns debug info via the debugLog closure for troubleshooting.
    /// Low-level SPI diagnostic using both old spiStream and new spiCommand.
    func spiDiagnostic(debugLog: ((String) -> Void)? = nil) throws {
        debugLog?("=== SPI DIAGNOSTIC ===")

        // Test 1: JEDEC via new spiCommand (send 1 byte cmd, read 3 bytes)
        debugLog?("Test 1: JEDEC via spiCommand(write:[9F], read:3)")
        do {
            let t0 = Date()
            let resp = try spiCommand(write: [0x9F], readCount: 3)
            let ms = Date().timeIntervalSince(t0) * 1000
            let hex = resp.map { String(format: "%02X", $0) }.joined(separator: " ")
            debugLog?("  Response: [\(hex)] (\(String(format: "%.1f", ms))ms)")
        } catch { debugLog?("  Error: \(error)") }

        // Test 2: Status register via spiCommand
        debugLog?("Test 2: Status via spiCommand(write:[05], read:1)")
        do {
            let resp = try spiCommand(write: [0x05], readCount: 1)
            let hex = resp.map { String(format: "%02X", $0) }.joined(separator: " ")
            debugLog?("  Response: [\(hex)]")
        } catch { debugLog?("  Error: \(error)") }

        // Test 3: Flash read via spiCommand (4 write + 8 read)
        debugLog?("Test 3: Read @0x0000 via spiCommand(write:[03,00,00,00], read:8)")
        do {
            let resp = try spiCommand(write: [0x03, 0x00, 0x00, 0x00], readCount: 8)
            let hex = resp.map { String(format: "%02X", $0) }.joined(separator: " ")
            debugLog?("  Data: [\(hex)]")
        } catch { debugLog?("  Error: \(error)") }

        // Test 4: JEDEC via legacy spiStream for comparison
        debugLog?("Test 4: JEDEC via legacy spiStream([9F,00,00,00], len:4)")
        do {
            let resp = try spiStream([0x9F, 0, 0, 0], length: 4)
            let hex = resp.map { String(format: "%02X", $0) }.joined(separator: " ")
            debugLog?("  Response: [\(hex)]")
        } catch { debugLog?("  Error: \(error)") }

        // Test 5: REMS (0x90) via spiCommand
        debugLog?("Test 5: REMS via spiCommand(write:[90,00,00,00], read:2)")
        do {
            let resp = try spiCommand(write: [0x90, 0x00, 0x00, 0x00], readCount: 2)
            let hex = resp.map { String(format: "%02X", $0) }.joined(separator: " ")
            debugLog?("  Response: [\(hex)]")
        } catch { debugLog?("  Error: \(error)") }

        // Test 6: RDID (0xAB) via spiCommand
        debugLog?("Test 6: RDID via spiCommand(write:[AB,00,00,00], read:1)")
        do {
            let resp = try spiCommand(write: [0xAB, 0x00, 0x00, 0x00], readCount: 1)
            let hex = resp.map { String(format: "%02X", $0) }.joined(separator: " ")
            debugLog?("  Response: [\(hex)]")
        } catch { debugLog?("  Error: \(error)") }

        // Test 7: EXACT readFlash replica — 260-byte spiStream (4 cmd + 256 dummy)
        debugLog?("Test 7: Flash read EXACT replica (260B spiStream like readFlash)")
        do {
            var cmd = [UInt8](repeating: 0, count: 260)
            cmd[0] = 0x03  // Read Data
            // addr = 0x000000 (already zeros)
            let resp = try spiStream(cmd, length: 260)
            let firstData = resp.count > 4 ? resp[4..<min(12, resp.count)].map { String(format: "%02X", $0) }.joined(separator: " ") : "N/A"
            let allFF = resp.dropFirst(4).prefix(8).allSatisfy { $0 == 0xFF }
            debugLog?("  Response: \(resp.count)B, data@4: [\(firstData)] allFF=\(allFF)")
        } catch { debugLog?("  Error: \(error)") }

        debugLog?("=== END DIAGNOSTIC ===")
    }

    func readJEDECID(debugLog: ((String) -> Void)? = nil) throws -> JEDECInfo {
        // Warmup: toggle CS a few times to sync the SPI bus
        for _ in 0..<3 {
            try? spiChipSelect(true)
            usleep(1000)
            try? spiChipSelect(false)
            usleep(1000)
        }
        flushRead()

        for attempt in 0..<3 {
            flushRead()
            if attempt > 0 {
                Thread.sleep(forTimeInterval: 0.1)
                try? setStream(speed: .i2c20k)
            }

            var cmd = [UInt8](repeating: 0, count: 4)
            cmd[0] = CH341.spiReadJEDEC  // 0x9F

            do {
                let response = try spiStream(cmd, length: 4)
                let hex = response.map { String(format: "%02X", $0) }.joined(separator: " ")
                debugLog?("JEDEC attempt \(attempt): sent 9F 00 00 00, got [\(hex)] (\(response.count) bytes)")

                guard response.count >= 4 else {
                    debugLog?("  Too few bytes")
                    continue
                }

                let mfr = response[1]
                let memType = (UInt16(response[2]) << 8) | UInt16(response[3])
                let capBits = response[3]

                if mfr == 0xFF || mfr == 0x00 {
                    debugLog?("  Invalid manufacturer: 0x\(String(format: "%02X", mfr))")
                    continue
                }

                debugLog?("  Manufacturer: 0x\(String(format: "%02X", mfr)), Type: 0x\(String(format: "%04X", memType))")
                return JEDECInfo(manufacturerID: mfr, memoryType: memType, capacityBits: capBits)
            } catch {
                debugLog?("  SPI error: \(error.localizedDescription)")
                if attempt == 2 { throw error }
            }
        }
        throw CH341Error.chipNotDetected
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

    /// Erase the entire chip. Tries both 0xC7 and 0x60 erase commands.
    func chipErase(timeout: TimeInterval = 120,
                   progress: ((Double) -> Void)? = nil,
                   debugLog: ((String) -> Void)? = nil,
                   cancelled: (() -> Bool)? = nil) throws {
        flushRead()

        // Read status register before erase
        let preStatus = try? readStatus()
        debugLog?("Pre-erase status: 0x\(String(format: "%02X", preStatus ?? 0xFF))")

        // Unprotect: clear block protection bits
        _ = try spiStream([CH341.spiWriteEnable], length: 1)
        _ = try spiStream([CH341.spiWriteStatus, 0x00], length: 2)
        Thread.sleep(forTimeInterval: 0.05)

        // Check WEL bit after WREN
        _ = try spiStream([CH341.spiWriteEnable], length: 1)
        let welStatus = try? readStatus()
        debugLog?("After WREN status: 0x\(String(format: "%02X", welStatus ?? 0xFF)) (WEL=\((welStatus ?? 0) & 0x02 != 0 ? "SET" : "NOT SET"))")

        // Send chip erase — try 0xC7 first, then 0x60 if that doesn't start
        _ = try spiStream([CH341.spiChipErase], length: 1)
        Thread.sleep(forTimeInterval: 0.1)

        // Check if erase started (WIP should be set)
        let wipCheck = try? readStatus()
        debugLog?("After 0xC7 status: 0x\(String(format: "%02X", wipCheck ?? 0xFF)) (WIP=\((wipCheck ?? 0) & 0x01 != 0 ? "SET" : "NOT SET"))")

        if wipCheck == nil || wipCheck == 0xFF || (wipCheck! & 0x01 == 0) {
            // 0xC7 didn't start erase — try alternate command 0x60
            debugLog?("0xC7 didn't start erase, trying 0x60...")
            _ = try spiStream([CH341.spiWriteEnable], length: 1)
            _ = try spiStream([CH341.spiChipEraseAlt], length: 1)
            Thread.sleep(forTimeInterval: 0.1)
            let wipCheck2 = try? readStatus()
            debugLog?("After 0x60 status: 0x\(String(format: "%02X", wipCheck2 ?? 0xFF))")
        }

        // Poll status register
        let startTime = Date()
        for tick in 0..<Int(timeout) {
            if cancelled?() == true { throw CH341Error.cancelled }
            Thread.sleep(forTimeInterval: 1.0)

            let elapsed = Double(tick + 1)
            progress?(min(elapsed / 90.0, 0.95))

            let status: Int
            do {
                let cmd: [UInt8] = [CH341.spiReadStatus, 0x00]
                let resp = try spiStream(cmd, length: 2)
                status = resp.count >= 2 ? Int(resp[1]) : -1
                if tick < 3 || tick % 10 == 0 {
                    debugLog?("Erase poll \(tick+1)s: status=0x\(String(format: "%02X", status))")
                }
            } catch {
                debugLog?("Erase poll \(tick+1)s: read error")
                continue
            }

            if status == 0 {
                progress?(1.0)
                debugLog?("Erase complete after \(tick+1)s")
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
        flushRead()
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
        flushRead()
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
