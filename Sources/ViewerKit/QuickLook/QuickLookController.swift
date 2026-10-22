import AppKit
import QuickLookUI
import SuperPDFCore

/// One thing the Quick Look panel can show. The file is made only when the panel asks for it (a page or a merged file is
/// written to a temporary PDF then), and removed again when the panel lets go of the item.
final class QuickLookItem: NSObject, QLPreviewItem {
    let key: AnyHashable
    let title: String
    private let makeURL: @MainActor () -> URL?
    private let sourceFrame: @MainActor () -> NSRect?
    private let transition: @MainActor () -> NSImage?
    private let isTemporary: Bool
    private var made: URL?

    /// - Parameters:
    ///   - makeURL: the file to show; for a temporary one, a file inside a folder made just for it (`QuickLookFiles`).
    ///   - sourceFrame: where the item sits on screen, for the zoom in and out; nil when it is not visible.
    ///   - transition: a picture of the item as it sits now, for the same zoom.
    init(key: AnyHashable, title: String, isTemporary: Bool, makeURL: @escaping @MainActor () -> URL?,
         sourceFrame: @escaping @MainActor () -> NSRect? = { nil }, transition: @escaping @MainActor () -> NSImage? = { nil }) {
        self.key = key; self.title = title; self.isTemporary = isTemporary
        self.makeURL = makeURL; self.sourceFrame = sourceFrame; self.transition = transition
    }

    nonisolated var previewItemURL: URL! {
        MainActor.assumeIsolated {
            if made == nil { made = makeURL() }
            return made
        }
    }

    nonisolated var previewItemTitle: String! { title }

    @MainActor var screenFrame: NSRect? { sourceFrame() }
    @MainActor var transitionImage: NSImage? { transition() }

    /// Removes the temporary file this item made, and the folder made for it.
    @MainActor func discard() {
        guard isTemporary, let made else { return }
        try? FileManager.default.removeItem(at: made)
        try? FileManager.default.removeItem(at: made.deletingLastPathComponent())
        self.made = nil
    }
}

/// What a list tells the controller when the panel opens or the list changes.
struct QuickLookSelection {
    var items: [QuickLookItem]
    /// The item to show first.
    var current: Int
    /// Several things were selected: the panel shows just those. Otherwise it shows the whole list, starting at the
    /// selected one, and moving through it moves the selection too (Space on one thing, then ↑ ↓ ← →).
    var showsSelectedOnly: Bool
}

@MainActor
protocol QuickLookSource: AnyObject {
    func quickLookSelection() -> QuickLookSelection
    /// The panel moved to `item` (only asked when `showsSelectedOnly` is false): select it in the list.
    func quickLookSelect(_ item: QuickLookItem)
}

/// The system's panel, as far as the controller needs it, so that the self-test can use a fake and never opens one.
@MainActor
protocol PreviewPanelHosting: AnyObject {
    var isVisible: Bool { get }
    func show()
    func hide()
    func reload()
    var currentIndex: Int { get set }
}

@MainActor
final class SystemPreviewPanel: PreviewPanelHosting {
    private var panel: QLPreviewPanel? { QLPreviewPanel.shared() }
    var isVisible: Bool { QLPreviewPanel.sharedPreviewPanelExists() && (panel?.isVisible ?? false) }
    func show() { panel?.makeKeyAndOrderFront(nil) }
    func hide() { panel?.orderOut(nil) }
    func reload() { panel?.reloadData() }
    var currentIndex: Int {
        get { panel?.currentPreviewItemIndex ?? 0 }
        set { panel?.currentPreviewItemIndex = newValue }
    }
}

/// The macOS Quick Look panel for a list of things (the workspace's cards, the sidebar's thumbnails, the welcome window's
/// recent files): Space toggles it, the panel's own arrows and thumbnail strip move through the list, the list's selection
/// follows, and it zooms out of and back into the item. A view that holds a controller answers the three
/// `QLPreviewPanelController` calls (accepts, begin, end) by forwarding them here.
@MainActor
final class QuickLookController: NSObject, @preconcurrency QLPreviewPanelDataSource, @preconcurrency QLPreviewPanelDelegate {
    private weak var source: QuickLookSource?
    private let host: PreviewPanelHosting
    private(set) var items: [QuickLookItem] = []
    private var showsSelectedOnly = false
    private var observation: NSKeyValueObservation?

    init(source: QuickLookSource, host: PreviewPanelHosting? = nil) {
        self.source = source
        self.host = host ?? SystemPreviewPanel()
    }

    var isOpen: Bool { host.isVisible }

    /// Space: opens the panel on the selection, or closes it.
    func toggle() {
        if host.isVisible { host.hide(); return }
        refresh()
        guard !items.isEmpty else { NSSound.beep(); return }
        host.show()
    }

    /// The list changed under an open panel (a rotation, a deletion, a move): show it as it is now.
    func reloadIfOpen() {
        guard host.isVisible else { return }
        let start = refresh()
        host.reload()
        host.currentIndex = start
    }

    @discardableResult
    private func refresh() -> Int {
        items.forEach { $0.discard() }
        guard let selection = source?.quickLookSelection() else { items = []; return 0 }
        items = selection.items
        showsSelectedOnly = selection.showsSelectedOnly
        return min(max(selection.current, 0), max(items.count - 1, 0))
    }

    // MARK: The panel asks (via the responder chain)

    func begin(_ panel: QLPreviewPanel) {
        let start = refresh()
        panel.dataSource = self
        panel.delegate = self
        panel.reloadData()
        panel.currentPreviewItemIndex = start
        observation = panel.observe(\.currentPreviewItemIndex) { [weak self] panel, _ in
            let index = panel.currentPreviewItemIndex
            MainActor.assumeIsolated { self?.panelMoved(to: index) }
        }
    }

    func end(_ panel: QLPreviewPanel) {
        observation = nil
        if panel.dataSource === self { panel.dataSource = nil }
        if panel.delegate === self { panel.delegate = nil }
        items.forEach { $0.discard() }
        items = []
    }

    /// The panel moved to another item: the list's selection follows.
    func panelMoved(to index: Int) {
        guard !showsSelectedOnly, items.indices.contains(index) else { return }
        source?.quickLookSelect(items[index])
    }

    // MARK: QLPreviewPanelDataSource

    func numberOfPreviewItems(in panel: QLPreviewPanel!) -> Int { items.count }

    func previewPanel(_ panel: QLPreviewPanel!, previewItemAt index: Int) -> QLPreviewItem! {
        items.indices.contains(index) ? items[index] : nil
    }

    // MARK: QLPreviewPanelDelegate

    func previewPanel(_ panel: QLPreviewPanel!, sourceFrameOnScreenFor item: QLPreviewItem!) -> NSRect {
        (item as? QuickLookItem)?.screenFrame ?? .zero
    }

    func previewPanel(_ panel: QLPreviewPanel!, transitionImageFor item: QLPreviewItem!, contentRect: UnsafeMutablePointer<NSRect>!) -> Any! {
        (item as? QuickLookItem)?.transitionImage
    }
}

/// Where temporary previews are written: a folder of its own per file, so two pages of the same name never meet.
enum QuickLookFiles {
    static func write(_ data: Data, named name: String) -> URL? {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("com.udsy.superpdf.quicklook-\(UUID().uuidString)", isDirectory: true)
        let url = folder.appendingPathComponent(name)
        do {
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            try data.write(to: url)
            return url
        } catch {
            try? FileManager.default.removeItem(at: folder)
            return nil
        }
    }

    /// "Lease agreement.docx" → "Lease agreement.pdf"
    static func pdfName(_ fileName: String) -> String {
        (fileName as NSString).deletingPathExtension + ".pdf"
    }
}

extension NSView {
    /// `rect` (in this view) on the screen.
    func screenFrame(of rect: NSRect) -> NSRect? {
        guard let window, window.isVisible else { return nil }
        return window.convertToScreen(convert(rect, to: nil))
    }

    /// A picture of `rect` as it is drawn now.
    func snapshot(of rect: NSRect) -> NSImage? {
        guard let rep = bitmapImageRepForCachingDisplay(in: rect) else { return nil }
        cacheDisplay(in: rect, to: rep)
        let image = NSImage(size: rect.size)
        image.addRepresentation(rep)
        return image
    }
}
