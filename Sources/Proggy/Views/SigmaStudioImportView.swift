import SwiftUI
import UniformTypeIdentifiers

struct SigmaStudioImportSheet: View {
    @Environment(DeviceManager.self) private var manager
    @Binding var isPresented: Bool

    @State private var numBytesURL: URL?
    @State private var txBufferURL: URL?
    @State private var selectedChip: String = "25AA256"
    @State private var errorMessage: String?
    @State private var firmwareSize: Int?

    private let chipSizes: [(name: String, size: Int)] = [
        ("25AA010 / 25LC010", 128),
        ("25AA020 / 25LC020", 256),
        ("25AA040 / 25LC040", 512),
        ("25AA080 / 25LC080", 1024),
        ("25AA160 / 25LC160", 2048),
        ("25AA320 / 25LC320", 4096),
        ("25AA640 / 25LC640", 8192),
        ("25AA128 / 25LC128", 16384),
        ("25AA256 / 25LC256", 32768),
        ("25AA512 / 25LC512", 65536),
        ("25AA1024 / 25LC1024", 131072),
        ("W25Q80", 1_048_576),
        ("25Q16", 2_097_152),
    ]

    var body: some View {
        VStack(spacing: 0) {
            // Header
            HStack {
                Image(systemName: "waveform.path")
                    .font(.title2)
                    .foregroundStyle(.purple)
                VStack(alignment: .leading) {
                    Text("Import SigmaStudio Project")
                        .font(.headline)
                    Text("Convert TxBuffer/NumBytes .dat files to EEPROM image")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer()
            }
            .padding()

            Divider()

            VStack(alignment: .leading, spacing: 16) {
                // File selectors
                GroupBox("Input Files") {
                    VStack(alignment: .leading, spacing: 10) {
                        fileSelector(
                            label: "NumBytes .dat",
                            url: numBytesURL,
                            placeholder: "Select NumBytes_IC_1.dat"
                        ) { url in
                            numBytesURL = url
                        }

                        fileSelector(
                            label: "TxBuffer .dat",
                            url: txBufferURL,
                            placeholder: "Select TxBuffer_IC_1.dat"
                        ) { url in
                            txBufferURL = url
                        }
                    }
                    .padding(.vertical, 4)
                }

                // Chip selector
                GroupBox("Target Chip") {
                    Picker("Chip", selection: $selectedChip) {
                        ForEach(chipSizes, id: \.name) { chip in
                            HStack {
                                Text(chip.name)
                                Spacer()
                                Text(formatSize(chip.size))
                                    .foregroundStyle(.secondary)
                            }
                            .tag(chip.name)
                        }
                    }
                    .labelsHidden()
                    .padding(.vertical, 4)
                }

                // Status
                if let error = errorMessage {
                    HStack(spacing: 6) {
                        Image(systemName: "exclamationmark.triangle.fill")
                            .foregroundStyle(.red)
                        Text(error)
                            .font(.caption)
                            .foregroundStyle(.red)
                    }
                }

                if let size = firmwareSize {
                    let chipSize = chipSizes.first { $0.name == selectedChip }?.size ?? 0
                    HStack(spacing: 6) {
                        Image(systemName: "checkmark.circle.fill")
                            .foregroundStyle(.green)
                        Text("Firmware: \(formatSize(size)) / Chip: \(formatSize(chipSize)) (\(Int(Double(size) / Double(chipSize) * 100))% used)")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
            }
            .padding()

            Divider()

            // Actions
            HStack {
                Spacer()
                Button("Cancel") {
                    isPresented = false
                }
                .keyboardShortcut(.cancelAction)

                Button("Import") {
                    importFiles()
                }
                .keyboardShortcut(.defaultAction)
                .disabled(numBytesURL == nil || txBufferURL == nil)
            }
            .padding()
        }
        .frame(width: 500)
    }

    @ViewBuilder
    private func fileSelector(label: String, url: URL?, placeholder: String, onSelect: @escaping (URL) -> Void) -> some View {
        HStack {
            Text(label)
                .font(.caption)
                .frame(width: 90, alignment: .trailing)

            if let url {
                Text(url.lastPathComponent)
                    .font(.system(.caption, design: .monospaced))
                    .lineLimit(1)
                    .truncationMode(.middle)
            } else {
                Text(placeholder)
                    .font(.caption)
                    .foregroundStyle(.tertiary)
            }

            Spacer()

            Button("Browse...") {
                let panel = NSOpenPanel()
                panel.allowedContentTypes = [.plainText, .data]
                panel.allowsMultipleSelection = false
                panel.message = "Select \(label)"
                if panel.runModal() == .OK, let selected = panel.url {
                    onSelect(selected)
                    errorMessage = nil
                    firmwareSize = nil
                }
            }
            .controlSize(.small)
        }
    }

    private func importFiles() {
        guard let numBytesURL, let txBufferURL else { return }

        do {
            let numBytesContent = try String(contentsOf: numBytesURL, encoding: .utf8)
            let txBufferContent = try String(contentsOf: txBufferURL, encoding: .utf8)

            let chipSize = chipSizes.first { $0.name == selectedChip }?.size ?? 32768

            let padded = try SigmaStudio.convertPadded(
                numBytesContent: numBytesContent,
                txBufferContent: txBufferContent,
                chipSize: chipSize
            )

            // Also compute unpadded size for display
            let firmware = try SigmaStudio.convert(
                numBytesContent: numBytesContent,
                txBufferContent: txBufferContent
            )
            firmwareSize = firmware.count

            manager.buffer.load(padded)
            manager.log(.info, "SigmaStudio import: \(formatSize(firmware.count)) firmware, padded to \(formatSize(chipSize)) (\(selectedChip))")
            manager.statusMessage = "Imported SigmaStudio project"

            isPresented = false
        } catch {
            errorMessage = error.localizedDescription
            manager.log(.error, "SigmaStudio import failed: \(error.localizedDescription)")
        }
    }

    private func formatSize(_ bytes: Int) -> String {
        if bytes >= 1_048_576 { return String(format: "%.1f MB", Double(bytes) / 1_048_576.0) }
        if bytes >= 1024 { return String(format: "%.1f KB", Double(bytes) / 1024.0) }
        return "\(bytes) B"
    }
}
