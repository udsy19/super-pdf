import AppKit
import SuperPDFCore

/// A locked PDF asks for its password inside its own window, as Preview does: the window opens with a lock, one
/// sentence, a secure field and Open; a wrong password shakes the field. When the password is right, DocumentKit opens
/// the document and this window becomes its window (`Viewer.makeWindowController` adopts it), so nothing jumps.
/// Closing the window cancels the open.
@MainActor
final class LockedPromptWindowController: NSWindowController, NSWindowDelegate, NSToolbarDelegate {
    let lockView = LockedView()
    private let titleView = TitleView()
    private let environment: ViewerEnvironment
    private var continuation: CheckedContinuation<String?, Never>?
    private static let titleItem = NSToolbarItem.Identifier("viewer.locked.title")

    init(fileName: String, environment: ViewerEnvironment) {
        self.environment = environment
        let window = DocumentWindowController.makeWindow()
        super.init(window: window)
        window.title = fileName
        window.titleVisibility = .hidden
        window.toolbarStyle = .unified
        window.minSize = SPMetrics.Window.minimumSize
        window.delegate = self
        let toolbar = NSToolbar(identifier: "SuperPDFLockedToolbar")
        toolbar.delegate = self
        toolbar.displayMode = .iconOnly
        toolbar.centeredItemIdentifiers = [Self.titleItem]
        window.toolbar = toolbar
        titleView.update(name: fileName, edited: false, url: nil)
        let content = NSViewController()
        content.view = lockView
        window.contentViewController = content
        window.setFrame(NSRect(origin: window.frame.origin, size: SPMetrics.Window.defaultSize), display: false)
        window.center()
        lockView.onSubmit = { [weak self] password in self?.answer(password) }
    }

    required init?(coder: NSCoder) { fatalError("not used") }

    /// Waiting for Open.
    var isAsking: Bool { continuation != nil }

    /// Waits for Open (or the window closing). `retry` means the last password was wrong: the field shakes and clears.
    func ask(retry: Bool) async -> String? {
        if retry { lockView.rejectPassword(animated: environment.moves) }
        lockView.isBusy = false
        if environment.showsWindows, window?.isVisible == false { showWindow(nil) }
        window?.makeFirstResponder(lockView.field)
        return await withCheckedContinuation { continuation in
            self.continuation?.resume(returning: nil)
            self.continuation = continuation
        }
    }

    private func answer(_ password: String?) {
        lockView.isBusy = password != nil
        let waiting = continuation
        continuation = nil
        waiting?.resume(returning: password)
    }

    /// Gives the window to the document's controller and steps aside.
    func handOverWindow() -> NSWindow? {
        guard let window else { return nil }
        window.delegate = nil
        window.toolbar = nil
        window.contentViewController = nil
        self.window = nil
        return window
    }

    func windowWillClose(_ notification: Notification) { answer(nil) }

    func toolbarDefaultItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] { [.flexibleSpace, Self.titleItem, .flexibleSpace] }
    func toolbarAllowedItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] { toolbarDefaultItemIdentifiers(toolbar) }
    func toolbar(_ toolbar: NSToolbar, itemForItemIdentifier identifier: NSToolbarItem.Identifier, willBeInsertedIntoToolbar flag: Bool) -> NSToolbarItem? {
        guard identifier == Self.titleItem else { return nil }
        let item = NSToolbarItem(itemIdentifier: identifier)
        item.view = titleView
        return item
    }
}

/// The lock, the sentence, the secure field and Open, centred on the document well's grey.
final class LockedView: NSView {
    let field = NSSecureTextField()
    let openButton = NSButton(title: ViewerStrings.Locked.open, target: nil, action: nil)
    var onSubmit: ((String) -> Void)?
    var isBusy = false { didSet { openButton.isEnabled = !isBusy; field.isEnabled = !isBusy } }

    override init(frame: NSRect) {
        super.init(frame: frame)
        let lock = NSImageView(image: NSImage(systemSymbolName: "lock.fill", accessibilityDescription: nil)!)
        lock.symbolConfiguration = .init(pointSize: 44, weight: .regular)
        lock.contentTintColor = SPColor.secondaryLabel.color
        let message = NSTextField(wrappingLabelWithString: ViewerStrings.Locked.message)
        message.font = SPFont.body.font()
        message.alignment = .center
        field.placeholderString = ViewerStrings.Locked.placeholder
        field.font = SPFont.body.font()
        field.target = self
        field.action = #selector(submit(_:))
        field.wantsLayer = true
        field.widthAnchor.constraint(equalToConstant: 220).isActive = true
        openButton.target = self
        openButton.action = #selector(submit(_:))
        openButton.keyEquivalent = "\r"
        openButton.bezelStyle = .push
        let row = NSStackView(views: [field, openButton])
        row.spacing = 8
        let stack = NSStackView(views: [lock, message, row])
        stack.orientation = .vertical
        stack.spacing = 14
        stack.setCustomSpacing(18, after: lock)
        stack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(stack)
        NSLayoutConstraint.activate([
            stack.centerXAnchor.constraint(equalTo: centerXAnchor),
            stack.centerYAnchor.constraint(equalTo: centerYAnchor, constant: -20),
            message.widthAnchor.constraint(lessThanOrEqualToConstant: 360),
        ])
        setAccessibilityLabel(ViewerStrings.Locked.message)
    }

    required init?(coder: NSCoder) { fatalError("not used") }

    override func draw(_ dirtyRect: NSRect) {
        SPColor.underPageBackground.color.setFill()
        dirtyRect.fill()
    }

    @objc private func submit(_ sender: Any?) {
        guard !isBusy, !field.stringValue.isEmpty else { return }
        onSubmit?(field.stringValue)
    }

    /// A wrong password: the field clears and shakes (no movement with Reduce Motion).
    func rejectPassword(animated: Bool) {
        field.stringValue = ""
        NSAccessibility.post(element: field, notification: .announcementRequested,
                             userInfo: [.announcement: Strings.Errors.invalidPassword, .priority: NSAccessibilityPriorityLevel.high.rawValue])
        guard animated, let layer = field.layer else { return }
        let shake = CAKeyframeAnimation(keyPath: "transform.translation.x")
        shake.values = [0, -10, 10, -8, 8, -4, 4, 0]
        shake.duration = 0.4
        shake.timingFunction = CAMediaTimingFunction(name: .easeOut)
        layer.add(shake, forKey: "shake")
    }
}
