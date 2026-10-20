import AppKit
import SuperPDFCore
import UniformTypeIdentifiers

/// One tile of the Tools sheet (ux §2.1, §4): 150 × 116, a category-coloured circle with the symbol, the name and two
/// lines of hint; hover lifts it with an accent border, the keyboard's tile gets a focus ring, files dropped on it run
/// that tool, right-click adds it to the toolbar or the Dock menu.
@MainActor
final class TileView: NSView {
    let tile: ToolTile
    var onChoose: ((ToolTile, [URL]) -> Void)?
    var onAddToToolbar: ((ToolTile) -> Void)?
    var onAddToDockMenu: ((ToolTile) -> Void)?

    var isHovered = false { didSet { if isHovered != oldValue { restyle(animated: true) } } }
    var isKeyboardSelected = false { didSet { if isKeyboardSelected != oldValue { restyle(animated: false) } } }
    private var isDropTarget = false { didSet { if isDropTarget != oldValue { restyle(animated: true) } } }

    private let card = FlippedView()
    private let circle = NSView()
    private let icon = NSImageView()
    private let name = NSTextField(labelWithString: "")
    private let hint = NSTextField(wrappingLabelWithString: "")
    private let badge = NSTextField(labelWithString: "")
    private let badgeBack = NSView()

    init(tile: ToolTile, availability: ToolAvailability) {
        self.tile = tile
        super.init(frame: NSRect(origin: .zero, size: SPMetrics.Tile.size))
        wantsLayer = true
        card.wantsLayer = true
        card.layer?.cornerRadius = SPMetrics.Tile.radius
        card.layer?.cornerCurve = .continuous
        card.layer?.borderWidth = SPMetrics.Tile.border
        addSubview(card)

        circle.wantsLayer = true
        circle.layer?.cornerRadius = SPMetrics.Tile.iconCircle / 2
        card.addSubview(circle)
        icon.image = symbol(tile.symbol, size: SPMetrics.Tile.symbolSize)
        icon.contentTintColor = Style.category(tile.section)
        icon.imageScaling = .scaleProportionallyDown
        circle.addSubview(icon)

        name.stringValue = tile.name
        name.font = Style.font(SPFont.tileName)
        name.textColor = Style.label
        name.lineBreakMode = .byTruncatingTail
        card.addSubview(name)

        hint.attributedStringValue = Self.hintText(tile)
        hint.maximumNumberOfLines = SPMetrics.Tile.hintLines
        hint.cell?.truncatesLastVisibleLine = true
        hint.cell?.lineBreakMode = .byWordWrapping
        card.addSubview(hint)

        if let text = availability.badge {
            badgeBack.wantsLayer = true
            badgeBack.layer?.cornerRadius = 8
            card.addSubview(badgeBack)
            badge.stringValue = text
            badge.font = Style.font(size: 10, weight: .medium)
            badge.textColor = Style.secondary
            card.addSubview(badge)
        }

        registerForDraggedTypes([.fileURL])
        setAccessibilityElement(true)
        setAccessibilityRole(.button)
        setAccessibilityLabel(tile.name)
        setAccessibilityHelp(availability.badge.map { "\(tile.hint). \($0)" } ?? tile.hint)
        restyle(animated: false)
    }

    @available(*, unavailable) required init?(coder: NSCoder) { fatalError() }

    override var isFlipped: Bool { true }

    /// The hint, with the Acrobat word in brackets for experts (Settings › Tools, ux §6.6): "… (Compress)".
    static func hintText(_ tile: ToolTile) -> NSAttributedString {
        var text = tile.hint
        if Defaults[.showJargonInHints], let jargon = tile.synonyms.first { text += " (\(jargonWord(jargon)))" }
        let paragraph = NSMutableParagraphStyle()
        paragraph.minimumLineHeight = 13.75   // 1.25 × 11 pt, as the mockup
        paragraph.maximumLineHeight = 13.75
        paragraph.lineBreakMode = .byWordWrapping
        return NSAttributedString(string: text, attributes: [.font: Style.font(SPFont.tileHint), .foregroundColor: Style.secondary,
                                                              .paragraphStyle: paragraph])
    }

    /// "compress" → "Compress", "ocr" → "OCR", "pdfa" → "PDF/A", "jpg to pdf" → "JPG to PDF".
    static func jargonWord(_ synonym: String) -> String {
        let acronyms: Set<String> = ["ocr", "pdf", "docx", "xlsx", "pptx", "csv", "html", "epub", "txt", "rtf", "doc", "url", "hwp", "odt",
                                     "heic", "png", "jpeg", "jpg", "tiff", "cmyk", "a4", "pdf/x", "pdf/ua", "iso"]
        if synonym == "pdfa" { return "PDF/A" }
        return synonym.split(separator: " ").enumerated().map { index, word in
            let w = String(word)
            if acronyms.contains(w) { return w.uppercased() }
            return index == 0 ? w.prefix(1).uppercased() + w.dropFirst() : w
        }.joined(separator: " ")
    }

    // MARK: Layout

    override func layout() {
        super.layout()
        let lift = isHovered && !Style.reduceMotion ? SPMetrics.Tile.hoverLift : 0
        card.frame = bounds.offsetBy(dx: 0, dy: -lift)
        let inset = Style.TileInside.padding
        let d = SPMetrics.Tile.iconCircle
        let nameHeight = ceil(name.intrinsicContentSize.height)
        let hintHeight = 13.75 * CGFloat(SPMetrics.Tile.hintLines)
        // The mockup's 6 pt gaps, tightened if a larger circle needs the room.
        let room = bounds.height - inset.top - inset.bottom - d - nameHeight - hintHeight
        let gap = max(2, min(Style.TileInside.gap, room / 2))
        circle.frame = NSRect(x: inset.left, y: inset.top, width: d, height: d)
        icon.frame = circle.bounds
        let width = bounds.width - inset.left - inset.right
        name.frame = NSRect(x: inset.left - 2, y: circle.frame.maxY + gap, width: width + 4, height: nameHeight)
        hint.preferredMaxLayoutWidth = width
        hint.frame = NSRect(x: inset.left - 2, y: name.frame.maxY + gap - 1, width: width + 4, height: hintHeight + 2)
        if !badge.stringValue.isEmpty {
            let size = badge.intrinsicContentSize
            let back = NSRect(x: bounds.width - inset.right - size.width - 10, y: inset.top, width: size.width + 10, height: 16)
            badgeBack.frame = back
            badge.frame = NSRect(x: back.minX + 5, y: back.midY - size.height / 2, width: size.width, height: size.height)
        }
    }

    override var intrinsicContentSize: NSSize { SPMetrics.Tile.size }

    // MARK: Look

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        restyle(animated: false)
    }

    private func restyle(animated: Bool) {
        let highlighted = isHovered || isKeyboardSelected || isDropTarget
        effectiveAppearance.performAsCurrentDrawingAppearance {
            let layer = card.layer
            let apply = {
                layer?.backgroundColor = (self.isDropTarget ? Style.accent.withAlphaComponent(SPMetrics.DropTarget.tintOpacity)
                    .blended(withFraction: 0.92, of: Style.control) ?? Style.control : Style.control).cgColor
                layer?.borderColor = (highlighted ? Style.accent : Style.separator).cgColor
                layer?.borderWidth = self.isDropTarget || self.isKeyboardSelected ? SPMetrics.DropTarget.ring : SPMetrics.Tile.border
                layer?.shadowColor = NSColor.black.cgColor
                layer?.shadowOpacity = self.isHovered ? 0.10 : 0.04
                layer?.shadowRadius = self.isHovered ? 6 : 1
                layer?.shadowOffset = CGSize(width: 0, height: self.isHovered ? -4 : -1)
            }
            if animated && !Style.reduceMotion {
                CATransaction.begin()
                CATransaction.setAnimationDuration(SPMotion.hover)
                apply()
                CATransaction.commit()
            } else {
                CATransaction.begin()
                CATransaction.setDisableActions(true)
                apply()
                CATransaction.commit()
            }
            circle.layer?.backgroundColor = Style.category(tile.section).withAlphaComponent(SPMetrics.Tile.iconCircleOpacity).cgColor
            badgeBack.layer?.backgroundColor = Style.faintFill.cgColor
        }
        needsLayout = true
    }

    // MARK: Mouse

    private var tracking: NSTrackingArea?

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let tracking { removeTrackingArea(tracking) }
        let area = NSTrackingArea(rect: bounds, options: [.mouseEnteredAndExited, .activeInKeyWindow, .inVisibleRect], owner: self)
        addTrackingArea(area)
        tracking = area
    }

    override func mouseEntered(with event: NSEvent) { isHovered = true }
    override func mouseExited(with event: NSEvent) { isHovered = false }

    override func mouseUp(with event: NSEvent) {
        guard bounds.contains(convert(event.locationInWindow, from: nil)) else { return }
        onChoose?(tile, [])
    }

    override func accessibilityPerformPress() -> Bool { onChoose?(tile, []); return true }

    override func menu(for event: NSEvent) -> NSMenu? {
        let menu = NSMenu()
        let toolbar = NSMenuItem(title: Strings.ToolsSheet.addToToolbar, action: #selector(addToToolbar), keyEquivalent: "")
        toolbar.target = self
        toolbar.isEnabled = !Defaults[.toolbarTools].contains(tile.id)
        let dock = NSMenuItem(title: Strings.ToolsSheet.addToDockMenu, action: #selector(addToDockMenu), keyEquivalent: "")
        dock.target = self
        dock.isEnabled = !Defaults[.dockMenuTools].contains(tile.id)
        menu.autoenablesItems = false
        menu.items = [toolbar, dock]
        return menu
    }

    @objc private func addToToolbar() { onAddToToolbar?(tile) }
    @objc private func addToDockMenu() { onAddToDockMenu?(tile) }

    // MARK: Drop files on a tile (ux §3)

    private func fileURLs(_ info: NSDraggingInfo) -> [URL] {
        (info.draggingPasteboard.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as? [URL]) ?? []
    }

    override func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation {
        guard !fileURLs(sender).isEmpty else { return [] }
        isDropTarget = true
        return .copy
    }

    override func draggingExited(_ sender: NSDraggingInfo?) { isDropTarget = false }

    override func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
        isDropTarget = false
        let urls = fileURLs(sender)
        guard !urls.isEmpty else { return false }
        onChoose?(tile, urls)
        return true
    }
}

/// A view whose y grows downwards, for laying out top to bottom.
class FlippedView: NSView {
    override var isFlipped: Bool { true }
}
