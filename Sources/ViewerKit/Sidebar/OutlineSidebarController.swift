import AppKit
import PDFKit
import SuperPDFCore

/// Table of Contents (ux §6.3, features #6): the document outline as a tree, 24 pt rows at 13 pt (Preview's). Click
/// jumps; drag to reorder or nest; double-click renames; ⌫ deletes; + adds an entry for the page in view. Empty: "No
/// table of contents yet." with Find headings. Every change is one undo step.
@MainActor
final class OutlineSidebarController: NSViewController, NSOutlineViewDataSource, NSOutlineViewDelegate, NSTextFieldDelegate, SidebarRefreshing {
    private unowned let owner: DocumentWindowController
    private let outlineView = OutlineView()
    private let scrollView = NSScrollView()
    private let empty = NSStackView()
    private static let dragType = NSPasteboard.PasteboardType("com.udsy.superpdf.outline-entry")
    private var dragged: PDFOutline?

    private var document: DocumentHandle { owner.handle }
    private var root: PDFOutline? { document.pdf.outlineRoot }

    init(owner: DocumentWindowController) {
        self.owner = owner
        super.init(nibName: nil, bundle: nil)
    }

    required init?(coder: NSCoder) { fatalError("not used") }

    override func loadView() {
        let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("title"))
        outlineView.addTableColumn(column)
        outlineView.outlineTableColumn = column
        outlineView.headerView = nil
        outlineView.rowHeight = SPMetrics.Sidebar.outlineRowHeight
        outlineView.style = .sourceList
        outlineView.backgroundColor = .clear
        outlineView.dataSource = self
        outlineView.delegate = self
        outlineView.target = self
        outlineView.action = #selector(clicked(_:))
        outlineView.doubleAction = #selector(rename(_:))
        outlineView.registerForDraggedTypes([Self.dragType])
        outlineView.onDelete = { [weak self] in self?.deleteSelected() }
        outlineView.setAccessibilityLabel("Table of Contents")
        scrollView.documentView = outlineView
        scrollView.drawsBackground = false
        scrollView.hasVerticalScroller = true
        scrollView.autohidesScrollers = true

        let title = NSTextField(labelWithString: Strings.Empty.tableOfContents)
        title.font = SPFont.body.font()
        title.textColor = SPColor.secondaryLabel.color
        let hint = NSTextField(wrappingLabelWithString: ViewerStrings.Sidebar.tableOfContentsEmptyHint)
        hint.font = SPFont.secondary.font()
        hint.textColor = SPColor.secondaryLabel.color
        hint.alignment = .center
        let find = NSButton(title: ViewerStrings.Contents.findHeadings, target: self, action: #selector(findHeadings(_:)))
        find.controlSize = .small
        empty.orientation = .vertical
        empty.alignment = .centerX
        empty.spacing = 8
        [title, hint, find].forEach(empty.addArrangedSubview)

        let root = NSView()
        for view in [scrollView, empty] as [NSView] {
            view.translatesAutoresizingMaskIntoConstraints = false
            root.addSubview(view)
        }
        NSLayoutConstraint.activate([
            scrollView.topAnchor.constraint(equalTo: root.topAnchor), scrollView.bottomAnchor.constraint(equalTo: root.bottomAnchor),
            scrollView.leadingAnchor.constraint(equalTo: root.leadingAnchor), scrollView.trailingAnchor.constraint(equalTo: root.trailingAnchor),
            empty.centerYAnchor.constraint(equalTo: root.centerYAnchor), empty.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 16),
            empty.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -16),
        ])
        view = root
        refresh()
    }

    func refresh() {
        guard isViewLoaded else { return }
        outlineView.reloadData()
        outlineView.expandItem(nil, expandChildren: true)
        let isEmpty = (root?.numberOfChildren ?? 0) == 0
        empty.isHidden = !isEmpty
        scrollView.isHidden = isEmpty
    }

    // MARK: Data source

    func outlineView(_ outlineView: NSOutlineView, numberOfChildrenOfItem item: Any?) -> Int {
        ((item as? PDFOutline) ?? root)?.numberOfChildren ?? 0
    }

    func outlineView(_ outlineView: NSOutlineView, child index: Int, ofItem item: Any?) -> Any {
        ((item as? PDFOutline) ?? root)!.child(at: index)!
    }

    func outlineView(_ outlineView: NSOutlineView, isItemExpandable item: Any) -> Bool { ((item as? PDFOutline)?.numberOfChildren ?? 0) > 0 }

    func outlineView(_ outlineView: NSOutlineView, viewFor tableColumn: NSTableColumn?, item: Any) -> NSView? {
        let entry = item as? PDFOutline
        let cell = NSTableCellView()
        let field = NSTextField(labelWithString: entry?.label ?? "")
        field.font = SPFont.body.font()
        field.lineBreakMode = .byTruncatingTail
        field.delegate = self
        field.translatesAutoresizingMaskIntoConstraints = false
        cell.addSubview(field)
        cell.textField = field
        NSLayoutConstraint.activate([field.leadingAnchor.constraint(equalTo: cell.leadingAnchor, constant: 2),
                                     field.trailingAnchor.constraint(equalTo: cell.trailingAnchor, constant: -2),
                                     field.centerYAnchor.constraint(equalTo: cell.centerYAnchor)])
        return cell
    }

    // MARK: Actions

    @objc private func clicked(_ sender: Any?) {
        guard let entry = outlineView.item(atRow: outlineView.clickedRow) as? PDFOutline else { return }
        if let destination = entry.destination { owner.pdfView.go(to: destination) } else if let action = entry.action { owner.pdfView.perform(action) }
    }

    @objc private func rename(_ sender: Any?) {
        let row = outlineView.clickedRow
        guard row >= 0, let cell = outlineView.view(atColumn: 0, row: row, makeIfNecessary: false) as? NSTableCellView,
              let field = cell.textField else { return }
        field.isEditable = true
        view.window?.makeFirstResponder(field)
    }

    func controlTextDidEndEditing(_ notification: Notification) {
        guard let field = notification.object as? NSTextField else { return }
        field.isEditable = false
        let row = outlineView.row(for: field)
        guard let entry = outlineView.item(atRow: row) as? PDFOutline, entry.label != field.stringValue else { return }
        let before = entry.label, after = field.stringValue
        entry.label = after
        commit(UndoGroup(ViewerStrings.Sidebar.rename, undo: { [weak self] in entry.label = before; self?.refresh() },
                         redo: { [weak self] in entry.label = after; self?.refresh() }))
    }

    /// + : an entry for the page in view, after the selected entry (or at the end).
    func addEntryForCurrentPage() {
        guard let page = owner.pdfView.currentPage else { return }
        let entry = PDFOutline()
        entry.label = ViewerStrings.Sidebar.page(page.label ?? "\(document.pdf.index(for: page) + 1)")
        entry.destination = PDFDestination(page: page, at: CGPoint(x: 0, y: page.bounds(for: .cropBox).maxY))
        let root = ensureRoot()
        let parent = (outlineView.item(atRow: outlineView.selectedRow) as? PDFOutline)?.parent ?? root
        let index = (outlineView.item(atRow: outlineView.selectedRow) as? PDFOutline).map { $0.index + 1 } ?? parent.numberOfChildren
        parent.insertChild(entry, at: index)
        commit(UndoGroup(ViewerStrings.Sidebar.newEntry, undo: { [weak self] in entry.removeFromParent(); self?.refresh() },
                         redo: { [weak self] in parent.insertChild(entry, at: min(index, parent.numberOfChildren)); self?.refresh() }))
    }

    private func deleteSelected() {
        guard let entry = outlineView.item(atRow: outlineView.selectedRow) as? PDFOutline, let parent = entry.parent else { return }
        let index = entry.index
        entry.removeFromParent()
        commit(UndoGroup(ViewerStrings.Sidebar.delete, undo: { [weak self] in parent.insertChild(entry, at: min(index, parent.numberOfChildren)); self?.refresh() },
                         redo: { [weak self] in entry.removeFromParent(); self?.refresh() }))
    }

    @objc private func findHeadings(_ sender: Any?) {
        Task {
            let headings = await OutlineBuilder.headings(in: document)
            if let group = OutlineBuilder.insert(headings, into: document) { commit(group) } else {
                owner.environment.alert(ViewerStrings.Contents.noHeadings, view.window)
            }
        }
    }

    private func ensureRoot() -> PDFOutline {
        if let root { return root }
        let made = PDFOutline()
        document.pdf.outlineRoot = made
        return made
    }

    private func commit(_ group: UndoGroup) {
        refresh()
        Task { try? await Services.documents.apply(.inPlace(undoable: group, banner: nil),
                                                   of: ToolRequest(tool: .contents, document: document, workFolder: SuperPDFPaths.work)) }
    }

    // MARK: Drag to reorder and nest

    func outlineView(_ outlineView: NSOutlineView, pasteboardWriterForItem item: Any) -> NSPasteboardWriting? {
        dragged = item as? PDFOutline
        let writer = NSPasteboardItem()
        writer.setString("entry", forType: Self.dragType)
        return writer
    }

    func outlineView(_ outlineView: NSOutlineView, validateDrop info: NSDraggingInfo, proposedItem item: Any?, proposedChildIndex index: Int) -> NSDragOperation {
        guard let dragged else { return [] }
        var ancestor = item as? PDFOutline
        while let current = ancestor { if current === dragged { return [] }; ancestor = current.parent }
        return .move
    }

    func outlineView(_ outlineView: NSOutlineView, acceptDrop info: NSDraggingInfo, item: Any?, childIndex index: Int) -> Bool {
        guard let dragged, let oldParent = dragged.parent else { return false }
        let newParent = (item as? PDFOutline) ?? ensureRoot()
        let oldIndex = dragged.index
        var newIndex = index < 0 ? newParent.numberOfChildren : index
        if newParent === oldParent && oldIndex < newIndex { newIndex -= 1 }
        dragged.removeFromParent()
        newParent.insertChild(dragged, at: min(newIndex, newParent.numberOfChildren))
        commit(UndoGroup(ViewerStrings.Sidebar.moveEntry, undo: { [weak self] in
            dragged.removeFromParent(); oldParent.insertChild(dragged, at: min(oldIndex, oldParent.numberOfChildren)); self?.refresh()
        }, redo: { [weak self] in
            dragged.removeFromParent(); newParent.insertChild(dragged, at: min(newIndex, newParent.numberOfChildren)); self?.refresh()
        }))
        self.dragged = nil
        return true
    }
}

final class OutlineView: NSOutlineView {
    var onDelete: (() -> Void)?

    override func keyDown(with event: NSEvent) {
        if let key = event.charactersIgnoringModifiers?.unicodeScalars.first?.value,
           key == UInt32(NSDeleteCharacter) || key == UInt32(NSDeleteFunctionKey) {
            onDelete?()
            return
        }
        super.keyDown(with: event)
    }
}

/// "Find headings" (ux §6.3) and the Contents tool: LayoutKit's headings become outline entries, level 1 at the top
/// and deeper levels nested under the heading before them.
@MainActor
enum OutlineBuilder {
    struct Heading: Equatable {
        var title: String
        var level: Int
        var page: Int
        /// Top of the heading in page space.
        var top: CGFloat
    }

    /// The document's headings, from LayoutKit (empty when it isn't installed or finds none).
    static func headings(in document: DocumentHandle) async -> [Heading] {
        guard let layout = Services.layout,
              let analysed = try? await layout.analyze(document.snapshot(), pages: nil, options: LayoutOptions()) else { return [] }
        return analysed.pages.flatMap { page in
            page.blocks.compactMap { block -> Heading? in
                guard case .heading(let level) = block.kind else { return nil }
                let title = block.text.replacingOccurrences(of: "\n", with: " ").trimmingCharacters(in: .whitespaces)
                return title.isEmpty ? nil : Heading(title: title, level: level, page: page.index, top: block.bounds.maxY)
            }
        }
    }

    /// Adds the headings to the end of the outline and returns the undo step (already applied); nil when there are none.
    static func insert(_ headings: [Heading], into document: DocumentHandle) -> UndoGroup? {
        guard !headings.isEmpty else { return nil }
        let root = document.pdf.outlineRoot ?? PDFOutline()
        let hadRoot = document.pdf.outlineRoot != nil
        let entries = tree(headings).map { node in node.outline(in: document.pdf) }
        let start = root.numberOfChildren
        let insert = {
            for (offset, entry) in entries.enumerated() { root.insertChild(entry, at: min(start + offset, root.numberOfChildren)) }
            if !hadRoot { document.pdf.outlineRoot = root }
        }
        let remove = {
            entries.forEach { $0.removeFromParent() }
            if !hadRoot { document.pdf.outlineRoot = nil }
        }
        let refresh = { Viewer.shared.controller(for: document)?.sidebar.pagesChanged() }
        insert()
        refresh()
        return UndoGroup(ViewerStrings.Contents.findHeadings, undo: { remove(); refresh() }, redo: { insert(); refresh() })
    }

    final class Node {
        let heading: Heading
        var children: [Node] = []
        init(_ heading: Heading) { self.heading = heading }

        func outline(in pdf: PDFDocument) -> PDFOutline {
            let entry = PDFOutline()
            entry.label = heading.title
            if let page = pdf.page(at: heading.page) { entry.destination = PDFDestination(page: page, at: CGPoint(x: 0, y: heading.top)) }
            for (index, child) in children.enumerated() { entry.insertChild(child.outline(in: pdf), at: index) }
            entry.isOpen = true
            return entry
        }
    }

    /// Nests each heading under the closest earlier heading of a smaller level.
    static func tree(_ headings: [Heading]) -> [Node] {
        var top: [Node] = []
        var stack: [Node] = []
        for heading in headings {
            let node = Node(heading)
            while let last = stack.last, last.heading.level >= heading.level { stack.removeLast() }
            if let parent = stack.last { parent.children.append(node) } else { top.append(node) }
            stack.append(node)
        }
        return top
    }
}
