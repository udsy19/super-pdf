import AppKit
import SuperPDFCore

// The Headers & footers panel's 2×3 grid of fields (ux §5.3): left/centre/right × top/bottom, each a small text field
// with a "+" menu that inserts a token (Page number, Page count, Date, Title, File name, Author, Bates number).
// Tokens are kept in the text as {page}, {pages}, {date}, {title}, {file}, {author}, {bates}.

/// The six fields' text for one document while its panel is open.
@MainActor
final class HeaderFields {
    let document: DocumentHandle
    /// Top left, top centre, top right, bottom left, bottom centre, bottom right.
    var texts: [String]

    init(document: DocumentHandle, texts: [String]) {
        self.document = document
        self.texts = texts.count == 6 ? texts : Array(repeating: "", count: 6)
    }

    static let changedAction = "fieldsChanged"
    static let positions: [PagePosition] = [.topLeft, .topCenter, .topRight, .bottomLeft, .bottomCenter, .bottomRight]
    static let tokens: [(token: String, title: String, part: HeaderFooterPart)] = [
        ("{page}", EditKitStrings.Headers.tokenPageNumber, .pageNumber), ("{pages}", EditKitStrings.Headers.tokenPageCount, .pageCount),
        ("{date}", EditKitStrings.Headers.tokenDate, .date), ("{title}", EditKitStrings.Headers.tokenTitle, .title),
        ("{file}", EditKitStrings.Headers.tokenFileName, .fileName), ("{author}", EditKitStrings.Headers.tokenAuthor, .author),
        ("{bates}", EditKitStrings.Headers.tokenBates, .batesNumber),
    ]

    func announce() {
        NotificationCenter.default.post(name: ToolPanel.performActionNotification, object: document, userInfo: [ToolPanel.actionKey: Self.changedAction])
    }

    /// The fields as parts, by position (empty fields left out).
    static func fields(from texts: [String]) -> [PagePosition: [HeaderFooterPart]] {
        var fields: [PagePosition: [HeaderFooterPart]] = [:]
        for (position, text) in zip(positions, texts) {
            let parts = parse(text)
            if !parts.isEmpty { fields[position] = parts }
        }
        return fields
    }

    /// "Page {page} of {pages}" → [.text("Page "), .pageNumber, .text(" of "), .pageCount].
    static func parse(_ text: String) -> [HeaderFooterPart] {
        var parts: [HeaderFooterPart] = []
        var rest = Substring(text)
        var literal = ""
        while !rest.isEmpty {
            if rest.hasPrefix("{"), let token = tokens.first(where: { rest.hasPrefix($0.token) }) {
                if !literal.isEmpty { parts.append(.text(literal)); literal = "" }
                parts.append(token.part)
                rest = rest.dropFirst(token.token.count)
            } else {
                literal.append(rest.removeFirst())
            }
        }
        if !literal.isEmpty { parts.append(.text(literal)) }
        return parts
    }

    /// The reverse: parts back to the field's text.
    static func text(of parts: [HeaderFooterPart]) -> String {
        parts.map { part in
            if case .text(let literal) = part { return literal }
            return tokens.first { $0.part == part }?.token ?? ""
        }.joined()
    }
}

/// The grid in the panel.
@MainActor
final class HeaderFieldsView: NSView, NSTextFieldDelegate {
    private let store: HeaderFields
    private var fields: [NSTextField] = []

    init(store: HeaderFields) {
        self.store = store
        super.init(frame: NSRect(x: 0, y: 0, width: 280, height: 122))
        let labels = [EditKitStrings.Headers.topLeft, EditKitStrings.Headers.topCenter, EditKitStrings.Headers.topRight,
                      EditKitStrings.Headers.bottomLeft, EditKitStrings.Headers.bottomCenter, EditKitStrings.Headers.bottomRight]
        let grid = NSGridView()
        grid.translatesAutoresizingMaskIntoConstraints = false
        grid.rowSpacing = 6
        grid.columnSpacing = 6
        for row in 0..<2 {
            var cells: [NSView] = []
            for column in 0..<3 {
                let index = row * 3 + column
                let cell = NSStackView()
                cell.orientation = .vertical
                cell.alignment = .leading
                cell.spacing = 2
                let label = NSTextField(labelWithString: labels[index])
                label.font = .systemFont(ofSize: 10)
                label.textColor = .secondaryLabelColor
                let field = NSTextField(string: store.texts[index])
                field.font = .systemFont(ofSize: 12)
                field.controlSize = .small
                field.placeholderString = ""
                field.delegate = self
                field.tag = index
                field.setAccessibilityLabel(labels[index])
                let plus = NSPopUpButton(frame: .zero, pullsDown: true)
                plus.controlSize = .small
                plus.font = .systemFont(ofSize: 11)
                plus.addItem(withTitle: "+")
                plus.item(at: 0)?.image = NSImage(systemSymbolName: "plus", accessibilityDescription: EditKitStrings.Headers.insert)
                plus.setAccessibilityLabel(EditKitStrings.Headers.insert)
                for (offset, token) in HeaderFields.tokens.enumerated() {
                    let item = NSMenuItem(title: token.title, action: #selector(insertToken(_:)), keyEquivalent: "")
                    item.target = self
                    item.tag = index * 100 + offset
                    plus.menu?.addItem(item)
                }
                let line = NSStackView(views: [field, plus])
                line.spacing = 2
                field.widthAnchor.constraint(greaterThanOrEqualToConstant: 54).isActive = true
                plus.widthAnchor.constraint(equalToConstant: 28).isActive = true
                cell.addArrangedSubview(label)
                cell.addArrangedSubview(line)
                fields.append(field)
                cells.append(cell)
            }
            grid.addRow(with: cells)
        }
        addSubview(grid)
        NSLayoutConstraint.activate([
            grid.leadingAnchor.constraint(equalTo: leadingAnchor), grid.trailingAnchor.constraint(equalTo: trailingAnchor),
            grid.topAnchor.constraint(equalTo: topAnchor), grid.bottomAnchor.constraint(equalTo: bottomAnchor),
        ])
    }

    @available(*, unavailable) required init?(coder: NSCoder) { fatalError() }

    func controlTextDidChange(_ notification: Notification) {
        guard let field = notification.object as? NSTextField, fields.indices.contains(field.tag) else { return }
        store.texts[field.tag] = field.stringValue
        store.announce()
    }

    @objc private func insertToken(_ sender: NSMenuItem) {
        let index = sender.tag / 100, offset = sender.tag % 100
        guard fields.indices.contains(index), HeaderFields.tokens.indices.contains(offset) else { return }
        let field = fields[index]
        field.stringValue += HeaderFields.tokens[offset].token
        store.texts[index] = field.stringValue
        store.announce()
    }
}
