import SwiftUI

struct ChipSelectorView: View {
    @Environment(DeviceManager.self) private var manager
    @State private var searchText = ""
    @State private var selectedCategory: ChipCategory = .spiFlash
    @State private var showSelector = false

    var body: some View {
        GroupBox {
            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    Image(systemName: "cpu")
                        .foregroundStyle(.blue)
                    if let selected = manager.selectedChip {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(selected.name)
                                .font(.system(.body, design: .monospaced))
                                .fontWeight(.medium)
                            Text("\(manager.formatSize(selected.capacity)) \(selected.category.rawValue)")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    } else if let jedec = manager.chipInfo {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(manager.chipName ?? "Unknown")
                                .font(.system(.body, design: .monospaced))
                                .fontWeight(.medium)
                            Text("Auto-detected \(jedec.manufacturerName)")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    } else {
                        Text("No chip selected")
                            .foregroundStyle(.secondary)
                    }

                    Spacer()

                    Button("Select...") {
                        showSelector = true
                    }
                    .controlSize(.small)
                }

                // Detection buttons
                if manager.isConnected {
                    HStack(spacing: 6) {
                        Button {
                            manager.autoDetectAll()
                        } label: {
                            Label("Auto-Detect", systemImage: "sparkle.magnifyingglass")
                        }
                        .controlSize(.small)
                        .disabled(manager.isBusy)

                        Button("JEDEC ID") {
                            Task { await manager.detectChip() }
                        }
                        .controlSize(.small)
                        .disabled(manager.isBusy)
                    }

                    // Show detected devices
                    if !manager.detectedDevices.isEmpty {
                        Divider()
                        ForEach(Array(manager.detectedDevices.enumerated()), id: \.offset) { _, dev in
                            HStack(spacing: 4) {
                                Image(systemName: dev.type == .i2cEEPROM ? "point.3.connected.trianglepath.dotted" : "bolt.horizontal")
                                    .font(.caption2)
                                    .foregroundStyle(dev.type == .i2cEEPROM ? .cyan : .orange)
                                VStack(alignment: .leading, spacing: 0) {
                                    Text(dev.name ?? dev.type.rawValue)
                                        .font(.system(.caption, design: .monospaced))
                                        .fontWeight(.medium)
                                    Text("\(dev.manufacturer) \(manager.formatSize(dev.capacity)) [\(dev.rawID)]")
                                        .font(.caption2)
                                        .foregroundStyle(.secondary)
                                }
                            }
                        }
                    }
                }
            }
            .padding(.vertical, 2)
        } label: {
            Text("Device / Part")
        }
        .sheet(isPresented: $showSelector) {
            ChipPickerSheet(
                selectedCategory: $selectedCategory,
                searchText: $searchText,
                onSelect: { chip in
                    manager.selectChip(chip)
                    showSelector = false
                },
                onCancel: {
                    showSelector = false
                }
            )
        }
    }
}

// MARK: - Chip Category

enum ChipCategory: String, CaseIterable, Identifiable {
    case spiFlash = "SPI Flash"
    case i2cEEPROM = "I2C EEPROM"

    var id: String { rawValue }

    var icon: String {
        switch self {
        case .spiFlash: return "bolt.horizontal"
        case .i2cEEPROM: return "point.3.connected.trianglepath.dotted"
        }
    }
}

// MARK: - Chip Entry (for selector)

struct ChipEntry: Identifiable, Hashable {
    let id: String
    let name: String
    let manufacturer: String
    let capacity: Int
    let category: ChipCategory
    let voltageRange: String
    let pageSize: Int
    let sectorSize: Int

    // For I2C EEPROMs
    let i2cAddress: UInt8?

    init(name: String, manufacturer: String, capacity: Int, category: ChipCategory,
         voltageRange: String = "2.7-3.6V", pageSize: Int = 256, sectorSize: Int = 4096,
         i2cAddress: UInt8? = nil) {
        self.id = "\(manufacturer)/\(name)"
        self.name = name
        self.manufacturer = manufacturer
        self.capacity = capacity
        self.category = category
        self.voltageRange = voltageRange
        self.pageSize = pageSize
        self.sectorSize = sectorSize
        self.i2cAddress = i2cAddress
    }
}

// MARK: - Chip Picker Sheet

struct ChipPickerSheet: View {
    @Binding var selectedCategory: ChipCategory
    @Binding var searchText: String
    let onSelect: (ChipEntry) -> Void
    let onCancel: () -> Void

    private var recentChips: [ChipEntry] {
        let names = (UserDefaults.standard.array(forKey: "recentChips") as? [String]) ?? []
        return names.compactMap { name in ChipLibrary.chips.first { $0.id == name } }
    }

    private var filteredChips: [ChipEntry] {
        let chips = ChipLibrary.chips.filter { $0.category == selectedCategory }
        if searchText.isEmpty { return chips }
        let query = searchText.lowercased()
        return chips.filter {
            $0.name.lowercased().contains(query) ||
            $0.manufacturer.lowercased().contains(query)
        }
    }

    private var groupedChips: [(String, [ChipEntry])] {
        Dictionary(grouping: filteredChips, by: \.manufacturer)
            .sorted { $0.key < $1.key }
    }

    private var totalForCategory: Int {
        ChipLibrary.chips.filter { $0.category == selectedCategory }.count
    }

    var body: some View {
        VStack(spacing: 0) {
            // Header
            HStack {
                Text("Select Device")
                    .font(.headline)
                Text("(\(totalForCategory) chips)")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Spacer()
                Button("Cancel") { onCancel() }
                    .keyboardShortcut(.cancelAction)
            }
            .padding()

            // Category picker + search
            HStack(spacing: 12) {
                Picker("Type", selection: $selectedCategory) {
                    ForEach(ChipCategory.allCases) { cat in
                        Label(cat.rawValue, systemImage: cat.icon).tag(cat)
                    }
                }
                .pickerStyle(.segmented)
                .frame(width: 260)

                TextField("Search \(totalForCategory) chips...", text: $searchText)
                    .textFieldStyle(.roundedBorder)
            }
            .padding(.horizontal)
            .padding(.bottom, 8)

            Divider()

            // Chip list
            List {
                // Recently used section
                let recentForCat = recentChips.filter { $0.category == selectedCategory }
                if !recentForCat.isEmpty && searchText.isEmpty {
                    Section("Recently Used") {
                        ForEach(recentForCat.prefix(5)) { chip in
                            chipRow(chip, isRecent: true)
                                .contentShape(Rectangle())
                                .onTapGesture { selectChip(chip) }
                        }
                    }
                }

                // All chips grouped by manufacturer
                ForEach(groupedChips, id: \.0) { manufacturer, chips in
                    Section("\(manufacturer) (\(chips.count))") {
                        ForEach(chips) { chip in
                            chipRow(chip, isRecent: false)
                                .contentShape(Rectangle())
                                .onTapGesture { selectChip(chip) }
                        }
                    }
                }
            }
            .listStyle(.inset(alternatesRowBackgrounds: true))
        }
        .frame(width: 600, height: 520)
    }

    private func selectChip(_ chip: ChipEntry) {
        // Save to recent
        var recents = (UserDefaults.standard.array(forKey: "recentChips") as? [String]) ?? []
        recents.removeAll { $0 == chip.id }
        recents.insert(chip.id, at: 0)
        if recents.count > 5 { recents = Array(recents.prefix(5)) }
        UserDefaults.standard.set(recents, forKey: "recentChips")

        onSelect(chip)
    }

    @ViewBuilder
    private func chipRow(_ chip: ChipEntry, isRecent: Bool) -> some View {
        HStack(spacing: 8) {
            if isRecent {
                Image(systemName: "clock.arrow.circlepath")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }

            Text(chip.name)
                .font(.system(.body, design: .monospaced))
                .fontWeight(.medium)

            Text(chip.manufacturer)
                .font(.caption)
                .foregroundStyle(.tertiary)

            Spacer()

            Text(formatSize(chip.capacity))
                .font(.system(.caption, design: .monospaced))
                .foregroundStyle(.secondary)

            if let addr = chip.i2cAddress {
                Text(String(format: "0x%02X", addr))
                    .font(.system(.caption2, design: .monospaced))
                    .padding(.horizontal, 4)
                    .padding(.vertical, 1)
                    .background(.cyan.opacity(0.15))
                    .cornerRadius(3)
            }
        }
        .padding(.vertical, 1)
    }

    private func formatSize(_ bytes: Int) -> String {
        if bytes >= 1_048_576 { return "\(bytes / 1_048_576) MB" }
        if bytes >= 1024 { return "\(bytes / 1024) KB" }
        return "\(bytes) B"
    }
}

// MARK: - Chip Library


// MARK: - Chip Library (489 SPI flash + 32 I2C EEPROM + 11 SPI EEPROM)

enum ChipLibrary {
    static let chips: [ChipEntry] = spiFlashChips + spiEEPROMChips + spiFramChips + i2cEEPROMChips + i2cFramChips

    // MARK: - SPI Flash (489 chips, 27 manufacturers)
    static let spiFlashChips: [ChipEntry] = [
    // MARK: - AMIC
    ChipEntry(name: "A25L010", manufacturer: "AMIC", capacity: 131072, category: .spiFlash),
    ChipEntry(name: "A25L016", manufacturer: "AMIC", capacity: 2097152, category: .spiFlash),
    ChipEntry(name: "A25L020", manufacturer: "AMIC", capacity: 262144, category: .spiFlash),
    ChipEntry(name: "A25L032", manufacturer: "AMIC", capacity: 4194304, category: .spiFlash),
    ChipEntry(name: "A25L040", manufacturer: "AMIC", capacity: 524288, category: .spiFlash),
    ChipEntry(name: "A25L05PT", manufacturer: "AMIC", capacity: 65536, category: .spiFlash),
    ChipEntry(name: "A25L05PU", manufacturer: "AMIC", capacity: 65536, category: .spiFlash),
    ChipEntry(name: "A25L080", manufacturer: "AMIC", capacity: 1048576, category: .spiFlash),
    ChipEntry(name: "A25L10PT", manufacturer: "AMIC", capacity: 131072, category: .spiFlash),
    ChipEntry(name: "A25L10PU", manufacturer: "AMIC", capacity: 131072, category: .spiFlash),
    ChipEntry(name: "A25L16PT", manufacturer: "AMIC", capacity: 2097152, category: .spiFlash),
    ChipEntry(name: "A25L16PU", manufacturer: "AMIC", capacity: 2097152, category: .spiFlash),
    ChipEntry(name: "A25L20PT", manufacturer: "AMIC", capacity: 262144, category: .spiFlash),
    ChipEntry(name: "A25L20PU", manufacturer: "AMIC", capacity: 262144, category: .spiFlash),
    ChipEntry(name: "A25L40PT", manufacturer: "AMIC", capacity: 524288, category: .spiFlash),
    ChipEntry(name: "A25L40PU", manufacturer: "AMIC", capacity: 524288, category: .spiFlash),
    ChipEntry(name: "A25L512", manufacturer: "AMIC", capacity: 65536, category: .spiFlash),
    ChipEntry(name: "A25L80P", manufacturer: "AMIC", capacity: 1048576, category: .spiFlash),
    ChipEntry(name: "A25LQ032/A25LQ32A", manufacturer: "AMIC", capacity: 4194304, category: .spiFlash),
    ChipEntry(name: "A25LQ16", manufacturer: "AMIC", capacity: 2097152, category: .spiFlash),
    ChipEntry(name: "A25LQ64", manufacturer: "AMIC", capacity: 8388608, category: .spiFlash),

    // MARK: - Atmel
    ChipEntry(name: "AT25DF011", manufacturer: "Atmel", capacity: 131072, category: .spiFlash),
    ChipEntry(name: "AT25DF021", manufacturer: "Atmel", capacity: 262144, category: .spiFlash),
    ChipEntry(name: "AT25DF021A", manufacturer: "Atmel", capacity: 262144, category: .spiFlash),
    ChipEntry(name: "AT25DF041A", manufacturer: "Atmel", capacity: 524288, category: .spiFlash),
    ChipEntry(name: "AT25DF081", manufacturer: "Atmel", capacity: 1048576, category: .spiFlash),
    ChipEntry(name: "AT25DF081A", manufacturer: "Atmel", capacity: 1048576, category: .spiFlash),
    ChipEntry(name: "AT25DF161", manufacturer: "Atmel", capacity: 2097152, category: .spiFlash),
    ChipEntry(name: "AT25DF321", manufacturer: "Atmel", capacity: 4194304, category: .spiFlash),
    ChipEntry(name: "AT25DF321A", manufacturer: "Atmel", capacity: 4194304, category: .spiFlash),
    ChipEntry(name: "AT25DF641(A)", manufacturer: "Atmel", capacity: 8388608, category: .spiFlash),
    ChipEntry(name: "AT25DL081", manufacturer: "Atmel", capacity: 1048576, category: .spiFlash),
    ChipEntry(name: "AT25DL161", manufacturer: "Atmel", capacity: 2097152, category: .spiFlash),
    ChipEntry(name: "AT25DQ161", manufacturer: "Atmel", capacity: 2097152, category: .spiFlash),
    ChipEntry(name: "AT25F1024(A)", manufacturer: "Atmel", capacity: 131072, category: .spiFlash),
    ChipEntry(name: "AT25F2048", manufacturer: "Atmel", capacity: 262144, category: .spiFlash),
    ChipEntry(name: "AT25F4096", manufacturer: "Atmel", capacity: 524288, category: .spiFlash),
    ChipEntry(name: "AT25F512", manufacturer: "Atmel", capacity: 65536, category: .spiFlash),
    ChipEntry(name: "AT25F512A", manufacturer: "Atmel", capacity: 65536, category: .spiFlash),
    ChipEntry(name: "AT25F512B", manufacturer: "Atmel", capacity: 65536, category: .spiFlash),
    ChipEntry(name: "AT25FS010", manufacturer: "Atmel", capacity: 131072, category: .spiFlash),
    ChipEntry(name: "AT25FS040", manufacturer: "Atmel", capacity: 524288, category: .spiFlash),
    ChipEntry(name: "AT25SF041", manufacturer: "Atmel", capacity: 524288, category: .spiFlash),
    ChipEntry(name: "AT25SF081", manufacturer: "Atmel", capacity: 1048576, category: .spiFlash),
    ChipEntry(name: "AT25SF128A", manufacturer: "Atmel", capacity: 16777216, category: .spiFlash),
    ChipEntry(name: "AT25SF161", manufacturer: "Atmel", capacity: 2097152, category: .spiFlash),
    ChipEntry(name: "AT25SF321", manufacturer: "Atmel", capacity: 4194304, category: .spiFlash),
    ChipEntry(name: "AT25SL128A", manufacturer: "Atmel", capacity: 16777216, category: .spiFlash),
    ChipEntry(name: "AT26DF041", manufacturer: "Atmel", capacity: 524288, category: .spiFlash),
    ChipEntry(name: "AT26DF081A", manufacturer: "Atmel", capacity: 1048576, category: .spiFlash),
    ChipEntry(name: "AT26DF161", manufacturer: "Atmel", capacity: 2097152, category: .spiFlash),
    ChipEntry(name: "AT26DF161A", manufacturer: "Atmel", capacity: 2097152, category: .spiFlash),
    ChipEntry(name: "AT26F004", manufacturer: "Atmel", capacity: 524288, category: .spiFlash),
    ChipEntry(name: "AT45CS1282", manufacturer: "Atmel", capacity: 17301504, category: .spiFlash),
    ChipEntry(name: "AT45DB011D", manufacturer: "Atmel", capacity: 131072, category: .spiFlash),
    ChipEntry(name: "AT45DB021D", manufacturer: "Atmel", capacity: 262144, category: .spiFlash),
    ChipEntry(name: "AT45DB041D", manufacturer: "Atmel", capacity: 524288, category: .spiFlash),
    ChipEntry(name: "AT45DB081D", manufacturer: "Atmel", capacity: 1048576, category: .spiFlash),
    ChipEntry(name: "AT45DB161D", manufacturer: "Atmel", capacity: 2097152, category: .spiFlash),
    ChipEntry(name: "AT45DB321C", manufacturer: "Atmel", capacity: 4325376, category: .spiFlash),
    ChipEntry(name: "AT45DB321D", manufacturer: "Atmel", capacity: 4194304, category: .spiFlash),
    ChipEntry(name: "AT45DB321E", manufacturer: "Atmel", capacity: 4194304, category: .spiFlash),
    ChipEntry(name: "AT45DB642D", manufacturer: "Atmel", capacity: 8388608, category: .spiFlash),
    ChipEntry(name: "AT45DB641E", manufacturer: "Atmel", capacity: 8388608, category: .spiFlash),

    // MARK: - Boya/BoHong Microelectronics
    ChipEntry(name: "B.25D16A", manufacturer: "Boya/BoHong Microelectronics", capacity: 2097152, category: .spiFlash),
    ChipEntry(name: "B.25D80A", manufacturer: "Boya/BoHong Microelectronics", capacity: 1048576, category: .spiFlash),
    ChipEntry(name: "B.25Q64AS", manufacturer: "Boya/BoHong Microelectronics", capacity: 8388608, category: .spiFlash),
    ChipEntry(name: "B.25Q128AS", manufacturer: "Boya/BoHong Microelectronics", capacity: 16777216, category: .spiFlash),

    // MARK: - ENE
    ChipEntry(name: "KB9012 (EDI)", manufacturer: "ENE", capacity: 131072, category: .spiFlash),

    // MARK: - Eon
    ChipEntry(name: "EN25B05", manufacturer: "Eon", capacity: 65536, category: .spiFlash),
    ChipEntry(name: "EN25B05T", manufacturer: "Eon", capacity: 65536, category: .spiFlash),
    ChipEntry(name: "EN25B10", manufacturer: "Eon", capacity: 131072, category: .spiFlash),
    ChipEntry(name: "EN25B10T", manufacturer: "Eon", capacity: 131072, category: .spiFlash),
    ChipEntry(name: "EN25B16", manufacturer: "Eon", capacity: 2097152, category: .spiFlash),
    ChipEntry(name: "EN25B16T", manufacturer: "Eon", capacity: 2097152, category: .spiFlash),
    ChipEntry(name: "EN25B20", manufacturer: "Eon", capacity: 262144, category: .spiFlash),
    ChipEntry(name: "EN25B20T", manufacturer: "Eon", capacity: 262144, category: .spiFlash),
    ChipEntry(name: "EN25B32", manufacturer: "Eon", capacity: 4194304, category: .spiFlash),
    ChipEntry(name: "EN25B32T", manufacturer: "Eon", capacity: 4194304, category: .spiFlash),
    ChipEntry(name: "EN25B40", manufacturer: "Eon", capacity: 524288, category: .spiFlash),
    ChipEntry(name: "EN25B40T", manufacturer: "Eon", capacity: 524288, category: .spiFlash),
    ChipEntry(name: "EN25B64", manufacturer: "Eon", capacity: 8388608, category: .spiFlash),
    ChipEntry(name: "EN25B64T", manufacturer: "Eon", capacity: 8388608, category: .spiFlash),
    ChipEntry(name: "EN25B80", manufacturer: "Eon", capacity: 1048576, category: .spiFlash),
    ChipEntry(name: "EN25B80T", manufacturer: "Eon", capacity: 1048576, category: .spiFlash),
    ChipEntry(name: "EN25F05", manufacturer: "Eon", capacity: 65536, category: .spiFlash),
    ChipEntry(name: "EN25F10", manufacturer: "Eon", capacity: 131072, category: .spiFlash),
    ChipEntry(name: "EN25F16", manufacturer: "Eon", capacity: 2097152, category: .spiFlash),
    ChipEntry(name: "EN25F20", manufacturer: "Eon", capacity: 262144, category: .spiFlash),
    ChipEntry(name: "EN25F32", manufacturer: "Eon", capacity: 4194304, category: .spiFlash),
    ChipEntry(name: "EN25F40", manufacturer: "Eon", capacity: 524288, category: .spiFlash),
    ChipEntry(name: "EN25F64", manufacturer: "Eon", capacity: 8388608, category: .spiFlash),
    ChipEntry(name: "EN25F80", manufacturer: "Eon", capacity: 1048576, category: .spiFlash),
    ChipEntry(name: "EN25P05", manufacturer: "Eon", capacity: 65536, category: .spiFlash),
    ChipEntry(name: "EN25P10", manufacturer: "Eon", capacity: 131072, category: .spiFlash),
    ChipEntry(name: "EN25P16", manufacturer: "Eon", capacity: 2097152, category: .spiFlash),
    ChipEntry(name: "EN25P20", manufacturer: "Eon", capacity: 262144, category: .spiFlash),
    ChipEntry(name: "EN25P32", manufacturer: "Eon", capacity: 4194304, category: .spiFlash),
    ChipEntry(name: "EN25P40", manufacturer: "Eon", capacity: 524288, category: .spiFlash),
    ChipEntry(name: "EN25P64", manufacturer: "Eon", capacity: 8388608, category: .spiFlash),
    ChipEntry(name: "EN25P80", manufacturer: "Eon", capacity: 1048576, category: .spiFlash),
    ChipEntry(name: "EN25Q128", manufacturer: "Eon", capacity: 16777216, category: .spiFlash),
    ChipEntry(name: "EN25Q16", manufacturer: "Eon", capacity: 2097152, category: .spiFlash),
    ChipEntry(name: "EN25Q32(A/B)", manufacturer: "Eon", capacity: 4194304, category: .spiFlash),
    ChipEntry(name: "EN25Q40", manufacturer: "Eon", capacity: 524288, category: .spiFlash),
    ChipEntry(name: "EN25Q64", manufacturer: "Eon", capacity: 8388608, category: .spiFlash),
    ChipEntry(name: "EN25Q80(A)", manufacturer: "Eon", capacity: 1048576, category: .spiFlash),
    ChipEntry(name: "EN25QH128", manufacturer: "Eon", capacity: 16777216, category: .spiFlash),
    ChipEntry(name: "EN25QH16", manufacturer: "Eon", capacity: 2097152, category: .spiFlash),
    ChipEntry(name: "EN25QH32", manufacturer: "Eon", capacity: 4194304, category: .spiFlash),
    ChipEntry(name: "EN25QH32B", manufacturer: "Eon", capacity: 4194304, category: .spiFlash),
    ChipEntry(name: "EN25QH64", manufacturer: "Eon", capacity: 8388608, category: .spiFlash),
    ChipEntry(name: "EN25QH64A", manufacturer: "Eon", capacity: 8388608, category: .spiFlash),
    ChipEntry(name: "EN25QX128A", manufacturer: "Eon", capacity: 16777216, category: .spiFlash),
    ChipEntry(name: "EN25S10", manufacturer: "Eon", capacity: 131072, category: .spiFlash),
    ChipEntry(name: "EN25S16", manufacturer: "Eon", capacity: 2097152, category: .spiFlash),
    ChipEntry(name: "EN25S20", manufacturer: "Eon", capacity: 262144, category: .spiFlash),
    ChipEntry(name: "EN25S32", manufacturer: "Eon", capacity: 4194304, category: .spiFlash),
    ChipEntry(name: "EN25S40", manufacturer: "Eon", capacity: 524288, category: .spiFlash),
    ChipEntry(name: "EN25S64", manufacturer: "Eon", capacity: 8388608, category: .spiFlash),
    ChipEntry(name: "EN25S80", manufacturer: "Eon", capacity: 1048576, category: .spiFlash),

    // MARK: - ESI
    ChipEntry(name: "ES25P16", manufacturer: "ESI", capacity: 2097152, category: .spiFlash),
    ChipEntry(name: "ES25P40", manufacturer: "ESI", capacity: 524288, category: .spiFlash),
    ChipEntry(name: "ES25P80", manufacturer: "ESI", capacity: 1048576, category: .spiFlash),

    // MARK: - ESMT
    ChipEntry(name: "F25L008A", manufacturer: "ESMT", capacity: 1048576, category: .spiFlash),
    ChipEntry(name: "F25L32PA", manufacturer: "ESMT", capacity: 4194304, category: .spiFlash),

    // MARK: - Fudan
    ChipEntry(name: "FM25F005", manufacturer: "Fudan", capacity: 65536, category: .spiFlash),
    ChipEntry(name: "FM25F01", manufacturer: "Fudan", capacity: 131072, category: .spiFlash),
    ChipEntry(name: "FM25F02(A)", manufacturer: "Fudan", capacity: 262144, category: .spiFlash),
    ChipEntry(name: "FM25F04(A)", manufacturer: "Fudan", capacity: 524288, category: .spiFlash),
    ChipEntry(name: "FM25Q04", manufacturer: "Fudan", capacity: 524288, category: .spiFlash),
    ChipEntry(name: "FM25Q08", manufacturer: "Fudan", capacity: 1048576, category: .spiFlash),
    ChipEntry(name: "FM25Q16", manufacturer: "Fudan", capacity: 2097152, category: .spiFlash),
    ChipEntry(name: "FM25Q32", manufacturer: "Fudan", capacity: 4194304, category: .spiFlash),
    ChipEntry(name: "FM25Q64", manufacturer: "Fudan", capacity: 8388608, category: .spiFlash),
    ChipEntry(name: "FM25Q128", manufacturer: "Fudan", capacity: 16777216, category: .spiFlash),

    // MARK: - GigaDevice
    ChipEntry(name: "GD25B128B/GD25Q128B", manufacturer: "GigaDevice", capacity: 16777216, category: .spiFlash),
    ChipEntry(name: "GD25LF128E", manufacturer: "GigaDevice", capacity: 16777216, category: .spiFlash),
    ChipEntry(name: "GD25LF256F", manufacturer: "GigaDevice", capacity: 33554432, category: .spiFlash),
    ChipEntry(name: "GD25LF512MF", manufacturer: "GigaDevice", capacity: 67108864, category: .spiFlash),
    ChipEntry(name: "GD25LQ128E/GD25LB128E/GD25LR128E/GD25LQ128D/GD25LQ128C", manufacturer: "GigaDevice", capacity: 16777216, category: .spiFlash),
    ChipEntry(name: "GD25LQ255E", manufacturer: "GigaDevice", capacity: 33554432, category: .spiFlash),
    ChipEntry(name: "GD25LQ16", manufacturer: "GigaDevice", capacity: 2097152, category: .spiFlash),
    ChipEntry(name: "GD25LQ32", manufacturer: "GigaDevice", capacity: 4194304, category: .spiFlash),
    ChipEntry(name: "GD25LQ40", manufacturer: "GigaDevice", capacity: 524288, category: .spiFlash),
    ChipEntry(name: "GD25LQ64(B)", manufacturer: "GigaDevice", capacity: 8388608, category: .spiFlash),
    ChipEntry(name: "GD25LQ80", manufacturer: "GigaDevice", capacity: 1048576, category: .spiFlash),
    ChipEntry(name: "GD25LB256E/GD25LR256E", manufacturer: "GigaDevice", capacity: 33554432, category: .spiFlash),
    ChipEntry(name: "GD25LB256F/GD25LR256F", manufacturer: "GigaDevice", capacity: 33554432, category: .spiFlash),
    ChipEntry(name: "GD25LB512MF/GD25LR512MF", manufacturer: "GigaDevice", capacity: 67108864, category: .spiFlash),
    ChipEntry(name: "GD25LB512ME/GD25LR512ME", manufacturer: "GigaDevice", capacity: 67108864, category: .spiFlash),
    ChipEntry(name: "GD25Q10", manufacturer: "GigaDevice", capacity: 131072, category: .spiFlash),
    ChipEntry(name: "GD25Q128E/GD25B128E/GD25R128E/GD25Q127C", manufacturer: "GigaDevice", capacity: 16777216, category: .spiFlash),
    ChipEntry(name: "GD25Q128C", manufacturer: "GigaDevice", capacity: 16777216, category: .spiFlash),
    ChipEntry(name: "GD25Q16(B)", manufacturer: "GigaDevice", capacity: 2097152, category: .spiFlash),
    ChipEntry(name: "GD25Q20(B)", manufacturer: "GigaDevice", capacity: 262144, category: .spiFlash),
    ChipEntry(name: "GD25Q256E/GD25B256E/GD25R256E/GD25Q256D", manufacturer: "GigaDevice", capacity: 33554432, category: .spiFlash),
    ChipEntry(name: "GD25Q32(B)", manufacturer: "GigaDevice", capacity: 4194304, category: .spiFlash),
    ChipEntry(name: "GD25Q40(B)", manufacturer: "GigaDevice", capacity: 524288, category: .spiFlash),
    ChipEntry(name: "GD25Q512", manufacturer: "GigaDevice", capacity: 65536, category: .spiFlash),
    ChipEntry(name: "GD25Q64(B)", manufacturer: "GigaDevice", capacity: 8388608, category: .spiFlash),
    ChipEntry(name: "GD25Q80(B)", manufacturer: "GigaDevice", capacity: 1048576, category: .spiFlash),
    ChipEntry(name: "GD25T80", manufacturer: "GigaDevice", capacity: 1048576, category: .spiFlash),
    ChipEntry(name: "GD25VQ16C", manufacturer: "GigaDevice", capacity: 2097152, category: .spiFlash),
    ChipEntry(name: "GD25VQ21B", manufacturer: "GigaDevice", capacity: 262144, category: .spiFlash),
    ChipEntry(name: "GD25VQ40C", manufacturer: "GigaDevice", capacity: 524288, category: .spiFlash),
    ChipEntry(name: "GD25VQ41B", manufacturer: "GigaDevice", capacity: 524288, category: .spiFlash),
    ChipEntry(name: "GD25VQ80C", manufacturer: "GigaDevice", capacity: 1048576, category: .spiFlash),
    ChipEntry(name: "GD25F256F", manufacturer: "GigaDevice", capacity: 33554432, category: .spiFlash),
    ChipEntry(name: "GD25WQ80E", manufacturer: "GigaDevice", capacity: 1048576, category: .spiFlash),

    // MARK: - Intel
    ChipEntry(name: "25F160S33B8", manufacturer: "Intel", capacity: 2097152, category: .spiFlash),
    ChipEntry(name: "25F160S33T8", manufacturer: "Intel", capacity: 2097152, category: .spiFlash),
    ChipEntry(name: "25F320S33B8", manufacturer: "Intel", capacity: 4194304, category: .spiFlash),
    ChipEntry(name: "25F320S33T8", manufacturer: "Intel", capacity: 4194304, category: .spiFlash),
    ChipEntry(name: "25F640S33B8", manufacturer: "Intel", capacity: 8388608, category: .spiFlash),
    ChipEntry(name: "25F640S33T8", manufacturer: "Intel", capacity: 8388608, category: .spiFlash),

    // MARK: - ISSI
    ChipEntry(name: "IS25LP016", manufacturer: "ISSI", capacity: 2097152, category: .spiFlash),
    ChipEntry(name: "IS25LP064", manufacturer: "ISSI", capacity: 8388608, category: .spiFlash),
    ChipEntry(name: "IS25LP128", manufacturer: "ISSI", capacity: 16777216, category: .spiFlash),
    ChipEntry(name: "IS25LP256", manufacturer: "ISSI", capacity: 33554432, category: .spiFlash),
    ChipEntry(name: "IS25LQ016", manufacturer: "ISSI", capacity: 2097152, category: .spiFlash),
    ChipEntry(name: "IS25WP016", manufacturer: "ISSI", capacity: 2097152, category: .spiFlash),
    ChipEntry(name: "IS25WP020", manufacturer: "ISSI", capacity: 262144, category: .spiFlash),
    ChipEntry(name: "IS25WP032", manufacturer: "ISSI", capacity: 4194304, category: .spiFlash),
    ChipEntry(name: "IS25WP040", manufacturer: "ISSI", capacity: 524288, category: .spiFlash),
    ChipEntry(name: "IS25WP064", manufacturer: "ISSI", capacity: 8388608, category: .spiFlash),
    ChipEntry(name: "IS25WP080", manufacturer: "ISSI", capacity: 1048576, category: .spiFlash),
    ChipEntry(name: "IS25WP128", manufacturer: "ISSI", capacity: 16777216, category: .spiFlash),
    ChipEntry(name: "IS25WP256", manufacturer: "ISSI", capacity: 33554432, category: .spiFlash),
    ChipEntry(name: "IS25WQ040", manufacturer: "ISSI", capacity: 524288, category: .spiFlash),

    // MARK: - Macronix
    ChipEntry(name: "MX23L12854", manufacturer: "Macronix", capacity: 16777216, category: .spiFlash),
    ChipEntry(name: "MX23L1654", manufacturer: "Macronix", capacity: 2097152, category: .spiFlash),
    ChipEntry(name: "MX23L3254", manufacturer: "Macronix", capacity: 4194304, category: .spiFlash),
    ChipEntry(name: "MX23L6454", manufacturer: "Macronix", capacity: 8388608, category: .spiFlash),
    ChipEntry(name: "MX25L1005(C)/MX25L1006E", manufacturer: "Macronix", capacity: 131072, category: .spiFlash),
    ChipEntry(name: "MX25L12805D", manufacturer: "Macronix", capacity: 16777216, category: .spiFlash),
    ChipEntry(name: "MX25L12833F", manufacturer: "Macronix", capacity: 16777216, category: .spiFlash),
    ChipEntry(name: "MX25L12835F/MX25L12873F", manufacturer: "Macronix", capacity: 16777216, category: .spiFlash),
    ChipEntry(name: "MX25L12845E/MX25L12865E", manufacturer: "Macronix", capacity: 16777216, category: .spiFlash),
    ChipEntry(name: "MX25L12850F", manufacturer: "Macronix", capacity: 16777216, category: .spiFlash),
    ChipEntry(name: "MX25L1605", manufacturer: "Macronix", capacity: 2097152, category: .spiFlash),
    ChipEntry(name: "MX25V16066", manufacturer: "Macronix", capacity: 2097152, category: .spiFlash),
    ChipEntry(name: "MX25L1605A/MX25L1606E/MX25L1608E", manufacturer: "Macronix", capacity: 2097152, category: .spiFlash),
    ChipEntry(name: "MX25L1605D/MX25L1608D/MX25L1673E", manufacturer: "Macronix", capacity: 2097152, category: .spiFlash),
    ChipEntry(name: "MX25L1635D", manufacturer: "Macronix", capacity: 2097152, category: .spiFlash),
    ChipEntry(name: "MX25L1633E", manufacturer: "Macronix", capacity: 2097152, category: .spiFlash),
    ChipEntry(name: "MX25L1635E/MX25L1636E", manufacturer: "Macronix", capacity: 2097152, category: .spiFlash),
    ChipEntry(name: "MX25L2005(C)/MX25L2006E", manufacturer: "Macronix", capacity: 262144, category: .spiFlash),
    ChipEntry(name: "MX25L25635F/MX25L25645G", manufacturer: "Macronix", capacity: 33554432, category: .spiFlash),
    ChipEntry(name: "MX25L3205(A)", manufacturer: "Macronix", capacity: 4194304, category: .spiFlash),
    ChipEntry(name: "MX25L3205D/MX25L3208D", manufacturer: "Macronix", capacity: 4194304, category: .spiFlash),
    ChipEntry(name: "MX25L3206E/MX25L3208E", manufacturer: "Macronix", capacity: 4194304, category: .spiFlash),
    ChipEntry(name: "MX25L3235D", manufacturer: "Macronix", capacity: 4194304, category: .spiFlash),
    ChipEntry(name: "MX25L3233F/MX25L3273E", manufacturer: "Macronix", capacity: 4194304, category: .spiFlash),
    ChipEntry(name: "MX25L3255E", manufacturer: "Macronix", capacity: 4194304, category: .spiFlash),
    ChipEntry(name: "MX25L4005(A/C)/MX25L4006E", manufacturer: "Macronix", capacity: 524288, category: .spiFlash),
    ChipEntry(name: "MX25L512(E)/MX25V512(C)", manufacturer: "Macronix", capacity: 65536, category: .spiFlash),
    ChipEntry(name: "MX25L5121E", manufacturer: "Macronix", capacity: 65536, category: .spiFlash),
    ChipEntry(name: "MX25L6405", manufacturer: "Macronix", capacity: 8388608, category: .spiFlash),
    ChipEntry(name: "MX25L6405D", manufacturer: "Macronix", capacity: 8388608, category: .spiFlash),
    ChipEntry(name: "MX25L6406E/MX25L6408E", manufacturer: "Macronix", capacity: 8388608, category: .spiFlash),
    ChipEntry(name: "MX25L6436E/MX25L6445E/MX25L6465E", manufacturer: "Macronix", capacity: 8388608, category: .spiFlash),
    ChipEntry(name: "MX25L6473E", manufacturer: "Macronix", capacity: 8388608, category: .spiFlash),
    ChipEntry(name: "MX25L6473F", manufacturer: "Macronix", capacity: 8388608, category: .spiFlash),
    ChipEntry(name: "MX25L6495F", manufacturer: "Macronix", capacity: 8388608, category: .spiFlash),
    ChipEntry(name: "MX25L8005/MX25L8006E/MX25L8008E/MX25V8005", manufacturer: "Macronix", capacity: 1048576, category: .spiFlash),
    ChipEntry(name: "MX25R512F", manufacturer: "Macronix", capacity: 65536, category: .spiFlash),
    ChipEntry(name: "MX25R1035F", manufacturer: "Macronix", capacity: 131072, category: .spiFlash),
    ChipEntry(name: "MX25R1635F", manufacturer: "Macronix", capacity: 2097152, category: .spiFlash),
    ChipEntry(name: "MX25R2035F", manufacturer: "Macronix", capacity: 262144, category: .spiFlash),
    ChipEntry(name: "MX25R3235F", manufacturer: "Macronix", capacity: 4194304, category: .spiFlash),
    ChipEntry(name: "MX25R4035F", manufacturer: "Macronix", capacity: 524288, category: .spiFlash),
    ChipEntry(name: "MX25R6435F", manufacturer: "Macronix", capacity: 8388608, category: .spiFlash),
    ChipEntry(name: "MX25R8035F", manufacturer: "Macronix", capacity: 1048576, category: .spiFlash),
    ChipEntry(name: "MX25V4035F", manufacturer: "Macronix", capacity: 524288, category: .spiFlash),
    ChipEntry(name: "MX25V8035F", manufacturer: "Macronix", capacity: 1048576, category: .spiFlash),
    ChipEntry(name: "MX25V1635F", manufacturer: "Macronix", capacity: 2097152, category: .spiFlash),
    ChipEntry(name: "MX25U12835F/MX25U12873F", manufacturer: "Macronix", capacity: 16777216, category: .spiFlash),
    ChipEntry(name: "MX25U1635E", manufacturer: "Macronix", capacity: 2097152, category: .spiFlash),
    ChipEntry(name: "MX25U25635F", manufacturer: "Macronix", capacity: 33554432, category: .spiFlash),
    ChipEntry(name: "MX25U25643G", manufacturer: "Macronix", capacity: 33554432, category: .spiFlash),
    ChipEntry(name: "MX25U25645G", manufacturer: "Macronix", capacity: 33554432, category: .spiFlash),
    ChipEntry(name: "MX25U3235E/F", manufacturer: "Macronix", capacity: 4194304, category: .spiFlash),
    ChipEntry(name: "MX25U51245G", manufacturer: "Macronix", capacity: 67108864, category: .spiFlash),
    ChipEntry(name: "MX25U6435E/F", manufacturer: "Macronix", capacity: 8388608, category: .spiFlash),
    ChipEntry(name: "MX25U8032E", manufacturer: "Macronix", capacity: 1048576, category: .spiFlash),
    ChipEntry(name: "MX66L51235F/MX25L51245G", manufacturer: "Macronix", capacity: 67108864, category: .spiFlash),
    ChipEntry(name: "MX66L1G45G", manufacturer: "Macronix", capacity: 134217728, category: .spiFlash),
    ChipEntry(name: "MX66L2G45G", manufacturer: "Macronix", capacity: 268435456, category: .spiFlash),
    ChipEntry(name: "MX66U1G45G", manufacturer: "Macronix", capacity: 134217728, category: .spiFlash),
    ChipEntry(name: "MX66U2G45G", manufacturer: "Macronix", capacity: 268435456, category: .spiFlash),
    ChipEntry(name: "MX77L25650F", manufacturer: "Macronix", capacity: 33554432, category: .spiFlash),
    ChipEntry(name: "MX77U25650F", manufacturer: "Macronix", capacity: 33554432, category: .spiFlash),
    ChipEntry(name: "MX77U51250F", manufacturer: "Macronix", capacity: 67108864, category: .spiFlash),

    // MARK: - Micron/Numonyx/ST
    ChipEntry(name: "M25P05", manufacturer: "Micron/Numonyx/ST", capacity: 65536, category: .spiFlash),
    ChipEntry(name: "M25P05-A", manufacturer: "Micron/Numonyx/ST", capacity: 65536, category: .spiFlash),
    ChipEntry(name: "M25P10", manufacturer: "Micron/Numonyx/ST", capacity: 131072, category: .spiFlash),
    ChipEntry(name: "M25P10-A", manufacturer: "Micron/Numonyx/ST", capacity: 131072, category: .spiFlash),
    ChipEntry(name: "M25P128", manufacturer: "Micron/Numonyx/ST", capacity: 16777216, category: .spiFlash),
    ChipEntry(name: "M25P16", manufacturer: "Micron/Numonyx/ST", capacity: 2097152, category: .spiFlash),
    ChipEntry(name: "M25P20", manufacturer: "Micron/Numonyx/ST", capacity: 262144, category: .spiFlash),
    ChipEntry(name: "M25P20-old", manufacturer: "Micron/Numonyx/ST", capacity: 262144, category: .spiFlash),
    ChipEntry(name: "M25P32", manufacturer: "Micron/Numonyx/ST", capacity: 4194304, category: .spiFlash),
    ChipEntry(name: "M25P40", manufacturer: "Micron/Numonyx/ST", capacity: 524288, category: .spiFlash),
    ChipEntry(name: "M25P40-old", manufacturer: "Micron/Numonyx/ST", capacity: 524288, category: .spiFlash),
    ChipEntry(name: "M25P64", manufacturer: "Micron/Numonyx/ST", capacity: 8388608, category: .spiFlash),
    ChipEntry(name: "M25P80", manufacturer: "Micron/Numonyx/ST", capacity: 1048576, category: .spiFlash),
    ChipEntry(name: "M25PE10", manufacturer: "Micron/Numonyx/ST", capacity: 131072, category: .spiFlash),
    ChipEntry(name: "M25PE16", manufacturer: "Micron/Numonyx/ST", capacity: 2097152, category: .spiFlash),
    ChipEntry(name: "M25PE20", manufacturer: "Micron/Numonyx/ST", capacity: 262144, category: .spiFlash),
    ChipEntry(name: "M25PE40", manufacturer: "Micron/Numonyx/ST", capacity: 524288, category: .spiFlash),
    ChipEntry(name: "M25PE80", manufacturer: "Micron/Numonyx/ST", capacity: 1048576, category: .spiFlash),
    ChipEntry(name: "M25PX16", manufacturer: "Micron/Numonyx/ST", capacity: 2097152, category: .spiFlash),
    ChipEntry(name: "M25PX32", manufacturer: "Micron/Numonyx/ST", capacity: 4194304, category: .spiFlash),
    ChipEntry(name: "M25PX64", manufacturer: "Micron/Numonyx/ST", capacity: 8388608, category: .spiFlash),
    ChipEntry(name: "M25PX80", manufacturer: "Micron/Numonyx/ST", capacity: 1048576, category: .spiFlash),
    ChipEntry(name: "M45PE10", manufacturer: "Micron/Numonyx/ST", capacity: 131072, category: .spiFlash),
    ChipEntry(name: "M45PE16", manufacturer: "Micron/Numonyx/ST", capacity: 2097152, category: .spiFlash),
    ChipEntry(name: "M45PE20", manufacturer: "Micron/Numonyx/ST", capacity: 262144, category: .spiFlash),
    ChipEntry(name: "M45PE40", manufacturer: "Micron/Numonyx/ST", capacity: 524288, category: .spiFlash),
    ChipEntry(name: "M45PE80", manufacturer: "Micron/Numonyx/ST", capacity: 1048576, category: .spiFlash),
    ChipEntry(name: "N25Q00A..1G", manufacturer: "Micron/Numonyx/ST", capacity: 134217728, category: .spiFlash),
    ChipEntry(name: "N25Q00A..3G", manufacturer: "Micron/Numonyx/ST", capacity: 134217728, category: .spiFlash),
    ChipEntry(name: "N25Q016", manufacturer: "Micron/Numonyx/ST", capacity: 2097152, category: .spiFlash),
    ChipEntry(name: "N25Q032..1E", manufacturer: "Micron/Numonyx/ST", capacity: 4194304, category: .spiFlash),
    ChipEntry(name: "N25Q032..3E", manufacturer: "Micron/Numonyx/ST", capacity: 4194304, category: .spiFlash),
    ChipEntry(name: "N25Q064..1E", manufacturer: "Micron/Numonyx/ST", capacity: 8388608, category: .spiFlash),
    ChipEntry(name: "N25Q064..3E", manufacturer: "Micron/Numonyx/ST", capacity: 8388608, category: .spiFlash),
    ChipEntry(name: "N25Q128..1E", manufacturer: "Micron/Numonyx/ST", capacity: 16777216, category: .spiFlash),
    ChipEntry(name: "N25Q128..3E", manufacturer: "Micron/Numonyx/ST", capacity: 16777216, category: .spiFlash),
    ChipEntry(name: "N25Q256..1E", manufacturer: "Micron/Numonyx/ST", capacity: 33554432, category: .spiFlash),
    ChipEntry(name: "N25Q256..3E", manufacturer: "Micron/Numonyx/ST", capacity: 33554432, category: .spiFlash),
    ChipEntry(name: "N25Q512..1G", manufacturer: "Micron/Numonyx/ST", capacity: 67108864, category: .spiFlash),
    ChipEntry(name: "N25Q512..3G", manufacturer: "Micron/Numonyx/ST", capacity: 67108864, category: .spiFlash),

    // MARK: - Micron
    ChipEntry(name: "MT25QL01G", manufacturer: "Micron", capacity: 134217728, category: .spiFlash),
    ChipEntry(name: "MT25QU01G", manufacturer: "Micron", capacity: 134217728, category: .spiFlash),
    ChipEntry(name: "MT25QL02G", manufacturer: "Micron", capacity: 268435456, category: .spiFlash),
    ChipEntry(name: "MT25QU02G", manufacturer: "Micron", capacity: 268435456, category: .spiFlash),
    ChipEntry(name: "MT25QU128", manufacturer: "Micron", capacity: 16777216, category: .spiFlash),
    ChipEntry(name: "MT25QL128", manufacturer: "Micron", capacity: 16777216, category: .spiFlash),
    ChipEntry(name: "MT25QL256", manufacturer: "Micron", capacity: 33554432, category: .spiFlash),
    ChipEntry(name: "MT25QU256", manufacturer: "Micron", capacity: 33554432, category: .spiFlash),
    ChipEntry(name: "MT25QL512", manufacturer: "Micron", capacity: 67108864, category: .spiFlash),
    ChipEntry(name: "MT25QU512", manufacturer: "Micron", capacity: 67108864, category: .spiFlash),
    ChipEntry(name: "MT35XU02G", manufacturer: "Micron", capacity: 268435456, category: .spiFlash),

    // MARK: - Nantronics
    ChipEntry(name: "N25S10", manufacturer: "Nantronics", capacity: 131072, category: .spiFlash),
    ChipEntry(name: "N25S16", manufacturer: "Nantronics", capacity: 2097152, category: .spiFlash),
    ChipEntry(name: "N25S20", manufacturer: "Nantronics", capacity: 262144, category: .spiFlash),
    ChipEntry(name: "N25S40", manufacturer: "Nantronics", capacity: 524288, category: .spiFlash),
    ChipEntry(name: "N25S80", manufacturer: "Nantronics", capacity: 1048576, category: .spiFlash),

    // MARK: - PMC
    ChipEntry(name: "Pm25LD010(C)", manufacturer: "PMC", capacity: 131072, category: .spiFlash),
    ChipEntry(name: "Pm25LD020(C)", manufacturer: "PMC", capacity: 262144, category: .spiFlash),
    ChipEntry(name: "Pm25LD040(C)", manufacturer: "PMC", capacity: 524288, category: .spiFlash),
    ChipEntry(name: "Pm25LD256C", manufacturer: "PMC", capacity: 32768, category: .spiFlash),
    ChipEntry(name: "Pm25LD512(C)", manufacturer: "PMC", capacity: 65536, category: .spiFlash),
    ChipEntry(name: "Pm25LQ016", manufacturer: "PMC", capacity: 2097152, category: .spiFlash),
    ChipEntry(name: "Pm25LQ020", manufacturer: "PMC", capacity: 262144, category: .spiFlash),
    ChipEntry(name: "Pm25LQ032C", manufacturer: "PMC", capacity: 4194304, category: .spiFlash),
    ChipEntry(name: "Pm25LQ040", manufacturer: "PMC", capacity: 524288, category: .spiFlash),
    ChipEntry(name: "Pm25LQ080", manufacturer: "PMC", capacity: 1048576, category: .spiFlash),
    ChipEntry(name: "Pm25LV010", manufacturer: "PMC", capacity: 131072, category: .spiFlash),
    ChipEntry(name: "Pm25LV010A", manufacturer: "PMC", capacity: 131072, category: .spiFlash),
    ChipEntry(name: "Pm25LV016B", manufacturer: "PMC", capacity: 2097152, category: .spiFlash),
    ChipEntry(name: "Pm25LV020", manufacturer: "PMC", capacity: 262144, category: .spiFlash),
    ChipEntry(name: "Pm25LV040", manufacturer: "PMC", capacity: 524288, category: .spiFlash),
    ChipEntry(name: "Pm25LV080B", manufacturer: "PMC", capacity: 1048576, category: .spiFlash),
    ChipEntry(name: "Pm25LV512(A)", manufacturer: "PMC", capacity: 65536, category: .spiFlash),

    // MARK: - PUYA
    ChipEntry(name: "P25Q06H", manufacturer: "PUYA", capacity: 65536, category: .spiFlash),
    ChipEntry(name: "P25Q11H", manufacturer: "PUYA", capacity: 131072, category: .spiFlash),
    ChipEntry(name: "P25Q21H", manufacturer: "PUYA", capacity: 262144, category: .spiFlash),
    ChipEntry(name: "P25D80H", manufacturer: "PUYA", capacity: 1048576, category: .spiFlash),

    // MARK: - Sanyo
    ChipEntry(name: "LE25FU106B", manufacturer: "Sanyo", capacity: 131072, category: .spiFlash),
    ChipEntry(name: "LE25FU206", manufacturer: "Sanyo", capacity: 262144, category: .spiFlash),
    ChipEntry(name: "LE25FU206A", manufacturer: "Sanyo", capacity: 262144, category: .spiFlash),
    ChipEntry(name: "LE25FU406B", manufacturer: "Sanyo", capacity: 524288, category: .spiFlash),
    ChipEntry(name: "LE25FU406C/LE25U40CMC", manufacturer: "Sanyo", capacity: 524288, category: .spiFlash),
    ChipEntry(name: "LE25FW106", manufacturer: "Sanyo", capacity: 131072, category: .spiFlash),
    ChipEntry(name: "LE25FW203A", manufacturer: "Sanyo", capacity: 262144, category: .spiFlash),
    ChipEntry(name: "LE25FW403A", manufacturer: "Sanyo", capacity: 524288, category: .spiFlash),
    ChipEntry(name: "LE25FW406A", manufacturer: "Sanyo", capacity: 524288, category: .spiFlash),
    ChipEntry(name: "LE25FW418A", manufacturer: "Sanyo", capacity: 524288, category: .spiFlash),
    ChipEntry(name: "LE25FW806", manufacturer: "Sanyo", capacity: 1048576, category: .spiFlash),
    ChipEntry(name: "LE25FW808", manufacturer: "Sanyo", capacity: 1048576, category: .spiFlash),

    // MARK: - Spansion
    ChipEntry(name: "S25FL004A", manufacturer: "Spansion", capacity: 524288, category: .spiFlash),
    ChipEntry(name: "S25FL008A", manufacturer: "Spansion", capacity: 1048576, category: .spiFlash),
    ChipEntry(name: "S25FL016A", manufacturer: "Spansion", capacity: 2097152, category: .spiFlash),
    ChipEntry(name: "S25FL032A/P", manufacturer: "Spansion", capacity: 4194304, category: .spiFlash),
    ChipEntry(name: "S25FL064A/P", manufacturer: "Spansion", capacity: 8388608, category: .spiFlash),
    ChipEntry(name: "S25FL116K/S25FL216K", manufacturer: "Spansion", capacity: 2097152, category: .spiFlash),
    ChipEntry(name: "S25FL127S-256kB", manufacturer: "Spansion", capacity: 16777216, category: .spiFlash),
    ChipEntry(name: "S25FL127S-64kB", manufacturer: "Spansion", capacity: 16777216, category: .spiFlash),
    ChipEntry(name: "S25FL128L", manufacturer: "Spansion", capacity: 16777216, category: .spiFlash),
    ChipEntry(name: "S25FL128P......0", manufacturer: "Spansion", capacity: 16777216, category: .spiFlash),
    ChipEntry(name: "S25FL128P......1", manufacturer: "Spansion", capacity: 16777216, category: .spiFlash),
    ChipEntry(name: "S25FL128S......0", manufacturer: "Spansion", capacity: 16777216, category: .spiFlash),
    ChipEntry(name: "S25FL128S......1", manufacturer: "Spansion", capacity: 16777216, category: .spiFlash),
    ChipEntry(name: "S25FL128S_UL Uniform 128 kB Sectors", manufacturer: "Spansion", capacity: 16777216, category: .spiFlash),
    ChipEntry(name: "S25FL128S_US Uniform 64 kB Sectors", manufacturer: "Spansion", capacity: 16777216, category: .spiFlash),
    ChipEntry(name: "S25FL129P......0", manufacturer: "Spansion", capacity: 16777216, category: .spiFlash),
    ChipEntry(name: "S25FL129P......1", manufacturer: "Spansion", capacity: 16777216, category: .spiFlash),
    ChipEntry(name: "S25FL132K", manufacturer: "Spansion", capacity: 4194304, category: .spiFlash),
    ChipEntry(name: "S25FL164K", manufacturer: "Spansion", capacity: 8388608, category: .spiFlash),
    ChipEntry(name: "S25FL204K", manufacturer: "Spansion", capacity: 524288, category: .spiFlash),
    ChipEntry(name: "S25FL208K", manufacturer: "Spansion", capacity: 1048576, category: .spiFlash),
    ChipEntry(name: "S25FL256L", manufacturer: "Spansion", capacity: 33554432, category: .spiFlash),
    ChipEntry(name: "S25FL256S Large Sectors", manufacturer: "Spansion", capacity: 16777216, category: .spiFlash),
    ChipEntry(name: "S25FL256S Small Sectors", manufacturer: "Spansion", capacity: 16777216, category: .spiFlash),
    ChipEntry(name: "S25FL256S......0", manufacturer: "Spansion", capacity: 33554432, category: .spiFlash),
    ChipEntry(name: "S25FL512S", manufacturer: "Spansion", capacity: 67108864, category: .spiFlash),
    ChipEntry(name: "S25FS128S Large Sectors", manufacturer: "Spansion", capacity: 16777216, category: .spiFlash),
    ChipEntry(name: "S25FS128S Small Sectors", manufacturer: "Spansion", capacity: 16777216, category: .spiFlash),
    ChipEntry(name: "S25FS512S", manufacturer: "Spansion", capacity: 67108864, category: .spiFlash),

    // MARK: - SST
    ChipEntry(name: "SST25LF020A", manufacturer: "SST", capacity: 262144, category: .spiFlash),
    ChipEntry(name: "SST25LF040A", manufacturer: "SST", capacity: 524288, category: .spiFlash),
    ChipEntry(name: "SST25LF080(A)", manufacturer: "SST", capacity: 1048576, category: .spiFlash),
    ChipEntry(name: "SST25VF010(A)", manufacturer: "SST", capacity: 131072, category: .spiFlash),
    ChipEntry(name: "SST25VF016B", manufacturer: "SST", capacity: 2097152, category: .spiFlash),
    ChipEntry(name: "SST25VF020", manufacturer: "SST", capacity: 262144, category: .spiFlash),
    ChipEntry(name: "SST25VF020B", manufacturer: "SST", capacity: 262144, category: .spiFlash),
    ChipEntry(name: "SST25VF032B", manufacturer: "SST", capacity: 4194304, category: .spiFlash),
    ChipEntry(name: "SST25VF040", manufacturer: "SST", capacity: 524288, category: .spiFlash),
    ChipEntry(name: "SST25VF040B", manufacturer: "SST", capacity: 524288, category: .spiFlash),
    ChipEntry(name: "SST25VF040B.REMS", manufacturer: "SST", capacity: 524288, category: .spiFlash),
    ChipEntry(name: "SST25VF064C", manufacturer: "SST", capacity: 8388608, category: .spiFlash),
    ChipEntry(name: "SST25VF080B", manufacturer: "SST", capacity: 1048576, category: .spiFlash),
    ChipEntry(name: "SST25VF512(A)", manufacturer: "SST", capacity: 65536, category: .spiFlash),
    ChipEntry(name: "SST25WF010", manufacturer: "SST", capacity: 131072, category: .spiFlash),
    ChipEntry(name: "SST25WF020", manufacturer: "SST", capacity: 262144, category: .spiFlash),
    ChipEntry(name: "SST25WF020A", manufacturer: "SST", capacity: 262144, category: .spiFlash),
    ChipEntry(name: "SST25WF040", manufacturer: "SST", capacity: 524288, category: .spiFlash),
    ChipEntry(name: "SST25WF040B", manufacturer: "SST", capacity: 524288, category: .spiFlash),
    ChipEntry(name: "SST25WF080", manufacturer: "SST", capacity: 1048576, category: .spiFlash),
    ChipEntry(name: "SST25WF080B", manufacturer: "SST", capacity: 1048576, category: .spiFlash),
    ChipEntry(name: "SST25WF512", manufacturer: "SST", capacity: 65536, category: .spiFlash),
    ChipEntry(name: "SST26VF016B(A)", manufacturer: "SST", capacity: 2097152, category: .spiFlash),
    ChipEntry(name: "SST26VF032B(A)", manufacturer: "SST", capacity: 4194304, category: .spiFlash),
    ChipEntry(name: "SST26VF064B(A)", manufacturer: "SST", capacity: 8388608, category: .spiFlash),

    // MARK: - ST
    ChipEntry(name: "M95M02", manufacturer: "ST", capacity: 262144, category: .spiFlash),

    // MARK: - Winbond
    ChipEntry(name: "W25P16", manufacturer: "Winbond", capacity: 2097152, category: .spiFlash),
    ChipEntry(name: "W25P32", manufacturer: "Winbond", capacity: 4194304, category: .spiFlash),
    ChipEntry(name: "W25P80", manufacturer: "Winbond", capacity: 1048576, category: .spiFlash),
    ChipEntry(name: "W25Q128.V", manufacturer: "Winbond", capacity: 16777216, category: .spiFlash),
    ChipEntry(name: "W25Q128.V..M", manufacturer: "Winbond", capacity: 16777216, category: .spiFlash),
    ChipEntry(name: "W25Q128.W", manufacturer: "Winbond", capacity: 16777216, category: .spiFlash),
    ChipEntry(name: "W25Q128.JW.DTR", manufacturer: "Winbond", capacity: 16777216, category: .spiFlash),
    ChipEntry(name: "W25Q16JV_M", manufacturer: "Winbond", capacity: 2097152, category: .spiFlash),
    ChipEntry(name: "W25Q16.V", manufacturer: "Winbond", capacity: 2097152, category: .spiFlash),
    ChipEntry(name: "W25Q16.W", manufacturer: "Winbond", capacity: 2097152, category: .spiFlash),
    ChipEntry(name: "W25Q20.W", manufacturer: "Winbond", capacity: 262144, category: .spiFlash),
    ChipEntry(name: "W25Q256FV", manufacturer: "Winbond", capacity: 33554432, category: .spiFlash),
    ChipEntry(name: "W25Q256JV_Q", manufacturer: "Winbond", capacity: 33554432, category: .spiFlash),
    ChipEntry(name: "W25Q256JV_M", manufacturer: "Winbond", capacity: 33554432, category: .spiFlash),
    ChipEntry(name: "W25Q512JV_M", manufacturer: "Winbond", capacity: 67108864, category: .spiFlash),
    ChipEntry(name: "W25Q256JW", manufacturer: "Winbond", capacity: 33554432, category: .spiFlash),
    ChipEntry(name: "W25R256JW", manufacturer: "Winbond", capacity: 33554432, category: .spiFlash),
    ChipEntry(name: "W25R512NW/W74M51NW", manufacturer: "Winbond", capacity: 67108864, category: .spiFlash),
    ChipEntry(name: "W25Q256JW_DTR", manufacturer: "Winbond", capacity: 33554432, category: .spiFlash),
    ChipEntry(name: "W25Q32BV/W25Q32CV/W25Q32DV", manufacturer: "Winbond", capacity: 4194304, category: .spiFlash),
    ChipEntry(name: "W25Q32FV", manufacturer: "Winbond", capacity: 4194304, category: .spiFlash),
    ChipEntry(name: "W25Q32JV_M", manufacturer: "Winbond", capacity: 4194304, category: .spiFlash),
    ChipEntry(name: "W25Q32JV", manufacturer: "Winbond", capacity: 4194304, category: .spiFlash),
    ChipEntry(name: "W25Q32BW/W25Q32CW/W25Q32DW", manufacturer: "Winbond", capacity: 4194304, category: .spiFlash),
    ChipEntry(name: "W25Q32FW", manufacturer: "Winbond", capacity: 4194304, category: .spiFlash),
    ChipEntry(name: "W25Q32JW...Q", manufacturer: "Winbond", capacity: 4194304, category: .spiFlash),
    ChipEntry(name: "W25Q32JW...M", manufacturer: "Winbond", capacity: 4194304, category: .spiFlash),
    ChipEntry(name: "W25Q40.V", manufacturer: "Winbond", capacity: 524288, category: .spiFlash),
    ChipEntry(name: "W25Q40BW", manufacturer: "Winbond", capacity: 524288, category: .spiFlash),
    ChipEntry(name: "W25Q40EW", manufacturer: "Winbond", capacity: 524288, category: .spiFlash),
    ChipEntry(name: "W25Q512JV", manufacturer: "Winbond", capacity: 67108864, category: .spiFlash),
    ChipEntry(name: "W25Q01JV", manufacturer: "Winbond", capacity: 134217728, category: .spiFlash),
    ChipEntry(name: "W25Q512NW-IM", manufacturer: "Winbond", capacity: 67108864, category: .spiFlash),
    ChipEntry(name: "W25Q64BV/W25Q64CV/W25Q64FV", manufacturer: "Winbond", capacity: 8388608, category: .spiFlash),
    ChipEntry(name: "W25Q64JV-.Q", manufacturer: "Winbond", capacity: 8388608, category: .spiFlash),
    ChipEntry(name: "W25Q64JV-.M", manufacturer: "Winbond", capacity: 8388608, category: .spiFlash),
    ChipEntry(name: "W25Q64.W", manufacturer: "Winbond", capacity: 8388608, category: .spiFlash),
    ChipEntry(name: "W25Q64JW...M", manufacturer: "Winbond", capacity: 8388608, category: .spiFlash),
    ChipEntry(name: "W25Q80BV/W25Q80DV", manufacturer: "Winbond", capacity: 1048576, category: .spiFlash),
    ChipEntry(name: "W25Q80RV", manufacturer: "Winbond", capacity: 1048576, category: .spiFlash),
    ChipEntry(name: "W25Q80BW", manufacturer: "Winbond", capacity: 1048576, category: .spiFlash),
    ChipEntry(name: "W25Q80EW", manufacturer: "Winbond", capacity: 1048576, category: .spiFlash),
    ChipEntry(name: "W25X05", manufacturer: "Winbond", capacity: 65536, category: .spiFlash),
    ChipEntry(name: "W25X10", manufacturer: "Winbond", capacity: 131072, category: .spiFlash),
    ChipEntry(name: "W25X16", manufacturer: "Winbond", capacity: 2097152, category: .spiFlash),
    ChipEntry(name: "W25X20", manufacturer: "Winbond", capacity: 262144, category: .spiFlash),
    ChipEntry(name: "W25X32", manufacturer: "Winbond", capacity: 4194304, category: .spiFlash),
    ChipEntry(name: "W25X40", manufacturer: "Winbond", capacity: 524288, category: .spiFlash),
    ChipEntry(name: "W25X64", manufacturer: "Winbond", capacity: 8388608, category: .spiFlash),
    ChipEntry(name: "W25X80", manufacturer: "Winbond", capacity: 1048576, category: .spiFlash),
    ChipEntry(name: "W35T02NW", manufacturer: "Winbond", capacity: 268435456, category: .spiFlash),
    ChipEntry(name: "W77Q16JW", manufacturer: "Winbond", capacity: 2097152, category: .spiFlash),
    ChipEntry(name: "W77Q32JW", manufacturer: "Winbond", capacity: 4194304, category: .spiFlash),
    ChipEntry(name: "W77Q64JV", manufacturer: "Winbond", capacity: 8388608, category: .spiFlash),
    ChipEntry(name: "W77Q128JV", manufacturer: "Winbond", capacity: 16777216, category: .spiFlash),
    ChipEntry(name: "W77Q64JW", manufacturer: "Winbond", capacity: 8388608, category: .spiFlash),
    ChipEntry(name: "W77Q128JW", manufacturer: "Winbond", capacity: 16777216, category: .spiFlash),
    ChipEntry(name: "W77Q25NWS", manufacturer: "Winbond", capacity: 33554432, category: .spiFlash),
    ChipEntry(name: "W77Q51NWD", manufacturer: "Winbond", capacity: 67108864, category: .spiFlash),
    ChipEntry(name: "W77Q01NWQ", manufacturer: "Winbond", capacity: 134217728, category: .spiFlash),
    ChipEntry(name: "W77T25NWS", manufacturer: "Winbond", capacity: 33554432, category: .spiFlash),
    ChipEntry(name: "W77T51NWD", manufacturer: "Winbond", capacity: 67108864, category: .spiFlash),
    ChipEntry(name: "W77T01NWQ", manufacturer: "Winbond", capacity: 134217728, category: .spiFlash),
    ChipEntry(name: "W77Q64NW", manufacturer: "Winbond", capacity: 8388608, category: .spiFlash),
    ChipEntry(name: "W77Q128NW", manufacturer: "Winbond", capacity: 16777216, category: .spiFlash),
    ChipEntry(name: "W77T64NW", manufacturer: "Winbond", capacity: 8388608, category: .spiFlash),
    ChipEntry(name: "W77T128NW", manufacturer: "Winbond", capacity: 16777216, category: .spiFlash),

    // MARK: - XMC
    ChipEntry(name: "XM25QH80B", manufacturer: "XMC", capacity: 1048576, category: .spiFlash),
    ChipEntry(name: "XM25QU80B", manufacturer: "XMC", capacity: 1048576, category: .spiFlash),
    ChipEntry(name: "XM25QH16C/XM25QH16D", manufacturer: "XMC", capacity: 2097152, category: .spiFlash),
    ChipEntry(name: "XM25QU16C", manufacturer: "XMC", capacity: 2097152, category: .spiFlash),
    ChipEntry(name: "XM25QH32C/XM25QH32D", manufacturer: "XMC", capacity: 4194304, category: .spiFlash),
    ChipEntry(name: "XM25QU32C", manufacturer: "XMC", capacity: 4194304, category: .spiFlash),
    ChipEntry(name: "XM25QH64C/XM25QH64D", manufacturer: "XMC", capacity: 8388608, category: .spiFlash),
    ChipEntry(name: "XM25QU64C/XM25LU64C", manufacturer: "XMC", capacity: 8388608, category: .spiFlash),
    ChipEntry(name: "XM25QH64A", manufacturer: "XMC", capacity: 8388608, category: .spiFlash),
    ChipEntry(name: "XM25QH128A", manufacturer: "XMC", capacity: 16777216, category: .spiFlash),
    ChipEntry(name: "XM25QH128C/XM25QH128D", manufacturer: "XMC", capacity: 16777216, category: .spiFlash),
    ChipEntry(name: "XM25QU128C/XM25QU128D", manufacturer: "XMC", capacity: 16777216, category: .spiFlash),
    ChipEntry(name: "XM25QH256C/XM25QH256D", manufacturer: "XMC", capacity: 33554432, category: .spiFlash),
    ChipEntry(name: "XM25QU256C/XM25QU256D", manufacturer: "XMC", capacity: 33554432, category: .spiFlash),
    ChipEntry(name: "XM25RU256C", manufacturer: "XMC", capacity: 33554432, category: .spiFlash),
    ChipEntry(name: "XM25QH512C/XM25QH512D", manufacturer: "XMC", capacity: 67108864, category: .spiFlash),
    ChipEntry(name: "XM25QU512C/XM25QU512D", manufacturer: "XMC", capacity: 67108864, category: .spiFlash),

    // MARK: - XTX Technology Limited
    ChipEntry(name: "XT25F02E", manufacturer: "XTX Technology Limited", capacity: 262144, category: .spiFlash),
    ChipEntry(name: "XT25F64B", manufacturer: "XTX Technology Limited", capacity: 8388608, category: .spiFlash),
    ChipEntry(name: "XT25F128B", manufacturer: "XTX Technology Limited", capacity: 16777216, category: .spiFlash),

    // MARK: - Zbit Semiconductor, Inc.
    ChipEntry(name: "ZB25VQ16", manufacturer: "Zbit Semiconductor, Inc.", capacity: 2097152, category: .spiFlash),

    // MARK: - Zetta Device
    ChipEntry(name: "ZD25D20", manufacturer: "Zetta Device", capacity: 262144, category: .spiFlash),
    ChipEntry(name: "ZD25D40", manufacturer: "Zetta Device", capacity: 524288, category: .spiFlash),
    ChipEntry(name: "ZD25LQ128", manufacturer: "Zetta Device", capacity: 16777216, category: .spiFlash),
    ]

    // MARK: - SPI EEPROM (Microchip 25AA/25LC series)
    static let spiEEPROMChips: [ChipEntry] = [
        ChipEntry(name: "25AA010A", manufacturer: "Microchip", capacity: 128, category: .spiFlash),
        ChipEntry(name: "25LC010A", manufacturer: "Microchip", capacity: 128, category: .spiFlash),
        ChipEntry(name: "25AA020A", manufacturer: "Microchip", capacity: 256, category: .spiFlash),
        ChipEntry(name: "25LC020A", manufacturer: "Microchip", capacity: 256, category: .spiFlash),
        ChipEntry(name: "25AA040A", manufacturer: "Microchip", capacity: 512, category: .spiFlash),
        ChipEntry(name: "25LC040A", manufacturer: "Microchip", capacity: 512, category: .spiFlash),
        ChipEntry(name: "25AA080B", manufacturer: "Microchip", capacity: 1024, category: .spiFlash),
        ChipEntry(name: "25LC080B", manufacturer: "Microchip", capacity: 1024, category: .spiFlash),
        ChipEntry(name: "25AA160B", manufacturer: "Microchip", capacity: 2048, category: .spiFlash),
        ChipEntry(name: "25LC160B", manufacturer: "Microchip", capacity: 2048, category: .spiFlash),
        ChipEntry(name: "25AA320A", manufacturer: "Microchip", capacity: 4096, category: .spiFlash),
        ChipEntry(name: "25LC320A", manufacturer: "Microchip", capacity: 4096, category: .spiFlash),
        ChipEntry(name: "25AA640A", manufacturer: "Microchip", capacity: 8192, category: .spiFlash),
        ChipEntry(name: "25LC640A", manufacturer: "Microchip", capacity: 8192, category: .spiFlash),
        ChipEntry(name: "25AA128", manufacturer: "Microchip", capacity: 16384, category: .spiFlash),
        ChipEntry(name: "25LC128", manufacturer: "Microchip", capacity: 16384, category: .spiFlash),
        ChipEntry(name: "25AA256", manufacturer: "Microchip", capacity: 32768, category: .spiFlash),
        ChipEntry(name: "25LC256", manufacturer: "Microchip", capacity: 32768, category: .spiFlash),
        ChipEntry(name: "25AA512", manufacturer: "Microchip", capacity: 65536, category: .spiFlash),
        ChipEntry(name: "25LC512", manufacturer: "Microchip", capacity: 65536, category: .spiFlash),
        ChipEntry(name: "25AA1024", manufacturer: "Microchip", capacity: 131072, category: .spiFlash),
        ChipEntry(name: "25LC1024", manufacturer: "Microchip", capacity: 131072, category: .spiFlash),
    ]

    // MARK: - I2C EEPROM
    static let i2cEEPROMChips: [ChipEntry] = [
        ChipEntry(name: "AT24C01", manufacturer: "Atmel", capacity: 128, category: .i2cEEPROM, pageSize: 8, sectorSize: 128, i2cAddress: 0x50),
        ChipEntry(name: "AT24C02", manufacturer: "Atmel", capacity: 256, category: .i2cEEPROM, pageSize: 8, sectorSize: 256, i2cAddress: 0x50),
        ChipEntry(name: "AT24C04", manufacturer: "Atmel", capacity: 512, category: .i2cEEPROM, pageSize: 16, sectorSize: 512, i2cAddress: 0x50),
        ChipEntry(name: "AT24C08", manufacturer: "Atmel", capacity: 1024, category: .i2cEEPROM, pageSize: 16, sectorSize: 1024, i2cAddress: 0x50),
        ChipEntry(name: "AT24C16", manufacturer: "Atmel", capacity: 2048, category: .i2cEEPROM, pageSize: 16, sectorSize: 2048, i2cAddress: 0x50),
        ChipEntry(name: "AT24C32", manufacturer: "Atmel", capacity: 4096, category: .i2cEEPROM, pageSize: 32, sectorSize: 4096, i2cAddress: 0x50),
        ChipEntry(name: "AT24C64", manufacturer: "Atmel", capacity: 8192, category: .i2cEEPROM, pageSize: 32, sectorSize: 8192, i2cAddress: 0x50),
        ChipEntry(name: "AT24C128", manufacturer: "Atmel", capacity: 16384, category: .i2cEEPROM, pageSize: 64, sectorSize: 16384, i2cAddress: 0x50),
        ChipEntry(name: "AT24C256", manufacturer: "Atmel", capacity: 32768, category: .i2cEEPROM, pageSize: 64, sectorSize: 32768, i2cAddress: 0x50),
        ChipEntry(name: "AT24C512", manufacturer: "Atmel", capacity: 65536, category: .i2cEEPROM, pageSize: 128, sectorSize: 65536, i2cAddress: 0x50),
        ChipEntry(name: "M24C02", manufacturer: "STMicro", capacity: 256, category: .i2cEEPROM, pageSize: 16, sectorSize: 256, i2cAddress: 0x50),
        ChipEntry(name: "M24C04", manufacturer: "STMicro", capacity: 512, category: .i2cEEPROM, pageSize: 16, sectorSize: 512, i2cAddress: 0x50),
        ChipEntry(name: "M24C08", manufacturer: "STMicro", capacity: 1024, category: .i2cEEPROM, pageSize: 16, sectorSize: 1024, i2cAddress: 0x50),
        ChipEntry(name: "M24C16", manufacturer: "STMicro", capacity: 2048, category: .i2cEEPROM, pageSize: 16, sectorSize: 2048, i2cAddress: 0x50),
        ChipEntry(name: "M24C32", manufacturer: "STMicro", capacity: 4096, category: .i2cEEPROM, pageSize: 32, sectorSize: 4096, i2cAddress: 0x50),
        ChipEntry(name: "M24C64", manufacturer: "STMicro", capacity: 8192, category: .i2cEEPROM, pageSize: 32, sectorSize: 8192, i2cAddress: 0x50),
        ChipEntry(name: "M24256", manufacturer: "STMicro", capacity: 32768, category: .i2cEEPROM, pageSize: 64, sectorSize: 32768, i2cAddress: 0x50),
        ChipEntry(name: "M24512", manufacturer: "STMicro", capacity: 65536, category: .i2cEEPROM, pageSize: 128, sectorSize: 65536, i2cAddress: 0x50),
        ChipEntry(name: "24LC02B", manufacturer: "Microchip", capacity: 256, category: .i2cEEPROM, pageSize: 8, sectorSize: 256, i2cAddress: 0x50),
        ChipEntry(name: "24LC04B", manufacturer: "Microchip", capacity: 512, category: .i2cEEPROM, pageSize: 16, sectorSize: 512, i2cAddress: 0x50),
        ChipEntry(name: "24LC08B", manufacturer: "Microchip", capacity: 1024, category: .i2cEEPROM, pageSize: 16, sectorSize: 1024, i2cAddress: 0x50),
        ChipEntry(name: "24LC16B", manufacturer: "Microchip", capacity: 2048, category: .i2cEEPROM, pageSize: 16, sectorSize: 2048, i2cAddress: 0x50),
        ChipEntry(name: "24LC32A", manufacturer: "Microchip", capacity: 4096, category: .i2cEEPROM, pageSize: 32, sectorSize: 4096, i2cAddress: 0x50),
        ChipEntry(name: "24LC64", manufacturer: "Microchip", capacity: 8192, category: .i2cEEPROM, pageSize: 32, sectorSize: 8192, i2cAddress: 0x50),
        ChipEntry(name: "24LC128", manufacturer: "Microchip", capacity: 16384, category: .i2cEEPROM, pageSize: 64, sectorSize: 16384, i2cAddress: 0x50),
        ChipEntry(name: "24LC256", manufacturer: "Microchip", capacity: 32768, category: .i2cEEPROM, pageSize: 64, sectorSize: 32768, i2cAddress: 0x50),
        ChipEntry(name: "24LC512", manufacturer: "Microchip", capacity: 65536, category: .i2cEEPROM, pageSize: 128, sectorSize: 65536, i2cAddress: 0x50),
        ChipEntry(name: "BR24L02", manufacturer: "ROHM", capacity: 256, category: .i2cEEPROM, pageSize: 8, sectorSize: 256, i2cAddress: 0x50),
        ChipEntry(name: "BR24G64", manufacturer: "ROHM", capacity: 8192, category: .i2cEEPROM, pageSize: 32, sectorSize: 8192, i2cAddress: 0x50),
        ChipEntry(name: "CAT24C32", manufacturer: "ON Semi", capacity: 4096, category: .i2cEEPROM, pageSize: 32, sectorSize: 4096, i2cAddress: 0x50),
        ChipEntry(name: "CAT24C64", manufacturer: "ON Semi", capacity: 8192, category: .i2cEEPROM, pageSize: 32, sectorSize: 8192, i2cAddress: 0x50),
        ChipEntry(name: "CAT24C128", manufacturer: "ON Semi", capacity: 16384, category: .i2cEEPROM, pageSize: 64, sectorSize: 16384, i2cAddress: 0x50),
        ChipEntry(name: "CAT24C256", manufacturer: "ON Semi", capacity: 32768, category: .i2cEEPROM, pageSize: 64, sectorSize: 32768, i2cAddress: 0x50),
    ]

    // MARK: - SPI FRAM (Cypress/Infineon FM25xxx, Fujitsu MB85RS series)
    static let spiFramChips: [ChipEntry] = [
        // Cypress / Infineon FM25 series
        ChipEntry(name: "FM25V01A", manufacturer: "Cypress", capacity: 16384, category: .spiFlash),
        ChipEntry(name: "FM25V02A", manufacturer: "Cypress", capacity: 32768, category: .spiFlash),
        ChipEntry(name: "FM25V05", manufacturer: "Cypress", capacity: 65536, category: .spiFlash),
        ChipEntry(name: "FM25V10", manufacturer: "Cypress", capacity: 131072, category: .spiFlash),
        ChipEntry(name: "FM25V20A", manufacturer: "Cypress", capacity: 262144, category: .spiFlash),
        ChipEntry(name: "FM25V40", manufacturer: "Cypress", capacity: 524288, category: .spiFlash),
        ChipEntry(name: "FM25W256", manufacturer: "Cypress", capacity: 32768, category: .spiFlash),
        ChipEntry(name: "FM25CL64B", manufacturer: "Cypress", capacity: 8192, category: .spiFlash),
        // Fujitsu MB85RS series
        ChipEntry(name: "MB85RS16N", manufacturer: "Fujitsu", capacity: 2048, category: .spiFlash),
        ChipEntry(name: "MB85RS64V", manufacturer: "Fujitsu", capacity: 8192, category: .spiFlash),
        ChipEntry(name: "MB85RS128B", manufacturer: "Fujitsu", capacity: 16384, category: .spiFlash),
        ChipEntry(name: "MB85RS256B", manufacturer: "Fujitsu", capacity: 32768, category: .spiFlash),
        ChipEntry(name: "MB85RS512T", manufacturer: "Fujitsu", capacity: 65536, category: .spiFlash),
        ChipEntry(name: "MB85RS1MT", manufacturer: "Fujitsu", capacity: 131072, category: .spiFlash),
        ChipEntry(name: "MB85RS2MT", manufacturer: "Fujitsu", capacity: 262144, category: .spiFlash),
        ChipEntry(name: "MB85RS4MT", manufacturer: "Fujitsu", capacity: 524288, category: .spiFlash),
    ]

    // MARK: - I2C FRAM (Cypress FM24xxx, Fujitsu MB85RC series)
    static let i2cFramChips: [ChipEntry] = [
        // Cypress / Infineon FM24 series
        ChipEntry(name: "FM24C16B", manufacturer: "Cypress", capacity: 2048, category: .i2cEEPROM, pageSize: 32, sectorSize: 2048, i2cAddress: 0x50),
        ChipEntry(name: "FM24CL64B", manufacturer: "Cypress", capacity: 8192, category: .i2cEEPROM, pageSize: 32, sectorSize: 8192, i2cAddress: 0x50),
        ChipEntry(name: "FM24V01A", manufacturer: "Cypress", capacity: 16384, category: .i2cEEPROM, pageSize: 64, sectorSize: 16384, i2cAddress: 0x50),
        ChipEntry(name: "FM24V02A", manufacturer: "Cypress", capacity: 32768, category: .i2cEEPROM, pageSize: 64, sectorSize: 32768, i2cAddress: 0x50),
        ChipEntry(name: "FM24V05", manufacturer: "Cypress", capacity: 65536, category: .i2cEEPROM, pageSize: 128, sectorSize: 65536, i2cAddress: 0x50),
        ChipEntry(name: "FM24V10", manufacturer: "Cypress", capacity: 131072, category: .i2cEEPROM, pageSize: 256, sectorSize: 131072, i2cAddress: 0x50),
        // Fujitsu MB85RC series
        ChipEntry(name: "MB85RC16V", manufacturer: "Fujitsu", capacity: 2048, category: .i2cEEPROM, pageSize: 32, sectorSize: 2048, i2cAddress: 0x50),
        ChipEntry(name: "MB85RC64TA", manufacturer: "Fujitsu", capacity: 8192, category: .i2cEEPROM, pageSize: 32, sectorSize: 8192, i2cAddress: 0x50),
        ChipEntry(name: "MB85RC128A", manufacturer: "Fujitsu", capacity: 16384, category: .i2cEEPROM, pageSize: 64, sectorSize: 16384, i2cAddress: 0x50),
        ChipEntry(name: "MB85RC256V", manufacturer: "Fujitsu", capacity: 32768, category: .i2cEEPROM, pageSize: 64, sectorSize: 32768, i2cAddress: 0x50),
        ChipEntry(name: "MB85RC512T", manufacturer: "Fujitsu", capacity: 65536, category: .i2cEEPROM, pageSize: 128, sectorSize: 65536, i2cAddress: 0x50),
        ChipEntry(name: "MB85RC1MT", manufacturer: "Fujitsu", capacity: 131072, category: .i2cEEPROM, pageSize: 256, sectorSize: 131072, i2cAddress: 0x50),
    ]
}
