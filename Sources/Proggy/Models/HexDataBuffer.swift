import Foundation
import CryptoKit

@Observable
final class HexDataBuffer {
    private(set) var data: Data
    private(set) var isDirty: Bool = false

    var count: Int { data.count }
    var isEmpty: Bool { data.isEmpty }

    // Undo/redo
    private var undoStack: [(offset: Int, oldByte: UInt8, newByte: UInt8)] = []
    private var redoStack: [(offset: Int, oldByte: UInt8, newByte: UInt8)] = []
    var canUndo: Bool { !undoStack.isEmpty }
    var canRedo: Bool { !redoStack.isEmpty }

    init(data: Data = Data()) {
        self.data = data
    }

    // MARK: - Access

    subscript(offset: Int) -> UInt8 {
        get { data[offset] }
        set {
            let old = data[offset]
            guard newValue != old else { return }
            undoStack.append((offset: offset, oldByte: old, newByte: newValue))
            redoStack.removeAll()
            data[offset] = newValue
            isDirty = true
        }
    }

    func bytes(at offset: Int, count: Int) -> [UInt8] {
        let end = min(offset + count, data.count)
        guard offset < end else { return [] }
        return Array(data[offset..<end])
    }

    // MARK: - Undo / Redo

    func undo() {
        guard let entry = undoStack.popLast() else { return }
        data[entry.offset] = entry.oldByte
        redoStack.append(entry)
        isDirty = true
    }

    func redo() {
        guard let entry = redoStack.popLast() else { return }
        data[entry.offset] = entry.newByte
        undoStack.append(entry)
        isDirty = true
    }

    // MARK: - Modification

    func load(_ newData: Data) {
        data = newData
        isDirty = false
        undoStack.removeAll()
        redoStack.removeAll()
    }

    func fill(_ value: UInt8 = 0xFF) {
        data = Data(repeating: value, count: data.count)
        isDirty = true
        undoStack.removeAll()
        redoStack.removeAll()
    }

    func resize(_ newSize: Int, fill: UInt8 = 0xFF) {
        if newSize > data.count {
            data.append(Data(repeating: fill, count: newSize - data.count))
        } else {
            data = data.prefix(newSize)
        }
        isDirty = true
    }

    func markClean() {
        isDirty = false
    }

    // MARK: - File I/O

    func loadFromFile(_ url: URL) throws {
        data = try Data(contentsOf: url)
        isDirty = false
        undoStack.removeAll()
        redoStack.removeAll()
    }

    func saveToFile(_ url: URL) throws {
        try data.write(to: url)
    }

    // MARK: - Checksums

    var crc32: UInt32 {
        var crc: UInt32 = 0xFFFFFFFF
        for byte in data {
            crc ^= UInt32(byte)
            for _ in 0..<8 {
                crc = (crc >> 1) ^ (crc & 1 != 0 ? 0xEDB88320 : 0)
            }
        }
        return ~crc
    }

    var sha256: String {
        guard !data.isEmpty else { return "" }
        let digest = SHA256.hash(data: data)
        return digest.map { String(format: "%02x", $0) }.joined()
    }

    var md5: String {
        guard !data.isEmpty else { return "" }
        let digest = Insecure.MD5.hash(data: data)
        return digest.map { String(format: "%02x", $0) }.joined()
    }
}
