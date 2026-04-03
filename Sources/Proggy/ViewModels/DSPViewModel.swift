import Foundation
import SwiftUI

@Observable
@MainActor
final class DSPViewModel {
    var firmwareData: Data?
    var firmwareFileName: String?
    var firmwareSize: Int = 0
    var skipPrePLL: Int = 14

    // Status
    var isUploading = false
    var uploadProgress: Double = 0
    var coreStatus: String = "Unknown"
    var pllLocked: Bool = false
    var executeCount: UInt16 = 0
    var panicFlag: Bool = false
    var panicCode: UInt16 = 0
    var asrcLockRaw: UInt16 = 0xFFFF
    var powerEnable0: UInt16 = 0
    var powerEnable1: UInt16 = 0

    // Register read/write
    var regAddress: String = "F401"
    var regValue: String = ""
    var regReadResult: String = ""
    var regReadBytes: Int = 2 // 2 for control regs, 4 for data/param

    // Safeload
    var safeloadAddr: String = ""
    var safeloadValue: String = "1.0"
    var safeloadFormat: SafeloadFormat = .float

    // Polling
    private var pollTask: Task<Void, Never>?
    var isPolling = false

    enum SafeloadFormat: String, CaseIterable, Identifiable {
        case float = "Float"
        case dB = "dB"
        case hex = "Hex (8.24)"
        var id: String { rawValue }
    }

    // MARK: - Firmware Loading

    func loadDatFiles(numBytesURL: URL, txBufferURL: URL, manager: DeviceManager) {
        do {
            let numBytesContent = try String(contentsOf: numBytesURL, encoding: .utf8)
            let txBufferContent = try String(contentsOf: txBufferURL, encoding: .utf8)
            let firmware = try SigmaStudio.convert(numBytesContent: numBytesContent,
                                                    txBufferContent: txBufferContent)
            firmwareData = firmware
            firmwareSize = firmware.count
            firmwareFileName = txBufferURL.lastPathComponent
            manager.log(.info, "DSP firmware loaded: \(manager.formatSize(firmware.count))")
        } catch {
            manager.log(.error, "Failed to load DSP firmware: \(error.localizedDescription)")
        }
    }

    func loadBinaryFirmware(_ url: URL, manager: DeviceManager) {
        do {
            let data = try Data(contentsOf: url)
            firmwareData = data
            firmwareSize = data.count
            firmwareFileName = url.lastPathComponent
            manager.log(.info, "DSP firmware loaded: \(manager.formatSize(data.count))")
        } catch {
            manager.log(.error, "Failed to load firmware: \(error.localizedDescription)")
        }
    }

    // MARK: - Upload Firmware via SPI

    func uploadFirmware(device: CH341Device, manager: DeviceManager) {
        guard let firmware = firmwareData, !isUploading else { return }
        let skip = skipPrePLL

        isUploading = true
        uploadProgress = 0
        manager.log(.info, "DSP SPI upload starting (skip \(skip) pre-PLL records)...")

        Task {
            do {
                // Enter SPI mode
                manager.log(.info, "Entering SPI mode...")
                try await device.perform { dev in
                    try dev.dspEnterSPIMode()
                }

                // Pre-PLL init
                manager.log(.info, "Soft reset + hibernate + kill core...")
                try await device.perform { dev in
                    try dev.dspSoftReset()
                    try dev.dspHibernate(true)
                    try dev.dspKillCore()
                }

                manager.log(.info, "Configuring PLL (M=96, DIV_4)...")
                try await device.perform { dev in
                    try dev.dspWriteReg(ADAU14xx.PLL_CTRL0, value: 0x0060)
                    try dev.dspWriteReg(ADAU14xx.PLL_CTRL1, value: 0x0002)
                    try dev.dspWriteReg(ADAU14xx.PLL_CLK_SRC, value: 0x0001)
                    try dev.dspPulseReg(ADAU14xx.PLL_ENABLE)
                }

                // Wait for PLL lock
                manager.log(.info, "Waiting for PLL lock...")
                var locked = false
                for _ in 0..<50 {
                    try await Task.sleep(for: .milliseconds(10))
                    locked = try await device.perform { dev in try dev.dspPLLLocked() }
                    if locked { break }
                }
                await MainActor.run { self.pllLocked = locked }
                manager.log(locked ? .info : .warning, locked ? "PLL locked" : "PLL lock timeout!")

                // Upload firmware records
                manager.log(.info, "Uploading \(manager.formatSize(firmware.count)) firmware...")
                try await device.perform { dev in
                    try dev.dspUploadFirmware(records: firmware, skipPrePLL: skip,
                                               progress: { pct in Task { @MainActor in self.uploadProgress = pct } })
                }

                // Start core
                manager.log(.info, "Starting core...")
                try await device.perform { dev in
                    try dev.dspStartCore()
                    try dev.dspHibernate(false)
                }

                manager.log(.info, "DSP upload complete")
                await refreshStatus(device: device, manager: manager)

            } catch {
                manager.log(.error, "DSP upload failed: \(error.localizedDescription)")
            }

            isUploading = false
            uploadProgress = 0
        }
    }

    // MARK: - Status

    func refreshStatus(device: CH341Device, manager: DeviceManager) async {
        do {
            let status = try await device.perform { dev in try dev.dspCoreStatus() }
            let exec = try await device.perform { dev in try dev.dspExecuteCount() }
            let panic = try await device.perform { dev in try dev.dspPanicFlag() }
            let pll = try await device.perform { dev in try dev.dspPLLLocked() }
            let asrc = try await device.perform { dev in try dev.dspASRCLockStatus() }

            coreStatus = status.description
            executeCount = exec
            panicFlag = panic.flag
            panicCode = panic.code
            pllLocked = pll
            asrcLockRaw = asrc
        } catch {
            manager.log(.error, "Status read failed: \(error.localizedDescription)")
        }
    }

    // MARK: - Register Access

    func readRegister(device: CH341Device, manager: DeviceManager) {
        guard let reg = UInt16(regAddress, radix: 16) else { return }
        Task {
            do {
                if regReadBytes == 4 {
                    let val = try await device.perform { dev in try dev.dspReadParam(reg) }
                    let flt = DSPFixedPoint.toFloat(val)
                    regReadResult = String(format: "0x%08X (%.6f)", val, flt)
                    manager.log(.info, String(format: "DSP [0x%04X] = 0x%08X (%.6f)", reg, val, flt))
                } else {
                    let val = try await device.perform { dev in try dev.dspReadReg(reg) }
                    regReadResult = String(format: "0x%04X (%d)", val, val)
                    manager.log(.info, String(format: "DSP [0x%04X] = 0x%04X", reg, val))
                }
            } catch {
                regReadResult = "Error"
                manager.log(.error, "Register read failed: \(error.localizedDescription)")
            }
        }
    }

    func writeRegister(device: CH341Device, manager: DeviceManager) {
        guard let reg = UInt16(regAddress, radix: 16) else { return }
        guard let val = UInt16(regValue, radix: 16) else { return }
        Task {
            do {
                try await device.perform { dev in try dev.dspWriteReg(reg, value: val) }
                manager.log(.info, String(format: "DSP [0x%04X] <- 0x%04X", reg, val))
            } catch {
                manager.log(.error, "Register write failed: \(error.localizedDescription)")
            }
        }
    }

    // MARK: - Safeload

    func performSafeload(device: CH341Device, manager: DeviceManager) {
        guard let targetAddr = UInt16(safeloadAddr, radix: 16) else { return }

        let value: UInt32
        switch safeloadFormat {
        case .float: value = DSPFixedPoint.fromFloat(Float(safeloadValue) ?? 0)
        case .dB: value = DSPFixedPoint.fromDecibels(Float(safeloadValue) ?? -144)
        case .hex: value = UInt32(safeloadValue.replacingOccurrences(of: "0x", with: ""), radix: 16) ?? 0
        }

        Task {
            do {
                try await device.perform { dev in
                    try dev.dspSafeload(targetAddr: targetAddr, values: [value])
                }
                let flt = DSPFixedPoint.toFloat(value)
                let db = DSPFixedPoint.toDecibels(value)
                manager.log(.info, String(format: "Safeload [0x%04X] = 0x%08X (%.6f / %.1f dB)",
                                          targetAddr, value, flt, db))
            } catch {
                manager.log(.error, "Safeload failed: \(error.localizedDescription)")
            }
        }
    }

    // MARK: - Quick Actions

    func softReset(device: CH341Device, manager: DeviceManager) {
        Task {
            do {
                try await device.perform { dev in try dev.dspSoftReset() }
                manager.log(.info, "DSP soft reset (re-entered SPI mode)")
            } catch { manager.log(.error, "Soft reset failed: \(error.localizedDescription)") }
        }
    }

    func clearPanic(device: CH341Device, manager: DeviceManager) {
        Task {
            do {
                try await device.perform { dev in try dev.dspClearPanic() }
                manager.log(.info, "Panic cleared")
                await refreshStatus(device: device, manager: manager)
            } catch { manager.log(.error, "Clear panic failed: \(error.localizedDescription)") }
        }
    }

    // MARK: - Status Polling

    func startPolling(device: CH341Device, manager: DeviceManager) {
        guard !isPolling else { return }
        isPolling = true
        pollTask = Task { [weak self] in
            while !Task.isCancelled {
                guard let self else { return }
                await self.refreshStatus(device: device, manager: manager)
                try? await Task.sleep(for: .seconds(1))
            }
        }
    }

    func stopPolling() {
        isPolling = false
        pollTask?.cancel()
        pollTask = nil
    }
}
