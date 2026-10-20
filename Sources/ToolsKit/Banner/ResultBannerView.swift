import AppKit
import SuperPDFCore

/// What the banner's buttons reach outside ToolsKit. The self-test swaps these so nothing opens Finder or another app.
@MainActor
enum ToolsKitSystem {
    static var reveal: ([URL]) -> Void = { NSWorkspace.shared.activateFileViewerSelecting($0) }
    /// "Open in Word": the file in the app that owns it.
    static var openInApp: (URL, String) -> Void = { file, _ in
        guard let app = NSWorkspace.shared.urlForApplication(toOpen: file) else { return }
        NSWorkspace.shared.open([file], withApplicationAt: app, configuration: NSWorkspace.OpenConfiguration())
    }
    static var share: (URL, NSView) -> Void = { file, button in
        NSSharingServicePicker(items: [file]).show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
    }
}

/// The result banner (ux §7.3, mockup main-window-result): 44 pt under the toolbar, a green check, one sentence with
/// its numbers in semibold, and up to three small buttons on the right. It hides after 8 s unless the pointer is
/// inside, or when clicked; ⌘-click reveals the file in Finder.
@MainActor
final class ResultBannerView: NSView {
    let banner: ResultBanner
    private weak var document: DocumentHandle?
    private let dismiss: () -> Void
    private let showDetails: () -> Void
    private let icon = NSView()
    private let check = NSImageView()
    private let text = NSTextField(labelWithString: "")
    private(set) var buttons: [BannerButton] = []
    private let separator = SolidView()
    private var timer: Timer?
    private var pointerInside = false
    private var expired = false

    init(banner: ResultBanner, document: DocumentHandle?, showDetails: @escaping () -> Void, dismiss: @escaping () -> Void) {
        self.banner = banner
        self.document = document
        self.showDetails = showDetails
        self.dismiss = dismiss
        super.init(frame: NSRect(x: 0, y: 0, width: 600, height: SPMetrics.Banner.height))
        wantsLayer = true
        icon.wantsLayer = true
        icon.layer?.cornerRadius = 11
        addSubview(icon)
        check.image = symbol("checkmark", size: 11, weight: .heavy)
        check.contentTintColor = .white
        icon.addSubview(check)
        text.attributedStringValue = emphasised(banner.text, banner.emphasis, font: Style.font(SPFont.banner),
                                                bold: Style.font(SPFont.bannerEmphasis), color: Style.label)
        text.lineBreakMode = .byTruncatingTail
        text.cell?.truncatesLastVisibleLine = true
        addSubview(text)
        for action in banner.actions.prefix(3) {
            let button = BannerButton(title: action.title, symbol: action == .share ? "square.and.arrow.up" : nil)
            button.target = self
            button.action = #selector(pressed(_:))
            button.tag = buttons.count
            buttons.append(button)
            addSubview(button)
        }
        separator.color = { Style.separator }
        addSubview(separator)
        setAccessibilityElement(true)
        setAccessibilityRole(.group)
        setAccessibilityLabel(banner.text)
        restyle()
    }

    @available(*, unavailable) required init?(coder: NSCoder) { fatalError() }

    override var isFlipped: Bool { true }
    override var intrinsicContentSize: NSSize { NSSize(width: NSView.noIntrinsicMetric, height: SPMetrics.Banner.height) }

    override func layout() {
        super.layout()
        let h = bounds.height - SPMetrics.Banner.separator
        icon.frame = NSRect(x: 16, y: (h - 22) / 2, width: 22, height: 22)
        check.frame = icon.bounds
        var right = bounds.width - 16
        for button in buttons.reversed() {
            let width = button.fittingWidth
            button.frame = NSRect(x: right - width, y: (h - 22) / 2, width: width, height: 22)
            right -= width + 6
        }
        let size = text.intrinsicContentSize
        text.frame = NSRect(x: icon.frame.maxX + 10 - 2, y: (h - size.height) / 2, width: max(right - 10 - icon.frame.maxX - 6, 0),
                            height: size.height)
        separator.frame = NSRect(x: 0, y: h, width: bounds.width, height: SPMetrics.Banner.separator)
    }

    override func viewDidChangeEffectiveAppearance() { restyle() }

    private func restyle() {
        effectiveAppearance.performAsCurrentDrawingAppearance {
            layer?.backgroundColor = Style.control.cgColor
            icon.layer?.backgroundColor = SPColor.categoryGreen.color.cgColor
        }
    }

    // MARK: Hiding

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        timer?.invalidate()
        guard window != nil else { return }
        timer = Timer.scheduledTimer(withTimeInterval: SPMetrics.Banner.autoHideDelay, repeats: false) { [weak self] _ in
            MainActor.assumeIsolated { self?.expire() }
        }
    }

    private func expire() {
        expired = true
        if !pointerInside { dismiss() }
    }

    private var tracking: NSTrackingArea?
    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let tracking { removeTrackingArea(tracking) }
        let area = NSTrackingArea(rect: bounds, options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect], owner: self)
        addTrackingArea(area)
        tracking = area
    }

    override func mouseEntered(with event: NSEvent) { pointerInside = true }
    override func mouseExited(with event: NSEvent) {
        pointerInside = false
        if expired { dismiss() }
    }

    override func mouseUp(with event: NSEvent) {
        if event.modifierFlags.contains(.command), let file = banner.file { ToolsKitSystem.reveal([file]) }
        dismiss()
    }

    // MARK: Actions

    @objc private func pressed(_ sender: BannerButton) {
        perform(banner.actions[sender.tag], from: sender)
    }

    func perform(_ action: ResultBanner.Action, from button: NSView) {
        switch action {
        case .showInFinder:
            if let file = banner.file { ToolsKitSystem.reveal([file]) }
        case .share:
            if let file = banner.file ?? document?.url { ToolsKitSystem.share(file, button) }
        case .undo:
            document?.undoManager?.undo()
            dismiss()
        case .save:
            NSApp.sendAction(#selector(NSDocument.save(_:)), to: nil, from: button)
        case .openIn(let app):
            if let file = banner.file { ToolsKitSystem.openInApp(file, app) }
        case .showRequests:
            let item = NSMenuItem()
            item.identifier = NSUserInterfaceItemIdentifier(MenuCommand.signatureRequests.rawValue)
            NSApp.sendAction(#selector(MenuCommandResponding.performMenuCommand(_:)), to: nil, from: item)
        case .showDetails:
            showDetails()
            dismiss()
        }
    }
}

/// The banner's small bordered button (mockup `.btn.sm`): 22 pt, 11 pt text, an optional symbol.
@MainActor
final class BannerButton: NSButton {
    init(title: String, symbol name: String?) {
        super.init(frame: .zero)
        isBordered = false
        wantsLayer = true
        layer?.cornerRadius = 7
        layer?.cornerCurve = .continuous
        layer?.borderWidth = 1
        attributedTitle = NSAttributedString(string: title, attributes: [.font: Style.font(SPFont.secondary), .foregroundColor: Style.label])
        if let name {
            image = symbol(name, size: 11, weight: .medium)
            imagePosition = .imageLeading
            imageHugsTitle = true
            contentTintColor = Style.label
        }
        setAccessibilityLabel(title)
    }

    @available(*, unavailable) required init?(coder: NSCoder) { fatalError() }

    var fittingWidth: CGFloat {
        let titleWidth = ceil(attributedTitle.size().width)
        return titleWidth + 18 + (image == nil ? 0 : 17)
    }

    override var wantsUpdateLayer: Bool { true }
    override func updateLayer() {
        effectiveAppearance.performAsCurrentDrawingAppearance {
            layer?.backgroundColor = Style.control.cgColor
            layer?.borderColor = Style.strongSeparator.cgColor
        }
    }
}
