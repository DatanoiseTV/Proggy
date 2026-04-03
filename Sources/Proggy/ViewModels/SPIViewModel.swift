import Foundation
import SwiftUI

@Observable
@MainActor
final class SPIViewModel {
    var inputHex: String = ""
    var history: [SPITransaction] = []
    var keepCSLow: Bool = false
    var isBusy: Bool = false

    struct SPITransaction: Identifiable {
        let id = UUID()
        let timestamp = Date()
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

    func send(device: CH341Device, manager: DeviceManager) {
        let bytes = parseHex(inputHex)
        guard !bytes.isEmpty else { return }
        guard !isBusy else { return }

        isBusy = true
        Task {
            do {
                let response = try await device.perform { dev in
                    try dev.spiExchange(data: bytes, keepCSLow: self.keepCSLow)
                }
                let txn = SPITransaction(sent: bytes, received: response)
                history.insert(txn, at: 0)
                manager.log(.info, "SPI TX: \(txn.sentHex) → RX: \(txn.receivedHex)")
            } catch {
                manager.log(.error, "SPI transfer failed: \(error.localizedDescription)")
            }
            isBusy = false
        }
    }

    func releaseCS(device: CH341Device) {
        Task {
            try? await device.perform { dev in
                try dev.spiChipSelect(false)
            }
            keepCSLow = false
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
