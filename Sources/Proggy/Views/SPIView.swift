import SwiftUI

struct SPIView: View {
    @Environment(DeviceManager.self) private var manager
    @State private var vm = SPIViewModel()

    var body: some View {
        VStack(spacing: 0) {
            // Input area
            VStack(alignment: .leading, spacing: 12) {
                Text("SPI Transfer")
                    .font(.headline)

                HStack(spacing: 8) {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("Data (hex)")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        TextField("e.g. 9F 00 00 00", text: $vm.inputHex)
                            .font(.system(.body, design: .monospaced))
                            .textFieldStyle(.roundedBorder)
                            .onSubmit {
                                vm.send(device: manager.device, manager: manager)
                            }
                    }

                    VStack(alignment: .leading, spacing: 4) {
                        Text(" ")
                            .font(.caption)
                        Button("Send") {
                            vm.send(device: manager.device, manager: manager)
                        }
                        .disabled(!manager.isConnected || vm.isBusy || vm.inputHex.isEmpty)
                        .controlSize(.regular)
                        .keyboardShortcut(.return, modifiers: [])
                    }
                }

                HStack {
                    Toggle("Keep CS low", isOn: $vm.keepCSLow)
                        .toggleStyle(.checkbox)

                    if vm.keepCSLow {
                        Button("Release CS") {
                            vm.releaseCS(device: manager.device)
                        }
                        .controlSize(.small)
                        .tint(.orange)
                    }

                    Spacer()

                    Button("Clear History") {
                        vm.clearHistory()
                    }
                    .controlSize(.small)
                    .disabled(vm.history.isEmpty)
                }
            }
            .padding(16)

            Divider()

            // Transaction history
            if vm.history.isEmpty {
                VStack(spacing: 8) {
                    Image(systemName: "arrow.left.arrow.right")
                        .font(.system(size: 36))
                        .foregroundStyle(.quaternary)
                    Text("No SPI transactions yet")
                        .foregroundStyle(.secondary)
                    Text("Enter hex bytes and press Send to transfer via SPI")
                        .font(.caption)
                        .foregroundStyle(.tertiary)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                List(vm.history) { txn in
                    VStack(alignment: .leading, spacing: 4) {
                        HStack(spacing: 8) {
                            Text(txn.timestampString)
                                .font(.system(.caption2, design: .monospaced))
                                .foregroundStyle(.tertiary)
                            Spacer()
                        }
                        HStack(alignment: .top, spacing: 4) {
                            Text("TX")
                                .font(.system(.caption, design: .monospaced))
                                .foregroundStyle(.blue)
                                .frame(width: 24)
                            Text(txn.sentHex)
                                .font(.system(.body, design: .monospaced))
                                .textSelection(.enabled)
                        }
                        HStack(alignment: .top, spacing: 4) {
                            Text("RX")
                                .font(.system(.caption, design: .monospaced))
                                .foregroundStyle(.green)
                                .frame(width: 24)
                            Text(txn.receivedHex)
                                .font(.system(.body, design: .monospaced))
                                .textSelection(.enabled)
                        }
                    }
                    .padding(.vertical, 4)
                }
                .listStyle(.plain)
                .font(.system(.body, design: .monospaced))
            }
        }
    }
}
