import SwiftUI

struct ESPView: View {
    @Environment(DeviceManager.self) private var manager
    @State private var vm = ESPViewModel()

    var body: some View {
        HSplitView {
            // Left: Flash controls
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    portSection
                    firmwareSection
                    flashSection
                }
                .padding(16)
            }
            .frame(width: 300)
            .background(.background)

            // Right: Serial monitor
            VStack(spacing: 0) {
                HStack {
                    Text("Serial Monitor")
                        .font(.headline)
                    Spacer()
                    if vm.isMonitoring {
                        Button("Stop") { vm.stopMonitor() }
                            .controlSize(.small)
                            .tint(.red)
                    } else {
                        Button("Start") { vm.startMonitor(manager: manager) }
                            .controlSize(.small)
                            .disabled(vm.selectedPort.isEmpty || vm.isFlashing)
                    }
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 10)

                Divider()

                // Output
                ScrollViewReader { proxy in
                    ScrollView {
                        Text(vm.monitorOutput.isEmpty ? "No output yet..." : vm.monitorOutput)
                            .font(.system(.caption, design: .monospaced))
                            .foregroundStyle(vm.monitorOutput.isEmpty ? .tertiary : .primary)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(8)
                            .id("bottom")
                    }
                    .onChange(of: vm.monitorOutput) { _, _ in
                        proxy.scrollTo("bottom", anchor: .bottom)
                    }
                }
                .background(.black.opacity(0.3))

                // Input
                HStack(spacing: 6) {
                    TextField("Send text...", text: $vm.monitorInput)
                        .font(.system(.caption, design: .monospaced))
                        .textFieldStyle(.roundedBorder)
                        .onSubmit { vm.sendMonitorText() }
                        .disabled(!vm.isMonitoring)

                    Button("Send") { vm.sendMonitorText() }
                        .controlSize(.small)
                        .disabled(!vm.isMonitoring || vm.monitorInput.isEmpty)
                }
                .padding(8)
            }
        }
    }

    // MARK: - Port Selection

    @ViewBuilder
    private var portSection: some View {
        GroupBox("Serial Port") {
            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    Picker("Port", selection: $vm.selectedPort) {
                        if vm.availablePorts.isEmpty {
                            Text("No ports found").tag("")
                        }
                        ForEach(vm.availablePorts, id: \.path) { port in
                            Text("\(port.name) (\(port.path.components(separatedBy: "/").last ?? port.path))")
                                .tag(port.path)
                        }
                    }
                    .labelsHidden()

                    Button {
                        vm.refreshPorts()
                    } label: {
                        Image(systemName: "arrow.clockwise")
                    }
                    .controlSize(.small)
                }

                LabeledContent("Baud rate") {
                    Picker("", selection: $vm.baudRate) {
                        Text("115200").tag(115200)
                        Text("230400").tag(230400)
                        Text("460800").tag(460800)
                        Text("921600").tag(921600)
                        Text("1500000").tag(1500000)
                        Text("2000000").tag(2000000)
                    }
                    .labelsHidden()
                    .frame(width: 100)
                }
            }
            .padding(.vertical, 4)
        }
    }

    // MARK: - Firmware

    @ViewBuilder
    private var firmwareSection: some View {
        GroupBox("Firmware") {
            VStack(alignment: .leading, spacing: 8) {
                if let name = vm.firmwareFileName {
                    HStack(spacing: 6) {
                        Image(systemName: "doc.fill")
                            .foregroundStyle(.blue)
                        VStack(alignment: .leading, spacing: 1) {
                            Text(name)
                                .font(.system(.caption, design: .monospaced))
                                .fontWeight(.medium)
                            if let data = vm.firmwareData {
                                Text(manager.formatSize(data.count))
                                    .font(.caption2)
                                    .foregroundStyle(.secondary)
                            }
                        }
                    }
                } else {
                    Text("No firmware loaded")
                        .foregroundStyle(.secondary)
                        .font(.caption)
                }

                Button("Select Firmware (.bin)") {
                    let panel = NSOpenPanel()
                    panel.allowedContentTypes = [.data]
                    panel.message = "Select ESP firmware binary"
                    guard panel.runModal() == .OK, let url = panel.url else { return }
                    vm.loadFirmware(url, manager: manager)
                }
                .controlSize(.small)

                LabeledContent("Flash offset") {
                    TextField("10000", text: $vm.flashOffset)
                        .font(.system(.caption, design: .monospaced))
                        .textFieldStyle(.roundedBorder)
                        .frame(width: 80)
                }

                Text("Common: 0x0 (bootloader), 0x8000 (partition table), 0x10000 (app)")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
            }
            .padding(.vertical, 4)
        }
    }

    // MARK: - Flash

    @ViewBuilder
    private var flashSection: some View {
        GroupBox("Flash") {
            VStack(alignment: .leading, spacing: 8) {
                // Supported chips
                HStack(spacing: 4) {
                    ForEach(["ESP32", "S2", "S3", "C3", "C6", "H2"], id: \.self) { chip in
                        Text(chip)
                            .font(.system(.caption2, design: .monospaced))
                            .padding(.horizontal, 4)
                            .padding(.vertical, 1)
                            .background(.blue.opacity(0.15))
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
                }
                .controlSize(.regular)
                .tint(.blue)
                .disabled(vm.firmwareData == nil || vm.selectedPort.isEmpty || vm.isFlashing)

                if vm.isFlashing {
                    ProgressView(value: vm.flashProgress)
                        .tint(.blue)
                    Text(vm.flashStatus)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                } else if !vm.flashStatus.isEmpty {
                    HStack(spacing: 4) {
                        Image(systemName: vm.flashStatus.starts(with: "Done") ? "checkmark.circle.fill" : "exclamationmark.circle.fill")
                            .foregroundStyle(vm.flashStatus.starts(with: "Done") ? .green : .red)
                        Text(vm.flashStatus)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }

                if let chip = vm.detectedChip {
                    HStack(spacing: 4) {
                        Image(systemName: "cpu")
                            .foregroundStyle(.green)
                        Text(chip)
                            .font(.system(.caption, design: .monospaced))
                            .fontWeight(.medium)
                    }
                }
            }
            .padding(.vertical, 4)
        }
    }
}
