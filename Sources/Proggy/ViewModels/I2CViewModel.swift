import Foundation
import SwiftUI

@Observable
@MainActor
final class I2CViewModel {
    var targetAddress: String = "50"
    var registerAddress: String = ""
    var writeDataHex: String = ""
    var readLength: String = "1"
    var speed: CH341Speed = .i2c100k

    var history: [I2CTransaction] = []
    var scanResults: [UInt8] = []
    var isScanning: Bool = false
    var isBusy: Bool = false

    struct I2CTransaction: Identifiable {
        let id = UUID()
        let timestamp = Date()
        let address: UInt8
        let operation: String  // "W", "R", "WR"
        let sent: [UInt8]
        let received: [UInt8]

        var sentHex: String { sent.map { String(format: "%02X", $0) }.joined(separator: " ") }
        var receivedHex: String { received.map { String(format: "%02X", $0) }.joined(separator: " ") }

        var timestampString: String {
            let fmt = DateFormatter()
            fmt.dateFormat = "HH:mm:ss.SSS"
            return fmt.string(from: timestamp)
        }
    }

    // MARK: - I2C Operations

    func write(device: CH341Device, manager: DeviceManager) {
        guard let addr = UInt8(targetAddress, radix: 16), !isBusy else { return }
        let bytes = parseHex(writeDataHex)
        guard !bytes.isEmpty else { return }

        isBusy = true
        Task {
            do {
                try await device.perform { dev in
                    try dev.setStream(speed: self.speed)
                    try dev.i2cWrite(address: addr, data: bytes)
                }
                let txn = I2CTransaction(address: addr, operation: "W", sent: bytes, received: [])
                history.insert(txn, at: 0)
                manager.log(.info, "I2C Write [0x\(String(format: "%02X", addr))]: \(txn.sentHex)")
            } catch {
                manager.log(.error, "I2C write failed: \(error.localizedDescription)")
            }
            isBusy = false
        }
    }

    func read(device: CH341Device, manager: DeviceManager) {
        guard let addr = UInt8(targetAddress, radix: 16), !isBusy else { return }
        guard let len = Int(readLength), len > 0 else { return }

        isBusy = true
        Task {
            do {
                let response: [UInt8]
                let regData = parseHex(registerAddress)

                if !regData.isEmpty {
                    // Write-then-read (register access)
                    response = try await device.perform { dev in
                        try dev.setStream(speed: self.speed)
                        return try dev.i2cWriteRead(address: addr, writeData: regData, readLength: len)
                    }
                    let txn = I2CTransaction(address: addr, operation: "WR", sent: regData, received: response)
                    history.insert(txn, at: 0)
                    manager.log(.info, "I2C WriteRead [0x\(String(format: "%02X", addr))] reg \(txn.sentHex) → \(txn.receivedHex)")
                } else {
                    // Plain read
                    response = try await device.perform { dev in
                        try dev.setStream(speed: self.speed)
                        return try dev.i2cRead(address: addr, length: len)
                    }
                    let txn = I2CTransaction(address: addr, operation: "R", sent: [], received: response)
                    history.insert(txn, at: 0)
                    manager.log(.info, "I2C Read [0x\(String(format: "%02X", addr))]: \(txn.receivedHex)")
                }
            } catch {
                manager.log(.error, "I2C read failed: \(error.localizedDescription)")
            }
            isBusy = false
        }
    }

    func scan(device: CH341Device, manager: DeviceManager) {
        guard !isScanning else { return }
        isScanning = true
        scanResults = []
        manager.log(.info, "I2C bus scan started...")

        Task {
            do {
                let found = try await device.perform { dev in
                    try dev.setStream(speed: self.speed)
                    return try dev.i2cScan()
                }
                scanResults = found
                if found.isEmpty {
                    manager.log(.info, "I2C scan: no devices found")
                } else {
                    let addrs = found.map { String(format: "0x%02X", $0) }.joined(separator: ", ")
                    manager.log(.info, "I2C scan found \(found.count) device(s): \(addrs)")
                }
            } catch {
                manager.log(.error, "I2C scan failed: \(error.localizedDescription)")
            }
            isScanning = false
        }
    }

    func clearHistory() {
        history.removeAll()
    }

    private func parseHex(_ string: String) -> [UInt8] {
        let cleaned = string.replacingOccurrences(of: "[^0-9A-Fa-f]", with: "", options: .regularExpression)
        var bytes = [UInt8]()
        var i = cleaned.startIndex
        while i < cleaned.endIndex {
            let next = cleaned.index(i, offsetBy: 2, limitedBy: cleaned.endIndex) ?? cleaned.endIndex
            if let byte = UInt8(cleaned[i..<next], radix: 16) {
                bytes.append(byte)
            }
            i = next
        }
        return bytes
    }
}
