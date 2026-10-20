import AppKit
import SuperPDFCore

/// How a page thumbnail looks in the sidebar and in the organiser (ux §2.1, §6.2; main-window.png, organizer.png).
struct ThumbnailStyle {
    /// Corner radius of the page itself (the mockups: 3 pt in the sidebar, 6 pt in the organiser).
    var pageRadius: CGFloat
    /// 1 pt `separatorColor` border (sidebar) or a 0.5 pt hairline (organiser).
    var borderWidth: CGFloat
    var borderAlpha: CGFloat
    var shadowBlur: CGFloat
    var shadowAlpha: CGFloat
    /// The selection ring: radius, width, and its distance from the page.
    var ringRadius: CGFloat
    var ringWidth: CGFloat
    var ringOffset: CGFloat
    /// Accent 15 % behind a selected page (ux §2.1 sidebar).
    var selectionFill: Bool
    /// Page to page-number distance; the number is 11 pt (ux §2.2).
    var labelGap: CGFloat

    static let labelHeight: CGFloat = 14

    /// Room around the page for the ring.
    var ringMargin: CGFloat { ringOffset + ringWidth }

    static let sidebar = ThumbnailStyle(pageRadius: 3, borderWidth: SPMetrics.Sidebar.thumbnailBorder, borderAlpha: 1,
                                        shadowBlur: SPMetrics.Sidebar.thumbnailShadow, shadowAlpha: 0.12,
                                        ringRadius: SPMetrics.Sidebar.thumbnailRadius, ringWidth: SPMetrics.Sidebar.selectionRing,
                                        ringOffset: 2, selectionFill: true, labelGap: 5)
    static let organiser = ThumbnailStyle(pageRadius: 6, borderWidth: 0.5, borderAlpha: 0.08, shadowBlur: 5, shadowAlpha: 0.18,
                                          ringRadius: SPMetrics.Organiser.radius, ringWidth: 2.5, ringOffset: 3, selectionFill: false,
                                          labelGap: 8)

    /// The cell size for a page of `aspect` (height / width) shown `pageWidth` wide.
    func cellSize(pageWidth: CGFloat, aspect: CGFloat) -> NSSize {
        NSSize(width: pageWidth + 2 * ringMargin, height: ringMargin + (pageWidth * aspect).rounded() + labelGap + Self.labelHeight)
    }
}

/// One page: its picture, the selection ring, the file-colour bar and the page number underneath. Drawn in
/// `draw(_:)` (no per-frame work while scrolling: the layer caches it).
final class PageThumbnailView: NSView {
    var style: ThumbnailStyle = .sidebar { didSet { needsDisplay = true } }
    var image: CGImage? { didSet { needsDisplay = true } }
    /// Height / width of the turned page.
    var aspect: CGFloat = 11 / 8.5 { didSet { needsDisplay = true } }
    var label = "" { didSet { needsDisplay = true } }
    var isSelected = false { didSet { if isSelected != oldValue { needsDisplay = true } } }
    /// The bar of a page that came from another file (organiser).
    var originColor: NSColor? { didSet { needsDisplay = true } }
    /// The page being dragged stays behind at 25 % (organizer.png).
    var isGhosted = false { didSet { if isGhosted != oldValue { needsDisplay = true } } }

    override var isFlipped: Bool { true }
    override var wantsUpdateLayer: Bool { false }

    override init(frame: NSRect) {
        super.init(frame: frame)
        layerContentsRedrawPolicy = .onSetNeedsDisplay
    }

    required init?(coder: NSCoder) { fatalError("not used") }

    /// The page's rectangle in this view: full width less the ring margin, aspect height, top-aligned.
    var pageRect: NSRect {
        let margin = style.ringMargin
        let width = bounds.width - 2 * margin
        let available = bounds.height - margin - style.labelGap - ThumbnailStyle.labelHeight
        var height = (width * aspect).rounded()
        var pageWidth = width
        if height > available, available > 0 { height = available; pageWidth = (available / aspect).rounded() }
        return NSRect(x: ((bounds.width - pageWidth) / 2).rounded(), y: margin, width: pageWidth, height: height)
    }

    override func draw(_ dirtyRect: NSRect) {
        guard let context = NSGraphicsContext.current?.cgContext else { return }
        if isGhosted { context.setAlpha(0.25); context.beginTransparencyLayer(auxiliaryInfo: nil) }
        let page = pageRect
        let accent = SPColor.accent.color
        let ringRect = page.insetBy(dx: -style.ringOffset - style.ringWidth / 2, dy: -style.ringOffset - style.ringWidth / 2)
        let ringPath = NSBezierPath(roundedRect: ringRect, xRadius: style.ringRadius, yRadius: style.ringRadius)
        if isSelected && style.selectionFill {
            accent.withAlphaComponent(SPMetrics.Sidebar.selectionFillOpacity).setFill()
            ringPath.fill()
        }

        let pagePath = NSBezierPath(roundedRect: page, xRadius: style.pageRadius, yRadius: style.pageRadius)
        NSGraphicsContext.saveGraphicsState()
        let shadow = NSShadow()
        shadow.shadowColor = NSColor.black.withAlphaComponent(style.shadowAlpha)
        shadow.shadowBlurRadius = style.shadowBlur
        shadow.shadowOffset = NSSize(width: 0, height: -1)
        shadow.set()
        NSColor.white.setFill()
        pagePath.fill()
        NSGraphicsContext.restoreGraphicsState()

        NSGraphicsContext.saveGraphicsState()
        pagePath.addClip()
        if let image {
            context.saveGState()
            context.translateBy(x: 0, y: page.maxY + page.minY)
            context.scaleBy(x: 1, y: -1)
            context.interpolationQuality = .high
            context.draw(image, in: page)
            context.restoreGState()
        }
        if let originColor {
            originColor.setFill()
            NSRect(x: page.minX, y: page.maxY - SPMetrics.Organiser.fileColorBar, width: page.width, height: SPMetrics.Organiser.fileColorBar).fill()
        }
        NSGraphicsContext.restoreGraphicsState()

        let border = NSBezierPath(roundedRect: page.insetBy(dx: style.borderWidth / 2, dy: style.borderWidth / 2),
                                  xRadius: style.pageRadius, yRadius: style.pageRadius)
        border.lineWidth = style.borderWidth
        (style.borderAlpha < 1 ? NSColor.black.withAlphaComponent(style.borderAlpha) : SPColor.separator.color).setStroke()
        border.stroke()

        if isSelected {
            ringPath.lineWidth = style.ringWidth
            accent.setStroke()
            ringPath.stroke()
        }

        let font = isSelected ? NSFont.systemFont(ofSize: SPFont.secondary.size, weight: .semibold) : SPFont.secondary.font()
        let color = isSelected ? SPColor.label.color : SPColor.secondaryLabel.color
        let paragraph = NSMutableParagraphStyle()
        paragraph.alignment = .center
        paragraph.lineBreakMode = .byTruncatingMiddle
        let text = NSAttributedString(string: label, attributes: [.font: font, .foregroundColor: color, .paragraphStyle: paragraph])
        text.draw(in: NSRect(x: 0, y: page.maxY + style.labelGap, width: bounds.width, height: ThumbnailStyle.labelHeight))
        if isGhosted { context.endTransparencyLayer() }
    }
}
