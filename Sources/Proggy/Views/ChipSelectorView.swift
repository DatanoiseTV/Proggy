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

    @State private var hoveredChip: ChipEntry?

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

    var body: some View {
        VStack(spacing: 0) {
            // Header
            HStack {
                Text("Select Device")
                    .font(.headline)
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

                TextField("Search chips...", text: $searchText)
                    .textFieldStyle(.roundedBorder)
            }
            .padding(.horizontal)
            .padding(.bottom, 8)

            Divider()

            // Chip list
            List {
                ForEach(groupedChips, id: \.0) { manufacturer, chips in
                    Section(manufacturer) {
                        ForEach(chips) { chip in
                            chipRow(chip)
                                .contentShape(Rectangle())
                                .onTapGesture { onSelect(chip) }
                                .background(hoveredChip == chip ? Color.accentColor.opacity(0.1) : Color.clear)
                                .cornerRadius(4)
                                .onHover { isHovered in
                                    hoveredChip = isHovered ? chip : nil
                                }
                        }
                    }
                }
            }
            .listStyle(.inset(alternatesRowBackgrounds: true))
        }
        .frame(width: 560, height: 480)
    }

    @ViewBuilder
    private func chipRow(_ chip: ChipEntry) -> some View {
        HStack {
            VStack(alignment: .leading, spacing: 2) {
                Text(chip.name)
                    .font(.system(.body, design: .monospaced))
                    .fontWeight(.medium)
                Text(chip.voltageRange)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Spacer()

            VStack(alignment: .trailing, spacing: 2) {
                Text(formatSize(chip.capacity))
                    .font(.system(.caption, design: .monospaced))
                if let addr = chip.i2cAddress {
                    Text(String(format: "0x%02X", addr))
                        .font(.system(.caption2, design: .monospaced))
                        .foregroundStyle(.cyan)
                }
            }
        }
        .padding(.vertical, 2)
    }

    private func formatSize(_ bytes: Int) -> String {
        if bytes >= 1_048_576 { return "\(bytes / 1_048_576) MB" }
        if bytes >= 1024 { return "\(bytes / 1024) KB" }
        return "\(bytes) B"
    }
}

// MARK: - Chip Library

enum ChipLibrary {
    static let chips: [ChipEntry] = spiFlashChips + i2cEEPROMChips

    // MARK: SPI Flash
    static let spiFlashChips: [ChipEntry] = [
        // Winbond
        ChipEntry(name: "W25Q80BV", manufacturer: "Winbond", capacity: 1_048_576, category: .spiFlash),
        ChipEntry(name: "W25Q16JV", manufacturer: "Winbond", capacity: 2_097_152, category: .spiFlash),
        ChipEntry(name: "W25Q32JV", manufacturer: "Winbond", capacity: 4_194_304, category: .spiFlash),
        ChipEntry(name: "W25Q64JV", manufacturer: "Winbond", capacity: 8_388_608, category: .spiFlash),
        ChipEntry(name: "W25Q128JV", manufacturer: "Winbond", capacity: 16_777_216, category: .spiFlash),
        ChipEntry(name: "W25Q256JV", manufacturer: "Winbond", capacity: 33_554_432, category: .spiFlash),
        ChipEntry(name: "W25Q512JV", manufacturer: "Winbond", capacity: 67_108_864, category: .spiFlash),
        // GigaDevice
        ChipEntry(name: "GD25Q16C", manufacturer: "GigaDevice", capacity: 2_097_152, category: .spiFlash),
        ChipEntry(name: "GD25Q32C", manufacturer: "GigaDevice", capacity: 4_194_304, category: .spiFlash),
        ChipEntry(name: "GD25Q64C", manufacturer: "GigaDevice", capacity: 8_388_608, category: .spiFlash),
        ChipEntry(name: "GD25Q128E", manufacturer: "GigaDevice", capacity: 16_777_216, category: .spiFlash),
        // Macronix
        ChipEntry(name: "MX25L8006E", manufacturer: "Macronix", capacity: 1_048_576, category: .spiFlash),
        ChipEntry(name: "MX25L1606E", manufacturer: "Macronix", capacity: 2_097_152, category: .spiFlash),
        ChipEntry(name: "MX25L3206E", manufacturer: "Macronix", capacity: 4_194_304, category: .spiFlash),
        ChipEntry(name: "MX25L6406E", manufacturer: "Macronix", capacity: 8_388_608, category: .spiFlash),
        ChipEntry(name: "MX25L12835F", manufacturer: "Macronix", capacity: 16_777_216, category: .spiFlash),
        ChipEntry(name: "MX25L25645G", manufacturer: "Macronix", capacity: 33_554_432, category: .spiFlash),
        // ISSI
        ChipEntry(name: "IS25LP032D", manufacturer: "ISSI", capacity: 4_194_304, category: .spiFlash),
        ChipEntry(name: "IS25LP064D", manufacturer: "ISSI", capacity: 8_388_608, category: .spiFlash),
        ChipEntry(name: "IS25LP128F", manufacturer: "ISSI", capacity: 16_777_216, category: .spiFlash),
        // Micron
        ChipEntry(name: "N25Q032A", manufacturer: "Micron", capacity: 4_194_304, category: .spiFlash),
        ChipEntry(name: "N25Q064A", manufacturer: "Micron", capacity: 8_388_608, category: .spiFlash),
        ChipEntry(name: "N25Q128A", manufacturer: "Micron", capacity: 16_777_216, category: .spiFlash),
        // Spansion / Infineon
        ChipEntry(name: "S25FL016K", manufacturer: "Spansion", capacity: 2_097_152, category: .spiFlash),
        ChipEntry(name: "S25FL032P", manufacturer: "Spansion", capacity: 4_194_304, category: .spiFlash),
        ChipEntry(name: "S25FL064P", manufacturer: "Spansion", capacity: 8_388_608, category: .spiFlash),
        ChipEntry(name: "S25FL128S", manufacturer: "Spansion", capacity: 16_777_216, category: .spiFlash),
        // SST / Microchip
        ChipEntry(name: "SST25VF016B", manufacturer: "SST", capacity: 2_097_152, category: .spiFlash),
        ChipEntry(name: "SST25VF032B", manufacturer: "SST", capacity: 4_194_304, category: .spiFlash),
        ChipEntry(name: "SST26VF064B", manufacturer: "SST", capacity: 8_388_608, category: .spiFlash),
        // Atmel / Adesto
        ChipEntry(name: "AT25SF041", manufacturer: "Atmel", capacity: 524_288, category: .spiFlash),
        ChipEntry(name: "AT25SF081", manufacturer: "Atmel", capacity: 1_048_576, category: .spiFlash),
        ChipEntry(name: "AT25SF161", manufacturer: "Atmel", capacity: 2_097_152, category: .spiFlash),
        // XTX
        ChipEntry(name: "XT25F32B", manufacturer: "XTX", capacity: 4_194_304, category: .spiFlash),
        ChipEntry(name: "XT25F64B", manufacturer: "XTX", capacity: 8_388_608, category: .spiFlash),
        ChipEntry(name: "XT25F128B", manufacturer: "XTX", capacity: 16_777_216, category: .spiFlash),
        // Puya
        ChipEntry(name: "P25Q16H", manufacturer: "Puya", capacity: 2_097_152, category: .spiFlash),
        ChipEntry(name: "P25Q32H", manufacturer: "Puya", capacity: 4_194_304, category: .spiFlash),
        // Boya
        ChipEntry(name: "BY25Q32BS", manufacturer: "Boya", capacity: 4_194_304, category: .spiFlash),
        ChipEntry(name: "BY25Q64AS", manufacturer: "Boya", capacity: 8_388_608, category: .spiFlash),
        ChipEntry(name: "BY25Q128AS", manufacturer: "Boya", capacity: 16_777_216, category: .spiFlash),
    ]

    // MARK: I2C EEPROM
    static let i2cEEPROMChips: [ChipEntry] = [
        // Atmel / Microchip
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
        // STMicro
        ChipEntry(name: "M24C02", manufacturer: "STMicro", capacity: 256, category: .i2cEEPROM, pageSize: 16, sectorSize: 256, i2cAddress: 0x50),
        ChipEntry(name: "M24C04", manufacturer: "STMicro", capacity: 512, category: .i2cEEPROM, pageSize: 16, sectorSize: 512, i2cAddress: 0x50),
        ChipEntry(name: "M24C08", manufacturer: "STMicro", capacity: 1024, category: .i2cEEPROM, pageSize: 16, sectorSize: 1024, i2cAddress: 0x50),
        ChipEntry(name: "M24C16", manufacturer: "STMicro", capacity: 2048, category: .i2cEEPROM, pageSize: 16, sectorSize: 2048, i2cAddress: 0x50),
        ChipEntry(name: "M24C32", manufacturer: "STMicro", capacity: 4096, category: .i2cEEPROM, pageSize: 32, sectorSize: 4096, i2cAddress: 0x50),
        ChipEntry(name: "M24C64", manufacturer: "STMicro", capacity: 8192, category: .i2cEEPROM, pageSize: 32, sectorSize: 8192, i2cAddress: 0x50),
        ChipEntry(name: "M24256", manufacturer: "STMicro", capacity: 32768, category: .i2cEEPROM, pageSize: 64, sectorSize: 32768, i2cAddress: 0x50),
        ChipEntry(name: "M24512", manufacturer: "STMicro", capacity: 65536, category: .i2cEEPROM, pageSize: 128, sectorSize: 65536, i2cAddress: 0x50),
        // Microchip
        ChipEntry(name: "24LC02B", manufacturer: "Microchip", capacity: 256, category: .i2cEEPROM, pageSize: 8, sectorSize: 256, i2cAddress: 0x50),
        ChipEntry(name: "24LC04B", manufacturer: "Microchip", capacity: 512, category: .i2cEEPROM, pageSize: 16, sectorSize: 512, i2cAddress: 0x50),
        ChipEntry(name: "24LC08B", manufacturer: "Microchip", capacity: 1024, category: .i2cEEPROM, pageSize: 16, sectorSize: 1024, i2cAddress: 0x50),
        ChipEntry(name: "24LC16B", manufacturer: "Microchip", capacity: 2048, category: .i2cEEPROM, pageSize: 16, sectorSize: 2048, i2cAddress: 0x50),
        ChipEntry(name: "24LC32A", manufacturer: "Microchip", capacity: 4096, category: .i2cEEPROM, pageSize: 32, sectorSize: 4096, i2cAddress: 0x50),
        ChipEntry(name: "24LC64", manufacturer: "Microchip", capacity: 8192, category: .i2cEEPROM, pageSize: 32, sectorSize: 8192, i2cAddress: 0x50),
        ChipEntry(name: "24LC128", manufacturer: "Microchip", capacity: 16384, category: .i2cEEPROM, pageSize: 64, sectorSize: 16384, i2cAddress: 0x50),
        ChipEntry(name: "24LC256", manufacturer: "Microchip", capacity: 32768, category: .i2cEEPROM, pageSize: 64, sectorSize: 32768, i2cAddress: 0x50),
        ChipEntry(name: "24LC512", manufacturer: "Microchip", capacity: 65536, category: .i2cEEPROM, pageSize: 128, sectorSize: 65536, i2cAddress: 0x50),
        // ROHM
        ChipEntry(name: "BR24L02", manufacturer: "ROHM", capacity: 256, category: .i2cEEPROM, pageSize: 8, sectorSize: 256, i2cAddress: 0x50),
        ChipEntry(name: "BR24G64", manufacturer: "ROHM", capacity: 8192, category: .i2cEEPROM, pageSize: 32, sectorSize: 8192, i2cAddress: 0x50),
        // ON Semiconductor
        ChipEntry(name: "CAT24C32", manufacturer: "ON Semi", capacity: 4096, category: .i2cEEPROM, pageSize: 32, sectorSize: 4096, i2cAddress: 0x50),
        ChipEntry(name: "CAT24C64", manufacturer: "ON Semi", capacity: 8192, category: .i2cEEPROM, pageSize: 32, sectorSize: 8192, i2cAddress: 0x50),
    ]
}
