import AppKit
import PDFKit
import PDFModelKit
import SuperPDFCore
import UniformTypeIdentifiers

/// One row of a list mode: a small page picture or a symbol, a title, lines under it, and buttons (Reply, Resolve).
struct SidebarRow {
    var page: Int?
    var symbol: String?
    var symbolColor: NSColor?
    /// 11 pt bold over the text (Highlights and Notes: the page number, Preview's cell).
    var heading: String?
    var title: String
    var detail: String?
    var buttons: [(title: String, action: () -> Void)] = []
    var onClick: (() -> Void)?
}

/// A list mode of the sidebar: a header (filter chips, sort, Verify all), rows, or the empty sentence.
@MainActor
class SidebarListController: NSViewController, NSTableViewDataSource, NSTableViewDelegate, SidebarRefreshing {
    unowned let owner: DocumentWindowController
    let tableView = NSTableView()
    let header = NSStackView()
    private let scrollView = NSScrollView()
    private let emptyLabel = NSTextField(wrappingLabelWithString: "")
    var rows: [SidebarRow] = []
    /// Preview's row heights: 45 pt bookmarks, 50 pt + insets for search results.
    var rowHeight: CGFloat = 44

    var document: DocumentHandle { owner.handle }

    init(owner: DocumentWindowController) {
        self.owner = owner
        super.init(nibName: nil, bundle: nil)
    }

    required init?(coder: NSCoder) { fatalError("not used") }

    override func loadView() {
        tableView.addTableColumn(NSTableColumn(identifier: NSUserInterfaceItemIdentifier("row")))
        tableView.headerView = nil
        tableView.style = .sourceList
        tableView.backgroundColor = .clear
        tableView.usesAutomaticRowHeights = true
        tableView.dataSource = self
        tableView.delegate = self
        tableView.target = self
        tableView.action = #selector(clicked(_:))
        scrollView.documentView = tableView
        scrollView.drawsBackground = false
        scrollView.hasVerticalScroller = true
        scrollView.autohidesScrollers = true
        header.orientation = .horizontal
        header.spacing = 6
        header.edgeInsets = NSEdgeInsets(top: 8, left: 10, bottom: 4, right: 10)
        emptyLabel.font = SPFont.body.font()
        emptyLabel.textColor = SPColor.secondaryLabel.color
        emptyLabel.alignment = .center

        let root = NSView()
        for view in [header, scrollView, emptyLabel] as [NSView] {
            view.translatesAutoresizingMaskIntoConstraints = false
            root.addSubview(view)
        }
        NSLayoutConstraint.activate([
            header.topAnchor.constraint(equalTo: root.topAnchor), header.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            header.trailingAnchor.constraint(lessThanOrEqualTo: root.trailingAnchor),
            scrollView.topAnchor.constraint(equalTo: header.bottomAnchor), scrollView.bottomAnchor.constraint(equalTo: root.bottomAnchor),
            scrollView.leadingAnchor.constraint(equalTo: root.leadingAnchor), scrollView.trailingAnchor.constraint(equalTo: root.trailingAnchor),
            emptyLabel.centerYAnchor.constraint(equalTo: root.centerYAnchor),
            emptyLabel.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 16),
            emptyLabel.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -16),
        ])
        view = root
        setUpHeader()
        refresh()
    }

    /// Subclasses add chips or buttons to `header`.
    func setUpHeader() {}

    /// Subclasses rebuild `rows` and call `show(_:empty:)`.
    func refresh() {}

    func show(_ rows: [SidebarRow], empty: String) {
        self.rows = rows
        guard isViewLoaded else { return }
        tableView.reloadData()
        emptyLabel.stringValue = empty
        emptyLabel.isHidden = !rows.isEmpty
    }

    func numberOfRows(in tableView: NSTableView) -> Int { rows.count }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        SidebarRowView(rows[row], document: document, minimumHeight: rowHeight)
    }

    @objc private func clicked(_ sender: Any?) {
        let row = tableView.clickedRow
        guard rows.indices.contains(row) else { return }
        if let onClick = rows[row].onClick { onClick() } else if let page = rows[row].page { owner.go(toPage: page) }
    }

    /// A filter chip (ux §6.3): a small recessed button that stays on.
    func chip(_ title: String, on: Bool, action: Selector) -> NSButton {
        let button = NSButton(title: title, target: self, action: action)
        button.setButtonType(.pushOnPushOff)
        button.bezelStyle = .push
        button.controlSize = .small
        button.state = on ? .on : .off
        return button
    }
}

/// A row: picture or symbol at the left, the text, then the buttons under it.
final class SidebarRowView: NSTableCellView {
    init(_ row: SidebarRow, document: DocumentHandle, minimumHeight: CGFloat) {
        super.init(frame: .zero)
        let text = NSStackView()
        text.orientation = .vertical
        text.alignment = .leading
        text.spacing = 2
        if let heading = row.heading {
            let label = NSTextField(labelWithString: heading)
            label.font = SPFont.notesPageNumber.font()
            text.addArrangedSubview(label)
        }
        let title = NSTextField(wrappingLabelWithString: row.title)
        title.font = SPFont.body.font()
        title.maximumNumberOfLines = 3
        text.addArrangedSubview(title)
        if let detail = row.detail {
            let label = NSTextField(labelWithString: detail)
            label.font = SPFont.secondary.font()
            label.textColor = SPColor.secondaryLabel.color
            text.addArrangedSubview(label)
        }
        if !row.buttons.isEmpty {
            let buttons = NSStackView()
            buttons.spacing = 6
            for (title, action) in row.buttons {
                let button = ClosureButton(title: title, action: action)
                button.controlSize = .small
                button.bezelStyle = .push
                buttons.addArrangedSubview(button)
            }
            text.addArrangedSubview(buttons)
        }
        let leading: NSView
        if let index = row.page, let page = document.pdf.page(at: index) {
            let picture = PageThumbnailView()
            picture.style = ThumbnailStyle(pageRadius: 2, borderWidth: 1, borderAlpha: 1, shadowBlur: 2, shadowAlpha: 0.1, ringRadius: 0,
                                           ringWidth: 0, ringOffset: 0, selectionFill: false, labelGap: -ThumbnailStyle.labelHeight)
            let box = page.bounds(for: .cropBox)
            picture.aspect = page.rotation % 180 == 0 ? box.height / max(box.width, 1) : box.width / max(box.height, 1)
            picture.image = ThumbnailRenderer.shared.cachedImage(for: page, pixelWidth: 76)
            if picture.image == nil {
                ThumbnailRenderer.shared.image(for: page, pixelWidth: 76) { [weak picture] image in picture?.image = image }
            }
            let size = SPMetrics.Sidebar.searchThumbnail
            picture.widthAnchor.constraint(equalToConstant: size.width).isActive = true
            picture.heightAnchor.constraint(equalToConstant: size.height).isActive = true
            leading = picture
        } else {
            let image = NSImageView(image: NSImage(systemSymbolName: row.symbol ?? "doc", accessibilityDescription: nil) ?? NSImage())
            image.symbolConfiguration = .init(pointSize: 16, weight: .regular)
            image.contentTintColor = row.symbolColor ?? SPColor.secondaryLabel.color
            image.widthAnchor.constraint(equalToConstant: 24).isActive = true
            leading = image
        }
        let stack = NSStackView(views: [leading, text])
        stack.alignment = .top
        stack.spacing = 8
        stack.edgeInsets = NSEdgeInsets(top: 6, left: 4, bottom: 6, right: 4)
        stack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(stack)
        NSLayoutConstraint.activate([stack.leadingAnchor.constraint(equalTo: leadingAnchor), stack.trailingAnchor.constraint(equalTo: trailingAnchor),
                                     stack.topAnchor.constraint(equalTo: topAnchor), stack.bottomAnchor.constraint(equalTo: bottomAnchor),
                                     heightAnchor.constraint(greaterThanOrEqualToConstant: minimumHeight)])
    }

    required init?(coder: NSCoder) { fatalError("not used") }
}

/// A button that runs a closure.
final class ClosureButton: NSButton {
    private var handler: () -> Void = {}

    convenience init(title: String, action: @escaping () -> Void) {
        self.init(frame: .zero)
        self.title = title
        handler = action
        target = self
        self.action = #selector(run(_:))
    }

    @objc private func run(_ sender: Any?) { handler() }
}

// MARK: - Highlights and Notes (ux §6.3)

@MainActor
final class NotesSidebarController: SidebarListController {
    private enum Filter { case all, mine, unresolved }
    private var filter = Filter.all
    private var chips: [NSButton] = []

    override func setUpHeader() {
        chips = [chip(ViewerStrings.Sidebar.all, on: true, action: #selector(filterAll)),
                 chip(ViewerStrings.Sidebar.mine, on: false, action: #selector(filterMine)),
                 chip(ViewerStrings.Sidebar.unresolved, on: false, action: #selector(filterUnresolved))]
        chips.forEach(header.addArrangedSubview)
    }

    @objc private func filterAll() { setFilter(.all) }
    @objc private func filterMine() { setFilter(.mine) }
    @objc private func filterUnresolved() { setFilter(.unresolved) }

    private func setFilter(_ filter: Filter) {
        self.filter = filter
        for (chip, value) in zip(chips, [Filter.all, .mine, .unresolved]) { chip.state = value == filter ? .on : .off }
        refresh()
    }

    override func refresh() {
        let markup = Services.markup
        let author = markup?.authorName ?? ""
        let comments = (markup?.comments(in: document) ?? []).filter { comment in
            switch filter {
            case .all: true
            case .mine: comment.author == author
            case .unresolved: comment.status != .resolved && comment.status != .completed
            }
        }
        let rows = comments.map { comment in
            SidebarRow(page: nil, symbol: comment.kind == .highlight ? "highlighter" : "text.bubble", symbolColor: SPColor.highlightYellow.color,
                       heading: ViewerStrings.Sidebar.page("\(comment.page + 1)"),
                       title: comment.text.isEmpty ? (comment.quotedText ?? "") : comment.text,
                       detail: comment.author.isEmpty ? nil : comment.author,
                       buttons: [(ViewerStrings.Sidebar.reply, { [weak self] in self?.reply(to: comment) }),
                                 (ViewerStrings.Sidebar.resolve, { [weak self] in self?.resolve(comment) })],
                       onClick: { [weak self] in self?.owner.go(toPage: comment.page) })
        }
        show(rows, empty: filter == .unresolved ? Strings.Empty.commentsUnresolved : Strings.Empty.highlightsAndNotes)
    }

    private func reply(to comment: CommentItem) {
        let alert = NSAlert()
        alert.messageText = ViewerStrings.Sidebar.reply
        let field = NSTextField(frame: NSRect(x: 0, y: 0, width: 260, height: 24))
        alert.accessoryView = field
        alert.addButton(withTitle: ViewerStrings.Sidebar.reply)
        alert.addButton(withTitle: Strings.Panel.cancel)
        alert.window.initialFirstResponder = field
        guard let window = view.window else { return }
        alert.beginSheetModal(for: window) { [weak self] response in
            MainActor.assumeIsolated {
                guard let self, response == .alertFirstButtonReturn, !field.stringValue.isEmpty, let markup = Services.markup else { return }
                self.commit(markup.reply(to: comment, text: field.stringValue, in: self.document))
            }
        }
    }

    private func resolve(_ comment: CommentItem) {
        guard let markup = Services.markup else { return }
        commit(markup.setStatus(.resolved, of: comment, in: document))
    }

    private func commit(_ group: UndoGroup) {
        Task {
            try? await Services.documents.apply(.inPlace(undoable: group, banner: nil),
                                                of: ToolRequest(tool: .commentsList, document: document, workFolder: SuperPDFPaths.work))
            refresh()
        }
    }
}

// MARK: - Bookmarks (ux §6.3, features #7): personal bookmarks kept in app data, never written into the file

@MainActor
final class BookmarksSidebarController: SidebarListController {
    override func loadView() {
        rowHeight = SPMetrics.Sidebar.bookmarkRowHeight
        super.loadView()
    }

    override func refresh() {
        let pages = Bookmarks.pages(for: document)
        let rows = pages.filter { $0 < document.pageCount }.map { index in
            SidebarRow(page: index, title: ViewerStrings.Sidebar.page(document.pdf.page(at: index)?.label ?? "\(index + 1)"),
                       buttons: [(ViewerStrings.Sidebar.removeBookmark, { [weak self] in
                           guard let self else { return }
                           Bookmarks.toggle(index, in: self.document)
                           self.refresh()
                       })])
        }
        show(rows, empty: "")
    }
}

/// Bookmarks by file (features #7: in app data when not written into the file). Module-private setting.
@MainActor
enum Bookmarks {
    static let key = Defaults.Key<[String: [Int]]>("viewerKit.bookmarks", default: [:])

    private static func id(_ document: DocumentHandle) -> String { document.url?.standardizedFileURL.path ?? document.id.uuidString }

    static func pages(for document: DocumentHandle) -> [Int] { Defaults[key][id(document)] ?? [] }

    static func contains(_ page: Int, in document: DocumentHandle) -> Bool { pages(for: document).contains(page) }

    static func toggle(_ page: Int, in document: DocumentHandle) {
        var all = Defaults[key]
        var pages = all[id(document)] ?? []
        if let index = pages.firstIndex(of: page) { pages.remove(at: index) } else { pages.append(page); pages.sort() }
        all[id(document)] = pages.isEmpty ? nil : pages
        Defaults[key] = all
    }
}

// MARK: - Attachments (ux §6.3, features #9)

/// The document's embedded files (read with PDFModelKit off the main actor) and the files clipped to pages; Save… writes
/// one out; files dropped here are clipped to the page in view (MarkupKit).
@MainActor
final class AttachmentsSidebarController: SidebarListController {
    private var embedded: [(file: PDFEmbeddedFile, data: @Sendable () -> Data?)] = []
    private var loading: Task<Void, Never>?

    override func loadView() {
        super.loadView()
        tableView.registerForDraggedTypes([.fileURL])
    }

    override func refresh() {
        showRows()
        loading?.cancel()
        let source = document.snapshot()
        loading = Task { [weak self] in
            let files = await Task.detached(priority: .utility) { () -> [PDFEmbeddedFile] in
                (try? PDFModel(source))?.embeddedFiles() ?? []
            }.value
            guard let self, !Task.isCancelled else { return }
            self.embedded = files.map { file in (file, { try? PDFModel(source).embeddedFileData(named: file.name) }) }
            self.showRows()
        }
    }

    private func showRows() {
        var rows = embedded.map { item in
            SidebarRow(symbol: "doc", title: item.file.fileName, detail: item.file.size.map { Formatting.bytes(Int64($0)) },
                       buttons: [(ViewerStrings.Sidebar.saveAttachment, { [weak self] in self?.save(item.file.fileName, item.data) })])
        }
        for index in 0..<document.pageCount {
            guard let page = document.pdf.page(at: index) else { continue }
            for annotation in page.annotations where annotation.type == "FileAttachment" {
                let name = annotation.contents.flatMap { $0.isEmpty ? nil : $0 } ?? ViewerStrings.Sidebar.attachment
                rows.append(SidebarRow(symbol: "paperclip", title: name, detail: ViewerStrings.Sidebar.page(page.label ?? "\(index + 1)"),
                                       onClick: { [weak self] in self?.owner.go(toPage: index) }))
            }
        }
        show(rows, empty: Strings.Empty.attachments)
    }

    private func save(_ name: String, _ data: @escaping @Sendable () -> Data?) {
        guard let window = view.window else { return }
        let panel = NSSavePanel()
        panel.nameFieldStringValue = name
        panel.beginSheetModal(for: window) { response in
            guard response == .OK, let url = panel.url else { return }
            Task.detached(priority: .userInitiated) { try? data()?.write(to: url) }
        }
    }

    func tableView(_ tableView: NSTableView, validateDrop info: NSDraggingInfo, proposedRow row: Int,
                   proposedDropOperation dropOperation: NSTableView.DropOperation) -> NSDragOperation {
        tableView.setDropRow(-1, dropOperation: .on)
        return Services.markup == nil ? [] : .copy
    }

    func tableView(_ tableView: NSTableView, acceptDrop info: NSDraggingInfo, row: Int, dropOperation: NSTableView.DropOperation) -> Bool {
        guard let markup = Services.markup,
              let urls = info.draggingPasteboard.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as? [URL] else { return false }
        let page = owner.currentPageIndex
        var groups: [UndoGroup] = []
        for (offset, url) in urls.enumerated() {
            if let group = try? markup.attachFile(url, to: page, at: CGPoint(x: 36, y: 36 + 24 * offset), in: document) { groups.append(group) }
        }
        guard !groups.isEmpty else { return false }
        Task {
            try? await Services.documents.apply(.inPlace(undoable: groups.count == 1 ? groups[0] : .combined(groups[0].actionName, groups), banner: nil),
                                                of: ToolRequest(tool: .attachFile, document: document, workFolder: SuperPDFPaths.work))
            refresh()
        }
        return true
    }
}

// MARK: - Signatures (ux §6.3): appears when the file has signatures

@MainActor
final class SignaturesSidebarController: SidebarListController {
    private var reports: [SignatureReport]?

    override func setUpHeader() {
        let verify = NSButton(title: ViewerStrings.Sidebar.verifyAll, target: self, action: #selector(verifyAll))
        verify.controlSize = .small
        header.addArrangedSubview(verify)
    }

    override func refresh() {
        guard let reports else { verifyAll(); return }
        show(reports.map { report in
            let valid = report.validity == .valid && !report.changedAfterSigning
            return SidebarRow(symbol: valid ? "checkmark.seal.fill" : "exclamationmark.triangle.fill",
                              symbolColor: valid ? .systemGreen : .systemOrange, title: report.signerName,
                              detail: report.changedAfterSigning ? ViewerStrings.Sidebar.changedAfterSigning
                                : report.signedAt.map { DateFormatter.localizedString(from: $0, dateStyle: .medium, timeStyle: .short) })
        }, empty: "")
    }

    @objc private func verifyAll() {
        guard let sign = Services.sign else { show([], empty: ""); return }
        let source = document.snapshot()
        Task {
            reports = (try? await sign.verify(source)) ?? []
            refresh()
        }
    }
}
