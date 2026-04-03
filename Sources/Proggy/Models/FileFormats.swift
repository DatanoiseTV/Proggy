import Foundation

// MARK: - Intel HEX (.hex, .ihex)

enum IntelHex {

    enum RecordType: UInt8 {
        case data = 0x00
        case eof = 0x01
        case extendedSegmentAddress = 0x02
        case startSegmentAddress = 0x03
        case extendedLinearAddress = 0x04
        case startLinearAddress = 0x05
    }

    enum ParseError: LocalizedError {
        case invalidFormat(line: Int)
        case checksumMismatch(line: Int)
        case unsupportedRecord(UInt8, line: Int)

        var errorDescription: String? {
            switch self {
            case .invalidFormat(let line): return "Invalid IHEX format at line \(line)"
            case .checksumMismatch(let line): return "Checksum mismatch at line \(line)"
            case .unsupportedRecord(let type, let line): return "Unsupported record type 0x\(String(format: "%02X", type)) at line \(line)"
            }
        }
    }

    /// Parse an Intel HEX string into binary Data, padded with 0xFF to fill gaps.
    static func parse(_ string: String) throws -> Data {
        var segments: [(address: UInt32, data: [UInt8])] = []
        var baseAddress: UInt32 = 0
        var minAddr: UInt32 = .max
        var maxAddr: UInt32 = 0

        for (lineNum, line) in string.components(separatedBy: .newlines).enumerated() {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.isEmpty { continue }
            guard trimmed.hasPrefix(":") else { throw ParseError.invalidFormat(line: lineNum + 1) }

            let hex = String(trimmed.dropFirst())
            let bytes = hexToBytes(hex)
            guard bytes.count >= 5 else { throw ParseError.invalidFormat(line: lineNum + 1) }

            // Verify checksum
            let checksum = bytes.reduce(0 as UInt8) { $0 &+ $1 }
            guard checksum == 0 else { throw ParseError.checksumMismatch(line: lineNum + 1) }

            let byteCount = Int(bytes[0])
            let address = (UInt16(bytes[1]) << 8) | UInt16(bytes[2])
            let recordType = bytes[3]
            let data = Array(bytes[4..<(4 + byteCount)])

            switch recordType {
            case RecordType.data.rawValue:
                let fullAddr = baseAddress + UInt32(address)
                segments.append((address: fullAddr, data: data))
                minAddr = min(minAddr, fullAddr)
                maxAddr = max(maxAddr, fullAddr + UInt32(data.count))

            case RecordType.eof.rawValue:
                break

            case RecordType.extendedSegmentAddress.rawValue:
                guard data.count == 2 else { throw ParseError.invalidFormat(line: lineNum + 1) }
                baseAddress = UInt32((UInt16(data[0]) << 8) | UInt16(data[1])) << 4

            case RecordType.extendedLinearAddress.rawValue:
                guard data.count == 2 else { throw ParseError.invalidFormat(line: lineNum + 1) }
                baseAddress = UInt32((UInt16(data[0]) << 8) | UInt16(data[1])) << 16

            case RecordType.startSegmentAddress.rawValue,
                 RecordType.startLinearAddress.rawValue:
                // Execution start address — skip, not relevant for programming
                break

            default:
                throw ParseError.unsupportedRecord(recordType, line: lineNum + 1)
            }
        }

        guard minAddr < maxAddr else { return Data() }

        // Build contiguous buffer padded with 0xFF
        let size = Int(maxAddr - minAddr)
        var result = Data(repeating: 0xFF, count: size)
        for seg in segments {
            let offset = Int(seg.address - minAddr)
            for (i, byte) in seg.data.enumerated() {
                result[offset + i] = byte
            }
        }

        return result
    }

    /// Export binary Data to Intel HEX format string.
    static func export(_ data: Data, baseAddress: UInt32 = 0) -> String {
        var lines = [String]()
        let bytesPerLine = 16

        var currentExtAddr: UInt16 = 0xFFFF // force first extended address record

        for offset in stride(from: 0, to: data.count, by: bytesPerLine) {
            let fullAddr = baseAddress + UInt32(offset)
            let extAddr = UInt16(fullAddr >> 16)

            // Emit extended linear address record if needed
            if extAddr != currentExtAddr {
                currentExtAddr = extAddr
                let rec = makeRecord(type: .extendedLinearAddress, address: 0,
                                     data: [UInt8(extAddr >> 8), UInt8(extAddr & 0xFF)])
                lines.append(rec)
            }

            let count = min(bytesPerLine, data.count - offset)
            let addr = UInt16(fullAddr & 0xFFFF)
            let chunk = Array(data[offset..<(offset + count)])
            lines.append(makeRecord(type: .data, address: addr, data: chunk))
        }

        // EOF record
        lines.append(":00000001FF")
        lines.append("")

        return lines.joined(separator: "\n")
    }

    private static func makeRecord(type: RecordType, address: UInt16, data: [UInt8]) -> String {
        var bytes = [UInt8]()
        bytes.append(UInt8(data.count))
        bytes.append(UInt8(address >> 8))
        bytes.append(UInt8(address & 0xFF))
        bytes.append(type.rawValue)
        bytes.append(contentsOf: data)

        let checksum: UInt8 = 0 &- bytes.reduce(0 as UInt8) { $0 &+ $1 }
        bytes.append(checksum)

        return ":" + bytes.map { String(format: "%02X", $0) }.joined()
    }

    private static func hexToBytes(_ hex: String) -> [UInt8] {
        var bytes = [UInt8]()
        var i = hex.startIndex
        while i < hex.endIndex {
            guard let next = hex.index(i, offsetBy: 2, limitedBy: hex.endIndex) else { break }
            if let byte = UInt8(hex[i..<next], radix: 16) {
                bytes.append(byte)
            }
            i = next
        }
        return bytes
    }
}

// MARK: - SigmaStudio .dat Files

enum SigmaStudio {

    enum ParseError: LocalizedError {
        case missingFiles
        case invalidNumBytes
        case invalidTxBuffer
        case firmwareTooLarge(firmware: Int, chip: Int)

        var errorDescription: String? {
            switch self {
            case .missingFiles: return "Both NumBytes and TxBuffer .dat files are required"
            case .invalidNumBytes: return "Invalid NumBytes .dat format"
            case .invalidTxBuffer: return "Invalid TxBuffer .dat format"
            case .firmwareTooLarge(let fw, let chip):
                return "Firmware (\(fw) bytes) exceeds chip capacity (\(chip) bytes)"
            }
        }
    }

    /// Convert SigmaStudio NumBytes + TxBuffer .dat files into binary record format.
    /// Output format per segment: [addr_hi, addr_lo, len_hi, len_lo, data...]
    static func convert(numBytesContent: String, txBufferContent: String) throws -> Data {
        // Parse NumBytes: comma or whitespace separated integers
        let sizes = numBytesContent
            .replacingOccurrences(of: "\n", with: ",")
            .replacingOccurrences(of: " ", with: "")
            .split(separator: ",")
            .compactMap { Int($0.trimmingCharacters(in: .whitespaces)) }

        guard !sizes.isEmpty else { throw ParseError.invalidNumBytes }

        // Parse TxBuffer: space/newline separated 0xNN hex tokens
        let tokens = txBufferContent
            .replacingOccurrences(of: "\n", with: " ")
            .split(separator: " ")
            .map { $0.trimmingCharacters(in: .whitespaces).trimmingCharacters(in: CharacterSet(charactersIn: ",")) }
            .filter { $0.hasPrefix("0x") || $0.hasPrefix("0X") }

        let buf = tokens.compactMap { UInt8($0.dropFirst(2), radix: 16) }
        guard !buf.isEmpty else { throw ParseError.invalidTxBuffer }

        var out = Data()
        var offset = 0

        for n in sizes {
            guard offset + n <= buf.count else { break }
            let seg = Array(buf[offset..<(offset + n)])

            // First 2 bytes = address (big-endian)
            let addr = (UInt16(seg[0]) << 8) | UInt16(seg[1])
            let data = Array(seg[2...])
            let dataLen = UInt16(data.count)

            // Record: address (2B BE) + length (2B BE) + data
            out.append(UInt8(addr >> 8))
            out.append(UInt8(addr & 0xFF))
            out.append(UInt8(dataLen >> 8))
            out.append(UInt8(dataLen & 0xFF))
            out.append(contentsOf: data)

            offset += n
        }

        return out
    }

    /// Convert and pad to chip size with 0xFF.
    static func convertPadded(numBytesContent: String, txBufferContent: String, chipSize: Int) throws -> Data {
        let firmware = try convert(numBytesContent: numBytesContent, txBufferContent: txBufferContent)

        guard firmware.count <= chipSize else {
            throw ParseError.firmwareTooLarge(firmware: firmware.count, chip: chipSize)
        }

        var padded = firmware
        let padLen = chipSize - firmware.count
        padded.append(Data(repeating: 0xFF, count: padLen))

        return padded
    }
}
