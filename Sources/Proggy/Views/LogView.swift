import SwiftUI

struct LogView: View {
    @Environment(DeviceManager.self) private var manager

    var body: some View {
        VStack(spacing: 0) {
            // Log header
            HStack {
                Text("Log")
                    .font(.caption)
                    .fontWeight(.medium)
                    .foregroundStyle(.secondary)
                Spacer()
                Button("Copy All") {
                    let text = manager.logEntries.map { "\($0.timestampString) \($0.level.rawValue) \($0.message)" }.joined(separator: "\n")
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(text, forType: .string)
                }
                .controlSize(.mini)
                .disabled(manager.logEntries.isEmpty)

                Button("Clear") {
                    manager.logEntries.removeAll()
                }
                .controlSize(.mini)
                .disabled(manager.logEntries.isEmpty)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 4)
            .background(.bar)

            Divider()

            // Log entries
            ScrollViewReader { proxy in
                ScrollView(.vertical) {
                    LazyVStack(alignment: .leading, spacing: 1) {
                        ForEach(manager.logEntries) { entry in
                            HStack(alignment: .top, spacing: 8) {
                                Text(entry.timestampString)
                                    .font(.system(.caption2, design: .monospaced))
                                    .foregroundStyle(.tertiary)
                                    .frame(width: 80, alignment: .leading)

                                Text(entry.level.rawValue)
                                    .font(.system(.caption2, design: .monospaced))
                                    .fontWeight(.medium)
                                    .foregroundStyle(entry.level.color)
                                    .frame(width: 36, alignment: .leading)

                                Text(entry.message)
                                    .font(.system(.caption, design: .monospaced))
                                    .foregroundStyle(.primary)
                                    .textSelection(.enabled)
                            }
                            .padding(.horizontal, 12)
                            .padding(.vertical, 1)
                            .id(entry.id)
                        }
                    }
                    .padding(.vertical, 4)
                }
                .onChange(of: manager.logEntries.count) { _, _ in
                    if let last = manager.logEntries.last {
                        withAnimation {
                            proxy.scrollTo(last.id, anchor: .bottom)
                        }
                    }
                }
            }
        }
    }
}
