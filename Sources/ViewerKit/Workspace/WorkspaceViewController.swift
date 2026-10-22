import AppKit
import PDFKit
import SuperPDFCore
import UniformTypeIdentifiers

/// The workspace (ux §6.2, workspace.png): Combine and Rearrange in one full-window view on a soft blue canvas. Files
/// shows one card per file, Pages one per page; both rearrange by drag with the other cards springing aside, take files
/// of any kind dropped anywhere (each converts on its own card first), and preview big. The toolbar (DocumentToolbar)
/// switches Files | Pages, adds, rotates, deletes, selects all, sorts, switches grid | list and finishes. The status
/// line counts files, pages and the selection, and says what the gestures do. Nothing is written until Save.
@MainActor
final class WorkspaceViewController: NSViewController, WorkspaceGridDelegate, NSFilePromiseProviderDelegate {
    private unowned let owner: DocumentWindowController
    let grid = WorkspaceGridView()
    private let scrollView = NSScrollView()
    private let status = NSTextField(labelWithString: "")
    private let hint = NSTextField(labelWithString: ViewerStrings.Workspace.hint)
    private(set) var model: WorkspaceModel
    private(set) var mode: WorkspaceMode
    private(set) var layoutKind: WorkspaceLayout
    /// Space and the cards' zoom button: the system's Quick Look panel on the selected cards.
    private(set) lazy var quickLook = QuickLookController(source: self)

    static let layoutKey = Defaults.Key<String>("viewerKit.workspaceLayout", default: WorkspaceLayout.grid.rawValue)
    static let scaleKey = Defaults.Key<Double>("viewerKit.workspaceScale", default: 1)

    init(owner: DocumentWindowController) {
        self.owner = owner
        model = owner.pageActions.workspaceModel()
        // Several files start as files (Combine); one document starts as its pages (Rearrange).
        mode = model.files.count + model.pending.count > 1 ? .files : .pages
        layoutKind = WorkspaceLayout(rawValue: Defaults[Self.layoutKey]) ?? .grid
        super.init(nibName: nil, bundle: nil)
    }

    required init?(coder: NSCoder) { fatalError("not used") }

    override func loadView() {
        let root = CanvasView()
        grid.delegate = self
        grid.animates = owner.environment.moves
        grid.scale = CGFloat(Defaults[Self.scaleKey])
        grid.frame = NSRect(x: 0, y: 0, width: 800, height: 600)
        grid.autoresizingMask = [.width]
        scrollView.documentView = grid
        scrollView.drawsBackground = false
        scrollView.hasVerticalScroller = true
        scrollView.autohidesScrollers = true
        scrollView.contentView.postsBoundsChangedNotifications = true
        NotificationCenter.default.addObserver(self, selector: #selector(scrolled), name: NSView.boundsDidChangeNotification, object: scrollView.contentView)

        let bar = StatusBarView()
        for label in [status, hint] {
            label.font = SPFont.secondary.font()
            label.textColor = SPColor.secondaryLabel.color
            label.lineBreakMode = .byTruncatingTail
            label.translatesAutoresizingMaskIntoConstraints = false
            bar.addSubview(label)
        }
        hint.alignment = .right
        hint.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        for view in [scrollView, bar] {
            view.translatesAutoresizingMaskIntoConstraints = false
            root.addSubview(view)
        }
        NSLayoutConstraint.activate([
            scrollView.topAnchor.constraint(equalTo: root.topAnchor),
            scrollView.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            scrollView.trailingAnchor.constraint(equalTo: root.trailingAnchor),
            scrollView.bottomAnchor.constraint(equalTo: bar.topAnchor),
            bar.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            bar.trailingAnchor.constraint(equalTo: root.trailingAnchor),
            bar.bottomAnchor.constraint(equalTo: root.bottomAnchor),
            bar.heightAnchor.constraint(equalToConstant: SPMetrics.Workspace.statusBarHeight),
            status.leadingAnchor.constraint(equalTo: bar.leadingAnchor, constant: 20),
            status.centerYAnchor.constraint(equalTo: bar.centerYAnchor),
            hint.leadingAnchor.constraint(greaterThanOrEqualTo: status.trailingAnchor, constant: 16),
            hint.trailingAnchor.constraint(equalTo: bar.trailingAnchor, constant: -20),
            hint.centerYAnchor.constraint(equalTo: bar.centerYAnchor),
        ])
        view = root
        owner.pageActions.onPendingChange = { [weak self] in self?.reload(selecting: nil) }
    }

    override func viewDidLayout() {
        super.viewDidLayout()
        let width = scrollView.contentSize.width
        if grid.frame.width != width { grid.setFrameSize(NSSize(width: width, height: grid.frame.height)) }
    }

    override func viewDidAppear() {
        super.viewDidAppear()
        view.window?.makeFirstResponder(grid)
    }

    deinit { NotificationCenter.default.removeObserver(self) }

    @objc private func scrolled() { grid.updateVisibleCards() }

    // MARK: Reloading

    /// The pages changed (or a file is converting): cards slide to their places; `selection` (page indices) is what the
    /// edit wants selected afterwards.
    func reload(selecting selection: IndexSet?, animated: Bool = true) {
        _ = view
        let old = model
        model = owner.pageActions.workspaceModel()
        if let selection {
            grid.selection = ids(forPages: selection)
        }
        grid.show(model.items(mode), mode: mode, layout: layoutKind, animated: animated && old.entries.count > 0)
        if let frame = selection?.first.flatMap({ grid.frame(of: id(forPage: $0)) }) { grid.scrollToVisible(frame.insetBy(dx: 0, dy: -20)) }
        updateStatus()
        quickLook.reloadIfOpen()
        owner.toolbarController.workspaceChanged()
    }

    private func updateStatus() {
        status.stringValue = model.statusLine(mode, selectedCards: grid.selection.count)
        owner.updateTitle()
    }

    /// The card a page is on.
    private func id(forPage index: Int) -> WorkspaceItemID {
        switch mode {
        case .pages: .page(key: model.entries[index].key)
        case .files: .file(model.file(of: index))
        }
    }

    private func ids(forPages pages: IndexSet) -> Set<WorkspaceItemID> {
        Set(pages.filter { $0 < model.entries.count }.map(id(forPage:)))
    }

    // MARK: What the window asks

    /// The pages the menus' page commands act on: the selected cards' pages.
    var selectedPages: [Int] { model.pages(of: grid.selection, in: mode) }

    var pageCount: Int { model.entries.count }
    var fileCount: Int { model.files.count + model.pending.count }

    func setMode(_ mode: WorkspaceMode) {
        guard mode != self.mode else { return }
        let pages = IndexSet(selectedPages)
        self.mode = mode
        grid.selection = []
        grid.show(model.items(mode), mode: mode, layout: layoutKind, animated: false)
        grid.selection = ids(forPages: pages)
        updateStatus()
        owner.toolbarController.workspaceChanged()
    }

    func setLayout(_ layout: WorkspaceLayout) {
        guard layout != layoutKind else { return }
        layoutKind = layout
        if owner.environment.persistsWindowState { Defaults[Self.layoutKey] = layout.rawValue }
        grid.show(model.items(mode), mode: mode, layout: layout, animated: false)
        owner.toolbarController.workspaceChanged()
    }

    /// ⌘+ and ⌘− (View › Zoom In / Zoom Out) and pinching resize the cards.
    func zoom(by factor: CGFloat) {
        let range = SPMetrics.Workspace.scaleRange
        grid.scale = min(max(grid.scale * factor, range.lowerBound), range.upperBound)
        if owner.environment.persistsWindowState { Defaults[Self.scaleKey] = Double(grid.scale) }
    }

    func selectAll() { grid.select(Set(grid.contentIDs)) }

    func rotateSelection(_ turns: Int) {
        let pages = selectedPages
        guard !pages.isEmpty else { NSSound.beep(); return }
        owner.pageActions.rotate(pages, quarterTurns: turns)
    }

    func deleteSelection() {
        let pages = selectedPages
        guard !pages.isEmpty else { NSSound.beep(); return }
        owner.pageActions.delete(pages)
    }

    func sort(_ sort: WorkspaceSort) {
        guard let blocks = model.arrangement(sort, in: mode) else { return }
        owner.pageActions.arrange(blocks)
    }

    /// The add menu for a gap between cards (the "+"), or the end (the toolbar's Add and the add card).
    func showAddMenu(atPageGap gap: Int, from view: NSView) { owner.showAddPagesMenu(at: gap, from: view) }

    func addFiles(atPageGap gap: Int) { owner.addPagesFromFile(atGap: gap) }

    // MARK: Preview

    /// Quick Look on the card (the hover button, double-click or Space): a card that isn't selected becomes the selection.
    func showPreview(_ id: WorkspaceItemID) {
        if !grid.selection.contains(id) { grid.select([id]) }
        quickLook.toggle()
    }

    // MARK: WorkspaceGridDelegate

    func page(at index: Int) -> PDFPage? { owner.handle.pdf.page(at: index) }

    func perform(_ action: WorkspaceCardAction, on card: WorkspaceCardView) {
        let pages = card.item.pages
        guard !pages.isEmpty else { return }
        switch action {
        case .preview: showPreview(card.item.id)
        case .rotate: owner.pageActions.rotate(pages, quarterTurns: 1)
        case .duplicate: owner.pageActions.duplicate(pages, asNewFile: mode == .files)
        case .delete: owner.pageActions.delete(pages)
        }
    }

    func press(_ card: WorkspaceCardView) {
        if card.item.id == .add { gridAddFiles() } else if card.item.isContent { grid.toggleSelection(of: card.item.id) }
    }

    func gridSelectionChanged() {
        updateStatus()
        owner.toolbarController.workspaceChanged()
    }

    func gridPreview(_ id: WorkspaceItemID) { showPreview(id) }

    func gridInsert(atCardGap gap: Int, from view: NSView) {
        showAddMenu(atPageGap: model.pageGap(forCardGap: gap, in: mode), from: view)
    }

    func gridAddFiles() { addFiles(atPageGap: model.entries.count) }

    func gridDeleteSelection() { deleteSelection() }

    func gridEscape() {
        owner.hideWorkspace()
    }

    func gridValidateDrop(_ info: NSDraggingInfo, atCardGap gap: Int, excluding: Set<WorkspaceItemID>) -> (NSDragOperation, String?) {
        let decision = decide(info, gap: model.pageGap(forCardGap: gap, in: mode, excluding: excluding))
        switch decision.outcome {
        case .movePages: return (.move, nil)
        case .copyPages(_, _, _, let removing): return (removing ? .move : .copy, decision.label)
        case .insertFiles: return (.copy, decision.label)
        default: return ([], nil)
        }
    }

    func gridAcceptDrop(_ info: NSDraggingInfo, atCardGap gap: Int, excluding: Set<WorkspaceItemID>) -> Bool {
        let decision = decide(info, gap: model.pageGap(forCardGap: gap, in: mode, excluding: excluding))
        switch decision.outcome {
        case .movePages(let pages, let gap):
            owner.pageActions.move(pages, toGap: gap)
        case .copyPages(let source, let pages, let gap, let removing):
            guard let handle = Services.documents?.openDocuments.first(where: { $0.id == source }) else { return false }
            owner.pageActions.copyPages(pages, from: handle, toGap: gap, removingFromSource: removing)
        case .insertFiles(let urls, let gap):
            owner.pageActions.insertFiles(urls, atGap: gap, tagged: true)
        default:
            return false
        }
        return true
    }

    private var droppedFiles: (sequence: Int, files: [DroppedFile])?

    private func decide(_ info: NSDraggingInfo, gap: Int) -> DropDecision {
        let pasteboard = info.draggingPasteboard
        let payload: DropPayload?
        if let pages = PagesPromiseProvider.read(pasteboard) {
            payload = .pages(from: pages.document, indices: pages.pages)
        } else if let cached = droppedFiles, cached.sequence == info.draggingSequenceNumber {
            payload = .files(cached.files)
        } else if let urls = pasteboard.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as? [URL], !urls.isEmpty {
            let files = urls.map { DroppedFile(url: $0, canConvert: { Services.convert?.canConvertToPDF($0) ?? false }) }
            droppedFiles = (info.draggingSequenceNumber, files)
            payload = .files(files)
        } else {
            payload = nil
        }
        guard let payload else { return DropDecision(.none) }
        return DropDecision.decide(payload, onto: .workspaceGap(gap), of: owner.handle.id, isLocked: owner.handle.state.isLocked,
                                   optionKey: NSEvent.modifierFlags.contains(.option))
    }

    func gridPasteboardWriters(for ids: [WorkspaceItemID]) -> [NSPasteboardWriting] {
        let pages = model.pages(of: Set(ids), in: mode)
        guard !pages.isEmpty else { return [] }
        let plist = PagesPromiseProvider.plist(document: owner.handle.id, pages: pages)
        let provider = PagesPromiseProvider(fileType: UTType.pdf.identifier, delegate: self)
        provider.pagesPlist = plist
        provider.userInfo = pages
        // Every other card in the stack carries the same pages for drops inside the app.
        return [provider] + ids.dropFirst().map { _ in
            let item = NSPasteboardItem()
            item.setPropertyList(plist, forType: .superPDFPages)
            return item
        }
    }

    // MARK: NSFilePromiseProviderDelegate (cards dragged to Finder become "Report – pages 3-5.pdf", ux §3)

    nonisolated func filePromiseProvider(_ filePromiseProvider: NSFilePromiseProvider, fileNameForType fileType: String) -> String {
        MainActor.assumeIsolated { owner.pageActions.extractName(filePromiseProvider.userInfo as? [Int] ?? []) }
    }

    nonisolated func operationQueue(for filePromiseProvider: NSFilePromiseProvider) -> OperationQueue { .main }

    nonisolated func filePromiseProvider(_ filePromiseProvider: NSFilePromiseProvider, writePromiseTo url: URL,
                                         completionHandler: @escaping (Error?) -> Void) {
        MainActor.assumeIsolated {
            guard let data = owner.pageActions.extract(filePromiseProvider.userInfo as? [Int] ?? []) else {
                completionHandler(CocoaError(.fileWriteUnknown)); return
            }
            do { try data.write(to: url); completionHandler(nil) } catch { completionHandler(error) }
        }
    }
}

/// The workspace's soft blue canvas (ux §2.3 `canvas`).
final class CanvasView: NSView {
    override func draw(_ dirtyRect: NSRect) {
        SPColor.canvas.color.setFill()
        dirtyRect.fill()
    }
}

/// The status line under the cards: window background with a 1 pt separator above.
final class StatusBarView: NSView {
    override func draw(_ dirtyRect: NSRect) {
        SPColor.windowBackground.color.setFill()
        bounds.fill()
        SPColor.separator.color.setFill()
        NSRect(x: 0, y: bounds.height - 1, width: bounds.width, height: 1).fill()
    }
}

// MARK: - Quick Look

extension WorkspaceViewController: QuickLookSource {
    /// Several cards selected: just those. One (or none): every card, starting at the selected one, so the panel's strip
    /// and arrows walk the whole workspace and the selection follows. Each shows a temporary PDF of its pages as they are
    /// now (rotated, reordered, merged), made when the panel asks for it.
    func quickLookSelection() -> QuickLookSelection {
        let cards = model.items(mode).filter(\.isContent)
        let selected = cards.filter { grid.selection.contains($0.id) }
        let list = selected.count > 1 ? selected : cards
        let current = selected.count > 1 ? 0 : (list.firstIndex { selected.first?.id == $0.id } ?? 0)
        return QuickLookSelection(items: list.map(quickLookItem), current: current, showsSelectedOnly: selected.count > 1)
    }

    func quickLookSelect(_ item: QuickLookItem) {
        guard let id = item.key.base as? WorkspaceItemID else { return }
        grid.select([id])
        if let frame = grid.frame(of: id) { grid.scrollToVisible(frame.insetBy(dx: 0, dy: -20)) }
    }

    private func quickLookItem(for card: WorkspaceItem) -> QuickLookItem {
        let id = card.id
        let pages = card.pages
        let title: String
        switch card {
        case .file(let origin, _): title = origin.fileName
        case .page(let index, _, let origin): title = "\(origin.fileName) – \(ViewerStrings.Workspace.pageNumber(index + 1))"
        default: title = ""
        }
        return QuickLookItem(key: id, title: title, isTemporary: true,
                             makeURL: { [weak self] in
                                 guard let self, let data = try? Services.pages.extract(pages, from: self.owner.handle) else { return nil }
                                 return QuickLookFiles.write(data, named: QuickLookFiles.pdfName(title))
                             },
                             sourceFrame: { [weak self] in
                                 guard let self, let card = self.grid.card(for: id) else { return nil }
                                 return self.grid.screenFrame(of: card.frame)
                             },
                             transition: { [weak self] in
                                 guard let self, let card = self.grid.card(for: id) else { return nil }
                                 return self.grid.snapshot(of: card.frame)
                             })
    }
}
