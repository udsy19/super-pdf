import AppKit

// The app's icon shape (ux §2.4): a rounded square filled with a brand colour, a touch lighter at the top, with a white
// SF Symbol on it. Tools tiles, section chips and headers, panel headers and the welcome window's targets all draw it,
// so it lives here for ToolsKit and ViewerKit alike. Drawn, not cached: the colours resolve with the appearance in use.

public enum SPIcon {
    /// Draws the icon into the current graphics context (a flipped or unflipped view's `draw(_:)`).
    public static func draw(_ symbol: String, color: NSColor, in rect: NSRect, radius: CGFloat, glyph: CGFloat,
                            weight: NSFont.Weight = .semibold, shadow: Bool = true) {
        let path = NSBezierPath(roundedRect: rect, xRadius: radius, yRadius: radius)
        if shadow {
            NSGraphicsContext.saveGraphicsState()
            let drop = NSShadow()
            drop.shadowColor = color.withAlphaComponent(0.35)
            drop.shadowBlurRadius = 3
            drop.shadowOffset = NSSize(width: 0, height: -1)
            drop.set()
            color.setFill()
            path.fill()
            NSGraphicsContext.restoreGraphicsState()
        }
        let flipped = NSGraphicsContext.current?.isFlipped ?? false
        let top = color.blended(withFraction: 0.24, of: .white) ?? color
        NSGradient(starting: top, ending: color)?.draw(in: path, angle: flipped ? 90 : -90)
        NSColor.black.withAlphaComponent(0.06).setStroke()
        let edge = NSBezierPath(roundedRect: rect.insetBy(dx: 0.25, dy: 0.25), xRadius: radius, yRadius: radius)
        edge.lineWidth = 0.5
        edge.stroke()
        guard let image = glyphImage(symbol, size: glyph, weight: weight) else { return }
        let size = image.size
        image.draw(in: NSRect(x: (rect.midX - size.width / 2).rounded(), y: (rect.midY - size.height / 2).rounded(), width: size.width, height: size.height),
                   from: .zero, operation: .sourceOver, fraction: 1, respectFlipped: true, hints: nil)
    }

    /// The white glyph alone (nil for a name the system doesn't know: never a crash on a bad name).
    public static func glyphImage(_ symbol: String, size: CGFloat, weight: NSFont.Weight = .semibold) -> NSImage? {
        NSImage(systemSymbolName: symbol, accessibilityDescription: nil)?
            .withSymbolConfiguration(NSImage.SymbolConfiguration(pointSize: size, weight: weight).applying(.init(paletteColors: [.white])))
    }
}

/// A view that draws `SPIcon` (tiles, chips, section headers, welcome targets), redrawn when the appearance changes.
public final class SPIconView: NSView {
    public var symbol: String { didSet { needsDisplay = true } }
    public var color: SPColorToken { didSet { needsDisplay = true } }
    public var radius: CGFloat { didSet { needsDisplay = true } }
    public var glyph: CGFloat { didSet { needsDisplay = true } }

    public init(symbol: String, color: SPColorToken, radius: CGFloat, glyph: CGFloat) {
        self.symbol = symbol; self.color = color; self.radius = radius; self.glyph = glyph
        super.init(frame: .zero)
        setAccessibilityElement(false)
    }

    @available(*, unavailable) required init?(coder: NSCoder) { fatalError() }

    public override var isFlipped: Bool { true }

    public override func draw(_ dirtyRect: NSRect) {
        // A point of room all round for the soft shadow: the icon itself is the frame less 1 pt each side.
        SPIcon.draw(symbol, color: color.color, in: bounds.insetBy(dx: 1, dy: 1), radius: radius, glyph: glyph)
    }

    public override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        needsDisplay = true
    }
}
