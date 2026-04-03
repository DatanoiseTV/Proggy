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
                OperationProgressView(
                    progress: manager.progress,
                    status: manager.statusMessage,
                    onCancel: { manager.cancelOperation() }
                )
            } else {
                Text(manager.statusMessage)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }
}

// MARK: - Animated Operation Progress

struct OperationProgressView: View {
    let progress: Double
    let status: String
    let onCancel: () -> Void

    @State private var pulseOpacity: Double = 0.6

    private var progressColor: Color {
        if progress < 0.3 { return .blue }
        if progress < 0.7 { return .cyan }
        if progress < 0.95 { return .green }
        return .green
    }

    private var speedText: String {
        // Show percentage prominently
        "\(Int(progress * 100))%"
    }

    var body: some View {
        HStack(spacing: 10) {
            // Animated activity dot
            Circle()
                .fill(progressColor)
                .frame(width: 8, height: 8)
                .opacity(pulseOpacity)
                .animation(.easeInOut(duration: 0.6).repeatForever(autoreverses: true), value: pulseOpacity)
                .onAppear { pulseOpacity = 1.0 }

            // Status text
            Text(status)
                .font(.system(.caption, design: .monospaced))
                .foregroundStyle(.primary)
                .lineLimit(1)

            // Progress bar with glow
            ZStack(alignment: .leading) {
                // Track
                RoundedRectangle(cornerRadius: 3)
                    .fill(.quaternary)
                    .frame(width: 160, height: 6)

                // Fill with gradient
                RoundedRectangle(cornerRadius: 3)
                    .fill(
                        LinearGradient(
                            colors: [progressColor.opacity(0.8), progressColor],
                            startPoint: .leading,
                            endPoint: .trailing
                        )
                    )
                    .frame(width: max(4, 160 * progress), height: 6)
                    .shadow(color: progressColor.opacity(0.5), radius: 4, x: 0, y: 0)
                    .animation(.easeInOut(duration: 0.3), value: progress)
            }

            // Percentage
            Text(speedText)
                .font(.system(.caption, design: .monospaced))
                .fontWeight(.bold)
                .foregroundStyle(progressColor)
                .frame(width: 36, alignment: .trailing)

            // Cancel button
            Button {
                onCancel()
            } label: {
                Image(systemName: "xmark.circle.fill")
                    .font(.caption)
            }
            .buttonStyle(.plain)
            .foregroundStyle(.red.opacity(0.8))
            .help("Cancel operation")
        }
    }
}
