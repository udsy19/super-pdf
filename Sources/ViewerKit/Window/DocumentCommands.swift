import AppKit
import CoreImage
import PDFKit
import SuperPDFCore
import UniformTypeIdentifiers

/// The menus a document window answers (ux §8, Preview's tree): View, Go, the page commands of Tools and Edit ›
/// Insert, Find, and Speech. Commands it doesn't own go on: File › Save a Copy… and Enter Password… to the document,
/// the rest (Tools, Settings, Welcome…) to the app delegate.
extension DocumentWindowController: MenuCommandResponding, NSMenuItemValidation {
    public func performMenuCommand(_ sender: NSMenuItem) {
        guard let command = sender.menuCommand else { return }
        if perform(command, from: sender) { return }
        forwardee(for: command)?.performMenuCommand(sender)
    }

    public func validateMenuItem(_ menuItem: NSMenuItem) -> Bool {
        switch menuItem.action {
        case #selector(startSpeaking(_:)): return handle.pageCount > 0
        case #selector(stopSpeaking(_:)): return readAloud.isSpeaking
        case #selector(performMenuCommand(_:)): break
        default: return true
        }
        guard let command = menuItem.menuCommand else { return false }
        if let enabled = validate(command, menuItem) { return enabled }
        guard let next = forwardee(for: command) else { return false }
        return (next as? NSMenuItemValidation)?.validateMenuItem(menuItem) ?? true
    }

    /// The document for its own commands (File › Save a Copy…, Enter Password…), else the app delegate.
    private func forwardee(for command: MenuCommand) -> MenuCommandResponding? {
        if [.saveACopy, .enterPassword].contains(command) { return document as? MenuCommandResponding }
        return NSApp.delegate as? MenuCommandResponding
    }

    // MARK: Perform

    /// True when the window handled the command.
    func perform(_ command: MenuCommand, from item: NSMenuItem?) -> Bool {
        switch command {
        case .hideSidebar: setSidebarVisible(sidebarItem.isCollapsed)
        case .thumbnails: showSidebar(.thumbnails)
        case .tableOfContents: showSidebar(.tableOfContents)
        case .highlightsAndNotes: showSidebar(.highlightsAndNotes)
        case .bookmarks: showSidebar(.bookmarks)
        case .attachments: showSidebar(.attachments)
        case .pageOrganiser, .contactSheet: organiser == nil ? showOrganiser(adding: []) : hideOrganiser()
        case .continuousScroll: setDisplayMode(.continuousScroll)
        case .singlePage: setDisplayMode(.singlePage)
        case .twoPages: setDisplayMode(.twoPages)
        case .darkAppearanceForPDF: setDarkPDF(!darkPDF)
        case .actualSize: fitsPage = false; pdfView.scaleFactor = 1
        case .zoomToFit: fitsPage = true
        case .zoomIn: fitsPage = false; pdfView.zoomIn(nil)
        case .zoomOut: fitsPage = false; pdfView.zoomOut(nil)
        case .showMarkupToolbar: toolbarController.toggleMarkup(nil)
        case .slideshow: toggleReader()
        case .up: pdfView.documentView?.enclosingScrollView?.pageUp(nil)
        case .down: pdfView.documentView?.enclosingScrollView?.pageDown(nil)
        case .previousItem: pdfView.goToPreviousPage(nil)
        case .nextItem: pdfView.goToNextPage(nil)
        case .goToPage: askPageNumber()
        case .back: pdfView.goBack(nil)
        case .forward: pdfView.goForward(nil)
        case .rotateLeft: pageActions.rotate(targetPages, quarterTurns: -1)
        case .rotateRight: pageActions.rotate(targetPages, quarterTurns: 1)
        case .addBookmark: toggleBookmark()
        case .cropPage: Services.tools?.openPanel(.crop, for: handle, inputs: [])
        case .find: toolbarController.focusSearch()
        case .findNext: findStep(1)
        case .findPrevious: findStep(-1)
        case .useSelectionForFind:
            guard let text = pdfView.currentSelection?.string, !text.isEmpty else { return true }
            toolbarController.searchField?.stringValue = text
            search(text)
        case .insertPageFromFile: addPagesFromFile(atGap: currentPageIndex + 1)
        case .insertBlankPage: pageActions.insertBlank(after: targetPages.max() ?? currentPageIndex)
        case .insertPageFromScanner: Services.tools?.openPanel(.scanWithScanner, for: handle, inputs: [])
        default: return false
        }
        return true
    }

    /// Enabled state and check marks; nil for commands the window doesn't own.
    func validate(_ command: MenuCommand, _ item: NSMenuItem) -> Bool? {
        let mode = organiser == nil && !sidebarItem.isCollapsed ? sidebar.mode : nil
        func check(_ on: Bool) { item.state = on ? .on : .off }
        switch command {
        case .hideSidebar:
            item.title = sidebarItem.isCollapsed ? ViewerStrings.Toolbar.showSidebar : ViewerStrings.Toolbar.hideSidebar
            return organiser == nil
        case .thumbnails: check(mode == .thumbnails); return true
        case .tableOfContents: check(mode == .tableOfContents); return true
        case .highlightsAndNotes: check(mode == .highlightsAndNotes); return Services.markup != nil
        case .bookmarks: check(mode == .bookmarks); return true
        case .attachments: check(mode == .attachments); return true
        case .pageOrganiser, .contactSheet: check(organiser != nil); return true
        case .continuousScroll: check(displayMode == .continuousScroll); return organiser == nil
        case .singlePage: check(displayMode == .singlePage); return organiser == nil
        case .twoPages: check(displayMode == .twoPages); return organiser == nil
        case .darkAppearanceForPDF: check(darkPDF); return true
        case .actualSize, .zoomToFit, .zoomIn, .zoomOut, .slideshow: return organiser == nil
        case .showMarkupToolbar:
            item.title = markupBarVisible ? "Hide Markup Toolbar" : "Show Markup Toolbar"
            return Services.markup != nil
        case .up, .down, .goToPage: return handle.pageCount > 0
        case .previousItem: return pdfView.canGoToPreviousPage
        case .nextItem: return pdfView.canGoToNextPage
        case .back: return pdfView.canGoBack
        case .forward: return pdfView.canGoForward
        case .rotateLeft, .rotateRight: return handle.state.permissions.pageChanges
        case .addBookmark: return true
        case .cropPage: return Services.tools != nil
        case .find, .useSelectionForFind: return true
        case .findNext, .findPrevious: return !(sidebar.search.matches.isEmpty)
        case .insertPageFromFile, .insertBlankPage: return handle.state.permissions.pageChanges
        case .insertPageFromScanner: return Services.tools != nil && handle.state.permissions.pageChanges
        default: return nil
        }
    }

    // MARK: Speech (Edit › Speech, Preview's): reads the selection or from the page in view

    @objc public func startSpeaking(_ sender: Any?) {
        readAloud.start(fromPage: currentPageIndex, selection: pdfView.currentSelection)
    }

    @objc public func stopSpeaking(_ sender: Any?) { readAloud.stop() }

    // MARK: Search

    func search(_ text: String) {
        let query = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if query.isEmpty {
            sidebar.search.search("")
            if sidebar.mode == .search { sidebar.show(modeBeforeSearch) }
            return
        }
        if sidebar.mode != .search { modeBeforeSearch = sidebar.mode }
        if organiser != nil { hideOrganiser() }
        if sidebarItem.isCollapsed { setSidebarVisible(true) }
        sidebar.show(.search)
        sidebar.search.search(query)
    }

    func findStep(_ direction: Int) { sidebar.search.step(direction) }

    // MARK: Bookmarks (⌘D)

    func toggleBookmark() {
        Bookmarks.toggle(currentPageIndex, in: handle)
        if sidebar.mode == .bookmarks { sidebar.pagesChanged() }
    }

    // MARK: Page menus

    /// The thumbnail context menu (ux §6.3, main-window.png).
    func pageMenu(for pages: [Int]) -> NSMenu {
        let pages = pages.sorted()
        let count = pages.count
        let menu = NSMenu()
        menu.autoenablesItems = false
        let canChange = handle.state.permissions.pageChanges
        func add(_ title: String, key: String = "", modifiers: NSEvent.ModifierFlags = .command, enabled: Bool = true,
                 _ action: @escaping () -> Void) {
            let item = NSMenuItem(title: title, action: #selector(MenuAction.run(_:)), keyEquivalent: key)
            item.keyEquivalentModifierMask = modifiers
            item.representedObject = MenuAction(action)
            item.target = item.representedObject as AnyObject
            item.isEnabled = enabled
            menu.addItem(item)
        }
        add(ViewerStrings.PageMenu.rotateLeft, key: "l", enabled: canChange) { [weak self] in self?.pageActions.rotate(pages, quarterTurns: -1) }
        add(ViewerStrings.PageMenu.rotateRight, key: "r", enabled: canChange) { [weak self] in self?.pageActions.rotate(pages, quarterTurns: 1) }
        add(ViewerStrings.PageMenu.delete(count), key: KeyCombo.deleteKey, modifiers: [], enabled: canChange) { [weak self] in
            self?.pageActions.delete(pages)
        }
        menu.addItem(.separator())
        add(ViewerStrings.PageMenu.extract(count)) { [weak self] in
            guard let self else { return }
            Services.tools?.openPanel(.extractPages, for: self.handle, inputs: [])
        }
        let insert = NSMenuItem(title: ViewerStrings.PageMenu.insert, action: nil, keyEquivalent: "")
        insert.submenu = addPagesMenu(atGap: (pages.last ?? currentPageIndex) + 1, menuTitles: true)
        insert.isEnabled = canChange
        menu.addItem(insert)
        add(ViewerStrings.PageMenu.duplicate, enabled: canChange) { [weak self] in self?.pageActions.duplicate(pages) }
        menu.addItem(.separator())
        add(ViewerStrings.PageMenu.blackOut(count)) { [weak self] in
            guard let self else { return }
            Services.tools?.openPanel(.blackOut, for: self.handle, inputs: [])
        }
        add(ViewerStrings.PageMenu.makeSmaller) { [weak self] in
            guard let self else { return }
            Services.tools?.openPanel(.makeSmaller, for: self.handle, inputs: [])
        }
        add(ViewerStrings.PageMenu.share(count)) { [weak self] in self?.sharePages(pages) }
        return menu
    }

    /// From file… · Blank page · From scanner… · From iPhone… (ux §2.1 sidebar [+], organiser tile, Insert Page ▸).
    func addPagesMenu(atGap gap: Int, menuTitles: Bool = false) -> NSMenu {
        let menu = NSMenu()
        let titles = menuTitles
            ? [ViewerStrings.AddPages.menuBlankPage, ViewerStrings.AddPages.menuFromFile, ViewerStrings.AddPages.menuFromScanner, ViewerStrings.AddPages.menuFromIPhone]
            : [ViewerStrings.AddPages.blankPage, ViewerStrings.AddPages.fromFile, ViewerStrings.AddPages.fromScanner, ViewerStrings.AddPages.fromIPhone]
        let actions: [() -> Void] = [
            { [weak self] in self?.pageActions.insertBlank(after: gap - 1) },
            { [weak self] in self?.addPagesFromFile(atGap: gap) },
            { [weak self] in guard let self else { return }; Services.tools?.openPanel(.scanWithScanner, for: self.handle, inputs: []) },
            { [weak self] in guard let self else { return }; Services.tools?.openPanel(.scanWithIPhone, for: self.handle, inputs: []) },
        ]
        // Preview's Insert submenu leads with the blank page; the [+] menu leads with From file… (ux §2.1).
        let order = menuTitles ? [0, 1, 2, 3] : [1, 0, 2, 3]
        for index in order {
            let item = NSMenuItem(title: titles[index], action: #selector(MenuAction.run(_:)), keyEquivalent: "")
            let action = MenuAction(actions[index])
            item.representedObject = action
            item.target = action
            menu.addItem(item)
        }
        return menu
    }

    func showAddPagesMenu(at gap: Int, from view: NSView) {
        addPagesMenu(atGap: gap).popUp(positioning: nil, at: NSPoint(x: 0, y: view.bounds.height + 4), in: view)
    }

    func addPagesFromFile(atGap gap: Int) {
        Task {
            let urls = await environment.chooseFiles([], true, window)
            if !urls.isEmpty { pageActions.insertFiles(urls, atGap: gap, tagged: organiser != nil) }
        }
    }

    private func sharePages(_ pages: [Int]) {
        guard let data = pageActions.extract(pages) else { return }
        let folder = SuperPDFPaths.ensure(SuperPDFPaths.work.appendingPathComponent(UUID().uuidString, isDirectory: true))
        let file = folder.appendingPathComponent(pageActions.extractName(pages))
        guard (try? data.write(to: file)) != nil else { return }
        let anchor = organiser?.grid.collectionView ?? sidebar.thumbnails.collectionView
        environment.share([file], anchor)
    }

    // MARK: Go to Page… (⌥⌘G)

    private func askPageNumber() {
        guard let window else { return }
        let alert = NSAlert()
        alert.messageText = ViewerStrings.GoToPage.title
        alert.informativeText = ViewerStrings.GoToPage.message(handle.pageCount)
        let field = NSTextField(frame: NSRect(x: 0, y: 0, width: 120, height: 24))
        alert.accessoryView = field
        alert.addButton(withTitle: ViewerStrings.GoToPage.go)
        alert.addButton(withTitle: Strings.Panel.cancel)
        alert.window.initialFirstResponder = field
        alert.beginSheetModal(for: window) { [weak self] response in
            MainActor.assumeIsolated {
                guard let self, response == .alertFirstButtonReturn else { return }
                if let index = self.pageIndex(forTyped: field.stringValue) { self.go(toPage: index) }
            }
        }
    }

    /// A page number or a page label ("iv").
    func pageIndex(forTyped text: String) -> Int? {
        let typed = text.trimmingCharacters(in: .whitespaces)
        if let number = Int(typed), (1...handle.pageCount).contains(number) { return number - 1 }
        return (0..<handle.pageCount).first { handle.pdf.page(at: $0)?.label?.caseInsensitiveCompare(typed) == .orderedSame }
    }

    // MARK: Use Dark Appearance for PDF (the page inverted softly, hues kept)

    func setDarkPDF(_ on: Bool) {
        darkPDF = on
        guard let view = pdfView.documentView else { return }
        view.wantsLayer = true
        view.layerUsesCoreImageFilters = true
        if on, let invert = CIFilter(name: "CIColorInvert"), let hue = CIFilter(name: "CIHueAdjust") {
            hue.setValue(Double.pi, forKey: kCIInputAngleKey)
            view.contentFilters = [invert, hue]
        } else {
            view.contentFilters = []
        }
    }

    // MARK: Reader (features #2): toolbar and sidebar away, one page at a time, full screen; Esc leaves

    struct ReaderState {
        var sidebarCollapsed: Bool
        var displayMode: DisplayMode
        var fitsPage: Bool
        var scale: CGFloat
    }

    func toggleReader() {
        if let reader {
            self.reader = nil
            window?.toolbar?.isVisible = true
            sidebarItem.isCollapsed = reader.sidebarCollapsed
            setDisplayMode(reader.displayMode)
            fitsPage = reader.fitsPage
            if !reader.fitsPage { pdfView.scaleFactor = reader.scale }
            if window?.styleMask.contains(.fullScreen) == true { window?.toggleFullScreen(nil) }
            return
        }
        reader = ReaderState(sidebarCollapsed: sidebarItem.isCollapsed, displayMode: displayMode, fitsPage: fitsPage,
                             scale: pdfView.scaleFactor)
        window?.toolbar?.isVisible = false
        sidebarItem.isCollapsed = true
        setDisplayMode(.singlePage)
        fitsPage = true
        if window?.styleMask.contains(.fullScreen) == false, window?.isVisible == true { window?.toggleFullScreen(nil) }
    }

    override public func cancelOperation(_ sender: Any?) {
        if reader != nil { toggleReader() } else if organiser != nil { hideOrganiser() }
    }
}

/// A menu item's closure.
final class MenuAction: NSObject {
    private let action: () -> Void
    init(_ action: @escaping () -> Void) { self.action = action }
    @objc func run(_ sender: Any?) { action() }
}

/// The toolbar's View popup: the first part of the View menu, Preview's (ux §2.1).
@MainActor
enum ViewMenuBuilder {
    static func menu(for owner: DocumentWindowController) -> NSMenu {
        let menu = NSMenu()
        let entries = MenuTree.main.first { $0.title == "View" }?.entries ?? []
        for entry in entries {
            guard case .item(let title, let command, let shortcut) = entry else { break }
            let item = NSMenuItem(title: title, action: #selector(DocumentWindowController.performMenuCommand(_:)), keyEquivalent: shortcut?.key ?? "")
            item.keyEquivalentModifierMask = shortcut?.modifiers.flags ?? []
            item.identifier = NSUserInterfaceItemIdentifier(command.rawValue)
            item.target = owner
            menu.addItem(item)
        }
        return menu
    }
}
