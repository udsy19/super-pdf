import AppKit
import PDFKit
import SuperPDFCore

/// The big preview over the workspace (ux §6.2, workspace-preview.png): the page large on a frosted canvas, its file's
/// pill at the top left, ✕ at the top right, and a floating bar with ‹ 5 / 12 ›, rotate left and right, and delete.
/// From a file card it turns that file's pages; from a page card, every page. ← → turn pages, ⌘L ⌘R rotate (the
/// menus), ⌫ deletes, Esc or Space closes.
@MainActor
final class WorkspacePreviewView: NSView {
    struct Actions {
        var close: () -> Void
        var rotate: (_ page: Int, _ quarterTurns: Int) -> Void
        var delete: (_ page: Int) -> Void
    }

    private let actions: Actions
    private let page: (Int) -> PDFPage?
    private let origin: (Int) -> PageOrigin
    /// The pages it turns through (document indices, in order) and where it is among them.
    private(set) var pages: [Int]
    private(set) var position: Int
    private var image: CGImage?
    private var request: ThumbnailRequest?
    private weak var shownPage: PDFPage?
    private var shownMarkup = 0

    private let backdrop: NSView
    private let tint = CanvasTint()
    private let stage = PreviewStage()
    private let pill = PreviewPill()
    private let close = PreviewRoundButton(symbol: "xmark", label: ViewerStrings.Workspace.closePreview)
    private let bar = PreviewBar()

    init(pages: [Int], at position: Int, page: @escaping (Int) -> PDFPage?, origin: @escaping (Int) -> PageOrigin, actions: Actions) {
        self.pages = pages
        self.position = min(max(position, 0), max(pages.count - 1, 0))
        self.page = page
        self.origin = origin
        self.actions = actions
        let effect = NSVisualEffectView()
        effect.blendingMode = .withinWindow
        effect.material = .underWindowBackground
        effect.state = .active
        backdrop = effect
        super.init(frame: .zero)
        wantsLayer = true
        addSubview(backdrop)
        addSubview(tint)
        addSubview(stage)
        addSubview(pill)
        close.onPress = { [weak self] in self?.actions.close() }
        addSubview(close)
        bar.onPrevious = { [weak self] in self?.turn(-1) }
        bar.onNext = { [weak self] in self?.turn(1) }
        bar.onRotateLeft = { [weak self] in self.map { $0.actions.rotate($0.currentPage, -1) } }
        bar.onRotateRight = { [weak self] in self.map { $0.actions.rotate($0.currentPage, 1) } }
        bar.onDelete = { [weak self] in self.map { $0.actions.delete($0.currentPage) } }
        addSubview(bar)
        setAccessibilityElement(true)
        setAccessibilityRole(.group)
        update()
    }

    @available(*, unavailable) required init?(coder: NSCoder) { fatalError() }

    override var isFlipped: Bool { true }
    override var acceptsFirstResponder: Bool { true }

    var currentPage: Int { pages.isEmpty ? 0 : pages[position] }

    /// The pages changed under it (a rotation, a deletion, a move): keep showing the same page, or the one after it.
    func reload(pages: [Int], current: Int?) {
        self.pages = pages
        if let current, let index = pages.firstIndex(of: current) { position = index } else { position = min(position, max(pages.count - 1, 0)) }
        shownPage = nil
        update()
    }

    private func turn(_ delta: Int) {
        let next = position + delta
        guard pages.indices.contains(next) else { NSSound.beep(); return }
        position = next
        update()
    }

    private func update() {
        bar.counter = ViewerStrings.Workspace.counter(position + 1, of: pages.count)
        bar.canGoBack = position > 0
        bar.canGoOn = position < pages.count - 1
        let file = origin(currentPage)
        pill.set(file.fileName, pill: file.pill)
        setAccessibilityLabel(ViewerStrings.Workspace.previewLabel(file.fileName, bar.counter))
        render()
        needsLayout = true
    }

    private func render() {
        guard let page = page(currentPage) else { return }
        let signature = ThumbnailRenderer.markupSignature(of: page)
        let box = page.bounds(for: .cropBox)
        stage.aspect = box.width > 0 && box.height > 0 ? (page.rotation % 180 == 0 ? box.height / box.width : box.width / box.height) : 11 / 8.5
        let pixels = min(Int((max(bounds.width, 600) * (window?.backingScaleFactor ?? 2)).rounded()), 2400)
        if shownPage === page, shownMarkup == signature, image?.width == pixels { return }
        shownPage = page
        shownMarkup = signature
        request?.cancel()
        let renderer = ThumbnailRenderer.shared
        if let cached = renderer.cachedImage(for: page, pixelWidth: pixels) { stage.image = cached; return }
        // The card's smaller picture stands in while the big one renders.
        stage.image = renderer.cachedImage(for: page, pixelWidth: 360) ?? stage.image
        request = renderer.image(for: page, pixelWidth: pixels) { [weak self, weak page] image in
            guard let self, let page, self.shownPage === page else { return }
            self.stage.image = image
        }
    }

    override func layout() {
        super.layout()
        backdrop.frame = bounds
        tint.frame = bounds
        let barSize = bar.fittingSize
        bar.frame = NSRect(x: (bounds.width - barSize.width) / 2, y: bounds.height - 20 - barSize.height, width: barSize.width, height: barSize.height)
        let top: CGFloat = 24, bottom = bar.frame.minY - 16
        let room = NSRect(x: 80, y: top, width: max(bounds.width - 160, 100), height: max(bottom - top, 100))
        var height = room.height, width = height / stage.aspect
        if width > room.width { width = room.width; height = width * stage.aspect }
        stage.frame = NSRect(x: (bounds.width - width) / 2, y: top, width: width, height: height).integral
        let pillSize = pill.fittingSize
        pill.frame = NSRect(x: 20, y: 18, width: min(pillSize.width, max(stage.frame.minX - 32, 120)), height: pillSize.height)
        close.frame = NSRect(x: bounds.width - 20 - 30, y: 18, width: 30, height: 30)
        if window != nil { render() }
    }

    // MARK: Keys and clicks

    override func keyDown(with event: NSEvent) {
        guard let key = event.charactersIgnoringModifiers?.unicodeScalars.first?.value else { return super.keyDown(with: event) }
        switch Int(key) {
        case NSLeftArrowFunctionKey, NSUpArrowFunctionKey: turn(-1)
        case NSRightArrowFunctionKey, NSDownArrowFunctionKey: turn(1)
        case 0x20, 0x1B: actions.close()
        case NSDeleteCharacter, NSDeleteFunctionKey: actions.delete(currentPage)
        default: super.keyDown(with: event)
        }
    }

    override func cancelOperation(_ sender: Any?) { actions.close() }

    /// A click on the backdrop (not the page or the controls) closes it.
    override func mouseUp(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        if !stage.frame.contains(point) { actions.close() }
    }

    override func mouseDown(with event: NSEvent) {}

    // MARK: For the self-test

    var counterText: String { bar.counter }
}

/// The canvas over the blur: the cards show through, softly.
@MainActor
private final class CanvasTint: NSView {
    override func draw(_ dirtyRect: NSRect) {
        SPColor.canvas.color.withAlphaComponent(0.78).setFill()
        dirtyRect.fill()
    }
    override func viewDidChangeEffectiveAppearance() { needsDisplay = true }
}

/// The page, large, with a soft shadow.
@MainActor
private final class PreviewStage: NSView {
    var image: CGImage? { didSet { needsDisplay = true } }
    var aspect: CGFloat = 11 / 8.5 { didSet { if aspect != oldValue { superview?.needsLayout = true } } }

    override var isFlipped: Bool { true }

    override func draw(_ dirtyRect: NSRect) {
        let rect = bounds.insetBy(dx: 2, dy: 2)
        NSGraphicsContext.saveGraphicsState()
        let shadow = NSShadow()
        shadow.shadowColor = NSColor(srgbRed: 20 / 255, green: 40 / 255, blue: 90 / 255, alpha: 0.28)
        shadow.shadowBlurRadius = 30
        shadow.shadowOffset = NSSize(width: 0, height: -12)
        shadow.set()
        NSColor.white.setFill()
        NSBezierPath(roundedRect: rect, xRadius: 6, yRadius: 6).fill()
        NSGraphicsContext.restoreGraphicsState()
        guard let image, let context = NSGraphicsContext.current?.cgContext else { return }
        NSGraphicsContext.saveGraphicsState()
        NSBezierPath(roundedRect: rect, xRadius: 6, yRadius: 6).addClip()
        context.saveGState()
        context.translateBy(x: 0, y: rect.maxY + rect.minY)
        context.scaleBy(x: 1, y: -1)
        context.interpolationQuality = .high
        context.draw(image, in: rect)
        context.restoreGState()
        NSGraphicsContext.restoreGraphicsState()
    }

    override func hitTest(_ point: NSPoint) -> NSView? { nil }
}

/// The file's name in its pill, at the top left.
@MainActor
private final class PreviewPill: NSView {
    private var text = NSAttributedString()
    private var fill: NSColor = .clear

    override var isFlipped: Bool { true }

    func set(_ name: String, pill: SPPill) {
        let paragraph = NSMutableParagraphStyle()
        paragraph.lineBreakMode = .byTruncatingMiddle
        text = NSAttributedString(string: name, attributes: [.font: SPFont.pill.font(), .foregroundColor: pill.ink.color, .paragraphStyle: paragraph])
        fill = pill.fill.color
        needsDisplay = true
    }

    override var fittingSize: NSSize { NSSize(width: ceil(text.size().width) + 24, height: 26) }

    override func draw(_ dirtyRect: NSRect) {
        fill.setFill()
        NSBezierPath(roundedRect: bounds, xRadius: bounds.height / 2, yRadius: bounds.height / 2).fill()
        let size = text.size()
        text.draw(with: NSRect(x: 12, y: (bounds.height - size.height) / 2, width: bounds.width - 24, height: ceil(size.height)),
                  options: [.usesLineFragmentOrigin, .truncatesLastVisibleLine])
    }
}

/// A round white button with a symbol (✕).
@MainActor
final class PreviewRoundButton: NSControl {
    var onPress: (() -> Void)?
    private let symbol: String

    init(symbol: String, label: String) {
        self.symbol = symbol
        super.init(frame: .zero)
        setAccessibilityElement(true)
        setAccessibilityRole(.button)
        setAccessibilityLabel(label)
        toolTip = label
    }

    @available(*, unavailable) required init?(coder: NSCoder) { fatalError() }

    override var isFlipped: Bool { true }

    override func draw(_ dirtyRect: NSRect) {
        NSGraphicsContext.saveGraphicsState()
        let shadow = NSShadow()
        shadow.shadowColor = NSColor.black.withAlphaComponent(0.14)
        shadow.shadowBlurRadius = 6
        shadow.shadowOffset = NSSize(width: 0, height: -2)
        shadow.set()
        SPColor.controlBackground.color.setFill()
        NSBezierPath(ovalIn: bounds.insetBy(dx: 1, dy: 1)).fill()
        NSGraphicsContext.restoreGraphicsState()
        let image = NSImage(systemSymbolName: symbol, accessibilityDescription: nil)?
            .withSymbolConfiguration(.init(pointSize: 11, weight: .bold).applying(.init(paletteColors: [SPColor.label.color])))
        if let image {
            image.draw(in: NSRect(x: bounds.midX - image.size.width / 2, y: bounds.midY - image.size.height / 2, width: image.size.width, height: image.size.height),
                       from: .zero, operation: .sourceOver, fraction: 1, respectFlipped: true, hints: nil)
        }
    }

    override func mouseDown(with event: NSEvent) {}
    override func mouseUp(with event: NSEvent) {
        if bounds.contains(convert(event.locationInWindow, from: nil)) { onPress?() }
    }
    override func accessibilityPerformPress() -> Bool { onPress?(); return true }
}

/// The floating bar: ‹ 5 / 12 › · ⟲ ⟳ · 🗑.
@MainActor
private final class PreviewBar: NSView {
    var onPrevious: (() -> Void)?
    var onNext: (() -> Void)?
    var onRotateLeft: (() -> Void)?
    var onRotateRight: (() -> Void)?
    var onDelete: (() -> Void)?
    var counter = "" { didSet { label.stringValue = counter; label.setAccessibilityLabel(counter) } }
    var canGoBack = false { didSet { previous.isEnabled = canGoBack } }
    var canGoOn = false { didSet { next.isEnabled = canGoOn } }

    private let label = NSTextField(labelWithString: "")
    private lazy var previous = button("chevron.left", ViewerStrings.Workspace.previousPage) { [weak self] in self?.onPrevious?() }
    private lazy var next = button("chevron.right", ViewerStrings.Workspace.nextPage) { [weak self] in self?.onNext?() }
    private lazy var rotateLeft = button("rotate.left", ViewerStrings.PageMenu.rotateLeft) { [weak self] in self?.onRotateLeft?() }
    private lazy var rotateRight = button("rotate.right", ViewerStrings.PageMenu.rotateRight) { [weak self] in self?.onRotateRight?() }
    private lazy var delete = button("trash", ViewerStrings.PageMenu.delete(1), tint: SPColor.categoryRed.color) { [weak self] in self?.onDelete?() }
    private var handlers: [() -> Void] = []

    override init(frame: NSRect) {
        super.init(frame: frame)
        label.font = NSFont.monospacedDigitSystemFont(ofSize: 13, weight: .semibold)
        label.alignment = .center
        label.textColor = SPColor.label.color
        for view in [previous, label, next, rotateLeft, rotateRight, delete] { addSubview(view) }
        setAccessibilityElement(true)
        setAccessibilityRole(.toolbar)
    }

    @available(*, unavailable) required init?(coder: NSCoder) { fatalError() }

    override var isFlipped: Bool { true }

    private func button(_ symbol: String, _ title: String, tint: NSColor? = nil, _ action: @escaping () -> Void) -> NSButton {
        let button = NSButton(image: NSImage(systemSymbolName: symbol, accessibilityDescription: title) ?? NSImage(), target: self, action: #selector(press(_:)))
        button.isBordered = false
        button.symbolConfiguration = .init(pointSize: 15, weight: .medium)
        button.contentTintColor = tint ?? SPColor.label.color
        button.toolTip = title
        button.setAccessibilityLabel(title)
        button.tag = handlers.count
        handlers.append(action)
        return button
    }

    @objc private func press(_ sender: NSButton) { handlers[sender.tag]() }

    override var fittingSize: NSSize { NSSize(width: 6 + 34 + 72 + 34 + 13 + 34 + 34 + 13 + 34 + 6, height: 44) }

    override func layout() {
        super.layout()
        var x: CGFloat = 6
        func place(_ view: NSView, _ width: CGFloat) {
            view.frame = NSRect(x: x, y: (bounds.height - 34) / 2, width: width, height: 34)
            x += width
        }
        place(previous, 34)
        let labelHeight = ceil(label.intrinsicContentSize.height)
        label.frame = NSRect(x: x, y: (bounds.height - labelHeight) / 2, width: 72, height: labelHeight)
        x += 72
        place(next, 34)
        x += 13
        place(rotateLeft, 34)
        place(rotateRight, 34)
        x += 13
        place(delete, 34)
    }

    override func draw(_ dirtyRect: NSRect) {
        let capsule = NSBezierPath(roundedRect: bounds.insetBy(dx: 0.5, dy: 0.5), xRadius: bounds.height / 2, yRadius: bounds.height / 2)
        NSGraphicsContext.saveGraphicsState()
        let shadow = NSShadow()
        shadow.shadowColor = NSColor(srgbRed: 20 / 255, green: 40 / 255, blue: 90 / 255, alpha: 0.2)
        shadow.shadowBlurRadius = 16
        shadow.shadowOffset = NSSize(width: 0, height: -6)
        shadow.set()
        SPColor.controlBackground.color.setFill()
        capsule.fill()
        NSGraphicsContext.restoreGraphicsState()
        SPColor.separator.color.setFill()
        for x in [6 + 34 + 72 + 34 + 6, 6 + 34 + 72 + 34 + 13 + 68 + 6] {
            NSRect(x: CGFloat(x), y: (bounds.height - 22) / 2, width: 1, height: 22).fill()
        }
    }
}
