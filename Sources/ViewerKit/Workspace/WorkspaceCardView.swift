import AppKit
import PDFKit
import SuperPDFCore

/// What a card needs from the workspace: the page pictures, the hover toolbar's actions and what a press does (a screen
/// reader's press: select or deselect a card, add files on the add card).
@MainActor
protocol WorkspaceCardHost: AnyObject {
    func page(at index: Int) -> PDFPage?
    func perform(_ action: WorkspaceCardAction, on card: WorkspaceCardView)
    func press(_ card: WorkspaceCardView)
}

/// The hover toolbar's buttons (ux §6.2), in their order; also each card's accessibility actions.
enum WorkspaceCardAction: CaseIterable {
    case preview, rotate, duplicate, delete

    var symbol: String {
        switch self {
        case .preview: "plus.magnifyingglass"
        case .rotate: "rotate.right"
        case .duplicate: "plus.square.on.square"
        case .delete: "trash"
        }
    }

    var title: String {
        switch self {
        case .preview: ViewerStrings.Workspace.preview
        case .rotate: ViewerStrings.Workspace.rotate
        case .duplicate: ViewerStrings.Workspace.duplicate
        case .delete: ViewerStrings.Workspace.delete
        }
    }
}

/// One card of the workspace (ux §6.2, workspace.png): a white rounded card on the canvas with the file's page stack (or
/// the page), a round checkbox at the top left, the file's name in its coloured pill and "12 pages" (or "Page 3").
/// Hovering grows it a little on a spring and shows the toolbar: Preview, Rotate, Duplicate, Delete. A converting file
/// shows a spinner and its progress; the add card is dashed, with the formats it takes. The card draws itself (no
/// per-frame work while scrolling) in a frame `outset` bigger than the card, so its shadow has room.
@MainActor
final class WorkspaceCardView: NSView {
    static let outset: CGFloat = 16

    weak var host: WorkspaceCardHost?
    private(set) var item: WorkspaceItem = .add
    private(set) var layoutKind: WorkspaceLayout = .grid
    private(set) var mode: WorkspaceMode = .files
    var isSelected = false { didSet { if isSelected != oldValue { needsDisplay = true; updateAccessibility() } } }
    var isHovered = false { didSet { if isHovered != oldValue { hoverChanged() } } }
    /// Files are being dragged over the add card.
    var isDropTarget = false { didSet { if isDropTarget != oldValue { needsDisplay = true } } }

    private var image: CGImage?
    private var aspect: CGFloat = 11 / 8.5
    private weak var page: PDFPage?
    private var request: ThumbnailRequest?
    private var markup = 0
    private let toolbar = WorkspaceHoverBar()
    private var spinner: NSProgressIndicator?

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        layerContentsRedrawPolicy = .onSetNeedsDisplay
        toolbar.isHidden = true
        toolbar.onAction = { [weak self] action in
            guard let self else { return }
            self.host?.perform(action, on: self)
        }
        addSubview(toolbar)
        setAccessibilityElement(true)
    }

    @available(*, unavailable) required init?(coder: NSCoder) { fatalError() }

    override var isFlipped: Bool { true }

    /// The card itself inside the view.
    var cardRect: NSRect { bounds.insetBy(dx: Self.outset, dy: Self.outset) }

    // MARK: Content

    func configure(_ item: WorkspaceItem, mode: WorkspaceMode, layout: WorkspaceLayout, pixelScale: CGFloat) {
        let changed = item != self.item || mode != self.mode || layout != self.layoutKind
        self.item = item
        self.mode = mode
        self.layoutKind = layout
        if changed { needsDisplay = true; needsLayout = true }
        updateSpinner()
        updateAccessibility()
        loadThumbnail(pixelScale: pixelScale)
    }

    /// The first page's picture, at the card's size (the add and converting cards have none).
    private func loadThumbnail(pixelScale: CGFloat) {
        guard let index = item.pages.first, let page = host?.page(at: index) else {
            request?.cancel(); request = nil; image = nil; self.page = nil
            return
        }
        let box = page.bounds(for: .cropBox)
        aspect = box.width > 0 && box.height > 0 ? (page.rotation % 180 == 0 ? box.height / box.width : box.width / box.height) : 11 / 8.5
        let pixels = max(Int((pictureRect(in: thumbArea).width * pixelScale).rounded()), 16)
        let signature = ThumbnailRenderer.markupSignature(of: page)
        if self.page === page, markup == signature, let image, image.width == pixels { return }
        request?.cancel()
        self.page = page
        markup = signature
        let renderer = ThumbnailRenderer.shared
        if let cached = renderer.cachedImage(for: page, pixelWidth: pixels) {
            image = cached
            request = nil
            needsDisplay = true
            return
        }
        request = renderer.image(for: page, pixelWidth: pixels) { [weak self, weak page] image in
            guard let self, let page, self.page === page else { return }
            self.image = image
            self.needsDisplay = true
        }
    }

    override func prepareForReuse() {
        super.prepareForReuse()
        request?.cancel()
        request = nil
        page = nil
        image = nil
        isHovered = false
        isSelected = false
        isDropTarget = false
        layer?.removeAllAnimations()
    }

    private func updateSpinner() {
        guard case .pending = item else { spinner?.removeFromSuperview(); spinner = nil; return }
        if spinner == nil {
            let indicator = NSProgressIndicator()
            indicator.style = .spinning
            indicator.controlSize = layoutKind == .list ? .small : .regular
            indicator.isDisplayedWhenStopped = false
            addSubview(indicator)
            spinner = indicator
            indicator.startAnimation(nil)
        }
        needsLayout = true
    }

    // MARK: Geometry

    /// The words under a grid card's picture: the gap, the pill, the gap, the caption and the bottom margin.
    static func wordsHeight(_ mode: WorkspaceMode) -> CGFloat {
        mode == .files ? 10 + SPMetrics.Workspace.pillHeight + 6 + 14 + 10 : 8 + SPMetrics.Workspace.pagePillHeight + 4 + 13 + 9
    }

    /// A grid card's size at a scale: the picture area grows, the words keep their size (184 × 242 and 148 × 214 at 1).
    static func cardSize(_ mode: WorkspaceMode, scale: CGFloat) -> NSSize {
        let base = mode == .files ? SPMetrics.Workspace.fileCard : SPMetrics.Workspace.pageCard
        let inset = mode == .files ? SPMetrics.Workspace.fileCardInset : SPMetrics.Workspace.pageCardInset
        let picture = (base.height - inset - wordsHeight(mode)) * scale
        return NSSize(width: (base.width * scale).rounded(), height: (inset + picture + wordsHeight(mode)).rounded())
    }

    /// The middle of a grid card's picture area, from the card's top (where the "+" between cards sits).
    static func pictureMiddle(_ mode: WorkspaceMode, cardHeight: CGFloat) -> CGFloat {
        let inset = mode == .files ? SPMetrics.Workspace.fileCardInset : SPMetrics.Workspace.pageCardInset
        return inset + (cardHeight - inset - wordsHeight(mode)) / 2
    }

    private var inset: CGFloat { mode == .files ? SPMetrics.Workspace.fileCardInset : SPMetrics.Workspace.pageCardInset }
    private var pillHeight: CGFloat { mode == .files ? SPMetrics.Workspace.pillHeight : SPMetrics.Workspace.pagePillHeight }
    private var pillFont: NSFont { (mode == .files ? SPFont.pill : SPFont.pagePill).font() }

    /// Where the page (or stack) goes.
    var thumbArea: NSRect {
        let card = cardRect
        switch layoutKind {
        case .list:
            return NSRect(x: card.minX + 42, y: card.minY + 8, width: 36, height: card.height - 16)
        case .grid:
            return NSRect(x: card.minX + inset, y: card.minY + inset, width: card.width - 2 * inset,
                          height: card.height - inset - Self.wordsHeight(mode))
        }
    }

    /// The page's picture fitted (and centred) in an area, by its aspect.
    private func pictureRect(in area: NSRect) -> NSRect {
        var width = area.width, height = (area.width * aspect).rounded()
        if height > area.height { height = area.height; width = (height / aspect).rounded() }
        // A stack leaves room for the sheets behind it.
        if case .file(_, let pages) = item, pages.count > 1, layoutKind == .grid {
            width = min(width, area.width - 12); height = min(height, (width * aspect).rounded())
        }
        return NSRect(x: (area.midX - width / 2).rounded(), y: (area.midY - height / 2).rounded(), width: width, height: height)
    }

    private var checkboxRect: NSRect {
        let d = SPMetrics.Workspace.checkbox
        let card = cardRect
        return layoutKind == .list ? NSRect(x: card.minX + 12, y: card.midY - d / 2, width: d, height: d)
            : NSRect(x: card.minX + 10, y: card.minY + 10, width: d, height: d)
    }

    /// Whether a point (in this view) is on the checkbox, with a little slop.
    func isOnCheckbox(_ point: NSPoint) -> Bool { item.isContent && checkboxRect.insetBy(dx: -4, dy: -4).contains(point) }

    override func layout() {
        super.layout()
        let size = toolbar.fittingSize(compact: mode == .pages || layoutKind == .list)
        let card = cardRect, pad = WorkspaceHoverBar.padding
        toolbar.frame = (layoutKind == .list
            ? NSRect(x: card.maxX - size.width - 12, y: card.midY - size.height / 2, width: size.width, height: size.height)
            : NSRect(x: card.maxX - size.width - 10, y: card.minY + 10, width: size.width, height: size.height)).insetBy(dx: -pad, dy: -pad)
        if let spinner {
            let s: CGFloat = layoutKind == .list ? 16 : 32
            let area = pictureRect(in: thumbArea)
            spinner.frame = NSRect(x: area.midX - s / 2, y: area.midY - s / 2 - (layoutKind == .list ? 0 : 10), width: s, height: s)
        }
    }

    // MARK: Hover

    private func hoverChanged() {
        toolbar.isHidden = !(isHovered && item.isContent)
        needsDisplay = true
        guard let layer, layoutKind == .grid, item.isContent else { return }
        let reduce = NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
        let scale: CGFloat = isHovered && !reduce ? 1.02 : 1
        var transform = CATransform3DMakeTranslation(bounds.width / 2, bounds.height / 2, 0)
        transform = CATransform3DScale(transform, scale, scale, 1)
        transform = CATransform3DTranslate(transform, -bounds.width / 2, -bounds.height / 2, 0)
        let from = layer.presentation()?.transform ?? layer.transform
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        layer.transform = transform
        CATransaction.commit()
        guard !reduce else { return }
        layer.add(SPMotion.hoverSpring.animation("transform", from: NSValue(caTransform3D: from), to: NSValue(caTransform3D: transform)), forKey: "hover")
    }

    // MARK: Drawing

    override func draw(_ dirtyRect: NSRect) {
        let card = cardRect
        let radius = mode == .files || layoutKind == .list ? SPMetrics.Workspace.fileCardRadius : SPMetrics.Workspace.pageCardRadius
        if case .add = item { drawAddCard(card, radius: radius); return }
        let path = NSBezierPath(roundedRect: card, xRadius: radius, yRadius: radius)
        NSGraphicsContext.saveGraphicsState()
        let shadow = NSShadow()
        shadow.shadowColor = NSColor(srgbRed: 31 / 255, green: 64 / 255, blue: 128 / 255, alpha: isHovered ? 0.18 : 0.10)
        shadow.shadowBlurRadius = isHovered ? 18 : 9
        shadow.shadowOffset = NSSize(width: 0, height: isHovered ? -8 : -3)
        shadow.set()
        SPColor.card.color.setFill()
        path.fill()
        NSGraphicsContext.restoreGraphicsState()

        drawPicture()
        drawWords(card)
        if item.isContent { drawCheckbox() }
        if isSelected {
            let ring = NSBezierPath(roundedRect: card.insetBy(dx: -1.25, dy: -1.25), xRadius: radius + 1.25, yRadius: radius + 1.25)
            ring.lineWidth = 2.5
            SPColor.accent.color.setStroke()
            ring.stroke()
        }
    }

    private func drawPicture() {
        let picture = pictureRect(in: thumbArea)
        let pageRadius: CGFloat = layoutKind == .list ? 2 : 4
        // The sheets behind a file of several pages.
        if case .file(_, let pages) = item, pages.count > 1, layoutKind == .grid {
            let sheets: [(CGFloat, CGFloat)] = pages.count > 2 ? [(4, 6), (-3, -4)] : [(-3, -4)]
            for (degrees, dx) in sheets { drawSheet(picture.offsetBy(dx: dx, dy: 0), radius: pageRadius, rotation: degrees, image: nil) }
        }
        drawSheet(picture, radius: pageRadius, rotation: 0, image: image)
        if case .pending(let file) = item, let fraction = file.fraction, layoutKind == .grid {
            let bar = NSRect(x: picture.minX + 18, y: picture.midY + 18, width: picture.width - 36, height: 6)
            SPColor.accent.color.withAlphaComponent(0.15).setFill()
            NSBezierPath(roundedRect: bar, xRadius: 3, yRadius: 3).fill()
            SPColor.accent.color.setFill()
            NSBezierPath(roundedRect: NSRect(x: bar.minX, y: bar.minY, width: max(bar.height, bar.width * fraction), height: bar.height),
                         xRadius: 3, yRadius: 3).fill()
        }
    }

    private func drawSheet(_ rect: NSRect, radius: CGFloat, rotation: CGFloat, image: CGImage?) {
        NSGraphicsContext.saveGraphicsState()
        if rotation != 0 {
            let transform = NSAffineTransform()
            transform.translateX(by: rect.midX, yBy: rect.midY)
            transform.rotate(byDegrees: rotation)
            transform.translateX(by: -rect.midX, yBy: -rect.midY)
            transform.concat()
        }
        let path = NSBezierPath(roundedRect: rect, xRadius: radius, yRadius: radius)
        NSGraphicsContext.saveGraphicsState()
        let shadow = NSShadow()
        shadow.shadowColor = NSColor.black.withAlphaComponent(0.16)
        shadow.shadowBlurRadius = 3
        shadow.shadowOffset = NSSize(width: 0, height: -1)
        shadow.set()
        NSColor.white.setFill()
        path.fill()
        NSGraphicsContext.restoreGraphicsState()
        if let image, let context = NSGraphicsContext.current?.cgContext {
            NSGraphicsContext.saveGraphicsState()
            path.addClip()
            context.saveGState()
            context.translateBy(x: 0, y: rect.maxY + rect.minY)
            context.scaleBy(x: 1, y: -1)
            context.interpolationQuality = .high
            context.draw(image, in: rect)
            context.restoreGState()
            NSGraphicsContext.restoreGraphicsState()
        }
        NSColor.black.withAlphaComponent(0.10).setStroke()
        let edge = NSBezierPath(roundedRect: rect.insetBy(dx: 0.25, dy: 0.25), xRadius: radius, yRadius: radius)
        edge.lineWidth = 0.5
        edge.stroke()
        NSGraphicsContext.restoreGraphicsState()
    }

    private var origin: PageOrigin? {
        switch item {
        case .file(let origin, _): origin
        case .page(_, _, let file): file
        case .pending(let file): PageOrigin(fileName: file.name, colorIndex: file.colorIndex)
        case .add: nil
        }
    }

    private var caption: String {
        switch item {
        case .file(_, let pages): ViewerStrings.pages(pages.count)
        case .page(let index, _, _): ViewerStrings.Sidebar.page("\(index + 1)")
        case .pending(let file): file.fraction.map { ViewerStrings.Workspace.converting(percent: Int(($0 * 100).rounded())) }
            ?? ViewerStrings.Workspace.convertingToPDF
        case .add: ""
        }
    }

    private func drawWords(_ card: NSRect) {
        guard let origin else { return }
        let pill = origin.pill
        let paragraph = NSMutableParagraphStyle()
        paragraph.lineBreakMode = .byTruncatingMiddle
        let name = NSAttributedString(string: origin.fileName, attributes: [.font: pillFont, .foregroundColor: pill.ink.color, .paragraphStyle: paragraph])
        let captionFont = SPFont.secondary.font()
        let caption = NSAttributedString(string: self.caption, attributes: [.font: captionFont, .foregroundColor: SPColor.secondaryLabel.color,
                                                                             .paragraphStyle: paragraph])
        let padding: CGFloat = mode == .files ? 10 : 9
        switch layoutKind {
        case .grid:
            let maxWidth = card.width - 2 * (mode == .files ? 12 : 10)
            let width = min(ceil(name.size().width) + 2 * padding, maxWidth)
            let pillRect = NSRect(x: (card.midX - width / 2).rounded(), y: thumbArea.maxY + (mode == .files ? 10 : 8), width: width, height: pillHeight)
            drawPill(pillRect, fill: pill.fill.color, text: name, padding: padding)
            let captionSize = caption.size()
            let captionY = pillRect.maxY + (mode == .files ? 6 : 4)
            caption.draw(with: NSRect(x: card.minX + 8, y: captionY, width: card.width - 16, height: ceil(captionSize.height)).insetBy(dx: max(0, (card.width - 16 - captionSize.width) / 2), dy: 0),
                         options: [.usesLineFragmentOrigin, .truncatesLastVisibleLine])
        case .list:
            let x = thumbArea.maxX + 16
            let toolbarRoom: CGFloat = 130
            let maxWidth = max(card.maxX - x - toolbarRoom - 120, 60)
            let width = min(ceil(name.size().width) + 2 * padding, maxWidth)
            let pillRect = NSRect(x: x, y: (card.midY - pillHeight / 2).rounded(), width: width, height: pillHeight)
            drawPill(pillRect, fill: pill.fill.color, text: name, padding: padding)
            let captionSize = caption.size()
            caption.draw(at: NSPoint(x: pillRect.maxX + 12, y: card.midY - captionSize.height / 2))
        }
    }

    private func drawPill(_ rect: NSRect, fill: NSColor, text: NSAttributedString, padding: CGFloat) {
        fill.setFill()
        NSBezierPath(roundedRect: rect, xRadius: rect.height / 2, yRadius: rect.height / 2).fill()
        let size = text.size()
        text.draw(with: NSRect(x: rect.minX + padding, y: rect.midY - size.height / 2, width: rect.width - 2 * padding, height: ceil(size.height)),
                  options: [.usesLineFragmentOrigin, .truncatesLastVisibleLine])
    }

    private func drawCheckbox() {
        let rect = checkboxRect
        let circle = NSBezierPath(ovalIn: rect.insetBy(dx: 0.75, dy: 0.75))
        if isSelected {
            SPColor.accent.color.setFill()
            circle.fill()
            let tick = NSBezierPath()
            tick.move(to: NSPoint(x: rect.minX + rect.width * 0.28, y: rect.minY + rect.height * 0.52))
            tick.line(to: NSPoint(x: rect.minX + rect.width * 0.44, y: rect.minY + rect.height * 0.68))
            tick.line(to: NSPoint(x: rect.minX + rect.width * 0.73, y: rect.minY + rect.height * 0.34))
            tick.lineWidth = 2
            tick.lineCapStyle = .round
            tick.lineJoinStyle = .round
            NSColor.white.setStroke()
            tick.stroke()
        } else {
            NSGraphicsContext.saveGraphicsState()
            let shadow = NSShadow()
            shadow.shadowColor = NSColor.black.withAlphaComponent(0.12)
            shadow.shadowBlurRadius = 2
            shadow.shadowOffset = NSSize(width: 0, height: -1)
            shadow.set()
            NSColor.white.withAlphaComponent(0.92).setFill()
            circle.fill()
            NSGraphicsContext.restoreGraphicsState()
            circle.lineWidth = 1.5
            NSColor.black.withAlphaComponent(isHovered ? 0.35 : 0.22).setStroke()
            circle.stroke()
        }
    }

    /// The dashed card that ends the grid: a big "+", what it takes, and the formats as coloured badges.
    private func drawAddCard(_ card: NSRect, radius: CGFloat) {
        let accent = SPColor.accent.color
        let path = NSBezierPath(roundedRect: card.insetBy(dx: 1, dy: 1), xRadius: radius, yRadius: radius)
        accent.withAlphaComponent(isDropTarget ? 0.12 : isHovered ? 0.08 : 0.05).setFill()
        path.fill()
        path.lineWidth = 2
        path.setLineDash(isDropTarget ? [] : [6, 4], count: isDropTarget ? 0 : 2, phase: 0)
        accent.withAlphaComponent(isDropTarget ? 0.9 : 0.45).setStroke()
        path.stroke()
        let compact = layoutKind == .list || mode == .pages
        let d: CGFloat = compact ? 36 : 48
        let title = NSMutableParagraphStyle()
        title.alignment = layoutKind == .list ? .left : .center
        let titleText = NSAttributedString(string: ViewerStrings.Workspace.addFiles, attributes: [
            .font: NSFont.systemFont(ofSize: compact ? 12 : 13, weight: .semibold), .foregroundColor: SPColor.label.color, .paragraphStyle: title])
        let hint = NSAttributedString(string: ViewerStrings.Workspace.orDrop, attributes: [
            .font: SPFont.secondary.font(), .foregroundColor: SPColor.secondaryLabel.color, .paragraphStyle: title])
        let circle: NSRect
        switch layoutKind {
        case .grid:
            circle = NSRect(x: card.midX - d / 2, y: card.minY + (compact ? 34 : 52), width: d, height: d)
            let textRect = NSRect(x: card.minX + 14, y: circle.maxY + (compact ? 12 : 16), width: card.width - 28, height: 60)
            let bounds = titleText.boundingRect(with: textRect.size, options: [.usesLineFragmentOrigin])
            titleText.draw(with: textRect, options: [.usesLineFragmentOrigin])
            hint.draw(with: NSRect(x: textRect.minX, y: textRect.minY + ceil(bounds.height) + 4, width: textRect.width, height: 16), options: [.usesLineFragmentOrigin])
            if !compact { drawBadges(centeredAt: NSPoint(x: card.midX, y: card.maxY - 36)) }
        case .list:
            circle = NSRect(x: card.minX + 16, y: card.midY - d / 2, width: d, height: d)
            titleText.draw(at: NSPoint(x: circle.maxX + 14, y: card.midY - 17))
            hint.draw(at: NSPoint(x: circle.maxX + 14, y: card.midY + 2))
        }
        NSGraphicsContext.saveGraphicsState()
        let shadow = NSShadow()
        shadow.shadowColor = accent.withAlphaComponent(0.4)
        shadow.shadowBlurRadius = 8
        shadow.shadowOffset = NSSize(width: 0, height: -3)
        shadow.set()
        accent.setFill()
        NSBezierPath(ovalIn: circle).fill()
        NSGraphicsContext.restoreGraphicsState()
        if let plus = SPIcon.glyphImage("plus", size: d * 0.42, weight: .bold) {
            plus.draw(in: NSRect(x: circle.midX - plus.size.width / 2, y: circle.midY - plus.size.height / 2, width: plus.size.width, height: plus.size.height),
                      from: .zero, operation: .sourceOver, fraction: 1, respectFlipped: true, hints: nil)
        }
    }

    private func drawBadges(centeredAt center: NSPoint) {
        let badges: [(String, SPColorToken)] = [("PDF", SPColor.categoryRed), ("JPG", SPColor.categoryPink), ("DOC", SPColor.categoryBlue),
                                                ("XLS", SPColor.categoryGreen), ("PPT", SPColor.categoryOrange)]
        let font = NSFont.systemFont(ofSize: 9, weight: .bold)
        let texts = badges.map { NSAttributedString(string: $0.0, attributes: [.font: font, .foregroundColor: NSColor.white, .kern: 0.2]) }
        let widths = texts.map { ceil($0.size().width) + 10 }
        var x = center.x - (widths.reduce(0, +) + CGFloat(badges.count - 1) * 4) / 2
        for (index, text) in texts.enumerated() {
            let rect = NSRect(x: x, y: center.y - 8, width: widths[index], height: 16)
            badges[index].1.color.setFill()
            NSBezierPath(roundedRect: rect, xRadius: 4, yRadius: 4).fill()
            let size = text.size()
            text.draw(at: NSPoint(x: rect.midX - size.width / 2, y: rect.midY - size.height / 2))
            x += widths[index] + 4
        }
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        needsDisplay = true
    }

    // MARK: Accessibility (the hover toolbar's buttons are custom actions, so they never need a pointer)

    private func updateAccessibility() {
        switch item {
        case .add:
            setAccessibilityRole(.button)
            setAccessibilityLabel(ViewerStrings.Workspace.addFiles)
            setAccessibilityCustomActions(nil)
        case .pending:
            setAccessibilityRole(.group)
            setAccessibilityLabel("\(origin?.fileName ?? ""), \(caption)")
            setAccessibilityCustomActions(nil)
        default:
            setAccessibilityRole(.checkBox)
            setAccessibilityLabel("\(origin?.fileName ?? ""), \(caption)")
            setAccessibilityValue(isSelected ? 1 : 0)
            setAccessibilitySelected(isSelected)
            setAccessibilityCustomActions(WorkspaceCardAction.allCases.map { action in
                NSAccessibilityCustomAction(name: action.title) { [weak self] in
                    guard let self else { return false }
                    self.host?.perform(action, on: self)
                    return true
                }
            })
        }
    }

    override func accessibilityPerformPress() -> Bool {
        host?.press(self)
        return true
    }
}

/// The small white toolbar a hovered card shows: Preview, Rotate, Duplicate, Delete, each with a tooltip.
@MainActor
final class WorkspaceHoverBar: NSView {
    var onAction: ((WorkspaceCardAction) -> Void)?
    private var buttons: [NSButton] = []

    override init(frame: NSRect) {
        super.init(frame: frame)
        for (index, action) in WorkspaceCardAction.allCases.enumerated() {
            let button = NSButton(image: NSImage(systemSymbolName: action.symbol, accessibilityDescription: action.title) ?? NSImage(),
                                  target: self, action: #selector(press(_:)))
            button.isBordered = false
            button.tag = index
            button.toolTip = action.title
            button.setAccessibilityLabel(action.title)
            button.symbolConfiguration = .init(pointSize: 12, weight: .semibold)
            button.contentTintColor = action == .delete ? SPColor.categoryRed.color : SPColor.label.color
            addSubview(button)
            buttons.append(button)
        }
    }

    @available(*, unavailable) required init?(coder: NSCoder) { fatalError() }

    override var isFlipped: Bool { true }

    /// Room round the bar for its shadow.
    static let padding: CGFloat = 8

    /// The bar's own size (its frame is `padding` bigger all round).
    func fittingSize(compact: Bool) -> NSSize {
        let b = compact ? SPMetrics.Workspace.hoverButton - 2 : SPMetrics.Workspace.hoverButton
        return NSSize(width: CGFloat(buttons.count) * b + 4, height: b + 4)
    }

    override func layout() {
        super.layout()
        let bar = bounds.insetBy(dx: Self.padding, dy: Self.padding)
        let b = bar.height - 4
        for (index, button) in buttons.enumerated() { button.frame = NSRect(x: bar.minX + 2 + CGFloat(index) * b, y: bar.minY + 2, width: b, height: b) }
    }

    override func draw(_ dirtyRect: NSRect) {
        NSGraphicsContext.saveGraphicsState()
        let shadow = NSShadow()
        shadow.shadowColor = NSColor.black.withAlphaComponent(0.16)
        shadow.shadowBlurRadius = 6
        shadow.shadowOffset = NSSize(width: 0, height: -2)
        shadow.set()
        SPColor.controlBackground.color.withAlphaComponent(0.97).setFill()
        NSBezierPath(roundedRect: bounds.insetBy(dx: Self.padding + 0.5, dy: Self.padding + 0.5), xRadius: 9, yRadius: 9).fill()
        NSGraphicsContext.restoreGraphicsState()
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        needsDisplay = true
    }

    /// Clicks in the shadow's room go to the card below.
    override func hitTest(_ point: NSPoint) -> NSView? {
        let local = convert(point, from: superview)
        return bounds.insetBy(dx: Self.padding, dy: Self.padding).contains(local) ? super.hitTest(point) : nil
    }

    @objc private func press(_ sender: NSButton) { onAction?(WorkspaceCardAction.allCases[sender.tag]) }
}
