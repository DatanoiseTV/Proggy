import Foundation

// MARK: - SPI Operations

extension CH341Device {

    /// Assert or deassert the SPI chip select line
    func spiChipSelect(_ assert: Bool) throws {
        _ = try bulkWrite(assert ? CH341.csAssert : CH341.csDeassert)
    }

    /// Transfer bytes over SPI (simultaneous write/read). Returns received bytes.
    /// All data is automatically bit-reversed per CH341A protocol.
    func spiStream(_ out: [UInt8], length: Int) throws -> [UInt8] {
        guard length > 0 else { return [] }

        let packetPayload = CH341.packetLength - 1  // 31 bytes per packet (1 byte command header)

        try spiChipSelect(true)
        defer { try? spiChipSelect(false) }

        var result = [UInt8]()
        var offset = 0
        var remaining = length

        while remaining > 0 {
            let chunkSize = min(remaining, packetPayload)

            // Build packet: command header + bit-reversed data
            var packet = [UInt8](repeating: 0, count: chunkSize + 1)
            packet[0] = CH341.cmdSPIStream
            for i in 0..<chunkSize {
                let srcByte = offset + i < out.count ? out[offset + i] : 0
                packet[i + 1] = swapByte[Int(srcByte)]
            }

            _ = try bulkWrite(packet)
            let response = try bulkRead(chunkSize)

            // Bit-reverse the response
            for byte in response {
                result.append(swapByte[Int(byte)])
            }

            offset += chunkSize
            remaining -= chunkSize
        }

        return result
    }

    /// Transfer raw SPI data without automatic chip select management.
    /// Caller is responsible for CS assertion.
    func spiTransferRaw(_ data: [UInt8]) throws -> [UInt8] {
        let packetPayload = CH341.packetLength - 1
        var result = [UInt8]()
        var offset = 0

        while offset < data.count {
            let chunkSize = min(data.count - offset, packetPayload)
            var packet = [UInt8](repeating: 0, count: chunkSize + 1)
            packet[0] = CH341.cmdSPIStream
            for i in 0..<chunkSize {
                packet[i + 1] = swapByte[Int(data[offset + i])]
            }

            _ = try bulkWrite(packet)
            let response = try bulkRead(chunkSize)
            for byte in response {
                result.append(swapByte[Int(byte)])
            }
            offset += chunkSize
        }

        return result
    }

    /// Perform a raw SPI transfer with manual CS control (for SPI terminal use).
    /// Data is sent as-is with bit reversal. Returns response.
    func spiExchange(data: [UInt8], keepCSLow: Bool = false) throws -> [UInt8] {
        try spiChipSelect(true)
        let result = try spiTransferRaw(data)
        if !keepCSLow {
            try spiChipSelect(false)
        }
        return result
    }
}
