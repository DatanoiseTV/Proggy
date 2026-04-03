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

    // MARK: - Safeload (1–5 params, 28-byte atomic burst)

    func performSafeload(device: CH341Device, manager: DeviceManager) {
        guard let targetAddr = UInt16(safeloadAddr, radix: 16) else { return }

        // Parse up to 5 values separated by commas or spaces
        let tokens = safeloadValue
            .replacingOccurrences(of: ",", with: " ")
            .split(separator: " ")
            .filter { !$0.isEmpty }

        let values: [UInt32] = tokens.prefix(5).map { token in
            let s = String(token)
            switch safeloadFormat {
            case .float: return DSPFixedPoint.fromFloat(Float(s) ?? 0)
            case .dB: return DSPFixedPoint.fromDecibels(Float(s) ?? -144)
            case .hex: return UInt32(s.replacingOccurrences(of: "0x", with: ""), radix: 16) ?? 0
            }
        }
        guard !values.isEmpty else { return }

        Task {
            do {
                try await device.perform { dev in
                    try dev.dspSafeload(targetAddr: targetAddr, values: values)
                }
                let desc = values.enumerated().map { (i, v) in
                    String(format: "[0x%04X]=0x%08X(%.4f)", targetAddr + UInt16(i), v, DSPFixedPoint.toFloat(v))
                }.joined(separator: " ")
                manager.log(.info, "Safeload \(values.count) param(s): \(desc)")
            } catch {
                manager.log(.error, "Safeload failed: \(error.localizedDescription)")
            }
        }
    }

    // MARK: - Biquad

    var biquadAddr: String = ""
    var biquadB0: String = "1.0"
    var biquadB1: String = "0.0"
    var biquadB2: String = "0.0"
    var biquadA1: String = "0.0"
    var biquadA2: String = "0.0"

    func writeBiquad(device: CH341Device, manager: DeviceManager) {
        guard let addr = UInt16(biquadAddr, radix: 16) else { return }
        let coeffs = CH341Device.BiquadCoeffs(
            b0: Float(biquadB0) ?? 1, b1: Float(biquadB1) ?? 0, b2: Float(biquadB2) ?? 0,
            a1: Float(biquadA1) ?? 0, a2: Float(biquadA2) ?? 0
        )

        Task {
            do {
                let stable = try await device.perform { dev in
                    try dev.dspWriteBiquad(baseAddr: addr, coeffs: coeffs)
                }
                if stable {
                    manager.log(.info, String(format: "Biquad [0x%04X]: b0=%.4f b1=%.4f b2=%.4f a1=%.4f a2=%.4f",
                                              addr, coeffs.b0, coeffs.b1, coeffs.b2, coeffs.a1, coeffs.a2))
                } else {
                    manager.log(.warning, "Biquad UNSTABLE — forced to unity passthrough")
                }
            } catch {
                manager.log(.error, "Biquad write failed: \(error.localizedDescription)")
            }
        }
    }

    func readBiquad(device: CH341Device, manager: DeviceManager) {
        guard let addr = UInt16(biquadAddr, radix: 16) else { return }
        Task {
            do {
                let c = try await device.perform { dev in try dev.dspReadBiquad(baseAddr: addr) }
                biquadB0 = String(format: "%.6f", c.b0)
                biquadB1 = String(format: "%.6f", c.b1)
                biquadB2 = String(format: "%.6f", c.b2)
                biquadA1 = String(format: "%.6f", c.a1)
                biquadA2 = String(format: "%.6f", c.a2)
                manager.log(.info, String(format: "Biquad [0x%04X]: b0=%.6f b1=%.6f b2=%.6f a1=%.6f a2=%.6f %s",
                                          addr, c.b0, c.b1, c.b2, c.a1, c.a2, c.isStable ? "STABLE" : "UNSTABLE"))
            } catch {
                manager.log(.error, "Biquad read failed: \(error.localizedDescription)")
            }
        }
    }

    // MARK: - Level Meters

    var levelAddrs: String = ""  // Comma-separated hex addresses
    var levelValues: [Float] = []

    func readLevels(device: CH341Device, manager: DeviceManager) {
        let addrs = levelAddrs
            .replacingOccurrences(of: ",", with: " ")
            .split(separator: " ")
            .compactMap { UInt16(String($0).replacingOccurrences(of: "0x", with: ""), radix: 16) }
        guard !addrs.isEmpty else { return }

        Task {
            do {
                let vals = try await device.perform { dev in try dev.dspReadLevels(addrs: addrs) }
                levelValues = vals
                let desc = zip(addrs, vals).map { (a, v) in
                    String(format: "0x%04X=%.4f(%.1fdB)", a, v, v > 0 ? 20*log10(v) : -144)
                }.joined(separator: " ")
                manager.log(.info, "Levels: \(desc)")
            } catch {
                manager.log(.error, "Level read failed: \(error.localizedDescription)")
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
