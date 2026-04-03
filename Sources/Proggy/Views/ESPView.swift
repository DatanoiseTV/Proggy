import SwiftUI

struct ESPView: View {
    @Environment(DeviceManager.self) private var manager
    @State private var vm = ESPViewModel()

    var body: some View {
        HSplitView {
            // Left: Flash controls
            ScrollView {
                VStack(alignment: .leading, spacing: 12) {
                    connectionSection
                    imagesSection
                    optionsSection
                    flashActionSection
                }
                .padding(16)
            }
            .frame(width: 320)
            .background(.background)

            // Right: Serial monitor
            monitorPanel
        }
    }

    // MARK: - Connection

    @ViewBuilder
    private var connectionSection: some View {
        GroupBox {
            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    Picker("", selection: $vm.selectedPort) {
                        if vm.availablePorts.isEmpty {
                            Text("No ports found").tag("")
                        }
                        ForEach(vm.availablePorts, id: \.path) { port in
                            Text(port.name)
                                .tag(port.path)
                        }
                    }
                    .labelsHidden()

                    Button { vm.refreshPorts() } label: {
                        Image(systemName: "arrow.clockwise")
                    }
                    .controlSize(.small)
                    .help("Refresh serial ports")
                }

                HStack(spacing: 12) {
                    LabeledContent("Baud") {
                        Picker("", selection: $vm.baudRate) {
                            Text("115200").tag(115200)
                            Text("230400").tag(230400)
                            Text("460800").tag(460800)
                            Text("921600").tag(921600)
                            Text("2000000").tag(2000000)
                        }
                        .labelsHidden()
                        .frame(width: 90)
                    }

                    LabeledContent("Chip") {
                        Picker("", selection: $vm.selectedChip) {
                            Text("Auto").tag("")
                            ForEach(ESPChip.allCases) { chip in
                                Text(chip.rawValue).tag(chip.rawValue)
                            }
                        }
                        .labelsHidden()
                        .frame(width: 100)
                    }
                }
            }
            .padding(.vertical, 2)
        } label: {
            Label("Serial Port", systemImage: "cable.connector")
        }
    }

    // MARK: - Flash Images

    @ViewBuilder
    private var imagesSection: some View {
        GroupBox {
            VStack(alignment: .leading, spacing: 8) {
                // Main firmware
                imageRow(
                    label: "Firmware",
                    file: vm.firmwareFileName,
                    size: vm.firmwareData?.count,
                    offset: $vm.flashOffset,
                    onSelect: { selectFirmware(slot: .main) }
                )

                Divider()

                // Bootloader (optional)
                imageRow(
                    label: "Bootloader",
                    file: vm.bootloaderFileName,
                    size: vm.bootloaderData?.count,
                    offset: $vm.bootloaderOffset,
                    onSelect: { selectFirmware(slot: .bootloader) },
                    onClear: { vm.bootloaderData = nil; vm.bootloaderFileName = nil }
                )

                // Partition table (optional)
                imageRow(
                    label: "Partitions",
                    file: vm.partitionFileName,
                    size: vm.partitionData?.count,
                    offset: $vm.partitionOffset,
                    onSelect: { selectFirmware(slot: .partition) },
                    onClear: { vm.partitionData = nil; vm.partitionFileName = nil }
                )
            }
            .padding(.vertical, 2)
        } label: {
            Label("Flash Images", systemImage: "doc.on.doc")
        }
    }

    @ViewBuilder
    private func imageRow(label: String, file: String?, size: Int?, offset: Binding<String>,
                          onSelect: @escaping () -> Void, onClear: (() -> Void)? = nil) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text(label)
                    .font(.caption)
                    .fontWeight(.medium)
                    .frame(width: 70, alignment: .leading)

                if let name = file {
                    Text(name)
                        .font(.system(.caption2, design: .monospaced))
                        .lineLimit(1)
                        .truncationMode(.middle)
                    if let size {
                        Text(manager.formatSize(size))
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }
                    if let onClear {
                        Button { onClear() } label: {
                            Image(systemName: "xmark.circle.fill")
                                .font(.caption2)
                        }
                        .buttonStyle(.plain)
                        .foregroundStyle(.secondary)
                    }
                } else {
                    Button("Select...", action: onSelect)
                        .controlSize(.mini)
                }

                Spacer()
            }

            HStack(spacing: 4) {
                Text("@ 0x")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
                TextField("offset", text: offset)
                    .font(.system(.caption2, design: .monospaced))
                    .textFieldStyle(.roundedBorder)
                    .frame(width: 64)
            }
        }
    }

    enum FirmwareSlot { case main, bootloader, partition }

    private func selectFirmware(slot: FirmwareSlot) {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.data]
        guard panel.runModal() == .OK, let url = panel.url else { return }

        switch slot {
        case .main:
            vm.loadFirmware(url, manager: manager)
        case .bootloader:
            vm.bootloaderData = try? Data(contentsOf: url)
            vm.bootloaderFileName = url.lastPathComponent
        case .partition:
            vm.partitionData = try? Data(contentsOf: url)
            vm.partitionFileName = url.lastPathComponent
        }
    }

    // MARK: - Options

    @ViewBuilder
    private var optionsSection: some View {
        GroupBox {
            VStack(alignment: .leading, spacing: 6) {
                Toggle("Erase before flash", isOn: $vm.eraseBeforeFlash)
                    .toggleStyle(.checkbox)
                Toggle("Verify after flash", isOn: $vm.verifyAfterFlash)
                    .toggleStyle(.checkbox)
                Toggle("Reset after flash", isOn: $vm.resetAfterFlash)
                    .toggleStyle(.checkbox)

                Divider()

                Toggle(isOn: $vm.autoProgramOnChange) {
                    HStack(spacing: 4) {
                        Image(systemName: "arrow.triangle.2.circlepath")
                            .foregroundStyle(vm.autoProgramOnChange ? .green : .secondary)
                        Text("Auto-flash on file change")
                    }
                }
                .toggleStyle(.checkbox)
                .disabled(vm.watchedFirmwareURL == nil)

                if vm.autoProgramOnChange {
                    HStack(spacing: 4) {
                        Image(systemName: "eye.fill")
                            .foregroundStyle(.green)
                            .font(.caption2)
                        Text("Watching & auto-flashing")
                            .font(.caption2)
                            .foregroundStyle(.green)
                        if vm.autoProgramCount > 0 {
                            Text("(\(vm.autoProgramCount)x)")
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                        }
                    }
                }
            }
            .font(.caption)
            .padding(.vertical, 2)
        } label: {
            Label("Options", systemImage: "gearshape")
        }
    }

    // MARK: - Flash Action

    @ViewBuilder
    private var flashActionSection: some View {
        VStack(spacing: 8) {
            // Supported chips
            HStack(spacing: 3) {
                ForEach(["ESP32", "S2", "S3", "C2", "C3", "C5", "C6", "H2", "P4"], id: \.self) { tag in
                    Text(tag)
                        .font(.system(size: 9, weight: .medium, design: .monospaced))
                        .padding(.horizontal, 3)
                        .padding(.vertical, 1)
                        .background(.blue.opacity(0.12))
                        .cornerRadius(3)
                }
            }

            Button {
                vm.flash(manager: manager)
            } label: {
                HStack {
                    Image(systemName: "bolt.fill")
                    Text("Flash")
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, 2)
            }
            .controlSize(.large)
            .tint(.blue)
            .disabled(vm.firmwareData == nil || vm.selectedPort.isEmpty || vm.isFlashing)

            if vm.isFlashing {
                VStack(spacing: 4) {
                    ProgressView(value: vm.flashProgress)
                        .tint(.blue)
                    Text(vm.flashStatus)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            } else if !vm.flashStatus.isEmpty {
                HStack(spacing: 4) {
                    Image(systemName: vm.flashStatus.starts(with: "Done") ? "checkmark.circle.fill" : "xmark.circle.fill")
                        .foregroundStyle(vm.flashStatus.starts(with: "Done") ? .green : .red)
                    Text(vm.flashStatus)
                        .font(.caption)
                    if let chip = vm.detectedChip {
                        Text("(\(chip))")
                            .font(.system(.caption, design: .monospaced))
                            .fontWeight(.medium)
                            .foregroundStyle(.blue)
                    }
                }
            }
        }
    }

    // MARK: - Serial Monitor

    @ViewBuilder
    private var monitorPanel: some View {
        VStack(spacing: 0) {
            // Toolbar
            HStack(spacing: 8) {
                Image(systemName: "terminal")
                    .foregroundStyle(.green)
                Text("Serial Monitor")
                    .font(.headline)

                Spacer()

                Picker("", selection: $vm.monitorBaud) {
                    Text("9600").tag(9600)
                    Text("115200").tag(115200)
                    Text("460800").tag(460800)
                }
                .labelsHidden()
                .frame(width: 80)

                Toggle("Hex", isOn: $vm.monitorHexMode)
                    .toggleStyle(.checkbox)
                    .font(.caption)

                Button("Clear") {
                    vm.monitorOutput = ""
                }
                .controlSize(.small)
                .disabled(vm.monitorOutput.isEmpty)

                if vm.isMonitoring {
                    Button("Stop") { vm.stopMonitor() }
                        .controlSize(.small)
                        .tint(.red)
                } else {
                    Button("Start") { vm.startMonitor(manager: manager) }
                        .controlSize(.small)
                        .tint(.green)
                        .disabled(vm.selectedPort.isEmpty || vm.isFlashing)
                }
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)

            Divider()

            // Output area
            ScrollViewReader { proxy in
                ScrollView {
                    Text(vm.monitorOutput.isEmpty ? "Connect to see serial output..." : vm.monitorOutput)
                        .font(.system(.caption, design: .monospaced))
                        .foregroundStyle(vm.monitorOutput.isEmpty ? Color.secondary : Color.green)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(8)
                        .textSelection(.enabled)
                        .id("end")
                }
                .background(Color(nsColor: .init(white: 0.05, alpha: 1)))
                .onChange(of: vm.monitorOutput) { _, _ in
                    proxy.scrollTo("end", anchor: .bottom)
                }
            }

            // Input bar
            HStack(spacing: 6) {
                TextField("Type to send...", text: $vm.monitorInput)
                    .font(.system(.caption, design: .monospaced))
                    .textFieldStyle(.roundedBorder)
                    .onSubmit { vm.sendMonitorText() }
                    .disabled(!vm.isMonitoring)

                Button("Send") { vm.sendMonitorText() }
                    .controlSize(.small)
                    .disabled(!vm.isMonitoring || vm.monitorInput.isEmpty)
                    .keyboardShortcut(.return, modifiers: [])
            }
            .padding(8)
        }
    }
}
