import SwiftUI

struct DSPView: View {
    @Environment(DeviceManager.self) private var manager
    @State private var vm = DSPViewModel()
    @State private var showDatImport = false
    @State private var skipRecordsPopover = false

    var body: some View {
        HSplitView {
            // Left: Controls
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    firmwareSection
                    controlSection
                    registerSection
                    safeloadSection
                    biquadSection
                    levelMeterSection
                }
                .padding(16)
            }
            .frame(width: 300)
            .background(.background)

            // Right: Diagnostics
            VStack(spacing: 0) {
                diagnosticsPanel
                Spacer()
            }
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
                            .foregroundStyle(.purple)
                        VStack(alignment: .leading, spacing: 1) {
                            Text(name)
                                .font(.system(.caption, design: .monospaced))
                                .fontWeight(.medium)
                            Text(manager.formatSize(vm.firmwareSize))
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                        }
                    }
                } else {
                    Text("No firmware loaded")
                        .foregroundStyle(.secondary)
                        .font(.caption)
                }

                HStack(spacing: 6) {
                    Button("Load .dat") { showDatImport = true }
                        .controlSize(.small)
                    Button("Load .bin") { loadBinaryFile() }
                        .controlSize(.small)
                }

                Divider()

                Text("Transport: SPI (CH341A)")
                    .font(.caption2)
                    .foregroundStyle(.secondary)

                HStack(alignment: .top, spacing: 6) {
                    LabeledContent("Skip records") {
                        TextField("14", value: $vm.skipPrePLL, format: .number)
                            .font(.system(.caption, design: .monospaced))
                            .textFieldStyle(.roundedBorder)
                            .frame(width: 44)
                    }
                    Button {
                        skipRecordsPopover = true
                    } label: {
                        Image(systemName: "questionmark.circle")
                            .font(.caption)
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(.secondary)
                    .popover(isPresented: $skipRecordsPopover, arrowEdge: .trailing) {
                        VStack(alignment: .leading, spacing: 8) {
                            Text("Pre-PLL Records")
                                .font(.headline)
                            Text("SigmaStudio exports firmware as a sequence of I2C write records. The first records (0–13) contain pre-PLL initialization:")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                            VStack(alignment: .leading, spacing: 3) {
                                skipRecordLine("0–1", "Soft reset (0xF890)")
                                skipRecordLine("2–3", "Kill core + hibernate")
                                skipRecordLine("4–7", "PLL config (M, prescaler, clk src)")
                                skipRecordLine("8–13", "PLL enable, MCLK out, watchdog")
                            }
                            .font(.system(.caption, design: .monospaced))
                            Divider()
                            Text("These are skipped because Proggy handles PLL init manually with proper SPI timing (400 kHz pre-lock). SigmaStudio's records assume I2C — a soft reset would revert the chip to I2C mode, breaking SPI comms.")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                            Text("Record 14 is a delay for PLL lock (also handled manually). Records 15+ contain the actual firmware: power enables, serial routing, program RAM, param RAM, data memory, and core start.")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                        .padding(12)
                        .frame(width: 320)
                    }
                }

                Button {
                    vm.uploadFirmware(device: manager.device, manager: manager)
                } label: {
                    HStack {
                        Image(systemName: "arrow.up.circle.fill")
                        Text("Upload & Run")
                    }
                    .frame(maxWidth: .infinity)
                }
                .controlSize(.regular)
                .tint(.purple)
                .disabled(!manager.isConnected || vm.firmwareData == nil || vm.isUploading)

                if vm.isUploading {
                    ProgressView(value: vm.uploadProgress)
                        .tint(.purple)
                }
            }
            .padding(.vertical, 4)
        }
        .sheet(isPresented: $showDatImport) {
            DSPDatImportSheet(vm: vm, isPresented: $showDatImport)
                .environment(manager)
        }
    }

    // MARK: - Control

    @ViewBuilder
    private var controlSection: some View {
        GroupBox("Control") {
            VStack(spacing: 6) {
                HStack(spacing: 6) {
                    Button("Soft Reset") {
                        vm.softReset(device: manager.device, manager: manager)
                    }
                    .controlSize(.small)
                    .tint(.red)

                    Button("Clear Panic") {
                        vm.clearPanic(device: manager.device, manager: manager)
                    }
                    .controlSize(.small)
                    .tint(.orange)
                }

                HStack(spacing: 6) {
                    Button("Refresh Status") {
                        Task { await vm.refreshStatus(device: manager.device, manager: manager) }
                    }
                    .controlSize(.small)

                    Toggle("Auto-poll", isOn: Binding(
                        get: { vm.isPolling },
                        set: { on in
                            if on { vm.startPolling(device: manager.device, manager: manager) }
                            else { vm.stopPolling() }
                        }
                    ))
                    .toggleStyle(.checkbox)
                    .font(.caption)
                }
            }
            .disabled(!manager.isConnected)
            .padding(.vertical, 4)
        }
    }

    // MARK: - Register Access

    @ViewBuilder
    private var registerSection: some View {
        GroupBox("Register Access") {
            VStack(alignment: .leading, spacing: 6) {
                LabeledContent("Address") {
                    TextField("F401", text: $vm.regAddress)
                        .font(.system(.caption, design: .monospaced))
                        .textFieldStyle(.roundedBorder)
                        .frame(width: 70)
                }

                HStack(spacing: 6) {
                    Button("Read") {
                        vm.readRegister(device: manager.device, manager: manager)
                    }
                    .controlSize(.small)

                    if !vm.regReadResult.isEmpty {
                        Text(vm.regReadResult)
                            .font(.system(.caption, design: .monospaced))
                            .foregroundStyle(.green)
                    }
                }

                HStack(spacing: 6) {
                    TextField("Value (hex)", text: $vm.regValue)
                        .font(.system(.caption, design: .monospaced))
                        .textFieldStyle(.roundedBorder)
                        .frame(width: 70)
                    Button("Write") {
                        vm.writeRegister(device: manager.device, manager: manager)
                    }
                    .controlSize(.small)
                    .tint(.orange)
                }
            }
            .disabled(!manager.isConnected)
            .padding(.vertical, 4)
        }
    }

    // MARK: - Safeload

    @ViewBuilder
    private var safeloadSection: some View {
        GroupBox("Safeload") {
            VStack(alignment: .leading, spacing: 6) {
                LabeledContent("Param addr") {
                    TextField("0035", text: $vm.safeloadAddr)
                        .font(.system(.caption, design: .monospaced))
                        .textFieldStyle(.roundedBorder)
                        .frame(width: 70)
                }

                LabeledContent("Format") {
                    Picker("", selection: $vm.safeloadFormat) {
                        ForEach(DSPViewModel.SafeloadFormat.allCases) { f in
                            Text(f.rawValue).tag(f)
                        }
                    }
                    .labelsHidden()
                    .frame(width: 100)
                }

                HStack(spacing: 6) {
                    TextField("1.0, 0.5, ...", text: $vm.safeloadValue)
                        .font(.system(.caption, design: .monospaced))
                        .textFieldStyle(.roundedBorder)
                    Button("Send") {
                        vm.performSafeload(device: manager.device, manager: manager)
                    }
                    .controlSize(.small)
                    .tint(.green)
                }

                Text("Up to 5 values (comma/space separated). 28-byte atomic burst at frame boundary.")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
            }
            .disabled(!manager.isConnected)
            .padding(.vertical, 4)
        }
    }

    // MARK: - Biquad

    @ViewBuilder
    private var biquadSection: some View {
        GroupBox("Biquad (EQ Cookbook)") {
            VStack(alignment: .leading, spacing: 6) {
                LabeledContent("Base addr") {
                    TextField("0000", text: $vm.biquadAddr)
                        .font(.system(.caption, design: .monospaced))
                        .textFieldStyle(.roundedBorder)
                        .frame(width: 70)
                }

                // Coefficient fields in 2 rows
                HStack(spacing: 4) {
                    coeffField("b0", $vm.biquadB0)
                    coeffField("b1", $vm.biquadB1)
                    coeffField("b2", $vm.biquadB2)
                }
                HStack(spacing: 4) {
                    coeffField("a1", $vm.biquadA1)
                    coeffField("a2", $vm.biquadA2)
                    Spacer()
                }

                HStack(spacing: 6) {
                    Button("Write") {
                        vm.writeBiquad(device: manager.device, manager: manager)
                    }
                    .controlSize(.small)
                    .tint(.orange)

                    Button("Read") {
                        vm.readBiquad(device: manager.device, manager: manager)
                    }
                    .controlSize(.small)
                }

                Text("Writes B2,B1,B0,A2,A1 via safeload. a1/a2 auto-negated for ADAU convention. Unstable filters forced to unity.")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
            }
            .disabled(!manager.isConnected)
            .padding(.vertical, 4)
        }
    }

    @ViewBuilder
    private func coeffField(_ label: String, _ value: Binding<String>) -> some View {
        VStack(spacing: 1) {
            Text(label)
                .font(.system(.caption2, design: .monospaced))
                .foregroundStyle(.secondary)
            TextField("0.0", text: value)
                .font(.system(.caption, design: .monospaced))
                .textFieldStyle(.roundedBorder)
                .frame(width: 72)
        }
    }

    // MARK: - Level Meters

    @ViewBuilder
    private var levelMeterSection: some View {
        GroupBox("Level Meters") {
            VStack(alignment: .leading, spacing: 6) {
                LabeledContent("Addresses") {
                    TextField("addr1, addr2...", text: $vm.levelAddrs)
                        .font(.system(.caption, design: .monospaced))
                        .textFieldStyle(.roundedBorder)
                        .frame(width: 140)
                }

                Button("Read Levels") {
                    vm.readLevels(device: manager.device, manager: manager)
                }
                .controlSize(.small)

                if !vm.levelValues.isEmpty {
                    ForEach(Array(vm.levelValues.enumerated()), id: \.offset) { i, val in
                        HStack(spacing: 6) {
                            Text("[\(i)]")
                                .font(.system(.caption2, design: .monospaced))
                                .foregroundStyle(.secondary)
                                .frame(width: 20)
                            ProgressView(value: min(max(Double(val), 0), 1))
                                .tint(val > 0.9 ? .red : val > 0.7 ? .orange : .green)
                            Text(String(format: "%.1f dB", val > 0 ? 20 * log10(val) : -144))
                                .font(.system(.caption2, design: .monospaced))
                                .frame(width: 56, alignment: .trailing)
                        }
                    }
                }
            }
            .disabled(!manager.isConnected)
            .padding(.vertical, 4)
        }
    }

    // MARK: - Diagnostics Panel

    @ViewBuilder
    private var diagnosticsPanel: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                Text("DSP Diagnostics")
                    .font(.headline)
                    .padding(.bottom, 2)

                // Status row — horizontal, not grid
                HStack(spacing: 10) {
                    statusPill(icon: "cpu", label: "Core", value: vm.coreStatus,
                               color: vm.coreStatus == "Running" ? .green : .orange)
                    statusPill(icon: "waveform.path", label: "PLL", value: vm.pllLocked ? "Locked" : "Unlocked",
                               color: vm.pllLocked ? .green : .red)
                    statusPill(icon: "number", label: "Exec", value: "\(vm.executeCount)", color: .blue)
                    statusPill(icon: "exclamationmark.triangle", label: "Panic",
                               value: vm.panicFlag ? String(format: "0x%04X", vm.panicCode) : "None",
                               color: vm.panicFlag ? .red : .green)
                }

                // ASRC Lock — single horizontal row
                GroupBox {
                    HStack(spacing: 14) {
                        ForEach(0..<8, id: \.self) { i in
                            let locked = (vm.asrcLockRaw >> i) & 1 == 0
                            VStack(spacing: 3) {
                                Circle()
                                    .fill(locked ? .green : .red.opacity(0.3))
                                    .frame(width: 10, height: 10)
                                Text("\(i)")
                                    .font(.system(.caption2, design: .monospaced))
                                    .foregroundStyle(.secondary)
                            }
                        }
                    }
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 4)
                } label: {
                    Text("ASRC Lock")
                }

                // Panic decoder
                if vm.panicFlag {
                    GroupBox("Panic Details") {
                        VStack(alignment: .leading, spacing: 3) {
                            panicBit(vm.panicCode, bit: 0, name: "ASRC0 underflow")
                            panicBit(vm.panicCode, bit: 1, name: "ASRC1 underflow")
                            panicBit(vm.panicCode, bit: 2, name: "PRAM parity 0")
                            panicBit(vm.panicCode, bit: 3, name: "PRAM parity 1")
                            panicBit(vm.panicCode, bit: 12, name: "Watchdog timeout")
                            panicBit(vm.panicCode, bit: 13, name: "Stack overrun")
                            panicBit(vm.panicCode, bit: 14, name: "Loop overrun")
                            panicBit(vm.panicCode, bit: 15, name: "Software panic")
                        }
                        .font(.system(.caption, design: .monospaced))
                        .padding(.vertical, 2)
                    }
                }
            }
            .padding(20)
        }
    }

    @ViewBuilder
    private func statusPill(icon: String, label: String, value: String, color: Color) -> some View {
        VStack(spacing: 4) {
            HStack(spacing: 4) {
                Image(systemName: icon)
                    .font(.caption2)
                    .foregroundStyle(color)
                Text(label)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
            Text(value)
                .font(.system(.caption, design: .monospaced))
                .fontWeight(.semibold)
                .foregroundStyle(color)
                .lineLimit(1)
                .minimumScaleFactor(0.7)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 8)
        .padding(.horizontal, 6)
        .background(color.opacity(0.08))
        .cornerRadius(8)
    }

    @ViewBuilder
    private func panicBit(_ code: UInt16, bit: Int, name: String) -> some View {
        let active = (code >> bit) & 1 != 0
        if active {
            HStack(spacing: 4) {
                Image(systemName: "xmark.circle.fill")
                    .foregroundStyle(.red)
                    .font(.caption)
                Text(name)
            }
        }
    }

    @ViewBuilder
    private func skipRecordLine(_ range: String, _ desc: String) -> some View {
        HStack(spacing: 6) {
            Text(range)
                .foregroundStyle(.orange)
                .frame(width: 36, alignment: .trailing)
            Text(desc)
                .foregroundStyle(.primary)
        }
    }

    // MARK: - Helpers

    private func loadBinaryFile() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.data]
        panel.message = "Select compiled DSP firmware (.bin)"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        vm.loadBinaryFirmware(url, manager: manager)
    }
}

// MARK: - DAT Import Sheet for DSP

struct DSPDatImportSheet: View {
    var vm: DSPViewModel
    @Binding var isPresented: Bool
    @Environment(DeviceManager.self) private var manager

    @State private var numBytesURL: URL?
    @State private var txBufferURL: URL?

    var body: some View {
        VStack(spacing: 16) {
            HStack {
                Image(systemName: "waveform.path")
                    .font(.title2)
                    .foregroundStyle(.purple)
                Text("Import SigmaStudio .dat for DSP")
                    .font(.headline)
                Spacer()
            }

            datFileSelector(label: "NumBytes", url: $numBytesURL)
            datFileSelector(label: "TxBuffer", url: $txBufferURL)

            HStack {
                Spacer()
                Button("Cancel") { isPresented = false }
                    .keyboardShortcut(.cancelAction)
                Button("Import") {
                    guard let nb = numBytesURL, let tx = txBufferURL else { return }
                    vm.loadDatFiles(numBytesURL: nb, txBufferURL: tx, manager: manager)
                    isPresented = false
                }
                .keyboardShortcut(.defaultAction)
                .disabled(numBytesURL == nil || txBufferURL == nil)
            }
        }
        .padding()
        .frame(width: 440)
    }

    @ViewBuilder
    private func datFileSelector(label: String, url: Binding<URL?>) -> some View {
        HStack {
            Text("\(label):")
                .font(.caption)
                .frame(width: 70, alignment: .trailing)
            Text(url.wrappedValue?.lastPathComponent ?? "Not selected")
                .font(.system(.caption, design: .monospaced))
                .foregroundStyle(url.wrappedValue != nil ? .primary : .tertiary)
            Spacer()
            Button("Browse...") {
                let panel = NSOpenPanel()
                panel.allowedContentTypes = [.plainText, .data]
                guard panel.runModal() == .OK else { return }
                url.wrappedValue = panel.url
            }
            .controlSize(.small)
        }
    }
}
