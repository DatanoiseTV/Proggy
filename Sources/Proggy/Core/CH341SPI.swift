import Foundation

// MARK: - SPI Operations (matching IMSProg/ch341a implementation)

extension CH341Device {

    /// Enable SPI pins — matches IMSProg's enable_pins().
    /// Sends 5x CS-high (debounce), then CS-low, direction set, end.
    func spiEnablePins() throws {
        let cmd: [UInt8] = [
            CH341.cmdUIOStream,
            CH341.uioOut | 0x37,   // CS HIGH (debounce 1)
            CH341.uioOut | 0x37,   // CS HIGH (debounce 2)
            CH341.uioOut | 0x37,   // CS HIGH (debounce 3)
            CH341.uioOut | 0x37,   // CS HIGH (debounce 4)
            CH341.uioOut | 0x37,   // CS HIGH (debounce 5)
            CH341.uioOut | 0x36,   // CS LOW (assert)
            CH341.uioDir | 0x3F,   // Pin direction: outputs
            CH341.uioEnd,
        ]
        _ = try bulkWrite(cmd)
    }

    /// Disable SPI pins (CS high)
    func spiDisablePins() throws {
        let cmd: [UInt8] = [
            CH341.cmdUIOStream,
            CH341.uioOut | 0x37,   // CS HIGH
            CH341.uioDir | 0x3F,   // Keep direction
            CH341.uioEnd,
        ]
        _ = try bulkWrite(cmd)
    }

    /// Assert or deassert the SPI chip select line
    func spiChipSelect(_ assert: Bool) throws {
        if assert {
            try spiEnablePins()
        } else {
            try spiDisablePins()
        }
    }

    /// SPI command: send `writecnt` bytes, then read `readcnt` bytes.
    /// Matches IMSProg's ch341a_spi_send_command() — builds unified packet buffer.
    func spiCommand(write writeData: [UInt8], readCount: Int) throws -> [UInt8] {
        let writecnt = writeData.count
        let readcnt = readCount
        let total = writecnt + readcnt
        let packetPayload = CH341.packetLength - 1  // 31

        // Calculate number of SPI packets needed
        let packets = max(1, (total + packetPayload - 1) / packetPayload)

        // Build unified write buffer: all packets concatenated
        var wbuf = [UInt8]()

        var byteIdx = 0
        for _ in 0..<packets {
            // Always full 32-byte packet: [A8] + 31 data/dummy bytes
            wbuf.append(CH341.cmdSPIStream)
            for _ in 0..<packetPayload {
                if byteIdx < writecnt {
                    wbuf.append(swapByte[Int(writeData[byteIdx])])
                } else if byteIdx < total {
                    wbuf.append(0xFF)  // Read phase dummy
                } else {
                    wbuf.append(0xFF)  // Padding dummy
                }
                byteIdx += 1
            }
        }

        // Assert CS
        try spiEnablePins()

        // Send ALL SPI packets in one bulk write
        let written = try bulkWrite(wbuf)

        // Read response — one packet per SPI packet sent
        var rbuf = [UInt8]()
        for _ in 0..<packets {
            let resp = try bulkRead(CH341.packetLength)
            rbuf.append(contentsOf: resp)
        }

        // Deassert CS
        try spiDisablePins()

        // Debug: log raw USB traffic
        if let log = spiDebugLog {
            let txHex = wbuf.prefix(16).map { String(format: "%02X", $0) }.joined(separator: " ")
            let rxHex = rbuf.prefix(16).map { String(format: "%02X", $0) }.joined(separator: " ")
            log("spiCommand: TX[\(written)B]: \(txHex)...  RX[\(rbuf.count)B]: \(rxHex)...")
        }

        // Extract read data: starts after writecnt bytes in the response
        // Response bytes are bit-swapped
        var result = [UInt8]()
        for i in 0..<readcnt {
            let idx = writecnt + i
            if idx < rbuf.count {
                result.append(swapByte[Int(rbuf[idx])])
            } else {
                result.append(0xFF)
            }
        }

        return result
    }

    /// SPI stream — always sends FULL 32-byte packets (A8 + 31 data).
    /// CH341A on macOS requires complete packet-aligned bulk writes.
    /// Unused bytes are 0xFF (SPI idle/dummy).
    func spiStream(_ out: [UInt8], length: Int) throws -> [UInt8] {
        guard length > 0 else { return [] }

        let packetPayload = CH341.packetLength - 1  // 31

        try spiEnablePins()
        defer { try? spiDisablePins() }

        var result = [UInt8]()
        var offset = 0
        var remaining = length

        while remaining > 0 {
            let chunkSize = min(remaining, packetPayload)

            // ALWAYS 32 bytes: [A8] [data...] [FF padding to 31 total]
            var packet = [UInt8](repeating: 0xFF, count: CH341.packetLength)
            packet[0] = CH341.cmdSPIStream
            for i in 0..<chunkSize {
                let srcByte = offset + i < out.count ? out[offset + i] : 0xFF
                packet[i + 1] = swapByte[Int(srcByte)]
            }

            _ = try bulkWrite(packet)
            let response = try bulkRead(CH341.packetLength)

            // Take exactly chunkSize bytes from response
            let responseBytes = min(chunkSize, response.count)
            for i in 0..<responseBytes {
                result.append(swapByte[Int(response[i])])
            }

            offset += chunkSize
            remaining -= chunkSize
        }

        return result
    }

    /// Transfer raw SPI data without automatic chip select management.
    func spiTransferRaw(_ data: [UInt8]) throws -> [UInt8] {
        let packetPayload = CH341.packetLength - 1
        var result = [UInt8]()
        var offset = 0

        while offset < data.count {
            let chunkSize = min(data.count - offset, packetPayload)
            // Full 32-byte packet with 0xFF padding
            var packet = [UInt8](repeating: 0xFF, count: CH341.packetLength)
            packet[0] = CH341.cmdSPIStream
            for i in 0..<chunkSize {
                packet[i + 1] = swapByte[Int(data[offset + i])]
            }

            _ = try bulkWrite(packet)
            let response = try bulkRead(CH341.packetLength)

            let responseBytes = min(chunkSize, response.count)
            for i in 0..<responseBytes {
                result.append(swapByte[Int(response[i])])
            }
            offset += chunkSize
        }

        return result
    }

    /// Perform a raw SPI transfer with manual CS control (for SPI terminal use).
    func spiExchange(data: [UInt8], keepCSLow: Bool = false) throws -> [UInt8] {
        try spiEnablePins()
        let result = try spiTransferRaw(data)
        if !keepCSLow {
            try spiDisablePins()
        }
        return result
    }
}
