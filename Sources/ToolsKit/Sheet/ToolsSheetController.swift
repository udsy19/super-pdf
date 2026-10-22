import AppKit
import QuartzCore
import SuperPDFCore

/// The Tools sheet (ux §4): "What do you want to do?", the search field (focused on open), a row of coloured section
/// chips that jump to their section, Recently used and the sections of tiles. Plain AppKit views built once and reused, so it opens at once and filters on every keystroke.
@MainActor
final class ToolsSheetController: NSViewController, NSTextFieldDelegate {
    struct Actions {
        var choose: (ToolTile, [URL]) -> Void
        var close: () -> Void
        var addToToolbar: (ToolTile) -> Void
        var addToDockMenu: (ToolTile) -> Void
    }

    let model: ToolsSheetModel
    private let actions: Actions
    private let availability: (ToolID) -> ToolAvailability
    private var sheetView: ToolsSheetView { view as! ToolsSheetView }

    init(model: ToolsSheetModel, availability: @escaping (ToolID) -> ToolAvailability, actions: Actions) {
        self.model = model
        self.availability = availability
        self.actions = actions
        super.init(nibName: nil, bundle: nil)
    }

    @available(*, unavailable) required init?(coder: NSCoder) { fatalError() }

    override func loadView() {
        let sheet = ToolsSheetView(frame: NSRect(origin: .zero, size: SPMetrics.ToolsSheet.size))
        sheet.search.field.delegate = self
        sheet.closeButton.target = self
        sheet.closeButton.action = #selector(closeSheet)
        sheet.onSection = { [weak self] section in self?.scroll(to: section) }
        sheet.onCancel = { [weak self] in self?.actions.close() }
        view = sheet
        reloadTiles()
    }

    /// Fresh for ⌘T (empty search); `query` restores the search when coming back from a panel.
    func prepare(query: String) {
        _ = view
        sheetView.search.field.stringValue = query
        model.search(query)
        model.reload()
        reloadTiles()
        sheetView.grid.scroll(NSPoint(x: 0, y: 0))
    }

    override func viewDidAppear() {
        super.viewDidAppear()
        view.window?.makeFirstResponder(sheetView.search.field)
        sheetView.search.showsFocus = true
        sheetView.grid.animateIn()
    }

    @objc private func closeSheet() { actions.close() }

    // MARK: Tiles

    /// Tiles are made once per catalogue tile and once per Recently used slot; filtering only hides and moves them.
    private var sectionTiles: [ToolID: TileView] = [:]
    private var recentTiles: [TileView] = []

    private func makeTile(_ tile: ToolTile) -> TileView {
        let view = TileView(tile: tile, availability: availability(tile.id))
        view.onChoose = { [weak self] tile, urls in self?.actions.choose(tile, urls) }
        view.onAddToToolbar = { [weak self] tile in self?.actions.addToToolbar(tile) }
        view.onAddToDockMenu = { [weak self] tile in self?.actions.addToDockMenu(tile) }
        return view
    }

    private func reloadTiles() {
        if sectionTiles.isEmpty {
            for tile in ToolCatalog.tiles { sectionTiles[tile.id] = makeTile(tile) }
        }
        let recent = model.groups.first { $0.section == nil }?.tiles ?? []
        if recentTiles.map(\.tile) != recent { recentTiles = recent.map(makeTile) }
        var rows: [TileGrid.Row] = []
        for (g, group) in model.groups.enumerated() {
            let views = group.section == nil ? recentTiles : group.tiles.compactMap { sectionTiles[$0.id] }
            rows.append(.init(group: g, title: group.title, section: group.section, tiles: views))
        }
        sheetView.grid.show(rows, all: Array(sectionTiles.values) + recentTiles)
        sheetView.showNoResults(model.isEmpty ? Strings.ToolsSheet.noResults(model.query.trimmingCharacters(in: .whitespaces)) : nil)
        markSelection()
    }

    private func markSelection() {
        let selected = model.selection.flatMap { position in sheetView.grid.tileView(at: position) }
        for view in sheetView.grid.allTiles { view.isKeyboardSelected = view === selected }
        selected?.scrollToVisible(selected?.bounds.insetBy(dx: -8, dy: -16) ?? .zero)
    }

    private func scroll(to section: ToolSection) {
        guard let group = model.group(of: section) else { return }
        sheetView.grid.scrollTo(group: group)
    }

    // MARK: Search field

    func controlTextDidChange(_ notification: Notification) {
        model.search(sheetView.search.field.stringValue)
        reloadTiles()
    }

    func controlTextDidEndEditing(_ notification: Notification) { sheetView.search.showsFocus = false }

    func control(_ control: NSControl, textView: NSTextView, doCommandBy selector: Selector) -> Bool {
        let columns = sheetView.grid.columns
        switch selector {
        case #selector(NSResponder.moveDown(_:)): model.move(.down, columns: columns)
        case #selector(NSResponder.moveUp(_:)): model.move(.up, columns: columns)
        // Left and right edit the text while there is some; with an empty field (or a tile picked by arrows) they move.
        case #selector(NSResponder.moveLeft(_:)) where textView.string.isEmpty || arrowsInGrid: model.move(.left, columns: columns)
        case #selector(NSResponder.moveRight(_:)) where textView.string.isEmpty || arrowsInGrid: model.move(.right, columns: columns)
        case #selector(NSResponder.insertNewline(_:)):
            if let tile = model.returnTarget { actions.choose(tile, []) } else { NSSound.beep() }
            return true
        case #selector(NSResponder.cancelOperation(_:)):
            actions.close()
            return true
        default:
            arrowsInGrid = false
            return false
        }
        arrowsInGrid = true
        markSelection()
        return true
    }

    /// Up or down moved into the grid: left and right follow until the next typing.
    private var arrowsInGrid = false
}

// MARK: - Views

/// The sheet's root: background with a soft colour wash, close button, title, search field, section chips, the scrolling
/// grid and the "nothing found" line.
@MainActor
final class ToolsSheetView: NSView {
    let closeButton = CloseButton()
    let search = SearchBox()
    let chips = SectionChips()
    let grid = TileGrid()
    var onSection: ((ToolSection) -> Void)?
    var onCancel: (() -> Void)?

    private let background: NSView
    private let wash = WashView()
    private let title = NSTextField(labelWithString: Strings.ToolsSheet.title)
    private let scroll = NSScrollView()
    private let noResults = NSTextField(wrappingLabelWithString: "")

    override init(frame: NSRect) {
        if Style.opaqueBackgrounds {
            let solid = SolidView()
            solid.color = { Style.surface }
            background = solid
        } else {
            let effect = NSVisualEffectView()
            effect.material = .sidebar
            effect.blendingMode = .behindWindow
            effect.state = .followsWindowActiveState
            background = effect
        }
        super.init(frame: frame)
        addSubview(background)
        addSubview(wash)
        chips.onSection = { [weak self] section in self?.onSection?(section) }
        addSubview(chips)
        title.font = Style.font(SPFont.sheetTitle)
        title.textColor = Style.label
        title.setAccessibilityRole(.staticText)
        addSubview(title)
        addSubview(search)
        closeButton.setAccessibilityLabel(Strings.Panel.cancel)
        addSubview(closeButton)
        scroll.drawsBackground = false
        scroll.hasVerticalScroller = true
        scroll.hasHorizontalScroller = false
        scroll.autohidesScrollers = true
        scroll.scrollerStyle = .overlay
        scroll.documentView = grid
        scroll.contentView.postsBoundsChangedNotifications = false
        addSubview(scroll)
        noResults.font = Style.font(SPFont.body)
        noResults.textColor = Style.secondary
        noResults.alignment = .center
        noResults.isHidden = true
        addSubview(noResults)
        setAccessibilityLabel(Strings.ToolsSheet.title)
    }

    @available(*, unavailable) required init?(coder: NSCoder) { fatalError() }

    override var isFlipped: Bool { true }

    override func layout() {
        super.layout()
        let m = SPMetrics.ToolsSheet.margin
        background.frame = bounds
        wash.frame = NSRect(x: 0, y: 0, width: bounds.width, height: Style.Sheet.washHeight)
        // The title's line box is 1.3 × its size, the text centred in it (as the mockup's CSS).
        let line = (SPFont.sheetTitle.font(Defaults[.textSize]).pointSize * 1.3).rounded()
        let titleHeight = ceil(title.intrinsicContentSize.height)
        title.frame = NSRect(x: m - 2, y: Style.Sheet.titleTop + (line - titleHeight) / 2,
                             width: bounds.width - 2 * m - Style.Sheet.closeSize, height: titleHeight)
        let s = Style.Sheet.closeSize
        closeButton.frame = NSRect(x: bounds.width - Style.Sheet.closeInset - s, y: Style.Sheet.closeInset, width: s, height: s)
        let ring = Style.Sheet.focusRing
        search.frame = NSRect(x: m, y: Style.Sheet.titleTop + line + Style.Sheet.titleGap, width: bounds.width - 2 * m,
                              height: SPMetrics.ToolsSheet.searchFieldHeight).insetBy(dx: -ring, dy: -ring)
        chips.frame = NSRect(x: m, y: search.frame.maxY - ring + Style.Sheet.chipsGap, width: bounds.width - 2 * m, height: Style.Sheet.chipHeight)
        // The grid starts under the chips; its first header sits 24 pt lower (mockup `.sb` + `h2` margins).
        let top = chips.frame.maxY
        scroll.frame = NSRect(x: 0, y: top, width: bounds.width, height: bounds.height - top)
        grid.frame.size.width = scroll.contentSize.width
        grid.relayout()
        noResults.preferredMaxLayoutWidth = bounds.width - 4 * m
        let size = noResults.intrinsicContentSize
        noResults.frame = NSRect(x: 2 * m, y: top + 48, width: bounds.width - 4 * m, height: size.height)
    }

    func showNoResults(_ text: String?) {
        noResults.stringValue = text ?? ""
        noResults.isHidden = text == nil
        needsLayout = true
    }

    /// ⌘1–8 jump to the sections (ux §4).
    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        if event.modifierFlags.intersection(.deviceIndependentFlagsMask) == .command, let chars = event.charactersIgnoringModifiers,
           let n = Int(chars), ToolSection.allCases.indices.contains(n - 1) {
            onSection?(ToolSection.allCases[n - 1])
            return true
        }
        return super.performKeyEquivalent(with: event)
    }

    override func cancelOperation(_ sender: Any?) { onCancel?() }
}

/// The scrolling grid: section headers and tiles, five columns of 150 pt with 16 pt gaps and 24 pt margins (fewer
/// columns when the sheet is narrower).
@MainActor
final class TileGrid: NSView {
    struct Row {
        var group: Int
        var title: String
        /// Nil for Recently used.
        var section: ToolSection?
        var tiles: [TileView]
    }

    private var rows: [Row] = []
    private var headers: [SectionHeader] = []
    private(set) var allTiles: [TileView] = []
    private(set) var columns = SPMetrics.ToolsSheet.columns

    override var isFlipped: Bool { true }

    func show(_ rows: [Row], all: [TileView]) {
        self.rows = rows
        for tile in all where tile.superview !== self { addSubview(tile) }
        for tile in allTiles where !all.contains(where: { $0 === tile }) { tile.removeFromSuperview() }
        allTiles = all
        let shown = Set(rows.flatMap(\.tiles).map(ObjectIdentifier.init))
        for tile in all { tile.isHidden = !shown.contains(ObjectIdentifier(tile)) }
        while headers.count < rows.count { let header = SectionHeader(); headers.append(header); addSubview(header) }
        for (i, header) in headers.enumerated() {
            header.isHidden = i >= rows.count
            if i < rows.count { header.set(rows[i].title, section: rows[i].section) }
        }
        relayout()
    }

    func tileView(at position: ToolsSheetModel.Position) -> TileView? {
        rows.first { $0.group == position.group }.flatMap { $0.tiles.indices.contains(position.index) ? $0.tiles[position.index] : nil }
    }

    func relayout() {
        let m = SPMetrics.ToolsSheet.margin, gap = SPMetrics.ToolsSheet.gap, size = SPMetrics.Tile.size
        columns = max(1, min(SPMetrics.ToolsSheet.columns, Int((bounds.width - 2 * m + gap) / (size.width + gap))))
        var y = Style.Sheet.bodyTop
        for (i, row) in rows.enumerated() {
            y += Style.Sheet.headerTop
            headers[i].frame = NSRect(x: m, y: y, width: bounds.width - 2 * m, height: Style.Sheet.headerLine)
            y += Style.Sheet.headerLine + Style.Sheet.headerGap
            for (n, tile) in row.tiles.enumerated() {
                let column = n % columns, line = n / columns
                tile.frame = NSRect(x: m + CGFloat(column) * (size.width + gap), y: y + CGFloat(line) * (size.height + gap),
                                    width: size.width, height: size.height)
            }
            let lines = (row.tiles.count + columns - 1) / columns
            y += CGFloat(lines) * size.height + CGFloat(max(lines - 1, 0)) * gap
        }
        y += Style.Sheet.bottom
        let height = max(y, enclosingScrollView?.contentSize.height ?? 0)
        if frame.height != height { setFrameSize(NSSize(width: frame.width, height: height)) }
    }

    override func resizeSubviews(withOldSize oldSize: NSSize) {
        super.resizeSubviews(withOldSize: oldSize)
        if oldSize.width != frame.width { relayout() }
    }

    func scrollTo(group: Int) {
        guard let index = rows.firstIndex(where: { $0.group == group }) else { return }
        scroll(NSPoint(x: 0, y: max(headers[index].frame.minY - Style.Sheet.headerTop, 0)))
    }

    /// Tiles fade up in three staggered rows of 40 ms (ux §2.5); with Reduce Motion they only fade.
    func animateIn() {
        let visible = enclosingScrollView?.documentVisibleRect ?? bounds
        let rowTops = Array(Set(allTiles.filter { !$0.isHidden && $0.frame.intersects(visible) }.map(\.frame.minY))).sorted()
        for tile in allTiles where !tile.isHidden && tile.frame.intersects(visible) {
            guard let layer = tile.layer, let row = rowTops.firstIndex(of: tile.frame.minY) else { continue }
            let delay = CACurrentMediaTime() + Double(min(row, SPMotion.tileStaggerRows - 1)) * SPMotion.tileStagger
            let fade = CABasicAnimation(keyPath: "opacity")
            fade.fromValue = 0
            fade.toValue = 1
            let group = CAAnimationGroup()
            group.animations = [fade]
            if !Style.reduceMotion {
                let rise = CABasicAnimation(keyPath: "transform.translation.y")
                rise.fromValue = -6
                rise.toValue = 0
                group.animations?.append(rise)
            }
            group.beginTime = delay
            group.duration = 0.2
            group.fillMode = .backwards
            group.timingFunction = CAMediaTimingFunction(name: .easeOut)
            layer.add(group, forKey: "fadeUp")
        }
    }
}

/// "Recently used", or a section's name after its coloured icon.
@MainActor
final class SectionHeader: NSView {
    private let icon = SPIconView(symbol: "", color: SPColor.categoryBlue, radius: 6, glyph: 11)
    private let label = NSTextField(labelWithString: "")

    override init(frame: NSRect) {
        super.init(frame: frame)
        addSubview(icon)
        label.font = Style.font(SPFont.sectionHeader)
        label.textColor = Style.label
        addSubview(label)
        setAccessibilityElement(true)
        setAccessibilityRole(.staticText)
    }

    @available(*, unavailable) required init?(coder: NSCoder) { fatalError() }

    override var isFlipped: Bool { true }

    func set(_ title: String, section: ToolSection?) {
        label.stringValue = title
        icon.isHidden = section == nil
        if let section { icon.symbol = section.symbol; icon.color = section.color }
        setAccessibilityLabel(title)
        setAccessibilityRoleDescription("heading")
        needsLayout = true
    }

    override func layout() {
        let size = label.intrinsicContentSize
        let d = Style.Sheet.headerLine
        icon.frame = NSRect(x: -1, y: (bounds.height - d) / 2 - 1, width: d + 2, height: d + 2)
        let x = icon.isHidden ? 0 : d + 8
        label.frame = NSRect(x: x - 2, y: (bounds.height - size.height) / 2, width: bounds.width - x + 2, height: size.height)
    }
}

/// The row of section chips under the search field: each section's coloured icon and name; a click jumps to it (⌘1–8
/// do the same).
@MainActor
final class SectionChips: NSView {
    var onSection: ((ToolSection) -> Void)?
    private(set) var chips: [SectionChip] = []

    override init(frame: NSRect) {
        super.init(frame: frame)
        for section in ToolSection.allCases {
            let chip = SectionChip(section: section)
            chip.onPress = { [weak self] in self?.onSection?(section) }
            chips.append(chip)
            addSubview(chip)
        }
        setAccessibilityElement(true)
        setAccessibilityRole(.group)
        setAccessibilityLabel(ToolsKitStrings.sections)
    }

    @available(*, unavailable) required init?(coder: NSCoder) { fatalError() }

    override var isFlipped: Bool { true }

    override func layout() {
        super.layout()
        var x: CGFloat = 0
        for chip in chips {
            let width = chip.fittingWidth
            chip.frame = NSRect(x: x, y: 0, width: width, height: bounds.height)
            chip.isHidden = chip.frame.maxX > bounds.width
            x += width + Style.Sheet.chipGap
        }
    }
}

/// One section chip: 28 pt capsule, the section's 18 pt icon and its name; hover tints it with the section's colour.
@MainActor
final class SectionChip: NSControl {
    let section: ToolSection
    var onPress: (() -> Void)?
    private let icon: SPIconView
    private let label = NSTextField(labelWithString: "")
    private var isHovered = false { didSet { needsDisplay = true } }

    init(section: ToolSection) {
        self.section = section
        icon = SPIconView(symbol: section.symbol, color: section.color, radius: 6, glyph: 10)
        super.init(frame: .zero)
        addSubview(icon)
        label.stringValue = section.title
        label.font = Style.font(size: 12, weight: .medium)
        label.textColor = Style.label
        addSubview(label)
        setAccessibilityElement(true)
        setAccessibilityRole(.button)
        setAccessibilityLabel(section.title)
    }

    @available(*, unavailable) required init?(coder: NSCoder) { fatalError() }

    override var isFlipped: Bool { true }

    /// The icon 5 pt in, 6 pt to the name, 11 pt after it (the label's own 2 pt inset each side included).
    var fittingWidth: CGFloat { 5 + 18 + 6 - 2 + ceil(label.intrinsicContentSize.width) + 2 + 9 }

    override func layout() {
        super.layout()
        icon.frame = NSRect(x: 4, y: (bounds.height - 20) / 2, width: 20, height: 20)
        let size = label.intrinsicContentSize
        label.frame = NSRect(x: 5 + 18 + 6 - 2, y: (bounds.height - size.height) / 2, width: ceil(size.width) + 2, height: size.height)
    }

    override func draw(_ dirtyRect: NSRect) {
        let path = NSBezierPath(roundedRect: bounds.insetBy(dx: 0.5, dy: 0.5), xRadius: bounds.height / 2, yRadius: bounds.height / 2)
        (isHovered ? section.color.color.withAlphaComponent(0.10).blended(withFraction: 0.9, of: Style.control) ?? Style.control : Style.control).setFill()
        path.fill()
        (isHovered ? section.color.color.withAlphaComponent(0.6) : Style.separator).setStroke()
        path.stroke()
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        trackingAreas.forEach(removeTrackingArea)
        addTrackingArea(NSTrackingArea(rect: .zero, options: [.mouseEnteredAndExited, .activeInKeyWindow, .inVisibleRect], owner: self))
    }

    override func mouseEntered(with event: NSEvent) { isHovered = true }
    override func mouseExited(with event: NSEvent) { isHovered = false }
    override func mouseUp(with event: NSEvent) {
        guard bounds.contains(convert(event.locationInWindow, from: nil)) else { return }
        onPress?()
    }
    override func accessibilityPerformPress() -> Bool { onPress?(); return true }
    override func viewDidChangeEffectiveAppearance() { needsDisplay = true }
}

/// A soft wash of two brand colours behind the sheet's title (light enough to keep the text calm).
@MainActor
final class WashView: NSView {
    override var isFlipped: Bool { true }
    override func draw(_ dirtyRect: NSRect) {
        let blobs: [(NSColor, CGFloat, CGFloat)] = [(SPColor.categoryBlue.color, 0.12, 0.12), (SPColor.categoryPink.color, 0.88, 0.10)]
        for (color, x, alpha) in blobs {
            let center = NSPoint(x: bounds.width * x, y: 0)
            let gradient = NSGradient(colors: [color.withAlphaComponent(alpha), color.withAlphaComponent(0)])
            NSGraphicsContext.saveGraphicsState()
            // An ellipse: wider than tall, as the mockup's radial gradients.
            let transform = NSAffineTransform()
            transform.translateX(by: center.x, yBy: center.y)
            transform.scaleX(by: 3.5, yBy: 1)
            transform.concat()
            gradient?.draw(fromCenter: .zero, radius: 0, toCenter: .zero, radius: bounds.height * 0.8, options: [])
            NSGraphicsContext.restoreGraphicsState()
        }
    }
    override func viewDidChangeEffectiveAppearance() { needsDisplay = true }
    override func hitTest(_ point: NSPoint) -> NSView? { nil }
}

/// The big search field: 32 pt, a magnifier, the hint as placeholder, an accent border and a 3 pt ring while focused.
/// Its frame includes the ring, so it sits `Style.Sheet.focusRing` outside the field's own edge.
@MainActor
final class SearchBox: NSView {
    let field = NSTextField()
    private let box = NSView()
    private let glass = NSImageView()
    var showsFocus = false { didSet { restyle() } }

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        layer?.cornerRadius = Style.Sheet.searchRadius + Style.Sheet.focusRing
        layer?.cornerCurve = .continuous
        box.wantsLayer = true
        box.layer?.cornerRadius = Style.Sheet.searchRadius
        box.layer?.cornerCurve = .continuous
        box.layer?.borderWidth = 1
        addSubview(box)
        glass.image = symbol("magnifyingglass", size: 13, weight: .medium)
        glass.contentTintColor = Style.secondary
        box.addSubview(glass)
        field.isBordered = false
        field.drawsBackground = false
        field.focusRingType = .none
        field.font = Style.font(SPFont.body)
        field.textColor = Style.label
        field.cell?.isScrollable = true
        field.cell?.wraps = false
        field.placeholderAttributedString = NSAttributedString(string: Strings.ToolsSheet.searchPlaceholder,
                                                               attributes: [.font: Style.font(SPFont.body), .foregroundColor: Style.tertiary])
        field.setAccessibilityLabel(Strings.ToolsSheet.searchPlaceholder)
        box.addSubview(field)
        restyle()
    }

    @available(*, unavailable) required init?(coder: NSCoder) { fatalError() }

    override var isFlipped: Bool { true }

    override func layout() {
        super.layout()
        box.frame = bounds.insetBy(dx: Style.Sheet.focusRing, dy: Style.Sheet.focusRing)
        let b = box.bounds
        glass.frame = NSRect(x: 10, y: (b.height - 16) / 2, width: 16, height: 16)
        let height = ceil(field.intrinsicContentSize.height)
        field.frame = NSRect(x: 34, y: (b.height - height) / 2, width: b.width - 44, height: height)
    }

    override func viewDidChangeEffectiveAppearance() { restyle() }

    private func restyle() {
        effectiveAppearance.performAsCurrentDrawingAppearance {
            layer?.backgroundColor = showsFocus ? Style.accentSoft.cgColor : NSColor.clear.cgColor
            box.layer?.backgroundColor = Style.control.cgColor
            box.layer?.borderColor = (showsFocus ? Style.accent : Style.strongSeparator).cgColor
        }
    }

    override func mouseDown(with event: NSEvent) { window?.makeFirstResponder(field) }
}

/// The sheet's round ✕ (24 pt, a faint fill).
@MainActor
final class CloseButton: NSButton {
    override init(frame: NSRect) {
        super.init(frame: frame)
        isBordered = false
        title = ""
        image = symbol("xmark", size: 10, weight: .bold)
        imagePosition = .imageOnly
        contentTintColor = Style.secondary
        wantsLayer = true
        layer?.cornerRadius = Style.Sheet.closeSize / 2
    }

    @available(*, unavailable) required init?(coder: NSCoder) { fatalError() }

    override func viewDidChangeEffectiveAppearance() { updateLayer() }
    override var wantsUpdateLayer: Bool { true }
    override func updateLayer() {
        effectiveAppearance.performAsCurrentDrawingAppearance { layer?.backgroundColor = Style.faintFill.cgColor }
    }
}

/// A view filled with a colour that follows the appearance.
@MainActor
final class SolidView: NSView {
    var color: () -> NSColor = { .clear } { didSet { needsDisplay = true } }
    override var wantsUpdateLayer: Bool { true }
    override init(frame: NSRect) { super.init(frame: frame); wantsLayer = true }
    @available(*, unavailable) required init?(coder: NSCoder) { fatalError() }
    override func updateLayer() {
        effectiveAppearance.performAsCurrentDrawingAppearance { layer?.backgroundColor = color().cgColor }
    }
}
