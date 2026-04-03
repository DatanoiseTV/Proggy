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

    // Auto-program
    var autoProgramOnChange: Bool = false
    var autoProgramCount: Int = 0
    var watchedFirmwareURL: URL?
    private var fwWatchSource: DispatchSourceFileSystemObject?
    private var lastFwModDate: Date?

    // MARK: - Firmware

    func loadFirmware(_ url: URL, manager: DeviceManager) {
        do {
            firmwareData = try Data(contentsOf: url)
            firmwareFileName = url.lastPathComponent
            manager.log(.info, "SWD firmware loaded: \(manager.formatSize(firmwareData!.count))")
            watchFirmware(url, manager: manager)
        } catch {
            manager.log(.error, "Failed to load: \(error.localizedDescription)")
        }
    }

    func watchFirmware(_ url: URL, manager: DeviceManager) {
        stopWatchingFirmware()
        watchedFirmwareURL = url
        lastFwModDate = manager.fileModDate(url)

        let fd = Darwin.open(url.path, O_EVTONLY)
        guard fd >= 0 else { return }

        let source = DispatchSource.makeFileSystemObjectSource(
            fileDescriptor: fd, eventMask: [.write, .rename], queue: .main
        )
        source.setEventHandler { [weak self] in
            guard let self, !self.isFlashing else { return }
            let newDate = manager.fileModDate(url)
            guard newDate != self.lastFwModDate else { return }
            self.lastFwModDate = newDate

            guard let data = try? Data(contentsOf: url), !data.isEmpty else { return }
            self.firmwareData = data
            manager.log(.info, "SWD firmware reloaded: \(manager.formatSize(data.count))")

            if self.autoProgramOnChange && self.isProbeConnected {
                self.autoProgramCount += 1
                manager.log(.info, "SWD auto-program #\(self.autoProgramCount) triggered")
                self.flash(manager: manager)
            }
        }
        source.setCancelHandler { Darwin.close(fd) }
        source.resume()
        fwWatchSource = source
    }

    func stopWatchingFirmware() {
        fwWatchSource?.cancel()
        fwWatchSource = nil
        watchedFirmwareURL = nil
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
