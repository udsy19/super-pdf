import AppKit
import CoreText
import DocumentKit
@testable import EditKit
import ImageIO
import PDFKit
import PDFModelKit
import RenderKit
import SuperPDFCore
import ToolsKit
import UniformTypeIdentifiers

// EditKit's checks (WP8): fonts (encodings, CMaps, the TrueType subsetter), the content interpreter, block editing with
// reflow and substitution, find & replace, images, every decoration (headers and footers, page numbers, Bates,
// watermark, background), stamps, links, scripts, properties, transitions, destinations, optional content, and the
// panels driven through ToolsKit's session. Results are verified by re-extracting text with PDFKit and by rendering
// with Quartz and sampling the pixels; set SUPERPDF_SELFTEST_RENDERS=<folder> to write the renders for eyes.
func registerEditKitTests() {
    SelfTest.cases.append(("EditKit.fonts", { editFonts() }))
    SelfTest.cases.append(("EditKit.textRuns", { editTextRuns() }))
    SelfTest.cases.append(("EditKit.editBlock", { editBlock() }))
    SelfTest.cases.append(("EditKit.substitution", { editSubstitution() }))
    SelfTest.cases.append(("EditKit.findReplace", { editFindReplace() }))
    SelfTest.cases.append(("EditKit.addText", { editAddText() }))
    SelfTest.cases.append(("EditKit.images", { editImages() }))
    SelfTest.cases.append(("EditKit.headersFooters", { editHeadersFooters() }))
    SelfTest.cases.append(("EditKit.pageNumbers", { editPageNumbers() }))
    SelfTest.cases.append(("EditKit.bates", { editBates() }))
    SelfTest.cases.append(("EditKit.watermark", { editWatermark() }))
    SelfTest.cases.append(("EditKit.stamps", { editStamps() }))
    SelfTest.cases.append(("EditKit.scripts", { editScripts() }))
    SelfTest.cases.append(("EditKit.properties", { editProperties() }))
    SelfTest.cases.append(("EditKit.transitionsAndDestinations", { editTransitionsAndDestinations() }))
    SelfTest.cases.append(("EditKit.layers", { editLayers() }))
    SelfTest.cases.append(("EditKit.service", { editService() }))
    SelfTest.cases.append(("EditKit.modeSession", { editModeSession() }))
    SelfTest.cases.append(("EditKit.panels", { editPanels() }))
    SelfTest.cases.append(("EditKit.interaction", { editInteraction() }))
}

// MARK: - Fixtures and helpers

enum EditFixture {
    static let letter = CGSize(width: 612, height: 792)
    static let body = NSFont(name: "Helvetica", size: 11)!
    static let bold = NSFont(name: "Helvetica-Bold", size: 18)!
    static let serif = NSFont(name: "Georgia", size: 12)!

    static let paragraph1 = "The quick brown fox jumps over the lazy dog while the five boxing wizards jump quickly and the sphinx of black quartz judges my vow."
    static let paragraph2 = "Please let us know when you are available to meet so we can go through the plans together and agree on the schedule."

    /// A letter-like page: a heading, a centred title, a right-aligned date, two wrapped paragraphs and a picture.
    static func letterPage(image: CGImage? = nil) -> Data {
        Fixture.pdf([(letter, { c in
            Fixture.text("Project update", at: CGPoint(x: 72, y: 720), font: bold, in: c)
            let title = "Quarterly report"
            Fixture.text(title, at: CGPoint(x: 306 - Fixture.textWidth(title, font: body) / 2, y: 690), font: body, in: c)
            let date = "20 October 2026"
            Fixture.text(date, at: CGPoint(x: 540 - Fixture.textWidth(date, font: body), y: 690), font: body, in: c)
            var y = Fixture.paragraph(paragraph1, topLeft: CGPoint(x: 72, y: 650), width: 300, font: body, in: c)
            y = Fixture.paragraph(paragraph2, topLeft: CGPoint(x: 72, y: y - 24), width: 300, font: body, in: c)
            Fixture.text("Serif line in Georgia", at: CGPoint(x: 72, y: y - 40), font: serif, in: c)
            if let image { c.draw(image, in: CGRect(x: 400, y: 400, width: 150, height: 100)) }
        })])
    }

    static func image(width: Int = 60, height: Int = 40, red: Bool = true) -> CGImage {
        let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                                space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue)!
        context.setFillColor(red ? CGColor(red: 0.9, green: 0.1, blue: 0.1, alpha: 1) : CGColor(red: 0.1, green: 0.2, blue: 0.9, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        return context.makeImage()!
    }

    /// A PDF written by hand through PDFModelKit whose text uses the standard Helvetica (not embedded), the way many
    /// producers write simple documents.
    static func standardFontPage(lines: [(String, CGPoint)], size: CGSize = letter) -> Data {
        let model = PDFModel()
        let page = try! model.addBlankPage(size: size)
        let font = model.makeIndirect(.dictionary(["Type": .name("Font"), "Subtype": .name("Type1"), "BaseFont": .name("Helvetica"),
                                                   "Encoding": .name("WinAnsiEncoding")]))
        page.addResource(font, category: "Font", prefix: "F")
        var content = "BT /F0 12 Tf\n"
        for (text, point) in lines {
            let escaped = text.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "(", with: "\\(").replacingOccurrences(of: ")", with: "\\)")
            content += "1 0 0 1 \(point.x) \(point.y) Tm (\(escaped)) Tj\n"
        }
        content += "ET\n"
        page.setContentData(Data(content.utf8))
        return try! model.data()
    }
}

func editText(_ data: Data, page: Int = 0) -> String {
    guard let doc = PDFDocument(data: data) else { return "<unopenable>" }
    return doc.page(at: page)?.string ?? ""
}

/// Renders a page at `dpi` and returns the image (saved as PNG when SUPERPDF_SELFTEST_RENDERS is set).
func editRender(_ data: Data, page index: Int = 0, dpi: Double = 72, name: String) -> CGImage? {
    guard let document = try? PDFPages.open(.data(data)), let page = try? PDFPages.page(document, at: index),
          let image = try? Rasterizer.render(page, dpi: dpi) else { return nil }
    if let folder = ProcessInfo.processInfo.environment["SUPERPDF_SELFTEST_RENDERS"] {
        let url = URL(fileURLWithPath: folder).appendingPathComponent("edit-\(name).png")
        try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        if let png = try? ImageEncoder.encode(image, format: .png) { try? png.write(to: url) }
        print("  render: \(url.path)")
    }
    return image
}

/// Renders a page through PDFKit (annotations included) at 72 dpi.
@MainActor
func editRenderWithAnnotations(_ data: Data, page index: Int = 0, name: String) -> CGImage? {
    guard let document = PDFDocument(data: data), let page = document.page(at: index) else { return nil }
    let bounds = page.bounds(for: .cropBox)
    let width = Int(bounds.width.rounded()), height = Int(bounds.height.rounded())
    guard let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0, space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
    context.setFillColor(CGColor(gray: 1, alpha: 1))
    context.fill(CGRect(x: 0, y: 0, width: width, height: height))
    page.draw(with: .cropBox, to: context)
    guard let image = context.makeImage() else { return nil }
    if let folder = ProcessInfo.processInfo.environment["SUPERPDF_SELFTEST_RENDERS"] {
        let url = URL(fileURLWithPath: folder).appendingPathComponent("edit-\(name).png")
        if let png = try? ImageEncoder.encode(image, format: .png) { try? png.write(to: url) }
        print("  render: \(url.path)")
    }
    return image
}

/// The share of pixels darker than mid-grey in a page-space rectangle (image rendered at `dpi`).
func editInk(_ image: CGImage, in rect: CGRect, pageHeight: Double, dpi: Double = 72) -> Double {
    let scale = dpi / 72
    let x0 = max(0, Int(rect.minX * scale)), x1 = min(image.width, Int(rect.maxX * scale))
    let y0 = max(0, Int((pageHeight - rect.maxY) * scale)), y1 = min(image.height, Int((pageHeight - rect.minY) * scale))
    guard x1 > x0, y1 > y0 else { return 0 }
    let width = x1 - x0, height = y1 - y0
    var bytes = [UInt8](repeating: 0, count: width * height * 4)
    let context = CGContext(data: &bytes, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width * 4,
                            space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
    context.draw(image, in: CGRect(x: -x0, y: -(image.height - y1), width: image.width, height: image.height))
    var dark = 0
    for i in stride(from: 0, to: bytes.count, by: 4) where Int(bytes[i]) + Int(bytes[i + 1]) + Int(bytes[i + 2]) < 384 { dark += 1 }
    return Double(dark) / Double(width * height)
}

/// The average colour of a page-space rectangle.
func editColor(_ image: CGImage, in rect: CGRect, pageHeight: Double, dpi: Double = 72) -> (r: Double, g: Double, b: Double) {
    let scale = dpi / 72
    let x0 = max(0, Int(rect.minX * scale)), x1 = min(image.width, Int(rect.maxX * scale))
    let y0 = max(0, Int((pageHeight - rect.maxY) * scale)), y1 = min(image.height, Int((pageHeight - rect.minY) * scale))
    guard x1 > x0, y1 > y0 else { return (0, 0, 0) }
    let width = x1 - x0, height = y1 - y0
    var bytes = [UInt8](repeating: 0, count: width * height * 4)
    let context = CGContext(data: &bytes, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width * 4,
                            space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
    context.draw(image, in: CGRect(x: -x0, y: -(image.height - y1), width: image.width, height: image.height))
    var r = 0, g = 0, b = 0
    for i in stride(from: 0, to: bytes.count, by: 4) { r += Int(bytes[i]); g += Int(bytes[i + 1]); b += Int(bytes[i + 2]) }
    let n = Double(width * height * 255)
    return (Double(r) / n, Double(g) / n, Double(b) / n)
}

@discardableResult
func editTry<T>(_ label: String, file: String = #fileID, line: Int = #line, _ body: () throws -> T) -> T? {
    do { return try body() } catch {
        check(false, "\(label) threw \(error)", file: file, line: line)
        return nil
    }
}

// MARK: - Fonts

@MainActor
private func editFonts() {
    // Encodings and glyph names.
    check(PDFEncoding.character(0xDE, in: "MacRomanEncoding") == "\u{FB01}", "MacRoman 0xDE is the fi ligature")
    check(PDFEncoding.character(0x27, in: "StandardEncoding") == "\u{2019}", "Standard 0x27 is quoteright")
    check(PDFEncoding.code(for: "é", in: "WinAnsiEncoding") == 0xE9 && PDFEncoding.code(for: "€", in: "WinAnsiEncoding") == 0x80, "WinAnsi codes")
    check(GlyphNames.scalar(for: "eacute") == "é" && GlyphNames.scalar(for: "uni20AC") == "€" && GlyphNames.scalar(for: "fi") == "\u{FB01}", "glyph names")
    // A ToUnicode map written here parses back.
    let cmap = CMap(parsing: ToUnicodeWriter.cmap([(3, "A"), (4, "fi"), (0x1F, "€")], byteCount: 2))
    check(cmap.text(3) == "A" && cmap.text(4) == "fi" && cmap.text(0x1F) == "€" && cmap.text(9) == nil, "ToUnicode round-trips")
    let ranged = CMap(parsing: Data("1 begincodespacerange <00> <FF> endcodespacerange 1 beginbfrange <41> <43> <0061> endbfrange".utf8))
    check(ranged.text(0x42) == "b" && ranged.codes(in: Data([0x41, 0x42])).count == 2, "bfrange and one-byte codes")

    // The subsetter: Helvetica subset to "Hello" renders and extracts through an embedded Type0 font.
    let model = PDFModel()
    guard let page = editTry("blank page", { try model.addBlankPage(size: EditFixture.letter) }) else { return }
    let (font, name) = FontEmbedder.embeddedFont(NSFont(name: "Helvetica", size: 24)!, on: page)
    guard let bytes = font.encode("Hello") else { return check(false, "Helvetica encodes Hello") }
    font.finish()
    let program = font.object["DescendantFonts"]?[0]?["FontDescriptor"]?["FontFile2"]
    check(program != nil, "a FontFile2 was embedded")
    if let data = try? program?.streamData(decode: .all), let parsed = TrueTypeFont(data: data) {
        let kept = (0..<parsed.numGlyphs).filter(parsed.hasOutline)
        check(kept.count >= 4 && kept.count <= 8, "the subset keeps the glyphs of Hello and little else (\(kept.count))")
        check(data.count < 8_000, "subset is small (\(data.count) bytes)")
    } else {
        check(false, "the embedded program parses")
    }
    let hex = bytes.map { String(format: "%02X", $0) }.joined()
    page.setContentData(Data("BT /\(name) 36 Tf 1 0 0 1 72 700 Tm <\(hex)> Tj ET".utf8))
    guard let saved = editTry("save", { try model.data() }) else { return }
    check(editText(saved).contains("Hello"), "PDFKit extracts Hello from the subset font: \(editText(saved))")
    if let image = editRender(saved, name: "subset-hello") {
        check(editInk(image, in: CGRect(x: 72, y: 695, width: 100, height: 30), pageHeight: 792) > 0.08, "the subset text renders")
    }
    check(font.width(of: "Hello", size: 36) > 60 && font.width(of: "Hello", size: 36) < 120, "widths measure (\(font.width(of: "Hello", size: 36)))")
    // The standard 14 by name.
    let (helv, _) = FontEmbedder.standardFont("Helvetica-Bold", on: page)
    check(helv.encode("Café €") != nil && helv.encode("Ωmega") == nil, "WinAnsi covers Latin-1 and the euro, not Greek")
    check(abs(helv.width(of: "W", size: 10) - 9.44) < 0.3, "Helvetica-Bold W is 944 (\(helv.width(of: "W", size: 10)))")

    // Matching.
    check(FontMatcher.familyName(of: "ABCDEF+TimesNewRomanPS-BoldItalicMT") == "Times New Roman", "family of a PostScript name")
    check(FontMatcher.traits(in: "Arial-BoldItalicMT") == (true, true), "traits in a name")
    let (georgia, substituted) = FontMatcher.match(FontFacts(baseFont: "GaramondPremier-Regular", isSerif: true, isFixedPitch: false, isBold: false, isItalic: false, isSymbolic: false), size: 12)
    check(substituted && georgia.familyName == "Georgia", "a missing serif font stands in as Georgia (\(georgia.familyName ?? "?"))")
    let (arial, kept) = FontMatcher.match(FontFacts(baseFont: "Arial-BoldMT", isSerif: false, isFixedPitch: false, isBold: true, isItalic: false, isSymbolic: false), size: 12)
    check(!kept && arial.familyName == "Arial" && arial.fontDescriptor.symbolicTraits.contains(.bold), "Arial Bold is on this Mac: Arial Bold (\(arial.fontName))")
}

// MARK: - The interpreter and blocks

@MainActor
private func editTextRuns() {
    let data = EditFixture.letterPage(image: EditFixture.image())
    guard let model = editTry("open", { try PDFModel(data: data) }), let page = model.page(at: 0),
          let content = editTry("read", { try ContentInterpreter.read(page) }) else { return }
    let text = content.runs.map(\.text).joined()
    check(text.contains("Project update") && text.contains("Quarterly report") && text.contains("20 October 2026"), "runs decode the text")
    check(content.images.count == 1 && content.images[0].bounds.integral == CGRect(x: 400, y: 400, width: 150, height: 100),
          "the image is found where it was drawn: \(content.images.map(\.bounds))")
    guard let heading = content.runs.first(where: { $0.text.hasPrefix("P") && $0.fontSize * $0.matrix.d > 15 }) ?? content.runs.first else { return }
    check(abs(heading.bounds.minX - 72) < 1 && heading.bounds.minY < 720 && heading.bounds.maxY > 720, "heading bounds sit on its baseline: \(heading.bounds)")
    check(heading.font.isEmbedded && heading.font.embeddedKind == .trueType, "Quartz embeds a TrueType subset")
    check(heading.font.canShow("Project") && !heading.font.canShow("Ω"), "the subset shows its own letters, not others")

    let pageText = PageText.analyze(page, content: content)
    let blocks = pageText.blocks.sorted { $0.bounds.maxY > $1.bounds.maxY }
    let texts = blocks.map(\.text)
    check(texts.contains("Project update"), "heading block")
    check(blocks.contains { $0.text.hasPrefix("The quick brown fox") && $0.lines.count >= 3 }, "paragraph one is one block of several lines: \(texts)")
    check(blocks.contains { $0.text.hasPrefix("Please let us know") }, "paragraph two")
    if let p1 = blocks.first(where: { $0.text.hasPrefix("The quick") }) {
        check(p1.isEditable && p1.style.fontName.hasPrefix("TT") && abs(p1.style.pageFontSize - 11) < 0.1, "paragraph style: \(p1.style.fontName) \(p1.style.pageFontSize)")
        check(abs(p1.linePitch - 13.75) < 0.3, "line pitch \(p1.linePitch)")
        check(p1.alignment == .left, "left aligned (got \(p1.alignment); lines \(p1.lines.map { $0.bounds.integral }))")
        check(p1.bounds.width > 250 && p1.bounds.width <= 301, "block width \(p1.bounds.width)")
        check(pageText.block(at: CGPoint(x: 100, y: p1.bounds.midY))?.id == p1.id, "click finds the block")
    }
    if let title = blocks.first(where: { $0.text == "Quarterly report" }) {
        check(abs(title.bounds.midX - 306) < 2, "centred title")
    }
    if let serif = blocks.first(where: { $0.text.hasPrefix("Serif line") }) {
        check(serif.style.font.facts.familyName == "Georgia" && serif.style.font.facts.isSerif == false, "Georgia block: \(serif.style.font.facts)")
    }
    // Find & replace style character map: the date block's words.
    check(blocks.first { $0.text == "20 October 2026" }?.lines[0].words.count == 3, "words in the date line")
}

@MainActor
private func editBlock() {
    let data = EditFixture.letterPage()
    guard let model = editTry("open", { try PDFModel(data: data) }), let page = model.page(at: 0),
          let content = editTry("read", { try ContentInterpreter.read(page) }) else { return }
    var pageText = PageText.analyze(page, content: content)
    guard let p1 = pageText.blocks.first(where: { $0.text.hasPrefix("The quick") }) else { return check(false, "paragraph one") }
    let originalLines = p1.lines.count
    // Retype with more text: it reflows in the same box, in the same font.
    let newText = "Thank you for the plans you sent last week. We read them with interest and have a few questions about the schedule, the budget, the access road and who will be on site in the first weeks of the build."
    guard let outcome = editTry("replace", { try TextRewriter.replace(block: p1, with: TextEdit(text: newText), in: pageText, page: page) }) else { return }
    check(outcome.substitution == nil, "the paragraph's own font had every glyph")
    guard let saved = editTry("save", { try model.data() }) else { return }
    let extracted = editText(saved)
    check(extracted.contains("Thank you for the plans") && extracted.contains("first weeks"), "new text extracts: \(extracted.prefix(200))")
    check(!extracted.contains("quick brown fox"), "old text is gone")
    check(extracted.contains("Please let us know") && extracted.contains("Project update") && extracted.contains("20 October 2026"), "the rest of the page stayed")
    // Read the result back: the new block sits in the old box, one more line.
    guard let back = editTry("reopen", { try PDFModel(data: saved) }), let backPage = back.page(at: 0),
          let backContent = editTry("read back", { try ContentInterpreter.read(backPage) }) else { return }
    pageText = PageText.analyze(backPage, content: backContent)
    guard let edited = pageText.blocks.first(where: { $0.text.hasPrefix("Thank you") }) else { return check(false, "edited block reads back: \(pageText.blocks.map(\.text))") }
    // The block grew by a line, towards the next paragraph (reflow stays inside the block; nothing below moves).
    let newLines = edited.lines.prefix(4)
    check(edited.lines.count >= originalLines + 1 && newLines.last?.text.hasSuffix("build.") == true,
          "reflowed to four lines (was \(originalLines)): \(edited.lines.map(\.text))")
    let newBounds = newLines.dropFirst().reduce(newLines[0].bounds) { $0.union($1.bounds) }
    check(abs(newBounds.minX - p1.bounds.minX) < 1 && newBounds.maxX <= p1.bounds.maxX + 1, "same left edge and width: \(newBounds) vs \(p1.bounds)")
    check(abs(edited.lines[0].baselineStart.y - p1.lines[0].baselineStart.y) < 0.5, "first baseline kept")
    check(abs(edited.linePitch - p1.linePitch) < 0.3, "line pitch kept (\(edited.linePitch))")
    // The subset had no “W”, so the text went to Helvetica by name: the same face, no notice.
    check(edited.style.font.facts.familyName == "Helvetica" && !edited.style.font.isEmbedded, "same family, by name (\(edited.style.font.baseFont))")
    if let image = editRender(saved, name: "block-reflow") {
        let lastLine = edited.lines.last!.bounds
        check(editInk(image, in: lastLine, pageHeight: 792) > 0.05, "the extra line renders with ink")
        check(editInk(image, in: CGRect(x: 72, y: lastLine.minY - 16, width: 300, height: 12), pageHeight: 792) < 0.02, "below it is blank (the old lines are gone)")
    }
    // Retyping again (the block is now ours) and emptying it.
    guard let again = editTry("replace again", { try TextRewriter.replace(block: edited, with: TextEdit(text: "Short."), in: pageText, page: backPage) }) else { return }
    check(again.bounds.width < 60, "a short block is narrow (\(again.bounds))")
    if let saved2 = editTry("save 2", { try back.data() }) {
        check(editText(saved2).contains("Short.") && !editText(saved2).contains("Thank you"), "second edit replaces the first")
        let ops = (try? back.page(at: 0)?.contentStream().operations) ?? []
        check(ops.filter { $0.operator == "BMC" && $0.operands.first == .name(ContentSurgery.originalTag) }.count == 1, "one wrapper, however many edits")
    }
    // Colour, size and alignment overrides.
    if let p2 = pageText.blocks.first(where: { $0.text.hasPrefix("Please let") }) {
        editTry("styled replace") { try TextRewriter.replace(block: p2, with: TextEdit(text: "Centred and red", size: 14, color: "#FF0000", alignment: .center), in: pageText, page: backPage) }
        if let saved3 = editTry("save 3", { try back.data() }), let image = editRender(saved3, name: "block-styled") {
            let colour = editColor(image, in: CGRect(x: p2.bounds.midX - 40, y: p2.bounds.maxY - 14, width: 80, height: 12), pageHeight: 792)
            check(colour.r > colour.g + 0.05 && colour.r > colour.b + 0.05, "red text at the block's centre: \(colour)")
            check(editText(saved3).contains("Centred and red"), "styled text extracts")
        }
    }
}

@MainActor
private func editSubstitution() {
    // The Georgia line's font is renamed to a family this Mac doesn't have (its subset stays): a letter the subset lacks
    // forces a stand-in, and the notice names both fonts.
    let data = EditFixture.letterPage()
    guard let model = editTry("open", { try PDFModel(data: data) }), let page = model.page(at: 0) else { return }
    if let fonts = page.resources?["Font"] {
        for name in fonts.keys {
            guard let font = fonts[name], font["BaseFont"]?.name?.hasSuffix("Georgia") == true else { continue }
            font.set("BaseFont", .name("ABCDEF+GaramondPremier-Regular"))
            font["FontDescriptor"]?.set("FontName", .name("ABCDEF+GaramondPremier-Regular"))
            font["FontDescriptor"]?.set("Flags", .integer(34))
        }
    }
    guard let content = editTry("read", { try ContentInterpreter.read(page) }) else { return }
    let pageText = PageText.analyze(page, content: content)
    guard let serif = pageText.blocks.first(where: { $0.text.hasPrefix("Serif line") }) else { return check(false, "serif block") }
    check(serif.style.font.facts.familyName == "Garamond Premier" && serif.style.font.facts.isSerif, "the renamed font reads as a serif Garamond Premier")
    check(serif.style.font.canShow("Serif line") && !serif.style.font.canShow("Serif zebra"), "the subset has its own letters only")
    guard let outcome = editTry("replace", { try TextRewriter.replace(block: serif, with: TextEdit(text: "Serif zebra line"), in: pageText, page: page) }) else { return }
    check(outcome.substitution?.from == "Garamond Premier" && outcome.substitution?.to == "Georgia", "substitution reported: \(String(describing: outcome.substitution))")
    check(Strings.Errors.fontMissing(outcome.substitution?.from ?? "", substitute: outcome.substitution?.to ?? "")
          == "The font “Garamond Premier” isn’t on this Mac, so new text uses “Georgia” instead.", "ux §7.4 copy")
    guard let saved = editTry("save", { try model.data() }) else { return }
    check(editText(saved).contains("Serif zebra line"), "the substituted text extracts: \(editText(saved).suffix(60))")
    // A letter the subset lacks but the same family has: the family is embedded again, no notice.
    guard let back = editTry("reopen", { try PDFModel(data: saved) }), let backPage = back.page(at: 0),
          let backContent = editTry("read back", { try ContentInterpreter.read(backPage) }) else { return }
    let backText = PageText.analyze(backPage, content: backContent)
    guard let heading = backText.blocks.first(where: { $0.text == "Project update" }) else { return check(false, "heading") }
    guard let outcome2 = editTry("replace heading", { try TextRewriter.replace(block: heading, with: TextEdit(text: "Project zenith"), in: backText, page: backPage) }) else { return }
    check(outcome2.substitution == nil, "Helvetica has z, so the same family is used without a notice: \(String(describing: outcome2.substitution))")
    if let saved2 = editTry("save 2", { try back.data() }) {
        check(editText(saved2).contains("Project zenith"), "heading retyped")
        if let image = editRender(saved2, name: "substitution") {
            check(editInk(image, in: CGRect(x: 72, y: 716, width: 120, height: 16), pageHeight: 792) > 0.1, "the retyped heading renders")
            check(editInk(image, in: CGRect(x: 72, y: serif.bounds.minY, width: 100, height: serif.bounds.height), pageHeight: 792) > 0.05, "the stand-in line renders")
        }
    }
}

@MainActor
private func editFindReplace() {
    // Standard Helvetica, two lines; "colour" → "color" fits in place, "cat" → "elephant" reflows the block.
    let data = EditFixture.standardFontPage(lines: [("The colour of the cat is grey.", CGPoint(x: 72, y: 700)), ("Another colour here.", CGPoint(x: 72, y: 600))])
    guard let model = editTry("open", { try PDFModel(data: data) }), let page = model.page(at: 0) else { return }
    let greyBefore = (try? ContentInterpreter.read(page)).map { PageText.analyze(page, content: $0) }?.blocks.flatMap(\.lines).flatMap(\.words).first { $0.text.hasPrefix("grey") }?.bounds.minX
    guard let one = editTry("replace colour", { try TextRewriter.replaceAll("colour", with: "color", options: FindReplaceOptions(), page: page) }) else { return }
    check(one.replaced == 2 && one.notFitting == 0, "both occurrences replaced in place: \(one)")
    guard let saved = editTry("save", { try model.data() }) else { return }
    let text = editText(saved)
    check(text.contains("The color of the cat is grey.") && text.contains("Another color here."), "text after replace: \(text)")
    // The rest of the line closes up as typing would, with no gap: "grey." moves left by the width of the "u".
    if let back = try? PDFModel(data: saved), let p = back.page(at: 0), let content = try? ContentInterpreter.read(p) {
        let pageText = PageText.analyze(p, content: content)
        let grey = pageText.blocks.flatMap(\.lines).flatMap(\.words).first { $0.text.hasPrefix("grey") }
        let u = 556.0 / 1000 * 12   // Helvetica "u" at 12 pt
        check(grey != nil && greyBefore != nil && abs((greyBefore ?? 0) - (grey?.bounds.minX ?? 0) - u) < 0.5,
              "“grey.” moves up by the “u” (\(String(describing: grey?.bounds.minX)) vs \(String(describing: greyBefore)))")
        guard let two = editTry("replace cat", { try TextRewriter.replaceAll("cat", with: "elephant", options: FindReplaceOptions(wholeWords: true), page: p) }) else { return }
        check(two.replaced == 1, "the longer word is replaced by reflowing its block: \(two)")
        if let saved2 = try? back.data() {
            check(editText(saved2).contains("The color of the elephant is grey."), "reflowed text: \(editText(saved2))")
            _ = editRender(saved2, name: "find-replace")
        }
        // Case and whole words.
        let none = try? TextRewriter.replaceAll("COLOR", with: "x", options: FindReplaceOptions(matchCase: true), page: p)
        check(none?.replaced == 0, "match case respected")
    }
}

@MainActor
private func editAddText() {
    let data = EditFixture.letterPage()
    guard let model = editTry("open", { try PDFModel(data: data) }), let page = model.page(at: 0) else { return }
    guard let bounds = editTry("add", { try TextRewriter.addTextBox("A new note added by hand, wrapped to a narrow box.", at: CGPoint(x: 350, y: 300), width: 120,
                                                                      font: NSFont(name: "Georgia", size: 12)!, size: 12, color: "#0000FF", page: page) }) else { return }
    check(bounds.minX >= 349 && bounds.maxX <= 472 && bounds.height > 30, "the box wraps inside 120 pt: \(bounds)")
    guard let saved = editTry("save", { try model.data() }) else { return }
    check(editText(saved).contains("A new note added by") && editText(saved).contains("narrow box."), "new text extracts: \(editText(saved))")
    if let image = editRender(saved, name: "add-text") {
        let colour = editColor(image, in: CGRect(x: 350, y: 290, width: 60, height: 12), pageHeight: 792)
        check(colour.b > colour.r + 0.05, "blue text: \(colour)")
    }
    // Helvetica goes in by name (no embedding).
    editTry("add standard") { try TextRewriter.addTextBox("Plain", at: CGPoint(x: 72, y: 100), width: 200, font: NSFont(name: "Helvetica", size: 10)!, size: 10, color: "#000000", page: page) }
    let fonts = page.resources?["Font"]?.keys ?? []
    let standard = fonts.compactMap { page.resources?["Font"]?[$0] }.contains { $0["BaseFont"]?.name == "Helvetica" && $0["Subtype"]?.name == "Type1" }
    check(standard, "Helvetica is referenced by name: \(fonts)")
}

// MARK: - Images

@MainActor
private func editImages() {
    let data = EditFixture.letterPage(image: EditFixture.image())
    guard let model = editTry("open", { try PDFModel(data: data) }), let page = model.page(at: 0),
          let content = editTry("read", { try ContentInterpreter.read(page) }), let picture = content.images.first else { return check(false, "picture") }
    // Move and resize: the red block lands in the new box, the old place is white.
    editTry("place") { try ImageEditor.place(picture, in: CGRect(x: 72, y: 150, width: 300, height: 100), page: page, content: content) }
    guard let moved = editTry("save", { try model.data() }), let image = editRender(moved, name: "image-moved") else { return }
    let there = editColor(image, in: CGRect(x: 100, y: 170, width: 200, height: 60), pageHeight: 792)
    let before = editColor(image, in: CGRect(x: 420, y: 420, width: 100, height: 60), pageHeight: 792)
    check(there.r > 0.7 && there.g < 0.3, "red where the picture went: \(there)")
    check(before.r > 0.95 && before.g > 0.95, "white where it was: \(before)")
    check(editText(moved).contains("Project update"), "the text is untouched")
    // Read back: the picture's new bounds; then flip, rotate, crop, replace and delete.
    guard let back = editTry("reopen", { try PDFModel(data: moved) }), let p2 = back.page(at: 0), let c2 = editTry("read 2", { try ContentInterpreter.read(p2) }),
          let moved2 = c2.images.first else { return }
    let target = CGRect(x: 72, y: 150, width: 300, height: 100)
    check(abs(moved2.bounds.minX - target.minX) < 0.01 && abs(moved2.bounds.minY - target.minY) < 0.01 && abs(moved2.bounds.width - target.width) < 0.01
          && abs(moved2.bounds.height - target.height) < 0.01, "bounds after the move: \(moved2.bounds)")
    editTry("rotate") { try ImageEditor.rotate(moved2, by: 90, page: p2, content: c2) }
    if let rotated = try? back.data(), let p3 = back.page(at: 0), let c3 = try? ContentInterpreter.read(p3), let r = c3.images.first {
        check(abs(r.bounds.width - 100) < 0.5 && abs(r.bounds.height - 300) < 0.5 && abs(r.bounds.midX - 222) < 0.5, "rotated about its centre: \(r.bounds)")
        _ = editRender(rotated, name: "image-rotated")
        editTry("crop") { try ImageEditor.crop(r, to: CGRect(x: 0, y: 0, width: 0.5, height: 1), page: p3, content: c3) }
        editTry("flip") { if let c4 = try? ContentInterpreter.read(p3), let i = c4.images.first { try ImageEditor.flip(i, horizontally: true, page: p3, content: c4) } }
        check((try? back.data()) != nil, "crop and flip write")
    }
    // Replace with a blue picture, keeping the box; then delete.
    let blueFile = scratch.appendingPathComponent("edit-blue.png")
    try? FileManager.default.createDirectory(at: scratch, withIntermediateDirectories: true)
    if let png = try? ImageEncoder.encode(EditFixture.image(width: 80, height: 40, red: false), format: .png) { try? png.write(to: blueFile) }
    guard let m5 = editTry("reopen 5", { try PDFModel(data: moved) }), let p5 = m5.page(at: 0), let c5 = editTry("read 5", { try ContentInterpreter.read(p5) }), let i5 = c5.images.first else { return }
    editTry("replace") { try ImageEditor.replace(i5, with: blueFile, keepAspect: true, page: p5, content: c5) }
    if let replaced = try? m5.data(), let image = editRender(replaced, name: "image-replaced") {
        let colour = editColor(image, in: CGRect(x: 150, y: 170, width: 100, height: 60), pageHeight: 792)
        check(colour.b > 0.7 && colour.r < 0.3, "blue after replacing: \(colour)")
        if let p6 = m5.page(at: 0), let c6 = try? ContentInterpreter.read(p6), let i6 = c6.images.first {
            check(abs(i6.bounds.width / i6.bounds.height - 2) < 0.05, "the box follows the new picture's aspect: \(i6.bounds)")
            editTry("delete") { try ImageEditor.delete(i6, page: p6, content: c6) }
            if let deleted = try? m5.data(), let image = editRender(deleted, name: "image-deleted") {
                check(editColor(image, in: CGRect(x: 100, y: 160, width: 250, height: 80), pageHeight: 792).r > 0.95, "white after deleting")
                check(editText(deleted).contains("Project update"), "text still there")
            }
            if let exported = try? ImageEditor.export(i6, page: p6) { check(exported.data.count > 100, "export gives \(exported.type.identifier)") }
        }
    }
    // Add a picture.
    guard let m7 = editTry("reopen 7", { try PDFModel(data: data) }), let p7 = m7.page(at: 0) else { return }
    let box = editTry("add") { try ImageEditor.add(blueFile, in: CGRect(x: 72, y: 100, width: 200, height: 200), page: p7) }
    check(box.map { abs($0.width / $0.height - 2) < 0.05 && $0.width <= 200 } ?? false, "added inside the box, aspect kept: \(String(describing: box))")
    if let added = try? m7.data(), let image = editRender(added, name: "image-added"), let box {
        let colour = editColor(image, in: box.insetBy(dx: 10, dy: 10), pageHeight: 792)
        check(colour.b > 0.7, "the added picture renders blue: \(colour)")
    }
}

// MARK: - Decorations

private let editContext = DecorationContext(title: "Quarterly report", fileName: "Report.pdf", author: "Jane Doe", pageCount: 3,
                                            date: ISO8601DateFormatter().date(from: "2026-10-20T10:00:00Z")!)

@MainActor
private func editHeadersFooters() {
    let data = makePDF(pages: 3)
    guard let model = editTry("open", { try PDFModel(data: data) }) else { return }
    let header = HeaderFooter(fields: [
        .topLeft: [.title], .topRight: [.text("Page "), .pageNumber, .text(" of "), .pageCount],
        .bottomCenter: [.date], .bottomLeft: [.fileName], .bottomRight: [.author],
    ], style: DecorationStyle(fontName: "Helvetica", fontSize: 10, color: "#333333"), margins: 36, dateFormat: "d MMMM yyyy")
    check(DecorationLayout.render(header.fields[.topRight]!, pageIndex: 1, header: header, context: editContext) == "Page 2 of 3", "tokens render")
    check(DecorationLayout.render([.date], pageIndex: 0, header: header, context: editContext) == "20 October 2026", "date token with the ICU pattern")
    editTry("apply") { try DecorationWriter.apply(.headerFooter(header), to: [0, 1, 2], in: model, context: editContext) }
    check(DecorationWriter.kinds(in: model) == [.headerFooter], "the header is listed: \(DecorationWriter.kinds(in: model))")
    guard let saved = editTry("save", { try model.data() }) else { return }
    let page2 = editText(saved, page: 1)
    check(page2.contains("Quarterly report") && page2.contains("Page 2 of 3") && page2.contains("20 October 2026") && page2.contains("Report.pdf") && page2.contains("Jane Doe"),
          "every field extracts on page 2: \(page2)")
    check(editText(saved, page: 2).contains("Page 3 of 3") && editText(saved, page: 0).contains("Page 1"), "page numbers count")
    if let image = editRender(saved, page: 1, name: "header") {
        check(editInk(image, in: CGRect(x: 36, y: 740, width: 120, height: 20), pageHeight: 792) > 0.03, "header ink at the top left")
        check(editInk(image, in: CGRect(x: 250, y: 30, width: 120, height: 20), pageHeight: 792) > 0.03, "footer ink at the bottom centre")
    }
    // Replace: the second apply after a remove leaves one set; remove takes it away.
    guard let back = editTry("reopen", { try PDFModel(data: saved) }) else { return }
    check((try? DecorationWriter.remove(.headerFooter, from: back)) == 15, "five fields × three pages removed")
    check(DecorationWriter.kinds(in: back).isEmpty, "nothing left")
    if let clean = try? back.data() { check(!editText(clean, page: 1).contains("Page 2 of 3") && !editText(clean, page: 1).contains("Jane"), "removed from the text: \(editText(clean, page: 1))") }
    // Shrink page: the content scales down and the header has room.
    guard let m2 = editTry("open 2", { try PDFModel(data: EditFixture.letterPage()) }) else { return }
    var shrinking = header
    shrinking.shrinkPage = true
    editTry("apply shrink") { try DecorationWriter.apply(.headerFooter(shrinking), to: [0], in: m2, context: editContext) }
    if let shrunk = try? m2.data(), let image = editRender(shrunk, name: "header-shrunk") {
        check(m2.page(at: 0)?.object[DecorationWriter.shrinkKey]?.number.map { $0 < 1 && $0 > 0.8 } == true, "a scale was recorded")
        check(editInk(image, in: CGRect(x: 72, y: 714, width: 100, height: 20), pageHeight: 792) < 0.01, "the heading moved down out of the header band")
        check(editText(shrunk).contains("Project update"), "content still extracts")
        editTry("remove shrunk") { try DecorationWriter.remove(.headerFooter, from: m2) }
        check(m2.page(at: 0)?.object[DecorationWriter.shrinkKey] == nil, "removing the header un-shrinks")
    }
    // Other fonts embed (Georgia) and non-WinAnsi text falls back.
    guard let m3 = editTry("open 3", { try PDFModel(data: makePDF(pages: 1)) }) else { return }
    let fancy = HeaderFooter(fields: [.topCenter: [.text("Ωmega — Georgia")]], style: DecorationStyle(fontName: "Georgia", fontSize: 12))
    editTry("apply georgia") { try DecorationWriter.apply(.headerFooter(fancy), to: [0], in: m3, context: editContext) }
    if let fancySaved = try? m3.data() { check(editText(fancySaved).contains("Ωmega — Georgia"), "an embedded Georgia header extracts: \(editText(fancySaved))") }
}

@MainActor
private func editPageNumbers() {
    guard let model = editTry("open", { try PDFModel(data: makePDF(pages: 4)) }) else { return }
    let numbering = PageNumbering(position: .bottomCenter, style: .pageOfTotal, startAt: 1, skipFirst: 1)
    let context = DecorationContext(pageCount: 4)
    editTry("apply") { try DecorationWriter.apply(.pageNumbers(numbering), to: [0, 1, 2, 3], in: model, context: context) }
    guard let saved = editTry("save", { try model.data() }) else { return }
    check(!editText(saved, page: 0).contains("Page 1 of"), "the cover is skipped")
    check(editText(saved, page: 1).contains("Page 1 of 3") && editText(saved, page: 3).contains("Page 3 of 3"), "numbers from the second page: \(editText(saved, page: 1))")
    check(PageNumberStyle.roman.text(4, of: 9) == "iv" && PageNumberStyle.dashed.text(2, of: 9) == "– 2 –", "styles")
    _ = editRender(saved, page: 1, name: "page-numbers")
    guard let back = editTry("reopen", { try PDFModel(data: saved) }) else { return }
    check(DecorationWriter.kinds(in: back) == [.pageNumbers], "listed as page numbers")
    editTry("replace") {
        try DecorationWriter.remove(.pageNumbers, from: back)
        try DecorationWriter.apply(.pageNumbers(PageNumbering(position: .topRight, style: .roman)), to: [0, 1, 2, 3], in: back, context: context)
    }
    if let replaced = try? back.data() { check(editText(replaced, page: 3).contains("iv") && !editText(replaced, page: 3).contains("Page 3"), "replaced with roman at the top right") }
}

@MainActor
private func editBates() {
    let bates = BatesNumbering(prefix: "ABC", suffix: "-X", start: 1, digits: 6, position: .bottomRight)
    check(bates.label(42) == "ABC000042-X", "label")
    guard let first = editTry("open", { try PDFModel(data: makePDF(pages: 3)) }) else { return }
    editTry("apply") { try DecorationWriter.apply(.bates(bates), to: [0, 1, 2], in: first, context: DecorationContext(pageCount: 3)) }
    guard let saved = editTry("save", { try first.data() }) else { return }
    check(editText(saved, page: 0).contains("ABC000001-X") && editText(saved, page: 2).contains("ABC000003-X"), "numbered across the file")
    // Continuation across files: the next file starts where this one stopped.
    let next = BatesContinuation.next(after: bates, pages: 3)
    check(next.start == 4, "the next file starts at 4")
    guard let second = editTry("open 2", { try PDFModel(data: makePDF(pages: 2)) }) else { return }
    editTry("apply 2") { try DecorationWriter.apply(.bates(next), to: [0, 1], in: second, context: DecorationContext(pageCount: 2)) }
    if let saved2 = try? second.data() {
        check(editText(saved2, page: 0).contains("ABC000004-X") && editText(saved2, page: 1).contains("ABC000005-X"), "continued in the second file: \(editText(saved2, page: 1))")
        _ = editRender(saved2, page: 1, name: "bates")
    }
    // The Bates token of a header follows the numbering in force.
    let header = HeaderFooter(fields: [.topLeft: [.text("Exhibit "), .batesNumber]])
    check(DecorationLayout.render(header.fields[.topLeft]!, pageIndex: 1, header: header, context: DecorationContext(pageCount: 3, bates: bates)) == "Exhibit ABC000002-X", "Bates token")
}

@MainActor
private func editWatermark() {
    let data = EditFixture.letterPage()
    guard let model = editTry("open", { try PDFModel(data: data) }) else { return }
    let watermark = Watermark(content: .text("DRAFT", DecorationStyle(fontName: "Helvetica-Bold", fontSize: 48, color: "#FF0000")), opacity: 0.3, rotation: 45, position: .center, scale: 0.6)
    editTry("apply") { try DecorationWriter.apply(.watermark(watermark), to: [0], in: model, context: editContext) }
    guard let saved = editTry("save", { try model.data() }) else { return }
    check(editText(saved).contains("DRAFT") && editText(saved).contains("Project update"), "the watermark extracts with the page: \(editText(saved).prefix(80))")
    if let image = editRender(saved, name: "watermark") {
        let centre = editColor(image, in: CGRect(x: 290, y: 380, width: 30, height: 30), pageHeight: 792)
        check(centre.r > centre.g + 0.03 || centre.r > centre.b + 0.03, "a reddish tint at the page centre: \(centre)")
    }
    guard let back = editTry("reopen", { try PDFModel(data: saved) }) else { return }
    check(DecorationWriter.kinds(in: back) == [.watermark], "listed")
    check((try? DecorationWriter.remove(.watermark, from: back)) == 1, "removed one")
    if let clean = try? back.data() {
        check(!editText(clean).contains("DRAFT") && editText(clean).contains("Project update"), "watermark gone, page intact")
        check(clean.count < saved.count, "the form and font went with it (\(clean.count) < \(saved.count))")
    }
    // A picture watermark behind the content, print-only (an optional content group), on several pages.
    let pictureFile = scratch.appendingPathComponent("edit-wm.png")
    try? FileManager.default.createDirectory(at: scratch, withIntermediateDirectories: true)
    if let png = try? ImageEncoder.encode(EditFixture.image(width: 100, height: 50), format: .png) { try? png.write(to: pictureFile) }
    guard let m2 = editTry("open 2", { try PDFModel(data: makePDF(pages: 2)) }) else { return }
    let picture = Watermark(content: .file(pictureFile), opacity: 0.5, rotation: 0, position: .bottomLeft, scale: 0.3, layer: .behind, visibility: .printOnly)
    editTry("apply picture") { try DecorationWriter.apply(.watermark(picture), to: [0, 1], in: m2, context: editContext) }
    check(m2.root["OCProperties"]?["OCGs"]?.count == 1 && m2.root["OCProperties"]?["D"]?["OFF"]?.count == 1, "one print-only group, off on screen")
    check(OptionalContent.layers(in: m2).map(\.name) == ["Watermark (print only)"] && OptionalContent.layers(in: m2)[0].isVisible == false, "listed as a layer")
    let forms = m2.page(at: 0)?.resources?["XObject"]?.keys ?? []
    let shared = forms.compactMap { m2.page(at: 0)?.resources?["XObject"]?[$0]?.objectID } == (m2.page(at: 1)?.resources?["XObject"]?.keys ?? []).compactMap { m2.page(at: 1)?.resources?["XObject"]?[$0]?.objectID }
    check(shared, "the picture form is shared between pages")
    if let saved2 = try? m2.data(), let image = editRender(saved2, page: 0, name: "watermark-picture") {
        let corner = editColor(image, in: CGRect(x: 40, y: 40, width: 100, height: 40), pageHeight: 792)
        check(corner.r > 0.95 && corner.g > 0.95, "print-only: nothing shows on screen (\(corner))")
        check((try? PDFModel(data: saved2)).map { DecorationWriter.kinds(in: $0) } == [.watermark], "listed after save")
    }
    // A colour background on a page, and a PDF-page watermark over it.
    guard let m3 = editTry("open 3", { try PDFModel(data: makePDF(pages: 1)) }) else { return }
    editTry("background") { try DecorationWriter.apply(.background(Watermark(content: .color("#FFF2CC"), opacity: 1)), to: [0], in: m3, context: editContext) }
    let stampFile = scratch.appendingPathComponent("edit-stamp-source.pdf")
    try? EditFixture.standardFontPage(lines: [("LOGO", CGPoint(x: 10, y: 10))], size: CGSize(width: 100, height: 40)).write(to: stampFile)
    editTry("pdf watermark") { try DecorationWriter.apply(.watermark(Watermark(content: .file(stampFile), opacity: 1, rotation: 0, position: .topRight, scale: 0.25)), to: [0], in: m3, context: editContext) }
    if let saved3 = try? m3.data(), let image = editRender(saved3, name: "background") {
        let colour = editColor(image, in: CGRect(x: 300, y: 300, width: 50, height: 50), pageHeight: 792)
        check(colour.b < 0.9 && colour.r > 0.95, "the yellow background shows: \(colour)")
        check(editText(saved3).contains("Page 1") && editText(saved3).contains("LOGO"), "text over the background, and the PDF watermark's text: \(editText(saved3))")
        check(Set(DecorationWriter.kinds(in: m3)) == [.watermark, .background], "both listed")
    }
}

// MARK: - Stamps, scripts, properties, transitions, destinations, layers

@MainActor
private func editStamps() {
    guard let model = editTry("open", { try PDFModel(data: makePDF(pages: 1)) }), let page = model.page(at: 0) else { return }
    let design = StampDesign.standard.first { $0.id == "approved-by" }!
    check(design.rendered(name: "Jane", date: editContext.date).hasPrefix("APPROVED by Jane "), "dynamic stamp text")
    let size = StampWriter.naturalSize(design, name: "Jane")
    let rect = CGRect(x: 200, y: 400, width: size.width, height: size.height)
    editTry("add") { try StampWriter.add(design, name: "Jane", in: rect, rotation: 0, opacity: 1, page: page) }
    editTry("add rotated") { try StampWriter.add(StampDesign.standard[1], name: "Jane", in: CGRect(x: 100, y: 100, width: 120, height: 50), rotation: 20, opacity: 0.8, page: page) }
    guard let saved = editTry("save", { try model.data() }), let document = PDFDocument(data: saved), let pdfPage = document.page(at: 0) else { return }
    let stamps = pdfPage.annotations.filter { $0.type == "Stamp" }
    check(stamps.count == 2, "two stamp annotations in PDFKit")
    check(stamps.first?.contents?.hasPrefix("APPROVED by Jane") == true, "contents carry the words")
    // Quartz draws page content only; annotations show through PDFKit, as in the window.
    if let image = editRenderWithAnnotations(saved, name: "stamps") {
        let colour = editColor(image, in: rect.insetBy(dx: 4, dy: 4), pageHeight: 792)
        check(colour.g > colour.r + 0.02, "a green stamp at its rect: \(colour)")
        check(editInk(image, in: CGRect(x: 100, y: 100, width: 120, height: 50), pageHeight: 792) > 0.02 || editColor(image, in: CGRect(x: 100, y: 100, width: 120, height: 50), pageHeight: 792).g < 0.95, "the rotated red stamp draws")
    }
}

@MainActor
private func editScripts() {
    guard let model = editTry("open", { try PDFModel(data: makePDF(pages: 2)) }) else { return }
    check(ScriptScanner.scripts(in: model).isEmpty, "a plain file has no scripts")
    // Plant scripts everywhere they can live.
    let js = model.makeIndirect(.dictionary(["S": .name("JavaScript"), "JS": .text("app.alert('hi');")]))
    model.root.set("OpenAction", js)
    model.root.dictionary("Names").set("JavaScript", PDFNameTree.make(in: model, entries: [(Data("init".utf8), model.make(.dictionary(["S": .name("JavaScript"), "JS": .text("var x = 1;\nvar y;")])))]))
    model.page(at: 1)?.object.set("AA", .dictionary(["O": .dictionary(["S": .name("JavaScript"), "JS": .text("page()")])]))
    let link = model.makeIndirect(.dictionary(["Type": .name("Annot"), "Subtype": .name("Link"), "Rect": .rect(CGRect(x: 0, y: 0, width: 10, height: 10)),
                                               "A": .dictionary(["S": .name("URI"), "URI": .ascii("https://example.com"), "Next": .dictionary(["S": .name("JavaScript"), "JS": .text("chain()")])])]))
    model.page(at: 0)?.addAnnotation(link)
    let field = model.makeIndirect(.dictionary(["FT": .name("Tx"), "T": .text("total"), "AA": .dictionary(["C": .dictionary(["S": .name("JavaScript"), "JS": .text("AFSimple_Calculate()")])])]))
    model.ensureAcroForm().array("Fields").append(field)
    let found = ScriptScanner.scripts(in: model)
    check(found.count == 5, "five scripts found: \(found.map(\.description))")
    check(found.contains { $0.description == "Document script “init”" && $0.excerpt == "var x = 1;" }, "the name tree script with its first line")
    check(found.contains { $0.description == "Page 2: runs on open" } && found.contains { $0.description == "Form field “total”: runs on calculation" }, "places in plain words: \(found.map(\.description))")
    check(ScriptScanner.removeScripts(from: model) == 5, "removed five")
    check(ScriptScanner.scripts(in: model).isEmpty && model.root["OpenAction"] == nil && model.root["Names"]?["JavaScript"] == nil, "all gone")
    check(model.page(at: 0)?.annotations.first?["A"] == nil, "the link's chained script went with its action")
    if let saved = try? model.data() { check(PDFDocument(data: saved)?.pageCount == 2, "the file still opens") }
}

@MainActor
private func editProperties() {
    guard let model = editTry("open", { try PDFModel(data: makePDF(pages: 3)) }) else { return }
    var properties = DocumentProperties.read(from: model)
    check(properties.title.isEmpty && properties.initialView == InitialView(), "a plain file: no title, default view")
    properties.title = "Lease agreement"
    properties.author = "Jane Doe"
    properties.keywords = "lease, flat"
    properties.custom["Department"] = "Legal"
    properties.initialView = InitialView(page: 2, zoom: .fitWidth, layout: .twoPages, sidebar: .thumbnails)
    properties.write(to: model)
    guard let saved = editTry("save", { try model.data() }), let document = PDFDocument(data: saved) else { return }
    check(document.documentAttributes?[PDFDocumentAttribute.titleAttribute] as? String == "Lease agreement", "PDFKit reads the title")
    check(document.documentAttributes?[PDFDocumentAttribute.authorAttribute] as? String == "Jane Doe", "and the author")
    guard let back = editTry("reopen", { try PDFModel(data: saved) }) else { return }
    let read = DocumentProperties.read(from: back)
    check(read == properties, "properties round-trip: \(read)")
    check(back.root["OpenAction"]?[1]?.name == "FitH" && back.root["PageLayout"]?.name == "TwoColumnLeft" && back.root["PageMode"]?.name == "UseThumbs", "initial view written")
    var reset = read
    reset.initialView = InitialView()
    reset.custom = [:]
    reset.write(to: back)
    check(back.root["OpenAction"] == nil && back.trailer["Info"]?["Department"] == nil, "defaults remove the entries")
}

@MainActor
private func editTransitionsAndDestinations() {
    guard let model = editTry("open", { try PDFModel(data: makePDF(pages: 3)) }) else { return }
    PageTransition.write(PageTransition(style: .wipe, duration: 2, advanceAfter: 5), to: [0, 1], in: model)
    check(PageTransition.read(from: model.page(at: 0)!) == PageTransition(style: .wipe, duration: 2, advanceAfter: 5), "transition round-trips")
    check(PageTransition.read(from: model.page(at: 2)!) == nil, "page 3 has none")
    PageTransition.write(nil, to: [0], in: model)
    check(model.page(at: 0)?.object["Trans"] == nil && model.page(at: 0)?.object["Dur"] == nil, "removed")

    check(NamedDestinations.read(from: model).isEmpty, "no destinations yet")
    NamedDestinations.set(NamedDestination(name: "chapter2", destination: PDFDestination(page: 1, view: .fit)), in: model)
    NamedDestinations.set(NamedDestination(name: "appendix", destination: PDFDestination(page: 2, view: .xyz(left: 0, top: 700, zoom: nil))), in: model)
    var dests = NamedDestinations.read(from: model)
    check(dests.map(\.name) == ["appendix", "chapter2"] && dests[1].destination.page == 1, "destinations written and sorted: \(dests)")
    // A link using the name follows a rename.
    let link = model.makeIndirect(.dictionary(["Type": .name("Annot"), "Subtype": .name("Link"), "Rect": .rect(CGRect(x: 0, y: 0, width: 10, height: 10)), "Dest": .text("chapter2")]))
    model.page(at: 0)?.addAnnotation(link)
    NamedDestinations.rename("chapter2", to: "part2", in: model)
    dests = NamedDestinations.read(from: model)
    check(dests.map(\.name) == ["appendix", "part2"] && model.page(at: 0)?.annotations.first?["Dest"]?.text == "part2", "rename updates the link")
    NamedDestinations.remove("appendix", from: model)
    guard let saved = editTry("save", { try model.data() }), let back = try? PDFModel(data: saved) else { return }
    check(NamedDestinations.read(from: back).map(\.name) == ["part2"], "saved and read back")
    // The old-style /Dests dictionary is read too.
    back.root.set("Dests", .dictionary(["old": .array([back.page(at: 2)!.object.reference!, .name("Fit")])]))
    check(NamedDestinations.read(from: back).map(\.name) == ["old", "part2"], "PDF 1.1 destinations read")
    // PDFKit resolves the link to its page after the rename.
    if let document = PDFDocument(data: saved), let annotation = document.page(at: 0)?.annotations.first {
        check(annotation.destination?.page.map { document.index(for: $0) } == 1 || (annotation.action as? PDFActionGoTo)?.destination.page.map { document.index(for: $0) } == 1,
              "PDFKit follows the renamed destination")
    }
}

@MainActor
private func editLayers() {
    guard let model = editTry("open", { try PDFModel(data: makePDF(pages: 1)) }), let page = model.page(at: 0) else { return }
    // Two layers: "Notes" (hidden) with its own text, "Marks" (shown) with an XObject.
    let notes = model.makeIndirect(.dictionary(["Type": .name("OCG"), "Name": .text("Notes")]))
    let marks = model.makeIndirect(.dictionary(["Type": .name("OCG"), "Name": .text("Marks")]))
    model.root.set("OCProperties", .dictionary(["OCGs": .array([notes.reference!, marks.reference!]), "D": .dictionary(["Order": .array([notes.reference!, marks.reference!]), "OFF": .array([notes.reference!])])]))
    page.ownResources().dictionary("Properties").set("oc1", notes)
    let (font, fontName) = FontEmbedder.standardFont("Helvetica", on: page)
    let bytes = font.encode("Hidden note")!
    let hex = bytes.map { String(format: "%02X", $0) }.joined()
    let form = model.makeStream(["Type": .name("XObject"), "Subtype": .name("Form"), "BBox": .rect(CGRect(x: 0, y: 0, width: 50, height: 50)), "OC": marks.reference!], data: Data("0 0 1 rg 0 0 50 50 re f".utf8))
    let formName = page.addResource(form, category: "XObject", prefix: "Fx")
    page.addContent(Data("/OC /oc1 BDC BT /\(fontName) 14 Tf 1 0 0 1 72 300 Tm <\(hex)> Tj ET EMC q 1 0 0 1 400 300 cm /\(formName) Do Q".utf8))
    let layers = OptionalContent.layers(in: model)
    check(layers.map(\.name) == ["Notes", "Marks"] && layers.map(\.isVisible) == [false, true], "layers listed with their state: \(layers)")
    // The interpreter reports hidden text as not editable and the form's image as on a layer.
    if let content = try? ContentInterpreter.read(page, hiddenLayers: OptionalContent.hiddenLayers(in: model)) {
        check(content.runs.contains { $0.text == "Hidden note" && $0.inForm }, "hidden-layer text is read but not editable")
    }
    OptionalContent.setVisible(true, layer: layers[0].id, in: model)
    check(OptionalContent.layers(in: model)[0].isVisible, "shown again")
    OptionalContent.setVisible(false, layer: layers[0].id, in: model)
    editTry("flatten") { try OptionalContent.flatten(model) }
    guard let saved = editTry("save", { try model.data() }) else { return }
    check(!editText(saved).contains("Hidden note") && editText(saved).contains("Page 1"), "hidden content is gone, the page stays: \(editText(saved))")
    check(model.root["OCProperties"] == nil && OptionalContent.layers(in: model).isEmpty, "no layers left")
    if let image = editRender(saved, name: "layers") {
        check(editColor(image, in: CGRect(x: 405, y: 305, width: 40, height: 40), pageHeight: 792).b > 0.8, "the shown layer's form still draws")
    }
}

// MARK: - The service, the mode session, the panels and the document interaction

/// A document opened from a file, as DocumentKit opens one (its snapshot is the file until it is edited).
@MainActor
private func editOpened(_ data: Data, name: String) -> DocumentHandle {
    let url = scratch.appendingPathComponent("edit-opened-\(UUID().uuidString)/\(name).pdf")
    SuperPDFPaths.ensure(url.deletingLastPathComponent())
    try? data.write(to: url)
    return DocumentHandle(url: url, pdf: PDFDocument(url: url)!, undoManager: makeUndoManager())
}

/// The bytes an in-place result carries, applied to the handle the way DocumentKit does (the fake only records): the
/// window shows them and they are the document's contents.
@MainActor
private func editApply(_ group: UndoGroup, to document: DocumentHandle) -> Bool {
    guard case .contents(_, let after) = group.change, let pdf = PDFDocument(data: after) else { return false }
    document.pdf = pdf
    document.state.isEdited = true
    DocumentBaseline.attach(after, to: document)
    return true
}

@MainActor
private func editService() {
    installFakes()
    EditKitModule.install()
    guard let service = Services.edit as? EditService else { return check(false, "EditKitModule registers EditService") }
    let document = makeDocument(pages: 3)
    document.pdf.documentAttributes = [PDFDocumentAttribute.titleAttribute: "Quarterly report"]
    document.state.isEdited = true
    let header = HeaderFooter(fields: [.topLeft: [.title], .bottomRight: [.text("Page "), .pageNumber, .text(" of "), .pageCount]])
    guard let group = (complete { try await service.apply(.headerFooter(header), to: [0, 1, 2], in: document, replacing: true) }).flatMap({ try? $0.get() }) else {
        return check(false, "apply returns a group")
    }
    check(group.actionName == "Add Headers & Footers", "undo name")
    guard case .contents(let before, let after) = group.change else { return check(false, "a contents group") }
    check(PDFDocument(data: before)?.pageCount == 3, "before is the document's bytes")
    check(editText(after, page: 2).contains("Page 3 of 3") && editText(after, page: 0).contains("Quarterly report"), "the title token took the document's title: \(editText(after, page: 0))")
    check(service.decorations(in: document).isEmpty, "nothing on the handle until the bytes are applied")
    check(editApply(group, to: document), "applied")
    check(service.decorations(in: document) == [.headerFooter], "the header is listed from the new bytes")
    // The snapshot is EditKit's bytes as they are, and a change made through PDFKit goes into them without redrawing
    // the pages, so the tags stay.
    if case .data(let bytes, _) = EditSource.source(for: document) { check(bytes == after, "EditKit's saved bytes are the source") }
    if let page = document.pdf.page(at: 1) {
        let note = PDFAnnotation(bounds: CGRect(x: 100, y: 100, width: 20, height: 20), forType: .text, withProperties: nil)
        page.addAnnotation(note)
        check(service.decorations(in: document) == [.headerFooter], "a change made through PDFKit keeps EditKit's tags")
        page.removeAnnotation(note)
        if case .data(let bytes, _) = EditSource.source(for: document) { check(bytes == after, "back as saved: the saved bytes again") }
    }
    // Replacing keeps one set; removing takes it away.
    let again = (complete { try await service.apply(.headerFooter(header), to: [0], in: document, replacing: true) }).flatMap { try? $0.get() }
    if let again, case .contents(_, let twice) = again.change {
        check(editText(twice, page: 0).components(separatedBy: "Quarterly report").count == 2, "one header after replacing")
        check(!editText(twice, page: 2).contains("Page 3 of 3"), "replacing on one page removes the others")
    }
    let removal = (complete { try await service.remove(.headerFooter, from: document) }).flatMap { try? $0.get() }
    if let removal, case .contents(_, let clean) = removal.change {
        check(!editText(clean, page: 0).contains("Quarterly report"), "removed")
        check(removal.actionName == "Remove Headers & Footers", "removal undo name")
    } else { check(false, "removal returns contents") }
    // Find & replace through the service.
    let replaceDocument = DocumentHandle(url: nil, displayName: "Memo", pdf: PDFDocument(data: EditFixture.standardFontPage(lines: [("Grey cat, grey dog.", CGPoint(x: 72, y: 700))]))!, undoManager: makeUndoManager())
    let replaced = (complete { try await service.replaceText("grey", with: "red", options: FindReplaceOptions(), pages: [0], in: replaceDocument) }).flatMap { try? $0.get() }
    check(replaced?.report.replaced == 2 && replaced?.report.notFitting == 0, "two replaced: \(String(describing: replaced?.report))")
    if let undo = replaced?.undo, case .contents(_, let data) = undo.change { check(editText(data).contains("red cat, red dog."), "text after: \(editText(data))") }
    // Scripts.
    let model = PDFModel()
    _ = try? model.addBlankPage(size: EditFixture.letter)
    model.root.set("OpenAction", .dictionary(["S": .name("JavaScript"), "JS": .text("app.alert(1)")]))
    let scripted = editOpened(try! model.data(), name: "Scripted")
    let scripts = (complete { try await service.scripts(in: scripted) }).flatMap { try? $0.get() }
    check(scripts == ["Runs when the file opens"], "scripts listed: \(String(describing: scripts))")
    let cleaned = (complete { try await service.removeScripts(from: scripted) }).flatMap { try? $0.get() }
    if let cleaned { check(editApply(cleaned, to: scripted) && (complete { try await service.scripts(in: scripted) }).flatMap({ try? $0.get() })?.isEmpty == true, "scripts removed") }
    installFakes()
}

@MainActor
private func editModeSession() {
    installFakes()
    EditKitModule.install()
    let document = DocumentHandle(url: nil, displayName: "Letter", pdf: PDFDocument(data: EditFixture.letterPage(image: EditFixture.image()))!, undoManager: makeUndoManager())
    let session = EditModeSession(document: document)
    var applied: [UndoGroup] = []
    session.apply = { group in applied.append(group); _ = editApply(group, to: document) }
    var changes = 0
    session.onChange = { changes += 1 }

    // Clicks select paragraphs and pictures; empty space clears.
    guard let text = session.pageText(0), let p1 = text.blocks.first(where: { $0.text.hasPrefix("The quick") }) else { return check(false, "page text") }
    let selection = complete { await session.click(page: 0, at: CGPoint(x: 100, y: p1.bounds.midY)) }
    check((try? selection?.get()) == .block(page: 0, id: p1.id) && session.block()?.text == p1.text, "a click selects the paragraph")
    _ = complete { await session.click(page: 0, at: CGPoint(x: 450, y: 450)) }
    check(session.image()?.bounds.integral == CGRect(x: 400, y: 400, width: 150, height: 100), "a click selects the picture")
    _ = complete { await session.click(page: 0, at: CGPoint(x: 300, y: 80)) }
    check(session.selection == nil && changes >= 3, "empty space clears")

    // Retype with a pending style: size and colour change, the edit is one undo step, the block stays selected.
    _ = complete { await session.click(page: 0, at: CGPoint(x: 100, y: p1.bounds.midY)) }
    session.pendingStyle = EditModeSession.Style(size: 14, color: "#FF0000")
    _ = complete { try await session.commitText("Retyped at fourteen points in red, which wraps to a few lines in the same box.") }
    check(applied.count == 1 && applied.first?.actionName == "Edit Text", "one undo step named Edit Text")
    check((document.pdf.page(at: 0)?.string ?? "").contains("Retyped at fourteen"), "the document shows the new text")
    check(session.block()?.text.hasPrefix("Retyped") == true && abs((session.block()?.style.pageFontSize ?? 0) - 14) < 0.1 && session.block()?.style.colorHex == "#FF0000",
          "the retyped block is selected again at 14 pt red: \(String(describing: session.block()?.style.pageFontSize)) \(String(describing: session.block()?.style.colorHex))")
    check(session.pendingStyle.isEmpty, "pending style cleared after the commit")
    // Delete the block.
    _ = complete { try await session.deleteSelection() }
    check(applied.count == 2 && applied.last?.actionName == "Delete Text" && !(document.pdf.page(at: 0)?.string ?? "").contains("Retyped"), "deleted")
    check(session.selection == nil, "nothing selected after deleting")

    // Pictures: move, flip, rotate, delete.
    _ = complete { await session.click(page: 0, at: CGPoint(x: 450, y: 450)) }
    _ = complete { try await session.moveImage(to: CGRect(x: 100, y: 100, width: 150, height: 100)) }
    check(applied.last?.actionName == "Move Picture" && session.image()?.bounds.integral == CGRect(x: 100, y: 100, width: 150, height: 100), "moved and still selected: \(String(describing: session.image()?.bounds))")
    _ = complete { try await session.moveImage(to: CGRect(x: 100, y: 100, width: 300, height: 200)) }
    check(applied.last?.actionName == "Resize Picture", "a size change is Resize Picture")
    _ = complete { try await session.rotateImage(by: 90) }
    check(applied.last?.actionName == "Rotate Picture" && session.image() != nil, "rotated, still selected")
    _ = complete { try await session.deleteSelection() }
    check(applied.last?.actionName == "Delete Picture" && session.pageText(0)?.content.images.isEmpty == true, "picture deleted")

    // Add text: the placeholder goes where the click is and is selected for typing; add picture places a file.
    session.tool = .addText
    _ = complete { await session.click(page: 0, at: CGPoint(x: 72, y: 300)) }
    check(session.tool == .select && session.block()?.text == "Type here", "a placeholder block is selected: \(String(describing: session.block()?.text))")
    check(abs((session.block()?.bounds.maxY ?? 0) - 300) < 3 && abs((session.block()?.bounds.minX ?? 0) - 72) < 1, "placed at the click: \(String(describing: session.block()?.bounds))")
    _ = complete { try await session.commitText("A fresh paragraph.") }
    check((document.pdf.page(at: 0)?.string ?? "").contains("A fresh paragraph.") && !(document.pdf.page(at: 0)?.string ?? "").contains("Type here"), "placeholder replaced")
    let pictureFile = scratch.appendingPathComponent("edit-session-picture.png")
    try? FileManager.default.createDirectory(at: scratch, withIntermediateDirectories: true)
    if let png = try? ImageEncoder.encode(EditFixture.image(width: 80, height: 40, red: false), format: .png) { try? png.write(to: pictureFile) }
    session.tool = .addImage
    session.pendingImage = pictureFile
    _ = complete { await session.click(page: 0, at: CGPoint(x: 300, y: 500)) }
    check(applied.last?.actionName == "Add Picture" && session.pageText(0)?.content.images.count == 1 && session.tool == .select, "picture added")
    // Find & replace through the session (the service is the real one).
    let report = complete { try await session.replaceAll("fresh", with: "new", options: FindReplaceOptions(), pages: [0]) }
    check((try? report?.get())?.replaced == 1 && (document.pdf.page(at: 0)?.string ?? "").contains("A new paragraph."), "replaced through the session")
    // Undo: the recorded groups swap back.
    if case .contents(let before, _) = applied.first!.change {
        document.pdf = PDFDocument(data: before)!
        check((document.pdf.page(at: 0)?.string ?? "").contains("The quick brown fox"), "the first group's before restores the original")
    }
    installFakes()
}

@MainActor
private func editPanels() {
    installFakes()
    EditKitModule.install()
    guard let provider = Services.toolProviders.compactMap({ $0 as? EditToolProvider }).first else { return check(false, "provider registered") }
    check(Set(provider.tools) == Set(ToolCatalog.tiles(ownedBy: .editKit).map(\.id)), "the provider serves EditKit's tiles")
    let documents = Services.documents as! FakeDocuments
    let folder = scratch.appendingPathComponent("edit-panels", isDirectory: true)
    SuperPDFPaths.ensure(folder)
    let url = folder.appendingPathComponent("Report.pdf")
    try? makePDF(pages: 3).write(to: url)
    let document = makeDocument(pages: 3, url: url)
    func lastApplied() -> UndoGroup? {
        guard case .inPlace(let group, _)? = documents.applied.last?.1 else { return nil }
        return group
    }

    // Headers & footers: the grid feeds the values through the action; the preview draws; the run is in place.
    let headers = ToolSession(tool: .headersAndFooters, provider: provider, document: document)
    check(headers.panel.archetype == .livePreview && !headers.canRun && headers.secondaryIsCancel, "empty: can't run yet, Cancel")
    guard case .custom(_, let make)? = headers.panel.controls.first else { return check(false, "the grid is the first control") }
    let grid = make() as? HeaderFieldsView
    check(grid != nil, "a HeaderFieldsView")
    let fields = HeaderFields(document: document, texts: ["{title}", "", "Page {page} of {pages}", "", "{date}", ""])
    check(HeaderFields.parse("Page {page} of {pages}") == [.text("Page "), .pageNumber, .text(" of "), .pageCount], "tokens parse")
    check(HeaderFields.text(of: HeaderFields.parse("A {date} B")) == "A {date} B", "tokens round-trip")
    provider.testSetHeaderFields(fields)
    _ = complete { await headers.perform(HeaderFields.changedAction) }
    check(headers.canRun && headers.values.strings("fields") == fields.texts, "fields reach the values")
    _ = complete { await headers.updatePreview() }
    if case .overlay = headers.preview {} else { check(false, "a live overlay") }
    headers.set("size", .int(12))
    let result = complete { await headers.run() }
    if case .success(.some(.inPlace(let group, nil)))? = result, case .contents(_, let after) = group.change {
        check(editText(after, page: 1).contains("Page 2 of 3") && editText(after, page: 1).contains("Report.pdf"), "run adds the fields (title falls back to the file name): \(editText(after, page: 1))")
        check(editApply(group, to: document), "applied to the handle")
    } else { check(false, "run returns an in-place contents group: \(String(describing: result))") }
    let headersAgain = ToolSession(tool: .headersAndFooters, provider: provider, document: document)
    check(!headersAgain.secondaryIsCancel && headersAgain.panel.secondary?.title == "Remove headers & footers", "Remove shows once ours exist")
    _ = complete { await headersAgain.perform(ToolPanel.secondaryAction) }
    check(documents.applied.last?.0 == .editTextAndImages || documents.applied.count >= 2, "removal applied through DocumentKit")
    if let group = lastApplied() { check(group.actionName == "Remove Headers & Footers" && editApply(group, to: document), "removed") }

    // Watermark: text by default, colour makes a background; the remove button names what is there.
    let watermark = ToolSession(tool: .watermark, provider: provider, document: document)
    check(watermark.values.string("text") == "DRAFT" && watermark.values.double("lightness") == 30 && watermark.panel.primary.title == "Add watermark", "defaults")
    watermark.set("angle", .string("custom"))
    check(watermark.panel.controls.contains { $0.id == "turn" }, "a custom angle shows the Turn slider")
    if let decoration = EditToolProvider.watermark(watermark.values), case .watermark(let w) = decoration { check(w.rotation == 30 && w.opacity == 0.3 && w.scale == 0.5, "values → watermark: \(w)") }
    if case .success(.some(.inPlace(let group, nil)))? = (complete { await watermark.run() }), case .contents(_, let after) = group.change {
        check(editText(after, page: 2).contains("DRAFT"), "the watermark is on every page")
        check(editApply(group, to: document), "applied")
    } else { check(false, "watermark run") }
    let background = ToolSession(tool: .watermark, provider: provider, document: document)
    check(background.panel.secondary?.title == "Remove watermark", "Remove watermark offered")
    background.set("kind", .string("colour"))
    check(background.panel.primary.title == "Add background" && background.panel.controls.contains { $0.id == "colour" }, "colour: Add background")
    if case .success(.some(.inPlace(let group, nil)))? = (complete { await background.run() }), case .contents(_, let after) = group.change {
        check(editApply(group, to: document) && (try? PDFModel(data: after)).map { DecorationWriter.kinds(in: $0) } == [.background], "a background replaces the watermark: \(String(describing: (try? PDFModel(data: after)).map { DecorationWriter.kinds(in: $0) }))")
    } else { check(false, "background run") }
    _ = complete { await ToolSession(tool: .watermark, provider: provider, document: document).perform(ToolPanel.secondaryAction) }
    if let group = lastApplied() { check(group.actionName == "Remove Background" && editApply(group, to: document), "background removed") }

    // Bates: the example line, the run, and carrying on in the next file.
    let bates = ToolSession(tool: .batesNumbering, provider: provider, document: document)
    bates.set("prefix", .string("ABC"))
    bates.set("start", .int(10))
    check(bates.panel.controls.contains { if case .note(let text) = $0 { return text == "First page: ABC000010" } else { return false } }, "example line")
    if case .success(.some(.inPlace(let group, nil)))? = (complete { await bates.run() }), case .contents(_, let after) = group.change {
        check(editText(after, page: 2).contains("ABC000012"), "numbered: \(editText(after, page: 2))")
    } else { check(false, "bates run") }
    let nextFile = ToolSession(tool: .batesNumbering, provider: provider, document: makeDocument(pages: 2))
    nextFile.set("prefix", .string("ABC"))
    nextFile.set("continueLast", .bool(true))
    check(provider.bates(nextFile.values).start == 13, "the next file carries on at 13 (\(provider.bates(nextFile.values).start))")
    check(nextFile.panel.controls.contains { if case .note(let text) = $0 { return text == "The next file would start at 13." } else { return false } }, "says so")

    // Stamps: on this page by default, every page on request.
    let stamps = ToolSession(tool: .stamps, provider: provider, document: document, currentPage: 1)
    check(stamps.values.strings("stamp") == ["approved"] && stamps.panel.primary.title == "Add stamp", "stamp defaults")
    _ = complete { await stamps.updatePreview() }
    if case .overlay = stamps.preview {} else { check(false, "stamp preview") }
    if case .success(.some(.inPlace(let group, nil)))? = (complete { await stamps.run() }), case .contents(_, let after) = group.change, let pdf = PDFDocument(data: after) {
        check(pdf.page(at: 1)?.annotations.filter { $0.type == "Stamp" }.count == 1 && pdf.page(at: 0)?.annotations.isEmpty == true, "one stamp on page 2")
        check(pdf.page(at: 1)?.annotations.first?.contents == "APPROVED", "the words")
    } else { check(false, "stamp run") }

    // Links: a drawn area and a web address; the detector links addresses in the text.
    let linked = DocumentHandle(url: nil, displayName: "Links", pdf: PDFDocument(data: EditFixture.standardFontPage(lines: [("See https://example.com/page for more", CGPoint(x: 72, y: 700))]))!, undoManager: makeUndoManager())
    let links = ToolSession(tool: .links, provider: provider, document: linked)
    check(!links.canRun, "no area yet")
    links.set("linkKind", .string("web"))
    links.set("url", .string("example.org/help"))
    provider.testSetLinkArea(page: 0, rect: CGRect(x: 72, y: 600, width: 200, height: 20), in: linked)
    _ = complete { await links.perform(LinkArea.changedAction) }
    check(links.canRun && links.panel.controls.contains { if case .note(let text) = $0 { return text.hasPrefix("Link area drawn on page 1") } else { return false } }, "area noted, can run")
    if case .success(.some(.inPlace(let group, nil)))? = (complete { await links.run() }) {
        let annotations = linked.pdf.page(at: 0)?.annotations ?? []
        check(annotations.count == 1 && (annotations.first?.action as? PDFActionURL)?.url?.absoluteString == "https://example.org/help", "a link annotation with https added: \(annotations)")
        group.undo()
        check(linked.pdf.page(at: 0)?.annotations.isEmpty == true, "undo removes it")
        group.redo()
    } else { check(false, "link run") }
    let detect = ToolSession(tool: .links, provider: provider, document: linked)
    _ = complete { await detect.perform("detect") }
    check(detect.panel.controls.contains { if case .note(let text) = $0 { return text == "Made 1 link." } else { return false } }, "detected one address")
    check(linked.pdf.page(at: 0)?.annotations.count == 2, "two links now")
    check(LinkTools.url(from: "not a url") == nil && LinkTools.url(from: "jane@example.com")?.scheme == "mailto", "address parsing")
    links.set("url", .string("nonsense"))
    check(!links.canRun, "a bad address disables the button")

    // Edit text & images: a mode panel with the header switch, strip for a selected block, find & replace, scripts.
    let scripted = PDFModel()
    _ = try? scripted.addBlankPage(size: EditFixture.letter)
    scripted.root.set("OpenAction", .dictionary(["S": .name("JavaScript"), "JS": .text("app.alert(1)")]))
    let editDocument = DocumentHandle(url: nil, displayName: "Letter", pdf: PDFDocument(data: EditFixture.letterPage())!, undoManager: makeUndoManager())
    let edit = ToolSession(tool: .editTextAndImages, provider: provider, document: editDocument)
    check(edit.panel.archetype == .mode && edit.layout.headerSwitch?.id == "tool" && edit.panel.primary.title == "Done" && edit.panel.secondary == nil, "D panel shape")
    let modeSession = provider.session(for: editDocument)
    modeSession.apply = { group in _ = editApply(group, to: editDocument) }
    guard let p1 = modeSession.pageText(0)?.blocks.first(where: { $0.text.hasPrefix("The quick") }) else { return check(false, "paragraph") }
    _ = complete { await modeSession.click(page: 0, at: CGPoint(x: 100, y: p1.bounds.midY)) }
    _ = complete { await edit.perform(EditToolProvider.Action.selectionChanged) }
    check(edit.panel.controls.contains { $0.id == "font" } && edit.values.string("font") == "Helvetica" && edit.values.int("size") == 11, "the strip shows the block's own look")
    edit.set("size", .int(16))
    edit.set("style", .strings(["bold"]))
    check(modeSession.pendingStyle == EditModeSession.Style(size: 16, bold: true), "strip changes become pending style: \(modeSession.pendingStyle)")
    _ = complete { try await modeSession.commitText("Bold and bigger now.") }
    check((editDocument.pdf.page(at: 0)?.string ?? "").contains("Bold and bigger now.") && modeSession.block()?.style.font.facts.isBold == true, "committed in bold")
    edit.set("tool", .string("find"))
    edit.set("find", .string("Please"))
    edit.set("replace", .string("Kindly"))
    _ = complete { await edit.perform(EditToolProvider.Action.replaceAll) }
    check(edit.panel.controls.contains { if case .note(let text) = $0 { return text == "Replaced 1 word." } else { return false } } && (editDocument.pdf.page(at: 0)?.string ?? "").contains("Kindly"), "find & replace from the panel: \(edit.panel.controls.compactMap { if case .note(let t) = $0 { t } else { nil } }) \(String(describing: edit.failure)) \(editDocument.pdf.page(at: 0)?.string ?? "")")
    let scriptedDocument = editOpened(try! scripted.data(), name: "Scripted")
    let editScripted = ToolSession(tool: .editTextAndImages, provider: provider, document: scriptedDocument)
    _ = complete { await editScripted.updatePreview() }
    check(editScripted.message?.text == "This file has scripts. Remove them?" && editScripted.message?.action?.id == "removeScripts", "scripts message: \(String(describing: editScripted.message))")
    provider.session(for: scriptedDocument).apply = { group in _ = editApply(group, to: scriptedDocument) }
    _ = complete { await editScripted.perform("removeScripts") }
    check(editScripted.message == nil && editScripted.panel.controls.contains { if case .note(let text) = $0 { return text == "The scripts are gone." } else { return false } }, "scripts removed from the panel")
    if case .success(.some(.none))? = (complete { await edit.run() }) {} else { check(false, "Done returns .none") }
    installFakes()
}

/// Click-to-edit through a real PDFView: the palette installs the overlay, a click opens the paragraph for typing in
/// its font and size, typing and clicking elsewhere commits.
@MainActor
private func editInteraction() {
    installFakes()
    EditKitModule.install()
    guard let provider = Services.toolProviders.compactMap({ $0 as? EditToolProvider }).first else { return }
    let document = DocumentHandle(url: nil, displayName: "Letter", pdf: PDFDocument(data: EditFixture.letterPage(image: EditFixture.image()))!, undoManager: makeUndoManager())
    let pdfView = PDFView(frame: NSRect(x: 0, y: 0, width: 700, height: 900))
    pdfView.document = document.pdf
    pdfView.autoScales = false
    pdfView.scaleFactor = 1
    let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 700, height: 900), styleMask: [.borderless], backing: .buffered, defer: false)
    window.contentView = pdfView
    let viewer = EditTestViewer()
    viewer.views[document.id] = pdfView
    Services.viewer = viewer
    let session = provider.session(for: document)
    session.apply = { group in _ = editApply(group, to: document); pdfView.document = document.pdf }
    let palette = EditModePalette(session: session)
    let host = NSView(frame: NSRect(x: 0, y: 0, width: 280, height: 40))
    host.addSubview(palette)
    let panelWindow = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 280, height: 40), styleMask: [.borderless], backing: .buffered, defer: false)
    panelWindow.contentView = host
    RunLoop.main.run(until: Date().addingTimeInterval(0.1))
    guard let interaction = pdfView.subviews.compactMap({ $0 as? EditInteractionView }).first else { return check(false, "the palette installs the interaction view over the PDF view") }
    guard let page = document.pdf.page(at: 0), let text = session.pageText(0), let p1 = text.blocks.first(where: { $0.text.hasPrefix("The quick") }) else { return }
    func click(_ pagePoint: CGPoint) {
        let inView = pdfView.convert(pagePoint, from: page)
        let event = NSEvent.mouseEvent(with: .leftMouseDown, location: pdfView.convert(inView, to: nil), modifierFlags: [], timestamp: 0, windowNumber: window.windowNumber,
                                       context: nil, eventNumber: 0, clickCount: 1, pressure: 1)!
        interaction.mouseDown(with: event)
        RunLoop.main.run(until: Date().addingTimeInterval(0.15))
    }
    click(CGPoint(x: 100, y: p1.bounds.midY))
    guard let editor = interaction.subviews.compactMap({ $0 as? InlineTextView }).first else { return check(false, "a click opens the inline editor: \(String(describing: session.selection))") }
    check(editor.string == p1.text && abs((editor.font?.pointSize ?? 0) - 11) < 0.6 && editor.font?.familyName == "Helvetica", "the editor shows the paragraph in Helvetica 11: \(String(describing: editor.font)) [\(editor.string)] vs [\(p1.text)]")
    let expected = pdfView.convert(p1.bounds, from: page)
    check(abs(editor.frame.midY - expected.midY) < 6 && abs(editor.frame.minX - expected.minX) < 8, "the editor sits over the paragraph: \(editor.frame) vs \(expected)")
    editor.string = "Typed right on the page."
    click(CGPoint(x: 300, y: 100))
    RunLoop.main.run(until: Date().addingTimeInterval(0.3))
    check(interaction.subviews.compactMap({ $0 as? InlineTextView }).isEmpty, "clicking elsewhere closes the editor")
    check((document.pdf.page(at: 0)?.string ?? "").contains("Typed right on the page.") && !(document.pdf.page(at: 0)?.string ?? "").contains("quick brown"), "the typing was committed: \(document.pdf.page(at: 0)?.string?.prefix(80) ?? "")")
    // A click on the picture selects it (handles are drawn), Delete removes it.
    click(CGPoint(x: 450, y: 450))
    check(session.image() != nil, "the picture is selected")
    interaction.keyDown(with: NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [], timestamp: 0, windowNumber: window.windowNumber, context: nil, characters: "\u{7F}", charactersIgnoringModifiers: "\u{7F}", isARepeat: false, keyCode: 51)!)
    RunLoop.main.run(until: Date().addingTimeInterval(0.3))
    check(session.pageText(0)?.content.images.isEmpty == true, "Delete removes the picture")
    // Closing the panel takes the overlay down.
    palette.removeFromSuperview()
    RunLoop.main.run(until: Date().addingTimeInterval(0.05))
    check(pdfView.subviews.compactMap({ $0 as? EditInteractionView }).isEmpty, "the overlay goes with the palette")
    window.orderOut(nil); panelWindow.orderOut(nil)
    installFakes()
}

/// A viewer fake that hands out the PDF views the interaction test builds.
@MainActor
private final class EditTestViewer: ViewerPresenting {
    var views: [UUID: PDFView] = [:]
    func makeWindowController(for document: DocumentHandle) -> NSWindowController { NSWindowController(window: nil) }
    func pdfView(for document: DocumentHandle) -> PDFView? { views[document.id] }
    func selectedPages(in document: DocumentHandle) -> [Int] { [] }
    func currentPage(in document: DocumentHandle) -> Int { 0 }
    func showToolPanel(_ panel: NSViewController?, in document: DocumentHandle) {}
    func showBanner(_ banner: ResultBanner, in document: DocumentHandle) {}
    func showSidebar(_ mode: SidebarMode, in document: DocumentHandle) {}
    func showOrganiser(for document: DocumentHandle, adding files: [URL]) {}
    func combine(_ files: [URL]) {}
    func showWelcome() {}
    func showCropHandles(_ handles: CropHandles?, in document: DocumentHandle) {}
    func password(forLocked fileName: String, retry: Bool) async -> String? { nil }
}
