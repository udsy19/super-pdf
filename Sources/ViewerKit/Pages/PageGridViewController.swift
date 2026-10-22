import AppKit
import PDFKit
import SuperPDFCore
import UniformTypeIdentifiers

/// The pages of a document as the sidebar's column of thumbnails (ux §2.1, §6.3). Drag to rearrange, drop files
/// between pages to insert them, drag pages from another window to copy them, drag pages to Finder to extract them;
/// right-click for the page menu; ⌫ deletes. Thumbnails render lazily off the main thread. (The workspace, ux §6.2,
/// is `WorkspaceGridView`.)
@MainActor
final class PageGridViewController: NSViewController, NSCollectionViewDataSource, NSCollectionViewDelegate,
    NSCollectionViewDelegateFlowLayout, NSFilePromiseProviderDelegate {
    private unowned let owner: DocumentWindowController
    let collectionView = PageCollectionView()
    let scrollView = NSScrollView()
    private let layout = PageFlowLayout()
    private let dropLabel = DropLabelView()
    private var dropLabelTimer: Timer?
    private let style = ThumbnailStyle.sidebar
    private(set) lazy var quickLook = QuickLookController(source: self)
    /// Turned page aspects (height / width), read once per reload.
    private var aspects: [CGFloat] = []
    private var droppedFiles: (sequence: Int, files: [DroppedFile])?
    /// Called when the selection changes by a click or a reload.
    var onSelectionChange: ((IndexSet) -> Void)?

    private var document: DocumentHandle { owner.handle }
    private var pageCount: Int { document.pageCount }

    init(owner: DocumentWindowController) {
        self.owner = owner
        super.init(nibName: nil, bundle: nil)
    }

    required init?(coder: NSCoder) { fatalError("not used") }

    override func loadView() {
        collectionView.collectionViewLayout = layout
        collectionView.dataSource = self
        collectionView.delegate = self
        collectionView.isSelectable = true
        collectionView.allowsMultipleSelection = true
        collectionView.allowsEmptySelection = false
        collectionView.backgroundColors = [.clear]
        collectionView.register(PageItem.self, forItemWithIdentifier: PageItem.identifier)
        collectionView.register(GapIndicatorView.self, forSupplementaryViewOfKind: NSCollectionView.elementKindInterItemGapIndicator,
                                withIdentifier: NSUserInterfaceItemIdentifier("Gap"))
        collectionView.registerForDraggedTypes([.superPDFPages, .fileURL, .string])
        collectionView.setDraggingSourceOperationMask([.copy, .move, .generic], forLocal: true)
        collectionView.setDraggingSourceOperationMask([.copy], forLocal: false)
        collectionView.onDelete = { [weak self] in self?.deleteSelection() }
        collectionView.quickLook = quickLook
        collectionView.onSpace = { [weak self] in self?.quickLook.toggle() }
        collectionView.onDragExit = { [weak self] in self?.hideDropLabel() }
        collectionView.menuForSelection = { [weak self] selection in self?.owner.pageMenu(for: Array(selection)) }
        collectionView.setAccessibilityLabel("Thumbnails")

        scrollView.documentView = collectionView
        scrollView.drawsBackground = false
        scrollView.hasVerticalScroller = true
        scrollView.autohidesScrollers = true
        scrollView.automaticallyAdjustsContentInsets = false

        dropLabel.isHidden = true
        collectionView.addSubview(dropLabel)
        view = scrollView
        reloadAspects()
    }

    override func viewDidLayout() {
        super.viewDidLayout()
        updateInsets()
    }

    // MARK: Reloading

    /// The pages changed (edit, undo, a new PDFKit document): reload, then select `selection` or keep the current one.
    func reload(selecting selection: IndexSet? = nil) {
        let keep = selection ?? self.selection
        reloadAspects()
        collectionView.pageCount = pageCount
        collectionView.reloadData()
        select(keep.filteredIndexSet { $0 < pageCount }, scroll: selection != nil)
        quickLook.reloadIfOpen()
    }

    /// Annotations changed (markup added, a note edited, a field filled, undo): the visible pages whose look changed get
    /// their picture again; the others keep theirs.
    func refreshMarkup() {
        for path in collectionView.indexPathsForVisibleItems() where path.item < pageCount {
            guard let item = collectionView.item(at: path) as? PageItem else { continue }
            configure(item, at: path.item)
        }
    }

    private func reloadAspects() {
        aspects = (0..<pageCount).map { index in
            guard let page = document.pdf.page(at: index) else { return 11 / 8.5 }
            let box = page.bounds(for: .cropBox)
            guard box.width > 0, box.height > 0 else { return 11 / 8.5 }
            return page.rotation % 180 == 0 ? box.height / box.width : box.width / box.height
        }
        collectionView.pageCount = pageCount
    }

    var selection: IndexSet { IndexSet(collectionView.selectionIndexPaths.map(\.item).filter { $0 < pageCount }) }

    func select(_ indices: IndexSet, scroll: Bool) {
        let paths = Set(indices.map { IndexPath(item: $0, section: 0) })
        if collectionView.selectionIndexPaths != paths { collectionView.selectionIndexPaths = paths }
        if scroll, let first = indices.first { scrollTo(first) }
    }

    func scrollTo(_ index: Int) {
        guard index < pageCount, let frame = layout.layoutAttributesForItem(at: IndexPath(item: index, section: 0))?.frame else { return }
        collectionView.scrollToVisible(frame.insetBy(dx: 0, dy: -8))
    }

    // MARK: Layout

    private var pageWidth: CGFloat {
        max(SPMetrics.Sidebar.minimumThumbnailWidth, scrollView.bounds.width - SPMetrics.Sidebar.thumbnailInset)
    }

    /// The page sits 16 pt in from each side and 14 pt from the top; thumbnails are 12 pt apart (main-window.png).
    private func updateInsets() {
        let margin = style.ringMargin
        let side = SPMetrics.Sidebar.thumbnailInset / 2 - margin
        layout.sectionInset = NSEdgeInsets(top: 14 - margin, left: side, bottom: 14, right: side)
        layout.minimumLineSpacing = SPMetrics.Sidebar.thumbnailGap - margin
        layout.minimumInteritemSpacing = 0
    }

    func collectionView(_ collectionView: NSCollectionView, layout collectionViewLayout: NSCollectionViewLayout,
                        sizeForItemAt indexPath: IndexPath) -> NSSize {
        let aspect = indexPath.item < aspects.count ? aspects[indexPath.item] : 11 / 8.5
        return style.cellSize(pageWidth: pageWidth, aspect: aspect)
    }

    // MARK: Data source

    func numberOfSections(in collectionView: NSCollectionView) -> Int { 1 }

    func collectionView(_ collectionView: NSCollectionView, numberOfItemsInSection section: Int) -> Int { pageCount }

    func collectionView(_ collectionView: NSCollectionView, itemForRepresentedObjectAt indexPath: IndexPath) -> NSCollectionViewItem {
        let item = collectionView.makeItem(withIdentifier: PageItem.identifier, for: indexPath) as! PageItem
        item.thumbnail.style = style
        configure(item, at: indexPath.item)
        return item
    }

    private func configure(_ item: PageItem, at index: Int) {
        guard let page = document.pdf.page(at: index) else { return }
        item.thumbnail.aspect = index < aspects.count ? aspects[index] : 11 / 8.5
        item.thumbnail.label = page.label ?? "\(index + 1)"
        item.thumbnail.setAccessibilityLabel(ViewerStrings.Sidebar.page(item.thumbnail.label))
        let pixels = Int((pageWidth * (view.window?.backingScaleFactor ?? 2)).rounded())
        let markup = ThumbnailRenderer.markupSignature(of: page)
        if item.page === page, item.markup == markup, item.thumbnail.image != nil, item.thumbnail.image?.width == pixels { return }
        item.request?.cancel()
        item.page = page
        item.markup = markup
        let renderer = ThumbnailRenderer.shared
        item.thumbnail.image = renderer.cachedImage(for: page, pixelWidth: pixels)
        guard item.thumbnail.image == nil else { item.request = nil; return }
        item.request = renderer.image(for: page, pixelWidth: pixels) { [weak item, weak page] image in
            guard let item, let page, item.page === page else { return }
            item.thumbnail.image = image
        }
    }

    func collectionView(_ collectionView: NSCollectionView, didEndDisplaying item: NSCollectionViewItem,
                        forRepresentedObjectAt indexPath: IndexPath) {
        (item as? PageItem)?.request?.cancel()
    }

    func collectionView(_ collectionView: NSCollectionView, viewForSupplementaryElementOfKind kind: NSCollectionView.SupplementaryElementKind,
                        at indexPath: IndexPath) -> NSView {
        collectionView.makeSupplementaryView(ofKind: kind, withIdentifier: NSUserInterfaceItemIdentifier("Gap"), for: indexPath)
    }

    // MARK: Selection

    func collectionView(_ collectionView: NSCollectionView, shouldSelectItemsAt indexPaths: Set<IndexPath>) -> Set<IndexPath> {
        indexPaths.filter { $0.item < pageCount }
    }

    func collectionView(_ collectionView: NSCollectionView, didSelectItemsAt indexPaths: Set<IndexPath>) {
        onSelectionChange?(selection)
    }

    func collectionView(_ collectionView: NSCollectionView, didDeselectItemsAt indexPaths: Set<IndexPath>) {
        onSelectionChange?(selection)
    }

    func deleteSelection() {
        let pages = Array(selection)
        guard !pages.isEmpty else { return }
        owner.pageActions.delete(pages)
    }

    // MARK: Dragging out

    func collectionView(_ collectionView: NSCollectionView, canDragItemsAt indexPaths: Set<IndexPath>, with event: NSEvent) -> Bool {
        indexPaths.allSatisfy { $0.item < pageCount }
    }

    func collectionView(_ collectionView: NSCollectionView, pasteboardWriterForItemAt indexPath: IndexPath) -> NSPasteboardWriting? {
        guard indexPath.item < pageCount else { return nil }
        let selected = selection
        let pages = selected.contains(indexPath.item) ? Array(selected) : [indexPath.item]
        let plist = PagesPromiseProvider.plist(document: document.id, pages: pages)
        guard indexPath.item == pages.first else {
            let item = NSPasteboardItem()
            item.setPropertyList(plist, forType: .superPDFPages)
            return item
        }
        let provider = PagesPromiseProvider(fileType: UTType.pdf.identifier, delegate: self)
        provider.pagesPlist = plist
        provider.userInfo = pages
        return provider
    }

    func collectionView(_ collectionView: NSCollectionView, draggingSession session: NSDraggingSession, willBeginAt screenPoint: NSPoint,
                        forItemsAt indexPaths: Set<IndexPath>) {
        session.draggingFormation = .stack
    }

    func collectionView(_ collectionView: NSCollectionView, draggingSession session: NSDraggingSession, endedAt screenPoint: NSPoint,
                        dragOperation operation: NSDragOperation) {
        hideDropLabel()
    }

    nonisolated func filePromiseProvider(_ filePromiseProvider: NSFilePromiseProvider, fileNameForType fileType: String) -> String {
        MainActor.assumeIsolated {
            owner.pageActions.extractName(filePromiseProvider.userInfo as? [Int] ?? [])
        }
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

    // MARK: Dropping in

    func collectionView(_ collectionView: NSCollectionView, validateDrop draggingInfo: NSDraggingInfo,
                        proposedIndexPath proposedDropIndexPath: AutoreleasingUnsafeMutablePointer<NSIndexPath>,
                        dropOperation proposedDropOperation: UnsafeMutablePointer<NSCollectionView.DropOperation>) -> NSDragOperation {
        let gap = min(max(proposedDropIndexPath.pointee.item, 0), pageCount)
        proposedDropIndexPath.pointee = NSIndexPath(forItem: gap, inSection: 0)
        proposedDropOperation.pointee = .before
        let decision = decide(draggingInfo, gap: gap)
        showDropLabel(decision, gap: gap)
        switch decision.outcome {
        case .movePages: return .move
        case .copyPages(_, _, _, let removing): return removing ? .move : .copy
        case .insertFiles: return .copy
        default: return []
        }
    }

    func collectionView(_ collectionView: NSCollectionView, acceptDrop draggingInfo: NSDraggingInfo, indexPath: IndexPath,
                        dropOperation: NSCollectionView.DropOperation) -> Bool {
        let gap = min(max(indexPath.item, 0), pageCount)
        let decision = decide(draggingInfo, gap: gap)
        hideDropLabel()
        droppedFiles = nil
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

    private func decide(_ info: NSDraggingInfo, gap: Int) -> DropDecision {
        guard let payload = payload(of: info) else { return DropDecision(.none) }
        return DropDecision.decide(payload, onto: .sidebarGap(gap), of: document.id, isLocked: document.state.isLocked,
                                   optionKey: NSEvent.modifierFlags.contains(.option))
    }

    /// What is being dragged, read once per drag for files.
    private func payload(of info: NSDraggingInfo) -> DropPayload? {
        let pasteboard = info.draggingPasteboard
        if let pages = PagesPromiseProvider.read(pasteboard) { return .pages(from: pages.document, indices: pages.pages) }
        if let cached = droppedFiles, cached.sequence == info.draggingSequenceNumber { return .files(cached.files) }
        if let urls = pasteboard.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as? [URL], !urls.isEmpty {
            let files = urls.map { DroppedFile(url: $0, canConvert: { Services.convert?.canConvertToPDF($0) ?? false }) }
            droppedFiles = (info.draggingSequenceNumber, files)
            return .files(files)
        }
        return pasteboard.string(forType: .string).map { .text($0) }
    }

    /// The words appear 300 ms after the pointer settles on a gap (ux §2.5).
    private func showDropLabel(_ decision: DropDecision, gap: Int) {
        let text: String? = switch decision.outcome {
        case .refuse(let reason): reason
        default: decision.label
        }
        guard let text else { hideDropLabel(); return }
        let refusal = !decision.isAllowed
        if !dropLabel.isHidden, dropLabel.text == text { positionDropLabel(gap: gap); return }
        dropLabelTimer?.invalidate()
        dropLabelTimer = Timer.scheduledTimer(withTimeInterval: SPMotion.dropLabelDelay, repeats: false) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                self.dropLabel.text = text
                self.dropLabel.isRefusal = refusal
                self.positionDropLabel(gap: gap)
                self.dropLabel.isHidden = false
            }
        }
    }

    private func positionDropLabel(gap: Int) {
        guard let frame = layout.layoutAttributesForInterItemGap(before: IndexPath(item: gap, section: 0))?.frame else { return }
        let size = dropLabel.intrinsicContentSize
        let width = min(size.width, collectionView.bounds.width - 16)
        var origin = NSPoint(x: (collectionView.bounds.width - width) / 2, y: frame.midY - size.height / 2)
        origin.x = min(max(8, origin.x), collectionView.bounds.width - width - 8)
        dropLabel.frame = NSRect(origin: origin, size: NSSize(width: width, height: size.height))
    }

    private func hideDropLabel() {
        dropLabelTimer?.invalidate()
        dropLabelTimer = nil
        dropLabel.isHidden = true
    }
}

// MARK: - Quick Look

extension PageGridViewController: QuickLookSource {
    /// Several pages selected: just those. One: every page, starting at it, so ↑ ↓ walk the document and the selection
    /// follows. Each is a temporary PDF of the page as it is now.
    func quickLookSelection() -> QuickLookSelection {
        let chosen = selection
        let pages = chosen.count > 1 ? Array(chosen) : Array(0..<pageCount)
        let name = QuickLookFiles.pdfName(document.displayName)
        return QuickLookSelection(items: pages.map { quickLookItem(page: $0, name: name) },
                                  current: chosen.count > 1 ? 0 : (pages.firstIndex(of: chosen.first ?? 0) ?? 0),
                                  showsSelectedOnly: chosen.count > 1)
    }

    func quickLookSelect(_ item: QuickLookItem) {
        guard let page = item.key.base as? Int else { return }
        select(IndexSet(integer: page), scroll: true)
        onSelectionChange?(IndexSet(integer: page))
    }

    private func quickLookItem(page: Int, name: String) -> QuickLookItem {
        let path = IndexPath(item: page, section: 0)
        return QuickLookItem(key: page, title: "\(document.displayName) – \(ViewerStrings.Workspace.pageNumber(page + 1))", isTemporary: true,
                             makeURL: { [weak self] in
                                 guard let self, let data = try? Services.pages.extract([page], from: self.document) else { return nil }
                                 return QuickLookFiles.write(data, named: name)
                             },
                             sourceFrame: { [weak self] in
                                 guard let self, let frame = self.layout.layoutAttributesForItem(at: path)?.frame else { return nil }
                                 return self.collectionView.screenFrame(of: frame)
                             },
                             transition: { [weak self] in
                                 guard let self, let frame = self.layout.layoutAttributesForItem(at: path)?.frame else { return nil }
                                 return self.collectionView.snapshot(of: frame)
                             })
    }
}
