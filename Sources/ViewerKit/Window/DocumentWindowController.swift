import AppKit
import Combine
import PDFKit
import SuperPDFCore

/// One PDF's window (ux §2): the unified 52 pt toolbar, the sidebar, the document well with its PDFView, the 320 pt
/// tool panel slot, the result banner under the toolbar, and the full-window page organiser. NSDocument owns it;
/// `Viewer` finds it by document.
@MainActor
public final class DocumentWindowController: NSWindowController, NSWindowDelegate {
    public let handle: DocumentHandle
    unowned let viewer: Viewer
    var environment: ViewerEnvironment { viewer.environment }

    let root = RootViewController()
    let split = NSSplitViewController()
    lazy var sidebar = SidebarViewController(owner: self)
    let documentArea = DocumentAreaViewController()
    let panelSlot = PanelSlotViewController()
    private(set) var sidebarItem: NSSplitViewItem!
    private(set) var panelItem: NSSplitViewItem!
    private(set) var organiser: OrganiserViewController?
    lazy var pageActions = PageActions(document: handle, window: window, environment: { [unowned viewer] in viewer.environment })
    let toolbarController: DocumentToolbar
    lazy var readAloud = ReadAloudController(owner: self)

    /// The sidebar mode before a search took the sidebar over.
    var modeBeforeSearch: SidebarMode = .thumbnails
    var markupBarVisible = false
    /// Zoom to Fit (⌘9, Preview's): the whole page in view, kept as the window resizes, until the person zooms.
    var fitsPage = true { didSet { fitPage() } }
    var darkPDF = false
    var reader: ReaderState?
    private var cancellables: Set<AnyCancellable> = []

    public var pdfView: PDFView { documentArea.pdfView }

    init(document: DocumentHandle, viewer: Viewer, adopting adopted: NSWindow?) {
        self.handle = document
        self.viewer = viewer
        let window = adopted ?? Self.makeWindow()
        toolbarController = DocumentToolbar()
        super.init(window: window)
        toolbarController.owner = self
        documentArea.owner = self
        configureWindow(window, adopted: adopted != nil)
        configureContent()
        // As content size: AppKit converts a frame minimum with the title bar's height, not the toolbar's.
        window.contentMinSize = NSSize(width: SPMetrics.Window.minimumSize.width,
                                       height: SPMetrics.Window.minimumSize.height - SPMetrics.Window.toolbarHeight)
        restoreViewState()
        observe()
    }

    required init?(coder: NSCoder) { fatalError("not used") }

    /// The default window: 1100 × 760, at least 640 × 440, unified title and toolbar (ux §2.1).
    static func makeWindow() -> NSWindow {
        let window = NSWindow(contentRect: NSRect(origin: .zero, size: SPMetrics.Window.defaultSize),
                              styleMask: [.titled, .closable, .miniaturizable, .resizable], backing: .buffered, defer: true)
        window.setFrame(NSRect(origin: .zero, size: SPMetrics.Window.defaultSize), display: false)
        window.center()
        return window
    }

    private func configureWindow(_ window: NSWindow, adopted: Bool) {
        window.delegate = self
        window.titleVisibility = .hidden
        window.toolbarStyle = .unified
        window.title = handle.displayName
        window.representedURL = handle.url
        window.tabbingIdentifier = "SuperPDFDocument"
        window.isRestorable = environment.persistsWindowState
        window.toolbar = toolbarController.makeToolbar(persists: environment.persistsWindowState)
        if !adopted {
            // Adding the toolbar grew the frame; the window is 1100 × 760 with it.
            window.setFrame(NSRect(origin: window.frame.origin, size: SPMetrics.Window.defaultSize), display: false)
            window.center()
            if environment.persistsWindowState { windowFrameAutosaveName = "SuperPDFDocumentWindow" }
        }
        pageActions.attach(window)
    }

    private func configureContent() {
        // A flush sidebar under a full-width toolbar, as Preview and main-window.png; the sidebar draws the system's
        // sidebar material itself.
        let sidebarItem = NSSplitViewItem(viewController: sidebar)
        sidebarItem.minimumThickness = SPMetrics.Sidebar.minimumWidth
        sidebarItem.maximumThickness = SPMetrics.Sidebar.maximumWidth
        sidebarItem.canCollapse = true
        sidebarItem.holdingPriority = .defaultLow + 10
        let documentItem = NSSplitViewItem(viewController: documentArea)
        documentItem.minimumThickness = SPMetrics.ToolPanel.minimumDocumentWidth
        let panelItem = NSSplitViewItem(viewController: panelSlot)
        panelItem.minimumThickness = SPMetrics.ToolPanel.width
        panelItem.maximumThickness = SPMetrics.ToolPanel.width
        panelItem.canCollapse = true
        panelItem.isCollapsed = true
        panelItem.holdingPriority = .defaultHigh
        split.splitViewItems = [sidebarItem, documentItem, panelItem]
        split.splitView.dividerStyle = .thin
        self.sidebarItem = sidebarItem
        self.panelItem = panelItem
        root.setContent(split)
        let frame = window?.frame ?? .zero
        window?.contentViewController = root
        window?.setFrame(frame, display: false)
        sidebar.thumbnails.onSelectionChange = { [weak self] selection in self?.thumbnailSelectionChanged(selection) }
        documentArea.pdfView.document = handle.pdf
        updateTitle()
    }

    private func observe() {
        NotificationCenter.default.publisher(for: .PDFViewPageChanged, object: pdfView)
            .sink { [weak self] _ in MainActor.assumeIsolated { self?.pageInViewChanged() } }
            .store(in: &cancellables)
        Defaults.publisher(.toolbarTools)
            .sink { [weak self] tools in MainActor.assumeIsolated { self?.toolbarController.addFavourites(tools) } }
            .store(in: &cancellables)
    }

    // MARK: Pages and selection

    /// Selected thumbnails (0-based), the organiser's while it shows.
    public var selectedPages: [Int] { Array(organiser?.grid.selection ?? sidebar.thumbnails.selection) }

    /// The page in view (0-based).
    public var currentPageIndex: Int { pdfView.currentPage.map { handle.pdf.index(for: $0) } ?? 0 }

    /// The pages a page command works on: the selection, else the page in view (Preview's ⌘R).
    var targetPages: [Int] { selectedPages.isEmpty ? [currentPageIndex] : selectedPages }

    func go(toPage index: Int) {
        guard let page = handle.pdf.page(at: index) else { return }
        pdfView.go(to: page)
    }

    private var followingSelection = false

    private func thumbnailSelectionChanged(_ selection: IndexSet) {
        guard selection.count == 1, let index = selection.first, index != currentPageIndex else { return }
        followingSelection = true
        go(toPage: index)
        followingSelection = false
    }

    /// Scrolling the document moves a single selection along, as Preview's sidebar does.
    private func pageInViewChanged() {
        guard !followingSelection, organiser == nil else { return }
        let thumbnails = sidebar.thumbnails
        let selection = thumbnails.selection
        let index = currentPageIndex
        guard selection.count <= 1, selection.first != index else { return }
        thumbnails.select([index], scroll: true)
    }

    /// DocumentKit says pages, annotations or bytes changed.
    func documentChanged() {
        if pdfView.document !== handle.pdf { pdfView.document = handle.pdf }
        pageActions.pruneOrigins()
        let selection = pageActions.pendingSelection
        pageActions.pendingSelection = nil
        sidebar.thumbnails.reload(selecting: selection)
        organiser?.reload(selecting: selection)
        sidebar.pagesChanged()
        toolbarController.documentStateChanged()
        updateTitle()
    }

    /// Saved: pages mixed in from other files lose their colour bars (ux §6.2 "until saved").
    func documentSaved() {
        pageActions.clearOrigins()
        organiser?.reload(selecting: nil)
        updateTitle()
    }

    // MARK: Title

    func updateTitle() {
        window?.title = handle.displayName
        window?.representedURL = handle.url
        toolbarController.titleView.update(name: handle.url?.lastPathComponent ?? handle.displayName, edited: handle.state.isEdited,
                                           url: handle.url)
    }

    override public func synchronizeWindowTitleWithDocumentName() {
        super.synchronizeWindowTitleWithDocumentName()
        updateTitle()
    }

    // MARK: Sidebar

    func showSidebar(_ mode: SidebarMode) {
        if organiser != nil { hideOrganiser() }
        if sidebarItem.isCollapsed { setSidebarVisible(true) }
        if mode != .search { modeBeforeSearch = mode }
        sidebar.show(mode)
    }

    func setSidebarVisible(_ visible: Bool) {
        let item = sidebarItem!
        if environment.moves {
            item.animator().isCollapsed = !visible
        } else {
            item.isCollapsed = !visible
        }
    }

    // MARK: Tool panel (ux §2.1: 320 pt inline; below a 1000 pt window it floats over the document as a card)

    func setToolPanel(_ panel: NSViewController?) {
        let narrow = (window?.frame.width ?? SPMetrics.Window.defaultSize.width) < SPMetrics.ToolPanel.overlayBelowWindowWidth
        documentArea.setOverlayPanel(nil)
        panelSlot.setPanel(nil)
        guard let panel else {
            setPanelCollapsed(true)
            return
        }
        if narrow {
            setPanelCollapsed(true)
            documentArea.setOverlayPanel(panel)
        } else {
            panelSlot.setPanel(panel)
            setPanelCollapsed(false)
        }
    }

    private func setPanelCollapsed(_ collapsed: Bool) {
        guard panelItem.isCollapsed != collapsed else { return }
        if environment.moves {
            NSAnimationContext.runAnimationGroup { context in
                context.duration = SPMotion.panelOpen
                context.timingFunction = CAMediaTimingFunction(name: .easeOut)
                context.allowsImplicitAnimation = true
                panelItem.animator().isCollapsed = collapsed
            }
        } else {
            panelItem.isCollapsed = collapsed
        }
    }

    public func windowDidResize(_ notification: Notification) {
        let panel = panelSlot.panel ?? documentArea.overlayPanel
        let narrow = (window?.frame.width ?? 0) < SPMetrics.ToolPanel.overlayBelowWindowWidth
        if let panel, narrow == (panelSlot.panel != nil) { setToolPanel(panel) }
    }

    // MARK: Banner (ux §7.3): ToolsKit draws it; it lives in the 44 pt slot under the toolbar

    func showBanner(_ banner: ResultBanner) {
        guard let tools = Services.tools else { return }
        var bannerView: NSView?
        let view = tools.makeBannerView(banner, in: handle) { [weak self] in
            guard let self, let bannerView else { return }
            self.root.hideBanner(bannerView, animated: self.environment.moves)
        }
        bannerView = view
        root.showBanner(view, animated: environment.moves)
    }

    // MARK: Organiser (ux §6.2)

    func showOrganiser(adding files: [URL]) {
        if organiser == nil {
            let organiser = OrganiserViewController(owner: self)
            self.organiser = organiser
            root.setContent(organiser)
            window?.toolbar = toolbarController.makeOrganiserToolbar()
            organiser.reload(selecting: sidebar.thumbnails.selection)
        }
        if !files.isEmpty { pageActions.insertFiles(files, atGap: handle.pageCount, tagged: true) }
    }

    func hideOrganiser() {
        guard let organiser else { return }
        let selection = organiser.grid.selection
        organiser.removeFromParent()
        self.organiser = nil
        root.setContent(split)
        window?.toolbar = toolbarController.makeToolbar(persists: environment.persistsWindowState)
        sidebar.thumbnails.reload(selecting: selection)
        if let first = selection.first { go(toPage: first) }
    }

    // MARK: View state (features §2.1: remembered per document, in the file's extended attribute)

    private func restoreViewState() {
        let state = handle.url.flatMap { Services.documents?.viewState(for: $0) } ?? DocumentViewState()
        window?.layoutIfNeeded()
        split.splitView.setPosition(CGFloat(state.sidebarWidth), ofDividerAt: 0)
        sidebarItem.isCollapsed = !state.sidebarVisible
        setDisplayMode(state.displayMode)
        if let scale = state.scale {
            fitsPage = false
            pdfView.scaleFactor = CGFloat(scale)
        } else if Defaults[.defaultZoom] == .scaleToFit {
            fitsPage = true
        } else {
            fitsPage = false
            pdfView.scaleFactor = 1
        }
        if state.pageIndex > 0 { go(toPage: min(state.pageIndex, max(handle.pageCount - 1, 0))) }
        sidebar.thumbnails.select([currentPageIndex], scroll: state.pageIndex > 0)
        sidebar.show(state.sidebarMode == .search || state.sidebarMode == .signatures ? .thumbnails : state.sidebarMode)
    }

    var viewState: DocumentViewState {
        let mode = sidebar.mode == .search ? modeBeforeSearch : sidebar.mode
        return DocumentViewState(pageIndex: currentPageIndex, scale: fitsPage ? nil : Double(pdfView.scaleFactor),
                                 displayMode: displayMode, sidebarMode: mode, sidebarVisible: !sidebarItem.isCollapsed,
                                 sidebarWidth: Double(sidebarItem.isCollapsed ? SPMetrics.Sidebar.defaultWidth : sidebar.view.frame.width))
    }

    var displayMode: DisplayMode {
        switch pdfView.displayMode {
        case .singlePage: .singlePage
        case .twoUp, .twoUpContinuous: .twoPages
        default: .continuousScroll
        }
    }

    func setDisplayMode(_ mode: DisplayMode) {
        switch mode {
        case .continuousScroll: pdfView.displayMode = .singlePageContinuous; pdfView.displaysAsBook = false
        case .singlePage: pdfView.displayMode = .singlePage; pdfView.displaysAsBook = false
        case .twoPages: pdfView.displayMode = .twoUpContinuous; pdfView.displaysAsBook = true
        }
        fitPage()
    }

    /// The scale that shows the whole page (two side by side in Two Pages) with room around it.
    func fitPage() {
        guard fitsPage, let page = pdfView.currentPage ?? handle.pdf.page(at: 0) else { return }
        let box = page.bounds(for: pdfView.displayBox)
        var size = page.rotation % 180 == 0 ? box.size : CGSize(width: box.height, height: box.width)
        if pdfView.displayMode == .twoUp || pdfView.displayMode == .twoUpContinuous { size.width *= 2 }
        let room: CGFloat = 20
        let area = pdfView.bounds.size
        guard size.width > 0, size.height > 0, area.width > 2 * room, area.height > 2 * room else { return }
        let scale = min((area.width - 2 * room) / size.width, (area.height - 2 * room) / size.height)
        pdfView.autoScales = false
        pdfView.scaleFactor = min(max(scale, SPMetrics.Document.scaleRange.lowerBound), SPMetrics.Document.scaleRange.upperBound)
        pdfView.layoutDocumentView()
    }

    public func windowWillClose(_ notification: Notification) {
        readAloud.stop()
        if let url = handle.url { Services.documents?.saveViewState(viewState, for: url) }
        if handle.pdf.isFinding { handle.pdf.cancelFindString() }
        viewer.windowClosed(self)
    }
}

/// The window's content: the result banner's slot under the toolbar, full width, over the split view or the organiser.
@MainActor
final class RootViewController: NSViewController {
    private let bannerSlot = NSView()
    private var bannerHeight: NSLayoutConstraint!
    private let contentSlot = NSView()
    private(set) var content: NSViewController?
    private(set) var banner: NSView?

    override func loadView() {
        let root = NSView(frame: NSRect(origin: .zero, size: SPMetrics.Window.defaultSize))
        for view in [bannerSlot, contentSlot] {
            view.translatesAutoresizingMaskIntoConstraints = false
            root.addSubview(view)
        }
        bannerSlot.wantsLayer = true
        bannerSlot.layer?.masksToBounds = true
        bannerHeight = bannerSlot.heightAnchor.constraint(equalToConstant: 0)
        NSLayoutConstraint.activate([
            bannerSlot.topAnchor.constraint(equalTo: root.safeAreaLayoutGuide.topAnchor),
            bannerSlot.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            bannerSlot.trailingAnchor.constraint(equalTo: root.trailingAnchor),
            bannerHeight,
            contentSlot.topAnchor.constraint(equalTo: bannerSlot.bottomAnchor),
            contentSlot.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            contentSlot.trailingAnchor.constraint(equalTo: root.trailingAnchor),
            contentSlot.bottomAnchor.constraint(equalTo: root.bottomAnchor),
        ])
        view = root
    }

    func setContent(_ controller: NSViewController) {
        _ = view
        if let content, content !== controller {
            content.view.removeFromSuperview()
            content.removeFromParent()
        }
        content = controller
        addChild(controller)
        controller.view.frame = contentSlot.bounds
        controller.view.autoresizingMask = [.width, .height]
        contentSlot.addSubview(controller.view)
    }

    /// Slides the banner down 44 pt under the toolbar, 300 ms ease-out (ux §2.5); a newer banner replaces it.
    func showBanner(_ view: NSView, animated: Bool) {
        banner?.removeFromSuperview()
        banner = view
        view.translatesAutoresizingMaskIntoConstraints = false
        bannerSlot.addSubview(view)
        NSLayoutConstraint.activate([
            view.leadingAnchor.constraint(equalTo: bannerSlot.leadingAnchor),
            view.trailingAnchor.constraint(equalTo: bannerSlot.trailingAnchor),
            view.bottomAnchor.constraint(equalTo: bannerSlot.bottomAnchor),
            view.heightAnchor.constraint(equalToConstant: SPMetrics.Banner.height),
        ])
        setBannerHeight(SPMetrics.Banner.height, animated: animated)
    }

    func hideBanner(_ view: NSView, animated: Bool) {
        guard banner === view else { return }
        banner = nil
        setBannerHeight(0, animated: animated) { view.removeFromSuperview() }
    }

    private func setBannerHeight(_ height: CGFloat, animated: Bool, completion: (@MainActor () -> Void)? = nil) {
        guard animated else {
            bannerHeight.constant = height
            view.layoutSubtreeIfNeeded()
            completion?()
            return
        }
        NSAnimationContext.runAnimationGroup({ context in
            context.duration = SPMotion.banner
            context.timingFunction = CAMediaTimingFunction(name: .easeOut)
            context.allowsImplicitAnimation = true
            bannerHeight.animator().constant = height
            view.layoutSubtreeIfNeeded()
        }, completionHandler: { MainActor.assumeIsolated { completion?() } })
    }

    var bannerSlotHeight: CGFloat { bannerHeight.constant }
}

/// The 320 pt inline slot ToolsKit's panels go into.
@MainActor
final class PanelSlotViewController: NSViewController {
    private(set) var panel: NSViewController?

    override func loadView() {
        view = NSView(frame: NSRect(x: 0, y: 0, width: SPMetrics.ToolPanel.width, height: 600))
    }

    func setPanel(_ controller: NSViewController?) {
        _ = view
        if let panel { panel.view.removeFromSuperview(); panel.removeFromParent() }
        panel = controller
        guard let controller else { return }
        addChild(controller)
        controller.view.frame = view.bounds
        controller.view.autoresizingMask = [.width, .height]
        view.addSubview(controller.view)
    }
}
