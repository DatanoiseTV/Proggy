import SwiftUI

struct FlashView: View {
    @Environment(DeviceManager.self) private var manager
    @State private var showSigmaImport = false

    var body: some View {
        HSplitView {
            // Left: Controls
            VStack(alignment: .leading, spacing: 0) {
                controlsPanel
                    .padding(16)
                Spacer()
            }
            .frame(width: 260)
            .background(.background)

            // Right: Hex editor
            VStack(spacing: 0) {
                hexToolbar
                Divider()
                if manager.buffer.isEmpty {
                    emptyState
                } else {
                    HexEditorPanel(buffer: manager.buffer)
                }
            }
        }
    }

    // MARK: - Controls Panel

    @ViewBuilder
    private var controlsPanel: some View {
        VStack(alignment: .leading, spacing: 16) {
            // Part selector
            ChipSelectorView()

            // Chip info (from auto-detect)
            if let chip = manager.chipInfo {
                GroupBox("Detected") {
                    VStack(alignment: .leading, spacing: 4) {
                        LabeledContent("ID") {
                            Text(String(format: "%02X %04X", chip.manufacturerID, chip.memoryType))
                                .font(.system(.body, design: .monospaced))
                        }
                        LabeledContent("Size") {
                            Text(manager.formatSize(manager.chipCapacity))
                                .font(.system(.body, design: .monospaced))
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.vertical, 2)
                }
            }

            // Operations
            GroupBox("Operations") {
                VStack(spacing: 8) {
                    HStack(spacing: 8) {
                        ActionButton(title: "Read", icon: "arrow.down.circle", color: .blue) {
                            manager.readChip()
                        }
                        ActionButton(title: "Write", icon: "arrow.up.circle", color: .orange) {
                            manager.writeChip()
                        }
                    }
                    HStack(spacing: 8) {
                        ActionButton(title: "Verify", icon: "checkmark.circle", color: .green) {
                            manager.verifyChip()
                        }
                        ActionButton(title: "Erase", icon: "trash.circle", color: .red) {
                            manager.eraseChip()
                        }
                    }
                    ActionButton(title: "Blank Check", icon: "circle.dashed", color: .purple) {
                        manager.blankCheck()
                    }

                    Divider()

                    Toggle("Verify after write", isOn: Binding(
                        get: { manager.verifyAfterWrite },
                        set: { manager.verifyAfterWrite = $0 }
                    ))
                    .toggleStyle(.checkbox)
                    .font(.caption)

                    Divider()

                    Toggle(isOn: Binding(
                        get: { manager.autoProgramOnChange },
                        set: { manager.autoProgramOnChange = $0 }
                    )) {
                        HStack(spacing: 4) {
                            Image(systemName: "arrow.triangle.2.circlepath")
                                .foregroundStyle(manager.autoProgramOnChange ? .green : .secondary)
                            Text("Auto-program on file change")
                        }
                    }
                    .toggleStyle(.checkbox)
                    .font(.caption)
                    .disabled(manager.watchedFileURL == nil)
                    .help("Automatically write to chip when the loaded file changes on disk")

                    if manager.autoProgramOnChange {
                        HStack(spacing: 4) {
                            Image(systemName: "eye.fill")
                                .foregroundStyle(.green)
                                .font(.caption2)
                            Text("Watching & auto-programming")
                                .font(.caption2)
                                .foregroundStyle(.green)
                            if manager.autoProgramCount > 0 {
                                Text("(\(manager.autoProgramCount)x)")
                                    .font(.caption2)
                                    .foregroundStyle(.secondary)
                            }
                        }
                    }
                }
                .disabled(!manager.isConnected || manager.isBusy)
                .padding(.vertical, 4)
            }

            // Size warning
            if let warning = manager.bufferSizeWarning {
                HStack(spacing: 4) {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .foregroundStyle(.red)
                    Text(warning)
                        .font(.caption2)
                        .foregroundStyle(.red)
                }
            }

            // Utilization bar
            if !manager.buffer.isEmpty && manager.chipCapacity > 0 {
                let pct = min(Double(manager.buffer.count) / Double(manager.chipCapacity), 1.0)
                VStack(alignment: .leading, spacing: 2) {
                    HStack {
                        Text("Utilization")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                        Spacer()
                        Text("\(Int(pct * 100))%")
                            .font(.system(.caption2, design: .monospaced))
                            .foregroundStyle(.secondary)
                    }
                    ProgressView(value: pct)
                        .tint(pct > 1.0 ? .red : pct > 0.9 ? .orange : .blue)
                }
            }

            // Buffer / File info
            if !manager.buffer.isEmpty {
                GroupBox("Buffer") {
                    VStack(alignment: .leading, spacing: 4) {
                        LabeledContent("Size") {
                            Text(manager.formatSize(manager.buffer.count))
                                .font(.system(.caption, design: .monospaced))
                        }
                        LabeledContent("CRC32") {
                            Text(String(format: "%08X", manager.buffer.crc32))
                                .font(.system(.caption, design: .monospaced))
                                .textSelection(.enabled)
                        }
                        LabeledContent("MD5") {
                            Text(manager.buffer.md5.prefix(16) + "...")
                                .font(.system(.caption2, design: .monospaced))
                                .textSelection(.enabled)
                                .help(manager.buffer.md5)
                        }
                        LabeledContent("SHA256") {
                            Text(manager.buffer.sha256.prefix(16) + "...")
                                .font(.system(.caption2, design: .monospaced))
                                .textSelection(.enabled)
                                .help(manager.buffer.sha256)
                        }

                        if let name = manager.loadedFileName {
                            Divider()
                            LabeledContent("File") {
                                Text(name)
                                    .font(.system(.caption, design: .monospaced))
                                    .lineLimit(1)
                                    .truncationMode(.middle)
                            }
                        }
                        if let fmt = manager.loadedFileFormat {
                            LabeledContent("Format") {
                                Text(fmt)
                                    .font(.system(.caption, design: .monospaced))
                            }
                        }
                        if let date = manager.loadedFileModDate {
                            LabeledContent("Modified") {
                                Text(date, style: .relative)
                                    .font(.system(.caption, design: .monospaced))
                            }
                        }
                        if manager.watchedFileURL != nil {
                            HStack(spacing: 4) {
                                Image(systemName: "eye.fill")
                                    .foregroundStyle(.green)
                                    .font(.caption2)
                                Text("Watching for changes")
                                    .font(.caption2)
                                    .foregroundStyle(.green)
                            }
                            .padding(.top, 2)
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.vertical, 4)
                }
            }
        }
    }

    // MARK: - Hex toolbar

    @ViewBuilder
    private var hexToolbar: some View {
        HStack(spacing: 8) {
            Menu {
                Button("Open Binary (.bin)...") { openFile(format: .binary) }
                Button("Open Intel HEX (.hex)...") { openFile(format: .ihex) }
                Divider()
                Button("Import SigmaStudio .dat...") { showSigmaImport = true }
            } label: {
                Label("Open", systemImage: "folder")
            }

            Menu {
                Button("Save as Binary (.bin)...") { saveFile(format: .binary) }
                Button("Save as Intel HEX (.hex)...") { saveFile(format: .ihex) }
            } label: {
                Label("Save", systemImage: "square.and.arrow.down")
            }
            .disabled(manager.buffer.isEmpty)

            Spacer()

            // Watched file indicator
            if let watchedURL = manager.watchedFileURL {
                HStack(spacing: 4) {
                    Image(systemName: "eye.circle.fill")
                        .foregroundStyle(.green)
                        .font(.caption)
                    Text(watchedURL.lastPathComponent)
                        .font(.system(.caption2, design: .monospaced))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                    Button {
                        manager.stopWatchingFile()
                    } label: {
                        Image(systemName: "xmark.circle")
                            .font(.caption2)
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(.secondary)
                }
            }

            if !manager.buffer.isEmpty {
                Text("\(manager.formatSize(manager.buffer.count))")
                    .font(.system(.caption, design: .monospaced))
                    .foregroundStyle(.secondary)
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
        .sheet(isPresented: $showSigmaImport) {
            SigmaStudioImportSheet(isPresented: $showSigmaImport)
        }
    }

    // MARK: - Empty state

    @ViewBuilder
    private var emptyState: some View {
        VStack(spacing: 12) {
            Image(systemName: "memorychip")
                .font(.system(size: 48))
                .foregroundStyle(.quaternary)
            Text("No data in buffer")
                .font(.headline)
                .foregroundStyle(.secondary)
            Text("Read from chip or open a file to get started")
                .font(.caption)
                .foregroundStyle(.tertiary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    // MARK: - File dialogs

    enum FileFormat { case binary, ihex }

    private func openFile(format: FileFormat) {
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false

        switch format {
        case .binary:
            panel.allowedContentTypes = [.data]
            panel.message = "Select a binary file"
        case .ihex:
            panel.allowedContentTypes = [.data, .plainText]
            panel.message = "Select an Intel HEX file"
        }

        guard panel.runModal() == .OK, let url = panel.url else { return }

        switch format {
        case .binary:
            manager.loadFile(url)
        case .ihex:
            manager.loadIntelHex(url)
        }
    }

    private func saveFile(format: FileFormat) {
        let panel = NSSavePanel()

        switch format {
        case .binary:
            panel.allowedContentTypes = [.data]
            panel.nameFieldStringValue = "flash_dump.bin"
        case .ihex:
            panel.allowedContentTypes = [.plainText]
            panel.nameFieldStringValue = "flash_dump.hex"
        }

        panel.message = "Save buffer contents"
        guard panel.runModal() == .OK, let url = panel.url else { return }

        switch format {
        case .binary:
            manager.saveFile(url)
        case .ihex:
            manager.saveIntelHex(url)
        }
    }
}

// MARK: - Action Button

struct ActionButton: View {
    let title: String
    let icon: String
    let color: Color
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Label(title, systemImage: icon)
                .frame(maxWidth: .infinity)
        }
        .tint(color)
        .controlSize(.regular)
    }
}
