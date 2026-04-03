import Foundation
import SwiftUI

@Observable
@MainActor
final class SWDViewModel {
    var firmwareData: Data?
    var firmwareFileName: String?
    var selectedChip: RPChip = .rp2040

    // Status
    var isFlashing = false
    var flashProgress: Double = 0
    var flashStatus: String = ""
    var probeInfo: String?
    var idcode: String?
    var isProbeConnected = false

    private var probe: DebugProbe?

    // MARK: - Firmware

    func loadFirmware(_ url: URL, manager: DeviceManager) {
        do {
            firmwareData = try Data(contentsOf: url)
            firmwareFileName = url.lastPathComponent
            manager.log(.info, "SWD firmware loaded: \(manager.formatSize(firmwareData!.count))")
        } catch {
            manager.log(.error, "Failed to load: \(error.localizedDescription)")
        }
    }

    // MARK: - Probe

    func connectProbe(manager: DeviceManager) {
        Task.detached { [weak self] in
            do {
                let probe = DebugProbe()
                try probe.open()
                let info = probe.probeInfo

                await MainActor.run {
                    self?.probe = probe
                    self?.probeInfo = info
                    self?.isProbeConnected = true
                    manager.log(.info, "Debug probe connected: \(info)")
                }
            } catch {
                await MainActor.run {
                    manager.log(.error, "Probe: \(error.localizedDescription)")
                }
            }
        }
    }

    func disconnectProbe(manager: DeviceManager) {
        probe?.close()
        probe = nil
        isProbeConnected = false
        probeInfo = nil
        idcode = nil
        manager.log(.info, "Probe disconnected")
    }

    func readIDCODE(manager: DeviceManager) {
        guard let probe else { return }
        Task.detached { [weak self] in
            do {
                try probe.initSWD()
                let id = try probe.readIDCODE()
                await MainActor.run {
                    self?.idcode = String(format: "0x%08X", id)
                    manager.log(.info, "SWD IDCODE: 0x\(String(format: "%08X", id))")
                }
            } catch {
                await MainActor.run {
                    manager.log(.error, "IDCODE read failed: \(error.localizedDescription)")
                }
            }
        }
    }

    // MARK: - Flash

    func flash(manager: DeviceManager) {
        guard let probe, let firmware = firmwareData, !isFlashing else { return }
        let chip = selectedChip

        isFlashing = true
        flashProgress = 0
        flashStatus = "Starting..."

        manager.log(.info, "SWD flash: \(manager.formatSize(firmware.count)) to \(chip.rawValue)")

        Task.detached { [weak self] in
            do {
                try probe.flashRP(
                    data: firmware,
                    chip: chip,
                    progress: { status, pct in
                        Task { @MainActor in
                            self?.flashStatus = status
                            self?.flashProgress = pct
                        }
                    },
                    cancelled: { false }
                )

                await MainActor.run {
                    self?.flashStatus = "Done! (\(chip.rawValue))"
                    self?.isFlashing = false
                    manager.log(.info, "SWD flash complete")
                }
            } catch {
                await MainActor.run {
                    self?.flashStatus = "Error: \(error.localizedDescription)"
                    self?.isFlashing = false
                    manager.log(.error, "SWD flash failed: \(error.localizedDescription)")
                }
            }
        }
    }
}
