import SwiftUI
import AppKit

// MARK: - High-performance hex editor using NSTableView

struct HexEditorView: NSViewRepresentable {
    let buffer: HexDataBuffer
    @Binding var goToAddress: String

    static let bytesPerRow = 16
    static let rowHeight: CGFloat = 18

    func makeNSView(context: Context) -> NSScrollView {
        let scrollView = NSScrollView()
        scrollView.hasVerticalScroller = true
        scrollView.hasHorizontalScroller = false
        scrollView.autohidesScrollers = true
        scrollView.borderType = .noBorder

        let tableView = NSTableView()
        tableView.style = .plain
        tableView.rowHeight = Self.rowHeight
        tableView.intercellSpacing = NSSize(width: 0, height: 0)
        tableView.headerView = nil
        tableView.selectionHighlightStyle = .regular
        tableView.allowsMultipleSelection = false
        tableView.gridStyleMask = []

        // Single column for the whole row
        let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("hex"))
        column.title = ""
        column.isEditable = false
        tableView.addTableColumn(column)

        tableView.delegate = context.coordinator
        tableView.dataSource = context.coordinator

        scrollView.documentView = tableView
        context.coordinator.tableView = tableView

        return scrollView
    }

    func updateNSView(_ scrollView: NSScrollView, context: Context) {
        context.coordinator.buffer = buffer
        context.coordinator.tableView?.reloadData()
    }

    func makeCoordinator() -> Coordinator {
        Coordinator(buffer: buffer)
    }

    class Coordinator: NSObject, NSTableViewDelegate, NSTableViewDataSource {
        var buffer: HexDataBuffer
        weak var tableView: NSTableView?

        // Pre-computed attributed string styles
        private let monoFont = NSFont.monospacedSystemFont(ofSize: 12, weight: .regular)
        private let addrAttrs: [NSAttributedString.Key: Any]
        private let zeroAttrs: [NSAttributedString.Key: Any]
        private let ffAttrs: [NSAttributedString.Key: Any]
        private let dataAttrs: [NSAttributedString.Key: Any]
        private let asciiAttrs: [NSAttributedString.Key: Any]
        private let sepAttrs: [NSAttributedString.Key: Any]

        init(buffer: HexDataBuffer) {
            self.buffer = buffer
            let font = NSFont.monospacedSystemFont(ofSize: 12, weight: .regular)
            addrAttrs = [.font: font, .foregroundColor: NSColor.secondaryLabelColor]
            zeroAttrs = [.font: font, .foregroundColor: NSColor.secondaryLabelColor.withAlphaComponent(0.35)]
            ffAttrs = [.font: font, .foregroundColor: NSColor.secondaryLabelColor.withAlphaComponent(0.5)]
            dataAttrs = [.font: font, .foregroundColor: NSColor.labelColor]
            asciiAttrs = [.font: font, .foregroundColor: NSColor.systemOrange]
            sepAttrs = [.font: font, .foregroundColor: NSColor.clear]
            super.init()
        }

        func numberOfRows(in tableView: NSTableView) -> Int {
            (buffer.count + HexEditorView.bytesPerRow - 1) / HexEditorView.bytesPerRow
        }

        func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
            let cellID = NSUserInterfaceItemIdentifier("HexCell")
            let cell: NSTextField
            if let existing = tableView.makeView(withIdentifier: cellID, owner: nil) as? NSTextField {
                cell = existing
            } else {
                cell = NSTextField(labelWithAttributedString: NSAttributedString())
                cell.identifier = cellID
                cell.isEditable = false
                cell.isBordered = false
                cell.drawsBackground = false
                cell.isSelectable = true
                cell.lineBreakMode = .byClipping
                cell.cell?.truncatesLastVisibleLine = true
            }

            cell.attributedStringValue = buildRowString(row: row)
            return cell
        }

        func tableView(_ tableView: NSTableView, heightOfRow row: Int) -> CGFloat {
            HexEditorView.rowHeight
        }

        // Build a single attributed string for the entire row — this is the key perf optimization
        private func buildRowString(row: Int) -> NSAttributedString {
            let bpr = HexEditorView.bytesPerRow
            let offset = row * bpr
            let bytes = buffer.bytes(at: offset, count: bpr)
            let result = NSMutableAttributedString()

            // Address
            result.append(NSAttributedString(
                string: String(format: "%08X  ", offset),
                attributes: addrAttrs
            ))

            // Hex bytes
            for col in 0..<bpr {
                if col < bytes.count {
                    let byte = bytes[col]
                    let attrs: [NSAttributedString.Key: Any]
                    if byte == 0x00 { attrs = zeroAttrs }
                    else if byte == 0xFF { attrs = ffAttrs }
                    else { attrs = dataAttrs }
                    result.append(NSAttributedString(
                        string: String(format: "%02X", byte),
                        attributes: attrs
                    ))
                } else {
                    result.append(NSAttributedString(string: "  ", attributes: dataAttrs))
                }
                // Separator
                result.append(NSAttributedString(
                    string: col == 7 ? "  " : " ",
                    attributes: dataAttrs
                ))
            }

            // ASCII column
            result.append(NSAttributedString(string: " ", attributes: dataAttrs))
            var ascii = ""
            for byte in bytes {
                ascii.append((byte >= 0x20 && byte <= 0x7E) ? Character(UnicodeScalar(byte)) : ".")
            }
            result.append(NSAttributedString(string: ascii, attributes: asciiAttrs))

            return result
        }

        func scrollToAddress(_ address: Int) {
            let row = address / HexEditorView.bytesPerRow
            guard let tableView, row < numberOfRows(in: tableView) else { return }
            tableView.scrollRowToVisible(row)
            tableView.selectRowIndexes(IndexSet(integer: row), byExtendingSelection: false)
        }
    }
}

// MARK: - Wrapper with toolbar

struct HexEditorPanel: View {
    let buffer: HexDataBuffer
    @State private var goToAddress: String = ""
    @State private var editAddress: String = ""
    @State private var editValue: String = ""
    @State private var showEditor: Bool = false

    var body: some View {
        VStack(spacing: 0) {
            // Column header + edit bar
            hexColumnHeader
                .padding(.horizontal, 14)
                .padding(.vertical, 5)
                .background(.bar)

            if showEditor {
                Divider()
                byteEditBar
                    .padding(.horizontal, 14)
                    .padding(.vertical, 4)
                    .background(.bar)
            }

            Divider()

            // NSTableView hex editor
            HexEditorRepresentable(buffer: buffer, goToAddress: $goToAddress)
        }
    }

    // MARK: - Byte Edit Bar

    @ViewBuilder
    private var byteEditBar: some View {
        HStack(spacing: 8) {
            Image(systemName: "pencil")
                .foregroundStyle(.orange)
                .font(.caption)

            HStack(spacing: 4) {
                Text("Addr:")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                TextField("0000", text: $editAddress)
                    .font(.system(.caption, design: .monospaced))
                    .textFieldStyle(.roundedBorder)
                    .frame(width: 72)
            }

            HStack(spacing: 4) {
                Text("Value:")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                TextField("FF", text: $editValue)
                    .font(.system(.caption, design: .monospaced))
                    .textFieldStyle(.roundedBorder)
                    .frame(width: 40)
                    .onSubmit { applyEdit() }
            }

            Button("Set") { applyEdit() }
                .controlSize(.small)

            Divider().frame(height: 16)

            Button {
                buffer.undo()
            } label: {
                Image(systemName: "arrow.uturn.backward")
            }
            .disabled(!buffer.canUndo)
            .controlSize(.small)
            .help("Undo")

            Button {
                buffer.redo()
            } label: {
                Image(systemName: "arrow.uturn.forward")
            }
            .disabled(!buffer.canRedo)
            .controlSize(.small)
            .help("Redo")

            Spacer()
        }
    }

    private func applyEdit() {
        let addrStr = editAddress.replacingOccurrences(of: "0x", with: "")
        guard let addr = Int(addrStr, radix: 16), addr < buffer.count else { return }

        // Support multiple bytes: "FF 00 A1"
        let byteStrs = editValue.split(separator: " ")
        for (i, byteStr) in byteStrs.enumerated() {
            let offset = addr + i
            guard offset < buffer.count else { break }
            if let val = UInt8(byteStr, radix: 16) {
                buffer[offset] = val
            }
        }

        editValue = ""
    }

    @ViewBuilder
    private var hexColumnHeader: some View {
        HStack(spacing: 6) {
            // Go to address
            HStack(spacing: 4) {
                Image(systemName: "arrow.right.circle")
                    .foregroundStyle(.secondary)
                    .font(.caption)
                TextField("Go to address...", text: $goToAddress)
                    .font(.system(.caption, design: .monospaced))
                    .textFieldStyle(.roundedBorder)
                    .frame(width: 110)
                    .onSubmit { /* handled by representable */ }
            }

            Button {
                withAnimation { showEditor.toggle() }
            } label: {
                Image(systemName: showEditor ? "pencil.circle.fill" : "pencil.circle")
            }
            .buttonStyle(.plain)
            .foregroundStyle(showEditor ? .orange : .secondary)
            .help("Toggle byte editor")

            Spacer()

            // Column headers
            Text(columnHeaderString)
                .font(.system(size: 10, weight: .regular, design: .monospaced))
                .foregroundStyle(.tertiary)
        }
    }

    private var columnHeaderString: String {
        let cols = (0..<16).map { String(format: "%02X", $0) }
        let left = cols[0..<8].joined(separator: " ")
        let right = cols[8..<16].joined(separator: " ")
        return "Address   \(left)  \(right)  ASCII"
    }
}

// MARK: - NSViewRepresentable wrapper

struct HexEditorRepresentable: NSViewRepresentable {
    let buffer: HexDataBuffer
    @Binding var goToAddress: String

    func makeNSView(context: Context) -> NSScrollView {
        let scrollView = NSScrollView()
        scrollView.hasVerticalScroller = true
        scrollView.hasHorizontalScroller = false
        scrollView.autohidesScrollers = false
        scrollView.scrollerStyle = .overlay
        scrollView.borderType = .noBorder
        scrollView.backgroundColor = .clear

        let tableView = NSTableView()
        tableView.style = .plain
        tableView.rowHeight = 18
        tableView.intercellSpacing = NSSize(width: 0, height: 1)
        tableView.headerView = nil
        tableView.selectionHighlightStyle = .regular
        tableView.allowsMultipleSelection = false
        tableView.focusRingType = .none

        let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("hex"))
        column.isEditable = false
        column.width = 900
        column.minWidth = 700
        tableView.addTableColumn(column)

        let coordinator = context.coordinator
        tableView.delegate = coordinator
        tableView.dataSource = coordinator
        coordinator.tableView = tableView

        scrollView.documentView = tableView
        return scrollView
    }

    func updateNSView(_ scrollView: NSScrollView, context: Context) {
        let coordinator = context.coordinator
        let needsReload = coordinator.buffer !== buffer || coordinator.lastCount != buffer.count

        coordinator.buffer = buffer
        coordinator.lastCount = buffer.count

        if needsReload {
            coordinator.tableView?.reloadData()
        }

        // Handle go-to-address
        let cleaned = goToAddress
            .replacingOccurrences(of: "0x", with: "")
            .replacingOccurrences(of: " ", with: "")
        if !cleaned.isEmpty, let addr = UInt32(cleaned, radix: 16) {
            // Only scroll once per address entry (avoid repeated scrolls on every update)
            if coordinator.lastScrollAddr != addr {
                coordinator.lastScrollAddr = addr
                coordinator.scrollToAddress(Int(addr))
            }
        }
    }

    func makeCoordinator() -> Coordinator {
        Coordinator(buffer: buffer)
    }

    class Coordinator: NSObject, NSTableViewDelegate, NSTableViewDataSource {
        var buffer: HexDataBuffer
        var lastCount: Int = 0
        var lastScrollAddr: UInt32 = .max
        weak var tableView: NSTableView?

        private let monoFont = NSFont.monospacedSystemFont(ofSize: 12, weight: .regular)
        private let addrColor = NSColor.secondaryLabelColor
        private let zeroColor = NSColor.secondaryLabelColor.withAlphaComponent(0.3)
        private let ffColor = NSColor.secondaryLabelColor.withAlphaComponent(0.45)
        private let dataColor = NSColor.labelColor
        private let asciiColor = NSColor.systemOrange

        init(buffer: HexDataBuffer) {
            self.buffer = buffer
            super.init()
        }

        func numberOfRows(in tableView: NSTableView) -> Int {
            (buffer.count + 15) / 16
        }

        func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
            let cellID = NSUserInterfaceItemIdentifier("HexCell")
            let cell: NSTextField
            if let reused = tableView.makeView(withIdentifier: cellID, owner: nil) as? NSTextField {
                cell = reused
            } else {
                cell = NSTextField(labelWithAttributedString: NSAttributedString())
                cell.identifier = cellID
                cell.isEditable = false
                cell.isBordered = false
                cell.drawsBackground = false
                cell.isSelectable = true
                cell.lineBreakMode = .byClipping
                cell.maximumNumberOfLines = 1
            }
            cell.attributedStringValue = renderRow(row)
            return cell
        }

        private func renderRow(_ row: Int) -> NSAttributedString {
            let offset = row * 16
            let bytes = buffer.bytes(at: offset, count: 16)
            let s = NSMutableAttributedString()

            // Address
            s.append(NSAttributedString(
                string: String(format: "%08X  ", offset),
                attributes: [.font: monoFont, .foregroundColor: addrColor]
            ))

            // Hex bytes with color coding
            for col in 0..<16 {
                if col < bytes.count {
                    let b = bytes[col]
                    let color: NSColor
                    switch b {
                    case 0x00: color = zeroColor
                    case 0xFF: color = ffColor
                    default: color = dataColor
                    }
                    s.append(NSAttributedString(
                        string: String(format: "%02X", b),
                        attributes: [.font: monoFont, .foregroundColor: color]
                    ))
                } else {
                    s.append(NSAttributedString(
                        string: "  ",
                        attributes: [.font: monoFont, .foregroundColor: dataColor]
                    ))
                }
                s.append(NSAttributedString(
                    string: col == 7 ? "  " : " ",
                    attributes: [.font: monoFont, .foregroundColor: dataColor]
                ))
            }

            // ASCII
            s.append(NSAttributedString(string: " ", attributes: [.font: monoFont]))
            var ascii = ""
            for b in bytes {
                ascii.append((b >= 0x20 && b <= 0x7E) ? Character(UnicodeScalar(b)) : ".")
            }
            s.append(NSAttributedString(
                string: ascii,
                attributes: [.font: monoFont, .foregroundColor: asciiColor]
            ))

            return s
        }

        func scrollToAddress(_ address: Int) {
            guard let tableView else { return }
            let row = address / 16
            let total = numberOfRows(in: tableView)
            guard row < total else { return }
            tableView.scrollRowToVisible(row)
            tableView.selectRowIndexes(IndexSet(integer: row), byExtendingSelection: false)
        }
    }
}
