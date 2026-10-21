import AppKit
import SuperPDFCore
import UniformTypeIdentifiers

/// Continuity Camera (features #101): a menu holding AppKit's `NSMenuItem.importFromDeviceIdentifier` item, which the
/// system fills with the nearby iPhones and iPads ("Take Photo", "Scan Documents", "Add Sketch"); what the device sends
/// back arrives through `NSServicesMenuRequestor.readSelection(from:)` on the view that showed the menu.
@MainActor
final class ContinuityCamera {
    /// What an iPhone or iPad sends back: "Scan Documents" gives a PDF, "Take Photo" a picture.
    enum Delivery: Sendable {
        case pdf(Data)
        case picture(Data)
    }

    /// The pasteboard types the requestor accepts, best first.
    static let acceptedTypes: [NSPasteboard.PasteboardType] = [
        .pdf, NSPasteboard.PasteboardType(UTType.heic.identifier), NSPasteboard.PasteboardType(UTType.jpeg.identifier), .png, .tiff,
    ]

    /// Shows the import menu from the view on screen and answers whether the system offered a device in it. Set by
    /// `ContinuityImportView` while it is in a window; tests set their own.
    var present: (@MainActor () -> Bool)?
    private var pending: AsyncThrowingStream<Delivery, Error>.Continuation?

    /// The next delivery. Fails with "No iPhone or iPad nearby" when the system listed no device; asking again replaces
    /// an import still waiting (the person picked nothing in the menu).
    func importNext() -> AsyncThrowingStream<Delivery, Error> {
        pending?.finish()
        let (stream, continuation) = AsyncThrowingStream<Delivery, Error>.makeStream()
        pending = continuation
        if !(present?() ?? false), pending != nil {
            pending = nil
            continuation.finish(throwing: ScanFailure.noIPhone)
        }
        return stream
    }

    /// The device's data, from the requestor; false when it holds nothing a page can be made of.
    @discardableResult
    func receive(_ pasteboard: NSPasteboard) -> Bool {
        guard let delivery = Self.delivery(from: pasteboard) else { return false }
        guard let pending else { return false }
        self.pending = nil
        pending.yield(delivery)
        pending.finish()
        return true
    }

    static func delivery(from pasteboard: NSPasteboard) -> Delivery? {
        if let pdf = pasteboard.data(forType: .pdf) { return .pdf(pdf) }
        for type in acceptedTypes.dropFirst() {
            if let data = pasteboard.data(forType: type) { return .picture(data) }
        }
        return nil
    }

    /// Whether a menu the system has filled lists a device: the placeholder item gains siblings or a submenu.
    static func offersDevice(_ menu: NSMenu) -> Bool {
        menu.items.contains { $0.identifier != NSMenuItem.importFromDeviceIdentifier || $0.hasSubmenu }
    }
}

/// The "Import from iPhone…" button of the Scan with iPhone panel. It is the services requestor: it becomes first
/// responder, shows the Continuity Camera menu under the button, and hands what comes back to `ContinuityCamera`.
@MainActor
final class ContinuityImportView: NSView, NSServicesMenuRequestor {
    private let camera: ContinuityCamera
    private let start: @MainActor () -> Void
    private let button: NSButton

    init(camera: ContinuityCamera, start: @escaping @MainActor () -> Void) {
        self.camera = camera
        self.start = start
        button = NSButton(title: ScanStrings.importFromIPhone, target: nil, action: nil)
        super.init(frame: NSRect(x: 0, y: 0, width: 280, height: 32))
        button.bezelStyle = .rounded
        button.controlSize = .large
        button.image = NSImage(systemSymbolName: "iphone", accessibilityDescription: nil)
        button.imagePosition = .imageLeading
        button.target = self
        button.action = #selector(showMenu)
        button.translatesAutoresizingMaskIntoConstraints = false
        addSubview(button)
        NSLayoutConstraint.activate([
            button.leadingAnchor.constraint(equalTo: leadingAnchor),
            button.trailingAnchor.constraint(equalTo: trailingAnchor),
            button.topAnchor.constraint(equalTo: topAnchor),
            button.bottomAnchor.constraint(equalTo: bottomAnchor),
        ])
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    override var acceptsFirstResponder: Bool { true }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if window != nil { camera.present = { [weak self] in self?.popUpMenu() ?? false } }
    }

    @objc private func showMenu() { start() }

    /// Shows the menu (tracking until it closes) and answers whether the system listed a device in it.
    private func popUpMenu() -> Bool {
        window?.makeFirstResponder(self)
        let menu = NSMenu()
        let item = NSMenuItem(title: ScanStrings.importFromIPhone, action: nil, keyEquivalent: "")
        item.identifier = NSMenuItem.importFromDeviceIdentifier
        menu.addItem(item)
        menu.popUp(positioning: nil, at: NSPoint(x: 0, y: button.bounds.height + 4), in: button)
        return ContinuityCamera.offersDevice(menu)
    }

    override func validRequestor(forSendType sendType: NSPasteboard.PasteboardType?,
                                 returnType: NSPasteboard.PasteboardType?) -> Any? {
        if sendType == nil, let returnType, ContinuityCamera.acceptedTypes.contains(returnType) { return self }
        return super.validRequestor(forSendType: sendType, returnType: returnType)
    }

    nonisolated func readSelection(from pasteboard: NSPasteboard) -> Bool {
        MainActor.assumeIsolated { camera.receive(pasteboard) }
    }

    nonisolated func writeSelection(to pasteboard: NSPasteboard, types: [NSPasteboard.PasteboardType]) -> Bool { false }
}
