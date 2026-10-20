import AppKit
import Combine
import SuperPDFCore
import UniformTypeIdentifiers

/// `Services.tools` (ux §4–§5): the providers, the Tools sheet, the panels in each document window, the live preview,
/// Recently used, the banner, toolbar items and the Dock menu.
@MainActor
final class ToolsController: NSObject, ToolRegistry {
    // MARK: Providers

    private var providers: [ToolID: any ToolProviding] = [:]
    private var collected = -1

    /// Providers are read from `Services.toolProviders` when first needed and again if more were added (ViewerKit
    /// installs after ToolsKit).
    func provider(for tool: ToolID) -> (any ToolProviding)? {
        if Services.toolProviders.count != collected {
            providers = ToolCoverage.map(Services.toolProviders)
            collected = Services.toolProviders.count
        }
        return providers[tool]
    }

    /// Logs what is wrong with the providers (run once every module has installed).
    func reportCoverage() {
        let registered = Services.toolProviders
        let strict = Set(registered.flatMap(\.tools)).count == ToolCatalog.tiles.count
        for issue in ToolCoverage.issues(registered, requireAll: strict) { Log.tools.fault("Tool coverage: \(issue.description, privacy: .public)") }
    }

    func availability(of tool: ToolID) -> ToolAvailability { provider(for: tool)?.availability(of: tool) ?? .ready }

    // MARK: Search and Recently used

    func search(_ query: String) -> [ToolTile] {
        let frecency = Defaults[.frecency], now = Date()
        return ToolSearch.rank(query, boost: { frecency.score($0, now: now) })
    }

    var recentlyUsed: [ToolTile] {
        Defaults[.frecency].top(SPMetrics.ToolsSheet.recentTiles).map(ToolCatalog.tile)
    }

    func recordUse(_ tool: ToolID) {
        var frecency = Defaults[.frecency]
        frecency.record(tool)
        Defaults[.frecency] = frecency
    }

    // MARK: The Tools sheet

    private lazy var sheet: ToolsSheetController = {
        let frecency = { Defaults[.frecency] }
        let model = ToolsSheetModel(recents: { [unowned self] in recentlyUsed }, boost: { frecency().score($0) })
        return ToolsSheetController(model: model, availability: { [unowned self] in availability(of: $0) }, actions: .init(
            choose: { [unowned self] tile, urls in choose(tile, inputs: urls) },
            close: { [unowned self] in closeSheet() },
            addToToolbar: { tile in Defaults[.toolbarTools] = Defaults[.toolbarTools].filter { $0 != tile.id } + [tile.id] },
            addToDockMenu: { tile in Defaults[.dockMenuTools] = Defaults[.dockMenuTools].filter { $0 != tile.id } + [tile.id] }))
    }()
    private var sheetWindow: NSWindow?
    private weak var sheetParent: NSWindow?
    private weak var sheetDocument: DocumentHandle?

    func showToolsSheet(for document: DocumentHandle?) { presentSheet(for: document, query: "") }

    private func presentSheet(for document: DocumentHandle?, query: String) {
        closeSheet()
        let parent = document.flatMap { Services.viewer?.pdfView(for: $0)?.window }
        let size = Self.sheetSize(in: parent?.contentLayoutRect.size)
        let window = sheetWindow ?? makeSheetWindow()
        sheet.prepare(query: query)
        window.setContentSize(size)
        sheetDocument = document
        sheetParent = parent
        if let parent {
            parent.beginSheet(window)
        } else {
            window.center()
            window.makeKeyAndOrderFront(nil)
        }
    }

    /// 880 × 620, kept 80 pt inside the window each way, never under 640 × 480 (ux §2.1).
    static func sheetSize(in content: NSSize?) -> NSSize {
        let ideal = SPMetrics.ToolsSheet.size, minimum = SPMetrics.ToolsSheet.minimumSize, inset = SPMetrics.ToolsSheet.windowInset
        guard let content else { return ideal }
        return NSSize(width: max(minimum.width, min(ideal.width, content.width - inset)),
                      height: max(minimum.height, min(ideal.height, content.height - inset)))
    }

    private func makeSheetWindow() -> NSWindow {
        let window = NSWindow(contentRect: NSRect(origin: .zero, size: SPMetrics.ToolsSheet.size),
                              styleMask: [.titled, .closable, .fullSizeContentView], backing: .buffered, defer: true)
        window.titleVisibility = .hidden
        window.titlebarAppearsTransparent = true
        for button: NSWindow.ButtonType in [.closeButton, .miniaturizeButton, .zoomButton] { window.standardWindowButton(button)?.isHidden = true }
        window.isReleasedWhenClosed = false
        window.contentViewController = sheet
        window.title = Strings.ToolsSheet.title
        sheetWindow = window
        return window
    }

    private func closeSheet() {
        guard let window = sheetWindow, window.isVisible || window.sheetParent != nil else { return }
        if let parent = window.sheetParent { parent.endSheet(window) } else { window.orderOut(nil) }
    }

    private func choose(_ tile: ToolTile, inputs: [URL]) {
        lastQuery = sheet.model.query
        let document = sheetDocument
        closeSheet()
        openPanel(tile.id, for: document, inputs: inputs)
    }

    /// The search typed before a tile was chosen, restored by the panel's back arrow.
    private var lastQuery = ""

    // MARK: Panels

    private struct OpenPanel {
        var session: ToolSession
        var controller: ToolPanelController
        var window: NSWindow?
        var observers: [Any]
        var cancellables: Set<AnyCancellable>
    }

    private var panels: [UUID: OpenPanel] = [:]
    /// Panels of tools started without a document (Combine from the welcome window, conversions from the Dock).
    private var loosePanels: [ObjectIdentifier: OpenPanel] = [:]
    private var lastTool: [UUID: ToolID] = [:]

    func openPanel(_ tool: ToolID, for document: DocumentHandle?, inputs: [URL]) {
        guard let provider = provider(for: tool) else {
            Log.tools.fault("No provider for \(tool.rawValue, privacy: .public)")
            NSSound.beep()
            return
        }
        let tile = ToolCatalog.tile(tool)
        guard document != nil || !tile.needsDocument else { return openAfterChoosingPDF(tile, inputs: inputs) }
        if let document { dismissPanel(of: document) }
        let selection = document.flatMap { Services.viewer?.selectedPages(in: $0) } ?? []
        let current = document.flatMap { Services.viewer?.currentPage(in: $0) } ?? 0
        let session = ToolSession(tile: tile, provider: provider, document: document, inputs: inputs, selection: selection, currentPage: current)
        let key = ObjectIdentifier(session)
        let controller = ToolPanelController(session: session, onBack: { [weak self] in
            self?.back(from: document, key: key)
        }, onClose: { [weak self] in
            self?.close(document, key: key)
        })
        session.onFinish = { [weak self] _ in self?.close(document, key: key) }
        var open = OpenPanel(session: session, controller: controller, window: nil, observers: [], cancellables: [])

        if let document {
            lastTool[document.id] = tool
            Services.viewer?.showToolPanel(controller, in: document)
            open.observers = watchSelection(of: document, session: session)
            open.cancellables = bindPreview(of: document, session: session)
            panels[document.id] = open
        } else {
            let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: SPMetrics.ToolPanel.width, height: SPMetrics.ToolsSheet.size.height),
                                  styleMask: [.titled, .closable, .fullSizeContentView], backing: .buffered, defer: true)
            window.titleVisibility = .hidden
            window.titlebarAppearsTransparent = true
            window.isReleasedWhenClosed = false
            window.title = tile.name
            window.contentViewController = controller
            window.center()
            window.makeKeyAndOrderFront(nil)
            open.window = window
            loosePanels[key] = open
        }
        Task { await session.updatePreview() }
    }

    func closePanel(for document: DocumentHandle) { dismissPanel(of: document) }

    private func dismissPanel(of document: DocumentHandle) {
        guard let open = panels.removeValue(forKey: document.id) else { return }
        open.session.stop()
        open.observers.forEach(NotificationCenter.default.removeObserver)
        if let pdfView = Services.viewer?.pdfView(for: document), let overlay = pdfView.pageOverlayViewProvider as? PreviewOverlay {
            overlay.draw = nil
        }
        Services.viewer?.showToolPanel(nil, in: document)
    }

    private func close(_ document: DocumentHandle?, key: ObjectIdentifier) {
        if let document, panels[document.id].map({ ObjectIdentifier($0.session) == key }) == true {
            dismissPanel(of: document)
        } else if let open = loosePanels.removeValue(forKey: key) {
            open.session.stop()
            open.window?.close()
        }
        sheet.model.reload()
    }

    private func back(from document: DocumentHandle?, key: ObjectIdentifier) {
        close(document, key: key)
        presentSheet(for: document, query: lastQuery)
    }

    /// A document tile chosen with no document open: pick a PDF, open it, then the panel.
    private func openAfterChoosingPDF(_ tile: ToolTile, inputs: [URL]) {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.pdf]
        panel.message = ToolsKitStrings.choosePDF(for: tile.name)
        guard panel.runModal() == .OK, let url = panel.url else { return }
        Task {
            do {
                let document = try await Services.documents.open(url)
                openPanel(tile.id, for: document, inputs: inputs)
            } catch {
                Log.tools.error("Couldn’t open \(url.lastPathComponent, privacy: .private): \(error.localizedDescription, privacy: .public)")
            }
        }
    }

    /// Thumbnails picked while the panel is open switch the scope (ux §5.1); checked after each event in that window.
    /// A mode tool's page interaction reaches its panel through `ToolPanel.performActionNotification`.
    private func watchSelection(of document: DocumentHandle, session: ToolSession) -> [Any] {
        let action = NotificationCenter.default.addObserver(forName: ToolPanel.performActionNotification, object: document, queue: .main) {
            [weak session] note in
            MainActor.assumeIsolated {
                guard let session, let id = note.userInfo?[ToolPanel.actionKey] as? String else { return }
                Task { await session.perform(id) }
            }
        }
        guard let window = Services.viewer?.pdfView(for: document)?.window else { return [action] }
        let observer = NotificationCenter.default.addObserver(forName: NSWindow.didUpdateNotification, object: window, queue: .main) {
            [weak session] _ in
            MainActor.assumeIsolated {
                guard let session, let viewer = Services.viewer else { return }
                session.updateSelection(viewer.selectedPages(in: document), currentPage: viewer.currentPage(in: document))
            }
        }
        return [action, observer]
    }

    /// `.overlay` previews are drawn over the document's pages; the overlay is installed the first time one arrives.
    private func bindPreview(of document: DocumentHandle, session: ToolSession) -> Set<AnyCancellable> {
        var bag = Set<AnyCancellable>()
        session.$preview.sink { [weak self] preview in
            guard self != nil, let pdfView = Services.viewer?.pdfView(for: document) else { return }
            switch preview {
            case .overlay(let draw): PreviewOverlay.installed(on: pdfView).draw = draw
            default: (pdfView.pageOverlayViewProvider as? PreviewOverlay)?.draw = nil
            }
        }.store(in: &bag)
        return bag
    }

    // MARK: Banner, toolbar, Dock menu

    func makeBannerView(_ banner: ResultBanner, in document: DocumentHandle, dismiss: @escaping @MainActor () -> Void) -> NSView {
        ResultBannerView(banner: banner, document: document, showDetails: { [weak self, weak document] in
            guard let self, let document, let tool = lastTool[document.id] else { return }
            openPanel(tool, for: document, inputs: [])
        }, dismiss: dismiss)
    }

    func makeToolbarItem(_ tool: ToolID) -> NSToolbarItem {
        let tile = ToolCatalog.tile(tool)
        let item = NSToolbarItem(itemIdentifier: tool.toolbarItemIdentifier)
        item.label = tile.name
        item.paletteLabel = tile.name
        item.toolTip = tile.hint
        item.image = NSImage(systemSymbolName: tile.symbol, accessibilityDescription: tile.name)
        item.isBordered = true
        item.target = self
        item.action = #selector(toolbarItemChosen(_:))
        return item
    }

    @objc private func toolbarItemChosen(_ sender: NSToolbarItem) {
        guard let tool = ToolID(toolbarItemIdentifier: sender.itemIdentifier) else { return }
        let window = NSApp.windows.first { $0.toolbar === sender.toolbar }
        let document = Services.documents?.openDocuments.first { Services.viewer?.pdfView(for: $0)?.window === window }
        openPanel(tool, for: document ?? Services.documents?.frontmost, inputs: [])
    }

    func makeDockMenu() -> NSMenu {
        let menu = NSMenu()
        let all = NSMenuItem(title: Strings.ToolsSheet.allTools, action: #selector(dockAllTools), keyEquivalent: "")
        all.target = self
        menu.addItem(all)
        let tools = Defaults[.dockMenuTools]
        if !tools.isEmpty { menu.addItem(.separator()) }
        for tool in tools {
            let item = NSMenuItem(title: ToolCatalog.tile(tool).menuTitle, action: #selector(dockTool(_:)), keyEquivalent: "")
            item.target = self
            item.representedObject = tool.rawValue
            item.image = NSImage(systemSymbolName: ToolCatalog.tile(tool).symbol, accessibilityDescription: nil)
            menu.addItem(item)
        }
        return menu
    }

    @objc private func dockAllTools() { showToolsSheet(for: Services.documents?.frontmost) }

    @objc private func dockTool(_ sender: NSMenuItem) {
        guard let raw = sender.representedObject as? String, let tool = ToolID(rawValue: raw) else { return }
        openPanel(tool, for: Services.documents?.frontmost, inputs: [])
    }
}
