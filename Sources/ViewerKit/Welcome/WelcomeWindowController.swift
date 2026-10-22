import AppKit
import SuperPDFCore

/// The welcome window (ux §6.1, welcome.png): 760 × 520, not resizable, centred, on a soft wash of the brand colours.
/// The app's multicolour mark and name, one friendly sentence, four big colourful targets — Open a PDF, Combine files,
/// Scan, Convert a file — the recent files and a tip about dropping. Dropping files anywhere does the obvious thing: one
/// file opens (converted first if needed), several open the workspace to combine them (ux §6.2).
@MainActor
final class WelcomeWindowController: NSWindowController, NSWindowDelegate {
    private unowned let viewer: Viewer
    let welcomeView: WelcomeView

    init(viewer: Viewer) {
        self.viewer = viewer
        let window = NSWindow(contentRect: NSRect(origin: .zero, size: SPMetrics.Welcome.size),
                              styleMask: [.titled, .closable, .miniaturizable, .fullSizeContentView], backing: .buffered, defer: true)
        window.titlebarAppearsTransparent = true
        window.titleVisibility = .hidden
        window.title = Strings.appName
        window.isMovableByWindowBackground = true
        window.isRestorable = false
        welcomeView = WelcomeView(frame: NSRect(origin: .zero, size: SPMetrics.Welcome.size))
        window.contentView = welcomeView
        window.setContentSize(SPMetrics.Welcome.size)
        window.center()
        super.init(window: window)
        window.delegate = self
        welcomeView.controller = self
        reloadRecents()
    }

    required init?(coder: NSCoder) { fatalError("not used") }

    override func showWindow(_ sender: Any?) {
        reloadRecents()
        guard viewer.environment.showsWindows else { return }
        super.showWindow(sender)
    }

    func reloadRecents() {
        welcomeView.recents = Services.documents?.recentDocuments ?? []
    }

    // MARK: Targets

    func openPDF() { viewer.environment.openDocumentPanel() }

    func chooseFilesToCombine() {
        Task {
            let urls = await viewer.environment.chooseFiles([], true, window)
            if urls.count == 1 { viewer.open(urls, from: window) } else if !urls.isEmpty { await combine(urls) }
        }
    }

    func scan() { Services.tools?.openPanel(.scanWithIPhone, for: nil, inputs: []) }

    func chooseFileToConvert() {
        Task {
            let urls = await viewer.environment.chooseFiles([], false, window)
            viewer.open(urls, from: window)
        }
    }

    func open(_ recent: RecentDocument) { viewer.open([recent.url], from: window) }

    func reveal(_ recent: RecentDocument) { viewer.environment.revealInFinder([recent.url]) }

    func remove(_ recent: RecentDocument) {
        Services.documents?.removeRecent(recent.url)
        reloadRecents()
    }

    func drop(_ decision: DropDecision) {
        switch decision.outcome {
        case .open(let urls): viewer.open(urls, from: window)
        case .combine(let urls): Task { await combine(urls) }
        default: break
        }
    }

    /// Several files: the workspace, a card per file (ux §6.1, §6.2); the window says when it is still reading them.
    func combine(_ urls: [URL]) async {
        await viewer.combine(urls, from: window) { [weak self] working in self?.welcomeView.isWorking = working }
    }
}

/// The welcome window's content, laid out to welcome.png: everything centred on the 760 pt window.
final class WelcomeView: NSView {
    weak var controller: WelcomeWindowController?
    var recents: [RecentDocument] = [] { didSet { layoutRecents() } }
    /// The first file of a combine is converting before the workspace can open.
    var isWorking = false { didSet { dropOverlay.isWorking = isWorking; dropOverlay.isHidden = !isWorking } }
    private(set) var targets: [WelcomeTargetView] = []
    private let recentHeader = NSTextField(labelWithString: ViewerStrings.Welcome.recent)
    private let recentScroll = NSScrollView()
    private let recentList = FlippedView()
    private let emptyLabel = NSTextField(labelWithString: Strings.Empty.welcomeRecents)
    private let tip = NSTextField(labelWithString: ViewerStrings.Welcome.dropTip)
    private let tipIcon = NSImageView()
    let dropOverlay = WelcomeDropView()

    // Positions from welcome.html: 26 pt top padding, the 56 pt mark, 28 pt title, 15 pt subtitle, 160 × 140 targets 16 pt
    // apart, "Recent" 22 pt below them, 36 pt rows, the tip 18 pt above the bottom.
    static let targetTop: CGFloat = 174
    static let recentTop: CGFloat = 336
    static let rowsTop: CGFloat = 359
    static let tipBottom: CGFloat = 18
    static var contentWidth: CGFloat { 4 * SPMetrics.Welcome.targetSize.width + 3 * 16 }

    override var isFlipped: Bool { true }

    override init(frame: NSRect) {
        super.init(frame: frame)
        let side = ((frame.width - Self.contentWidth) / 2).rounded()
        let specs: [(String, String, String, SPColorToken, String?)] = [
            ("doc.fill", ViewerStrings.Welcome.open, ViewerStrings.Welcome.openHint, SPColor.brand, "⌘O"),
            ("doc.on.doc.fill", ViewerStrings.Welcome.combine, ViewerStrings.Welcome.combineHint, ToolSection.pages.color, nil),
            ("scanner.fill", ViewerStrings.Welcome.scan, ViewerStrings.Welcome.scanHint, ToolSection.scan.color, nil),
            ("arrow.triangle.2.circlepath", ViewerStrings.Welcome.convert, ViewerStrings.Welcome.convertHint, ToolSection.convert.color, nil),
        ]
        for (index, spec) in specs.enumerated() {
            let target = WelcomeTargetView(symbol: spec.0, title: spec.1, hint: spec.2, color: spec.3, shortcut: spec.4)
            target.frame = NSRect(x: side + CGFloat(index) * (SPMetrics.Welcome.targetSize.width + 16), y: Self.targetTop,
                                  width: SPMetrics.Welcome.targetSize.width, height: SPMetrics.Welcome.targetSize.height)
            target.onPress = { [weak self] in self?.press(index) }
            addSubview(target)
            targets.append(target)
        }
        recentHeader.font = SPFont.sectionHeader.font()
        recentHeader.textColor = SPColor.secondaryLabel.color
        recentHeader.frame = NSRect(x: side, y: Self.recentTop, width: 200, height: 17)
        addSubview(recentHeader)
        let tipTop = frame.height - Self.tipBottom - 16
        recentScroll.frame = NSRect(x: side, y: Self.rowsTop, width: Self.contentWidth, height: tipTop - Self.rowsTop - 6)
        recentScroll.documentView = recentList
        recentScroll.drawsBackground = false
        recentScroll.hasVerticalScroller = true
        recentScroll.autohidesScrollers = true
        addSubview(recentScroll)
        emptyLabel.font = SPFont.body.font()
        emptyLabel.textColor = SPColor.tertiaryLabel.color
        emptyLabel.frame = NSRect(x: side + 8, y: Self.rowsTop + 9, width: Self.contentWidth, height: 18)
        addSubview(emptyLabel)
        tip.font = SPFont.secondary.font()
        tip.textColor = SPColor.secondaryLabel.color
        tip.sizeToFit()
        tipIcon.image = NSImage(systemSymbolName: "arrow.down.doc", accessibilityDescription: nil)?
            .withSymbolConfiguration(.init(pointSize: 11, weight: .semibold))
        tipIcon.contentTintColor = SPColor.brand.color
        let tipWidth = 16 + 4 + tip.frame.width
        tipIcon.frame = NSRect(x: (frame.width - tipWidth) / 2, y: tipTop, width: 16, height: 16)
        tip.frame.origin = NSPoint(x: tipIcon.frame.maxX + 4, y: tipTop + (16 - tip.frame.height) / 2)
        addSubview(tipIcon)
        addSubview(tip)
        dropOverlay.isHidden = true
        dropOverlay.frame = bounds.insetBy(dx: 8, dy: 8)
        addSubview(dropOverlay)
        registerForDraggedTypes([.fileURL])
        layoutRecents()
    }

    required init?(coder: NSCoder) { fatalError("not used") }

    private func press(_ index: Int) {
        switch index {
        case 0: controller?.openPDF()
        case 1: controller?.chooseFilesToCombine()
        case 2: controller?.scan()
        default: controller?.chooseFileToConvert()
        }
    }

    private func layoutRecents() {
        recentList.subviews.forEach { $0.removeFromSuperview() }
        let rowHeight = SPMetrics.Welcome.recentRowHeight
        for (index, recent) in recents.enumerated() {
            let row = RecentRowView(recent)
            row.frame = NSRect(x: 0, y: CGFloat(index) * rowHeight, width: Self.contentWidth, height: rowHeight)
            row.onOpen = { [weak self] in self?.controller?.open(recent) }
            row.onReveal = { [weak self] in self?.controller?.reveal(recent) }
            row.onRemove = { [weak self] in self?.controller?.remove(recent) }
            recentList.addSubview(row)
        }
        recentList.frame = NSRect(x: 0, y: 0, width: Self.contentWidth, height: max(CGFloat(recents.count) * rowHeight, recentScroll.bounds.height))
        emptyLabel.isHidden = !recents.isEmpty
    }

    override func draw(_ dirtyRect: NSRect) {
        SPColor.windowBackground.color.setFill()
        dirtyRect.fill()
        drawWash()
        drawMark()
        let title = NSAttributedString(string: Strings.appName, attributes: [.font: SPFont.welcomeTitle.font(), .foregroundColor: SPColor.label.color,
                                                                             .kern: -0.56])
        let titleSize = title.size()
        title.draw(at: NSPoint(x: (bounds.width - titleSize.width) / 2, y: 92 + (36 - titleSize.height) / 2))
        let subtitle = NSAttributedString(string: ViewerStrings.Welcome.subtitle,
                                          attributes: [.font: SPFont.welcomeSubtitle.font(), .foregroundColor: SPColor.secondaryLabel.color])
        let subtitleSize = subtitle.size()
        subtitle.draw(at: NSPoint(x: (bounds.width - subtitleSize.width) / 2, y: 132 + (19.5 - subtitleSize.height) / 2))
    }

    /// Soft pools of the brand colours along the top (welcome.html's radial gradients).
    private func drawWash() {
        let pools: [(NSColor, CGFloat, CGFloat, CGFloat)] = [
            (SPColor.categoryBlue.color, 0.08, 360, 0.14), (SPColor.categoryPink.color, 0.94, 340, 0.12), (SPColor.brand.color, 0.5, 420, 0.09),
        ]
        for (color, x, width, alpha) in pools {
            NSGraphicsContext.saveGraphicsState()
            let transform = NSAffineTransform()
            transform.translateX(by: bounds.width * x, yBy: 0)
            transform.scaleX(by: width / 200, yBy: 1)
            transform.concat()
            NSGradient(colors: [color.withAlphaComponent(alpha), color.withAlphaComponent(0)])?
                .draw(fromCenter: .zero, radius: 0, toCenter: .zero, radius: 200, options: [])
            NSGraphicsContext.restoreGraphicsState()
        }
    }

    /// The mark: a rounded square washing from blue through the app's indigo and violet to pink, with a white page.
    private func drawMark() {
        let rect = NSRect(x: (bounds.width - 56) / 2, y: 26, width: 56, height: 56)
        let path = NSBezierPath(roundedRect: rect, xRadius: 15, yRadius: 15)
        NSGraphicsContext.saveGraphicsState()
        let shadow = NSShadow()
        shadow.shadowColor = SPColor.brand.color.withAlphaComponent(0.4)
        shadow.shadowBlurRadius = 16
        shadow.shadowOffset = NSSize(width: 0, height: -6)
        shadow.set()
        SPColor.brand.color.setFill()
        path.fill()
        NSGraphicsContext.restoreGraphicsState()
        let colors = [NSColor(hex: "#6E8BFF"), SPColor.brand.color, NSColor(hex: "#B05CF0"), SPColor.categoryPink.color]
        NSGradient(colors: colors, atLocations: [0, 0.45, 0.8, 1], colorSpace: .sRGB)?.draw(in: path, angle: 55)
        NSGradient(starting: NSColor.white.withAlphaComponent(0.22), ending: NSColor.white.withAlphaComponent(0))?
            .draw(in: NSBezierPath(roundedRect: rect.insetBy(dx: 1, dy: 1), xRadius: 14, yRadius: 14), angle: 90)
        if let glyph = SPIcon.glyphImage("doc.text.fill", size: 25, weight: .medium) {
            let size = glyph.size
            glyph.draw(in: NSRect(x: rect.midX - size.width / 2, y: rect.midY - size.height / 2, width: size.width, height: size.height),
                       from: .zero, operation: .sourceOver, fraction: 1, respectFlipped: true, hints: nil)
        }
    }

    // MARK: Drops anywhere in the window (ux §3, §6.1)

    private func decision(_ info: NSDraggingInfo) -> DropDecision {
        guard let urls = info.draggingPasteboard.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as? [URL],
              !urls.isEmpty else { return DropDecision(.none) }
        let files = urls.map { DroppedFile(url: $0, canConvert: { Services.convert?.canConvertToPDF($0) ?? false }) }
        return DropDecision.decide(.files(files), onto: .welcome)
    }

    override func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation { highlight(sender) }
    override func draggingUpdated(_ sender: NSDraggingInfo) -> NSDragOperation { highlight(sender) }
    override func draggingExited(_ sender: NSDraggingInfo?) { if !isWorking { dropOverlay.isHidden = true } }

    private func highlight(_ info: NSDraggingInfo) -> NSDragOperation {
        guard !isWorking else { return [] }
        let decision = decision(info)
        switch decision.outcome {
        case .open, .combine:
            if case .combine(let urls) = decision.outcome {
                dropOverlay.label = ViewerStrings.Welcome.dropToCombine(urls.count)
            } else {
                dropOverlay.label = ViewerStrings.Welcome.dropToOpen
            }
            dropOverlay.isRefusal = false
            show(dropOverlay)
            return .copy
        case .refuse(let reason):
            dropOverlay.label = reason
            dropOverlay.isRefusal = true
            show(dropOverlay)
            return []
        default:
            dropOverlay.isHidden = true
            return []
        }
    }

    private func show(_ overlay: WelcomeDropView) {
        guard overlay.isHidden else { return }
        overlay.isHidden = false
        overlay.bounce()
    }

    override func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
        dropOverlay.isHidden = true
        let decision = decision(sender)
        guard decision.isAllowed else { return false }
        controller?.drop(decision)
        return true
    }
}

final class FlippedView: NSView {
    override var isFlipped: Bool { true }
}

/// The welcome window's drop target: a dashed, tinted card over the window with a bobbing arrow in an accent circle and
/// what the drop will do ("Drop to combine 3 files"); or a refusal with its reason; or "Getting your files ready…" with
/// a spinner while the first file converts.
final class WelcomeDropView: NSView {
    var label = "" { didSet { needsDisplay = true } }
    var isRefusal = false { didSet { needsDisplay = true } }
    var isWorking = false {
        didSet {
            label = isWorking ? ViewerStrings.Welcome.gettingReady : label
            isRefusal = false
            if isWorking { spinner.startAnimation(nil) } else { spinner.stopAnimation(nil) }
            needsDisplay = true
        }
    }
    private let spinner = NSProgressIndicator()

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        spinner.style = .spinning
        spinner.isDisplayedWhenStopped = false
        addSubview(spinner)
    }

    required init?(coder: NSCoder) { fatalError("not used") }

    override var isFlipped: Bool { true }
    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    private var circle: NSRect { NSRect(x: bounds.midX - 32, y: bounds.midY - 56, width: 64, height: 64) }

    override func layout() {
        super.layout()
        spinner.frame = circle.insetBy(dx: 16, dy: 16)
    }

    override func draw(_ dirtyRect: NSRect) {
        let accent = isRefusal ? SPColor.secondaryLabel.color : SPColor.accent.color
        let card = NSBezierPath(roundedRect: bounds.insetBy(dx: 1, dy: 1), xRadius: 18, yRadius: 18)
        SPColor.windowBackground.color.withAlphaComponent(0.92).setFill()
        card.fill()
        accent.withAlphaComponent(0.07).setFill()
        card.fill()
        card.lineWidth = 2.5
        card.setLineDash([9, 6], count: 2, phase: 0)
        accent.withAlphaComponent(0.6).setStroke()
        card.stroke()
        if !isWorking {
            NSGraphicsContext.saveGraphicsState()
            let shadow = NSShadow()
            shadow.shadowColor = accent.withAlphaComponent(0.4)
            shadow.shadowBlurRadius = 14
            shadow.shadowOffset = NSSize(width: 0, height: -5)
            shadow.set()
            accent.setFill()
            NSBezierPath(ovalIn: circle).fill()
            NSGraphicsContext.restoreGraphicsState()
            if let arrow = SPIcon.glyphImage(isRefusal ? "nosign" : "arrow.down", size: 26, weight: .bold) {
                arrow.draw(in: NSRect(x: circle.midX - arrow.size.width / 2, y: circle.midY - arrow.size.height / 2, width: arrow.size.width, height: arrow.size.height),
                           from: .zero, operation: .sourceOver, fraction: 1, respectFlipped: true, hints: nil)
            }
        }
        let paragraph = NSMutableParagraphStyle()
        paragraph.alignment = .center
        let text = NSAttributedString(string: label, attributes: [.font: NSFont.systemFont(ofSize: 17, weight: .semibold), .foregroundColor: SPColor.label.color,
                                                                  .paragraphStyle: paragraph])
        text.draw(with: NSRect(x: 40, y: circle.maxY + 18, width: bounds.width - 80, height: 48), options: [.usesLineFragmentOrigin])
    }

    /// The arrow circle drops in with a bounce (not with Reduce Motion).
    func bounce() {
        needsDisplay = true
        guard let layer, !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion else { return }
        let fade = CABasicAnimation(keyPath: "opacity")
        fade.fromValue = 0
        fade.toValue = 1
        fade.duration = 0.15
        layer.add(fade, forKey: "fade")
    }
}

/// One of the four big targets: 160 × 140, 14 pt radius, a 40 pt rounded square in its colour with a white symbol, the
/// label 15 pt semibold and the hint 11 pt; hover borders it in its colour and lifts it on a spring (welcome.png).
final class WelcomeTargetView: NSControl {
    private let symbol: String
    private let title: String
    private let hint: String
    private let color: SPColorToken
    private let shortcut: String?
    var onPress: (() -> Void)?
    var isHovered = false { didSet { if isHovered != oldValue { needsDisplay = true; lift() } } }

    init(symbol: String, title: String, hint: String, color: SPColorToken, shortcut: String?) {
        self.symbol = symbol; self.title = title; self.hint = hint; self.color = color; self.shortcut = shortcut
        super.init(frame: .zero)
        wantsLayer = true
        setAccessibilityRole(.button)
        setAccessibilityLabel(title)
        setAccessibilityHelp(hint)
    }

    required init?(coder: NSCoder) { fatalError("not used") }

    override var isFlipped: Bool { true }
    override var acceptsFirstResponder: Bool { true }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        trackingAreas.forEach(removeTrackingArea)
        addTrackingArea(NSTrackingArea(rect: bounds, options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect], owner: self, userInfo: nil))
    }

    override func mouseEntered(with event: NSEvent) { isHovered = true }
    override func mouseExited(with event: NSEvent) { isHovered = false }
    override func mouseDown(with event: NSEvent) { onPress?() }
    override func accessibilityPerformPress() -> Bool { onPress?(); return true }

    override func keyDown(with event: NSEvent) {
        if event.keyCode == 36 || event.keyCode == 49 { onPress?() } else { super.keyDown(with: event) }
    }

    /// Hover grows the card a touch on a lively spring (scaled about its middle); Reduce Motion keeps it still.
    private func lift() {
        guard let layer, !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion else { return }
        let scale: CGFloat = isHovered ? 1.03 : 1
        var transform = CATransform3DMakeTranslation(bounds.width / 2, bounds.height / 2, 0)
        transform = CATransform3DScale(transform, scale, scale, 1)
        transform = CATransform3DTranslate(transform, -bounds.width / 2, -bounds.height / 2, 0)
        let from = layer.presentation()?.transform ?? layer.transform
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        layer.transform = transform
        CATransaction.commit()
        layer.add(SPMotion.hoverSpring.animation("transform", from: NSValue(caTransform3D: from), to: NSValue(caTransform3D: transform)), forKey: "hover")
    }

    override func draw(_ dirtyRect: NSRect) {
        let tint = color.color
        let card = bounds.insetBy(dx: 0.75, dy: 0.75).offsetBy(dx: 0, dy: isHovered ? -SPMetrics.Tile.hoverLift : 0)
        let path = NSBezierPath(roundedRect: card, xRadius: SPMetrics.Welcome.targetRadius, yRadius: SPMetrics.Welcome.targetRadius)
        NSGraphicsContext.saveGraphicsState()
        let shadow = NSShadow()
        shadow.shadowColor = isHovered ? tint.withAlphaComponent(0.25) : NSColor.black.withAlphaComponent(0.05)
        shadow.shadowBlurRadius = isHovered ? 18 : 2
        shadow.shadowOffset = NSSize(width: 0, height: isHovered ? -8 : -1)
        shadow.set()
        SPColor.controlBackground.color.setFill()
        path.fill()
        NSGraphicsContext.restoreGraphicsState()
        path.lineWidth = isHovered ? 1.5 : 1
        (isHovered ? tint : SPColor.separator.color).setStroke()
        path.stroke()

        let d = SPMetrics.Welcome.targetIcon
        let icon = NSRect(x: card.minX + 14, y: card.minY + 16, width: d, height: d)
        SPIcon.draw(symbol, color: tint, in: icon, radius: SPMetrics.Welcome.targetIconRadius, glyph: SPMetrics.Tile.symbolSize + 1)
        let name = NSAttributedString(string: title, attributes: [.font: SPFont.welcomeTarget.font(), .foregroundColor: SPColor.label.color])
        name.draw(at: NSPoint(x: card.minX + 14, y: icon.maxY + 12))
        let paragraph = NSMutableParagraphStyle()
        paragraph.lineHeightMultiple = 1.15
        paragraph.lineBreakMode = .byWordWrapping
        let hintText = NSAttributedString(string: hint, attributes: [.font: SPFont.tileHint.font(), .foregroundColor: SPColor.secondaryLabel.color,
                                                                     .paragraphStyle: paragraph])
        hintText.draw(with: NSRect(x: card.minX + 14, y: icon.maxY + 12 + 22, width: card.width - 28, height: card.maxY - icon.maxY - 34),
                      options: [.usesLineFragmentOrigin])
        if let shortcut {
            let key = NSAttributedString(string: shortcut, attributes: [.font: NSFont.systemFont(ofSize: 10), .foregroundColor: SPColor.tertiaryLabel.color])
            let size = key.size()
            key.draw(at: NSPoint(x: card.maxX - 12 - size.width, y: card.minY + 12))
        }
    }
}

/// A recent file: 36 pt, a 24 pt page picture, the name at 13 pt and when · pages · size at 11 pt; hover highlights;
/// right-click offers Show in Finder and Remove from list (ux §6.1).
final class RecentRowView: NSView {
    let recent: RecentDocument
    var onOpen: (() -> Void)?
    var onReveal: (() -> Void)?
    var onRemove: (() -> Void)?
    var isHovered = false { didSet { needsDisplay = true } }
    private var picture: CGImage?

    init(_ recent: RecentDocument) {
        self.recent = recent
        super.init(frame: .zero)
        setAccessibilityRole(.button)
        setAccessibilityLabel(recent.name)
        RecentThumbnails.image(for: recent.url) { [weak self] image in
            self?.picture = image
            self?.needsDisplay = true
        }
    }

    required init?(coder: NSCoder) { fatalError("not used") }

    override var isFlipped: Bool { true }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        trackingAreas.forEach(removeTrackingArea)
        addTrackingArea(NSTrackingArea(rect: bounds, options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect], owner: self, userInfo: nil))
    }

    override func mouseEntered(with event: NSEvent) { isHovered = true }
    override func mouseExited(with event: NSEvent) { isHovered = false }
    override func mouseUp(with event: NSEvent) { onOpen?() }
    override func accessibilityPerformPress() -> Bool { onOpen?(); return true }

    override func menu(for event: NSEvent) -> NSMenu? {
        let menu = NSMenu()
        for (title, action) in [(ViewerStrings.Welcome.showInFinder, onReveal), (ViewerStrings.Welcome.removeFromList, onRemove)] {
            let handler = MenuAction { action?() }
            let item = NSMenuItem(title: title, action: #selector(MenuAction.run(_:)), keyEquivalent: "")
            item.target = handler
            item.representedObject = handler
            menu.addItem(item)
        }
        return menu
    }

    override func draw(_ dirtyRect: NSRect) {
        if isHovered {
            SPColor.accent.color.withAlphaComponent(0.08).setFill()
            NSBezierPath(roundedRect: bounds, xRadius: 8, yRadius: 8).fill()
        }
        let thumb = NSRect(x: 8 + 2, y: (bounds.height - 24) / 2, width: 20, height: 24)
        NSColor.white.setFill()
        thumb.fill()
        if let picture, let context = NSGraphicsContext.current?.cgContext {
            context.saveGState()
            context.translateBy(x: 0, y: thumb.maxY + thumb.minY)
            context.scaleBy(x: 1, y: -1)
            let aspect = CGFloat(picture.height) / CGFloat(picture.width)
            let height = min(thumb.height, thumb.width * aspect)
            context.draw(picture, in: NSRect(x: thumb.minX, y: thumb.midY - height / 2, width: thumb.width, height: height))
            context.restoreGState()
        } else {
            NSColor(white: 0.73, alpha: 1).setFill()
            for line in 0..<4 { NSRect(x: thumb.minX + 3, y: thumb.minY + 5 + CGFloat(line) * 3, width: thumb.width - 6, height: 1).fill() }
        }
        NSColor.black.withAlphaComponent(0.16).setStroke()
        NSBezierPath(rect: thumb.insetBy(dx: 0.5, dy: 0.5)).stroke()

        let name = NSAttributedString(string: recent.name, attributes: [.font: SPFont.body.font(), .foregroundColor: SPColor.label.color])
        let metaFont = SPFont.secondary.font()
        let meta = [RecentDates.string(for: recent.lastOpened), ViewerStrings.pages(recent.pageCount), Formatting.bytes(recent.fileSize)]
        var x = bounds.width - 13
        for (index, text) in meta.enumerated().reversed() {
            let string = NSAttributedString(string: text, attributes: [.font: metaFont, .foregroundColor: SPColor.secondaryLabel.color])
            let size = string.size()
            x -= size.width
            string.draw(at: NSPoint(x: x, y: (bounds.height - size.height) / 2))
            x -= index > 0 ? 18 + 10 : 0
        }
        let nameSize = name.size()
        name.draw(with: NSRect(x: thumb.maxX + 10 + 6, y: (bounds.height - nameSize.height) / 2, width: max(0, x - thumb.maxX - 40), height: nameSize.height),
                  options: [.usesLineFragmentOrigin, .truncatesLastVisibleLine])
    }
}

/// "Yesterday, 4:12 PM", "Monday", "12 Sep" (welcome.png), in the person's locale.
public enum RecentDates {
    public static func string(for date: Date, now: Date = Date(), calendar: Calendar = .current, locale: Locale = .current) -> String {
        let time = DateFormatter()
        time.locale = locale
        time.calendar = calendar
        time.timeZone = calendar.timeZone
        time.timeStyle = .short
        time.dateStyle = .none
        let startToday = calendar.startOfDay(for: now)
        let days = calendar.dateComponents([.day], from: calendar.startOfDay(for: date), to: startToday).day ?? 0
        if days <= 1 {
            // DateFormatter's relative words ("Today", "Yesterday") count from the real clock, not `now`, so ask it about
            // the same distance from the real today.
            let relative = DateFormatter()
            relative.locale = locale
            relative.dateStyle = .medium
            relative.timeStyle = .none
            relative.doesRelativeDateFormatting = true
            let word = relative.string(from: Calendar.current.date(byAdding: .day, value: -days, to: Date()) ?? date)
            return "\(word), \(time.string(from: date))"
        }
        let formatter = DateFormatter()
        formatter.locale = locale
        formatter.calendar = calendar
        if days < 7 {
            formatter.setLocalizedDateFormatFromTemplate("EEEE")
        } else if calendar.component(.year, from: date) == calendar.component(.year, from: now) {
            formatter.setLocalizedDateFormatFromTemplate("dMMM")
        } else {
            formatter.setLocalizedDateFormatFromTemplate("dMMMyyyy")
        }
        return formatter.string(from: date)
    }
}

/// First-page pictures for the recents, rendered off the main thread from the file (encrypted files keep the plain icon).
@MainActor
enum RecentThumbnails {
    private static let cache = NSCache<NSURL, CGImageBox>()
    private static let queue = DispatchQueue(label: "com.udsy.superpdf.recent-thumbnails", qos: .utility)

    static func image(for url: URL, completion: @escaping @MainActor (CGImage) -> Void) {
        if let cached = cache.object(forKey: url as NSURL) { completion(cached.image); return }
        queue.async {
            guard let document = CGPDFDocument(url as CFURL), !document.isEncrypted, let page = document.page(at: 1) else { return }
            let box = page.getBoxRect(.cropBox)
            let width = 48
            let height = max(1, Int(CGFloat(width) * box.height / max(box.width, 1)))
            guard let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                                          space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue) else { return }
            context.setFillColor(CGColor(gray: 1, alpha: 1))
            context.fill(CGRect(x: 0, y: 0, width: width, height: height))
            context.scaleBy(x: CGFloat(width) / box.width, y: CGFloat(height) / box.height)
            context.translateBy(x: -box.minX, y: -box.minY)
            context.drawPDFPage(page)
            guard let image = context.makeImage() else { return }
            let boxed = CGImageBox(image)
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    cache.setObject(boxed, forKey: url as NSURL)
                    completion(boxed.image)
                }
            }
        }
    }
}
