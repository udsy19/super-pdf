import AppKit
import CoreText
import DocumentKit
@testable import FixKit
import LayoutKit
import PDFKit
import PDFModelKit
import RenderKit
import SuperPDFCore
@testable import ToolsKit

// FixKit's checks (WP13): Make smaller's sizes, estimate and visual difference on generated picture fixtures; the OCR
// layer recovered from a page that is only a picture of text (straight and skewed, invisible and editable); damaged
// fixtures repaired and re-opened, also through DocumentKit's open flow, and a hopeless one failing with the plain
// message; Fast web view; Compare's text and visual changes and report; the accessibility, printing and PDF/A checks
// and their fixes; fonts; and every Fix & check panel driven through ToolsKit's `ToolSession`.
func registerFixKitTests() {
    SelfTest.cases.append(("FixKit.install", { fixInstall() }))
    SelfTest.cases.append(("FixKit.fontFiles", { fixFontFiles() }))
    SelfTest.cases.append(("FixKit.makeSmaller", { fixMakeSmaller() }))
    SelfTest.cases.append(("FixKit.estimateSample", { fixEstimateSample() }))
    SelfTest.cases.append(("FixKit.ocr", { fixOCR() }))
    SelfTest.cases.append(("FixKit.ocrSkewed", { fixOCRSkewed() }))
    SelfTest.cases.append(("FixKit.ocrEditable", { fixOCREditable() }))
    SelfTest.cases.append(("FixKit.repair", { fixRepair() }))
    SelfTest.cases.append(("FixKit.repairOnOpen", { fixRepairOnOpen() }))
    SelfTest.cases.append(("FixKit.linearize", { fixLinearize() }))
    SelfTest.cases.append(("FixKit.compare", { fixCompare() }))
    SelfTest.cases.append(("FixKit.accessibility", { fixAccessibility() }))
    SelfTest.cases.append(("FixKit.printing", { fixPrinting() }))
    SelfTest.cases.append(("FixKit.pdfA", { fixPDFA() }))
    SelfTest.cases.append(("FixKit.panels", { fixPanels() }))
}

// MARK: - Fixtures

private let letter = CGSize(width: 612, height: 792)

private func fixFolder(_ name: String) -> URL {
    SuperPDFPaths.ensure(scratch.appendingPathComponent("FixKit-\(name)-\(UUID().uuidString)", isDirectory: true))
}

/// A photo-like RGB picture: smooth gradients with grain, so both JPEG and Flate have work to do.
private func photo(width: Int, height: Int, seed: UInt64) -> CGImage {
    var bytes = [UInt8](repeating: 0, count: width * height * 3)
    var state = seed | 1
    bytes.withUnsafeMutableBufferPointer { buffer in
        for y in 0..<height {
            for x in 0..<width {
                state ^= state << 13; state ^= state >> 7; state ^= state << 17
                let grain = Int(state % 25) - 12
                let i = (y * width + x) * 3
                buffer[i] = UInt8(clamping: x * 255 / width + grain)
                buffer[i + 1] = UInt8(clamping: y * 255 / height + grain)
                buffer[i + 2] = UInt8(clamping: (x + y) * 128 / (width + height) + 64 + grain)
            }
        }
    }
    let provider = CGDataProvider(data: Data(bytes) as CFData)!
    return CGImage(width: width, height: height, bitsPerComponent: 8, bitsPerPixel: 24, bytesPerRow: width * 3, space: CGColorSpaceCreateDeviceRGB(),
                   bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.none.rawValue), provider: provider, decode: nil, shouldInterpolate: true,
                   intent: .defaultIntent)!
}

private func jpeg(_ image: CGImage, quality: Double) -> CGImage {
    let data = try! ImageEncoder.encode(image, format: .jpeg, quality: quality)
    return CGImage(jpegDataProviderSource: CGDataProvider(data: data as CFData)!, decode: nil, shouldInterpolate: true, intent: .defaultIntent)!
}

/// One page per entry: a picture drawn in `rect`, text lines at the top, extra drawing.
private struct FixturePage {
    var image: CGImage?
    var rect: CGRect = CGRect(origin: .zero, size: letter)
    var lines: [String] = []
    var fontSize: CGFloat = 14
    var draw: ((CGContext) -> Void)?
}

private func makeFixture(_ pages: [FixturePage], size: CGSize = letter) -> Data {
    let data = NSMutableData()
    var box = CGRect(origin: .zero, size: size)
    let context = CGContext(consumer: CGDataConsumer(data: data as CFMutableData)!, mediaBox: &box, nil)!
    for page in pages {
        context.beginPDFPage(nil)
        if let image = page.image { context.draw(image, in: page.rect) }
        var y = size.height - 90
        for (index, text) in page.lines.enumerated() {
            let font = index == 0 && page.fontSize > 20 ? NSFont.boldSystemFont(ofSize: page.fontSize) : NSFont.systemFont(ofSize: index == 0 ? page.fontSize : 12)
            let line = CTLineCreateWithAttributedString(NSAttributedString(string: text, attributes: [.font: font]))
            context.textPosition = CGPoint(x: 72, y: y)
            CTLineDraw(line, context)
            y -= index == 0 ? page.fontSize * 2 : 20
        }
        page.draw?(context)
        context.endPDFPage()
    }
    context.closePDF()
    return data as Data
}

/// A grey picture of a page of text, as a scanner would make it (`angle` in degrees, counter-clockwise).
private func scanOfText(_ lines: [String], dpi: Double = 200, angle: Double = 0, fontSize: CGFloat = 20) -> CGImage {
    let scale = dpi / 72
    let width = Int(letter.width * scale), height = Int(letter.height * scale)
    let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width, space: CGColorSpaceCreateDeviceGray(),
                            bitmapInfo: CGImageAlphaInfo.none.rawValue)!
    context.setFillColor(gray: 1, alpha: 1)
    context.fill(CGRect(x: 0, y: 0, width: width, height: height))
    context.scaleBy(x: scale, y: scale)
    context.translateBy(x: letter.width / 2, y: letter.height / 2)
    context.rotate(by: angle * .pi / 180)
    context.translateBy(x: -letter.width / 2, y: -letter.height / 2)
    for (index, text) in lines.enumerated() {
        let line = CTLineCreateWithAttributedString(NSAttributedString(string: text, attributes: [.font: NSFont(name: "Helvetica", size: fontSize)!]))
        context.textPosition = CGPoint(x: 60, y: letter.height - 120 - CGFloat(index) * fontSize * 2)
        CTLineDraw(line, context)
    }
    return context.makeImage()!
}

private let scanLines = ["The quick brown fox jumps over the lazy dog", "Invoice number 4521 total due 980 dollars", "Signed in Edinburgh on Monday"]

private func render(_ data: Data, page: Int, dpi: Double) -> CGImage? {
    guard let document = try? PDFPages.open(.data(data)), let page = try? PDFPages.page(document, at: page) else { return nil }
    return try? Rasterizer.render(page, dpi: dpi, colorSpace: .gray)
}

/// Mean absolute grey difference (0…255) of two images of the same size.
private func meanDifference(_ a: CGImage, _ b: CGImage) -> Double {
    guard a.width == b.width, a.height == b.height else { return 255 }
    func pixels(_ image: CGImage) -> [UInt8] {
        var out = [UInt8](repeating: 0, count: image.width * image.height)
        let context = CGContext(data: &out, width: image.width, height: image.height, bitsPerComponent: 8, bytesPerRow: image.width,
                                space: CGColorSpaceCreateDeviceGray(), bitmapInfo: CGImageAlphaInfo.none.rawValue)!
        context.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
        return out
    }
    let pa = pixels(a), pb = pixels(b)
    return Double(zip(pa, pb).reduce(0) { $0 + abs(Int($1.0) - Int($1.1)) }) / Double(max(pa.count, 1))
}

private func pdfKitText(_ data: Data, page: Int) -> String { PDFDocument(data: data)?.page(at: page)?.string ?? "" }

@MainActor
private func await_<T>(_ work: @escaping @MainActor () async throws -> T) -> T? {
    switch complete(300, work) {
    case .success(let value)?: return value
    case .failure(let error)?: check(false, "unexpected error: \(error)"); return nil
    case nil: check(false, "timed out"); return nil
    }
}

@MainActor
private func installForFix() -> FixService {
    installFakes()
    LayoutKitModule.install()
    RenderKitModule.install()
    FixKitModule.install()
    return Services.fix as! FixService
}

// MARK: - Install, fonts

@MainActor
private func fixInstall() {
    installFakes()
    FixKitModule.install()
    check(Services.fix is FixService, "Services.fix is FixKit’s")
    let provided = Services.toolProviders.flatMap(\.tools)
    check(Set(provided) == Set(ToolCatalog.tiles(ownedBy: .fixKit).map(\.id)) && provided.count == 6, "one provider for the six Fix & check tiles")
    check(ToolCoverage.issues(Services.toolProviders, requireAll: false).isEmpty, "coverage")
    installFakes()
}

@MainActor
private func fixFontFiles() {
    // The OCR layer's glyphless font is a TrueType file Quartz reads.
    let font = GlyphlessFont.data
    let cgFont = CGDataProvider(data: font as CFData).flatMap { CGFont($0) }
    check(cgFont != nil && cgFont?.postScriptName as String? == GlyphlessFont.name, "the glyphless font parses (\(font.count) bytes)")
    check(SFNT.tables(of: font)?.count == 10, "ten tables")
    check(SFNT.checksum(font) == 0xB1B0_AFBA, "the whole-font checksum balances")
    // A face of a system collection becomes a standalone font.
    let helvetica = URL(fileURLWithPath: "/System/Library/Fonts/Helvetica.ttc")
    if let data = try? Data(contentsOf: helvetica) {
        let faces = SFNT.faces(ofCollection: data)
        let names = faces.compactMap { CGDataProvider(data: $0 as CFData).flatMap { CGFont($0) }?.postScriptName as String? }
        check(faces.count > 1 && names.count == faces.count && names.contains("Helvetica"), "Helvetica.ttc splits into faces: \(names)")
    }
    // Contrast maths (WCAG): black on white 21:1, mid-grey under 4.5.
    check(abs((Checker.contrastAgainstWhite("#000000") ?? 0) - 21) < 0.01 && (Checker.contrastAgainstWhite("#999999") ?? 9) < 4.5, "contrast")
    check(Optimizer.sample(100, size: 5) == [10, 30, 50, 70, 90] && Optimizer.sample(3, size: 5) == [0, 1, 2], "page samples")
    // Myers.
    let hunks = Comparer.diff(Array("abcxdef"), Array("abydeqf"))
    check(hunks.count >= 2 && hunks.flatMap(\.old).count == 2 && hunks.flatMap(\.new).count == 2, "diff finds the two edits: \(hunks)")
}

// MARK: - Make smaller

@MainActor
private func fixMakeSmaller() {
    let service = installForFix()
    let folder = fixFolder("smaller")
    let original = makeFixture([
        FixturePage(image: photo(width: 1000, height: 1200, seed: 7), rect: CGRect(x: 72, y: 400, width: 216, height: 259), lines: ["Page 1"]),
        FixturePage(image: jpeg(photo(width: 1200, height: 1500, seed: 9), quality: 0.95), rect: CGRect(x: 72, y: 300, width: 288, height: 360),
                    lines: ["Page 2"]),
        FixturePage(lines: ["Page 3", "Only words on this page."]),
    ])
    let url = folder.appendingPathComponent("Photos.pdf")
    try? original.write(to: url)
    let source = PDFSource.file(url)

    var sizes: [SizePreset: Int] = [:]
    for preset in [SizePreset.email, .good, .best] {
        let out = folder.appendingPathComponent("\(preset.rawValue).pdf")
        _ = await_ { try await service.optimize(source, options: .defaults(for: preset), to: out, progress: .ignored) }
        let data = (try? Data(contentsOf: out)) ?? Data()
        sizes[preset] = data.count
        check(PDFDocument(data: data)?.pageCount == 3, "\(preset) output opens with its 3 pages")
        check(pdfKitText(data, page: 2).contains("Only words"), "\(preset) keeps the text")
    }
    let email = sizes[.email] ?? 0, good = sizes[.good] ?? 0, best = sizes[.best] ?? 0
    print("  Make smaller: original \(original.count) → best \(best), good \(good), email \(email)")
    check(email < good && good < best && best < original.count, "Email < Good < Best < original")
    check(Double(good) < Double(original.count) * 0.5, "Good at least halves this file (\(good) of \(original.count))")

    // Pictures look the same on the page.
    if let goodData = try? Data(contentsOf: folder.appendingPathComponent("good.pdf")) {
        for page in 0..<2 {
            if let a = render(original, page: page, dpi: 36), let b = render(goodData, page: page, dpi: 36) {
                let difference = meanDifference(a, b)
                check(difference < 4, "page \(page + 1) looks the same after Good (mean difference \(difference))")
            }
        }
        // Each picture now sits near the preset's resolution.
        if let model = try? PDFModel(data: goodData) {
            let resolutions = model.pages.flatMap { ImageUses.on($0) }.map(\.resolution)
            check(!resolutions.isEmpty && resolutions.allSatisfy { $0 < 160 }, "pictures downsampled to about 150 dpi: \(resolutions.map { Int($0) })")
        }
    }

    // The estimate (a whole short file) lands near the real sizes, fast.
    let start = Date()
    let estimates = await_ { try await service.estimates(source, options: [.defaults(for: .email), .defaults(for: .good), .defaults(for: .best)]) } ?? []
    let elapsed = Date().timeIntervalSince(start)
    print("  Estimates \(estimates) in \(String(format: "%.2f", elapsed)) s")
    check(estimates.count == 3, "three estimates")
    for (estimate, actual) in zip(estimates, [email, good, best]) {
        check(abs(Double(estimate) - Double(actual)) < Double(actual) * 0.1 + 4096, "estimate \(estimate) near actual \(actual)")
    }
    check(elapsed < 1.5, "estimates in about a second (\(elapsed) s)")

    // Space audit: the pictures are most of the file.
    if let audit = await_({ try await service.audit(source) }) {
        check(audit.images > Int64(original.count) * 8 / 10 && audit.fonts > 0 && audit.content > 0, "audit: \(audit)")
    }

    // Removing extra fonts unembeds the standard 14 only; options discard what they name.
    let model = PDFModel()
    if let page = try? model.addBlankPage(size: letter) {
        page.setContentData(Data("BT /F1 12 Tf 72 700 Td (Hello) Tj ET".utf8))
        page.ownResources().dictionary("Font").set("F1", model.makeIndirect(.dictionary([
            "Type": .name("Font"), "Subtype": .name("Type1"), "BaseFont": .name("Helvetica"), "Encoding": .name("WinAnsiEncoding")])))
        model.root.set("Outlines", model.makeIndirect(.dictionary(["Type": .name("Outlines")])))
        let (embedded, _) = Fonts.embedMissing(in: model)
        if embedded == ["Helvetica"] {
            check(Fonts.notEmbedded(in: model).isEmpty, "Helvetica embedded from this Mac")
            check(Fonts.unembedStandardFonts(in: model) == 1 && Fonts.notEmbedded(in: model).map(\.name) == ["Helvetica"], "and unembedded again")
        }
        var options = OptimizeOptions.defaults(for: .good)
        options.removeBookmarksAndAttachments = true
        try? Optimizer.apply(options, to: model)
        check(model.root["Outlines"] == nil, "bookmarks removed on request")
    }
    installFakes()
}

@MainActor
private func fixEstimateSample() {
    let service = installForFix()
    // Twelve pages, a different picture on each: the estimate reads five of them.
    let pages = (0..<12).map { FixturePage(image: photo(width: 500, height: 600, seed: UInt64($0 + 3)), rect: CGRect(x: 72, y: 300, width: 120, height: 144),
                                           lines: ["Page \($0 + 1)"]) }
    let data = makeFixture(pages)
    let folder = fixFolder("sample")
    let url = folder.appendingPathComponent("Long.pdf")
    try? data.write(to: url)
    let start = Date()
    let estimate = await_ { try await service.estimate(.file(url), options: .defaults(for: .good)) } ?? 0
    let elapsed = Date().timeIntervalSince(start)
    let out = folder.appendingPathComponent("out.pdf")
    _ = await_ { try await service.optimize(.file(url), options: .defaults(for: .good), to: out, progress: .ignored) }
    let actual = (try? Data(contentsOf: out))?.count ?? 0
    print("  Sampled estimate \(estimate) vs actual \(actual) (original \(data.count)) in \(String(format: "%.2f", elapsed)) s")
    check(abs(Double(estimate) - Double(actual)) < Double(actual) * 0.25, "a five-page sample estimates within 25%")
    check(elapsed < 1, "within a second")
    installFakes()
}

// MARK: - Recognise text

@MainActor
private func fixOCR() {
    let service = installForFix()
    let data = makeFixture([FixturePage(image: scanOfText(scanLines)), FixturePage(lines: ["Typed page"])])
    let document = DocumentHandle(url: nil, displayName: "Scan", pdf: PDFDocument(data: data)!, undoManager: makeUndoManager())
    check(service.pagesWithoutText(in: document) == [0], "the scanned page has no text yet")

    guard let report = await_({ try await service.recognize(.data(data), pages: [0], options: OCROptions(cleanUp: false), progress: .ignored) }) else { return }
    check(report.recognizedPages == 1 && report.emptyPages == 0, "one page recognised")
    guard let result = PDFDocument(data: report.data), let page = result.page(at: 0) else { check(false, "the result opens"); return }
    let text = (page.string ?? "").lowercased()
    print("  OCR text: \(text.replacingOccurrences(of: "\n", with: " / "))")
    for word in ["quick", "brown", "fox", "lazy", "invoice", "4521", "edinburgh"] { check(text.contains(word), "recovered “\(word)”") }
    check(text.contains("quick brown fox"), "words keep their spaces")
    check(result.page(at: 1)?.string?.contains("Typed page") == true, "the other page is untouched")
    // Search lands on the word, where the scan shows it.
    let found = result.findString("lazy", withOptions: .caseInsensitive)
    if let selection = found.first, let bounds = Optional(selection.bounds(for: page)) {
        check(selection.pages.first == page, "found on the scanned page")
        check(abs(bounds.midY - (letter.height - 120 + 6)) < 14 && bounds.minX > 300 && bounds.maxX < 560, "at the word’s place: \(bounds)")
    } else {
        check(false, "“lazy” is searchable")
    }
    // Still a picture: the layer is invisible (render mode 3) and the page looks the same.
    if let a = render(data, page: 0, dpi: 36), let b = render(report.data, page: 0, dpi: 36) { check(meanDifference(a, b) < 0.5, "the layer is invisible") }
    check(String(data: (try? PDFModel(data: report.data).page(at: 0)?.contentData()) ?? Data(), encoding: .isoLatin1)?.contains("3 Tr") == true, "render mode 3")
    installFakes()
}

@MainActor
private func fixOCRSkewed() {
    let service = installForFix()
    let image = scanOfText(scanLines, angle: 3)
    let angle = Deskew.angle(of: image) * 180 / .pi
    check(abs(angle - 3) < 0.5, "skew measured as 3° (got \(angle))")
    check(abs(Deskew.angle(of: scanOfText(scanLines)) * 180 / .pi) < 0.2, "a straight page measures straight")
    let data = makeFixture([FixturePage(image: image)])
    guard let report = await_({ try await service.recognize(.data(data), pages: [0], options: OCROptions(cleanUp: true), progress: .ignored) }),
          let page = PDFDocument(data: report.data)?.page(at: 0) else { return }
    let text = (page.string ?? "").lowercased()
    for word in ["quick", "lazy", "invoice", "edinburgh"] { check(text.contains(word), "skewed scan: recovered “\(word)”") }
    installFakes()
}

@MainActor
private func fixOCREditable() {
    let service = installForFix()
    let data = makeFixture([FixturePage(image: scanOfText(scanLines))])
    guard let report = await_({ try await service.recognize(.data(data), pages: [0], options: OCROptions(cleanUp: true, editableText: true), progress: .ignored) }),
          let model = try? PDFModel(data: report.data), let page = model.page(at: 0) else { return }
    check(ImageUses.on(page).isEmpty, "the scan’s picture is gone")
    let content = String(data: (try? page.contentData()) ?? Data(), encoding: .isoLatin1) ?? ""
    check(content.contains("0 Tr"), "the words are real, visible text")
    check((PDFDocument(data: report.data)?.page(at: 0)?.string ?? "").lowercased().contains("lazy dog"), "and extract as text")
    // Visible: the page is no longer blank where the text was.
    if let rendered = render(report.data, page: 0, dpi: 36), let blank = render(makeFixture([FixturePage()]), page: 0, dpi: 36) {
        check(meanDifference(rendered, blank) > 0.3, "the new text shows")
    }
    installFakes()
}

// MARK: - Repair

/// Damage of several kinds, each on a three-page file.
private func damagedFixtures() -> [(String, Data)] {
    let clean = makePDF(pages: 3)
    var xref = [UInt8](clean)
    if let range = clean.range(of: Data("\nxref\n".utf8), options: .backwards) {
        for i in range.upperBound..<min(range.upperBound + 200, xref.count) where xref[i] >= 49 && xref[i] <= 57 { xref[i] = 57 }
    }
    var shifted = clean
    shifted.insert(contentsOf: Data(repeating: 0x20, count: 517), at: clean.count / 3)
    return [("truncated", clean.prefix(clean.count - 400)), ("broken index", Data(xref)), ("shifted offsets", shifted)]
}

@MainActor
private func fixRepair() {
    let service = installForFix()
    let folder = fixFolder("repair")
    for (name, damaged) in damagedFixtures() {
        let url = folder.appendingPathComponent("\(name).pdf")
        try? damaged.write(to: url)
        let diagnosis = await_ { await service.diagnose(url) }
        check(diagnosis??.problems.isEmpty == false, "\(name): diagnosed (\(diagnosis??.problems ?? []))")
        let out = folder.appendingPathComponent("\(name) (repaired).pdf")
        guard let fixed = await_({ try await service.repair(.file(url), embedFonts: false, to: out) }) else { continue }
        let data = (try? Data(contentsOf: out)) ?? Data()
        check(PDFDocument(data: data)?.pageCount == 3, "\(name): the repaired file opens in PDFKit with its pages")
        check(pdfKitText(data, page: 2).contains("Page 3"), "\(name): and its text")
        check((try? PDFModel(data: data, attemptRecovery: false))?.wasRepaired == false, "\(name): and is sound")
        check(!fixed.problems.isEmpty, "\(name): says what it fixed")
    }
    // A sound file has nothing to report.
    let clean = folder.appendingPathComponent("clean.pdf")
    try? makePDF(pages: 2).write(to: clean)
    check(await_({ await service.diagnose(clean) })??.problems == [], "a sound file is healthy")
    // Past saving: the plain message.
    let hopeless = folder.appendingPathComponent("Hopeless.pdf")
    var noise = Data("%PDF-1.7\n".utf8)
    noise.append(Data((0..<4000).map { UInt8(truncatingIfNeeded: $0 &* 2_654_435_761 >> 13) }))
    try? noise.write(to: hopeless)
    switch complete(60, { try await service.repair(.file(hopeless), embedFonts: false, to: folder.appendingPathComponent("x.pdf")) }) {
    case .failure(let error)?:
        check((error as? ToolError)?.message.text == FixStrings.Repair.failed("Hopeless.pdf"), "a hopeless file fails plainly: \(error.localizedDescription)")
    default: check(false, "a hopeless file can’t be repaired")
    }
    check(await_({ await service.diagnose(folder.appendingPathComponent("missing.pdf")) }) == .some(nil), "no file: no diagnosis")
    installFakes()
}

/// DocumentKit's open flow with FixKit as the repairer.
@MainActor
private final class RepairPrompter: DocumentPrompting {
    var asked = 0
    func password(for fileName: String, retry: Bool) async -> String? { nil }
    func confirmRepair(of fileName: String, canRepair: Bool) async -> Bool { asked += 1; return canRepair }
    func firstSave(of fileName: String, window: NSWindow?) async -> (answer: FirstSaveAnswer, always: Bool)? { nil }
    func closeWithUnsavedChanges(window: NSWindow?) async -> CloseAnswer { .discard }
    func saveLocation(proposing proposal: URL, window: NSWindow?) async -> URL? { nil }
    func ownerPassword(for fileName: String, retry: Bool, window: NSWindow?) async -> String? { nil }
}

@MainActor
private func fixRepairOnOpen() {
    _ = installForFix()
    let folder = fixFolder("open")
    let prompter = RepairPrompter()
    let manager = DocumentManager(controller: NSDocumentController(), prompter: prompter,
                                  autosaveFolder: folder.appendingPathComponent("Autosave", isDirectory: true),
                                  fallbackFolder: SuperPDFPaths.ensure(folder.appendingPathComponent("Desktop", isDirectory: true)),
                                  displaysWindows: false, notesSystemRecents: false)
    Services.documents = manager
    let damaged = folder.appendingPathComponent("Report.pdf")
    let bytes = damagedFixtures()[0].1
    try? bytes.write(to: damaged)
    check(PDFDocument(url: damaged) == nil, "PDFKit can’t open the fixture")
    if let handle = await_({ try await manager.open(damaged) }) {
        check(handle.state.wasRepaired && handle.pageCount == 3 && prompter.asked == 1, "opened through FixKit’s repair")
        check((try? Data(contentsOf: damaged)) == bytes, "the original is untouched")
    }
    let hopeless = folder.appendingPathComponent("Ruined.pdf")
    try? Data("%PDF-1.4\n%%garbage only".utf8).write(to: hopeless)
    switch complete(60, { try await manager.open(hopeless) }) {
    case .failure(let error)?: check(error.localizedDescription == FixStrings.Repair.failed("Ruined.pdf"), "the plain message: \(error.localizedDescription)")
    default: check(false, "a ruined file doesn’t open")
    }
    for handle in manager.openDocuments {
        manager.document(for: handle)?.updateChangeCount(.changeCleared)
        manager.document(for: handle)?.close()
    }
    installFakes()
}

@MainActor
private func fixLinearize() {
    let service = installForFix()
    let folder = fixFolder("linear")
    let out = folder.appendingPathComponent("web.pdf")
    _ = await_ { try await service.linearize(.data(makePDF(pages: 4)), to: out) }
    let data = (try? Data(contentsOf: out)) ?? Data()
    check((try? PDFModel(data: data))?.isLinearized == true && PDFDocument(data: data)?.pageCount == 4, "Fast web view writes a linearized file")
    installFakes()
}

// MARK: - Compare

@MainActor
private func fixCompare() {
    let service = installForFix()
    let old = makeFixture([
        FixturePage(lines: ["Rental agreement", "The tenant pays rent on the first day of each month.", "The deposit is two months of rent.",
                            "Pets are not allowed in the flat."]),
        FixturePage(lines: ["Signatures", "Signed by both parties."]),
    ])
    let new = makeFixture([
        FixturePage(lines: ["Rental agreement", "The tenant pays rent on the fifth day of each month.", "The deposit is two months of rent.",
                            "Smoking is not allowed anywhere.", "Pets are not allowed in the flat."]),
        FixturePage(lines: ["Signatures", "Signed by both parties."], draw: { context in
            context.setFillColor(CGColor(red: 0.1, green: 0.3, blue: 0.9, alpha: 1)); context.fill(CGRect(x: 300, y: 200, width: 160, height: 120))
        }),
    ])
    guard let changes = await_({ try await service.locatedChanges(.data(old), .data(new), textOnly: false) }) else { return }
    for change in changes { print("  change: \(change.change.kind) p\((change.change.newPage ?? -1) + 1) \(change.change.oldText ?? "-") → \(change.change.newText ?? "-")") }
    check(changes.contains { $0.change.kind == .changed && $0.change.oldText == "first" && $0.change.newText == "fifth" && $0.change.newPage == 0 },
          "a changed word")
    check(changes.contains { $0.change.kind == .inserted && ($0.change.newText ?? "").contains("Smoking") && $0.change.newPage == 0 }, "an added line")
    check(changes.contains { $0.change.kind == .visual && $0.change.newPage == 1 }, "a picture added on page 2")
    check(changes.filter { $0.change.kind != .visual }.count == 2, "nothing else changed in the text")
    check(changes.first { $0.change.kind == .changed }.map { !$0.newBoxes.isEmpty && !$0.oldBoxes.isEmpty } == true, "changes know where they are")
    let textOnly = await_({ try await service.compare(.data(old), with: .data(new), textOnly: true, progress: .ignored) }) ?? []
    check(!textOnly.contains { $0.kind == .visual } && textOnly.count == 2, "Text only skips pictures")
    check(await_({ try await service.compare(.data(old), with: .data(old), textOnly: false, progress: .ignored) })?.isEmpty == true, "a file equals itself")
    // Removed words.
    let removed = await_({ try await service.compare(.data(new), with: .data(old), textOnly: true, progress: .ignored) }) ?? []
    check(removed.contains { $0.kind == .deleted && ($0.oldText ?? "").contains("Smoking") && $0.oldPage == 0 }, "a removed line")

    // The report: the list, then the changed pages.
    if let report = try? Comparer.report(changes, new: .data(new), oldName: "Lease v1.pdf", newName: "Lease v2.pdf"),
       let document = PDFDocument(data: report) {
        let first = document.page(at: 0)?.string ?? ""
        check(first.contains("Lease v1.pdf") && first.contains("3 changes on 2 pages") && first.contains("fifth"), "report summary: \(first.prefix(160))")
        check(document.pageCount == 3, "the report shows both changed pages")
    } else {
        check(false, "the report opens")
    }
    installFakes()
}

// MARK: - Checks

@MainActor
private func fixAccessibility() {
    let service = installForFix()
    let red = CGContext(data: nil, width: 64, height: 64, bitsPerComponent: 8, bytesPerRow: 0, space: CGColorSpaceCreateDeviceRGB(),
                        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
    red.setFillColor(CGColor(red: 0.9, green: 0.1, blue: 0.1, alpha: 1)); red.fill(CGRect(x: 0, y: 0, width: 64, height: 64))
    let data = makeFixture([
        FixturePage(image: red.makeImage(), rect: CGRect(x: 72, y: 250, width: 200, height: 200),
                    lines: ["Annual report", "Our year in numbers and words.", "Sales grew in every region this year.",
                            "The board thanks everyone who helped."], fontSize: 28),
    ])
    guard let report = await_({ try await service.accessibilityReport(.data(data)) }) else { return }
    func severity(_ id: String, in issues: [CheckIssue]) -> CheckIssue.Severity? { issues.first { $0.id == id }?.severity }
    for issue in report.issues { print("  a11y: \(issue.severity) \(issue.id) — \(issue.title) \(issue.fixTitle ?? "")") }
    check(severity("title", in: report.issues) == .failed && severity("language", in: report.issues) == .failed
          && severity("tags", in: report.issues) == .failed, "untitled, no language, untagged")
    check(report.language.code == "en" && report.issues.first { $0.id == "language" }?.fixTitle == "Set the language to English", "English found")
    check(report.figures.count == 1 && severity("alt-text", in: report.issues) == .failed, "one picture without a description")

    let folder = fixFolder("a11y")
    let out = folder.appendingPathComponent("fixed.pdf")
    let descriptions = Dictionary(uniqueKeysWithValues: report.figures.map { ($0.key, "A red square") })
    _ = await_ { try await service.fixAccessibility(["title", "language", "tags"], in: .data(data), descriptions: descriptions, to: out) }
    guard let fixed = try? Data(contentsOf: out), let model = try? PDFModel(data: fixed) else { check(false, "fixed copy written"); return }
    check(model.info("Title") == "Annual report" && model.root["Lang"]?.text == "en", "title and language set")
    let tree = model.structureTree()
    let types = tree.map { flattenTypes($0.elements) } ?? []
    check(types.contains("Document") && types.contains("H1") && types.contains("P") && types.contains("Figure"), "tagged: \(types)")
    check(AutoTagger.figures(in: model).first?.ref.hasDescription == true, "the picture has its description")
    check(model.root["StructTreeRoot"]?["ParentTree"] != nil && Checker.isTagged(model), "parent tree and MarkInfo")
    let content = String(data: (try? model.page(at: 0)?.contentData()) ?? Data(), encoding: .isoLatin1) ?? ""
    check(content.contains("/MCID 0") && content.contains("BDC") && content.contains("EMC"), "content is marked")
    check(PDFDocument(data: fixed)?.page(at: 0)?.string?.contains("Sales grew") == true, "the text still reads")
    if let a = render(data, page: 0, dpi: 36), let b = render(fixed, page: 0, dpi: 36) { check(meanDifference(a, b) < 0.5, "and looks the same") }
    if let again = await_({ try await service.check(.data(fixed), profile: .accessibility, progress: .ignored) }) {
        for id in ["title", "language", "tags", "reading-order", "alt-text"] { check(severity(id, in: again) == .passed, "after fixing: \(id) passes") }
    }
    installFakes()
}

private func flattenTypes(_ elements: [PDFStructureElement]) -> [String] {
    elements.flatMap { [$0.type] + flattenTypes($0.kids.compactMap { if case .element(let e) = $0 { e } else { nil } }) }
}

/// A page with an unembedded Helvetica, a hairline and RGB colour, built with QPDF.
private func printFixture() -> Data {
    let model = PDFModel()
    guard let page = try? model.addBlankPage(size: letter) else { return Data() }
    page.setContentData(Data("BT /F1 12 Tf 72 700 Td (Ready for print) Tj ET\n0 w 72 600 m 300 600 l S\n1 0 0 rg 72 500 100 50 re f\n".utf8))
    page.ownResources().dictionary("Font").set("F1", model.makeIndirect(.dictionary([
        "Type": .name("Font"), "Subtype": .name("Type1"), "BaseFont": .name("Helvetica"), "Encoding": .name("WinAnsiEncoding")])))
    return (try? model.data()) ?? Data()
}

@MainActor
private func fixPrinting() {
    let service = installForFix()
    let data = printFixture()
    guard let issues = await_({ try await service.check(.data(data), profile: .printing, progress: .ignored) }) else { return }
    for issue in issues { print("  print: \(issue.severity) \(issue.id) — \(issue.title) \(issue.fixTitle ?? "")") }
    func issue(_ id: String, _ list: [CheckIssue]) -> CheckIssue? { list.first { $0.id == id } }
    check(issue("fonts", issues)?.severity == .failed && issue("fonts", issues)?.title.contains("Helvetica") == true, "the unembedded font")
    check(issue("hairlines", issues)?.severity == .needsAttention && issue("hairlines", issues)?.pages == [0], "the hairline")
    check(issue("rgb", issues)?.severity == .needsAttention && issue("page-boxes", issues)?.severity == .needsAttention, "RGB, no trim box")
    check(issue("transparency", issues)?.severity == .passed && issue("image-resolution", issues)?.severity == .passed, "no transparency, no pictures")

    let folder = fixFolder("print")
    let out = folder.appendingPathComponent("print.pdf")
    _ = await_ { try await service.fixPrinting(["fonts", "hairlines"], in: .data(data), printerMarks: true, title: "Flyer.pdf", to: out) }
    guard let fixed = try? Data(contentsOf: out), let model = try? PDFModel(data: fixed), let page = model.page(at: 0) else { check(false, "fixed copy"); return }
    check(PrintProduction.pagesWithHairlines(in: model).isEmpty, "hairlines thickened")
    if issue("fonts", issues)?.fixTitle != nil { check(Fonts.notEmbedded(in: model).isEmpty, "Helvetica embedded") }
    check(page.object["TrimBox"]?.rect == CGRect(origin: .zero, size: letter) && page.box(.media).width > letter.width + 60, "printer marks: trim box kept, media grown")
    check(PDFDocument(data: fixed)?.page(at: 0)?.string?.contains("Ready for print") == true, "the text survives")
    check(PDFDocument(data: fixed)?.page(at: 0)?.string?.contains("Flyer.pdf") == true, "the slug names the file")
    installFakes()
}

@MainActor
private func fixPDFA() {
    let service = installForFix()
    let plain = makePDF(pages: 2)
    guard let issues = await_({ try await service.check(.data(plain), profile: .pdfA(.a2b), progress: .ignored) }) else { return }
    let ids = Set(issues.map(\.id))
    check(ids.contains("pdfa-metadata") && ids.contains("output-intent") && issues.allSatisfy { $0.severity == .failed }, "a plain file isn’t PDF/A: \(ids)")
    // Quartz's PDF/A-2b output (RenderKit) is the known-good file.
    let folder = fixFolder("pdfa")
    let archive = folder.appendingPathComponent("archive.pdf")
    _ = await_ { try await service.fix(issues.map(\.id), in: .data(plain), profile: .pdfA(.a2b), to: archive) }
    if let checked = await_({ try await service.check(.file(archive), profile: .pdfA(.a2b), progress: .ignored) }) {
        check(checked.map(\.id) == ["pdfa"] && checked.first?.severity == .passed, "the converted file passes PDF/A-2b: \(checked.map(\.title))")
        let strict = await_({ try await service.check(.file(archive), profile: .pdfA(.a1b), progress: .ignored) }) ?? []
        check(strict.contains { $0.id == "pdfa-metadata" }, "but isn’t marked PDF/A-1b")
    }
    let encrypted = folder.appendingPathComponent("locked.pdf")
    if let model = try? PDFModel(data: plain) {
        try? model.write(to: encrypted, options: PDFWriteOptions(encryption: .encrypt(PDFEncryption(userPassword: "", ownerPassword: "owner"))))
        let found = await_({ try await service.check(.file(encrypted), profile: .pdfA(.a2b), progress: .ignored) }) ?? []
        check(found.contains { $0.id == "encryption" }, "encryption isn’t allowed")
    }
    installFakes()
}

// MARK: - Panels through ToolsKit

@MainActor
private func fixPanels() {
    _ = installForFix()
    let provider = Services.toolProviders.first { $0.tools.contains(.makeSmaller) }!
    let folder = fixFolder("panels")
    let url = folder.appendingPathComponent("Report.pdf")
    try? makeFixture([FixturePage(image: photo(width: 900, height: 1100, seed: 5), rect: CGRect(x: 72, y: 300, width: 216, height: 264), lines: ["Report"]),
                      FixturePage(image: scanOfText(scanLines))]).write(to: url)
    let document = DocumentHandle(url: url, pdf: PDFDocument(url: url)!, undoManager: makeUndoManager())
    let documents = Services.documents as! FakeDocuments

    // Make smaller: estimates on the presets, "Now", the button and the banner.
    let smaller = ToolSession(tool: .makeSmaller, provider: provider, document: document)
    check(smaller.panel.archetype == .presetAndMore && smaller.panel.primary.title == "Make smaller", "Make smaller panel")
    _ = await_ { await smaller.updatePreview() }
    check(smaller.summary.first?.hasPrefix("Now: ") == true, "Now: \(smaller.summary)")
    if case .radio(_, let options, _)? = smaller.panel.controls.first {
        check(options.map(\.title) == ["Good (recommended)", "Email (smallest)", "Best quality"] && options.allSatisfy { $0.value?.hasPrefix("≈ ") == true },
              "three presets with estimates: \(options.map { $0.value ?? "-" })")
    } else { check(false, "presets first") }
    check(smaller.outputLine?.fileName == "Report (smaller).pdf", "saves Report (smaller).pdf")
    smaller.set("preset", .string("email"))
    var written: Data?
    let keep: @MainActor (ToolResult) -> Void = { result in if case .newFile(let url, _) = result { written = try? Data(contentsOf: url) } }
    smaller.onFinish = keep
    if case .newFile(let file, let banner)? = await_({ await smaller.run() }) ?? nil {
        check(banner.text.hasPrefix("Done. The file is ") && banner.text.contains("% smaller"), banner.text)
        check(file.lastPathComponent == "Report (smaller).pdf" && PDFDocument(data: written ?? Data())?.pageCount == 2, "written under its name")
    } else { check(false, "Make smaller runs: \(smaller.message?.text ?? "")") }

    // Already small: the message and a disabled button.
    let small = folder.appendingPathComponent("Small.pdf")
    if let model = try? PDFModel(data: makePDF(pages: 1)), let tight = try? model.data(options: PDFWriteOptions(objectStreams: .generate, decodeLevel: .generalized)) {
        try? tight.write(to: small)
        let smallDocument = DocumentHandle(url: small, pdf: PDFDocument(url: small)!, undoManager: makeUndoManager())
        let session = ToolSession(tool: .makeSmaller, provider: provider, document: smallDocument)
        _ = await_ { await session.updatePreview() }
        check(session.message?.text == "This file is already as small as it gets." && !session.canRun, "nothing to gain: \(session.message?.text ?? "no message")")
    }

    // Recognise text: the count line, scope, in-place result with undo.
    let recognise = ToolSession(tool: .recogniseText, provider: provider, document: document)
    check(recognise.panel.controls.contains { if case .note("1 of 2 pages has no text yet") = $0 { true } else { false } }, "1 of 2 pages has no text yet")
    check(recognise.panel.showsScope && recognise.canRun, "scope and an enabled button")
    if case .inPlace(let group, let banner)? = await_({ await recognise.run() }) ?? nil {
        check(banner?.text == "Recognised 1 page. You can now search and copy the text.", banner?.text ?? "no banner")
        if case .contents(let before, let after) = group.change {
            check(before.count > 0 && (PDFDocument(data: after)?.page(at: 1)?.string ?? "").lowercased().contains("lazy"), "undoable contents swap")
        } else { check(false, "a contents undo") }
    } else { check(false, "Recognise text runs: \(recognise.message?.text ?? "")") }
    recognise.setScope(.ranges(PageRanges([0...0])))
    check(!recognise.canRun, "nothing to recognise on a page with text")

    // Compare: empty state, then the other version.
    let compare = ToolSession(tool: .compareFiles, provider: provider, document: document)
    check(compare.panel.controls.contains { if case .note(Strings.Empty.compare) = $0 { true } else { false } } && !compare.canRun, "compare empty state")
    let other = folder.appendingPathComponent("Report v1.pdf")
    try? makeFixture([FixturePage(lines: ["Report draft"]), FixturePage(image: scanOfText(scanLines))]).write(to: other)
    compare.set("other", .files([other]))
    _ = await_ { await compare.updatePreview() }
    check(compare.canRun && compare.panel.primary.title == "Save comparison report…", "compare ready")
    if case .overlay = compare.preview {} else { check(false, "changes drawn on the page") }
    _ = await_ { await compare.perform("next") }
    check(compare.values.int("cursor", default: -1) == 0, "› moves to the first change")
    if case .newDocument(let data, let name, _)? = await_({ await compare.run() }) ?? nil {
        check(name == "Comparison" && PDFDocument(data: data) != nil, "the report opens as a new document")
    } else { check(false, "the report is made") }

    // Check accessibility: results, fixes, descriptions, a fixed copy.
    let a11y = ToolSession(tool: .checkAccessibility, provider: provider, document: document)
    check(!a11y.canRun, "nothing to fix before the check")
    _ = await_ { await a11y.updatePreview() }
    check(a11y.summary.contains { $0.hasPrefix("Failed: ") }, "grouped results: \(a11y.summary)")
    if case .checklist(_, let items, let selected)? = a11y.panel.controls.first {
        check(items.map(\.title).contains("Tag the document") && Set(selected) == Set(items.map(\.id)), "the fixes, all ticked: \(items.map(\.title))")
    } else { check(false, "the fixes first") }
    check(a11y.canRun && a11y.outputLine?.fileName == "Report (edited).pdf", "Save fixed copy → Report (edited).pdf")
    a11y.onFinish = keep
    if case .newFile(_, let banner)? = await_({ await a11y.run() }) ?? nil {
        check(banner.text == "Saved “Report (edited).pdf”." && (try? PDFModel(data: written ?? Data())).map(Checker.isTagged) == true, banner.text)
    } else { check(false, "accessibility fixes run: \(a11y.message?.text ?? "")") }

    // Check for printing: results, separations overlay.
    let printing = ToolSession(tool: .checkForPrinting, provider: provider, document: document)
    _ = await_ { await printing.updatePreview() }
    check(!printing.summary.isEmpty && printing.panel.moreOptions.count == 2, "printing results and More options")
    printing.set("plate", .string("c"))
    _ = await_ { await printing.updatePreview() }
    if case .overlay = printing.preview {} else { check(false, "the cyan plate is drawn over the page") }
    check(printing.panel.controls.contains { if case .note(let text) = $0 { text.hasPrefix("Ink coverage reaches") } else { false } }, "ink coverage")

    // Repair: the diagnosis line, the button, the output.
    let repair = ToolSession(tool: .repair, provider: provider, document: document)
    _ = await_ { await repair.updatePreview() }
    check(repair.panel.primary.title == "Repair and save copy" && repair.outputLine?.fileName == "Report (repaired).pdf", "Repair panel")
    repair.set("fastWebView", .bool(true))
    repair.onFinish = keep
    if case .newFile? = await_({ await repair.run() }) ?? nil {
        check((try? PDFModel(data: written ?? Data()))?.isLinearized == true, "repaired with fast web view")
    } else { check(false, "Repair runs: \(repair.message?.text ?? "")") }
    check(documents.applied.count >= 5, "results go through DocumentKit")
    // The choices ToolsKit remembered for these tiles don't leak into later cases.
    for tile in ToolCatalog.tiles(ownedBy: .fixKit) {
        Defaults.reset(ToolSession.valuesKey(tile.id))
        Defaults.reset(ToolSession.moreOptionsKey(tile.id))
    }
    installFakes()
}
