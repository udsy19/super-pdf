import AppKit
import PDFKit
import SuperPDFCore

extension NSToolbarItem.Identifier {
    static let viewMenu = Self("viewer.view")
    static let zoom = Self("viewer.zoom")
    static let markup = Self("viewer.markup")
    static let rotate = Self("viewer.rotate")
    static let formFilling = Self("viewer.formFilling")
    static let tools = Self("viewer.tools")
    static let share = Self("viewer.share")
    static let search = Self("viewer.search")
    static let workspaceMode = Self("viewer.workspace.mode")
    static let workspaceAdd = Self("viewer.workspace.add")
    static let workspaceRotateLeft = Self("viewer.workspace.rotateLeft")
    static let workspaceRotateRight = Self("viewer.workspace.rotateRight")
    static let workspaceDelete = Self("viewer.workspace.delete")
    static let workspaceSelectAll = Self("viewer.workspace.selectAll")
    static let workspaceSort = Self("viewer.workspace.sort")
    static let workspaceLayout = Self("viewer.workspace.layout")
    static let workspaceFinish = Self("viewer.workspace.finish")
}

/// The document window's toolbar (ux §2.1, Preview's `CommonToolbar` default set plus Tools): View popup · tracking
/// separator · Zoom (−, 1, +) · title (centred) · Markup · Rotate · Form Filling (only with form fields) · favourites ·
/// Tools · Share · Search. Customisable; every tile can be added (View › Customize Toolbar…, "Add to Toolbar").
/// The workspace has its own (ux §6.2): View popup · Files | Pages · (the title) · Add ▾ · ⟲ ⟳ 🗑 · Select All · Sort ▾ ·
/// Grid | List · Finish.
@MainActor
final class DocumentToolbar: NSObject, NSToolbarDelegate, NSSearchFieldDelegate, NSSharingServicePickerToolbarItemDelegate {
    weak var owner: DocumentWindowController!
    private(set) weak var searchField: NSSearchField?
    private var searchDebounce: Timer?

    static let documentToolbarID = "SuperPDFDocumentToolbar"
    static let workspaceToolbarID = "SuperPDFWorkspaceToolbar"

    func makeToolbar(persists: Bool) -> NSToolbar {
        let toolbar = NSToolbar(identifier: Self.documentToolbarID)
        toolbar.delegate = self
        toolbar.displayMode = .iconOnly
        toolbar.allowsUserCustomization = true
        toolbar.autosavesConfiguration = persists
        return toolbar
    }

    func makeWorkspaceToolbar() -> NSToolbar {
        let toolbar = NSToolbar(identifier: Self.workspaceToolbarID)
        toolbar.delegate = self
        toolbar.displayMode = .iconOnly
        toolbar.allowsUserCustomization = false
        return toolbar
    }

    // MARK: Item sets

    func toolbarDefaultItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] {
        if toolbar.identifier == Self.workspaceToolbarID {
            // `.space` keeps macOS 26 from merging neighbouring bordered items into one glass capsule.
            return [.viewMenu, .workspaceMode, .flexibleSpace, .workspaceAdd, .workspaceRotateLeft, .workspaceRotateRight, .workspaceDelete, .space,
                    .workspaceSelectAll, .workspaceSort, .workspaceLayout, .space, .workspaceFinish]
        }
        let forms: [NSToolbarItem.Identifier] = owner.handle.state.hasFormFields ? [.formFilling] : []
        // The title and subtitle are the window's own (leading, after the zoom group); `.space` keeps macOS 26 from merging
        // neighbouring bordered items into one glass capsule.
        return [.viewMenu, .sidebarTrackingSeparator, .zoom, .flexibleSpace, .markup, .rotate] + forms
            + Defaults[.toolbarTools].map(\.toolbarItemIdentifier) + [.space, .tools, .space, .share, .space, .search]
    }

    func toolbarAllowedItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] {
        if toolbar.identifier == Self.workspaceToolbarID { return toolbarDefaultItemIdentifiers(toolbar) }
        return [.viewMenu, .sidebarTrackingSeparator, .zoom, .markup, .rotate, .formFilling, .tools, .share, .search,
                .flexibleSpace, .space] + ToolCatalog.tiles.map(\.id.toolbarItemIdentifier)
    }

    func toolbar(_ toolbar: NSToolbar, itemForItemIdentifier identifier: NSToolbarItem.Identifier,
                 willBeInsertedIntoToolbar flag: Bool) -> NSToolbarItem? {
        if let tool = ToolID(toolbarItemIdentifier: identifier) { return Services.tools?.makeToolbarItem(tool) }
        switch identifier {
        case .sidebarTrackingSeparator:
            return NSTrackingSeparatorToolbarItem(identifier: identifier, splitView: owner.split.splitView, dividerIndex: 0)
        case .viewMenu:
            let item = NSMenuToolbarItem(itemIdentifier: identifier)
            item.image = NSImage(systemSymbolName: "sidebar.leading", accessibilityDescription: ViewerStrings.Toolbar.view)
            item.label = ViewerStrings.Toolbar.view
            item.toolTip = ViewerStrings.Toolbar.view
            item.showsIndicator = true
            item.menu = ViewMenuBuilder.menu(for: owner)
            return item
        case .zoom:
            let group = NSToolbarItemGroup(itemIdentifier: identifier, images: [Self.symbol("minus"), Self.textImage("1"), Self.symbol("plus")],
                                           selectionMode: .momentary,
                                           labels: [ViewerStrings.Toolbar.zoomOut, ViewerStrings.Toolbar.actualSize, ViewerStrings.Toolbar.zoomIn],
                                           target: self, action: #selector(zoom(_:)))
            group.label = ViewerStrings.Toolbar.zoom
            group.controlRepresentation = .expanded
            return group
        case .markup:
            return button(identifier, symbol: "pencil.tip.crop.circle", label: ViewerStrings.Toolbar.markup, action: #selector(toggleMarkup(_:)))
        case .rotate:
            return button(identifier, symbol: "rotate.left", label: ViewerStrings.Toolbar.rotate, action: #selector(rotateLeft(_:)))
        case .formFilling:
            return button(identifier, symbol: "rectangle.and.pencil.and.ellipsis", label: ViewerStrings.Toolbar.formFilling,
                          action: #selector(fillForm(_:)))
        case .tools:
            // A native bordered item; on macOS 26 the prominent style draws the accent-tinted glass capsule.
            let item = NSToolbarItem(itemIdentifier: identifier)
            item.image = NSImage(systemSymbolName: SPMetrics.Toolbar.toolsSymbol, accessibilityDescription: ViewerStrings.Toolbar.tools)
            item.title = ViewerStrings.Toolbar.tools
            item.label = ViewerStrings.Toolbar.tools
            item.toolTip = "\(ViewerStrings.Toolbar.tools) (⌘T)"
            item.isBordered = true
            if #available(macOS 26.0, *) { item.style = .prominent }
            item.target = self
            item.action = #selector(showTools(_:))
            item.visibilityPriority = .high
            return item
        case .share:
            let item = NSSharingServicePickerToolbarItem(itemIdentifier: identifier)
            item.delegate = self
            item.label = ViewerStrings.Toolbar.share
            item.toolTip = ViewerStrings.Toolbar.share
            return item
        case .search:
            let item = NSSearchToolbarItem(itemIdentifier: identifier)
            item.preferredWidthForSearchField = SPMetrics.Toolbar.searchFieldWidth
            item.searchField.placeholderString = ViewerStrings.Toolbar.search
            item.searchField.delegate = self
            item.searchField.sendsWholeSearchString = true
            item.searchField.target = self
            item.searchField.action = #selector(searchReturn(_:))
            item.label = ViewerStrings.Toolbar.search
            item.visibilityPriority = .low
            searchField = item.searchField
            return item
        case .workspaceMode:
            // Words with the pictures: the two views are the workspace's first choice (workspace.png).
            let control = NSSegmentedControl(labels: [ViewerStrings.Workspace.files, ViewerStrings.Workspace.pages], trackingMode: .selectOne,
                                             target: self, action: #selector(workspaceMode(_:)))
            for (segment, name) in ["doc.on.doc", "square.grid.2x2"].enumerated() {
                control.setImage(NSImage(systemSymbolName: name, accessibilityDescription: nil), forSegment: segment)
                control.setImageScaling(.scaleProportionallyDown, forSegment: segment)
            }
            control.selectedSegment = owner.workspace?.mode == .pages ? 1 : 0
            control.setAccessibilityLabel(ViewerStrings.Workspace.files + " / " + ViewerStrings.Workspace.pages)
            let item = NSToolbarItem(itemIdentifier: identifier)
            item.view = control
            item.label = ViewerStrings.Workspace.files + " / " + ViewerStrings.Workspace.pages
            item.visibilityPriority = .high
            return item
        case .workspaceAdd:
            let item = NSMenuToolbarItem(itemIdentifier: identifier)
            item.image = NSImage(systemSymbolName: "plus", accessibilityDescription: ViewerStrings.Workspace.add)
            item.label = ViewerStrings.Workspace.add
            item.toolTip = ViewerStrings.Workspace.add
            item.showsIndicator = true
            item.menu = owner.addPagesMenu(atGap: owner.handle.pageCount)
            return item
        case .workspaceRotateLeft:
            return button(identifier, symbol: "rotate.left", label: ViewerStrings.Workspace.rotateLeft, action: #selector(workspaceRotateLeft(_:)))
        case .workspaceRotateRight:
            return button(identifier, symbol: "rotate.right", label: ViewerStrings.Workspace.rotateRight, action: #selector(workspaceRotateRight(_:)))
        case .workspaceDelete:
            return button(identifier, symbol: "trash", label: ViewerStrings.Workspace.delete, action: #selector(workspaceDelete(_:)))
        case .workspaceSelectAll:
            return button(identifier, symbol: "checkmark.circle", label: ViewerStrings.Workspace.selectAll, action: #selector(workspaceSelectAll(_:)))
        case .workspaceSort:
            let item = NSMenuToolbarItem(itemIdentifier: identifier)
            item.image = NSImage(systemSymbolName: "arrow.up.arrow.down", accessibilityDescription: ViewerStrings.Workspace.sort)
            item.label = ViewerStrings.Workspace.sort
            item.toolTip = ViewerStrings.Workspace.sort
            item.showsIndicator = true
            let menu = NSMenu()
            for (title, sort) in [(ViewerStrings.Workspace.sortNameAscending, WorkspaceSort.nameAscending),
                                  (ViewerStrings.Workspace.sortNameDescending, .nameDescending), (ViewerStrings.Workspace.sortReverse, .reverse)] {
                let action = MenuAction { [weak self] in self?.owner.workspace?.sort(sort) }
                let entry = NSMenuItem(title: title, action: #selector(MenuAction.run(_:)), keyEquivalent: "")
                entry.target = action
                entry.representedObject = action
                menu.addItem(entry)
            }
            item.menu = menu
            return item
        case .workspaceLayout:
            let group = NSToolbarItemGroup(itemIdentifier: identifier, images: [Self.symbol("square.grid.2x2"), Self.symbol("list.bullet")],
                                           selectionMode: .selectOne, labels: [ViewerStrings.Workspace.grid, ViewerStrings.Workspace.list],
                                           target: self, action: #selector(workspaceLayout(_:)))
            group.label = ViewerStrings.Workspace.layout
            group.controlRepresentation = .expanded
            group.selectedIndex = owner.workspace?.layoutKind == .list ? 1 : 0
            return group
        case .workspaceFinish:
            let item = NSToolbarItem(itemIdentifier: identifier)
            item.title = ViewerStrings.Workspace.finish
            item.label = ViewerStrings.Workspace.finish
            item.toolTip = ViewerStrings.Workspace.finish
            item.isBordered = true
            if #available(macOS 26.0, *) { item.style = .prominent }
            item.target = self
            item.action = #selector(workspaceFinish(_:))
            item.visibilityPriority = .high
            return item
        default:
            return nil
        }
    }

    private func button(_ identifier: NSToolbarItem.Identifier, symbol: String, label: String, action: Selector) -> NSToolbarItem {
        let item = NSToolbarItem(itemIdentifier: identifier)
        item.image = NSImage(systemSymbolName: symbol, accessibilityDescription: label)
        item.label = label
        item.toolTip = label
        item.isBordered = true
        item.target = self
        item.action = action
        return item
    }

    static func symbol(_ name: String) -> NSImage { NSImage(systemSymbolName: name, accessibilityDescription: nil)! }

    /// The middle segment of Zoom is a "1" (actual size), as in the mockup.
    static func textImage(_ text: String) -> NSImage {
        let font = NSFont.systemFont(ofSize: 15, weight: .regular)
        let string = NSAttributedString(string: text, attributes: [.font: font, .foregroundColor: NSColor.black])
        let size = string.size()
        let image = NSImage(size: NSSize(width: ceil(size.width), height: 16), flipped: false) { rect in
            string.draw(at: NSPoint(x: 0, y: (rect.height - size.height) / 2))
            return true
        }
        image.isTemplate = true
        return image
    }

    // MARK: Changes

    /// Form Filling shows only while the document has fields (ux §2.1).
    func documentStateChanged() {
        guard let toolbar = owner.window?.toolbar, toolbar.identifier == Self.documentToolbarID else { return }
        let index = toolbar.items.firstIndex { $0.itemIdentifier == .formFilling }
        if owner.handle.state.hasFormFields, index == nil, let rotate = toolbar.items.firstIndex(where: { $0.itemIdentifier == .rotate }) {
            toolbar.insertItem(withItemIdentifier: .formFilling, at: rotate + 1)
        } else if !owner.handle.state.hasFormFields, let index {
            toolbar.removeItem(at: index)
        }
    }

    /// "Add to Toolbar" favourites appear before Tools (ux §4).
    func addFavourites(_ tools: [ToolID]) {
        guard let toolbar = owner.window?.toolbar, toolbar.identifier == Self.documentToolbarID else { return }
        for tool in tools where !toolbar.items.contains(where: { $0.itemIdentifier == tool.toolbarItemIdentifier }) {
            let at = toolbar.items.firstIndex { $0.itemIdentifier == .tools } ?? toolbar.items.count
            toolbar.insertItem(withItemIdentifier: tool.toolbarItemIdentifier, at: at)
        }
    }

    // MARK: Actions

    @objc private func zoom(_ sender: NSToolbarItemGroup) {
        owner.fitsPage = false
        switch sender.selectedIndex {
        case 0: owner.pdfView.zoomOut(nil)
        case 1: owner.pdfView.scaleFactor = 1
        default: owner.pdfView.zoomIn(nil)
        }
    }

    @objc func toggleMarkup(_ sender: Any?) {
        Services.markup?.setMarkupBarVisible(!owner.markupBarVisible, in: owner.handle)
    }

    @objc private func rotateLeft(_ sender: Any?) { owner.pageActions.rotate(owner.targetPages, quarterTurns: -1) }

    @objc private func fillForm(_ sender: Any?) { Services.tools?.openPanel(.fillForm, for: owner.handle, inputs: []) }

    @objc private func showTools(_ sender: Any?) { Services.tools?.showToolsSheet(for: owner.handle) }

    @objc private func workspaceMode(_ sender: NSSegmentedControl) { owner.workspace?.setMode(sender.selectedSegment == 1 ? .pages : .files) }
    @objc private func workspaceLayout(_ sender: NSToolbarItemGroup) { owner.workspace?.setLayout(sender.selectedIndex == 1 ? .list : .grid) }
    @objc private func workspaceRotateLeft(_ sender: Any?) { owner.workspace?.rotateSelection(-1) }
    @objc private func workspaceRotateRight(_ sender: Any?) { owner.workspace?.rotateSelection(1) }
    @objc private func workspaceDelete(_ sender: Any?) { owner.workspace?.deleteSelection() }
    @objc private func workspaceSelectAll(_ sender: Any?) { owner.workspace?.selectAll() }
    @objc private func workspaceFinish(_ sender: Any?) { owner.finishWorkspace() }

    /// The workspace's mode, layout or pages changed: its toolbar follows (the Add menu adds at the new end).
    func workspaceChanged() {
        guard let toolbar = owner.window?.toolbar, toolbar.identifier == Self.workspaceToolbarID, let workspace = owner.workspace else { return }
        for item in toolbar.items {
            switch item.itemIdentifier {
            case .workspaceMode: (item.view as? NSSegmentedControl)?.selectedSegment = workspace.mode == .pages ? 1 : 0
            case .workspaceLayout: (item as? NSToolbarItemGroup)?.selectedIndex = workspace.layoutKind == .list ? 1 : 0
            case .workspaceAdd: (item as? NSMenuToolbarItem)?.menu = owner.addPagesMenu(atGap: owner.handle.pageCount)
            case .workspaceFinish: item.isEnabled = workspace.pageCount > 0
            default: break
            }
        }
    }

    // MARK: Search (features #4)

    func controlTextDidChange(_ notification: Notification) {
        guard let field = notification.object as? NSSearchField else { return }
        searchDebounce?.invalidate()
        searchDebounce = Timer.scheduledTimer(withTimeInterval: 0.2, repeats: false) { [weak self] _ in
            MainActor.assumeIsolated { self?.owner.search(field.stringValue) }
        }
    }

    @objc private func searchReturn(_ sender: NSSearchField) {
        if sender.stringValue.isEmpty { owner.search("") } else { owner.findStep(1) }
    }

    func focusSearch() {
        if let searchField { owner.window?.makeFirstResponder(searchField) }
    }

    // MARK: Share

    nonisolated func items(for pickerToolbarItem: NSSharingServicePickerToolbarItem) -> [Any] {
        MainActor.assumeIsolated {
            guard let owner else { return [] }
            if let url = owner.handle.url, !owner.handle.state.isEdited { return [url] }
            let name = (owner.handle.url?.deletingPathExtension().lastPathComponent ?? owner.handle.displayName) + ".pdf"
            let folder = SuperPDFPaths.ensure(SuperPDFPaths.work.appendingPathComponent(UUID().uuidString, isDirectory: true))
            let file = folder.appendingPathComponent(name)
            guard owner.handle.pdf.write(to: file) else { return [] }
            return [file]
        }
    }
}

/// A title for a window without its own: the draggable proxy icon, the name in 13 pt semibold and "— Edited" in the
/// secondary colour (ux §2.1).
final class TitleView: NSView, NSDraggingSource {
    private var title = ""
    private var secondary = ""
    private var url: URL?
    private var showsIcon = false
    private static let iconSize: CGFloat = 16

    func update(name: String, edited: Bool, url: URL?) {
        title = name
        secondary = edited ? ViewerStrings.Toolbar.edited : ""
        self.url = url
        showsIcon = true
        refresh()
    }

    private func refresh() {
        invalidateIntrinsicContentSize()
        needsDisplay = true
        setAccessibilityLabel([title, secondary].filter { !$0.isEmpty }.joined(separator: " "))
    }

    private var attributed: NSAttributedString {
        let text = NSMutableAttributedString(string: title, attributes: [.font: NSFont.systemFont(ofSize: SPFont.body.size, weight: .semibold),
                                                                          .foregroundColor: SPColor.label.color])
        if !secondary.isEmpty {
            text.append(NSAttributedString(string: " " + secondary, attributes: [.font: SPFont.body.font(), .foregroundColor: SPColor.secondaryLabel.color]))
        }
        return text
    }

    override var intrinsicContentSize: NSSize {
        NSSize(width: min(420, ceil(attributed.size().width) + (showsIcon ? Self.iconSize + 6 : 0)), height: 22)
    }

    private var iconRect: NSRect {
        let width = intrinsicContentSize.width
        return NSRect(x: (bounds.width - width) / 2, y: (bounds.height - Self.iconSize) / 2, width: Self.iconSize, height: Self.iconSize)
    }

    override func draw(_ dirtyRect: NSRect) {
        let text = attributed
        let width = intrinsicContentSize.width
        var x = (bounds.width - width) / 2
        if showsIcon {
            let icon = NSWorkspace.shared.icon(for: .pdf)
            icon.draw(in: iconRect)
            x += Self.iconSize + 6
        }
        let size = text.size()
        let available = NSRect(x: x, y: (bounds.height - size.height) / 2 - 2, width: bounds.width - x, height: size.height + 4)
        text.draw(with: available, options: [.truncatesLastVisibleLine, .usesLineFragmentOrigin])
    }

    // The proxy icon drags the file, as a title bar's does.
    override func mouseDown(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        guard showsIcon, let url, iconRect.insetBy(dx: -4, dy: -4).contains(point) else { super.mouseDown(with: event); return }
        let item = NSDraggingItem(pasteboardWriter: url as NSURL)
        item.setDraggingFrame(iconRect, contents: NSWorkspace.shared.icon(forFile: url.path))
        beginDraggingSession(with: [item], event: event, source: self)
    }

    func draggingSession(_ session: NSDraggingSession, sourceOperationMaskFor context: NSDraggingContext) -> NSDragOperation {
        context == .outsideApplication ? [.copy, .link, .generic] : [.copy, .generic]
    }

    override var mouseDownCanMoveWindow: Bool { false }
}
