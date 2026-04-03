import SwiftUI
import UniformTypeIdentifiers

enum NavigationTab: String, CaseIterable, Identifiable {
    case flash = "Flash / EEPROM"
    case spi = "SPI Terminal"
    case i2c = "I2C Terminal"
    case dsp = "SigmaDSP"
    case esp = "ESP Flasher"

    var id: String { rawValue }

    var icon: String {
        switch self {
        case .flash: return "memorychip"
        case .spi: return "arrow.left.arrow.right"
        case .i2c: return "point.3.connected.trianglepath.dotted"
        case .dsp: return "waveform.path"
        case .esp: return "bolt.horizontal"
        }
    }
}

struct ContentView: View {
    @Environment(DeviceManager.self) private var manager
    @State private var selectedTab: NavigationTab = .flash
    @State private var showLog = true

    var body: some View {
        NavigationSplitView {
            SidebarView(selectedTab: $selectedTab)
        } detail: {
            VStack(spacing: 0) {
                // Status bar
                DeviceStatusBar()
                    .padding(.horizontal, 16)
                    .padding(.vertical, 8)

                Divider()

                // Main content
                Group {
                    switch selectedTab {
                    case .flash:
                        FlashView()
                    case .spi:
                        SPIView()
                    case .i2c:
                        I2CView()
                    case .dsp:
                        DSPView()
                    case .esp:
                        ESPView()
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)

                // Log panel
                if showLog {
                    Divider()
                    LogView()
                        .frame(height: 160)
                }
            }
            .toolbar {
                ToolbarItem(placement: .automatic) {
                    Button {
                        withAnimation { showLog.toggle() }
                    } label: {
                        Image(systemName: showLog ? "rectangle.bottomhalf.filled" : "rectangle.bottomhalf.inset.filled")
                    }
                    .help("Toggle log panel")
                }
            }
        }
        .navigationSplitViewColumnWidth(min: 210, ideal: 230, max: 260)
        .onDrop(of: [.fileURL], isTargeted: nil) { providers in
            handleDrop(providers)
        }
    }

    private func handleDrop(_ providers: [NSItemProvider]) -> Bool {
        guard let provider = providers.first else { return false }
        provider.loadItem(forTypeIdentifier: UTType.fileURL.identifier, options: nil) { data, _ in
            guard let data = data as? Data,
                  let url = URL(dataRepresentation: data, relativeTo: nil) else { return }
            Task { @MainActor in
                let ext = url.pathExtension.lowercased()
                if ext == "hex" || ext == "ihex" {
                    manager.loadIntelHex(url)
                } else {
                    manager.loadFile(url)
                }
                selectedTab = .flash
            }
        }
        return true
    }
}

// MARK: - Sidebar

struct SidebarView: View {
    @Binding var selectedTab: NavigationTab
    @Environment(DeviceManager.self) private var manager

    private var zifHighlight: ZIFSocketView.ZIFHighlight {
        switch selectedTab {
        case .i2c, .dsp: return .i2c
        case .spi, .flash, .esp: return .spi
        }
    }

    var body: some View {
        VStack(spacing: 0) {
            List(NavigationTab.allCases, selection: $selectedTab) { tab in
                Label(tab.rawValue, systemImage: tab.icon)
                    .tag(tab)
            }
            .listStyle(.sidebar)

            Divider()

            ZIFSocketView(highlightMode: zifHighlight)
                .padding(.vertical, 12)
                .frame(maxWidth: .infinity)

            Divider()

            ConnectionButton()
                .padding(.horizontal, 12)
                .padding(.vertical, 8)
        }
    }
}

// MARK: - Connection Button

struct ConnectionButton: View {
    @Environment(DeviceManager.self) private var manager

    var body: some View {
        Button {
            if manager.isConnected {
                manager.disconnect()
            } else {
                manager.connect()
            }
        } label: {
            HStack(spacing: 6) {
                Circle()
                    .fill(manager.isConnected ? .green : .red)
                    .frame(width: 8, height: 8)
                Text(manager.isConnected ? "Connected" : "Disconnected")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .buttonStyle(.plain)
    }
}
