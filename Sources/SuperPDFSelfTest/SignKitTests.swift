import AppKit
import PDFKit
import PDFModelKit
@testable import SignKit
import SuperPDFCore
@testable import ToolsKit

// SignKit's checks (WP11), on generated fixtures only. Keys live in memory (`MemorySigningKeyStore`,
// `MemorySignatureKey`): the person's Keychain is never touched; sharing is recorded, never performed; nothing opens
// the camera, a trackpad capture or an iPhone. Panels are driven as the app drives them: a ToolSession, the panel's own
// views in an offscreen window over a real PDFView, mouse events on the page. Renders go to SUPERPDF_RENDERS when set.

func registerSignKitTests() {
    SelfTest.cases += [
        ("SignKit.provider", signProvider),
        ("SignKit.library", signLibrary),
        ("SignKit.ink", signInk),
        ("SignKit.typedAndImported", signTypedAndImported),
        ("SignKit.certificateSigning", signCertificateSigning),
        ("SignKit.changesAfterSigning", signChangesAfterSigning),
        ("SignKit.repairedAndEncrypted", signRepairedAndEncrypted),
        ("SignKit.trust", signTrust),
        ("SignKit.timestamp", signTimestamp),
        ("SignKit.signPanel", signPanelPlacement),
        ("SignKit.certificatePanel", signCertificatePanel),
        ("SignKit.certificatesTile", signCertificatesTile),
        ("SignKit.requestRoundTrip", signRequestRoundTrip),
        ("SignKit.panelRenders", signPanelRenders),
    ]
}

// MARK: - Helpers

@MainActor
private final class RecordingSharing: RequestSharing {
    var sent: [(file: URL, recipients: [String], subject: String, channel: SharingChannel)] = []
    func share(_ file: URL, to recipients: [String], subject: String, message: String, via channel: SharingChannel) throws {
        sent.append((file, recipients, subject, channel))
    }
}

/// A viewer with real PDFViews in an offscreen window (never shown), so the panels' page editing can be driven.
@MainActor
private final class SignTestViewer: ViewerPresenting {
    var banners: [ResultBanner] = []
    let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 700, height: 900), styleMask: [.borderless], backing: .buffered, defer: false)
    private var views: [UUID: PDFView] = [:]

    init() { window.isReleasedWhenClosed = false }

    @discardableResult
    func attach(_ document: DocumentHandle) -> PDFView {
        let view = PDFView(frame: window.contentView!.bounds)
        view.document = document.pdf
        view.displayMode = .singlePage
        view.autoScales = false
        view.scaleFactor = 1
        window.contentView!.addSubview(view)
        view.layoutDocumentView()
        views[document.id] = view
        return view
    }

    /// Puts a panel's custom view in the window, as the panel host does (its page editor attaches then).
    func host(_ view: NSView) {
        view.frame = NSRect(x: 0, y: 0, width: 280, height: 200)
        window.contentView!.addSubview(view)
        view.layoutSubtreeIfNeeded()
    }

    func makeWindowController(for document: DocumentHandle) -> NSWindowController { NSWindowController(window: nil) }
    func pdfView(for document: DocumentHandle) -> PDFView? { views[document.id] }
    func selectedPages(in document: DocumentHandle) -> [Int] { [] }
    func currentPage(in document: DocumentHandle) -> Int { 0 }
    func showToolPanel(_ panel: NSViewController?, in document: DocumentHandle) {}
    func showBanner(_ banner: ResultBanner, in document: DocumentHandle) { banners.append(banner) }
    func showSidebar(_ mode: SidebarMode, in document: DocumentHandle) {}
    func showOrganiser(for document: DocumentHandle, adding files: [URL]) {}
    func combine(_ files: [URL]) {}
    func showWelcome() {}
    func showCropHandles(_ handles: CropHandles?, in document: DocumentHandle) {}
    func password(forLocked fileName: String, retry: Bool) async -> String? { nil }
}

@MainActor
private func signSetUp(sharing: RecordingSharing? = nil) -> SignService {
    installFakes()
    SignKitModule.install(keys: MemorySigningKeyStore(), signatureKey: MemorySignatureKey(), sharing: sharing ?? RecordingSharing())
    return Services.sign as! SignService
}

@MainActor
private var signProviderInstance: any ToolProviding { Services.toolProviders.first { $0.tools.contains(.sign) }! }

@MainActor
private func signRun<T>(_ name: String, _ work: @escaping @MainActor () async throws -> T) -> T? {
    switch complete(300, work) {
    case .success(let value): return value
    case .failure(let error): check(false, "\(name) failed: \(error)"); return nil
    default: check(false, "\(name) timed out"); return nil
    }
}

/// Turns the run loop until `condition` holds (tasks the services start on their own), at most `seconds`.
@MainActor
private func waitUntil(_ seconds: TimeInterval = 20, _ condition: () -> Bool) -> Bool {
    let deadline = Date().addingTimeInterval(seconds)
    while !condition() && Date() < deadline { RunLoop.main.run(until: Date().addingTimeInterval(0.02)) }
    return condition()
}

private var signFolder: URL { SuperPDFPaths.ensure(scratch.appendingPathComponent("SignKit", isDirectory: true)) }

private func signFile(_ name: String, _ data: Data? = nil) -> URL {
    let url = signFolder.appendingPathComponent(name)
    if let data { try? data.write(to: url) }
    return url
}

private var renderFolder: URL {
    if let path = ProcessInfo.processInfo.environment["SUPERPDF_RENDERS"] { return SuperPDFPaths.ensure(URL(fileURLWithPath: path, isDirectory: true)) }
    return SuperPDFPaths.ensure(signFolder.appendingPathComponent("renders", isDirectory: true))
}

/// A document backed by a file, with a heading and signature lines like the mockup's lease.
@MainActor
private func signDocument(_ name: String, pages: Int = 2) -> DocumentHandle {
    let data = NSMutableData()
    var box = CGRect(x: 0, y: 0, width: 612, height: 792)
    let consumer = CGDataConsumer(data: data as CFMutableData)!
    let context = CGContext(consumer: consumer, mediaBox: &box, nil)!
    for n in 1...pages {
        context.beginPDFPage(nil)
        let lines = ["Residential Lease Agreement", "Page \(n) of \(pages)", "The Tenant agrees to pay the rent on the first day of each month."]
        for (i, text) in lines.enumerated() {
            let line = CTLineCreateWithAttributedString(NSAttributedString(string: text, attributes: [.font: NSFont(name: "Helvetica", size: i == 0 ? 22 : 12)!]))
            context.textPosition = CGPoint(x: 72, y: 700 - CGFloat(i) * 32)
            CTLineDraw(line, context)
        }
        context.setStrokeColor(CGColor(gray: 0, alpha: 1))
        context.setLineWidth(0.75)
        for x in [72.0, 330.0] {
            context.move(to: CGPoint(x: x, y: 200)); context.addLine(to: CGPoint(x: x + 210, y: 200)); context.strokePath()
        }
        context.endPDFPage()
    }
    context.closePDF()
    let url = signFile(name + ".pdf", data as Data)
    return DocumentHandle(url: url, pdf: PDFDocument(url: url)!, undoManager: makeUndoManager())
}

/// A handwritten-looking signature, made the way the trackpad pad makes one.
private func handwriting(initials: Bool = false) -> Data {
    var first: [CGPoint] = []
    for i in 0...60 {
        let t = Double(i) / 60
        first.append(CGPoint(x: 20 + t * (initials ? 120 : 460), y: 70 + sin(t * .pi * (initials ? 4 : 9)) * 34 + t * 10))
    }
    let strokes = [first, [CGPoint(x: 40, y: 40), CGPoint(x: initials ? 130 : 420, y: 46)]]
    return SignatureInk.png(strokes: strokes, canvas: CGSize(width: initials ? 160 : 500, height: 140))!
}

/// The share of dark pixels (ink) inside `rect` (page space) of a page drawn by PDFKit, annotations included.
@MainActor
private func ink(_ page: PDFKit.PDFPage, in rect: CGRect) -> Double {
    let scale: CGFloat = 2
    let width = Int(rect.width * scale), height = Int(rect.height * scale)
    guard width > 0, height > 0, let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width,
                                                          space: CGColorSpaceCreateDeviceGray(), bitmapInfo: CGImageAlphaInfo.none.rawValue) else { return 0 }
    context.setFillColor(CGColor(gray: 1, alpha: 1))
    context.fill(CGRect(x: 0, y: 0, width: width, height: height))
    context.scaleBy(x: scale, y: scale)
    context.translateBy(x: -rect.minX, y: -rect.minY)
    page.draw(with: .mediaBox, to: context)
    let pixels = UnsafeBufferPointer(start: context.data!.assumingMemoryBound(to: UInt8.self), count: width * height)
    return Double(pixels.filter { $0 < 140 }.count) / Double(width * height)
}

/// Saves a page as PNG (for looking at), annotations included.
@MainActor
private func saveRender(_ page: PDFKit.PDFPage, _ name: String) {
    let bounds = page.bounds(for: .mediaBox)
    let scale: CGFloat = 1.5
    let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: Int(bounds.width * scale), pixelsHigh: Int(bounds.height * scale), bitsPerSample: 8,
                               samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
    NSGraphicsContext.saveGraphicsState()
    let context = NSGraphicsContext(bitmapImageRep: rep)!
    NSGraphicsContext.current = context
    context.cgContext.setFillColor(.white)
    context.cgContext.fill(CGRect(x: 0, y: 0, width: rep.pixelsWide, height: rep.pixelsHigh))
    context.cgContext.scaleBy(x: scale, y: scale)
    page.draw(with: .mediaBox, to: context.cgContext)
    NSGraphicsContext.restoreGraphicsState()
    let url = renderFolder.appendingPathComponent("signkit-\(name).png")
    try? rep.representation(using: .png, properties: [:])?.write(to: url)
    if ProcessInfo.processInfo.environment["SUPERPDF_RENDERS"] != nil { print("  render: \(url.path)") }
}

/// Clicks (and drags) on a page through the panel's page editor, as a person does.
@MainActor
private func click(_ pdfView: PDFView, page index: Int, at point: CGPoint, dragTo end: CGPoint? = nil) {
    guard let page = pdfView.document?.page(at: index),
          let editor = pdfView.subviews.last(where: { String(describing: type(of: $0)) == "PageBoardView" }), let window = pdfView.window else {
        check(false, "the page editor is over the document"); return
    }
    if pdfView.currentPage != page { pdfView.go(to: page) }
    pdfView.layoutDocumentView()
    func event(_ type: NSEvent.EventType, _ point: CGPoint) -> NSEvent {
        let inWindow = pdfView.convert(pdfView.convert(point, from: page), to: nil)
        return NSEvent.mouseEvent(with: type, location: inWindow, modifierFlags: [], timestamp: 0, windowNumber: window.windowNumber, context: nil,
                                  eventNumber: 0, clickCount: 1, pressure: 1)!
    }
    editor.mouseDown(with: event(.leftMouseDown, point))
    if let end {
        editor.mouseDragged(with: event(.leftMouseDragged, end))
        editor.mouseUp(with: event(.leftMouseUp, end))
    } else {
        editor.mouseUp(with: event(.leftMouseUp, point))
    }
}

/// A mouse click on a plain view at `point` (its own coordinates).
@MainActor
private func press(_ view: NSView, at point: NSPoint) {
    guard let window = view.window else { return }
    view.mouseDown(with: NSEvent.mouseEvent(with: .leftMouseDown, location: view.convert(point, to: nil), modifierFlags: [], timestamp: 0,
                                            windowNumber: window.windowNumber, context: nil, eventNumber: 0, clickCount: 1, pressure: 1)!)
}

/// The custom control `id` (or the first whose id starts with it) of a panel, made.
@MainActor
private func customView(_ panel: ToolPanel, _ id: String) -> NSView? {
    for control in panel.controls + panel.moreOptions {
        if case .custom(let controlID, let make) = control, controlID.hasPrefix(id) { return make() }
    }
    return nil
}

/// The CMS of a signature without the zero padding of /Contents.
private func trimmedCMS(_ contents: Data) -> Data {
    let bytes = [UInt8](contents)
    guard bytes.count > 4, bytes[0] == 0x30 else { return contents }
    let first = bytes[1]
    if first < 0x80 { return contents.prefix(2 + Int(first)) }
    let count = Int(first & 0x7F)
    let length = bytes[2..<(2 + count)].reduce(0) { $0 << 8 | Int($1) }
    return contents.prefix(2 + count + length)
}

/// `openssl cms -verify` (the system's LibreSSL) on a signature's CMS and the bytes it covers: the message digest and
/// the signature value (`-noverify`: LibreSSL won't take a self-signed end-entity certificate as a root; trust is our
/// verifier's job and checked there). Nil when there is no openssl to ask.
private func opensslVerifies(cms: Data, content: Data) -> Bool? {
    let openssl = URL(fileURLWithPath: "/usr/bin/openssl")
    guard FileManager.default.isExecutableFile(atPath: openssl.path) else { return nil }
    let cmsURL = signFile("openssl-\(UUID().uuidString).der", cms), contentURL = signFile("openssl-content.bin", content)
    let process = Process()
    process.executableURL = openssl
    process.arguments = ["cms", "-verify", "-binary", "-noverify", "-inform", "DER", "-in", cmsURL.path, "-content", contentURL.path, "-out", "/dev/null"]
    let pipe = Pipe()
    process.standardOutput = pipe
    process.standardError = pipe
    guard (try? process.run()) != nil else { return nil }
    let output = pipe.fileHandleForReading.readDataToEndOfFile()
    process.waitUntilExit()
    if process.terminationStatus != 0 { print("  openssl: \(String(decoding: output, as: UTF8.self))") }
    return process.terminationStatus == 0
}

/// Appends an update that changes `change` on page `index` of a signed file (a later revision).
private func appendUpdate(_ data: Data, page index: Int, _ change: (PDFModel, PDFModelKit.PDFPage) throws -> Void) -> Data? {
    guard let model = try? PDFModel(data: data), let page = model.page(at: index) else { return nil }
    try? change(model, page)
    return try? model.incrementalData()
}

// MARK: - The tiles

@MainActor
private func signProvider() {
    _ = signSetUp()
    for tool in ToolCatalog.tiles(ownedBy: .signKit).map(\.id) { Defaults.reset(ToolSession.valuesKey(tool)) }
    let provider = signProviderInstance
    check(Set(provider.tools) == Set(ToolCatalog.tiles(ownedBy: .signKit).map(\.id)), "SignKit serves its three tiles: \(provider.tools)")
    let document = signDocument("Lease agreement")

    // Sign (D): the mockup's panel.
    let sign = ToolSession(tool: .sign, provider: provider, document: document)
    check(sign.panel.archetype == .mode && sign.panel.hint == "Put your signature on the page. Click a signature, then click where it goes.",
          "Sign's hint")
    check(sign.panel.primary.title == "Sign and save…" && !sign.canRun, "Sign and save… waits for a signature on the page")
    check(sign.outputLine?.text == "Saves “Lease agreement (signed).pdf” · the original is untouched", "output line: \(sign.outputLine?.text ?? "-")")
    let ids = sign.panel.controls.compactMap(\.id)
    check(ids == ["kind", "pads", "create", "date"], "My signature's controls: \(ids)")
    sign.set("kind", .string("certificate"))
    check(sign.panel.controls.compactMap(\.id).contains("createIdentity") && !sign.canRun, "with no certificate: Create my certificate…")

    // Request signatures (G): three steps.
    let request = ToolSession(tool: .requestSignatures, provider: provider, document: document)
    check(request.panel.archetype == .flow && request.layout.steps == ["1 Who", "2 Where", "3 Send"], "request steps")
    check(request.panel.primary.title == "Next: Where" && !request.canRun, "Next: Where waits for a person")

    // Certificates & signatures (G): tabs and Done.
    let certificates = ToolSession(tool: .certificates, provider: provider, document: document)
    check(certificates.panel.primary.title == "Done" && certificates.panel.secondary == nil, "Certificates closes with Done")
}

// MARK: - Library (features #82: Keychain-protected, like Preview's)

@MainActor
private func signLibrary() {
    installFakes()
    let key = MemorySignatureKey()
    let folder = SuperPDFPaths.ensure(signFolder.appendingPathComponent("library", isDirectory: true))
    let service = SignService(keys: MemorySigningKeyStore(), signatureKey: key, signaturesFolder: folder)
    let signature = SavedSignature(kind: .signature, image: handwriting())
    let initials = SavedSignature(kind: .initials, image: handwriting(initials: true))
    do {
        try service.save(signature)
        try service.save(initials)
    } catch { check(false, "saving signatures: \(error)"); return }
    check(service.savedSignatures.map(\.id) == [signature.id, initials.id], "saved in order")

    // On disk the pictures are sealed: no PNG signature in any file.
    let files = (try? FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil)) ?? []
    check(files.count == 2, "one file per signature")
    let png = Data([0x89, 0x50, 0x4E, 0x47])
    check(files.allSatisfy { (try? Data(contentsOf: $0))?.range(of: png) == nil }, "the pictures are not readable on disk")

    // The same key reads them back; another key reads nothing.
    let again = SignService(keys: MemorySigningKeyStore(), signatureKey: key, signaturesFolder: folder)
    check(again.savedSignatures.map(\.image) == [signature.image, initials.image], "read back with the key")
    let stranger = SignService(keys: MemorySigningKeyStore(), signatureKey: MemorySignatureKey(), signaturesFolder: folder)
    check(stranger.savedSignatures.isEmpty, "another key can't read them")

    try? again.delete(signature.id)
    check(again.savedSignatures.map(\.id) == [initials.id], "deleted")
    check(((try? FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil)) ?? []).count == 1, "its file went")
}

// MARK: - Ink (trackpad strokes and photographed signatures)

@MainActor
private func signInk() {
    func pixels(_ png: Data) -> (alpha: [UInt8], width: Int, height: Int)? {
        guard let rep = NSBitmapImageRep(data: png), let image = rep.cgImage else { return nil }
        let width = image.width, height = image.height
        var bytes = [UInt8](repeating: 0, count: width * height * 4)
        let context = CGContext(data: &bytes, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width * 4,
                                space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
        return (stride(from: 3, to: bytes.count, by: 4).map { bytes[$0] }, width, height)
    }

    // Trackpad: a transparent picture cropped to the strokes.
    guard let drawn = pixels(handwriting()) else { check(false, "strokes make a PNG"); return }
    check(drawn.alpha.first == 0 && drawn.alpha.last == 0, "transparent around the ink")
    check(drawn.alpha.contains { $0 > 200 }, "the strokes are solid")
    check(drawn.width < 1000 && drawn.height < 280, "cropped to the ink: \(drawn.width)×\(drawn.height)")
    check(SignatureInk.png(strokes: [], canvas: CGSize(width: 100, height: 100)) == nil, "no strokes, no signature")

    // A photo of paper: uneven light grey with a dark signature; only the ink stays.
    let width = 800, height = 400
    let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0, space: CGColorSpace(name: CGColorSpace.sRGB)!,
                            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
    for x in stride(from: 0, to: width, by: 20) {
        context.setFillColor(CGColor(srgbRed: 0.80 + Double(x) / Double(width) * 0.1, green: 0.79 + Double(x) / Double(width) * 0.1, blue: 0.75, alpha: 1))
        context.fill(CGRect(x: x, y: 0, width: 20, height: height))
    }
    context.setStrokeColor(CGColor(srgbRed: 0.1, green: 0.1, blue: 0.2, alpha: 1))
    context.setLineWidth(5)
    context.move(to: CGPoint(x: 200, y: 200))
    context.addCurve(to: CGPoint(x: 600, y: 220), control1: CGPoint(x: 300, y: 320), control2: CGPoint(x: 450, y: 80))
    context.strokePath()
    guard let photo = context.makeImage(), let extracted = SignatureInk.extract(from: photo), let ink = pixels(extracted) else {
        check(false, "a photographed signature gives ink"); return
    }
    check(ink.width < 500 && ink.height < 220, "cropped to the signature: \(ink.width)×\(ink.height)")
    check(ink.alpha.first == 0 && ink.alpha.contains { $0 > 200 }, "paper gone, ink kept")
    // Blank paper has no signature.
    let blank = CGContext(data: nil, width: 400, height: 200, bitsPerComponent: 8, bytesPerRow: 0, space: CGColorSpace(name: CGColorSpace.sRGB)!,
                          bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
    blank.setFillColor(CGColor(srgbRed: 0.9, green: 0.9, blue: 0.88, alpha: 1))
    blank.fill(CGRect(x: 0, y: 0, width: 400, height: 200))
    check(SignatureInk.extract(from: blank.makeImage()!) == nil, "blank paper gives nothing")
}

/// Typed in a script font and imported from a picture (features #82), into the library like any other signature; the
/// sheet's Type and Picture panes give the same pictures.
@MainActor
private func signTypedAndImported() {
    func image(_ png: Data?) -> CGImage? { png.flatMap { NSBitmapImageRep(data: $0)?.cgImage } }
    /// Alpha and the colour of the most opaque pixel.
    func ink(_ png: Data?) -> (clearCorner: Bool, solid: Bool, rgb: (Int, Int, Int))? {
        guard let cg = image(png) else { return nil }
        let width = cg.width, height = cg.height
        var bytes = [UInt8](repeating: 0, count: width * height * 4)
        let context = CGContext(data: &bytes, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width * 4,
                                space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        context.draw(cg, in: CGRect(x: 0, y: 0, width: width, height: height))
        var best = 3
        for i in stride(from: 3, to: bytes.count, by: 4) where bytes[i] > bytes[best] { best = i }
        let alpha = max(Int(bytes[best]), 1)
        return (bytes[3] == 0, bytes[best] > 200, (Int(bytes[best - 3]) * 255 / alpha, Int(bytes[best - 2]) * 255 / alpha, Int(bytes[best - 1]) * 255 / alpha))
    }

    // Typed.
    check(!SignatureInk.scriptFonts.isEmpty, "this Mac has script fonts to type with: \(SignatureInk.scriptFonts)")
    guard let font = SignatureInk.scriptFonts.first else { return }
    let typed = SignatureInk.typed("Ada Lovelace", fontName: font)
    if let found = ink(typed), let cg = image(typed) {
        check(found.clearCorner && found.solid, "a typed name is solid ink on a clear background")
        check(found.rgb.2 > found.rgb.0 && found.rgb.0 < 60, "in the ink colour: \(found.rgb)")
        check(cg.width > cg.height * 2 && cg.width < 2000, "cropped to the name: \(cg.width)×\(cg.height)")
    } else { check(false, "typing makes a signature") }
    check(SignatureInk.typed("   ", fontName: font) == nil, "no name, no signature")
    check(SignatureInk.typed("Ada", fontName: "NoSuchScript-Font") == nil, "an unknown style makes nothing")
    let longer = image(SignatureInk.typed("Ada Augusta Lovelace", fontName: font))
    check((longer?.width ?? 0) > (image(typed)?.width ?? 0), "a longer name is a wider signature")

    // Imported: a scan on white keeps only its ink; a transparent PNG keeps its own colours; a blank picture gives nothing.
    let size = (width: 600, height: 240)
    func picture(transparent: Bool, ink colour: CGColor?) -> CGImage {
        let context = CGContext(data: nil, width: size.width, height: size.height, bitsPerComponent: 8, bytesPerRow: 0,
                                space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        if !transparent {
            context.setFillColor(CGColor(gray: 1, alpha: 1))
            context.fill(CGRect(x: 0, y: 0, width: size.width, height: size.height))
        }
        if let colour {
            context.setStrokeColor(colour)
            context.setLineWidth(6)
            context.move(to: CGPoint(x: 100, y: 120))
            context.addCurve(to: CGPoint(x: 500, y: 130), control1: CGPoint(x: 220, y: 230), control2: CGPoint(x: 360, y: 20))
            context.strokePath()
        }
        return context.makeImage()!
    }
    let scanned = SignatureInk.imported(picture(transparent: false, ink: CGColor(srgbRed: 0.05, green: 0.05, blue: 0.05, alpha: 1)))
    if let found = ink(scanned) {
        check(found.clearCorner && found.solid, "an imported scan loses its paper")
        check(found.rgb.2 > found.rgb.0, "and its ink takes the signature colour: \(found.rgb)")
    } else { check(false, "an imported scan gives ink") }
    let clear = picture(transparent: true, ink: CGColor(srgbRed: 0, green: 0.3, blue: 0.9, alpha: 1))
    check(SignatureInk.hasTransparency(clear) && !SignatureInk.hasTransparency(picture(transparent: false, ink: nil)), "see-through pictures are told apart")
    if let found = ink(SignatureInk.imported(clear)), let cg = image(SignatureInk.imported(clear)) {
        check(found.rgb.2 > 200 && found.rgb.0 < 30, "a transparent signature keeps its own blue: \(found.rgb)")
        check(cg.width < size.width && cg.height < size.height, "cropped to what shows: \(cg.width)×\(cg.height)")
    } else { check(false, "a transparent signature imports") }
    check(SignatureInk.imported(picture(transparent: false, ink: nil)) == nil, "a blank picture is no signature")

    // Both go into the library and come back.
    let folder = SuperPDFPaths.ensure(signFolder.appendingPathComponent("typed-imported", isDirectory: true))
    let service = SignService(keys: MemorySigningKeyStore(), signatureKey: MemorySignatureKey(), signaturesFolder: folder)
    let entries = [typed, scanned].compactMap { $0 }.map { SavedSignature(kind: .signature, image: $0) }
    for entry in entries { try? service.save(entry) }
    check(entries.count == 2 && service.savedSignatures.map(\.image) == entries.map(\.image), "typed and imported signatures are in the library")

    // The sheet's panes make the same pictures (nothing is shown; a file stands in for the open panel).
    let pane = TypePane()
    check(pane.png() == nil, "the Type pane starts empty")
    let file = folder.appendingPathComponent("signature.png")
    if let data = NSBitmapImageRep(cgImage: clear).representation(using: .png, properties: [:]) { try? data.write(to: file) }
    let picturePane = PicturePane()
    picturePane.use(file)
    check(picturePane.png == SignatureInk.imported(clear), "the Picture pane imports a chosen file")
    picturePane.use(folder.appendingPathComponent("missing.png"))
    check(picturePane.png == nil, "an unreadable picture is refused")
}

// MARK: - Certificate signing (features #82, #83, §3.6)

@MainActor
private func signCertificateSigning() {
    let sign = signSetUp()
    guard let identity = signRun("create identity", { try await sign.createIdentity(name: "Priya Natarajan", email: "priya@example.com") }) else { return }
    check(identity.commonName == "Priya Natarajan" && identity.email == "priya@example.com" && identity.isSelfSigned, "identity: \(identity)")
    check(Calendar.current.dateComponents([.year], from: Date(), to: identity.notAfter).year ?? 0 >= 9, "10-year certificate")
    check(sign.identities.map(\.id) == [identity.id], "identity listed")
    let exported = signFile("priya.cer")
    try? sign.exportCertificate(of: identity.id, to: exported)
    check((try? Data(contentsOf: exported)).map { SecCertificateCreateWithData(nil, $0 as CFData) != nil } ?? false, "public certificate exports as DER")

    let original = signFile("Contract.pdf", makePDF(pages: 2))
    let signed = signFile("Contract (signed).pdf")
    let options = CertificateSignOptions(identityID: identity.id, page: 1, rect: CGRect(x: 320, y: 80, width: 220, height: 60),
                                         reason: "I agree", location: "Bath")
    guard signRun("sign", { try await sign.sign(.file(original), options: options, to: signed) }) != nil,
          let data = try? Data(contentsOf: signed) else { return }

    // The original bytes are untouched at the front (an appended update), and the file opens in PDFKit and QPDF.
    let originalData = (try? Data(contentsOf: original)) ?? Data()
    check(data.prefix(originalData.count) == originalData, "appended to the original bytes")
    check(PDFDocument(data: data)?.pageCount == 2, "signed file opens in PDFKit")
    guard let model = try? PDFModel(data: data) else { check(false, "signed file opens in QPDF"); return }
    check(model.check().isEmpty, "QPDF finds no problems: \(model.check())")
    let infos = model.signatures()
    check(infos.count == 1 && infos.first?.subFilter == "ETSI.CAdES.detached" && infos.first?.reason == "I agree"
          && infos.first?.location == "Bath" && infos.first?.certificationPermissions == nil, "one PAdES approval signature")
    guard let info = infos.first, let covered = info.signedBytes(of: data) else { return }
    check(info.byteRange[0] == 0 && info.byteRange[2] + info.byteRange[3] == data.count, "ByteRange covers the whole file")

    // Our verifier: valid (the person's own certificate is trusted on their Mac).
    let reports = signRun("verify", { try await sign.verify(.data(data)) }) ?? []
    check(reports.count == 1 && reports.first?.validity == .valid && reports.first?.changedAfterSigning == false, "verified valid: \(reports)")
    check(reports.first?.signerName == "Priya Natarajan" && reports.first?.chain == ["Priya Natarajan"], "signer and chain")

    // OpenSSL agrees on the CMS (digest and signature over the ByteRange), and PAdES' attributes are there.
    let cms = trimmedCMS(info.contents)
    if let ok = opensslVerifies(cms: cms, content: covered) { check(ok, "openssl cms -verify accepts the signature") }
    let signingCertificateV2 = Data([0x06, 0x0B, 0x2A, 0x86, 0x48, 0x86, 0xF7, 0x0D, 0x01, 0x09, 0x10, 0x02, 0x2F])
    let signingTime = Data([0x06, 0x09, 0x2A, 0x86, 0x48, 0x86, 0xF7, 0x0D, 0x01, 0x09, 0x05])
    check(cms.range(of: signingCertificateV2) != nil && cms.range(of: signingTime) == nil, "PAdES-B-B: signing-certificate-v2, no signing-time")

    // The visible box shows the name.
    if let shown = PDFDocument(data: data), let page = shown.page(at: 1) {
        check(ink(page, in: CGRect(x: 320, y: 80, width: 220, height: 60)) > 0.01, "the signature box is drawn")
        saveRender(page, "certificate-box")
    }

    // Tampering inside the signed range: the digest no longer matches.
    var tampered = data
    let target = info.byteRange[1] / 2
    tampered[tampered.startIndex + target] = tampered[tampered.startIndex + target] == 0x20 ? 0x0A : 0x20
    let tamperedReports = signRun("verify tampered", { try await sign.verify(.data(tampered)) }) ?? []
    check(tamperedReports.first?.validity == .modified, "tampered bytes are reported: \(tamperedReports.map(\.validity))")

    // A second signature keeps the first valid.
    let twice = signFile("Contract (signed twice).pdf")
    let second = CertificateSignOptions(identityID: identity.id, page: 0, rect: nil, reason: "Witness")
    guard signRun("sign again", { try await sign.sign(.file(signed), options: second, to: twice) }) != nil, let both = try? Data(contentsOf: twice) else { return }
    let bothReports = signRun("verify both", { try await sign.verify(.data(both)) }) ?? []
    check(bothReports.count == 2 && bothReports.allSatisfy { $0.validity == .valid } && bothReports.allSatisfy { !$0.changedAfterSigning },
          "two signatures, both valid, a later signature is an allowed change: \(bothReports.map { ($0.validity, $0.changedAfterSigning) })")
}

/// Appended updates after a signature: annotations and form fills are allowed, page content isn't; a locked
/// (certified, DocMDP P=1) document allows nothing.
@MainActor
private func signChangesAfterSigning() {
    let sign = signSetUp()
    guard let identity = signRun("identity", { try await sign.createIdentity(name: "Margaret Ellison", email: nil) }) else { return }
    let original = signFile("Changes.pdf", makePDF(pages: 1))
    let approved = signFile("Changes (signed).pdf"), locked = signFile("Changes (locked).pdf")
    _ = signRun("approve") { try await sign.sign(.file(original), options: CertificateSignOptions(identityID: identity.id), to: approved) }
    _ = signRun("lock") { try await sign.sign(.file(original), options: CertificateSignOptions(identityID: identity.id, lockDocument: true), to: locked) }
    guard let approval = try? Data(contentsOf: approved), let certified = try? Data(contentsOf: locked) else { check(false, "signed fixtures"); return }
    check((try? PDFModel(data: certified))?.signatures().first?.certificationPermissions == 1, "Lock the document: a certification signature, P=1")

    func note(_ model: PDFModel, _ page: PDFModelKit.PDFPage) {
        page.addAnnotation(model.makeIndirect(.dictionary(["Type": .name("Annot"), "Subtype": .name("Text"),
                                                           "Rect": .rect(CGRect(x: 50, y: 50, width: 20, height: 20)), "Contents": .text("Looks good")])))
    }
    func content(_ model: PDFModel, _ page: PDFModelKit.PDFPage) { page.addContent(Data("q 1 0 0 rg 100 100 50 50 re f Q".utf8)) }

    func changed(_ data: Data?) -> Bool? {
        guard let data else { return nil }
        return (signRun("verify") { try await sign.verify(.data(data)) } ?? []).first.map { $0.validity == .valid ? $0.changedAfterSigning : true }
    }
    check(changed(appendUpdate(approval, page: 0, note)) == false, "a comment after an approval signature is allowed")
    check(changed(appendUpdate(approval, page: 0, content)) == true, "drawing on the page after signing is a change")
    check(changed(appendUpdate(certified, page: 0, note)) == true, "a locked document allows no comment")
}

/// A file rebuilt by recovery is saved whole first, then signed; a password-protected one is refused with the reason.
@MainActor
private func signRepairedAndEncrypted() {
    let sign = signSetUp()
    guard let identity = signRun("identity", { try await sign.createIdentity(name: "Repair Person", email: nil) }) else { return }

    // Break the cross-reference offset: QPDF recovers it, and an appended update would be refused.
    var damaged = makePDF(pages: 1)
    if let range = damaged.range(of: Data("startxref".utf8), options: .backwards) {
        let start = range.upperBound + 1
        damaged.replaceSubrange(start..<(start + 2), with: Data("99".utf8))
    }
    check((try? PDFModel(data: damaged))?.wasRepaired == true, "the fixture needs recovery")
    let repairedOut = signFile("Damaged (signed).pdf")
    _ = signRun("sign repaired") {
        try await sign.sign(.data(damaged), options: CertificateSignOptions(identityID: identity.id, rect: CGRect(x: 72, y: 72, width: 200, height: 50)),
                            to: repairedOut)
    }
    let repaired = (try? Data(contentsOf: repairedOut)).flatMap { data in signRun("verify repaired") { try await sign.verify(.data(data)) } } ?? []
    check(repaired.first?.validity == .valid && repaired.first?.changedAfterSigning == false, "signed after a whole save: \(repaired)")

    // Encrypted: the Sign panel says why.
    guard let model = try? PDFModel(data: makePDF(pages: 1)),
          let encrypted = try? model.data(options: PDFWriteOptions(encryption: .encrypt(PDFEncryption(userPassword: "", ownerPassword: "owner")))) else {
        check(false, "encrypted fixture"); return
    }
    let url = signFile("Locked.pdf", encrypted)
    let document = DocumentHandle(url: url, pdf: PDFDocument(url: url)!, undoManager: makeUndoManager())
    let viewer = SignTestViewer()
    Services.viewer = viewer
    let pdfView = viewer.attach(document)
    let session = ToolSession(tool: .sign, provider: signProviderInstance, document: document)
    session.set("kind", .string("certificate"))
    guard let host = customView(session.panel, "seal") else { check(false, "the certificate box view"); return }
    viewer.host(host)
    click(pdfView, page: 0, at: CGPoint(x: 300, y: 300))
    _ = signRun("sync") { await session.perform("board-changed") }
    _ = signRun("run encrypted") { await session.run() }
    check(session.message?.text == "This file has a password. Remove the password first, then sign it.", "encrypted: \(session.message?.text ?? "-")")
}

/// Someone else's certificate: valid maths, untrusted until the person trusts it; then valid.
@MainActor
private func signTrust() {
    let sign = signSetUp()
    let other = SignService(keys: MemorySigningKeyStore(), signatureKey: MemorySignatureKey(),
                            signaturesFolder: SuperPDFPaths.ensure(signFolder.appendingPathComponent("other", isDirectory: true)))
    guard let theirs = signRun("their identity", { try await other.createIdentity(name: "Landlord Ltd", email: "office@example.com") }) else { return }
    let out = signFile("From the landlord.pdf")
    _ = signRun("they sign") { try await other.sign(.data(makePDF(pages: 1)), options: CertificateSignOptions(identityID: theirs.id), to: out) }
    guard let data = try? Data(contentsOf: out) else { return }
    let before = signRun("verify") { try await sign.verify(.data(data)) } ?? []
    check(before.first?.validity == .untrusted, "someone unknown: untrusted, \(before.map(\.validity))")
    guard let certificate = before.first?.certificate, let trusted = try? sign.trust(certificate) else { check(false, "trust"); return }
    check(trusted.commonName == "Landlord Ltd" && trusted.email == "office@example.com", "trusted: \(trusted)")
    check(signRun("verify trusted") { try await sign.verify(.data(data)) }?.first?.validity == .valid, "trusted: valid")
    try? sign.untrust(trusted.id)
    check(signRun("verify untrusted") { try await sign.verify(.data(data)) }?.first?.validity == .untrusted, "untrusted again")
}

/// "Add a trusted timestamp": the TSA's token goes in as an unsigned attribute; the signature stays valid.
@MainActor
private func signTimestamp() {
    let sign = signSetUp()
    guard let identity = signRun("identity", { try await sign.createIdentity(name: "Stamp Person", email: nil) }) else { return }
    // The TSA's answer: status granted and a token (a stand-in ContentInfo; the server is this closure, no network).
    let token = Data([0x30, 0x0B, 0x06, 0x09, 0x2A, 0x86, 0x48, 0x86, 0xF7, 0x0D, 0x01, 0x07, 0x02])
    let response = Data([0x30, 0x12, 0x30, 0x03, 0x02, 0x01, 0x00]) + token
    final class Asked: @unchecked Sendable { var request: URLRequest? }
    let asked = Asked()
    sign.timestampTransport = { request in asked.request = request; return response }
    let out = signFile("Stamped.pdf")
    let options = CertificateSignOptions(identityID: identity.id, timestampServer: URL(string: "https://tsa.example.com")!)
    _ = signRun("sign with timestamp") { try await sign.sign(.data(makePDF(pages: 1)), options: options, to: out) }
    guard let data = try? Data(contentsOf: out), let info = (try? PDFModel(data: data))?.signatures().first else { check(false, "stamped file"); return }
    check(asked.request?.value(forHTTPHeaderField: "Content-Type") == "application/timestamp-query" && asked.request?.httpMethod == "POST",
          "an RFC 3161 query")
    check(trimmedCMS(info.contents).range(of: token) != nil, "the token is in the CMS")
    check(signRun("verify") { try await sign.verify(.data(data)) }?.first?.validity == .valid, "still valid")
}

// MARK: - The Sign panel, driven on the page

@MainActor
private func signPanelPlacement() {
    let sign = signSetUp()
    let viewer = SignTestViewer()
    Services.viewer = viewer
    let document = signDocument("Lease agreement")
    let pdfView = viewer.attach(document)
    try? sign.save(SavedSignature(kind: .signature, image: handwriting()))
    try? sign.save(SavedSignature(kind: .initials, image: handwriting(initials: true)))

    Defaults.reset(ToolSession.valuesKey(.sign))
    let session = ToolSession(tool: .sign, provider: signProviderInstance, document: document)
    guard let pads = customView(session.panel, "pads") else { check(false, "the signature cards"); return }
    viewer.host(pads)
    check(pads.fittingSize.height >= 84 * 2, "two cards: \(pads.fittingSize)")

    // The chosen card (the signature) goes where the page is clicked, with today's date under it.
    click(pdfView, page: 1, at: CGPoint(x: 435, y: 230))
    _ = signRun("sync") { await session.perform("board-changed") }
    check(session.canRun, "a placed signature enables Sign and save…")
    // Initials: click their card, then the page; then drag them somewhere else.
    guard let cards = pads.subviews.first(where: { $0 is LibraryCards }) else { check(false, "the cards in their host"); return }
    press(cards, at: NSPoint(x: 140, y: 84 + 14 + 40))
    click(pdfView, page: 1, at: CGPoint(x: 150, y: 400))
    click(pdfView, page: 1, at: CGPoint(x: 150, y: 400), dragTo: CGPoint(x: 160, y: 120))
    session.set("text", .string("PRIYA NATARAJAN"))
    _ = signRun("preview") { await session.updatePreview() }
    if case .overlay(let draw) = session.preview, let page = document.pdf.page(at: 1) {
        // The live preview draws the placements on the page.
        let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: 612, pixelsHigh: 792, bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true,
                                   isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
        let context = NSGraphicsContext(bitmapImageRep: rep)!
        context.cgContext.setFillColor(.white)
        context.cgContext.fill(CGRect(x: 0, y: 0, width: 612, height: 792))
        page.draw(with: .mediaBox, to: context.cgContext)
        draw(page, context.cgContext)
        try? rep.representation(using: .png, properties: [:])?.write(to: renderFolder.appendingPathComponent("signkit-sign-preview.png"))
    } else {
        check(false, "the placements are previewed on the page")
    }

    var saved: Data?
    session.onFinish = { result in if case .newFile(let url, _) = result { saved = try? Data(contentsOf: url) } }
    guard case .newFile(_, let banner)?? = signRun("sign and save", { await session.run() }), let out = saved else {
        check(false, "Sign and save writes a file: \(session.message?.text ?? "-")"); return
    }
    check(banner.text == "Signed and saved “Lease agreement (signed).pdf”.", "banner: \(banner.text)")
    let original = (try? Data(contentsOf: document.url!)) ?? Data()
    check(out.prefix(original.count) == original, "the signed copy is an appended update; the original file is untouched")
    guard let pdf = PDFDocument(data: out), let page = pdf.page(at: 1) else { check(false, "opens in PDFKit"); return }
    let stamps = page.annotations.filter { $0.type == "Stamp" }
    check(Set(stamps.compactMap(\.contents)) == ["Signature", "Date", "Initials", "PRIYA NATARAJAN"], "labelled stamps: \(stamps.compactMap(\.contents))")
    for stamp in stamps { check(ink(page, in: stamp.bounds) > 0.01, "\(stamp.contents ?? "-") renders ink at \(stamp.bounds)") }
    if let initialsStamp = stamps.first(where: { $0.contents == "Initials" }) {
        check(abs(initialsStamp.bounds.midX - 160) < 2 && abs(initialsStamp.bounds.midY - 120) < 2, "dragged initials landed: \(initialsStamp.bounds)")
    }
    check((try? PDFModel(data: out))?.check().isEmpty ?? false, "QPDF reads the stamps")
    saveRender(page, "sign-placed")
}

@MainActor
private func signCertificatePanel() {
    let sign = signSetUp()
    let viewer = SignTestViewer()
    Services.viewer = viewer
    let document = signDocument("Contract")
    let pdfView = viewer.attach(document)
    try? sign.save(SavedSignature(kind: .signature, image: handwriting()))
    guard let identity = signRun("identity", { try await sign.createIdentity(name: "Priya Natarajan", email: nil) }) else { return }

    let session = ToolSession(tool: .sign, provider: signProviderInstance, document: document)
    session.set("kind", .string("certificate"))
    check(session.canRun, "a certificate is enough to sign (invisible without a box)")
    check(session.panel.controls.compactMap(\.id).starts(with: ["kind", "identity", "createIdentity", "reason", "lock"]),
          "certificate controls: \(session.panel.controls.compactMap(\.id))")
    session.set("reason", .string("I agree to the terms"))
    session.set("lock", .bool(true))
    guard let seal = customView(session.panel, "seal") else { check(false, "the appearance preview"); return }
    viewer.host(seal)
    click(pdfView, page: 0, at: CGPoint(x: 435, y: 240))
    _ = signRun("sync") { await session.perform("board-changed") }

    var saved: Data?
    session.onFinish = { result in if case .newFile(let url, _) = result { saved = try? Data(contentsOf: url) } }
    _ = signRun("sign") { await session.run() }
    guard let out = saved, let info = (try? PDFModel(data: out))?.signatures().first else { check(false, "signed: \(session.message?.text ?? "-")"); return }
    check(info.page == 0 && info.reason == "I agree to the terms" && info.certificationPermissions == 1, "the box, the reason and the lock: \(info)")
    let box = info.rect ?? .zero
    check(abs(box.midX - 435) < 1 && abs(box.midY - 240) < 1 && box.width == 220, "where it was clicked: \(box)")
    let reports = signRun("verify") { try await sign.verify(.data(out)) } ?? []
    check(reports.first?.validity == .valid && reports.first?.signerName == identity.commonName, "valid: \(reports)")
    if let shown = PDFDocument(data: out), let page = shown.page(at: 0) {
        check(ink(page, in: box) > 0.02, "handwriting and the facts are drawn in the box")
        saveRender(page, "sign-certificate")
    }
    check(Defaults[.defaultCertificateID] == identity.id, "the certificate is remembered")
}

@MainActor
private func signCertificatesTile() {
    let sign = signSetUp()
    let other = SignService(keys: MemorySigningKeyStore(), signatureKey: MemorySignatureKey(),
                            signaturesFolder: SuperPDFPaths.ensure(signFolder.appendingPathComponent("other2", isDirectory: true)))
    guard let theirs = signRun("their identity", { try await other.createIdentity(name: "Margaret Ellison", email: nil) }) else { return }
    let url = signFile("Signed by Margaret.pdf")
    _ = signRun("sign") { try await other.sign(.data(makePDF(pages: 1)), options: CertificateSignOptions(identityID: theirs.id), to: url) }
    let document = DocumentHandle(url: url, pdf: PDFDocument(url: url)!, undoManager: makeUndoManager())
    let session = ToolSession(tool: .certificates, provider: signProviderInstance, document: document)
    check(session.panel.controls.contains { if case .note("Checking signatures…") = $0 { true } else { false } }, "checking first")
    _ = signRun("preview") { await session.updatePreview() }
    func buttons() -> [String] {
        guard let rows = customView(session.panel, "reports") else { return ["(no rows)"] }
        func all(_ view: NSView) -> [NSView] { [view] + view.subviews.flatMap(all) }
        return all(rows).compactMap { $0 as? NSButton }.map(\.title)
    }
    check(buttons() == ["Trust this person"], "untrusted: Trust this person, \(buttons())")
    _ = signRun("trust") { await session.perform("trust.0") }
    _ = signRun("preview again") { await session.updatePreview() }
    check(sign.trustedCertificates.map(\.commonName) == ["Margaret Ellison"], "trusted")
    check(buttons().isEmpty, "now valid, nothing to do: \(buttons())")

    session.set("tab", .string("trusted"))
    check(session.panel.controls.contains { $0.id?.hasPrefix("trusted.") == true }, "People I trust lists them")
    session.set("tab", .string("mine"))
    check(session.panel.controls.contains { if case .note("You don’t have a certificate yet.") = $0 { true } else { false } }, "no certificate yet")
}

// MARK: - Request signatures (features #84): package → returns → seal

@MainActor
private func signRequestRoundTrip() {
    let sharing = RecordingSharing()
    let sign = signSetUp(sharing: sharing)
    let viewer = SignTestViewer()
    Services.viewer = viewer
    let requests = Services.requests!
    let document = signDocument("Lease agreement")
    let pdfView = viewer.attach(document)

    // Step 1: two people, typed.
    Defaults.reset(ToolSession.valuesKey(.requestSignatures))
    let session = ToolSession(tool: .requestSignatures, provider: signProviderInstance, document: document)
    guard let editor = customView(session.panel, "people") else { check(false, "the people editor"); return }
    viewer.host(editor)
    func all(_ view: NSView) -> [NSView] { [view] + view.subviews.flatMap(all) }
    let fields = all(editor).compactMap { $0 as? NSTextField }.filter(\.isEditable)
    let add = all(editor).compactMap { $0 as? NSButton }.first { $0.title == "Add person" }
    guard fields.count == 2, let add else { check(false, "name and email fields and Add person"); return }
    for (name, email) in [("Margaret Ellison", "m.ellison@orchardlets.co.uk"), ("Priya Natarajan", "priya.natarajan@example.com")] {
        fields[0].stringValue = name
        fields[1].stringValue = email
        add.performClick(nil)
    }
    _ = signRun("people") { await session.perform("board-changed") }
    check(session.canRun && session.panel.primary.title == "Next: Where", "two people: Next: Where")
    session.set("order", .bool(true))
    session.next()

    // Step 2: Margaret's signature and date, then Priya's signature.
    check(session.panel.primary.title == "Next: Send" && !session.canRun, "Next: Send waits for everyone's field")
    guard let picker = customView(session.panel, "signers") else { check(false, "the people rows"); return }
    viewer.host(picker)
    click(pdfView, page: 1, at: CGPoint(x: 160, y: 220))
    session.set("field", .strings(["date"]))
    click(pdfView, page: 1, at: CGPoint(x: 160, y: 170))
    _ = signRun("fields") { await session.perform("board-changed") }
    check(session.message?.text == "Give each person at least one place to sign.", "Priya has no field yet: \(session.message?.text ?? "-")")
    let rows = all(picker).filter { String(describing: type(of: $0)) == "SignerRow" }
    guard rows.count == 2 else { check(false, "a row per person: \(rows.count)"); return }
    press(rows[1], at: NSPoint(x: 100, y: 20))
    session.set("field", .strings(["signature"]))
    click(pdfView, page: 1, at: CGPoint(x: 420, y: 220))
    _ = signRun("fields") { await session.perform("board-changed") }
    check(session.canRun, "everyone has a field")
    _ = signRun("preview") { await session.updatePreview() }
    if case .overlay(let draw) = session.preview, let page = document.pdf.page(at: 1) {
        let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: 612, pixelsHigh: 792, bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true,
                                   isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
        let context = NSGraphicsContext(bitmapImageRep: rep)!
        context.cgContext.setFillColor(.white)
        context.cgContext.fill(CGRect(x: 0, y: 0, width: 612, height: 792))
        page.draw(with: .mediaBox, to: context.cgContext)
        draw(page, context.cgContext)
        try? rep.representation(using: .png, properties: [:])?.write(to: renderFolder.appendingPathComponent("signkit-request-preview.png"))
    } else {
        check(false, "the fields are previewed on the page")
    }
    session.next()

    // Step 3: Send with Mail: the package goes to the first person (sign in this order).
    check(session.panel.primary.title == "Send with Mail", "step 3's button")
    _ = signRun("send") { await session.run() }
    guard let request = requests.requests.first, let sent = sharing.sent.first else { check(false, "the request was sent: \(session.message?.text ?? "-")"); return }
    check(sent.recipients == ["m.ellison@orchardlets.co.uk"] && sent.channel == .mail && sent.subject == "Please sign “Lease agreement”",
          "to Margaret first: \(sent.recipients), \(sent.subject)")
    check(viewer.banners.last?.text == "Sent to 1 person. We’ll match their files when they come back.", "banner: \(viewer.banners.last?.text ?? "-")")
    check(request.signers.map(\.state) == [.waiting, .waiting] && request.fields.count == 3 && request.signInOrder, "stored: \(request)")

    // The package: a cover, the pages, the fields and request.json.
    guard let package = try? Data(contentsOf: sent.file), let model = try? PDFModel(data: package), let pdf = PDFDocument(data: package) else {
        check(false, "the package opens"); return
    }
    check(model.pageCount == 3 && pdf.pageCount == 3, "cover + 2 pages")
    check(pdf.page(at: 0)?.string?.contains(request.id.uuidString.lowercased()) == true, "the cover carries the reference")
    check(pdf.page(at: 0)?.string?.contains("Open in any PDF app, sign in the highlighted spots, send it back.") == true, "the cover explains")
    let decoder = JSONDecoder()
    decoder.dateDecodingStrategy = .iso8601
    let manifest = (try? model.embeddedFileData(named: SigningPackageManifest.attachmentName)).flatMap { try? decoder.decode(SigningPackageManifest.self, from: $0) }
    check(manifest?.requestID == request.id && manifest?.signers.map(\.name) == ["Margaret Ellison", "Priya Natarajan"], "request.json round-trips")
    let names = model.formFields().map(\.name)
    check(names.count == 3 && names.allSatisfy { $0.hasPrefix("sp-" + request.id.uuidString.lowercased().prefix(8)) }, "fields: \(names)")
    check(model.formFields().filter { $0.type == "Sig" }.count == 2 && model.formFields().contains { $0.type == "Tx" }, "two signature fields and a text field")
    if let first = pdf.page(at: 0), let page = pdf.page(at: 2) { saveRender(first, "request-cover"); saveRender(page, "request-fields") }

    // Margaret signs in another app (it rewrites the file): her name as a free-text note, the date typed into its field.
    guard let other = PDFDocument(data: package), let page = other.page(at: 2) else { return }
    let sigField = request.fields.first { $0.kind == .signature && $0.signerID == request.signers[0].id }!
    let note = PDFAnnotation(bounds: sigField.rect, forType: .freeText, withProperties: nil)
    note.contents = "Margaret Ellison"
    note.font = NSFont(name: "Snell Roundhand", size: 20) ?? .systemFont(ofSize: 20)
    note.fontColor = .black
    note.color = .clear
    page.addAnnotation(note)
    page.annotations.first { $0.fieldName?.contains("-date-") == true }?.widgetStringValue = "21 Oct 2026"
    let returned = signFile("Lease agreement – Margaret.pdf", other.dataRepresentation()!)

    // Opened in Super PDF, it is matched and merged, with a banner.
    _ = signRun("open returned") { try await Services.documents.open(returned) }
    check(waitUntil { requests.requests.first?.signers[0].state == .done }, "Margaret is done: \(requests.requests.first?.signers.map(\.state) ?? [])")
    check(viewer.banners.last?.text == "“Lease agreement” came back from Margaret Ellison.", "banner: \(viewer.banners.last?.text ?? "-")")
    let current = SuperPDFPaths.request(request.id).appendingPathComponent("current/Lease agreement.pdf")
    guard let merged = try? Data(contentsOf: current), let mergedPDF = PDFDocument(data: merged), let mergedPage = mergedPDF.page(at: 2) else {
        check(false, "the copy so far"); return
    }
    check(merged.prefix(package.count) == package, "her marks were appended to the package")
    check(mergedPage.annotations.filter { $0.type == "Stamp" }.count == 2, "her two fields came across: \(mergedPage.annotations.map { $0.type ?? "-" })")
    saveRender(mergedPage, "request-merged")

    // Priya signs in Super PDF with her certificate, in her field: an appended update to the copy so far.
    guard let identity = signRun("identity", { try await sign.createIdentity(name: "Priya Natarajan", email: nil) }) else { return }
    let priyaField = request.fields.first { $0.signerID == request.signers[1].id }!
    let priyaCopy = signFile("Lease agreement (signed).pdf")
    _ = signRun("priya signs") {
        try await sign.sign(.file(current), options: CertificateSignOptions(identityID: identity.id, page: priyaField.page + 1, rect: priyaField.rect),
                            to: priyaCopy)
    }
    guard let afterPriya = signRun("receive", { try await requests.receive(priyaCopy) }) ?? nil else { check(false, "Priya's copy is matched"); return }
    check(afterPriya.signers.map(\.state) == [.done, .done] && afterPriya.isComplete, "everyone signed: \(afterPriya.signers.map(\.state))")
    check((try? Data(contentsOf: current)) == (try? Data(contentsOf: priyaCopy)), "her appended update became the copy so far")
    check(signRun("same again", { try await requests.receive(priyaCopy) })??.signers.map(\.state) == [.done, .done], "the same file again changes nothing")

    // Seal and finish: an audit page, then the sender's certificate.
    guard let sealedURL = signRun("seal", { try await requests.seal(afterPriya, identityID: identity.id) }), let sealed = try? Data(contentsOf: sealedURL),
          let sealedPDF = PDFDocument(data: sealed) else { check(false, "sealed"); return }
    check(sealedURL.lastPathComponent == "Lease agreement (signed).pdf" && sealedPDF.pageCount == 4, "sealed copy: \(sealedURL.lastPathComponent)")
    check(sealedPDF.page(at: 3)?.string?.contains("Signature record") == true && sealedPDF.page(at: 3)?.string?.contains("Margaret Ellison") == true,
          "the audit page lists the people")
    let reports = signRun("verify sealed") { try await sign.verify(.data(sealed)) } ?? []
    check(reports.count == 2 && reports.last?.validity == .valid && reports.last?.changedAfterSigning == false, "the seal is valid: \(reports)")
    check(reports.first?.validity == .valid, "Priya's signature still checks out")
    check(requests.requests.first?.sealedAt != nil, "the request is sealed")
    if let audit = sealedPDF.page(at: 3) { saveRender(audit, "request-audit") }
}

// MARK: - The panels as ToolsKit draws them (for review next to panel-sign.png and panel-request-signatures.png)

@MainActor
private func signPanelRenders() {
    let sign = signSetUp()
    let viewer = SignTestViewer()
    Services.viewer = viewer
    let document = signDocument("Lease agreement")
    viewer.attach(document)
    try? sign.save(SavedSignature(kind: .signature, image: handwriting()))
    try? sign.save(SavedSignature(kind: .initials, image: handwriting(initials: true)))
    for tool in [ToolID.sign, .requestSignatures] { Defaults.reset(ToolSession.valuesKey(tool)) }
    Style.opaqueBackgrounds = true
    defer { Style.opaqueBackgrounds = false }
    let size = NSSize(width: SPMetrics.ToolPanel.width, height: SPMetrics.Window.defaultSize.height - SPMetrics.Window.toolbarHeight)

    func render(_ session: ToolSession, _ name: String) -> NSBitmapImageRep {
        let controller = ToolPanelController(session: session, onBack: {}, onClose: {})
        let window = NSWindow(contentRect: NSRect(origin: .zero, size: size), styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.appearance = NSAppearance(named: .aqua)
        window.contentView = controller.view
        controller.view.frame = NSRect(origin: .zero, size: size)
        controller.view.layoutSubtreeIfNeeded()
        RunLoop.main.run(until: Date().addingTimeInterval(0.05))
        controller.view.layoutSubtreeIfNeeded()
        controller.view.displayIfNeeded()
        let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: Int(size.width * 2), pixelsHigh: Int(size.height * 2), bitsPerSample: 8,
                                   samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
        rep.size = size
        window.appearance?.performAsCurrentDrawingAppearance { controller.view.cacheDisplay(in: controller.view.bounds, to: rep) }
        try? rep.representation(using: .png, properties: [:])?.write(to: renderFolder.appendingPathComponent("signkit-\(name).png"))
        return rep
    }

    let signSession = ToolSession(tool: .sign, provider: signProviderInstance, document: document)
    let signRep = render(signSession, "panel-sign")
    check(signRep.pixelsWide == Int(size.width * 2), "the Sign panel renders")

    let requestSession = ToolSession(tool: .requestSignatures, provider: signProviderInstance, document: document)
    guard let board = (signProviderInstance as? SignToolProvider)?.requestBoard(document) else { check(false, "the request board"); return }
    board.addSigner(name: "Margaret Ellison", email: "m.ellison@orchardlets.co.uk")
    board.addSigner(name: "Priya Natarajan", email: "priya.natarajan@example.com")
    for (signer, x) in zip(board.signers, [72.0, 330.0]) {
        board.fields.append(RequestField(kind: .signature, signerID: signer.id, page: 1, rect: CGRect(x: x, y: 205, width: 170, height: 34)))
        board.fields.append(RequestField(kind: .date, signerID: signer.id, page: 1, rect: CGRect(x: x + 175, y: 205, width: 60, height: 34)))
    }
    requestSession.set("order", .bool(true))
    requestSession.next()
    _ = render(requestSession, "panel-request-signatures")
    check(requestSession.panel.primary.title == "Next: Send" && requestSession.canRun, "step 2 with two people placed")
}
