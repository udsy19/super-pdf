import AppKit
import CoreImage
import CoreText
import FixKit
import PagesKit
import PDFKit
@testable import ScanKit
import SuperPDFCore
@testable import ToolsKit

// ScanKit's checks (WP14). No case touches a camera, an iPhone or a scanner: devices are fakes (a scanner browser that
// "scans" generated pictures, a Continuity Camera whose menu is a closure), and the picture pipeline runs on generated
// photo-like fixtures (a rendered page, warped onto a noisy desk, tilted, turned, bordered or greyed). Covered: sheet
// detection and perspective correction, each clean-up step and the whole pipeline's idempotence, the device list's
// state mapping, scanner and iPhone streams, and the three Scan panels driven through ToolsKit's `ToolSession` into
// the open PDF (undoable) or a new one, with FixKit's OCR when asked.
func registerScanKitTests() {
    SelfTest.cases.append(("ScanKit.install", { scanInstall() }))
    SelfTest.cases.append(("ScanKit.detect", { scanDetect() }))
    SelfTest.cases.append(("ScanKit.straighten", { scanStraighten() }))
    SelfTest.cases.append(("ScanKit.deskew", { scanDeskew() }))
    SelfTest.cases.append(("ScanKit.borders", { scanBorders() }))
    SelfTest.cases.append(("ScanKit.whiten", { scanWhiten() }))
    SelfTest.cases.append(("ScanKit.autoRotate", { scanAutoRotate() }))
    SelfTest.cases.append(("ScanKit.idempotent", { scanIdempotent() }))
    SelfTest.cases.append(("ScanKit.devices", { scanDevices() }))
    SelfTest.cases.append(("ScanKit.scannerStream", { scanScannerStream() }))
    SelfTest.cases.append(("ScanKit.continuity", { scanContinuity() }))
    SelfTest.cases.append(("ScanKit.scannerPanel", { scanScannerPanel() }))
    SelfTest.cases.append(("ScanKit.iPhonePanel", { scanIPhonePanel() }))
    SelfTest.cases.append(("ScanKit.photoPanel", { scanPhotoPanel() }))
}

// MARK: - Fixtures

private let pageSize = CGSize(width: 850, height: 1100)

private func scanFolder(_ name: String) -> URL {
    SuperPDFPaths.ensure(scratch.appendingPathComponent("ScanKit-\(name)-\(UUID().uuidString)", isDirectory: true))
}

/// A page of text on paper of `paper` grey (255 white), as a scanner would see it.
private func renderPage(paper: CGFloat = 1, size: CGSize = pageSize) -> CGImage {
    let context = CGContext(data: nil, width: Int(size.width), height: Int(size.height), bitsPerComponent: 8, bytesPerRow: 0,
                            space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue)!
    context.setFillColor(CGColor(gray: paper, alpha: 1))
    context.fill(CGRect(origin: .zero, size: size))
    context.setFillColor(CGColor(gray: 0.1, alpha: 1))
    context.fill(CGRect(x: 70, y: size.height - 150, width: 260, height: 50))
    let font = CTFontCreateWithName("Helvetica" as CFString, 30, nil)
    let lines = ["The quick brown fox jumps over", "the lazy dog while the band", "plays a slow waltz in the park.",
                 "Pack my box with five dozen", "liquor jugs before the night ends.", "Sphinx of black quartz, judge my vow.",
                 "How vexingly quick daft zebras jump.", "Bright vixens jump; dozy fowl quack."]
    for (index, text) in lines.enumerated() {
        let line = CTLineCreateWithAttributedString(NSAttributedString(string: text, attributes: [
            NSAttributedString.Key(kCTFontAttributeName as String): font,
            NSAttributedString.Key(kCTForegroundColorAttributeName as String): CGColor(gray: 0.05, alpha: 1),
        ]))
        context.textPosition = CGPoint(x: 70, y: size.height - 230 - CGFloat(index) * 70)
        CTLineDraw(line, context)
    }
    context.setStrokeColor(CGColor(gray: 0.2, alpha: 1))
    context.setLineWidth(3)
    context.stroke(CGRect(x: 70, y: 90, width: size.width - 140, height: 160))
    return context.makeImage()!
}

private func jpeg(_ image: CGImage) -> Data { try! ScanImage.encode(image) }
private func png(_ image: CGImage) -> Data { try! ScanImage.encode(image, lossless: true) }

/// The page photographed on a dark, grainy desk with its corners at `corners` (0…1, origin bottom-left: top-left,
/// top-right, bottom-right, bottom-left).
private func photo(of page: CGImage, corners: [CGPoint], canvas: CGSize = CGSize(width: 1600, height: 1200)) -> Data {
    func vector(_ p: CGPoint) -> CIVector { CIVector(x: p.x * canvas.width, y: p.y * canvas.height) }
    let warped = CIImage(cgImage: page).applyingFilter("CIPerspectiveTransform", parameters: [
        "inputTopLeft": vector(corners[0]), "inputTopRight": vector(corners[1]),
        "inputBottomRight": vector(corners[2]), "inputBottomLeft": vector(corners[3]),
    ])
    let desk = CIImage(color: CIColor(red: 0.22, green: 0.16, blue: 0.11)).cropped(to: CGRect(origin: .zero, size: canvas))
    let grain = CIFilter(name: "CIRandomGenerator")!.outputImage!.cropped(to: CGRect(origin: .zero, size: canvas))
        .applyingFilter("CIColorMatrix", parameters: ["inputAVector": CIVector(x: 0, y: 0, z: 0, w: 0),
                                                      "inputBiasVector": CIVector(x: 0, y: 0, z: 0, w: 0.08)])
    let shot = grain.composited(over: warped.composited(over: desk)).cropped(to: CGRect(origin: .zero, size: canvas))
    return jpeg(try! ScanImage.render(shot))
}

private let photoCorners = [CGPoint(x: 0.30, y: 0.86), CGPoint(x: 0.68, y: 0.84), CGPoint(x: 0.69, y: 0.18), CGPoint(x: 0.29, y: 0.20)]

/// The page turned `degrees` counter-clockwise on white, same size (a crooked sheet on a scanner).
private func tilted(_ page: CGImage, degrees: Double) -> CGImage {
    let image = CIImage(cgImage: page)
    return try! ScanImage.render(ScanCleaner.straightened(image, by: -degrees))
}

private func grey(_ data: Data) -> ScanImage.Grey { try! ScanImage.grey(try! ScanImage.decode(data)) }

/// Mean absolute luminance difference of two pictures, the second scaled to the first's size.
private func difference(_ a: Data, _ b: Data) -> Double {
    let first = try! ScanImage.decode(a)
    var second = try! ScanImage.decode(b)
    second = second.transformed(by: CGAffineTransform(scaleX: first.extent.width / second.extent.width,
                                                      y: first.extent.height / second.extent.height))
    let ga = try! ScanImage.grey(ScanImage.downscaled(first, longSide: 400).image)
    let gb = try! ScanImage.grey(ScanImage.downscaled(second.cropped(to: first.extent), longSide: 400).image)
    let count = min(ga.pixels.count, gb.pixels.count)
    guard count > 0, ga.width == gb.width else { return 255 }
    return Double((0..<count).reduce(0) { $0 + abs(Int(ga.pixels[$1]) - Int(gb.pixels[$1])) }) / Double(count)
}

private func page(_ image: CGImage, resolution: Double = 100) -> ScannedPage {
    ScannedPage(image: jpeg(image), pixelSize: CGSize(width: image.width, height: image.height), resolution: resolution)
}

private func only(_ options: (inout CleanUpOptions) -> Void) -> CleanUpOptions {
    var o = CleanUpOptions(deskew: false, removeBorders: false, despeckle: false, whitenBackground: false, autoRotate: false)
    options(&o)
    return o
}

// MARK: - Fakes

/// A scanner browser with scripted devices; a scan writes one PNG per sheet into the job's folder.
@MainActor
private final class FakeScannerBrowser: ScannerBrowsing {
    var scanners: [ScannerInfo] = []
    var onChange: (@MainActor ([ScannerInfo]) -> Void)?
    var started = 0
    var sheets: [CGImage] = []
    var jobs: [ScannerJob] = []
    var failure: ScanFailure?

    func start() { started += 1; onChange?(scanners) }
    func stop() {}

    func set(_ list: [ScannerInfo]) { scanners = list; onChange?(list) }

    func scan(_ scannerID: String, job: ScannerJob) -> AsyncThrowingStream<URL, Error> {
        jobs.append(job)
        let urls = sheets.enumerated().map { index, image -> URL in
            let url = job.folder.appendingPathComponent("Scan \(index + 1).png")
            try! png(image).write(to: url)
            return url
        }
        let failure = self.failure
        return AsyncThrowingStream { continuation in
            urls.forEach { continuation.yield($0) }
            if let failure { continuation.finish(throwing: failure) } else { continuation.finish() }
        }
    }
}

@MainActor
private func makeService(_ browser: FakeScannerBrowser, camera: ContinuityCamera? = nil) -> ScanService {
    let folder = scanFolder("sheets")
    return ScanService(scanners: browser, continuity: camera ?? ContinuityCamera(), folder: { folder })
}

/// Fakes, the real PagesKit (to insert pages) and a ScanKit over fake devices; remembered panel choices forgotten.
@MainActor
private func installScan(_ browser: FakeScannerBrowser, camera: ContinuityCamera? = nil) -> (ScanTools, FakeDocuments) {
    installFakes()
    let documents = FakeDocuments()
    Services.documents = documents
    PagesKitModule.install()
    let service = makeService(browser, camera: camera)
    Services.scan = service
    let tools = ScanTools(service: service)
    tools.browseWait = 0.2
    Services.toolProviders.append(tools)
    for tool in tools.tools { Defaults.reset(ToolSession.valuesKey(tool)) }
    return (tools, documents)
}

@MainActor
@discardableResult
private func run(_ session: ToolSession) -> ToolResult? {
    guard case .success(let result)? = (complete { await session.run() }) else { return nil }
    return result
}

@MainActor
private func collectPages(_ stream: AsyncThrowingStream<ScannedPage, Error>) -> Result<[ScannedPage], Error>? {
    complete {
        var pages: [ScannedPage] = []
        for try await page in stream { pages.append(page) }
        return pages
    }
}

// MARK: - Cases

@MainActor
private func scanInstall() {
    installFakes()
    ScanKitModule.install()
    check(Services.scan is ScanService, "Services.scan is ScanKit's service")
    let tools = Services.toolProviders.compactMap { $0 as? ScanTools }.first
    check(tools.map { Set($0.tools) == Set(ToolCatalog.tiles(ownedBy: .scanKit).map(\.id)) } == true, "the three Scan tiles")
    check(ToolCoverage.issues(Services.toolProviders, requireAll: false).isEmpty, "ScanKit covers its tiles exactly once")
    check(Services.scan.sources.map(\.kind) == [.continuityCamera], "before browsing only the iPhone row is listed")
}

@MainActor
private func scanDetect() {
    let shot = photo(of: renderPage(), corners: photoCorners)
    guard case .success(let found?)? = (complete { try await ScanService(scanners: FakeScannerBrowser()).detectDocument(in: shot) }) else {
        return check(false, "a sheet is found in the photo")
    }
    let corners = [found.topLeft, found.topRight, found.bottomRight, found.bottomLeft]
    let worst = zip(corners, photoCorners).map { hypot($0.x - $1.x, $0.y - $1.y) }.max() ?? 1
    check(worst < 0.03, "corners within 3% of where the sheet lies (worst \(worst))")
    let desk = jpeg(try! ScanImage.render(CIImage(color: CIColor(red: 0.22, green: 0.16, blue: 0.11))
        .cropped(to: CGRect(x: 0, y: 0, width: 1200, height: 900))))
    check((try? DocumentDetector.detect(in: desk)) == .some(nil), "an empty desk has no sheet")
}

@MainActor
private func scanStraighten() {
    let original = renderPage()
    let shot = photo(of: original, corners: photoCorners)
    let service = ScanService(scanners: FakeScannerBrowser())
    guard case .success(let page)? = (complete { () -> ScannedPage in
        let found = try await service.detectDocument(in: shot)
        return try await service.straighten(shot, to: found!)
    }) else { return check(false, "the photo straightens") }
    let aspect = page.pixelSize.width / page.pixelSize.height
    check(abs(aspect - pageSize.width / pageSize.height) < 0.05, "the page keeps its proportions (\(aspect))")
    let diff = difference(page.image, jpeg(original))
    check(diff < 30, "the straightened page matches the original (mean difference \(diff))")
    let points = page.pixelSize.height * 72 / page.resolution
    check(points > 700 && points < 850, "the page comes out about Letter/A4 height (\(points) pt)")
}

@MainActor
private func scanDeskew() {
    let crooked = CIImage(cgImage: tilted(renderPage(), degrees: 3.5))
    let angle = (try? ScanCleaner.skewAngle(crooked)) ?? 0
    check(abs(angle - 3.5) < 0.6, "the tilt is measured (\(angle)°)")
    check(abs((try? ScanCleaner.skewAngle(CIImage(cgImage: renderPage()))) ?? 9) < 0.3, "a straight page measures straight")
    let cleaned = try! ScanCleaner.clean(page(tilted(renderPage(), degrees: -2.5)), options: only { $0.deskew = true })
    let after = (try? ScanCleaner.skewAngle(try ScanImage.decode(cleaned.image))) ?? 9
    check(abs(after) < 0.4, "after deskew the page measures straight (\(after)°)")
    check(cleaned.pixelSize == pageSize, "deskew keeps the page size")
}

@MainActor
private func scanBorders() {
    let inner = renderPage()
    let size = CGSize(width: 950, height: 1200)
    let context = CGContext(data: nil, width: Int(size.width), height: Int(size.height), bitsPerComponent: 8, bytesPerRow: 0,
                            space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue)!
    context.setFillColor(CGColor(gray: 0.03, alpha: 1))
    context.fill(CGRect(origin: .zero, size: size))
    context.draw(inner, in: CGRect(x: 50, y: 50, width: inner.width, height: inner.height))
    let cleaned = try! ScanCleaner.clean(page(context.makeImage()!), options: only { $0.removeBorders = true })
    check(abs(cleaned.pixelSize.width - pageSize.width) < 12 && abs(cleaned.pixelSize.height - pageSize.height) < 12,
          "the black frame is cut off (\(cleaned.pixelSize))")
    let g = grey(cleaned.image)
    let edges = (0..<g.width).map { Int(g.at($0, 0)) + Int(g.at($0, g.height - 1)) } + (0..<g.height).map { Int(g.at(0, $0)) + Int(g.at(g.width - 1, $0)) }
    check(Double(edges.reduce(0, +)) / Double(edges.count * 2) > 200, "the edges are paper")
    let plain = try! ScanCleaner.clean(page(inner), options: only { $0.removeBorders = true })
    check(plain.pixelSize == pageSize, "a page without borders keeps its size")
}

@MainActor
private func scanWhiten() {
    let dull = page(renderPage(paper: 0.68))
    check(grey(dull.image).percentile(0.6) < 190, "the fixture's paper is grey")
    let cleaned = try! ScanCleaner.clean(dull, options: only { $0.whitenBackground = true })
    let g = grey(cleaned.image)
    check(g.percentile(0.6) > 245, "the paper turns white (\(g.percentile(0.6)))")
    check(g.percentile(0.005) < 60, "the ink stays dark (\(g.percentile(0.005)))")
}

@MainActor
private func scanAutoRotate() {
    let upright = CIImage(cgImage: renderPage())
    check((try? ScanCleaner.uprightQuarterTurns(upright)) == .some(0), "an upright page stays as it is")
    for turns in [1, 2] {
        let turned = ScanCleaner.rotated(upright, quarterTurns: turns)
        guard let fix = (try? ScanCleaner.uprightQuarterTurns(turned)) ?? nil else {
            check(false, "a page turned \(turns) quarter turns is recognised"); continue
        }
        check((turns + fix) % 4 == 0, "a page turned \(turns) quarter turns comes back upright (turns back \(fix))")
        let cleaned = try! ScanCleaner.clean(page(try! ScanImage.render(turned)), options: only { $0.autoRotate = true })
        check(cleaned.pixelSize == pageSize, "after turning, the page is portrait again (\(cleaned.pixelSize))")
    }
}

@MainActor
private func scanIdempotent() {
    let service = ScanService(scanners: FakeScannerBrowser())
    let shot = photo(of: tilted(renderPage(paper: 0.8), degrees: 2), corners: photoCorners)
    guard case .success(let (once, twice))? = (complete { () -> (ScannedPage, ScannedPage) in
        let found = try await service.detectDocument(in: shot)
        let straight = try await service.straighten(shot, to: found!)
        let once = try await service.cleanUp(straight, options: CleanUpOptions())
        return (once, try await service.cleanUp(once, options: CleanUpOptions()))
    }) else { return check(false, "the pipeline runs") }
    check(abs(once.pixelSize.width - twice.pixelSize.width) <= 2 && abs(once.pixelSize.height - twice.pixelSize.height) <= 2,
          "cleaning again keeps the size (\(once.pixelSize) → \(twice.pixelSize))")
    let diff = difference(once.image, twice.image)
    check(diff < 4, "cleaning again changes nothing visible (mean difference \(diff))")
    check(abs((try? ScanCleaner.skewAngle(try ScanImage.decode(once.image))) ?? 9) < 0.5, "the photographed page ends up straight")
}

@MainActor
private func scanDevices() {
    let browser = FakeScannerBrowser()
    let service = makeService(browser)
    var published: [[ScanSource]] = []
    let bag = service.sourceChanges.sink { published.append($0) }
    service.startBrowsing()
    check(browser.started == 1, "browsing starts the device browser")
    browser.set([ScannerInfo(id: "b", name: "Office feeder", state: .busy), ScannerInfo(id: "a", name: "Zeta flatbed", state: .ready),
                 ScannerInfo(id: "c", name: "Alpha", state: .connecting)])
    let rows = service.sources
    check(rows.first == ScanService.continuitySource, "the iPhone row comes first")
    check(rows.dropFirst().map(\.id) == ["a", "c", "b"], "ready scanners first, then by name (\(rows.map(\.id)))")
    check(rows.first { $0.id == "a" }?.status == nil, "a ready scanner has no status line")
    check(rows.first { $0.id == "b" }?.status == ScanStrings.busy, "a busy scanner says so")
    check(rows.first { $0.id == "c" }?.status == ScanStrings.connecting, "a scanner opening its session says so")
    browser.set([])
    check(service.sources == [ScanService.continuitySource], "an unplugged scanner leaves the list")
    check(published.last == service.sources && published.count >= 3, "every change is published")
    bag.cancel()
}

@MainActor
private func scanScannerStream() {
    let browser = FakeScannerBrowser()
    browser.sheets = [renderPage(), renderPage(paper: 0.9)]
    browser.set([ScannerInfo(id: "s", name: "Flatbed", state: .ready)])
    let service = makeService(browser)
    let source = service.sources.first { $0.kind == .scanner }!
    let settings = ScanSettings(resolution: 150, colorMode: .grayscale, duplex: true, paper: .letter)
    guard case .success(let pages)? = collectPages(service.scan(from: source, settings: settings)) else { return check(false, "the scan streams") }
    check(pages.count == 2, "one page per sheet")
    check(pages.allSatisfy { $0.pixelSize == pageSize && $0.resolution == 150 }, "pages keep the sheet's pixels and the dpi")
    let job = browser.jobs.first
    check(job?.resolution == 150 && job?.colorMode == .grayscale && job?.duplex == true && job?.paper == CGSize(width: 612, height: 792),
          "the device is asked for the panel's settings")
    check((try? FileManager.default.contentsOfDirectory(atPath: job!.folder.path))?.isEmpty == true, "sheet files are cleared once read")
    browser.failure = .scannerBusy
    if case .failure(let error)? = collectPages(service.scan(from: source, settings: settings)) {
        check(error as? ScanFailure == .scannerBusy, "a busy scanner fails with its message")
    } else { check(false, "a busy scanner fails") }
}

@MainActor
private func scanContinuity() {
    let camera = ContinuityCamera()
    let service = makeService(FakeScannerBrowser(), camera: camera)
    var deliveries: [NSPasteboard] = []
    // The menu: the system lists a device and the iPhone sends back what is queued.
    camera.present = {
        if let next = deliveries.first { deliveries.removeFirst(); DispatchQueue.main.async { camera.receive(next) } }
        return true
    }
    func pasteboard(_ type: NSPasteboard.PasteboardType, _ data: Data) -> NSPasteboard {
        let board = NSPasteboard(name: NSPasteboard.Name("superpdf-selftest-\(UUID().uuidString)"))
        board.clearContents()
        board.setData(data, forType: type)
        return board
    }
    let iPhoneScan = makePDF(pages: 2)
    deliveries = [pasteboard(.pdf, iPhoneScan)]
    let scanned = collectPages(service.scan(from: ScanService.continuitySource, settings: ScanSettings()))
    if case .success(let pages)? = scanned {
        check(pages.count == 2, "Scan Documents brings each page")
        check(pages.allSatisfy { abs($0.pixelSize.width / $0.pixelSize.height - 612.0 / 792) < 0.01 && $0.resolution == ScanPDF.deviceResolution },
              "pages keep their shape at the device resolution")
    } else { check(false, "the iPhone's PDF arrives") }

    deliveries = [pasteboard(NSPasteboard.PasteboardType("public.jpeg"), photo(of: renderPage(), corners: photoCorners))]
    if case .success(let pages)? = collectPages(service.scan(from: ScanService.continuitySource, settings: ScanSettings())) {
        check(pages.count == 1 && abs(pages[0].pixelSize.width / pages[0].pixelSize.height - pageSize.width / pageSize.height) < 0.05,
              "Take Photo comes back straightened")
    } else { check(false, "the iPhone's photo arrives") }

    camera.present = { false }
    if case .failure(let error)? = collectPages(service.scan(from: ScanService.continuitySource, settings: ScanSettings())) {
        check(error as? ScanFailure == .noIPhone, "no device in the menu: No iPhone or iPad nearby")
        check(error.localizedDescription == Strings.Errors.noIPhone, "with ux §7.4's words")
    } else { check(false, "no device fails") }
    check(!camera.receive(pasteboard(.pdf, iPhoneScan)), "data arriving with nothing waiting is refused")

    let view = ContinuityImportView(camera: camera) {}
    check(view.validRequestor(forSendType: nil, returnType: .pdf) as? NSView === view, "the import view takes PDFs back")
    check(view.validRequestor(forSendType: .string, returnType: .pdf) as? NSView !== view, "it sends nothing")
}

@MainActor
private func scanScannerPanel() {
    let browser = FakeScannerBrowser()
    browser.sheets = [renderPage(), renderPage()]
    let (tools, documents) = installScan(browser)

    // No scanner: the panel says so, with Try again; Next waits.
    let empty = ToolSession(tool: .scanWithScanner, provider: tools, document: nil)
    _ = complete { await empty.updatePreview() }
    check(empty.message?.text == Strings.Errors.noScanner && empty.message?.action?.title == Strings.Errors.tryAgain, "No scanner found · Try again")
    check(!empty.canRun, "Next waits for a scanner")
    browser.set([ScannerInfo(id: "s1", name: "Flatbed", state: .ready)])
    _ = complete { await empty.perform(ScanTools.Action.tryAgain) }
    check(empty.message == nil && empty.panel.controls.contains { if case .radio = $0 { true } else { false } }, "Try again lists the scanner")

    let document = makeDocument(pages: 2)
    let session = ToolSession(tool: .scanWithScanner, provider: tools, document: document)
    check(session.panel.archetype == .flow && session.layout.steps == ScanStrings.deviceSteps, "three steps: device, scan, pages")
    check(session.values.string(ScanTools.Key.device) == "s1", "the ready scanner is chosen")
    _ = complete { await session.primary() }
    check(session.layout.currentStep == 1, "Next goes to Scan")
    check(session.panel.controls.filter(\.isChoice).count <= 3 && session.layout.moreOptions.contains { $0.id == ScanTools.Key.duplex },
          "at most three visible choices; both sides under More options")
    session.set(ScanTools.Key.resolution, .string("150"))
    _ = complete { await session.perform(ScanTools.Action.scan) }
    check(browser.jobs.last?.resolution == 150, "the scan uses the chosen dpi")
    check(session.layout.currentStep == 2 && tools.session(.scanWithScanner, document).pages.count == 2, "the sheets come in and step 3 shows")
    check(session.panel.primary.title == Strings.Panel.done && session.canRun, "Done adds them")
    _ = complete { await session.perform(ScanTools.Action.scanAnother) }
    check(session.layout.currentStep == 1, "Scan another goes back to Scan")
    _ = complete { await session.perform(ScanTools.Action.scan) }
    check(tools.session(.scanWithScanner, document).pages.count == 4, "Scan another adds to the pages")
    session.set(ScanTools.Key.cleanUp, .bool(false))
    guard case .inPlace(let group, let banner)? = run(session) else { return check(false, "Done inserts in place") }
    check(document.pageCount == 6 && banner == nil, "four pages added at the end (\(document.pageCount))")
    check(group.actionName == ScanStrings.undoName, "one undo step")
    check(document.pdf.page(at: 0)?.string?.contains("Page 1") == true, "the original pages stay in front")
    document.undoManager?.undo()
    check(document.pageCount == 2, "Undo removes the scanned pages")
    check(tools.session(.scanWithScanner, document).pages.isEmpty, "the panel starts empty next time")

    // Without a document the pages open as a new PDF.
    let loose = ToolSession(tool: .scanWithScanner, provider: tools, document: nil)
    _ = complete { await loose.primary() }
    _ = complete { await loose.perform(ScanTools.Action.scan) }
    guard case .newDocument(let data, let name, _)? = run(loose) else { return check(false, "a new PDF without a document") }
    check(name == ScanStrings.newDocumentName && PDFDocument(data: data)?.pageCount == 2, "a new two-page PDF")
    check(documents.openDocuments.last?.pageCount == 2, "it opens")
    // The panel's views build headlessly.
    for control in loose.panel.controls { if case .custom(_, let make) = control { _ = make() } }
}

@MainActor
private func scanIPhonePanel() {
    let camera = ContinuityCamera()
    let (tools, _) = installScan(FakeScannerBrowser(), camera: camera)
    let board = NSPasteboard(name: NSPasteboard.Name("superpdf-selftest-\(UUID().uuidString)"))
    board.clearContents()
    board.setData(makePDF(pages: 3), forType: .pdf)
    camera.present = { DispatchQueue.main.async { camera.receive(board) }; return true }
    let document = makeDocument(pages: 1)
    let session = ToolSession(tool: .scanWithIPhone, provider: tools, document: document)
    check(session.panel.controls.contains { if case .note(ScanStrings.iPhoneNeeds) = $0 { true } else { false } }, "step 1 says what the iPhone needs")
    _ = complete { await session.primary() }
    check(session.panel.controls.contains { $0.id == "import" }, "step 2 has the Import from iPhone button")
    // The button starts the import, as clicking it in the panel does.
    let gathered = tools.session(.scanWithIPhone, document)
    gathered.start(Services.scan.scan(from: ScanService.continuitySource, settings: ScanSettings()), working: ScanStrings.waitingForIPhone)
    let deadline = Date().addingTimeInterval(20)
    while (gathered.pages.count < 3 || gathered.isWorking) && Date() < deadline { RunLoop.main.run(until: Date().addingTimeInterval(0.02)) }
    check(gathered.pages.count == 3, "the iPhone's pages come in (\(gathered.pages.count))")
    _ = complete { await session.primary() }
    check(session.layout.currentStep == 2 && session.canRun, "step 3 offers Done")
    session.set(ScanTools.Key.cleanUp, .bool(false))
    guard case .inPlace? = run(session) else { return check(false, "Done inserts") }
    check(document.pageCount == 4, "three pages added after the one there was")

    camera.present = { false }
    gathered.start(Services.scan.scan(from: ScanService.continuitySource, settings: ScanSettings()), working: ScanStrings.waitingForIPhone)
    let until = Date().addingTimeInterval(5)
    while gathered.status != Strings.Errors.noIPhone, Date() < until { RunLoop.main.run(until: Date().addingTimeInterval(0.02)) }
    check(gathered.status == Strings.Errors.noIPhone, "no device nearby shows ux §7.4's line")
}

@MainActor
private func scanPhotoPanel() {
    let (tools, documents) = installScan(FakeScannerBrowser())
    FixKitModule.install()
    let folder = scanFolder("photos")
    let url = folder.appendingPathComponent("Receipt.jpg")
    try! photo(of: renderPage(paper: 0.85), corners: photoCorners).write(to: url)

    let first = ToolSession(tool: .fromPhoto, provider: tools, document: nil)
    check(!first.canRun && first.message?.text == ScanStrings.choosePhotos, "step 1 asks for photos")

    let session = ToolSession(tool: .fromPhoto, provider: tools, document: nil, inputs: [url])
    check(session.layout.steps == ScanStrings.photoSteps && session.canRun, "a dropped photo is ready to go")
    _ = complete { await session.primary() }
    _ = complete { await session.updatePreview() }
    let rows = session.panel.controls.compactMap { control -> [ToolOption]? in if case .list(let rows) = control { rows } else { nil } }.first
    check(rows?.first?.value == ScanStrings.pageFound, "the sheet is found (\(rows?.first?.value ?? "-"))")
    _ = complete { await session.primary() }
    check(session.layout.currentStep == 2 && session.layout.moreOptions.contains { $0.id == ScanTools.Key.recognise }, "Recognise text sits in More options")
    session.set(ScanTools.Key.recognise, .bool(true))
    guard case .newDocument(let data, _, _)? = run(session) else { return check(false, "the photo becomes a PDF") }
    let pdf = PDFDocument(data: data)
    check(pdf?.pageCount == 1, "one page")
    if let box = pdf?.page(at: 0)?.bounds(for: .mediaBox) {
        check(abs(box.width / box.height - pageSize.width / pageSize.height) < 0.05, "the page is the sheet, squared up")
    }
    let text = pdf?.string?.lowercased() ?? ""
    check(text.contains("quick") && text.contains("lazy"), "FixKit's text layer makes it searchable")
    check(documents.openDocuments.count == 1, "the new PDF opens")
}
