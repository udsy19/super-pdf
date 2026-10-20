import AppKit
import ImageIO
import LayoutKit
import PDFKit
import RenderKit
import SuperPDFCore

// RenderKit's checks (WP2): rasterization and encoding, PDF/A and PDF/X output, imposition, print as image, colour
// conversion, separations, colour usage and the page-image cache, on generated fixtures. Renders are looked at by
// sampling pixels; set SUPERPDF_SELFTEST_RENDERS=<folder> to also write the PNGs for eyes.

func registerRenderKitTests() {
    let rendersFolder = ProcessInfo.processInfo.environment["SUPERPDF_SELFTEST_RENDERS"].map { URL(fileURLWithPath: $0) }
    func save(_ data: Data, _ name: String) {
        guard let rendersFolder else { return }
        try? FileManager.default.createDirectory(at: rendersFolder, withIntermediateDirectories: true)
        try? data.write(to: rendersFolder.appendingPathComponent(name))
    }
    func decode(_ data: Data) -> CGImage? {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil) else { return nil }
        return CGImageSourceCreateImageAtIndex(source, 0, nil)
    }
    /// RGB of a pixel, from any 8-bit image, rendered into sRGB.
    func pixel(_ image: CGImage, _ x: Int, _ y: Int) -> (r: Int, g: Int, b: Int) {
        var bytes = [UInt8](repeating: 0, count: 4)
        let context = CGContext(data: &bytes, width: 1, height: 1, bitsPerComponent: 8, bytesPerRow: 4, space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        context.draw(image, in: CGRect(x: -x, y: -(image.height - 1 - y), width: image.width, height: image.height))
        return (Int(bytes[0]), Int(bytes[1]), Int(bytes[2]))
    }
    func isDark(_ p: (r: Int, g: Int, b: Int)) -> Bool { p.r + p.g + p.b < 300 }
    func isWhite(_ p: (r: Int, g: Int, b: Int)) -> Bool { p.r > 245 && p.g > 245 && p.b > 245 }
    @MainActor func run<T>(_ name: String, _ work: @escaping @MainActor () async throws -> T) -> T? {
        if !(Services.render is RenderService) { RenderKitModule.install() }
        switch complete(300, work) {
        case .success(let value): return value
        case .failure(let error): check(false, "\(name) failed: \(error)"); return nil
        default: check(false, "\(name) timed out"); return nil
        }
    }
    func output(_ name: String) -> URL {
        try? FileManager.default.createDirectory(at: scratch, withIntermediateDirectories: true)
        return scratch.appendingPathComponent("render-\(name).pdf")
    }
    func pageCount(_ url: URL) -> Int { PDFDocument(url: url)?.pageCount ?? -1 }
    func bytes(_ url: URL) -> String { String(decoding: (try? Data(contentsOf: url)) ?? Data(), as: UTF8.self) }
    /// A page with a red square, a cyan (CMYK) square and black text, with a trim box; used by the colour checks.
    func colourFixture(trimBox: Bool = false) -> Data {
        let data = NSMutableData()
        var box = CGRect(origin: .zero, size: Fixture.letter)
        let context = CGContext(consumer: CGDataConsumer(data: data as CFMutableData)!, mediaBox: &box, nil)!
        var info: [CFString: Any] = [:]
        if trimBox { var trim = CGRect(x: 18, y: 18, width: 576, height: 756); info[kCGPDFContextTrimBox] = Data(bytes: &trim, count: MemoryLayout<CGRect>.size) }
        context.beginPDFPage(info as CFDictionary)
        context.setFillColor(CGColor(red: 1, green: 0, blue: 0, alpha: 1)); context.fill(CGRect(x: 72, y: 500, width: 200, height: 200))
        context.setFillColor(CGColor(genericCMYKCyan: 1, magenta: 0, yellow: 0, black: 0, alpha: 1)); context.fill(CGRect(x: 340, y: 500, width: 200, height: 200))
        Fixture.text("Colour page", at: CGPoint(x: 72, y: 740), font: NSFont(name: "Helvetica-Bold", size: 24)!, in: context)
        context.endPDFPage(); context.closePDF()
        return data as Data
    }
    /// A hand-written PDF whose content uses a Separation colour space, for the plate list (Quartz cannot write one).
    func spotFixture() -> Data {
        let objects = [
            "<< /Type /Catalog /Pages 2 0 R >>",
            "<< /Type /Pages /Kids [3 0 R] /Count 1 >>",
            "<< /Type /Page /Parent 2 0 R /MediaBox [0 0 200 200] /Resources << /ColorSpace << /CS0 [/Separation /PANTONE#20300#20C /DeviceCMYK << /FunctionType 2 /Domain [0 1] /C0 [0 0 0 0] /C1 [1 0.4 0 0] /N 1 >>] >> >> /Contents 4 0 R >>",
        ]
        let content = "/CS0 cs 1 scn 20 20 100 100 re f 0 0 1 rg 130 130 50 50 re f"
        var pdf = "%PDF-1.4\n"
        var offsets: [Int] = []
        for (index, object) in objects.enumerated() { offsets.append(pdf.utf8.count); pdf += "\(index + 1) 0 obj\n\(object)\nendobj\n" }
        offsets.append(pdf.utf8.count)
        pdf += "4 0 obj\n<< /Length \(content.utf8.count) >>\nstream\n\(content)\nendstream\nendobj\n"
        let xref = pdf.utf8.count
        pdf += "xref\n0 5\n0000000000 65535 f \n" + offsets.map { String(format: "%010d 00000 n \n", $0) }.joined()
        pdf += "trailer\n<< /Size 5 /Root 1 0 R >>\nstartxref\n\(xref)\n%%EOF\n"
        return Data(pdf.utf8)
    }

    SelfTest.cases.append(("RenderKit.install", {
        installFakes()
        RenderKitModule.install()
        check(Services.render is RenderService, "install registers the RenderService")
    }))

    SelfTest.cases.append(("RenderKit.rasterize", {
        let source = PDFSource.data(Fixture.letterDocument())
        guard let pages = run("rasterize", { try await Services.render.rasterize(source, pages: [0], dpi: 72, format: .png, quality: 1, colorSpace: .sRGB) }) else { return }
        check(pages.count == 1 && pages[0].index == 0 && pages[0].pixelSize == CGSize(width: 612, height: 792), "one Letter page at 72 dpi: \(pages.map(\.pixelSize))")
        guard let image = decode(pages[0].data) else { check(false, "PNG decodes"); return }
        save(pages[0].data, "letter-72.png")
        check(image.width == 612 && image.height == 792, "pixel size")
        check(isWhite(pixel(image, 10, 10)), "white margin")
        // "Acme Corporation" sits at (72, 740) in 11 pt bold: row 792 − 744 has ink somewhere in x 72…150.
        let inkOnLetterhead = (72..<150).contains { isDark(pixel(image, $0, 792 - 744)) }
        check(inkOnLetterhead, "letterhead text rendered")
        guard let high = run("rasterize 300", { try await Services.render.rasterize(source, pages: [0], dpi: 300, format: .jpeg, quality: 0.8, colorSpace: .gray) }) else { return }
        check(high[0].pixelSize == CGSize(width: 2550, height: 3300), "300 dpi size: \(high[0].pixelSize)")
        check(high[0].data.starts(with: [0xFF, 0xD8]), "JPEG bytes")
        guard let cmyk = run("rasterize cmyk", { try await Services.render.rasterize(source, pages: [0], dpi: 36, format: .tiff, quality: 1, colorSpace: .cmyk) }) else { return }
        check(decode(cmyk[0].data)?.colorSpace?.model == .cmyk, "CMYK TIFF keeps its model: \(String(describing: decode(cmyk[0].data)?.colorSpace?.model))")
        check(cmyk[0].pixelSize == CGSize(width: 306, height: 396), "36 dpi size")
        guard let heic = run("rasterize heic", { try await Services.render.rasterize(source, pages: [0], dpi: 36, format: .heic, quality: 0.8, colorSpace: .sRGB) }) else { return }
        check(decode(heic[0].data) != nil, "HEIC decodes")
        if case .failure(let error)? = complete(300, { try await Services.render.rasterize(source, pages: [3], dpi: 72, format: .png, quality: 1, colorSpace: .sRGB) }) {
            check(error as? RenderError == .noSuchPage(3), "missing page fails cleanly: \(error)")
        } else { check(false, "missing page rendered") }
        check(ImageEncoder.supportedFormats.contains(.png) && ImageEncoder.supportedFormats.contains(.heic), "ImageIO formats: \(ImageEncoder.supportedFormats)")
        if !ImageEncoder.supportedFormats.contains(.webp) {
            if case .failure(let error)? = complete(300, { try await Services.render.rasterize(source, pages: [0], dpi: 36, format: .webp, quality: 0.8, colorSpace: .sRGB) }) {
                check(error as? RenderError == .unsupportedFormat(.webp), "WebP without an encoder fails cleanly: \(error)")
            } else { check(false, "WebP encoded without an encoder") }
        }
    }))

    SelfTest.cases.append(("RenderKit.multiPageTIFFAndLimits", {
        let document = CGPDFDocument(CGDataProvider(data: Fixture.report() as CFData)!)!
        let images = (0..<3).compactMap { try? Rasterizer.render(document.page(at: $0 + 1)!, dpi: 36) }
        check(images.count == 3, "three rasters")
        guard let tiff = try? ImageEncoder.encode(images, format: .tiff, dpi: 36), let source = CGImageSourceCreateWithData(tiff as CFData, nil) else { check(false, "multi-page TIFF"); return }
        check(CGImageSourceGetCount(source) == 3, "TIFF holds three pages: \(CGImageSourceGetCount(source))")
        let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any]
        check((properties?[kCGImagePropertyDPIWidth] as? Double) == 36, "resolution written: \(String(describing: properties?[kCGImagePropertyDPIWidth]))")
        let limit = Rasterizer.maxPixels
        Rasterizer.maxPixels = 1000
        defer { Rasterizer.maxPixels = limit }
        do { _ = try Rasterizer.render(document.page(at: 1)!, dpi: 72); check(false, "oversize raster refused") } catch { check(error as? RenderError == .tooLarge(width: 612, height: 792), "tooLarge: \(error)") }
        guard let thumb = try? Rasterizer.render(document.page(at: 1)!, fitting: CGSize(width: 20, height: 40)) else { check(false, "thumbnail"); return }
        check(thumb.width == 20 && thumb.height == 26, "fitting keeps the aspect: \(thumb.width)x\(thumb.height)")
    }))

    SelfTest.cases.append(("RenderKit.pdfa", {
        let destination = output("pdfa")
        guard run("writePDFA", { try await Services.render.writePDFA(.data(Fixture.report()), level: .a2b, to: destination) }) != nil else { return }
        check(pageCount(destination) == 3, "three pages out")
        let text = bytes(destination)
        check(text.contains("/OutputIntents") && text.contains("GTS_PDFA1"), "OutputIntent written")
        check(text.contains("/Metadata"), "XMP metadata stream present")
        check(text.contains("/FontFile"), "fonts embedded")
        check(PDFDocument(url: destination)?.page(at: 1)?.string?.contains("Page 2 paragraph 1") == true, "text survives re-rendering")
        guard let pages = run("rasterize pdfa", { try await Services.render.rasterize(.file(destination), pages: [0], dpi: 36, format: .png, quality: 1, colorSpace: .sRGB) }) else { return }
        check(pages[0].pixelSize == CGSize(width: 306, height: 396), "page size kept")
    }))

    SelfTest.cases.append(("RenderKit.pdfx", {
        let fixture = colourFixture(trimBox: true)
        let x4 = output("pdfx4")
        guard run("writePDFX x4", { try await Services.render.writePDFX(.data(fixture), level: .x4, outputIntent: nil, to: x4) }) != nil else { return }
        check(pageCount(x4) == 1, "one page out")
        let text = bytes(x4)
        check(text.contains("/OutputIntents") && text.contains("GTS_PDFX") && text.contains("Generic CMYK"), "PDF/X OutputIntent written")
        check(text.contains("/TrimBox [18 18 594 774]"), "trim box carried over: \(text.components(separatedBy: "/TrimBox").dropFirst().first?.prefix(24) ?? "")")
        let x4Page = CGPDFDocument(x4 as CFURL)!.page(at: 1)!
        check(ColorUsage.scan(x4Page).usesRGB, "X-4 keeps RGB content as drawn")
        check(PageGraphicsScanner.scan(x4Page).images.isEmpty, "X-4 keeps vectors")
        let x1a = output("pdfx1a")
        guard run("writePDFX x1a", { try await Services.render.writePDFX(.data(fixture), level: .x1a, outputIntent: nil, to: x1a) }) != nil else { return }
        let x1aPage = CGPDFDocument(x1a as CFURL)!.page(at: 1)!
        let usage = ColorUsage.scan(x1aPage)
        check(!usage.usesRGB && usage.usesCMYK, "X-1a page converted to CMYK: \(usage)")
        check(PageGraphicsScanner.scan(x1aPage).images.count == 1, "X-1a RGB page became one image")
        check(bytes(x1a).contains("/TrimBox [18 18 594 774]"), "trim box kept on the converted page")
        guard let pages = run("rasterize x1a", { try await Services.render.rasterize(.file(x1a), pages: [0], dpi: 72, format: .png, quality: 1, colorSpace: .sRGB) }), let image = decode(pages[0].data) else { return }
        save(pages[0].data, "pdfx1a.png")
        let red = pixel(image, 172, 792 - 600)
        check(red.r > 150 && red.g < 90 && red.b < 90, "red square survives the CMYK conversion: \(red)")
        // A broken profile fails cleanly.
        let badProfile = output("bad-profile").deletingPathExtension().appendingPathExtension("icc")
        try? Data("nope".utf8).write(to: badProfile)
        if case .failure(let error)? = complete(300, { try await Services.render.writePDFX(.data(fixture), level: .x4, outputIntent: badProfile, to: output("pdfx-bad")) }) {
            check(error as? RenderError == .badProfile, "bad profile: \(error)")
        } else { check(false, "bad profile accepted") }
    }))

    SelfTest.cases.append(("RenderKit.impose", {
        var numbered: [(CGSize, (CGContext) -> Void)] = []
        for n in 1...6 { numbered.append((Fixture.letter, { c in Fixture.text("Page \(n)", at: CGPoint(x: 200, y: 400), font: NSFont(name: "Helvetica-Bold", size: 72)!, in: c) })) }
        let six = PDFSource.data(Fixture.pdf(numbered))
        let booklet = output("booklet")
        guard run("booklet", { try await Services.render.impose(six, layout: .booklet, paper: .letter, to: booklet) }) != nil else { return }
        check(pageCount(booklet) == 4, "six pages pad to eight: two sheets, four sides, got \(pageCount(booklet))")
        guard let sheets = run("rasterize booklet", { try await Services.render.rasterize(.file(booklet), pages: [0, 1, 2, 3], dpi: 36, format: .png, quality: 1, colorSpace: .sRGB) }) else { return }
        check(sheets.allSatisfy { $0.pixelSize == CGSize(width: 396, height: 306) }, "landscape Letter sheets: \(sheets.map(\.pixelSize))")
        for (index, sheet) in sheets.enumerated() { save(sheet.data, "booklet-\(index).png") }
        // Sheet 1 front: blank (8) left, page 1 right; sheet 1 back: page 2 left, page 7 (blank) right.
        guard let front = decode(sheets[0].data), let back = decode(sheets[1].data) else { return }
        func hasInk(_ image: CGImage, _ xRange: Range<Int>) -> Bool { xRange.contains { x in (120..<200).contains { y in isDark(pixel(image, x, y)) } } }
        check(!hasInk(front, 20..<190) && hasInk(front, 210..<380), "front of sheet 1: blank | page 1")
        check(hasInk(back, 20..<190) && !hasInk(back, 210..<380), "back of sheet 1: page 2 | blank")
        // Order via the text on the sheets.
        let bookletPDF = PDFDocument(url: booklet)!
        let texts = (0..<4).map { bookletPDF.page(at: $0)!.string ?? "" }
        check(texts[0].contains("Page 1") && texts[1].contains("Page 2") && texts[2].contains("Page 6") && texts[2].contains("Page 3") && texts[3].contains("Page 4") && texts[3].contains("Page 5"), "saddle-stitch order: \(texts)")

        let nup = output("nup")
        guard run("nUp", { try await Services.render.impose(six, layout: .nUp(4), paper: .a4, to: nup) }) != nil else { return }
        check(pageCount(nup) == 2, "4-up over six pages: two sheets")
        check(PDFDocument(url: nup)!.page(at: 0)!.bounds(for: .mediaBox).size == CGSize(width: 595.28, height: 841.89), "portrait A4 for a 2x2 grid")
        let two = output("2up")
        guard run("2-up fit", { try await Services.render.impose(six, layout: .nUp(2), paper: .fitContent, to: two) }) != nil else { return }
        check(PDFDocument(url: two)!.page(at: 0)!.bounds(for: .mediaBox).size == CGSize(width: 1224, height: 792) && pageCount(two) == 3, "fitContent 2-up sheet is two pages wide")

        let contact = output("contact")
        guard run("contact sheet", { try await Services.render.impose(.data(Fixture.report()), layout: .contactSheet(columns: 2), paper: .letter, to: contact) }) != nil else { return }
        check(pageCount(contact) == 2, "two Letter thumbnails per two-column Letter sheet: three pages need two sheets, got \(pageCount(contact))")
        check(PDFDocument(url: contact)!.page(at: 0)!.string?.contains("3") == true, "page numbers labelled")
        guard let sheet = run("rasterize contact", { try await Services.render.rasterize(.file(contact), pages: [0], dpi: 72, format: .png, quality: 1, colorSpace: .sRGB) }) else { return }
        save(sheet[0].data, "contact.png")
        guard let ten = run("contact 10", { try await Services.render.impose(.data(makePDF(pages: 10)), layout: .contactSheet(columns: 4), paper: .letter, to: output("contact10")) }) else { return }
        _ = ten
        check(pageCount(output("contact10")) == 1, "ten pages at four columns fit one Letter sheet")
    }))

    SelfTest.cases.append(("RenderKit.printAsImage", {
        let destination = output("print-as-image")
        guard run("printAsImage", { try await Services.render.printAsImage(.data(Fixture.letterDocument()), dpi: 150, to: destination) }) != nil else { return }
        let pdf = PDFDocument(url: destination)!
        check(pdf.pageCount == 1 && pdf.page(at: 0)!.bounds(for: .mediaBox).size == Fixture.letter, "page size kept")
        check((pdf.page(at: 0)!.string ?? "").isEmpty, "no text left, only pixels")
        let page = CGPDFDocument(destination as CFURL)!.page(at: 1)!
        check(PageGraphicsScanner.scan(page).images.count == 1, "one image per page")
        check(bytes(destination).contains("/DCTDecode"), "JPEG kept as DCT, not re-encoded")
        guard let pages = run("rasterize print", { try await Services.render.rasterize(.file(destination), pages: [0], dpi: 72, format: .png, quality: 1, colorSpace: .sRGB) }), let image = decode(pages[0].data) else { return }
        check((72..<150).contains { isDark(pixel(image, $0, 792 - 744)) }, "the letterhead is still visible")
    }))

    SelfTest.cases.append(("RenderKit.convertColors", {
        let fixture = colourFixture()
        let gray = output("gray")
        guard run("convertColors gray", { try await Services.render.convertColors(.data(fixture), to: .gray, profile: nil, flattenTransparencyAt: 100, to: gray) }) != nil else { return }
        let usage = ColorUsage.scan(CGPDFDocument(gray as CFURL)!.page(at: 1)!)
        check(usage.usesGray && !usage.usesRGB && !usage.usesCMYK, "grey output: \(usage)")
        check(bytes(gray).contains("/OutputIntents"), "OutputIntent written")
        guard let pages = run("rasterize gray", { try await Services.render.rasterize(.file(gray), pages: [0], dpi: 72, format: .png, quality: 1, colorSpace: .sRGB) }), let image = decode(pages[0].data) else { return }
        save(pages[0].data, "gray.png")
        let p = pixel(image, 172, 792 - 600)
        check(abs(p.r - p.g) < 3 && abs(p.g - p.b) < 3 && p.r < 200, "the red square is now grey: \(p)")
        let cmyk = output("cmyk")
        guard run("convertColors cmyk", { try await Services.render.convertColors(.data(fixture), to: .cmyk, profile: nil, flattenTransparencyAt: nil, to: cmyk) }) != nil else { return }
        let cmykUsage = ColorUsage.scan(CGPDFDocument(cmyk as CFURL)!.page(at: 1)!)
        check(cmykUsage.usesCMYK && !cmykUsage.usesRGB, "CMYK output: \(cmykUsage)")
        check(bytes(cmyk).contains("GTS_PDFX"), "CMYK conversion carries a PDF/X-style intent")
    }))

    SelfTest.cases.append(("RenderKit.separations", {
        let source = PDFSource.data(colourFixture())
        guard let cyan = run("cyan plate", { try await Services.render.separation(source, page: 0, plate: .cyan, dpi: 36) }) else { return }
        save(cyan.image.data, "plate-cyan.png")
        check(cyan.image.pixelSize == CGSize(width: 306, height: 396) && cyan.image.index == 0, "plate raster size")
        check(cyan.maxInk >= 99 && cyan.maxInk <= 400, "max ink from the solid squares: \(cyan.maxInk)")
        guard let plate = decode(cyan.image.data) else { check(false, "plate decodes"); return }
        let onCyanSquare = pixel(plate, 220, 396 - 300)   // (440, 600) in page space
        check(onCyanSquare.r < 60 && onCyanSquare.g > 200 && onCyanSquare.b > 200, "cyan plate shows the cyan square in cyan: \(onCyanSquare)")
        let onRedSquare = pixel(plate, 86, 396 - 300)
        check(onRedSquare.r > 200 && onRedSquare.g > 200, "red square has (nearly) no cyan: \(onRedSquare)")
        guard let magenta = run("magenta plate", { try await Services.render.separation(source, page: 0, plate: .magenta, dpi: 36) }), let magentaPlate = decode(magenta.image.data) else { return }
        let redOnMagenta = pixel(magentaPlate, 86, 396 - 300)
        check(redOnMagenta.g < 80 && redOnMagenta.r > 200, "red square carries magenta: \(redOnMagenta)")
        guard let black = run("black plate", { try await Services.render.separation(source, page: 0, plate: .black, dpi: 36) }), let blackPlate = decode(black.image.data) else { return }
        check(isWhite(pixel(blackPlate, 220, 396 - 300)), "black plate is empty over the cyan square")
        check((36..<100).contains { isDark(pixel(blackPlate, $0, 396 - 372)) }, "black plate carries the text")
        if case .failure(let error)? = complete(300, { try await Services.render.separation(source, page: 0, plate: .spot("PANTONE 300 C"), dpi: 36) }) {
            check(error as? RenderError == .unsupportedPlate("PANTONE 300 C"), "spot plates are refused by name: \(error)")
        } else { check(false, "spot plate rendered") }
    }))

    SelfTest.cases.append(("RenderKit.colorUsage", {
        let colour = ColorUsage.scan(CGPDFDocument(CGDataProvider(data: colourFixture() as CFData)!)!.page(at: 1)!)
        check(colour.usesRGB && colour.usesCMYK && colour.spotColors.isEmpty && !colour.usesTransparency, "process colours: \(colour)")
        let letter = ColorUsage.scan(CGPDFDocument(CGDataProvider(data: Fixture.letterDocument() as CFData)!)!.page(at: 1)!)
        check(!letter.usesRGB && !letter.usesCMYK && letter.usesGray, "black text is grey: \(letter)")
        let spotData = spotFixture()
        guard let spotDocument = CGPDFDocument(CGDataProvider(data: spotData as CFData)!), let spotPage = spotDocument.page(at: 1) else { check(false, "spot fixture opens"); return }
        let spot = ColorUsage.scan(spotPage)
        check(spot.spotColors == ["PANTONE 300 C"] && spot.usesRGB, "spot colourant named: \(spot)")
        let figure = ColorUsage.scan(CGPDFDocument(CGDataProvider(data: Fixture.figure() as CFData)!)!.page(at: 1)!)
        check(figure.usesRGB, "an RGB image counts as RGB use")
    }))

    SelfTest.cases.append(("RenderKit.pageImageCache", {
        let cache = PageImageCache(byteLimit: 8 << 20, maxConcurrent: 2)
        let source = PDFSource.data(Fixture.report())
        guard let first = run("cache image", { try await cache.image(source, page: 1, maxPixelSize: CGSize(width: 160, height: 160)) }) else { return }
        check(first.width == 124 && first.height == 160, "thumbnail fitted: \(first.width)x\(first.height)")
        guard let again = run("cache hit", { try await cache.image(source, page: 1, maxPixelSize: CGSize(width: 160, height: 160)) }) else { return }
        check(first === again, "second request is the cached image")
        guard let other = run("cache other size", { try await cache.image(source, page: 1, maxPixelSize: CGSize(width: 80, height: 80)) }) else { return }
        check(other !== first && other.height == 80, "a different size renders anew")
        guard let count = run("page count", { try await cache.pageCount(source) }) else { return }
        check(count == 3, "page count through the kept document")
        // Many concurrent requests complete, including duplicates in flight.
        guard let many = run("concurrent", {
            try await withThrowingTaskGroup(of: Int.self) { group in
                for request in 0..<12 { group.addTask { try await cache.image(source, page: request % 3, maxPixelSize: CGSize(width: 200, height: 200)).height } }
                return try await group.reduce(into: [Int]()) { $0.append($1) }
            }
        }) else { return }
        check(many.count == 12 && many.allSatisfy { $0 == 200 }, "twelve concurrent thumbnails: \(many)")
        guard let text = run("thumb pixels", { try await cache.image(source, page: 0, maxPixelSize: CGSize(width: 612, height: 792)) }) else { return }
        check((72..<300).contains { isDark(pixel(text, $0, 792 - 705)) }, "thumbnail shows the page's text")
        if case .failure(let error)? = complete(300, { try await cache.image(source, page: 9, maxPixelSize: CGSize(width: 50, height: 50)) }) {
            check(error as? RenderError == .noSuchPage(9), "missing page: \(error)")
        } else { check(false, "missing page rendered") }
        if case .failure(let error)? = complete(300, { try await cache.image(.data(Data("x".utf8)), page: 0, maxPixelSize: CGSize(width: 50, height: 50)) }) {
            check(error as? RenderError == .cannotOpen, "garbage: \(error)")
        } else { check(false, "garbage rendered") }
        guard run("invalidate", { await cache.invalidate(source); await cache.removeAll() }) != nil else { return }
        guard let fresh = run("after removeAll", { try await cache.image(source, page: 1, maxPixelSize: CGSize(width: 160, height: 160)) }) else { return }
        check(fresh !== first, "removeAll drops the cached image")
    }))

    SelfTest.cases.append(("RenderKit.locked", {
        let pdf = PDFDocument(data: Fixture.letterDocument())!
        let lockedURL = output("locked")
        pdf.write(to: lockedURL, withOptions: [.userPasswordOption: "pw", .ownerPasswordOption: "pw"])
        if case .failure(let error)? = complete(300, { try await Services.render.rasterize(.file(lockedURL), pages: [0], dpi: 36, format: .png, quality: 1, colorSpace: .sRGB) }) {
            check(error as? RenderError == .locked, "locked without password: \(error)")
        } else { check(false, "locked file rendered without a password") }
        guard let pages = run("with password", { try await Services.render.rasterize(.file(lockedURL, password: "pw"), pages: [0], dpi: 36, format: .png, quality: 1, colorSpace: .sRGB) }) else { return }
        check(pages.count == 1, "rendered with the password")
    }))
}
