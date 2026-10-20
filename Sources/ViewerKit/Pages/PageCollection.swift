import AppKit
import PDFKit
import SuperPDFCore
import UniformTypeIdentifiers

extension NSPasteboard.PasteboardType {
    /// Thumbnails dragged out of a document window: `["document": UUID string, "pages": [Int]]`.
    static let superPDFPages = NSPasteboard.PasteboardType("com.udsy.superpdf.pages")
}

/// The flow layout of the thumbnail column and the organiser grid, with the drop gap between pages: a horizontal line
/// in the sidebar, a vertical one in the grid (ux §2.1 organiser insertion line, §3).
final class PageFlowLayout: NSCollectionViewFlowLayout {
    /// One page per row (the sidebar) or a grid (the organiser).
    var isList = true

    override func layoutAttributesForDropTarget(at pointInCollectionView: NSPoint) -> NSCollectionViewLayoutAttributes? {
        guard let collectionView, collectionView.numberOfSections > 0 else { return nil }
        let count = collectionView.numberOfItems(inSection: 0)
        guard count > 0 else {
            return gapAttributes(before: IndexPath(item: 0, section: 0))
        }
        let frames = (0..<count).compactMap { layoutAttributesForItem(at: IndexPath(item: $0, section: 0))?.frame }
        guard frames.count == count else { return nil }
        let gap = Self.gap(at: pointInCollectionView, frames: frames, isList: isList)
        return gapAttributes(before: IndexPath(item: gap, section: 0))
    }

    /// The gap (0…count) nearest `point`: by height in a list; in a grid, the row under the point, then the item whose
    /// middle is right of it.
    static func gap(at point: NSPoint, frames: [NSRect], isList: Bool) -> Int {
        guard !frames.isEmpty else { return 0 }
        if isList {
            return frames.firstIndex { point.y < $0.midY } ?? frames.count
        }
        let rowTop = frames.map(\.minY).filter { $0 <= point.y }.max() ?? frames[0].minY
        let row = frames.indices.filter { abs(frames[$0].minY - rowTop) < 1 }
        return row.first { point.x < frames[$0].midX } ?? ((row.last ?? frames.count - 1) + 1)
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
        let width = SPMetrics.Organiser.insertionLine + 8
        if isList {
            let y = switch (before, after) {
            case let (b?, a?): (b.maxY + a.minY) / 2
            case let (b?, nil): b.maxY + minimumLineSpacing / 2
            case let (nil, a?): a.minY - minimumLineSpacing / 2
            default: sectionInset.top
            }
            attributes.frame = NSRect(x: sectionInset.left, y: y - width / 2, width: collectionView.bounds.width - sectionInset.left - sectionInset.right,
                                      height: width)
        } else {
            // Between two pages of a row; after the last page of a row (the gap's other side starts the next row).
            let reference = before ?? after ?? NSRect(x: sectionInset.left, y: sectionInset.top, width: itemSize.width, height: itemSize.height)
            let x: CGFloat = if let before, let after, abs(before.minY - after.minY) < 1 { (before.maxX + after.minX) / 2 }
                else if before != nil { reference.maxX + minimumInteritemSpacing / 2 }
                else { reference.minX - minimumInteritemSpacing / 2 }
            let pageHeight = reference.height - ThumbnailStyle.labelHeight - ThumbnailStyle.organiser.labelGap
            attributes.frame = NSRect(x: x - width / 2, y: reference.minY, width: width, height: pageHeight)
        }
        attributes.zIndex = 10
        return attributes
    }
}

/// The 3 pt accent insertion line with a dot at each end (organizer.png).
final class GapIndicatorView: NSView, NSCollectionViewElement {
    override var isFlipped: Bool { true }

    override func draw(_ dirtyRect: NSRect) {
        let accent = SPColor.accent.color
        let line = SPMetrics.Organiser.insertionLine
        let dot: CGFloat = 8
        let horizontal = bounds.width > bounds.height
        accent.setFill()
        if horizontal {
            NSBezierPath(roundedRect: NSRect(x: dot / 2, y: bounds.midY - line / 2, width: bounds.width - dot, height: line), xRadius: 1.5, yRadius: 1.5).fill()
            NSBezierPath(ovalIn: NSRect(x: 0, y: bounds.midY - dot / 2, width: dot, height: dot)).fill()
            NSBezierPath(ovalIn: NSRect(x: bounds.maxX - dot, y: bounds.midY - dot / 2, width: dot, height: dot)).fill()
        } else {
            NSBezierPath(roundedRect: NSRect(x: bounds.midX - line / 2, y: dot / 2, width: line, height: bounds.height - dot), xRadius: 1.5, yRadius: 1.5).fill()
            NSBezierPath(ovalIn: NSRect(x: bounds.midX - dot / 2, y: 0, width: dot, height: dot)).fill()
            NSBezierPath(ovalIn: NSRect(x: bounds.midX - dot / 2, y: bounds.maxY - dot, width: dot, height: dot)).fill()
        }
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

    /// Items that are pages (the organiser adds an "Add pages" tile after them).
    var pageCount = 0
}

/// One page cell: the thumbnail view, the render request it is waiting on, and in the organiser the ⟲ ⟳ ✕ that
/// hovering reveals (ux §6.2).
final class PageItem: NSCollectionViewItem {
    static let identifier = NSUserInterfaceItemIdentifier("PageItem")

    let thumbnail = PageThumbnailView()
    var request: ThumbnailRequest?
    /// The page this cell shows, so a late render for a reused cell is ignored.
    weak var page: PDFPage?
    var hoverActions: HoverActionsView?

    override func loadView() { view = thumbnail }

    override var isSelected: Bool { didSet { thumbnail.isSelected = isSelected } }

    override func prepareForReuse() {
        super.prepareForReuse()
        request?.cancel()
        request = nil
        page = nil
        thumbnail.image = nil
        thumbnail.isGhosted = false
        thumbnail.originColor = nil
        hoverActions?.isHidden = true
    }

    /// Adds the hover actions (organiser only).
    func enableHoverActions(rotateLeft: @escaping () -> Void, rotateRight: @escaping () -> Void, delete: @escaping () -> Void) {
        guard hoverActions == nil else { return }
        let actions = HoverActionsView(rotateLeft: rotateLeft, rotateRight: rotateRight, delete: delete)
        actions.isHidden = true
        thumbnail.addSubview(actions)
        hoverActions = actions
        thumbnail.addTrackingArea(NSTrackingArea(rect: .zero, options: [.mouseEnteredAndExited, .activeInKeyWindow, .inVisibleRect],
                                                 owner: self, userInfo: nil))
    }

    override func viewDidLayout() {
        super.viewDidLayout()
        guard let hoverActions else { return }
        let size = hoverActions.fittingSize
        let page = thumbnail.pageRect
        hoverActions.frame = NSRect(x: (page.midX - size.width / 2).rounded(), y: page.maxY - size.height - 8, width: size.width, height: size.height)
    }

    override func mouseEntered(with event: NSEvent) { hoverActions?.isHidden = false; viewDidLayout() }
    override func mouseExited(with event: NSEvent) { hoverActions?.isHidden = true }
}

/// ⟲ ⟳ ✕ in a small white pill under the hovered page (organizer.png).
final class HoverActionsView: NSView {
    private let actions: [() -> Void]

    init(rotateLeft: @escaping () -> Void, rotateRight: @escaping () -> Void, delete: @escaping () -> Void) {
        actions = [rotateLeft, rotateRight, delete]
        super.init(frame: .zero)
        let stack = NSStackView()
        stack.spacing = 4
        stack.edgeInsets = NSEdgeInsets(top: 3, left: 3, bottom: 3, right: 3)
        let items: [(String, String)] = [("rotate.left", ViewerStrings.PageMenu.rotateLeft), ("rotate.right", ViewerStrings.PageMenu.rotateRight),
                                         ("xmark", ViewerStrings.PageMenu.delete(1))]
        for (index, (symbol, title)) in items.enumerated() {
            let button = NSButton(image: NSImage(systemSymbolName: symbol, accessibilityDescription: title)!, target: self, action: #selector(press(_:)))
            button.isBordered = false
            button.tag = index
            button.toolTip = title
            button.symbolConfiguration = .init(pointSize: 13, weight: .semibold)
            button.contentTintColor = SPColor.label.color
            button.widthAnchor.constraint(equalToConstant: 24).isActive = true
            button.heightAnchor.constraint(equalToConstant: 24).isActive = true
            stack.addArrangedSubview(button)
        }
        stack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(stack)
        NSLayoutConstraint.activate([stack.leadingAnchor.constraint(equalTo: leadingAnchor), stack.trailingAnchor.constraint(equalTo: trailingAnchor),
                                     stack.topAnchor.constraint(equalTo: topAnchor), stack.bottomAnchor.constraint(equalTo: bottomAnchor)])
    }

    required init?(coder: NSCoder) { fatalError("not used") }

    @objc private func press(_ sender: NSButton) { actions[sender.tag]() }

    override func draw(_ dirtyRect: NSRect) {
        NSGraphicsContext.saveGraphicsState()
        let shadow = NSShadow()
        shadow.shadowColor = NSColor.black.withAlphaComponent(0.2)
        shadow.shadowBlurRadius = 8
        shadow.shadowOffset = NSSize(width: 0, height: -2)
        shadow.set()
        NSColor.white.withAlphaComponent(0.95).setFill()
        NSBezierPath(roundedRect: bounds.insetBy(dx: 1, dy: 1), xRadius: 8, yRadius: 8).fill()
        NSGraphicsContext.restoreGraphicsState()
    }
}

/// The dashed "+ Add pages" tile at the end of the organiser grid: a click opens the add menu, and it takes drops.
final class AddPagesItem: NSCollectionViewItem {
    static let identifier = NSUserInterfaceItemIdentifier("AddPagesItem")
    var onClick: ((NSView) -> Void)?

    override func loadView() { view = AddPagesTileView() }

    override func mouseDown(with event: NSEvent) { onClick?(view) }
}

final class AddPagesTileView: NSView {
    override var isFlipped: Bool { true }

    override func draw(_ dirtyRect: NSRect) {
        let style = ThumbnailStyle.organiser
        let margin = style.ringMargin
        let tile = NSRect(x: margin, y: margin, width: bounds.width - 2 * margin,
                          height: bounds.height - margin - style.labelGap - ThumbnailStyle.labelHeight)
        let path = NSBezierPath(roundedRect: tile.insetBy(dx: 1, dy: 1), xRadius: style.pageRadius, yRadius: style.pageRadius)
        path.lineWidth = 2
        path.setLineDash([6, 4], count: 2, phase: 0)
        NSColor.black.withAlphaComponent(0.16).setStroke()
        if effectiveAppearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua { NSColor.white.withAlphaComponent(0.18).setStroke() }
        path.stroke()
        let secondary = SPColor.secondaryLabel.color
        let symbol = NSImage(systemSymbolName: "plus", accessibilityDescription: nil)?
            .withSymbolConfiguration(.init(pointSize: 22, weight: .regular).applying(.init(paletteColors: [secondary])))
        let text = NSAttributedString(string: ViewerStrings.AddPages.addPages, attributes: [.font: SPFont.body.font(), .foregroundColor: secondary])
        let textSize = text.size()
        let symbolSize = symbol?.size ?? .zero
        let total = symbolSize.height + 6 + textSize.height
        let top = tile.midY - total / 2
        symbol?.draw(in: NSRect(x: tile.midX - symbolSize.width / 2, y: top, width: symbolSize.width, height: symbolSize.height))
        text.draw(at: NSPoint(x: tile.midX - textSize.width / 2, y: top + symbolSize.height + 6))
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
