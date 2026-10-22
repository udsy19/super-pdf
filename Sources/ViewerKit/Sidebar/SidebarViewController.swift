import AppKit
import PDFKit
import SuperPDFCore

/// The sidebar (ux §2.1, §6.3): one mode at a time — Thumbnails, Table of Contents, Highlights and Notes, Bookmarks,
/// Attachments, Search results while searching, Signatures when the file is signed — over the 29 pt bottom bar with
/// the page count and [+].
@MainActor
final class SidebarViewController: NSViewController {
    private unowned let owner: DocumentWindowController
    let thumbnails: PageGridViewController
    private(set) var mode: SidebarMode = .thumbnails
    private var controllers: [SidebarMode: NSViewController] = [:]
    private let container = NSView()
    let bottomBar = SidebarBottomBar()

    init(owner: DocumentWindowController) {
        self.owner = owner
        thumbnails = PageGridViewController(owner: owner)
        super.init(nibName: nil, bundle: nil)
    }

    required init?(coder: NSCoder) { fatalError("not used") }

    override func loadView() {
        let root = NSVisualEffectView()
        root.material = .sidebar
        root.blendingMode = .behindWindow
        root.state = .followsWindowActiveState
        container.translatesAutoresizingMaskIntoConstraints = false
        bottomBar.translatesAutoresizingMaskIntoConstraints = false
        root.addSubview(container)
        root.addSubview(bottomBar)
        NSLayoutConstraint.activate([
            container.topAnchor.constraint(equalTo: root.topAnchor),
            container.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            container.trailingAnchor.constraint(equalTo: root.trailingAnchor),
            container.bottomAnchor.constraint(equalTo: bottomBar.topAnchor),
            bottomBar.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            bottomBar.trailingAnchor.constraint(equalTo: root.trailingAnchor),
            bottomBar.bottomAnchor.constraint(equalTo: root.bottomAnchor),
            bottomBar.heightAnchor.constraint(equalToConstant: SPMetrics.Sidebar.bottomBarHeight),
        ])
        bottomBar.onAdd = { [weak self] button in self?.addPressed(button) }
        view = root
        install(thumbnails, for: .thumbnails)
        pagesChanged()
    }

    /// Switches the mode; the search and signatures modes come and go with their content.
    func show(_ mode: SidebarMode) {
        _ = view
        let controller = controllers[mode] ?? makeController(for: mode)
        if controllers[mode] == nil { controllers[mode] = controller }
        install(controller, for: mode)
        (controller as? SidebarRefreshing)?.refresh()
        bottomBar.showsAdd = [.thumbnails, .tableOfContents, .bookmarks].contains(mode)
    }

    private func install(_ controller: NSViewController, for mode: SidebarMode) {
        self.mode = mode
        controllers[mode] = controller
        container.subviews.forEach { $0.removeFromSuperview() }
        children.filter { $0 !== controller }.forEach { $0.removeFromParent() }
        if controller.parent == nil { addChild(controller) }
        controller.view.frame = container.bounds
        controller.view.autoresizingMask = [.width, .height]
        container.addSubview(controller.view)
    }

    private func makeController(for mode: SidebarMode) -> NSViewController {
        switch mode {
        case .thumbnails: thumbnails
        case .tableOfContents: OutlineSidebarController(owner: owner)
        case .highlightsAndNotes: NotesSidebarController(owner: owner)
        case .bookmarks: BookmarksSidebarController(owner: owner)
        case .attachments: AttachmentsSidebarController(owner: owner)
        case .search: SearchSidebarController(owner: owner)
        case .signatures: SignaturesSidebarController(owner: owner)
        }
    }

    /// The search results controller, made on first use.
    var search: SearchSidebarController {
        if let existing = controllers[.search] as? SearchSidebarController { return existing }
        let made = SearchSidebarController(owner: owner)
        controllers[.search] = made
        return made
    }

    /// Pages or annotations changed: the count, and the current mode's content.
    func pagesChanged() {
        bottomBar.text = ViewerStrings.pages(owner.handle.pageCount)
        if mode != .thumbnails { (controllers[mode] as? SidebarRefreshing)?.refresh() }
    }

    private func addPressed(_ button: NSView) {
        switch mode {
        case .thumbnails: owner.showAddPagesMenu(at: (owner.selectedPages.max() ?? owner.currentPageIndex) + 1, from: button)
        case .tableOfContents: (controllers[.tableOfContents] as? OutlineSidebarController)?.addEntryForCurrentPage()
        case .bookmarks: owner.toggleBookmark()
        default: break
        }
    }
}

/// Modes that rebuild their rows when the document changes.
@MainActor
protocol SidebarRefreshing: AnyObject {
    func refresh()
}

/// "12 pages" and [+] (ux §2.1: 29 pt, 11 pt secondary text).
final class SidebarBottomBar: NSView {
    var onAdd: ((NSView) -> Void)?
    var text = "" { didSet { label.stringValue = text } }
    var showsAdd = true { didSet { addButton.isHidden = !showsAdd } }
    private let label = NSTextField(labelWithString: "")
    private let addButton = NSButton()

    override init(frame: NSRect) {
        super.init(frame: frame)
        label.font = SPFont.secondary.font()
        label.textColor = SPColor.secondaryLabel.color
        label.translatesAutoresizingMaskIntoConstraints = false
        addButton.image = NSImage(systemSymbolName: "plus", accessibilityDescription: ViewerStrings.AddPages.addPages)
        addButton.symbolConfiguration = .init(pointSize: 12, weight: .medium)
        addButton.contentTintColor = SPColor.secondaryLabel.color
        addButton.isBordered = false
        addButton.toolTip = ViewerStrings.AddPages.addPages
        addButton.target = self
        addButton.action = #selector(add(_:))
        addButton.translatesAutoresizingMaskIntoConstraints = false
        addSubview(label)
        addSubview(addButton)
        NSLayoutConstraint.activate([
            label.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 14),
            label.centerYAnchor.constraint(equalTo: centerYAnchor),
            addButton.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -8),
            addButton.centerYAnchor.constraint(equalTo: centerYAnchor),
            addButton.widthAnchor.constraint(equalToConstant: 20),
            addButton.heightAnchor.constraint(equalToConstant: 20),
        ])
    }

    required init?(coder: NSCoder) { fatalError("not used") }

    @objc private func add(_ sender: NSButton) { onAdd?(sender) }

    override func draw(_ dirtyRect: NSRect) {
        SPColor.separator.color.setFill()
        NSRect(x: 0, y: bounds.height - 1, width: bounds.width, height: 1).fill()
    }
}
