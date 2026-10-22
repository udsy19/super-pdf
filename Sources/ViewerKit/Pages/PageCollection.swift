import AppKit
import PDFKit
import SuperPDFCore
import UniformTypeIdentifiers

extension NSPasteboard.PasteboardType {
    /// Thumbnails dragged out of a document window: `["document": UUID string, "pages": [Int]]`.
    static let superPDFPages = NSPasteboard.PasteboardType("com.udsy.superpdf.pages")
}

/// The flow layout of the thumbnail column, with the drop gap between pages: a horizontal accent line (ux §3).
final class PageFlowLayout: NSCollectionViewFlowLayout {
    override func layoutAttributesForDropTarget(at pointInCollectionView: NSPoint) -> NSCollectionViewLayoutAttributes? {
        guard let collectionView, collectionView.numberOfSections > 0 else { return nil }
        let count = collectionView.numberOfItems(inSection: 0)
        guard count > 0 else {
            return gapAttributes(before: IndexPath(item: 0, section: 0))
        }
        let frames = (0..<count).compactMap { layoutAttributesForItem(at: IndexPath(item: $0, section: 0))?.frame }
        guard frames.count == count else { return nil }
        // The gap (0…count) nearest the point, by height.
        let gap = frames.firstIndex { pointInCollectionView.y < $0.midY } ?? frames.count
        return gapAttributes(before: IndexPath(item: gap, section: 0))
    }

    override func layoutAttributesForInterItemGap(before indexPath: IndexPath) -> NSCollectionViewLayoutAttributes? {
        gapAttributes(before: indexPath)
    }

    private func gapAttributes(before indexPath: IndexPath) -> NSCollectionViewLayoutAttributes? {
        guard let collectionView else { return nil }
        let attributes = NSCollectionViewLayoutAttributes(forInterItemGapBefore: indexPath)
        let count = collectionView.numberOfSections > 0 ? collectionView.numberOfItems(inSection: 0) : 0
        let item = indexPath.item
        let after = item < count ? layoutAttributesForItem(at: indexPath)?.frame : nil
        let before = item > 0 ? layoutAttributesForItem(at: IndexPath(item: item - 1, section: 0))?.frame : nil
        let width = SPMetrics.DropTarget.insertionLine + 8
        let y = switch (before, after) {
        case let (b?, a?): (b.maxY + a.minY) / 2
        case let (b?, nil): b.maxY + minimumLineSpacing / 2
        case let (nil, a?): a.minY - minimumLineSpacing / 2
        default: sectionInset.top
        }
        attributes.frame = NSRect(x: sectionInset.left, y: y - width / 2, width: collectionView.bounds.width - sectionInset.left - sectionInset.right,
                                  height: width)
        attributes.zIndex = 10
        return attributes
    }
}

/// The 3 pt accent insertion line with a dot at each end.
final class GapIndicatorView: NSView, NSCollectionViewElement {
    override var isFlipped: Bool { true }

    override func draw(_ dirtyRect: NSRect) {
        let line = SPMetrics.DropTarget.insertionLine
        let dot: CGFloat = 8
        SPColor.accent.color.setFill()
        NSBezierPath(roundedRect: NSRect(x: dot / 2, y: bounds.midY - line / 2, width: bounds.width - dot, height: line), xRadius: 1.5, yRadius: 1.5).fill()
        NSBezierPath(ovalIn: NSRect(x: 0, y: bounds.midY - dot / 2, width: dot, height: dot)).fill()
        NSBezierPath(ovalIn: NSRect(x: bounds.maxX - dot, y: bounds.midY - dot / 2, width: dot, height: dot)).fill()
    }
}

/// The words a drop target shows next to the insertion line ("Add 3 pages here"), or why a drop can't work.
final class DropLabelView: NSView {
    var text = "" { didSet { needsDisplay = true; invalidateIntrinsicContentSize() } }
    var isRefusal = false { didSet { needsDisplay = true } }

    private var attributed: NSAttributedString {
        NSAttributedString(string: text, attributes: [.font: SPFont.bannerEmphasis.font(),
                                                      .foregroundColor: isRefusal ? SPColor.label.color : NSColor.white])
    }

    override var intrinsicContentSize: NSSize {
        let size = attributed.size()
        return NSSize(width: ceil(size.width) + 24, height: 28)
    }

    override func draw(_ dirtyRect: NSRect) {
        let path = NSBezierPath(roundedRect: bounds.insetBy(dx: 0.5, dy: 0.5), xRadius: 9, yRadius: 9)
        (isRefusal ? SPColor.controlBackground.color : SPColor.accent.color).setFill()
        path.fill()
        if isRefusal { SPColor.separator.color.setStroke(); path.stroke() }
        let size = attributed.size()
        attributed.draw(at: NSPoint(x: (bounds.width - size.width) / 2, y: (bounds.height - size.height) / 2))
    }
}

/// The collection view of pages: ⌫ deletes the selection, right-click opens the page menu for what is under the pointer.
final class PageCollectionView: NSCollectionView {
    var onDelete: (() -> Void)?
    var menuForSelection: ((IndexSet) -> NSMenu?)?
    var onDragExit: (() -> Void)?

    override func draggingExited(_ sender: NSDraggingInfo?) {
        super.draggingExited(sender)
        onDragExit?()
    }

    override func keyDown(with event: NSEvent) {
        if let key = event.charactersIgnoringModifiers?.unicodeScalars.first?.value,
           key == UInt32(NSDeleteCharacter) || key == UInt32(NSDeleteFunctionKey) {
            onDelete?()
            return
        }
        super.keyDown(with: event)
    }

    override func menu(for event: NSEvent) -> NSMenu? {
        let point = convert(event.locationInWindow, from: nil)
        guard let indexPath = indexPathForItem(at: point), indexPath.item < pageCount else { return nil }
        if !selectionIndexPaths.contains(indexPath) {
            selectionIndexPaths = [indexPath]
            delegate?.collectionView?(self, didSelectItemsAt: [indexPath])
        }
        return menuForSelection?(IndexSet(selectionIndexPaths.map(\.item)))
    }

    /// The pages it shows (a right-click past the last page has none).
    var pageCount = 0
}

/// One page cell: the thumbnail view and the render request it is waiting on.
final class PageItem: NSCollectionViewItem {
    static let identifier = NSUserInterfaceItemIdentifier("PageItem")

    let thumbnail = PageThumbnailView()
    var request: ThumbnailRequest?
    /// The page this cell shows, so a late render for a reused cell is ignored.
    weak var page: PDFPage?
    /// What the page's annotations looked like when its image was asked for (`ThumbnailRenderer.markupSignature`).
    var markup = 0

    override func loadView() { view = thumbnail }

    override var isSelected: Bool { didSet { thumbnail.isSelected = isSelected } }

    override func prepareForReuse() {
        super.prepareForReuse()
        request?.cancel()
        request = nil
        page = nil
        thumbnail.image = nil
    }
}

/// The first dragged thumbnail promises Finder a PDF of every dragged page ("Report – pages 3-5.pdf", ux §3) and
/// carries the pages for drops inside Super PDF.
final class PagesPromiseProvider: NSFilePromiseProvider {
    var pagesPlist: [String: Any] = [:]

    override func writableTypes(for pasteboard: NSPasteboard) -> [NSPasteboard.PasteboardType] {
        super.writableTypes(for: pasteboard) + [.superPDFPages]
    }

    override func pasteboardPropertyList(forType type: NSPasteboard.PasteboardType) -> Any? {
        type == .superPDFPages ? pagesPlist : super.pasteboardPropertyList(forType: type)
    }

    static func plist(document: UUID, pages: [Int]) -> [String: Any] { ["document": document.uuidString, "pages": pages] }

    static func read(_ pasteboard: NSPasteboard) -> (document: UUID, pages: [Int])? {
        guard let plist = pasteboard.pasteboardItems?.lazy.compactMap({ $0.propertyList(forType: .superPDFPages) as? [String: Any] }).first,
              let id = (plist["document"] as? String).flatMap(UUID.init(uuidString:)), let pages = plist["pages"] as? [Int] else { return nil }
        return (id, pages)
    }
}
