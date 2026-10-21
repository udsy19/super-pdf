import AppKit
@preconcurrency import AVFoundation
import SuperPDFCore

// "Create signature…" (ux §5.3: Preview's three ways): draw on the trackpad, hold a signed sheet of paper up to the
// camera, or sign on an iPhone or iPad with Continuity Sketch. Each starts only from the person's own click; the
// result is a transparent PNG of the ink, saved to the library as a signature or (with "Initials") as initials.

@MainActor
final class CreateSignatureSheet: NSWindowController {
    private enum Source: Int { case trackpad, camera, iPhone }

    private let pads: [NSView]
    private let trackpad = TrackpadPad()
    private let camera = CameraPane()
    private let iPhone = SketchPane()
    private let segments = NSSegmentedControl(labels: [SignStrings.trackpad, SignStrings.camera, SignStrings.iPhone],
                                              trackingMode: .selectOne, target: nil, action: nil)
    private let initials = NSButton(checkboxWithTitle: SignStrings.initials, target: nil, action: nil)
    private let message = NSTextField(labelWithString: "")
    private var finish: ((SavedSignature?) -> Void)?

    init() {
        pads = [trackpad, camera, iPhone]
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 540, height: 340), styleMask: [.titled], backing: .buffered, defer: true)
        window.title = SignStrings.createSignature
        super.init(window: window)
        build()
    }

    @available(*, unavailable) required init?(coder: NSCoder) { fatalError() }

    /// Shows the sheet on `parent` (or as a window) and returns the new signature, nil when cancelled.
    func run(on parent: NSWindow?) async -> SavedSignature? {
        await withCheckedContinuation { continuation in
            finish = { continuation.resume(returning: $0) }
            if let parent, let window { parent.beginSheet(window) } else { showWindow(nil) }
        }
    }

    private func build() {
        guard let content = window?.contentView else { return }
        segments.selectedSegment = Source.trackpad.rawValue
        segments.target = self
        segments.action = #selector(switchSource)
        message.font = .systemFont(ofSize: 11)
        message.textColor = .secondaryLabelColor
        let clear = NSButton(title: SignStrings.clear, target: self, action: #selector(clear))
        let cancel = NSButton(title: SignStrings.cancel, target: self, action: #selector(cancel))
        cancel.keyEquivalent = "\u{1b}"
        let save = NSButton(title: SignStrings.saveSignature, target: self, action: #selector(save))
        save.keyEquivalent = "\r"
        let footer = NSStackView(views: [initials, message, NSView(), clear, cancel, save])
        footer.spacing = 8
        for view in [segments, footer] as [NSView] + pads {
            view.translatesAutoresizingMaskIntoConstraints = false
            content.addSubview(view)
        }
        var constraints = [
            segments.topAnchor.constraint(equalTo: content.topAnchor, constant: 16),
            segments.centerXAnchor.constraint(equalTo: content.centerXAnchor),
            footer.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 20),
            footer.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -20),
            footer.bottomAnchor.constraint(equalTo: content.bottomAnchor, constant: -16),
        ]
        for pad in pads {
            constraints += [
                pad.topAnchor.constraint(equalTo: segments.bottomAnchor, constant: 14),
                pad.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 20),
                pad.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -20),
                pad.bottomAnchor.constraint(equalTo: footer.topAnchor, constant: -14),
            ]
        }
        NSLayoutConstraint.activate(constraints)
        switchSource()
    }

    private var source: Source { Source(rawValue: segments.selectedSegment) ?? .trackpad }

    @objc private func switchSource() {
        for (i, pad) in pads.enumerated() { pad.isHidden = i != source.rawValue }
        message.stringValue = ""
        trackpad.stopCapturing()
        if source == .camera { camera.start() } else { camera.stop() }
    }

    @objc private func clear() {
        trackpad.clear()
        iPhone.clear()
        message.stringValue = ""
    }

    @objc private func cancel() { close(with: nil) }

    @objc private func save() {
        let png: Data? = switch source {
        case .trackpad: trackpad.png()
        case .camera: camera.capture()
        case .iPhone: iPhone.png
        }
        guard let png else { message.stringValue = SignStrings.nothingCaught; return }
        close(with: SavedSignature(kind: initials.state == .on ? .initials : .signature, image: png))
    }

    private func close(with signature: SavedSignature?) {
        trackpad.stopCapturing()
        camera.stop()
        if let window, let parent = window.sheetParent { parent.endSheet(window) } else { window?.close() }
        finish?(signature)
        finish = nil
    }
}

// MARK: - Trackpad

/// Preview's trackpad pad: click to begin, sign with one finger on the trackpad (the pointer stays still and hidden),
/// press any key to finish. A mouse can draw by dragging too.
@MainActor
final class TrackpadPad: NSView {
    private var strokes: [[CGPoint]] = []
    private var touchStrokes: [ObjectIdentifier: Int] = [:]
    private(set) var isCapturing = false

    override init(frame: NSRect) {
        super.init(frame: frame)
        allowedTouchTypes = [.indirect]
        wantsRestingTouches = false
        setAccessibilityElement(true)
        setAccessibilityRole(.group)
        setAccessibilityLabel(SignStrings.trackpadHint)
    }

    @available(*, unavailable) required init?(coder: NSCoder) { fatalError() }

    override var acceptsFirstResponder: Bool { true }
    override var isFlipped: Bool { false }

    func clear() { strokes = []; needsDisplay = true }

    func png() -> Data? { SignatureInk.png(strokes: strokes, canvas: bounds.size) }

    /// Where the mouse went down: a click starts trackpad signing, a drag draws with the mouse.
    private var pendingStart: CGPoint?

    override func mouseDown(with event: NSEvent) {
        if !isCapturing { pendingStart = convert(event.locationInWindow, from: nil) }
    }

    override func mouseDragged(with event: NSEvent) {
        guard !isCapturing else { return }
        let point = convert(event.locationInWindow, from: nil)
        if let start = pendingStart { strokes.append([start]); pendingStart = nil }
        guard !strokes.isEmpty else { return }
        strokes[strokes.count - 1].append(point)
        needsDisplay = true
    }

    override func mouseUp(with event: NSEvent) {
        if pendingStart != nil { pendingStart = nil; startCapturing() }
    }

    private var resignObserver: NSObjectProtocol?

    private func startCapturing() {
        guard !isCapturing else { return }
        isCapturing = true
        window?.makeFirstResponder(self)
        // Fingers on the trackpad must not move the pointer away while signing; leaving the window gives it back.
        CGAssociateMouseAndMouseCursorPosition(0)
        NSCursor.hide()
        resignObserver = NotificationCenter.default.addObserver(forName: NSWindow.didResignKeyNotification, object: window, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.stopCapturing() }
        }
        needsDisplay = true
    }

    func stopCapturing() {
        guard isCapturing else { return }
        isCapturing = false
        CGAssociateMouseAndMouseCursorPosition(1)
        NSCursor.unhide()
        if let resignObserver { NotificationCenter.default.removeObserver(resignObserver) }
        resignObserver = nil
        touchStrokes = [:]
        needsDisplay = true
    }

    override func viewWillMove(toWindow newWindow: NSWindow?) {
        if newWindow == nil { stopCapturing() }
        super.viewWillMove(toWindow: newWindow)
    }

    override func keyDown(with event: NSEvent) {
        if isCapturing { stopCapturing() } else { super.keyDown(with: event) }
    }

    private func point(_ touch: NSTouch) -> CGPoint {
        let p = touch.normalizedPosition
        let inset = bounds.insetBy(dx: 16, dy: 16)
        return CGPoint(x: inset.minX + p.x * inset.width, y: inset.minY + p.y * inset.height)
    }

    override func touchesBegan(with event: NSEvent) {
        guard isCapturing else { return }
        for touch in event.touches(matching: .began, in: self) {
            touchStrokes[ObjectIdentifier(touch.identity as AnyObject)] = strokes.count
            strokes.append([point(touch)])
        }
        needsDisplay = true
    }

    override func touchesMoved(with event: NSEvent) {
        guard isCapturing else { return }
        for touch in event.touches(matching: .moved, in: self) {
            guard let index = touchStrokes[ObjectIdentifier(touch.identity as AnyObject)], index < strokes.count else { continue }
            strokes[index].append(point(touch))
        }
        needsDisplay = true
    }

    override func touchesEnded(with event: NSEvent) {
        for touch in event.touches(matching: .ended, in: self) { touchStrokes[ObjectIdentifier(touch.identity as AnyObject)] = nil }
    }

    override func touchesCancelled(with event: NSEvent) { touchesEnded(with: event) }

    override func draw(_ dirtyRect: NSRect) {
        let box = bounds.insetBy(dx: 1, dy: 1)
        let path = NSBezierPath(roundedRect: box, xRadius: 10, yRadius: 10)
        NSColor.white.setFill()
        path.fill()
        (isCapturing ? NSColor.controlAccentColor : NSColor.separatorColor).setStroke()
        path.lineWidth = isCapturing ? 2 : 1
        path.stroke()
        let baseline = NSBezierPath()
        baseline.move(to: NSPoint(x: box.minX + 30, y: box.minY + box.height * 0.3))
        baseline.line(to: NSPoint(x: box.maxX - 30, y: box.minY + box.height * 0.3))
        NSColor.separatorColor.setStroke()
        baseline.stroke()
        if let context = NSGraphicsContext.current?.cgContext {
            context.setStrokeColor(SignatureInk.color)
            context.setLineWidth(3)
            context.setLineCap(.round)
            context.setLineJoin(.round)
            for stroke in strokes where stroke.count > 1 {
                context.addPath(SignatureInk.smoothPath(stroke))
                context.strokePath()
            }
        }
        let text = isCapturing ? SignStrings.trackpadHint : (strokes.isEmpty ? SignStrings.trackpadStart : "")
        guard !text.isEmpty else { return }
        let attributes: [NSAttributedString.Key: Any] = [.font: NSFont.systemFont(ofSize: isCapturing ? 11 : 15),
                                                         .foregroundColor: NSColor.secondaryLabelColor]
        let size = (text as NSString).size(withAttributes: attributes)
        let y = isCapturing ? box.minY + 10 : box.midY - size.height / 2
        (text as NSString).draw(at: NSPoint(x: box.midX - size.width / 2, y: y), withAttributes: attributes)
    }
}

// MARK: - Camera

/// The Mac's camera, started only while the Camera tab is shown; the frame current when Save is clicked gives the ink.
@MainActor
final class CameraPane: NSView {
    private let session = AVCaptureSession()
    private let output = AVCaptureVideoDataOutput()
    private let frames = LatestFrame()
    private let queue = DispatchQueue(label: "com.udsy.superpdf.signature-camera")
    private var configured = false
    private let note = NSTextField(wrappingLabelWithString: SignStrings.cameraHint)

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        layer?.cornerRadius = 10
        layer?.masksToBounds = true
        layer?.backgroundColor = NSColor.black.cgColor
        note.font = .systemFont(ofSize: 11)
        note.textColor = .white
        note.alignment = .center
        note.translatesAutoresizingMaskIntoConstraints = false
        addSubview(note)
        NSLayoutConstraint.activate([note.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 16),
                                     note.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -16),
                                     note.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -10)])
    }

    @available(*, unavailable) required init?(coder: NSCoder) { fatalError() }

    func start() {
        switch AVCaptureDevice.authorizationStatus(for: .video) {
        case .authorized:
            run()
        case .notDetermined:
            AVCaptureDevice.requestAccess(for: .video) { granted in
                Task { @MainActor [weak self] in if granted { self?.run() } else { self?.denied() } }
            }
        default:
            denied()
        }
    }

    private func denied() { note.stringValue = SignStrings.cameraUnavailable }

    private func run() {
        if !configured {
            guard let device = AVCaptureDevice.default(for: .video), let input = try? AVCaptureDeviceInput(device: device),
                  session.canAddInput(input), session.canAddOutput(output) else { denied(); return }
            session.addInput(input)
            output.videoSettings = [kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA]
            output.setSampleBufferDelegate(frames, queue: queue)
            session.addOutput(output)
            let preview = AVCaptureVideoPreviewLayer(session: session)
            preview.videoGravity = .resizeAspectFill
            preview.frame = bounds
            preview.autoresizingMask = [.layerWidthSizable, .layerHeightSizable]
            layer?.insertSublayer(preview, at: 0)
            configured = true
        }
        let session = self.session
        queue.async { if !session.isRunning { session.startRunning() } }
    }

    func stop() {
        let session = self.session
        queue.async { if session.isRunning { session.stopRunning() } }
    }

    func capture() -> Data? { frames.image.flatMap(SignatureInk.extract(from:)) }
}

/// Keeps the newest camera frame as a CGImage.
private final class LatestFrame: NSObject, AVCaptureVideoDataOutputSampleBufferDelegate, @unchecked Sendable {
    private let lock = NSLock()
    private let context = CIContext()
    private var latest: CGImage?

    var image: CGImage? { lock.withLock { latest } }

    func captureOutput(_ output: AVCaptureOutput, didOutput sampleBuffer: CMSampleBuffer, from connection: AVCaptureConnection) {
        guard let buffer = CMSampleBufferGetImageBuffer(sampleBuffer) else { return }
        let image = CIImage(cvPixelBuffer: buffer)
        guard let cg = context.createCGImage(image, from: image.extent) else { return }
        lock.withLock { latest = cg }
    }
}

// MARK: - iPhone (Continuity Sketch)

/// "Sign on iPhone…" asks the system for a sketch from a nearby iPhone or iPad (`NSMenuItem.importFromDeviceIdentifier`);
/// the picture comes back through the Services pasteboard and keeps only its ink.
@MainActor
final class SketchPane: NSView, NSServicesMenuRequestor {
    private let button = NSButton(title: SignStrings.signOnIPhone, target: nil, action: nil)
    private let preview = NSImageView()
    private(set) var png: Data?

    override init(frame: NSRect) {
        super.init(frame: frame)
        let note = NSTextField(wrappingLabelWithString: SignStrings.iPhoneHint)
        note.font = .systemFont(ofSize: 11)
        note.textColor = .secondaryLabelColor
        note.alignment = .center
        button.target = self
        button.action = #selector(choose(_:))
        button.bezelStyle = .rounded
        preview.imageScaling = .scaleProportionallyUpOrDown
        let stack = NSStackView(views: [preview, note, button])
        stack.orientation = .vertical
        stack.spacing = 10
        stack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(stack)
        NSLayoutConstraint.activate([stack.leadingAnchor.constraint(equalTo: leadingAnchor), stack.trailingAnchor.constraint(equalTo: trailingAnchor),
                                     stack.centerYAnchor.constraint(equalTo: centerYAnchor), preview.heightAnchor.constraint(equalToConstant: 90),
                                     preview.widthAnchor.constraint(equalTo: stack.widthAnchor)])
    }

    @available(*, unavailable) required init?(coder: NSCoder) { fatalError() }

    override var acceptsFirstResponder: Bool { true }

    func clear() { png = nil; preview.image = nil }

    @objc private func choose(_ sender: NSButton) {
        window?.makeFirstResponder(self)
        let menu = NSMenu()
        let item = NSMenuItem(title: SignStrings.signOnIPhone, action: nil, keyEquivalent: "")
        item.identifier = NSMenuItem.importFromDeviceIdentifier
        menu.addItem(item)
        menu.popUp(positioning: nil, at: NSPoint(x: 0, y: sender.bounds.height + 4), in: sender)
    }

    override func validRequestor(forSendType sendType: NSPasteboard.PasteboardType?, returnType: NSPasteboard.PasteboardType?) -> Any? {
        if let returnType, NSImage.imageTypes.contains(returnType.rawValue) { return self }
        return super.validRequestor(forSendType: sendType, returnType: returnType)
    }

    nonisolated func readSelection(from pasteboard: NSPasteboard) -> Bool {
        MainActor.assumeIsolated {
            guard let image = NSImage(pasteboard: pasteboard), let cg = image.cgImage(forProposedRect: nil, context: nil, hints: nil),
                  let ink = SignatureInk.extract(from: cg) else { return false }
            png = ink
            preview.image = NSImage(data: ink)
            return true
        }
    }
}
