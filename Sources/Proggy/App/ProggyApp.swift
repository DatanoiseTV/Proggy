import SwiftUI

@main
struct ProggyApp: App {
    @State private var manager = DeviceManager()
    @State private var showShortcutsHelp = false
    @State private var showURLSheet = false

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environment(manager)
                .onAppear { AppIconGenerator.setAppIcon() }
                .onDisappear { NSApplication.shared.terminate(nil) }
        }
        .defaultSize(width: 1100, height: 720)
        .commands {
            // File menu
            CommandGroup(replacing: .newItem) {
                Button("Open Binary...") {
                    openFile(format: .binary)
                }
                .keyboardShortcut("o")

                Button("Open Intel HEX...") {
                    openFile(format: .ihex)
                }
                .keyboardShortcut("o", modifiers: [.command, .shift])

                Button("Open from URL...") {
                    showURLSheet = true
                }
                .keyboardShortcut("u")

                Divider()

                // Recent files
                if !manager.recentFiles.isEmpty {
                    Menu("Recent Files") {
                        ForEach(manager.recentFiles, id: \.self) { url in
                            Button(url.lastPathComponent) {
                                let ext = url.pathExtension.lowercased()
                                if ext == "hex" || ext == "ihex" {
                                    manager.loadIntelHex(url)
                                } else {
                                    manager.loadFile(url)
                                }
                            }
                        }
                        Divider()
                        Button("Clear Recent Files") {
                            manager.clearRecentFiles()
                        }
                    }
                    Divider()
                }

                Button("Save as Binary...") {
                    saveFile(format: .binary)
                }
                .keyboardShortcut("s")
                .disabled(manager.buffer.isEmpty)

                Button("Save as Intel HEX...") {
                    saveFile(format: .ihex)
                }
                .keyboardShortcut("s", modifiers: [.command, .shift])
                .disabled(manager.buffer.isEmpty)
            }

            // Edit menu - Undo/Redo
            CommandGroup(replacing: .undoRedo) {
                Button("Undo") {
                    manager.buffer.undo()
                }
                .keyboardShortcut("z")
                .disabled(!manager.buffer.canUndo)

                Button("Redo") {
                    manager.buffer.redo()
                }
                .keyboardShortcut("z", modifiers: [.command, .shift])
                .disabled(!manager.buffer.canRedo)
            }

            // Device menu
            CommandMenu("Device") {
                Button("Connect") {
                    manager.connect()
                }
                .keyboardShortcut("k")
                .disabled(manager.isConnected)

                Button("Disconnect") {
                    manager.disconnect()
                }
                .keyboardShortcut("k", modifiers: [.command, .shift])
                .disabled(!manager.isConnected)

                Divider()

                Button("Auto-Detect") {
                    manager.autoDetectAll()
                }
                .keyboardShortcut("d")
                .disabled(!manager.isConnected || manager.isBusy)

                Divider()

                Picker("Speed", selection: Binding(
                    get: { manager.speed },
                    set: { manager.speed = $0 }
                )) {
                    ForEach(CH341Speed.allCases) { speed in
                        Text(speed.description).tag(speed)
                    }
                }
            }

            // Flash menu
            CommandMenu("Flash") {
                Button("Read Chip") {
                    manager.readChip()
                }
                .keyboardShortcut("r", modifiers: [.command, .shift])
                .disabled(!manager.isConnected || manager.isBusy || manager.chipCapacity == 0)

                Button("Write Chip") {
                    manager.writeChip()
                }
                .keyboardShortcut("w", modifiers: [.command, .shift])
                .disabled(!manager.isConnected || manager.isBusy || manager.buffer.isEmpty)

                Button("Verify Chip") {
                    manager.verifyChip()
                }
                .keyboardShortcut("v", modifiers: [.command, .shift])
                .disabled(!manager.isConnected || manager.isBusy || manager.buffer.isEmpty)

                Divider()

                Button("Erase Chip") {
                    manager.eraseChip()
                }
                .disabled(!manager.isConnected || manager.isBusy)

                Button("Blank Check") {
                    manager.blankCheck()
                }
                .disabled(!manager.isConnected || manager.isBusy || manager.chipCapacity == 0)

                Divider()

                Button("Cancel Operation") {
                    manager.cancelOperation()
                }
                .keyboardShortcut(".", modifiers: .command)
                .disabled(!manager.isBusy)
            }

            // Help menu
            CommandGroup(replacing: .help) {
                Button("Keyboard Shortcuts") {
                    showShortcutsHelp = true
                }
                .keyboardShortcut("/", modifiers: .command)
            }
        }

        // Shortcuts help window
        Window("Keyboard Shortcuts", id: "shortcuts") {
            ShortcutsHelpView()
        }
        .defaultSize(width: 420, height: 500)

        // URL download sheet
        Window("Open from URL", id: "url-open") {
            URLOpenView()
                .environment(manager)
        }
        .defaultSize(width: 460, height: 180)
    }

    // MARK: - File Dialogs

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
        case .binary: manager.loadFile(url)
        case .ihex: manager.loadIntelHex(url)
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
        guard panel.runModal() == .OK, let url = panel.url else { return }
        switch format {
        case .binary: manager.saveFile(url)
        case .ihex: manager.saveIntelHex(url)
        }
    }
}

// MARK: - Keyboard Shortcuts Help

struct ShortcutsHelpView: View {
    private let shortcuts: [(String, String, String)] = [
        ("File", "", ""),
        ("Open Binary", "Cmd+O", ""),
        ("Open Intel HEX", "Cmd+Shift+O", ""),
        ("Open from URL", "Cmd+U", ""),
        ("Save as Binary", "Cmd+S", ""),
        ("Save as Intel HEX", "Cmd+Shift+S", ""),
        ("", "", ""),
        ("Edit", "", ""),
        ("Undo", "Cmd+Z", ""),
        ("Redo", "Cmd+Shift+Z", ""),
        ("", "", ""),
        ("Device", "", ""),
        ("Connect", "Cmd+K", ""),
        ("Disconnect", "Cmd+Shift+K", ""),
        ("Auto-Detect", "Cmd+D", ""),
        ("", "", ""),
        ("Flash", "", ""),
        ("Read Chip", "Cmd+Shift+R", ""),
        ("Write Chip", "Cmd+Shift+W", ""),
        ("Verify Chip", "Cmd+Shift+V", ""),
        ("Cancel Operation", "Cmd+.", ""),
    ]

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text("Keyboard Shortcuts")
                .font(.headline)
                .padding()

            Divider()

            List {
                ForEach(Array(shortcuts.enumerated()), id: \.offset) { _, item in
                    if item.0.isEmpty {
                        Divider()
                    } else if item.1.isEmpty {
                        Text(item.0)
                            .font(.caption)
                            .fontWeight(.bold)
                            .foregroundStyle(.secondary)
                            .padding(.top, 4)
                    } else {
                        HStack {
                            Text(item.0)
                                .font(.system(.body, design: .default))
                            Spacer()
                            Text(item.1)
                                .font(.system(.caption, design: .monospaced))
                                .padding(.horizontal, 6)
                                .padding(.vertical, 2)
                                .background(.quaternary)
                                .cornerRadius(4)
                        }
                    }
                }
            }
            .listStyle(.plain)
        }
    }
}

// MARK: - URL Open View

struct URLOpenView: View {
    @Environment(DeviceManager.self) private var manager
    @Environment(\.dismiss) private var dismiss
    @State private var urlString = ""
    @State private var isLoading = false
    @State private var errorMessage: String?

    var body: some View {
        VStack(spacing: 16) {
            HStack {
                Image(systemName: "globe")
                    .font(.title2)
                    .foregroundStyle(.blue)
                Text("Open from URL")
                    .font(.headline)
                Spacer()
            }

            TextField("https://example.com/firmware.bin", text: $urlString)
                .textFieldStyle(.roundedBorder)
                .font(.system(.body, design: .monospaced))

            if let error = errorMessage {
                Text(error)
                    .font(.caption)
                    .foregroundStyle(.red)
            }

            HStack {
                Spacer()
                Button("Cancel") { dismiss() }
                    .keyboardShortcut(.cancelAction)

                Button("Download") {
                    downloadURL()
                }
                .keyboardShortcut(.defaultAction)
                .disabled(urlString.isEmpty || isLoading)

                if isLoading {
                    ProgressView()
                        .controlSize(.small)
                }
            }
        }
        .padding()
    }

    private func downloadURL() {
        guard let url = URL(string: urlString) else {
            errorMessage = "Invalid URL"
            return
        }

        isLoading = true
        errorMessage = nil

        Task {
            do {
                let (data, _) = try await URLSession.shared.data(from: url)

                await MainActor.run {
                    // Detect format by extension
                    let ext = url.pathExtension.lowercased()
                    if ext == "hex" || ext == "ihex" {
                        do {
                            let content = String(data: data, encoding: .utf8) ?? ""
                            let parsed = try IntelHex.parse(content)
                            manager.buffer.load(parsed)
                            manager.log(.info, "Downloaded IHEX from URL: \(manager.formatSize(parsed.count))")
                        } catch {
                            manager.buffer.load(data)
                            manager.log(.info, "Downloaded from URL: \(manager.formatSize(data.count))")
                        }
                    } else {
                        manager.buffer.load(data)
                        manager.log(.info, "Downloaded from URL: \(manager.formatSize(data.count))")
                    }
                    manager.loadedFileName = url.lastPathComponent
                    manager.loadedFileFormat = "URL"
                    manager.statusMessage = "Downloaded \(url.lastPathComponent)"

                    // Check size vs chip capacity
                    manager.checkBufferFitsChip()

                    isLoading = false
                    dismiss()
                }
            } catch {
                await MainActor.run {
                    errorMessage = error.localizedDescription
                    isLoading = false
                }
            }
        }
    }
}
