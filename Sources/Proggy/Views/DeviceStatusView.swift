import SwiftUI

struct DeviceStatusBar: View {
    @Environment(DeviceManager.self) private var manager

    var body: some View {
        HStack(spacing: 16) {
            // Connection indicator
            HStack(spacing: 6) {
                Image(systemName: manager.isConnected ? "cable.connector" : "cable.connector.slash")
                    .foregroundStyle(manager.isConnected ? .green : .secondary)
                Text(manager.deviceInfo)
                    .font(.system(.caption, design: .monospaced))
            }

            // Chip info
            if let chip = manager.chipInfo {
                Divider().frame(height: 16)
                HStack(spacing: 6) {
                    Image(systemName: "memorychip")
                        .foregroundStyle(.blue)
                    if let name = manager.chipName {
                        Text(name)
                            .font(.system(.caption, design: .monospaced))
                            .fontWeight(.medium)
                    }
                    Text(chip.description)
                        .font(.system(.caption, design: .monospaced))
                        .foregroundStyle(.secondary)
                }
            }

            Spacer()

            // API indicator
            if manager.apiServer.isRunning {
                HStack(spacing: 3) {
                    Circle()
                        .fill(.green)
                        .frame(width: 6, height: 6)
                    Text("API :\(manager.apiServer.port)")
                        .font(.system(.caption2, design: .monospaced))
                        .foregroundStyle(.secondary)
                }
            }

            // Progress / Status
            if manager.isBusy {
                HStack(spacing: 8) {
                    ProgressView(value: manager.progress)
                        .progressViewStyle(.linear)
                        .frame(width: 120)
                    Text("\(Int(manager.progress * 100))%")
                        .font(.system(.caption, design: .monospaced))
                        .foregroundStyle(.secondary)
                        .frame(width: 36, alignment: .trailing)
                    Button("Cancel", systemImage: "xmark.circle.fill") {
                        manager.cancelOperation()
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(.red)
                    .labelStyle(.iconOnly)
                }
            } else {
                Text(manager.statusMessage)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }
}
