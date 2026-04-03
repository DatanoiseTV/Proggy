import Foundation
import SwiftUI

@Observable
@MainActor
final class DeviceManager {
    let device = CH341Device()
    let buffer = HexDataBuffer()
    let apiServer = APIServer()

    // Connection state
    var isConnected = false
    var deviceInfo: String = "No device"
    var chipInfo: JEDECInfo?
    var chipName: String?
    var chipCapacity: Int = 0

    // Operation state
    var isBusy = false
    var progress: Double = 0
    var statusMessage: String = "Ready"

    // Log
    var logEntries: [LogEntry] = []

    // Speed setting
    var speed: CH341Speed = .i2c20k  // Default to slowest (most compatible, same as ch341prog)

    // Chip selection
    var selectedChip: ChipEntry?
    var verifyAfterWrite: Bool = true

    // Loaded file info
    var loadedFileName: String?
    var loadedFileFormat: String?
    var loadedFileModDate: Date?
    var loadedFilePath: String?
    var bufferSizeWarning: String?

    // Recent files
    var recentFiles: [URL] {
        get {
            (UserDefaults.standard.array(forKey: "recentFiles") as? [String])?.compactMap { URL(fileURLWithPath: $0) } ?? []
        }
        set {
            UserDefaults.standard.set(newValue.map(\.path), forKey: "recentFiles")
        }
    }

    // Cancellation
    private var currentTask: Task<Void, Never>?
    private var cancelFlag = false

    // Hotplug polling
    private var pollingTask: Task<Void, Never>?

    init() {
        startHotplugPolling()
    }

    // MARK: - Hotplug Polling

    /// Poll for device connection changes (simple approach without libusb hotplug callbacks)
    private func startHotplugPolling() {
        pollingTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(1))
                guard let self else { return }

                if self.isConnected && !self.device.isConnected {
                    // Device was disconnected
                    self.isConnected = false
                    self.deviceInfo = "Disconnected"
                    self.chipInfo = nil
                    self.chipName = nil
                    self.chipCapacity = 0
                    self.log(.warning, "Device disconnected")
                    self.device.close()
                } else if !self.isConnected && !self.isBusy {
                    // Try to detect device
                    await self.tryAutoConnect()
                }
            }
        }
    }

    private func tryAutoConnect() async {
        do {
            try device.open()
            try device.setStream(speed: speed)
            device.spiDebugLog = { msg in self.log(.info, msg) }
            isConnected = true
            deviceInfo = "CH341A (rev \(device.deviceRevision))"
            log(.info, "Device connected: \(deviceInfo)")

            // Try to detect chip
            await detectChip()
        } catch {
            device.close()
        }
    }

    // MARK: - Connection

    func connect() {
        guard !isConnected else { return }
        runOperation("Connecting") {
            try self.device.open()
            try self.device.setStream(speed: self.speed)
            // Enable SPI debug logging
            self.device.spiDebugLog = { msg in self.log(.info, msg) }
            await MainActor.run {
                self.isConnected = true
                self.deviceInfo = "CH341A (rev \(self.device.deviceRevision))"
            }
            self.log(.info, "Connected: \(self.device.deviceRevision)")
        }
    }

    func disconnect() {
        cancelFlag = true
        currentTask?.cancel()
        device.close()
        isConnected = false
        deviceInfo = "Disconnected"
        chipInfo = nil
        chipName = nil
        chipCapacity = 0
        statusMessage = "Disconnected"
        log(.info, "Disconnected")
    }

    // MARK: - Chip Detection

    var detectedDevices: [DetectedDevice] = []

    func detectChip() async {
        guard isConnected else { return }
        runOperation("Detecting chip") {
            // Run SPI diagnostic
            try? await self.device.perform { dev in
                try dev.spiDiagnostic(debugLog: { msg in self.log(.info, msg) })
            }

            // Try JEDEC first (most common), then REMS, then RDID
            self.log(.info, "Trying JEDEC ID (0x9F)...")
            if let jedec = try? await self.device.perform({ dev in
                try dev.readJEDECID(debugLog: { msg in self.log(.info, msg) })
            }) {
                await MainActor.run {
                    self.chipInfo = jedec
                    self.chipCapacity = jedec.capacityBytes
                    if let known = ChipDatabase.lookup(jedec: jedec) {
                        self.chipName = known.name
                        self.chipCapacity = known.capacity
                    }
                }
                self.log(.info, "Chip detected: \(jedec.description)")
                return
            }

            // JEDEC failed — try full auto-detect (REMS 0x90, RDID 0xAB)
            self.log(.info, "JEDEC not supported, trying REMS/RDID...")
            if let detected = try? await self.device.perform({ dev in
                try dev.spiAutoDetect()
            }) {
                await MainActor.run {
                    self.chipName = detected.name
                    self.chipCapacity = detected.capacity
                }
                self.log(.info, "\(detected.type.rawValue): \(detected.manufacturer) \(detected.name ?? "Unknown") (\(self.formatSize(detected.capacity))) [ID: \(detected.rawID)]")
                return
            }

            self.log(.warning, "No SPI chip detected via JEDEC/REMS/RDID — try selecting manually")
        }
    }

    /// Full auto-detect: tries SPI (JEDEC, REMS, RDID) then I2C bus scan
    func autoDetectAll() {
        guard isConnected else { return }
        runOperation("Auto-detecting") {
            var results = [DetectedDevice]()

            // Try SPI detection
            self.log(.info, "Probing SPI...")
            if let spiDev = try? await self.device.perform({ dev in
                try dev.spiAutoDetect()
            }) {
                results.append(spiDev)
                let name = spiDev.name ?? "Unknown"
                self.log(.info, "SPI \(spiDev.type.rawValue): \(spiDev.manufacturer) \(name) (\(self.formatSize(spiDev.capacity))) [ID: \(spiDev.rawID)]")

                // Auto-select if SPI flash found
                if spiDev.type == .spiFlash {
                    // Also set JEDEC info
                    let jedec = try? await self.device.perform { dev in
                        try dev.readJEDECID(debugLog: { msg in self.log(.info, msg) })
                    }
                    await MainActor.run {
                        self.chipInfo = jedec
                        self.chipName = spiDev.name
                        self.chipCapacity = spiDev.capacity
                    }
                } else {
                    await MainActor.run {
                        self.chipName = spiDev.name
                        self.chipCapacity = spiDev.capacity
                    }
                }
            } else {
                self.log(.info, "No SPI device detected")
            }

            // Try I2C detection
            self.log(.info, "Probing I2C bus...")
            let i2cDevs = try? await self.device.perform({ dev in
                try dev.i2cAutoDetect()
            })
            if let i2cDevs, !i2cDevs.isEmpty {
                for dev in i2cDevs {
                    results.append(dev)
                    let name = dev.name ?? "Unknown"
                    self.log(.info, "I2C EEPROM at \(dev.rawID): ~\(name) (\(self.formatSize(dev.capacity)))")
                }
            } else {
                self.log(.info, "No I2C EEPROM detected")
            }

            await MainActor.run {
                self.detectedDevices = results
            }

            if results.isEmpty {
                self.log(.warning, "No devices detected")
            } else {
                self.log(.info, "Detection complete: \(results.count) device(s) found")
            }
        }
    }

    // MARK: - Chip Selection

    func selectChip(_ chip: ChipEntry) {
        selectedChip = chip
        chipName = chip.name
        chipCapacity = chip.capacity
        log(.info, "Selected: \(chip.manufacturer) \(chip.name) (\(formatSize(chip.capacity)))")
        checkBufferFitsChip()
    }

    // MARK: - Chip Type

    var isI2CMode: Bool {
        guard let cat = selectedChip?.category else { return false }
        return cat == .i2cEEPROM || cat == .i2cFRAM
    }

    var isFRAMMode: Bool {
        guard let cat = selectedChip?.category else { return false }
        return cat == .spiFRAM || cat == .i2cFRAM
    }

    var i2cDeviceAddress: UInt8 {
        selectedChip?.i2cAddress ?? 0x50
    }

    // MARK: - Chip Operations (SPI Flash + I2C EEPROM)

    func readChip() {
        guard isConnected, chipCapacity > 0 else { return }
        let size = chipCapacity

        if isI2CMode {
            let addr = i2cDeviceAddress
            runOperation("Reading I2C \(formatSize(size))") {
                let data = try await self.device.perform { dev in
                    try dev.i2cEEPROMRead(address: addr, capacity: size,
                                           progress: { pct in Task { @MainActor in self.progress = pct } },
                                           cancelled: { self.cancelFlag })
                }
                await MainActor.run { self.buffer.load(data) }
                self.log(.info, "I2C read complete: \(self.formatSize(data.count)), CRC32: \(String(format: "%08X", self.buffer.crc32))")
            }
        } else {
            runOperation("Reading SPI \(formatSize(size))") {
                let data = try await self.device.perform { dev in
                    try dev.readFlash(address: 0, length: size,
                                      progress: { pct in Task { @MainActor in self.progress = pct } },
                                      cancelled: { self.cancelFlag })
                }
                await MainActor.run { self.buffer.load(data) }
                self.log(.info, "SPI read complete: \(self.formatSize(data.count)), CRC32: \(String(format: "%08X", self.buffer.crc32))")
            }
        }
    }

    func writeChip() {
        guard isConnected, !buffer.isEmpty, chipCapacity > 0 else {
            if chipCapacity == 0 {
                log(.warning, "No chip selected — detect or select a chip first")
            }
            return
        }
        let data = buffer.data

        if isI2CMode {
            let addr = i2cDeviceAddress
            let cap = chipCapacity
            runOperation("Writing I2C \(formatSize(data.count))") {
                try await self.device.perform { dev in
                    try dev.i2cEEPROMWrite(address: addr, data: data, capacity: cap,
                                            progress: { pct in Task { @MainActor in self.progress = pct } },
                                            cancelled: { self.cancelFlag })
                }
                self.log(.info, "I2C write complete: \(self.formatSize(data.count))")

                if self.verifyAfterWrite {
                    self.log(.info, "Verifying...")
                    await MainActor.run { self.statusMessage = "Verifying..."; self.progress = 0 }
                    try await self.device.perform { dev in
                        try dev.i2cEEPROMVerify(address: addr, data: data, capacity: cap,
                                                 progress: { pct in Task { @MainActor in self.progress = pct } },
                                                 cancelled: { self.cancelFlag })
                    }
                    self.log(.info, "Verify OK")
                }
            }
        } else {
            runOperation("Writing SPI \(formatSize(data.count))") {
                try await self.device.perform { dev in
                    try dev.writeStatus(0x00)
                }
                self.log(.info, "Chip unprotected")

                self.log(.info, "Erasing...")
                await MainActor.run { self.statusMessage = "Erasing..." }
                try await self.device.perform { dev in
                    try dev.chipErase(
                        progress: { pct in Task { @MainActor in self.progress = pct } },
                        debugLog: { msg in self.log(.info, msg) },
                        cancelled: { self.cancelFlag })
                }
                self.log(.info, "Erase complete")
                await MainActor.run { self.progress = 0 }

                await MainActor.run { self.statusMessage = "Writing..." }
                try await self.device.perform { dev in
                    try dev.writeFlash(address: 0, data: data,
                                       progress: { pct in Task { @MainActor in self.progress = pct } },
                                       cancelled: { self.cancelFlag })
                }
                self.log(.info, "SPI write complete: \(self.formatSize(data.count))")

                if self.verifyAfterWrite {
                    self.log(.info, "Verifying...")
                    await MainActor.run { self.statusMessage = "Verifying..."; self.progress = 0 }
                    try await self.device.perform { dev in
                        try dev.verifyFlash(address: 0, data: data,
                                            progress: { pct in Task { @MainActor in self.progress = pct } },
                                            cancelled: { self.cancelFlag })
                    }
                    self.log(.info, "Verify OK")
                }
            }
        }
    }

    func eraseChip() {
        guard isConnected, chipCapacity > 0 else {
            if chipCapacity == 0 { log(.warning, "No chip selected") }
            return
        }
        if isI2CMode {
            // I2C EEPROMs don't have an erase command — fill with 0xFF
            let cap = chipCapacity
            let addr = i2cDeviceAddress
            runOperation("Erasing I2C EEPROM") {
                let blank = Data(repeating: 0xFF, count: cap)
                try await self.device.perform { dev in
                    try dev.i2cEEPROMWrite(address: addr, data: blank, capacity: cap,
                                            progress: { pct in Task { @MainActor in self.progress = pct } },
                                            cancelled: { self.cancelFlag })
                }
                self.log(.info, "I2C EEPROM erased (filled with 0xFF)")
            }
        } else {
            runOperation("Erasing SPI chip") {
                try await self.device.perform { dev in
                    try dev.writeStatus(0x00)
                    try dev.chipErase(
                        progress: { pct in Task { @MainActor in self.progress = pct } },
                        cancelled: { self.cancelFlag })
                }
                self.log(.info, "SPI erase complete")
            }
        }
    }

    func verifyChip() {
        guard isConnected, !buffer.isEmpty, chipCapacity > 0 else {
            if chipCapacity == 0 { log(.warning, "No chip selected") }
            return
        }
        let data = buffer.data

        if isI2CMode {
            let addr = i2cDeviceAddress
            let cap = chipCapacity
            runOperation("Verifying I2C \(formatSize(data.count))") {
                try await self.device.perform { dev in
                    try dev.i2cEEPROMVerify(address: addr, data: data, capacity: cap,
                                             progress: { pct in Task { @MainActor in self.progress = pct } },
                                             cancelled: { self.cancelFlag })
                }
                self.log(.info, "I2C verify OK")
            }
        } else {
            runOperation("Verifying SPI \(formatSize(data.count))") {
                try await self.device.perform { dev in
                    try dev.verifyFlash(address: 0, data: data,
                                        progress: { pct in Task { @MainActor in self.progress = pct } },
                                        cancelled: { self.cancelFlag })
                }
                self.log(.info, "SPI verify OK")
            }
        }
    }

    func blankCheck() {
        guard isConnected, chipCapacity > 0 else { return }
        let size = chipCapacity

        if isI2CMode {
            let addr = i2cDeviceAddress
            runOperation("Blank check I2C") {
                let data = try await self.device.perform { dev in
                    try dev.i2cEEPROMRead(address: addr, capacity: size,
                                           progress: { pct in Task { @MainActor in self.progress = pct } },
                                           cancelled: { self.cancelFlag })
                }
                let isBlank = data.allSatisfy { $0 == 0xFF }
                self.log(.info, isBlank ? "EEPROM is blank" : "EEPROM is NOT blank")
            }
        } else {
            runOperation("Blank check SPI") {
                let isBlank = try await self.device.perform { dev in
                    try dev.blankCheck(address: 0, length: size,
                                       progress: { pct in Task { @MainActor in self.progress = pct } },
                                       cancelled: { self.cancelFlag })
                }
                self.log(.info, isBlank ? "Flash is blank" : "Flash is NOT blank")
            }
        }
    }

    // MARK: - Cancel

    func cancelOperation() {
        cancelFlag = true
        currentTask?.cancel()
        statusMessage = "Cancelling..."
    }

    // MARK: - File I/O

    // File watching
    var watchedFileURL: URL?
    private var fileWatchSource: DispatchSourceFileSystemObject?
    private var lastFileModDate: Date?

    func loadFile(_ url: URL) {
        do {
            try buffer.loadFromFile(url)
            setFileInfo(url: url, format: "Binary")
            addRecentFile(url)
            log(.info, "Loaded: \(url.lastPathComponent) (\(formatSize(buffer.count)))")
            statusMessage = "Loaded \(url.lastPathComponent)"
            watchFile(url)
            checkBufferFitsChip()
        } catch {
            log(.error, "Failed to load file: \(error.localizedDescription)")
        }
    }

    func loadIntelHex(_ url: URL) {
        do {
            let content = try String(contentsOf: url, encoding: .utf8)
            let data = try IntelHex.parse(content)
            buffer.load(data)
            setFileInfo(url: url, format: "Intel HEX")
            addRecentFile(url)
            log(.info, "Loaded IHEX: \(url.lastPathComponent) (\(formatSize(data.count)))")
            statusMessage = "Loaded \(url.lastPathComponent)"
            watchFile(url)
            checkBufferFitsChip()
        } catch {
            log(.error, "Failed to load IHEX: \(error.localizedDescription)")
        }
    }

    private func setFileInfo(url: URL, format: String) {
        loadedFileName = url.lastPathComponent
        loadedFileFormat = format
        loadedFilePath = url.path
        loadedFileModDate = fileModDate(url)
    }

    // MARK: - Recent Files

    private func addRecentFile(_ url: URL) {
        var recents = recentFiles
        recents.removeAll { $0.path == url.path }
        recents.insert(url, at: 0)
        if recents.count > 10 { recents = Array(recents.prefix(10)) }
        recentFiles = recents
    }

    func clearRecentFiles() {
        recentFiles = []
    }

    // MARK: - Buffer Size Validation

    func checkBufferFitsChip() {
        guard chipCapacity > 0, !buffer.isEmpty else {
            bufferSizeWarning = nil
            return
        }
        if buffer.count > chipCapacity {
            let excess = buffer.count - chipCapacity
            bufferSizeWarning = "Buffer (\(formatSize(buffer.count))) exceeds chip capacity (\(formatSize(chipCapacity))) by \(formatSize(excess))"
            log(.warning, bufferSizeWarning!)
        } else if buffer.count < chipCapacity {
            let pct = Int(Double(buffer.count) / Double(chipCapacity) * 100)
            bufferSizeWarning = nil
            log(.info, "Buffer uses \(pct)% of chip capacity (\(formatSize(buffer.count)) / \(formatSize(chipCapacity)))")
        } else {
            bufferSizeWarning = nil
        }
    }

    func saveFile(_ url: URL) {
        do {
            try buffer.saveToFile(url)
            log(.info, "Saved: \(url.lastPathComponent) (\(formatSize(buffer.count)))")
            statusMessage = "Saved \(url.lastPathComponent)"
        } catch {
            log(.error, "Failed to save file: \(error.localizedDescription)")
        }
    }

    func saveIntelHex(_ url: URL) {
        do {
            let hex = IntelHex.export(buffer.data)
            try hex.write(to: url, atomically: true, encoding: .utf8)
            log(.info, "Saved IHEX: \(url.lastPathComponent) (\(formatSize(buffer.count)))")
            statusMessage = "Saved \(url.lastPathComponent)"
        } catch {
            log(.error, "Failed to save IHEX: \(error.localizedDescription)")
        }
    }

    // MARK: - File Watching (auto-reload on disk change)

    /// When true, automatically programs the chip after file reload
    var autoProgramOnChange: Bool = false
    var autoProgramCount: Int = 0

    func watchFile(_ url: URL) {
        stopWatchingFile()
        watchedFileURL = url
        lastFileModDate = fileModDate(url)

        let fd = open(url.path, O_EVTONLY)
        guard fd >= 0 else { return }

        let source = DispatchSource.makeFileSystemObjectSource(
            fileDescriptor: fd,
            eventMask: [.write, .rename, .delete],
            queue: .main
        )

        source.setEventHandler { [weak self] in
            guard let self else { return }
            // Don't reload during busy operations
            guard !self.isBusy else { return }

            // Check if file actually changed (debounce)
            let newDate = self.fileModDate(url)
            if newDate != self.lastFileModDate {
                self.lastFileModDate = newDate
                self.reloadAndMaybeProgram()
            }
        }

        source.setCancelHandler {
            close(fd)
        }

        source.resume()
        fileWatchSource = source
        log(.info, "Watching \(url.lastPathComponent) for changes")
    }

    func stopWatchingFile() {
        fileWatchSource?.cancel()
        fileWatchSource = nil
        watchedFileURL = nil
        lastFileModDate = nil
    }

    private func reloadAndMaybeProgram() {
        guard let url = watchedFileURL else { return }

        // Reload the file
        let ext = url.pathExtension.lowercased()
        if ext == "hex" || ext == "ihex" {
            do {
                let content = try String(contentsOf: url, encoding: .utf8)
                let data = try IntelHex.parse(content)
                guard !data.isEmpty else {
                    log(.warning, "Auto-reload skipped: file is empty")
                    return
                }
                buffer.load(data)
                log(.info, "Auto-reloaded: \(url.lastPathComponent) (\(formatSize(data.count)))")
            } catch {
                log(.warning, "Auto-reload failed: \(error.localizedDescription)")
                return
            }
        } else {
            do {
                let data = try Data(contentsOf: url)
                guard !data.isEmpty else {
                    log(.warning, "Auto-reload skipped: file is empty")
                    return
                }
                buffer.load(data)
                log(.info, "Auto-reloaded: \(url.lastPathComponent) (\(formatSize(buffer.count)))")
            } catch {
                log(.warning, "Auto-reload failed: \(error.localizedDescription)")
                return
            }
        }
        statusMessage = "Reloaded \(url.lastPathComponent)"

        // Auto-program if enabled and device is connected
        if autoProgramOnChange && isConnected && !buffer.isEmpty {
            autoProgramCount += 1
            log(.info, "Auto-program #\(autoProgramCount) triggered by file change")
            writeChip()
        }
    }

    func fileModDate(_ url: URL) -> Date? {
        try? FileManager.default.attributesOfItem(atPath: url.path)[.modificationDate] as? Date
    }

    // MARK: - Helpers

    private func runOperation(_ name: String, _ block: @escaping () async throws -> Void) {
        guard !isBusy else { return }
        isBusy = true
        progress = 0
        cancelFlag = false
        statusMessage = name + "..."

        currentTask = Task {
            do {
                try await block()
                await MainActor.run {
                    self.statusMessage = name + " complete"
                }
            } catch is CancellationError {
                self.log(.warning, "\(name) cancelled")
                self.statusMessage = "Cancelled"
            } catch let error as CH341Error where error.errorDescription?.contains("cancelled") == true {
                self.log(.warning, "\(name) cancelled")
                self.statusMessage = "Cancelled"
            } catch {
                self.log(.error, "\(name) failed: \(error.localizedDescription)")
                self.statusMessage = "Error: \(error.localizedDescription)"

                // Check if device disconnected
                if !self.device.isConnected {
                    self.isConnected = false
                    self.deviceInfo = "Disconnected"
                }
            }
            await MainActor.run {
                self.isBusy = false
                self.progress = 0
            }
        }
    }

    func log(_ level: LogEntry.Level, _ message: String) {
        Task { @MainActor in
            logEntries.append(LogEntry(level: level, message: message))
            // Keep log manageable
            if logEntries.count > 500 {
                logEntries.removeFirst(100)
            }
        }
    }

    func formatSize(_ bytes: Int) -> String {
        if bytes >= 1_048_576 { return String(format: "%.1f MB", Double(bytes) / 1_048_576.0) }
        if bytes >= 1024 { return String(format: "%.1f KB", Double(bytes) / 1024.0) }
        return "\(bytes) B"
    }
}

// MARK: - Log Entry

struct LogEntry: Identifiable {
    let id = UUID()
    let timestamp = Date()
    let level: Level
    let message: String

    enum Level: String {
        case info = "INFO"
        case warning = "WARN"
        case error = "ERROR"

        var color: Color {
            switch self {
            case .info: return .secondary
            case .warning: return .orange
            case .error: return .red
            }
        }
    }

    var timestampString: String {
        let fmt = DateFormatter()
        fmt.dateFormat = "HH:mm:ss.SSS"
        return fmt.string(from: timestamp)
    }
}
