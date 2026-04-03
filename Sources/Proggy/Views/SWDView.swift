import SwiftUI

struct SWDView: View {
    @Environment(DeviceManager.self) private var manager
    @State private var vm = SWDViewModel()

    var body: some View {
        HSplitView {
            // Left: Controls
            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    probeSection
                    targetSection
                    firmwareSection
                    flashSection
                }
                .padding(16)
            }
            .frame(width: 320)
            .background(.background)

            // Right: Info panel
            VStack(alignment: .leading, spacing: 16) {
                Text("SWD Debug Probe")
                    .font(.headline)

                GroupBox("Connection") {
                    VStack(alignment: .leading, spacing: 6) {
                        statusRow("Probe", vm.isProbeConnected ? (vm.probeInfo ?? "Connected") : "Not connected",
                                  color: vm.isProbeConnected ? .green : .secondary)
                        if let id = vm.idcode {
                            statusRow("IDCODE", id, color: .blue)
                        }
                        statusRow("Target", vm.selectedChip.rawValue, color: .orange)
                    }
                    .padding(.vertical, 4)
                }

                GroupBox("Pinout (Debug Probe)") {
                    VStack(alignment: .leading, spacing: 3) {
                        pinRow("SWCLK", "Probe GP2 → Target SWCLK")
                        pinRow("SWDIO", "Probe GP3 → Target SWDIO")
                        pinRow("GND", "Probe GND → Target GND")
                        pinRow("RESET", "Probe GP6 → Target RUN (optional)")
                        Divider()
                        pinRow("UART TX", "Probe GP4 → Target RX")
                        pinRow("UART RX", "Probe GP5 → Target TX")
                    }
                    .font(.system(.caption, design: .monospaced))
                    .padding(.vertical, 4)
                }

                GroupBox("Supported Targets") {
                    VStack(alignment: .leading, spacing: 4) {
                        HStack(spacing: 8) {
                            chipBadge("RP2040", color: .green)
                            chipBadge("RP2350", color: .purple)
                        }
                        Text("ARM Cortex-M0+/M33 via CMSIS-DAP v2")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                        Text("Requires Raspberry Pi Debug Probe or Picoprobe firmware")
                            .font(.caption2)
                            .foregroundStyle(.tertiary)
                    }
                    .padding(.vertical, 4)
                }

                Spacer()
            }
            .padding(20)
        }
    }

    // MARK: - Probe

    @ViewBuilder
    private var probeSection: some View {
        GroupBox {
            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    Circle()
                        .fill(vm.isProbeConnected ? .green : .red)
                        .frame(width: 8, height: 8)
                    Text(vm.isProbeConnected ? (vm.probeInfo ?? "Connected") : "No probe detected")
                        .font(.caption)
                        .foregroundStyle(vm.isProbeConnected ? .primary : .secondary)
                    Spacer()
                }

                HStack(spacing: 6) {
                    if vm.isProbeConnected {
                        Button("Disconnect") { vm.disconnectProbe(manager: manager) }
                            .controlSize(.small)
                        Button("Read IDCODE") { vm.readIDCODE(manager: manager) }
                            .controlSize(.small)
                    } else {
                        Button("Connect Probe") { vm.connectProbe(manager: manager) }
                            .controlSize(.small)
                            .tint(.green)
                    }
                }
            }
            .padding(.vertical, 2)
        } label: {
            Label("Debug Probe", systemImage: "cable.connector.horizontal")
        }
    }

    // MARK: - Target

    @ViewBuilder
    private var targetSection: some View {
        GroupBox {
            Picker("Chip", selection: $vm.selectedChip) {
                ForEach(RPChip.allCases) { chip in
                    Text(chip.rawValue).tag(chip)
                }
            }
            .pickerStyle(.segmented)
            .padding(.vertical, 2)
        } label: {
            Label("Target", systemImage: "cpu")
        }
    }

    // MARK: - Firmware

    @ViewBuilder
    private var firmwareSection: some View {
        GroupBox {
            VStack(alignment: .leading, spacing: 8) {
                if let name = vm.firmwareFileName, let data = vm.firmwareData {
                    HStack(spacing: 6) {
                        Image(systemName: "doc.fill")
                            .foregroundStyle(.green)
                        Text(name)
                            .font(.system(.caption, design: .monospaced))
                            .fontWeight(.medium)
                        Text(manager.formatSize(data.count))
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }
                } else {
                    Text("No firmware loaded")
                        .foregroundStyle(.secondary)
                        .font(.caption)
                }

                HStack(spacing: 6) {
                    Button("Select .bin") { selectFirmware(ext: "bin") }
                        .controlSize(.small)
                    Button("Select .uf2") { selectFirmware(ext: "uf2") }
                        .controlSize(.small)
                    Button("Select .elf") { selectFirmware(ext: "elf") }
                        .controlSize(.small)
                }
            }
            .padding(.vertical, 2)
        } label: {
            Label("Firmware", systemImage: "doc.zipper")
        }
    }

    // MARK: - Flash

    @ViewBuilder
    private var flashSection: some View {
        VStack(spacing: 8) {
            Toggle(isOn: $vm.autoProgramOnChange) {
                HStack(spacing: 4) {
                    Image(systemName: "arrow.triangle.2.circlepath")
                        .foregroundStyle(vm.autoProgramOnChange ? .green : .secondary)
                    Text("Auto-flash on file change")
                        .font(.caption)
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

            Button {
                vm.flash(manager: manager)
            } label: {
                HStack {
                    Image(systemName: "arrow.down.to.line")
                    Text("Flash via SWD")
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, 2)
            }
            .controlSize(.large)
            .tint(.green)
            .disabled(!vm.isProbeConnected || vm.firmwareData == nil || vm.isFlashing)

            if vm.isFlashing {
                VStack(spacing: 4) {
                    ProgressView(value: vm.flashProgress)
                        .tint(.green)
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
                }
            }
        }
    }

    // MARK: - Helpers

    private func selectFirmware(ext: String) {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.data]
        panel.message = "Select \(ext.uppercased()) firmware file"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        vm.loadFirmware(url, manager: manager)
    }

    @ViewBuilder
    private func statusRow(_ label: String, _ value: String, color: Color) -> some View {
        HStack {
            Text(label)
                .font(.caption)
                .foregroundStyle(.secondary)
                .frame(width: 60, alignment: .trailing)
            Text(value)
                .font(.system(.caption, design: .monospaced))
                .foregroundStyle(color)
        }
    }

    @ViewBuilder
    private func pinRow(_ pin: String, _ desc: String) -> some View {
        HStack(spacing: 8) {
            Text(pin)
                .fontWeight(.medium)
                .foregroundStyle(.orange)
                .frame(width: 60, alignment: .trailing)
            Text(desc)
                .foregroundStyle(.secondary)
        }
    }

    @ViewBuilder
    private func chipBadge(_ name: String, color: Color) -> some View {
        Text(name)
            .font(.system(.caption, design: .monospaced))
            .fontWeight(.semibold)
            .padding(.horizontal, 8)
            .padding(.vertical, 3)
            .background(color.opacity(0.15))
            .cornerRadius(4)
    }
}
