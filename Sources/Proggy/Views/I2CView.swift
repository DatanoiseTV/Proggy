import SwiftUI

struct I2CView: View {
    @Environment(DeviceManager.self) private var manager
    @State private var vm = I2CViewModel()

    var body: some View {
        HSplitView {
            // Left: Controls + Scanner
            VStack(alignment: .leading, spacing: 0) {
                controlsPanel
                    .padding(16)

                Divider()

                scannerPanel
                    .padding(16)

                Spacer()
            }
            .frame(width: 280)
            .background(.background)

            // Right: Transaction history
            VStack(spacing: 0) {
                HStack {
                    Text("Transaction History")
                        .font(.headline)
                    Spacer()
                    Button("Clear") {
                        vm.clearHistory()
                    }
                    .controlSize(.small)
                    .disabled(vm.history.isEmpty)
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 10)

                Divider()

                if vm.history.isEmpty {
                    VStack(spacing: 8) {
                        Image(systemName: "point.3.connected.trianglepath.dotted")
                            .font(.system(size: 36))
                            .foregroundStyle(.quaternary)
                        Text("No I2C transactions yet")
                            .foregroundStyle(.secondary)
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else {
                    List(vm.history) { txn in
                        VStack(alignment: .leading, spacing: 4) {
                            HStack(spacing: 8) {
                                Text(txn.timestampString)
                                    .font(.system(.caption2, design: .monospaced))
                                    .foregroundStyle(.tertiary)
                                AddressBadge(address: txn.address)
                                OperationBadge(op: txn.operation)
                                Spacer()
                            }
                            if !txn.sent.isEmpty {
                                HStack(alignment: .top, spacing: 4) {
                                    Text("TX")
                                        .font(.system(.caption, design: .monospaced))
                                        .foregroundStyle(.orange)
                                        .frame(width: 24)
                                    Text(txn.sentHex)
                                        .font(.system(.body, design: .monospaced))
                                        .textSelection(.enabled)
                                }
                            }
                            if !txn.received.isEmpty {
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
                        }
                        .padding(.vertical, 4)
                    }
                    .listStyle(.plain)
                }
            }
        }
    }

    // MARK: - Controls

    @ViewBuilder
    private var controlsPanel: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("I2C Transfer")
                .font(.headline)

            LabeledContent("Address (hex)") {
                TextField("50", text: $vm.targetAddress)
                    .font(.system(.body, design: .monospaced))
                    .textFieldStyle(.roundedBorder)
                    .frame(width: 80)
            }

            LabeledContent("Register (hex)") {
                TextField("Optional", text: $vm.registerAddress)
                    .font(.system(.body, design: .monospaced))
                    .textFieldStyle(.roundedBorder)
                    .frame(width: 80)
            }

            LabeledContent("Speed") {
                Picker("", selection: $vm.speed) {
                    ForEach(CH341Speed.allCases) { speed in
                        Text(speed.description).tag(speed)
                    }
                }
                .labelsHidden()
                .frame(width: 100)
            }

            Divider()

            // Write
            VStack(alignment: .leading, spacing: 4) {
                Text("Write Data (hex)")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                HStack {
                    TextField("e.g. 01 02 03", text: $vm.writeDataHex)
                        .font(.system(.body, design: .monospaced))
                        .textFieldStyle(.roundedBorder)
                    Button("Write") {
                        vm.write(device: manager.device, manager: manager)
                    }
                    .disabled(!manager.isConnected || vm.isBusy)
                }
            }

            // Read
            VStack(alignment: .leading, spacing: 4) {
                Text("Read")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                HStack {
                    TextField("Bytes", text: $vm.readLength)
                        .font(.system(.body, design: .monospaced))
                        .textFieldStyle(.roundedBorder)
                        .frame(width: 60)
                    Button("Read") {
                        vm.read(device: manager.device, manager: manager)
                    }
                    .disabled(!manager.isConnected || vm.isBusy)
                }
            }
        }
    }

    // MARK: - Scanner

    @ViewBuilder
    private var scannerPanel: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("Bus Scanner")
                    .font(.headline)
                Spacer()
                Button("Scan") {
                    vm.scan(device: manager.device, manager: manager)
                }
                .disabled(!manager.isConnected || vm.isScanning)
                .controlSize(.small)
            }

            if vm.isScanning {
                HStack(spacing: 8) {
                    ProgressView()
                        .controlSize(.small)
                    Text("Scanning 0x03...0x77")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            } else if vm.scanResults.isEmpty {
                Text("No devices found")
                    .font(.caption)
                    .foregroundStyle(.tertiary)
            } else {
                // Grid display like i2cdetect
                I2CScanGrid(results: vm.scanResults) { addr in
                    vm.targetAddress = String(format: "%02X", addr)
                }
            }
        }
    }
}

// MARK: - I2C Scan Grid

struct I2CScanGrid: View {
    let results: [UInt8]
    let onSelect: (UInt8) -> Void

    var body: some View {
        LazyVGrid(columns: Array(repeating: GridItem(.fixed(24), spacing: 2), count: 8), spacing: 2) {
            ForEach(0x00..<0x80, id: \.self) { addr in
                let addr8 = UInt8(addr)
                let found = results.contains(addr8)
                let inRange = addr >= 0x03 && addr <= 0x77

                Text(found ? String(format: "%02X", addr) : (inRange ? "--" : ""))
                    .font(.system(.caption2, design: .monospaced))
                    .frame(width: 24, height: 18)
                    .background(found ? Color.green.opacity(0.3) : Color.clear)
                    .cornerRadius(2)
                    .foregroundStyle(found ? .primary : .quaternary)
                    .onTapGesture {
                        if found { onSelect(addr8) }
                    }
            }
        }
    }
}

// MARK: - Badges

struct AddressBadge: View {
    let address: UInt8
    var body: some View {
        Text(String(format: "0x%02X", address))
            .font(.system(.caption, design: .monospaced))
            .padding(.horizontal, 4)
            .padding(.vertical, 1)
            .background(.blue.opacity(0.15))
            .cornerRadius(3)
    }
}

struct OperationBadge: View {
    let op: String
    var body: some View {
        Text(op)
            .font(.system(.caption, design: .monospaced))
            .fontWeight(.medium)
            .padding(.horizontal, 4)
            .padding(.vertical, 1)
            .background(op == "R" ? Color.green.opacity(0.15) : op == "W" ? Color.orange.opacity(0.15) : Color.purple.opacity(0.15))
            .cornerRadius(3)
    }
}
