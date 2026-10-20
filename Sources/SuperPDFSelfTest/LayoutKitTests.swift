import AppKit
import LayoutKit
import PDFKit
import SuperPDFCore

// LayoutKit's checks (WP2): the analysis pipeline on generated fixture documents (never anyone's files), the OCR path,
// the content-stream scanner, options, caching and the JSON form. Each fixture's expected block tree is asserted on
// the outline (`LayoutOutline.describe`) and on the model.

// MARK: - Fixtures (generated with Core Graphics and Core Text; RenderKitTests uses them too)

enum Fixture {
    static let letter = CGSize(width: 612, height: 792)
    static let body = NSFont(name: "Helvetica", size: 11)!
    static let bold = NSFont(name: "Helvetica-Bold", size: 11)!

    /// A PDF whose pages are drawn by closures (`kCGPDFContextMediaBox` per page; nothing else).
    static func pdf(_ pages: [(CGSize, (CGContext) -> Void)]) -> Data {
        let data = NSMutableData()
        var box = CGRect(origin: .zero, size: pages.first?.0 ?? letter)
        guard let consumer = CGDataConsumer(data: data as CFMutableData), let context = CGContext(consumer: consumer, mediaBox: &box, nil) else { return Data() }
        for (size, draw) in pages {
            var pageBox = CGRect(origin: .zero, size: size)
            let info = [kCGPDFContextMediaBox: Data(bytes: &pageBox, count: MemoryLayout<CGRect>.size) as CFData] as CFDictionary
            context.beginPDFPage(info)
            draw(context)
            context.endPDFPage()
        }
        context.closePDF()
        return data as Data
    }

    static func text(_ string: String, at point: CGPoint, font: NSFont, color: NSColor = .black, in context: CGContext) {
        let line = CTLineCreateWithAttributedString(NSAttributedString(string: string, attributes: [.font: font, .foregroundColor: color]))
        context.textPosition = point
        CTLineDraw(line, context)
    }

    static func textWidth(_ string: String, font: NSFont) -> CGFloat {
        CTLineGetTypographicBounds(CTLineCreateWithAttributedString(NSAttributedString(string: string, attributes: [.font: font])), nil, nil, nil)
    }

    /// Wraps `string` in `width` from `origin` (top-left) with `leading`; returns the y of the last baseline.
    @discardableResult
    static func paragraph(_ string: String, topLeft origin: CGPoint, width: CGFloat, font: NSFont, leading: CGFloat? = nil, align: CTTextAlignment = .left, in context: CGContext) -> CGFloat {
        let pitch = leading ?? font.pointSize * 1.25
        let words = string.split(separator: " ").map(String.init)
        var lines: [String] = []
        var current = ""
        for word in words {
            let candidate = current.isEmpty ? word : current + " " + word
            if textWidth(candidate, font: font) <= width { current = candidate } else { lines.append(current); current = word }
        }
        if !current.isEmpty { lines.append(current) }
        var y = origin.y - font.ascender
        for line in lines {
            var x = origin.x
            if align == .center { x = origin.x + (width - textWidth(line, font: font)) / 2 }
            if align == .right { x = origin.x + width - textWidth(line, font: font) }
            text(line, at: CGPoint(x: x, y: y), font: font, in: context)
            y -= pitch
        }
        return y + pitch
    }

    static let lorem = "The quick brown fox jumps over the lazy dog while the five boxing wizards jump quickly and the sphinx of black quartz judges my vow."

    // 1. A one-page letter: letterhead, date, address block, greeting, three paragraphs, sign-off.
    static func letterDocument() -> Data {
        pdf([(letter, { c in
            text("Acme Corporation", at: CGPoint(x: 72, y: 740), font: bold, in: c)
            text("20 October 2026", at: CGPoint(x: 72, y: 690), font: body, in: c)
            paragraph("Ms Jane Smith\n12 Harbour Street\nPortsmouth".replacingOccurrences(of: "\n", with: " "), topLeft: CGPoint(x: 72, y: 670), width: 120, font: body, in: c)
            text("Dear Ms Smith,", at: CGPoint(x: 72, y: 600), font: body, in: c)
            var y = paragraph("Thank you for your letter of last week. " + lorem + " " + lorem, topLeft: CGPoint(x: 72, y: 580), width: 468, font: body, in: c)
            y = paragraph("We have looked at the plans you sent and have a few questions about the schedule. " + lorem, topLeft: CGPoint(x: 72, y: y - 20), width: 468, font: body, in: c)
            y = paragraph("Please let us know when you are available to meet. " + lorem, topLeft: CGPoint(x: 72, y: y - 20), width: 468, font: body, in: c)
            text("Kind regards,", at: CGPoint(x: 72, y: y - 36), font: body, in: c)
            text("John Doe", at: CGPoint(x: 72, y: y - 72), font: body, in: c)
        })])
    }

    // 2. A two-column paper with a spanning title, abstract, section headings per column and a page number.
    static func twoColumnPaper() -> Data {
        pdf([(letter, { c in
            paragraph("Layout Analysis of Scanned and Born-Digital Documents", topLeft: CGPoint(x: 72, y: 740), width: 468, font: NSFont(name: "Helvetica-Bold", size: 20)!, align: .center, in: c)
            paragraph("A. Author and B. Author", topLeft: CGPoint(x: 72, y: 690), width: 468, font: body, align: .center, in: c)
            text("Abstract", at: CGPoint(x: 72, y: 650), font: bold, in: c)
            paragraph(lorem + " " + lorem, topLeft: CGPoint(x: 72, y: 636), width: 468, font: body, in: c)
            let small = NSFont(name: "Helvetica", size: 10)!
            let heading = NSFont(name: "Helvetica-Bold", size: 12)!
            text("1. Introduction", at: CGPoint(x: 72, y: 580), font: heading, in: c)
            var y = paragraph(lorem + " " + lorem + " " + lorem, topLeft: CGPoint(x: 72, y: 566), width: 222, font: small, in: c)
            y = paragraph("Second paragraph left. " + lorem + " " + lorem, topLeft: CGPoint(x: 72, y: y - 16), width: 222, font: small, in: c)
            text("2. Method", at: CGPoint(x: 318, y: 580), font: heading, in: c)
            var y2 = paragraph("Right column first. " + lorem + " " + lorem, topLeft: CGPoint(x: 318, y: 566), width: 222, font: small, in: c)
            y2 = paragraph("Right column second. " + lorem + " " + lorem + " " + lorem, topLeft: CGPoint(x: 318, y: y2 - 16), width: 222, font: small, in: c)
            _ = y; _ = y2
            text("1", at: CGPoint(x: 303, y: 40), font: small, in: c)
        })])
    }

    // 3. An invoice with a ruled table (header row + 4 items) and a totals line.
    static func invoice() -> Data {
        pdf([(letter, { c in
            text("Invoice", at: CGPoint(x: 72, y: 730), font: NSFont(name: "Helvetica-Bold", size: 18)!, in: c)
            text("Invoice number 1042 · 20 October 2026", at: CGPoint(x: 72, y: 705), font: body, in: c)
            let xs: [CGFloat] = [72, 272, 352, 442, 540]
            let ys: [CGFloat] = [660, 636, 612, 588, 564, 540]
            c.setStrokeColor(CGColor(gray: 0, alpha: 1)); c.setLineWidth(0.75)
            for y in ys { c.move(to: CGPoint(x: 72, y: y)); c.addLine(to: CGPoint(x: 540, y: y)) }
            for x in xs { c.move(to: CGPoint(x: x, y: 540)); c.addLine(to: CGPoint(x: x, y: 660)) }
            c.strokePath()
            let rows = [["Item", "Qty", "Unit price", "Amount"], ["Widget", "4", "10.00", "40.00"], ["Gadget", "1", "25.50", "25.50"],
                        ["Service fee", "2", "15.00", "30.00"], ["Delivery", "1", "8.00", "8.00"]]
            for (r, row) in rows.enumerated() {
                for (col, cell) in row.enumerated() {
                    text(cell, at: CGPoint(x: xs[col] + 6, y: ys[r] - 16), font: r == 0 ? bold : body, in: c)
                }
            }
            text("Total due: 103.50", at: CGPoint(x: 400, y: 510), font: bold, in: c)
            paragraph("Payment within 30 days. " + lorem, topLeft: CGPoint(x: 72, y: 470), width: 468, font: body, in: c)
        })])
    }

    // 4. A form: labels with underlines and check boxes; no tables, no figures expected.
    static func form() -> Data {
        pdf([(letter, { c in
            text("Membership application", at: CGPoint(x: 72, y: 730), font: NSFont(name: "Helvetica-Bold", size: 16)!, in: c)
            c.setStrokeColor(CGColor(gray: 0, alpha: 1)); c.setLineWidth(0.5)
            for (i, label) in ["Name:", "Address:", "Email:", "Telephone:"].enumerated() {
                let y = 680 - CGFloat(i) * 36
                text(label, at: CGPoint(x: 72, y: y), font: body, in: c)
                c.move(to: CGPoint(x: 150, y: y - 3)); c.addLine(to: CGPoint(x: 500, y: y - 3))
            }
            c.strokePath()
            text("Membership type:", at: CGPoint(x: 72, y: 520), font: body, in: c)
            for (i, option) in ["Individual", "Family", "Student"].enumerated() {
                let y = 500 - CGFloat(i) * 20
                c.stroke(CGRect(x: 90, y: y - 2, width: 10, height: 10))
                text(option, at: CGPoint(x: 108, y: y), font: body, in: c)
            }
            paragraph("By signing you agree to the terms. " + lorem, topLeft: CGPoint(x: 72, y: 420), width: 468, font: body, in: c)
        })])
    }

    // 5. A scan: the letter rasterized at 150 dpi and placed as the only content of an image page.
    static func scan() -> Data {
        guard let document = CGPDFDocument(CGDataProvider(data: letterDocument() as CFData)!), let page = document.page(at: 1) else { return Data() }
        let scale: CGFloat = 150 / 72
        let width = Int(letter.width * scale), height = Int(letter.height * scale)
        let bitmap = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0, space: CGColorSpaceCreateDeviceGray(), bitmapInfo: CGImageAlphaInfo.none.rawValue)!
        bitmap.setFillColor(gray: 1, alpha: 1); bitmap.fill(CGRect(x: 0, y: 0, width: width, height: height))
        bitmap.scaleBy(x: scale, y: scale)
        bitmap.drawPDFPage(page)
        let image = bitmap.makeImage()!
        return pdf([(letter, { c in c.draw(image, in: CGRect(origin: .zero, size: letter)) })])
    }

    // 6. Lists: bullets with a wrapped item and a nested level, then a numbered list.
    static func lists() -> Data {
        pdf([(letter, { c in
            text("Shopping", at: CGPoint(x: 72, y: 730), font: NSFont(name: "Helvetica-Bold", size: 16)!, in: c)
            var y: CGFloat = 700
            for item in ["Apples and pears from the market", "Bread, the large loaf that keeps for a week and is good for toast as well as sandwiches", "Milk"] {
                text("•", at: CGPoint(x: 72, y: y), font: body, in: c)
                y = paragraph(item, topLeft: CGPoint(x: 90, y: y + body.ascender), width: 300, font: body, in: c) - 14
                if item == "Milk" {
                    text("◦", at: CGPoint(x: 90, y: y), font: body, in: c)
                    text("Semi-skimmed if they have it", at: CGPoint(x: 108, y: y), font: body, in: c)
                    y -= 14
                }
            }
            y -= 20
            text("Steps", at: CGPoint(x: 72, y: y), font: bold, in: c)
            y -= 18
            for (i, step) in ["Preheat the oven.", "Mix the flour and butter.", "Bake for twenty minutes."].enumerated() {
                text("\(i + 1).", at: CGPoint(x: 72, y: y), font: body, in: c)
                text(step, at: CGPoint(x: 90, y: y), font: body, in: c)
                y -= 14
            }
        })])
    }

    // 7. A heading hierarchy by size and weight.
    static func headings() -> Data {
        pdf([(letter, { c in
            text("User guide", at: CGPoint(x: 72, y: 720), font: NSFont(name: "Helvetica-Bold", size: 24)!, in: c)
            var y = paragraph(lorem, topLeft: CGPoint(x: 72, y: 690), width: 468, font: body, in: c)
            text("Getting started", at: CGPoint(x: 72, y: y - 28), font: NSFont(name: "Helvetica-Bold", size: 16)!, in: c)
            y = paragraph(lorem + " " + lorem, topLeft: CGPoint(x: 72, y: y - 44), width: 468, font: body, in: c)
            text("Installing", at: CGPoint(x: 72, y: y - 24), font: NSFont(name: "Helvetica-Bold", size: 12)!, in: c)
            y = paragraph(lorem, topLeft: CGPoint(x: 72, y: y - 38), width: 468, font: body, in: c)
            text("First run", at: CGPoint(x: 72, y: y - 24), font: NSFont(name: "Helvetica-Bold", size: 12)!, in: c)
            paragraph(lorem, topLeft: CGPoint(x: 72, y: y - 38), width: 468, font: body, in: c)
        })])
    }

    // 8. A figure (image XObject) with a caption under it, between two paragraphs.
    static func figure() -> Data {
        let bitmap = CGContext(data: nil, width: 200, height: 120, bitsPerComponent: 8, bytesPerRow: 0, space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        bitmap.setFillColor(CGColor(red: 0.2, green: 0.5, blue: 0.9, alpha: 1)); bitmap.fill(CGRect(x: 0, y: 0, width: 200, height: 120))
        bitmap.setFillColor(CGColor(red: 1, green: 0.8, blue: 0.1, alpha: 1)); bitmap.fill(CGRect(x: 40, y: 20, width: 120, height: 60))
        let image = bitmap.makeImage()!
        return pdf([(letter, { c in
            var y = paragraph("Sales grew in every quarter. " + lorem, topLeft: CGPoint(x: 72, y: 720), width: 468, font: body, in: c)
            c.draw(image, in: CGRect(x: 206, y: y - 150, width: 200, height: 120))
            text("Figure 1. Sales by quarter", at: CGPoint(x: 228, y: y - 166), font: NSFont(name: "Helvetica-Oblique", size: 10)!, in: c)
            y = paragraph("The chart above shows the trend. " + lorem, topLeft: CGPoint(x: 72, y: y - 200), width: 468, font: body, in: c)
        })])
    }

    // 9. A table from alignment alone: bold header, three columns, numbers right-aligned.
    static func alignedTable() -> Data {
        pdf([(letter, { c in
            text("Quarterly figures", at: CGPoint(x: 72, y: 730), font: NSFont(name: "Helvetica-Bold", size: 14)!, in: c)
            let rows = [["Region", "Units", "Revenue"], ["North", "1,240", "12,400.00"], ["South", "980", "9,800.00"], ["East", "1,105", "11,050.00"], ["West", "760", "7,600.00"]]
            for (r, row) in rows.enumerated() {
                let y = 690 - CGFloat(r) * 16
                let font = r == 0 ? bold : body
                text(row[0], at: CGPoint(x: 72, y: y), font: font, in: c)
                text(row[1], at: CGPoint(x: 260 - textWidth(row[1], font: font), y: y), font: font, in: c)
                text(row[2], at: CGPoint(x: 380 - textWidth(row[2], font: font), y: y), font: font, in: c)
            }
            paragraph("Figures are provisional. " + lorem, topLeft: CGPoint(x: 72, y: 580), width: 468, font: body, in: c)
        })])
    }

    // 10. Three pages with a running header, "Page n of 3" footers and body text.
    static func report() -> Data {
        pdf((1...3).map { n in (letter, { c in
            text("Annual Report 2026", at: CGPoint(x: 72, y: 756), font: NSFont(name: "Helvetica", size: 9)!, in: c)
            text("Page \(n) of 3", at: CGPoint(x: 280, y: 36), font: NSFont(name: "Helvetica", size: 9)!, in: c)
            var y: CGFloat = 710
            for p in 1...3 { y = paragraph("Page \(n) paragraph \(p). " + lorem + " " + lorem, topLeft: CGPoint(x: 72, y: y), width: 468, font: body, in: c) - 20 }
        }) })
    }

    /// The letter with its page rotated 90° (PDFKit sets /Rotate).
    @MainActor static func rotatedLetter() -> Data {
        let pdf = PDFDocument(data: letterDocument())!
        pdf.page(at: 0)!.rotation = 90
        return pdf.dataRepresentation()!
    }
}

// MARK: - Cases

func registerLayoutKitTests() {
    @MainActor func analyze(_ data: Data, pages: [Int]? = nil, options: LayoutOptions = LayoutOptions()) -> LayoutDocument? {
        if !(Services.layout is LayoutService) { LayoutKitModule.install() }
        switch complete(300, { try await Services.layout.analyze(.data(data), pages: pages, options: options) }) {
        case .success(let document): return document
        case .failure(let error): check(false, "analyze failed: \(error)"); return nil
        default: check(false, "analyze timed out"); return nil
        }
    }
    func kinds(_ page: LayoutPage) -> [LayoutBlockKind] { page.readingOrder.compactMap { if case .block(let id) = $0 { return page.blocks[id].kind } else { return nil } } }
    func orderedText(_ page: LayoutPage) -> [String] { page.readingOrder.compactMap { if case .block(let id) = $0 { return page.blocks[id].text } else { return nil } } }
    func headings(_ page: LayoutPage) -> [(Int, String)] { page.blocks.compactMap { if case .heading(let level) = $0.kind { return (level, $0.text) } else { return nil } } }
    func roundTrips(_ document: LayoutDocument) -> Bool {
        guard let json = try? LayoutOutline.json(document), let back = try? LayoutOutline.document(fromJSON: json) else { return false }
        return back == document
    }
    let verbose = ProcessInfo.processInfo.environment["SUPERPDF_SELFTEST_VERBOSE"] != nil
    @MainActor func show(_ name: String, _ page: LayoutPage) { if verbose { print("--- \(name)\n" + LayoutOutline.describe(page)) } }

    SelfTest.cases.append(("LayoutKit.install", {
        installFakes()
        LayoutKitModule.install()
        check(Services.layout is LayoutService, "install registers the LayoutService")
    }))

    SelfTest.cases.append(("LayoutKit.letter", {
        guard let document = analyze(Fixture.letterDocument()), let page = document.pages.first else { return }
        show("letter", page)
        check(page.origin == .embedded && page.rotation == 0 && page.size == Fixture.letter, "page facts")
        check(page.tables.isEmpty && page.figures.isEmpty, "no tables or figures in a letter")
        let texts = orderedText(page)
        let greeting = texts.firstIndex { $0.hasPrefix("Dear Ms Smith") }, regards = texts.firstIndex { $0.hasPrefix("Kind regards") }
        check(greeting != nil && regards != nil && greeting! < regards!, "greeting before sign-off: \(texts)")
        let first = page.blocks.first { $0.text.hasPrefix("Thank you for your letter") }
        check((first?.lines.count ?? 0) >= 4, "first paragraph is one block of several lines: \(first?.lines.count ?? 0)")
        check(first.map { $0.text.contains("judges my vow.\n") || $0.text.hasSuffix("judges my vow.") } ?? false, "paragraph text joins its lines")
        check(page.blocks.filter { if case .paragraph = $0.kind { return $0.lines.count >= 3 } else { return false } }.count == 3, "three multi-line paragraphs")
        check(page.blocks.contains { $0.kind == .header && $0.text == "Acme Corporation" }, "the letterhead is a header")
        check(!page.readingOrder.contains { if case .block(let id) = $0 { return page.blocks[id].kind == .header } else { return false } }, "headers leave the reading order")
        check(page.blocks.allSatisfy { $0.lines.allSatisfy { $0.words.allSatisfy { $0.fontName != nil && $0.fontSize == 11 && $0.confidence == 1 } } }, "PDFKit words carry font, size and confidence 1")
        check(page.blocks.first { $0.text == "Acme Corporation" }?.lines[0].words[0].isBold == true, "bold trait from the font")
        check(roundTrips(document), "JSON round trip")
    }))

    SelfTest.cases.append(("LayoutKit.twoColumns", {
        guard let document = analyze(Fixture.twoColumnPaper()), let page = document.pages.first else { return }
        show("paper", page)
        let heads = headings(page)
        check(heads.contains { $0.0 == 1 && $0.1.hasPrefix("Layout Analysis") }, "title is H1: \(heads)")
        check(heads.contains { $0.1 == "1. Introduction" } && heads.contains { $0.1 == "2. Method" }, "section headings found: \(heads)")
        check(Set(heads.filter { $0.1.hasPrefix("1.") || $0.1.hasPrefix("2.") }.map(\.0)).count == 1, "section headings share a level")
        let left = page.blocks.filter { $0.text.hasPrefix("1. Introduction") || $0.text.hasPrefix("Second paragraph left") }
        let right = page.blocks.filter { $0.text.hasPrefix("2. Method") || $0.text.hasPrefix("Right column") }
        check(left.count == 2 && right.count == 3, "column blocks found: left \(left.count) right \(right.count)")
        check(left.allSatisfy { $0.column == 0 } && right.allSatisfy { $0.column == 1 }, "column indices: \(left.map(\.column)) \(right.map(\.column))")
        let order = orderedText(page)
        let lastLeft = order.lastIndex { $0.hasPrefix("Second paragraph left") } ?? -1
        let firstRight = order.firstIndex { $0.hasPrefix("2. Method") } ?? -1
        check(lastLeft >= 0 && firstRight > lastLeft, "left column reads before the right column")
        check((order.firstIndex { $0.hasPrefix("Layout Analysis") } ?? 9) < (order.firstIndex { $0 == "Abstract" } ?? 0), "title before abstract")
        check(page.blocks.contains { $0.kind == .pageNumber && $0.text == "1" }, "page number recognised")
        check(!order.contains("1"), "page number excluded from reading order")
        check(roundTrips(document), "JSON round trip")
    }))

    SelfTest.cases.append(("LayoutKit.invoiceTable", {
        guard let document = analyze(Fixture.invoice()), let page = document.pages.first else { return }
        show("invoice", page)
        check(page.tables.count == 1, "one ruled table, got \(page.tables.count)")
        guard let table = page.tables.first else { return }
        check(table.rowCount == 5 && table.columnCount == 4, "5x4 grid, got \(table.rowCount)x\(table.columnCount)")
        check(table.hasHeaderRow, "bold first row is a header")
        func cell(_ r: Int, _ c: Int) -> String? { table.cells.first { $0.row == r && $0.column == c }?.text }
        check(cell(0, 0) == "Item" && cell(1, 0) == "Widget" && cell(1, 3) == "40.00" && cell(3, 0) == "Service fee" && cell(4, 2) == "8.00", "cell texts: \(table.cells.map(\.text))")
        check(table.cells.allSatisfy { $0.rowSpan == 1 && $0.columnSpan == 1 }, "no spans in a full grid")
        check(!page.blocks.contains { $0.text.contains("Widget") }, "table words are not paragraphs")
        check(page.figures.isEmpty, "rulings are not figures")
        let order = page.readingOrder
        let tableAt = order.firstIndex { if case .table = $0 { return true } else { return false } } ?? -1
        let totalAt = order.firstIndex { if case .block(let id) = $0 { return page.blocks[id].text.hasPrefix("Total due") } else { return false } } ?? -1
        let titleAt = order.firstIndex { if case .block(let id) = $0 { return page.blocks[id].text == "Invoice" } else { return false } } ?? -1
        check(titleAt < tableAt && tableAt < totalAt, "title, table, total in order: \(titleAt) \(tableAt) \(totalAt)")
        check(headings(page).contains { $0.1 == "Invoice" && $0.0 == 1 }, "Invoice title is H1")
        check(page.text.contains("Item\tQty\tUnit price\tAmount"), "page text lays tables out with tabs")
        check(roundTrips(document), "JSON round trip")
    }))

    SelfTest.cases.append(("LayoutKit.form", {
        guard let document = analyze(Fixture.form()), let page = document.pages.first else { return }
        show("form", page)
        check(page.tables.isEmpty, "underlines are not a table (\(page.tables.count))")
        check(page.figures.isEmpty, "check boxes and underlines are not figures (\(page.figures.count))")
        for label in ["Name:", "Address:", "Email:", "Telephone:", "Membership type:"] { check(page.blocks.contains { $0.text == label }, "label \(label) is its own block") }
        check(page.blocks.contains { $0.text.hasPrefix("By signing") && $0.lines.count >= 2 }, "terms paragraph")
        check(headings(page).contains { $0.1 == "Membership application" }, "form title")
    }))

    SelfTest.cases.append(("LayoutKit.scanOCR", {
        let scan = Fixture.scan()
        guard let plain = analyze(scan, options: LayoutOptions(recognition: .never)) else { return }
        check(plain.pages[0].blocks.isEmpty && plain.pages[0].origin == .embedded, "an image page has no embedded text")
        guard let document = analyze(scan), let page = document.pages.first else { return }
        show("scan", page)
        check(page.origin == .recognized, "Vision ran on the page without text")
        check(page.blocks.count >= 5, "blocks from OCR: \(page.blocks.count)")
        let text = page.text
        check(text.contains("Dear Ms Smith"), "OCR read the greeting")
        check(text.contains("quick brown fox"), "OCR read the body")
        check(page.blocks.allSatisfy { $0.lines.allSatisfy { $0.words.allSatisfy { $0.confidence > 0 && $0.confidence <= 1 && $0.fontSize > 0 } } }, "OCR words carry confidence and an estimated size")
        check(page.figures.isEmpty, "the scan's own image is not a figure")
        let thanks = page.blocks.first { $0.text.hasPrefix("Thank you") }
        check((thanks?.lines.count ?? 0) >= 4, "OCR lines group into the paragraph: \(thanks?.lines.count ?? 0)")
        check(roundTrips(document), "JSON round trip")
    }))

    SelfTest.cases.append(("LayoutKit.lists", {
        guard let document = analyze(Fixture.lists()), let page = document.pages.first else { return }
        show("lists", page)
        let items = page.blocks.compactMap { block -> (Int, String, String)? in if case .listItem(let level, let marker) = block.kind { return (level, marker, block.text) } else { return nil } }
        check(items.count == 7, "seven list items, got \(items.count): \(items)")
        check(items.filter { $0.1 == "•" }.count == 3, "three bullet items")
        check(items.contains { $0.1 == "◦" && $0.0 == 1 && $0.2.hasPrefix("Semi-skimmed") }, "nested item at level 1")
        check(items.filter { $0.1 == "•" }.allSatisfy { $0.0 == 0 }, "bullets at level 0")
        check(items.contains { $0.1 == "1." && $0.2 == "Preheat the oven." } && items.contains { $0.1 == "3." }, "numbered markers as printed")
        check(page.blocks.contains { if case .listItem = $0.kind { return $0.text.hasPrefix("Bread") && $0.lines.count == 2 } else { return false } }, "wrapped item keeps its continuation line")
        check(!items.contains { $0.2.hasPrefix("•") || $0.2.hasPrefix("1.") }, "markers leave the item text")
        check(headings(page).contains { $0.1 == "Shopping" } && headings(page).contains { $0.1 == "Steps" }, "headings around the lists")
        check(roundTrips(document), "JSON round trip")
    }))

    SelfTest.cases.append(("LayoutKit.headings", {
        guard let document = analyze(Fixture.headings()), let page = document.pages.first else { return }
        show("headings", page)
        let heads = headings(page)
        check(heads.contains { $0 == (1, "User guide") }, "H1 by size: \(heads)")
        check(heads.contains { $0 == (2, "Getting started") }, "H2 by size: \(heads)")
        check(heads.contains { $0 == (3, "Installing") } && heads.contains { $0 == (3, "First run") }, "H3 by weight: \(heads)")
        check(kinds(page).filter { if case .paragraph = $0 { return true } else { return false } }.count == 4, "four body paragraphs")
        let order = orderedText(page)
        check(order.firstIndex(of: "User guide") == 0 && (order.firstIndex(of: "Installing") ?? 0) < (order.firstIndex(of: "First run") ?? 0), "top-down order")
    }))

    SelfTest.cases.append(("LayoutKit.figureCaption", {
        guard let document = analyze(Fixture.figure()), let page = document.pages.first else { return }
        show("figure", page)
        check(page.figures.count == 1 && page.figures[0].kind == .image, "one image figure, got \(page.figures.map(\.kind))")
        let figure = page.figures.first
        check(figure.map { abs($0.bounds.width - 200) < 1 && abs($0.bounds.height - 120) < 1 && abs($0.bounds.minX - 206) < 1 } ?? false, "figure bounds in page space: \(String(describing: figure?.bounds))")
        let caption = page.blocks.first { $0.kind == .caption }
        check(caption?.text == "Figure 1. Sales by quarter", "caption block: \(String(describing: caption?.text))")
        check(figure?.captionBlockID != nil && figure?.captionBlockID == caption?.id, "caption linked to the figure")
        check(caption?.lines[0].words[0].isItalic == true, "italic trait from the font")
        let order = page.readingOrder
        let figureAt = order.firstIndex { if case .figure = $0 { return true } else { return false } } ?? -1
        let aboveAt = order.firstIndex { if case .block(let id) = $0 { return page.blocks[id].text.hasPrefix("Sales grew") } else { return false } } ?? -1
        let belowAt = order.firstIndex { if case .block(let id) = $0 { return page.blocks[id].text.hasPrefix("The chart above") } else { return false } } ?? -1
        check(aboveAt < figureAt && figureAt < belowAt, "paragraph, figure, paragraph: \(aboveAt) \(figureAt) \(belowAt)")
        check(roundTrips(document), "JSON round trip")
    }))

    SelfTest.cases.append(("LayoutKit.alignedTable", {
        guard let document = analyze(Fixture.alignedTable()), let page = document.pages.first else { return }
        show("aligned", page)
        check(page.tables.count == 1, "one alignment table, got \(page.tables.count)")
        guard let table = page.tables.first else { return }
        check(table.rowCount == 5 && table.columnCount == 3, "5x3, got \(table.rowCount)x\(table.columnCount)")
        check(table.hasHeaderRow, "header row from bold and non-numeric text")
        func cell(_ r: Int, _ c: Int) -> String? { table.cells.first { $0.row == r && $0.column == c }?.text }
        check(cell(0, 0) == "Region" && cell(1, 1) == "1,240" && cell(4, 2) == "7,600.00", "cells: \(table.cells.map(\.text))")
        check(page.blocks.contains { $0.text.hasPrefix("Figures are provisional") }, "paragraph after the table stays a paragraph")
        check(headings(page).contains { $0.1 == "Quarterly figures" }, "title heading")
        guard let noTables = analyze(Fixture.alignedTable(), options: LayoutOptions(detectTables: false)) else { return }
        check(noTables.pages[0].tables.isEmpty && noTables.pages[0].blocks.contains { $0.text.contains("North") }, "detectTables: false leaves the rows as text")
    }))

    SelfTest.cases.append(("LayoutKit.runningHeadersAcrossPages", {
        guard let document = analyze(Fixture.report()) else { return }
        check(document.pages.count == 3, "three pages")
        for page in document.pages {
            show("report \(page.index)", page)
            check(page.blocks.contains { $0.kind == .header && $0.text == "Annual Report 2026" }, "running header on page \(page.index)")
            check(page.blocks.contains { $0.kind == .pageNumber && $0.text == "Page \(page.index + 1) of 3" }, "page number on page \(page.index): \(page.blocks.map { "\($0.kind) \($0.text)" })")
            check(kinds(page).count == 3 && kinds(page).allSatisfy { if case .paragraph = $0 { return true } else { return false } }, "three body paragraphs in reading order on page \(page.index)")
            check(!page.text.contains("Annual Report") && !page.text.contains("Page \(page.index + 1) of 3"), "page text skips running blocks")
        }
        guard let kept = analyze(Fixture.report(), pages: [1], options: LayoutOptions(excludeHeadersAndFooters: false)) else { return }
        check(kept.pages.count == 1 && kept.pages[0].index == 1, "pages: [1] analyses that page only")
        check(kept.pages[0].text.hasPrefix("Annual Report 2026") && kept.pages[0].text.hasSuffix("Page 2 of 3"), "excludeHeadersAndFooters: false keeps them in order")
        check(roundTrips(document), "JSON round trip")
    }))

    SelfTest.cases.append(("LayoutKit.rotatedPage", {
        guard let document = analyze(Fixture.rotatedLetter()), let page = document.pages.first else { return }
        check(page.rotation == 90 && page.size == Fixture.letter, "rotation and unrotated size kept")
        check(page.blocks.allSatisfy { CGRect(origin: .zero, size: Fixture.letter).contains($0.bounds) }, "blocks in unrotated page space")
        check(page.blocks.contains { $0.text.hasPrefix("Dear Ms Smith") }, "text found on a rotated page")
        // OCR on the rotated scan must land in the same unrotated space.
        let pdf = PDFDocument(data: Fixture.scan())!
        pdf.page(at: 0)!.rotation = 90
        guard let scanned = analyze(pdf.dataRepresentation()!), let scanPage = scanned.pages.first else { return }
        show("rotated scan", scanPage)
        check(scanPage.origin == .recognized && scanPage.rotation == 90, "OCR ran on the rotated scan")
        let greeting = scanPage.blocks.first { $0.text.hasPrefix("Dear Ms Smith") }
        let reference = page.blocks.first { $0.text.hasPrefix("Dear Ms Smith") }
        check(greeting != nil && reference != nil && abs(greeting!.bounds.minX - reference!.bounds.minX) < 6 && abs(greeting!.bounds.minY - reference!.bounds.minY) < 6,
              "OCR boxes map back through the rotation: \(String(describing: greeting?.bounds)) vs \(String(describing: reference?.bounds))")
    }))

    SelfTest.cases.append(("LayoutKit.recognizedLinesEntry", {
        let lines = [
            RecognizedLine(text: "Minutes of the meeting", bounds: CGRect(x: 72, y: 700, width: 220, height: 20), confidence: 0.9),
            RecognizedLine(text: "Present: everyone who could make it on the day", bounds: CGRect(x: 72, y: 670, width: 300, height: 13), confidence: 0.8),
            RecognizedLine(text: "and a few who joined late by telephone.", bounds: CGRect(x: 72, y: 655, width: 280, height: 13), confidence: 0.8),
            RecognizedLine(text: "• Approve the budget", bounds: CGRect(x: 72, y: 620, width: 150, height: 13), confidence: 0.7),
            RecognizedLine(text: "• Plan the picnic", bounds: CGRect(x: 72, y: 605, width: 130, height: 13), confidence: 0.7),
        ]
        if !(Services.layout is LayoutService) { LayoutKitModule.install() }
        guard case .success(let page)? = complete(300, { await Services.layout.analyze(recognized: lines, pageIndex: 4, pageSize: Fixture.letter, options: LayoutOptions()) }) else { check(false, "analyze(recognized:)"); return }
        show("recognized", page)
        check(page.index == 4 && page.origin == .recognized, "page facts")
        check(headings(page).contains { $0.1 == "Minutes of the meeting" }, "larger OCR line is a heading")
        check(page.blocks.contains { $0.text.hasPrefix("Present:") && $0.lines.count == 2 }, "two OCR lines form one paragraph")
        check(page.blocks.filter { if case .listItem(_, "•") = $0.kind { return true } else { return false } }.count == 2, "bullets from OCR text")
        check(page.blocks.allSatisfy { $0.lines.allSatisfy { $0.words.allSatisfy { $0.confidence < 1 } } }, "synthesised words keep the line confidence")
    }))

    SelfTest.cases.append(("LayoutKit.graphicsScanner", {
        func graphics(_ data: Data) -> PageGraphics {
            guard let document = CGPDFDocument(CGDataProvider(data: data as CFData)!), let page = document.page(at: 1) else { return .empty }
            return PageGraphicsScanner.scan(page)
        }
        let invoice = graphics(Fixture.invoice())
        check(invoice.rulings.filter(\.isHorizontal).count == 6 && invoice.rulings.filter { !$0.isHorizontal }.count == 5, "invoice rulings: \(invoice.rulings.count)")
        check(invoice.images.isEmpty && invoice.vectors.isEmpty, "only rulings on the invoice")
        let figure = graphics(Fixture.figure())
        check(figure.images.count == 1 && figure.images.first.map { abs($0.minX - 206) < 0.5 && abs($0.width - 200) < 0.5 } == true, "image XObject rect: \(figure.images)")
        let form = graphics(Fixture.form())
        check(form.rulings.count == 4 && form.vectors.count == 3, "form: 4 underlines, 3 boxes, got \(form.rulings.count) / \(form.vectors.count)")
        check(form.vectors.allSatisfy { abs($0.width - 10.5) < 0.6 && abs($0.height - 10.5) < 0.6 }, "stroked boxes include the line width")
        // A form XObject with its own matrix: drawn through PDFKit's data (PDFKit wraps pages in forms on rotation).
        let rotated = graphics(Fixture.rotatedLetter())
        check(rotated.rulings.isEmpty && rotated.images.isEmpty, "nothing drawn in the letter")
    }))

    SelfTest.cases.append(("LayoutKit.cacheAndPasswords", {
        installFakes()
        LayoutKitModule.install()
        let data = Fixture.headings()
        guard let first = analyze(data), let second = analyze(data) else { return }
        check(first == second, "a second analysis of the same bytes answers the same document")
        guard let subset = analyze(data, pages: [0]) else { return }
        check(subset == first, "pages: [0] on a one-page document")
        try? FileManager.default.createDirectory(at: scratch, withIntermediateDirectories: true)
        let fileURL = scratch.appendingPathComponent("layout-fixture.pdf")
        try? data.write(to: fileURL)
        guard case .success(let fromFile)? = complete(300, { try await Services.layout.analyze(.file(fileURL), pages: nil, options: LayoutOptions()) }) else { check(false, "file source"); return }
        check(fromFile == first, "file and data sources agree")
        check(PDFSource.data(data).fingerprint() == PDFSource.data(data).fingerprint() && PDFSource.data(data).fingerprint() != PDFSource.data(Fixture.lists()).fingerprint(), "fingerprints follow the bytes")
        // A locked document opens with its password and fails without.
        let pdf = PDFDocument(data: data)!
        let lockedURL = scratch.appendingPathComponent("layout-locked.pdf")
        pdf.write(to: lockedURL, withOptions: [.userPasswordOption: "pw", .ownerPasswordOption: "pw"])
        if case .failure(let error)? = complete(300, { try await Services.layout.analyze(.file(lockedURL), pages: nil, options: LayoutOptions()) }) {
            check(error as? LayoutError == .locked, "locked without password: \(error)")
        } else { check(false, "locked file analysed without a password") }
        guard case .success(let unlocked)? = complete(300, { try await Services.layout.analyze(.file(lockedURL, password: "pw"), pages: nil, options: LayoutOptions()) }) else { check(false, "password source"); return }
        check(unlocked.pages[0].blocks.contains { $0.text == "User guide" }, "analysed with the password")
        if case .failure(let error)? = complete(300, { try await Services.layout.analyze(.data(Data("not a pdf".utf8)), pages: nil, options: LayoutOptions()) }) {
            check(error as? LayoutError == .cannotOpen, "garbage fails cleanly: \(error)")
        } else { check(false, "garbage analysed") }
        if case .failure(let error)? = complete(300, { try await Services.layout.analyze(.data(data), pages: [7], options: LayoutOptions()) }) {
            check(error as? LayoutError == .noSuchPage(7), "missing page fails cleanly: \(error)")
        } else { check(false, "missing page analysed") }
    }))

    SelfTest.cases.append(("LayoutKit.outline", {
        guard let document = analyze(Fixture.invoice()), let page = document.pages.first else { return }
        let outline = LayoutOutline.describe(page)
        check(outline.hasPrefix("H1 c0 \"Invoice\""), "outline starts with the title: \(outline.prefix(60))")
        check(outline.contains("T 5x4 hdr \"Item | Qty | Unit price | Amount\""), "outline describes the table: \(outline)")
        let empty = LayoutPage(index: 0, size: Fixture.letter)
        check(LayoutOutline.describe(empty).isEmpty, "empty page, empty outline")
    }))
}
