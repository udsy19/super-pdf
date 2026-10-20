import AppKit
import CommonCrypto
import CryptoKit
import PDFKit
import PDFModelKit
import ProtectKit
import RenderKit
import Security
import SuperPDFCore
import ToolsKit

// ProtectKit's checks (WP12), on generated fixtures only. Black out is checked the hard way: the output is re-read
// (PDFKit text, the decoded bytes of every object, the image samples, a render) and what was under the marks must be
// gone, not covered, while what was next to it stays where it was. Passwords and permissions round-trip through QPDF
// and PDFKit; the envelope opens with its password; certificate encryption is opened with the recipient's key.

func registerProtectKitTests() {
    SelfTest.cases += [
        ("ProtectKit.provider", protectProvider),
        ("ProtectKit.findPatterns", protectFindPatterns),
        ("ProtectKit.blackOut", protectBlackOut),
        ("ProtectKit.blackOutPanel", protectBlackOutPanel),
        ("ProtectKit.blackOutScan", protectBlackOutScan),
        ("ProtectKit.hiddenInfo", protectHiddenInfo),
        ("ProtectKit.passwords", protectPasswords),
        ("ProtectKit.passwordPanels", protectPasswordPanels),
        ("ProtectKit.envelope", protectEnvelope),
        ("ProtectKit.lockIn", protectLockIn),
        ("ProtectKit.certificate", protectCertificate),
    ]
}

// MARK: - Helpers

@MainActor
private func protectSetUp() -> ProtectService {
    installFakes()
    ProtectKitModule.install()
    return Services.protect as! ProtectService
}

@MainActor
private func protectRun<T>(_ name: String, _ work: @escaping @MainActor () async throws -> T) -> T? {
    switch complete(300, work) {
    case .success(let value): return value
    case .failure(let error): check(false, "\(name) failed: \(error)"); return nil
    default: check(false, "\(name) timed out"); return nil
    }
}

private func protectFile(_ name: String, _ data: Data? = nil) -> URL {
    let folder = scratch.appendingPathComponent("protect", isDirectory: true)
    try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    let url = folder.appendingPathComponent(name)
    if let data { try? data.write(to: url) }
    return url
}

/// Every object of a PDF with streams decoded and uncompressed, as Latin-1 text, for "is it anywhere in the file".
private func decodedBytes(_ data: Data, password: String? = nil) -> String {
    guard let model = try? PDFModel(data: data, password: password),
          let plain = try? model.data(options: PDFWriteOptions(objectStreams: .disable, compressStreams: false, decodeLevel: .all,
                                                                encryption: .remove)) else { return "" }
    return String(decoding: plain.map { $0 }, as: Unicode.ASCII.self)
}

private func containsAnyForm(_ haystack: String, _ needle: String) -> Bool {
    let hex = needle.utf8.map { String(format: "%02x", $0) }.joined()
    return haystack.contains(needle) || haystack.lowercased().contains(hex)
}

/// RGBA pixels of a page rendered at 72 dpi (1 pt per pixel), top row first.
private func renderPixels(_ data: Data, page index: Int, password: String? = nil) -> (pixels: [UInt8], width: Int, height: Int)? {
    guard let document = try? PDFPages.open(.data(data, password: password)), let page = try? PDFPages.page(document, at: index),
          let image = try? Rasterizer.render(page, dpi: 72) else { return nil }
    var pixels = [UInt8](repeating: 0, count: image.width * image.height * 4)
    guard let context = CGContext(data: &pixels, width: image.width, height: image.height, bitsPerComponent: 8, bytesPerRow: image.width * 4,
                                  space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
    context.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
    return (pixels, image.width, image.height)
}

/// The colour at a page point (page space, y up) of a 72 dpi render.
private func colour(_ render: (pixels: [UInt8], width: Int, height: Int), _ x: Int, _ y: Int) -> (r: Int, g: Int, b: Int) {
    let row = render.height - 1 - y
    let p = (row * render.width + x) * 4
    return (Int(render.pixels[p]), Int(render.pixels[p + 1]), Int(render.pixels[p + 2]))
}

private func helvetica(_ model: PDFModel) -> PDFObject {
    model.makeIndirect(.dictionary(["Type": .name("Font"), "Subtype": .name("Type1"), "BaseFont": .name("Helvetica"),
                                    "Encoding": .name("WinAnsiEncoding")]))
}

/// Page 1: plain text with a name and an SSN, a TJ line with a secret between kept words, invisible (OCR-style) text,
/// text under an opaque picture, a red 100×100 picture, a blue filled rectangle and a green line, a form XObject with
/// a secret; a note over the vector area, a note mentioning the name elsewhere, a link, a thumbnail. Page 2 draws the
/// same form. The document has Info, a bookmark naming the secret, an attachment and an opening script.
private func blackOutFixture() -> Data {
    let model = PDFModel()
    let page1 = try! model.addBlankPage(size: CGSize(width: 612, height: 792))
    let page2 = try! model.addBlankPage(size: CGSize(width: 612, height: 792))
    let font = helvetica(model)
    var red = Data()
    for _ in 0..<(100 * 100) { red.append(contentsOf: [255, 0, 0]) }
    let image = model.makeStream(["Type": .name("XObject"), "Subtype": .name("Image"), "Width": .integer(100), "Height": .integer(100),
                                  "ColorSpace": .name("DeviceRGB"), "BitsPerComponent": .integer(8)], data: red)
    let form = model.makeStream(["Type": .name("XObject"), "Subtype": .name("Form"), "BBox": .rect(CGRect(x: 0, y: 0, width: 300, height: 40)),
                                 "Resources": .dictionary(["Font": .dictionary(["F0": font.reference!])])],
                                data: Data("BT /F0 14 Tf 0 10 Td (FORMSECRET) Tj ET".utf8))
    for page in [page1, page2] {
        page.addResource(font, category: "Font", prefix: "F")
        page.addResource(form, category: "XObject", prefix: "Fm")
    }
    page1.addResource(image, category: "XObject", prefix: "Im")
    page1.setContentData(Data("""
    BT /F0 12 Tf 72 700 Td (Name: John Secretname, SSN 123-45-6789) Tj ET
    BT /F0 12 Tf 72 660 Td [(Account ) -20 (TOPSECRET42) 30 ( done)] TJ ET
    q BT 3 Tr /F0 10 Tf 72 620 Td (HIDDENOCR) Tj ET Q
    BT /F0 12 Tf 305 440 Td (UNDERIMAGE) Tj ET
    q 100 0 0 100 300 400 cm /Im0 Do Q
    q 0 0 1 rg 72 300 200 50 re f Q
    q 0 1 0 RG 4 w 72 250 m 400 250 l S Q
    q 1 0 0 1 72 560 cm /Fm0 Do Q
    """.utf8))
    page2.setContentData(Data("q 1 0 0 1 72 560 cm /Fm0 Do Q BT /F0 12 Tf 72 700 Td (Page two) Tj ET".utf8))
    page1.addAnnotation(model.make(.dictionary(["Type": .name("Annot"), "Subtype": .name("Text"),
                                                "Rect": .rect(CGRect(x: 160, y: 300, width: 20, height: 20)), "Contents": .text("Covered note")])))
    page1.addAnnotation(model.make(.dictionary(["Type": .name("Annot"), "Subtype": .name("Text"),
                                                "Rect": .rect(CGRect(x: 500, y: 50, width: 20, height: 20)), "Contents": .text("About Secretname")])))
    page1.addAnnotation(model.make(.dictionary(["Type": .name("Annot"), "Subtype": .name("Link"),
                                                "Rect": .rect(CGRect(x: 500, y: 740, width: 50, height: 20)),
                                                "A": .dictionary(["S": .name("URI"), "URI": .ascii("https://example.com")])])))
    page1.object.set("Thumb", model.makeStream(["Width": .integer(1), "Height": .integer(1), "ColorSpace": .name("DeviceGray"),
                                                "BitsPerComponent": .integer(8)], data: Data([0])))
    model.setOutlines([PDFOutlineItem(title: "Secretname chapter", destination: PDFDestination(page: 0))])
    model.setInfo("Title", "Quarterly report")
    model.setInfo("Author", "Agent Smith")
    model.addEmbeddedFile(Data("attached".utf8), name: "notes.txt")
    model.root.set("OpenAction", .dictionary(["S": .name("JavaScript"), "JS": .text("app.alert(1)")]))
    return try! model.data()
}

@MainActor
private func document(_ data: Data, name: String) -> DocumentHandle {
    let url = protectFile(name, data)
    return DocumentHandle(url: url, pdf: PDFDocument(url: url)!, undoManager: makeUndoManager())
}

// MARK: - Provider

@MainActor
private func protectProvider() {
    _ = protectSetUp()
    let providers = Services.toolProviders
    check(providers.count == 1, "ProtectKit appends one tool provider")
    let expected = ToolCatalog.tiles(ownedBy: .protectKit).map(\.id)
    check(Set(providers.first?.tools ?? []) == Set(expected) && expected.count == 5, "the provider serves the five Protect tiles")
    check(ToolCoverage.issues(providers, requireAll: false).isEmpty, "no coverage issues for the Protect tiles")
}

// MARK: - Find and mark

@MainActor
private func protectFindPatterns() {
    let service = protectSetUp()
    // A valid Aadhaar number: eleven digits and the Verhoeff check digit.
    let aadhaar = verhoeffComplete("23412341234")
    let data = Fixture.pdf([(Fixture.letter, { c in
        Fixture.text("Call +1 (555) 123-4567 or mail jane.doe@example.com today.", at: CGPoint(x: 72, y: 700), font: Fixture.body, in: c)
        Fixture.text("Card 4111 1111 1111 1111 and not 4111 1111 1111 1112.", at: CGPoint(x: 72, y: 680), font: Fixture.body, in: c)
        Fixture.text("SSN 123-45-6789 born 12 March 1990 and 2024-05-06.", at: CGPoint(x: 72, y: 660), font: Fixture.body, in: c)
        Fixture.text("IBAN GB82 WEST 1234 5698 7654 32, NI AB 12 34 56 C, Aadhaar \(aadhaar.prefix(4)) \(aadhaar.dropFirst(4).prefix(4)) \(aadhaar.suffix(4)).",
                     at: CGPoint(x: 72, y: 640), font: Fixture.body, in: c)
        Fixture.text("Contact Ada Lovelace about the Secret Plan.", at: CGPoint(x: 72, y: 620), font: Fixture.body, in: c)
    })])
    let doc = document(data, name: "patterns.pdf")
    service.contactNames = { ["Ada Lovelace", "Nobody Here"] }
    func found(_ query: RedactionQuery) -> [String] {
        protectRun("find \(query)") { try await service.find(query, in: doc, pages: [0]) }?.compactMap(\.text) ?? []
    }
    check(found(.pattern(.emails)) == ["jane.doe@example.com"], "emails: \(found(.pattern(.emails)))")
    check(found(.pattern(.cardNumbers)) == ["4111 1111 1111 1111"], "only the Luhn-valid card number: \(found(.pattern(.cardNumbers)))")
    check(found(.pattern(.socialSecurityNumbers)) == ["123-45-6789"], "social security numbers")
    let dates = found(.pattern(.dates))
    check(dates.contains("12 March 1990") && dates.contains("2024-05-06"), "dates: \(dates)")
    check(found(.pattern(.phoneNumbers)).contains { $0.contains("555") && $0.contains("4567") }, "phone numbers: \(found(.pattern(.phoneNumbers)))")
    check(found(.pattern(.iban)) == ["GB82 WEST 1234 5698 7654 32"], "IBANs: \(found(.pattern(.iban)))")
    check(found(.pattern(.ukNationalInsurance)) == ["AB 12 34 56 C"], "UK NI numbers: \(found(.pattern(.ukNationalInsurance)))")
    check(found(.pattern(.aadhaar)).count == 1, "Aadhaar numbers with a valid check digit: \(found(.pattern(.aadhaar)))")
    check(found(.pattern(.contactNames)) == ["Ada Lovelace"], "names from the address book")
    check(found(.text("secret plan", wholeWords: true, matchCase: false)) == ["Secret Plan"], "text, case-insensitive")
    check(found(.text("secret plan", wholeWords: true, matchCase: true)).isEmpty, "text, matching case")
    check(found(.words(["Lovelace", "today"])).count == 2, "a list of words")
    check(found(.regularExpression("jane\\.\\w+")) == ["jane.doe"], "a custom regular expression")
    let bad = complete(30) { try await service.find(.regularExpression("(unclosed"), in: doc, pages: [0]) }
    if case .failure(let error)? = bad { check((error as? ToolError) != nil, "a bad pattern explains itself") } else { check(false, "a bad pattern fails") }
    let marks = protectRun("marks") { try await service.find(.pattern(.emails), in: doc, pages: [0]) } ?? []
    let x = 72 + Fixture.textWidth("Call +1 (555) 123-4567 or mail ", font: Fixture.body)
    check(marks.count == 1 && abs((marks.first?.rect.minX ?? 0) - x) < 3 && abs((marks.first?.rect.midY ?? 0) - 703) < 6,
          "the mark sits on the match: \(marks.first?.rect ?? .zero) vs x \(x)")
}

private func verhoeffComplete(_ eleven: String) -> String {
    let d: [[Int]] = [[0,1,2,3,4,5,6,7,8,9],[1,2,3,4,0,6,7,8,9,5],[2,3,4,0,1,7,8,9,5,6],[3,4,0,1,2,8,9,5,6,7],[4,0,1,2,3,9,5,6,7,8],
                      [5,9,8,7,6,0,4,3,2,1],[6,5,9,8,7,1,0,4,3,2],[7,6,5,9,8,2,1,0,4,3],[8,7,6,5,9,3,2,1,0,4],[9,8,7,6,5,4,3,2,1,0]]
    let p: [[Int]] = [[0,1,2,3,4,5,6,7,8,9],[1,5,7,6,2,8,3,0,9,4],[5,8,0,3,7,9,6,1,4,2],[8,9,1,6,0,4,3,5,2,7],[9,4,5,3,1,2,6,8,7,0],
                      [4,2,8,6,5,7,3,9,0,1],[2,7,9,3,8,0,6,4,1,5],[7,0,4,6,9,1,3,2,5,8]]
    for check in 0...9 {
        var c = 0
        for (i, ch) in (eleven + "\(check)").reversed().enumerated() { c = d[c][p[i % 8][ch.wholeNumberValue!]] }
        if c == 0 { return eleven + "\(check)" }
    }
    return eleven + "0"
}

// MARK: - Black out

@MainActor
private func protectBlackOut() {
    let service = protectSetUp()
    let data = blackOutFixture()
    let doc = document(data, name: "blackout.pdf")
    let found = protectRun("find") { () async throws -> [RedactionMark] in
        try await service.find(.text("Secretname", wholeWords: true, matchCase: false), in: doc, pages: [0, 1])
            + service.find(.text("TOPSECRET42", wholeWords: false, matchCase: true), in: doc, pages: [0])
            + service.find(.pattern(.socialSecurityNumbers), in: doc, pages: [0])
    } ?? []
    check(found.count == 3, "found the name, the secret and the SSN: \(found.map { $0.text ?? "" })")
    let pictureMark = RedactionMark(page: 0, rect: CGRect(x: 295, y: 395, width: 35, height: 110))
    let vectorMark = RedactionMark(page: 0, rect: CGRect(x: 150, y: 240, width: 50, height: 120))
    let formMark = RedactionMark(page: 0, rect: CGRect(x: 70, y: 565, width: 130, height: 25))
    let marks = found + [pictureMark, vectorMark, formMark]

    let output = protectFile("blackout (blacked out).pdf")
    let report = protectRun("apply") {
        try await service.apply(marks, to: .file(doc.url!), options: RedactionOptions(removeHiddenInformation: false), destination: output,
                                progress: .ignored)
    }
    check(report?.verified == true, "the result checks out (render and text)")
    check(report?.items == 6 && report?.pages == 1, "six items on one page: \(String(describing: report))")
    guard let out = try? Data(contentsOf: output), let pdf = PDFDocument(data: out) else { check(false, "the output opens"); return }

    // Text: gone from extraction, neighbours stay, positions after a removed word are kept.
    let text = pdf.page(at: 0)?.string ?? ""
    for secret in ["Secretname", "TOPSECRET42", "123-45-6789", "FORMSECRET"] { check(!text.contains(secret), "\(secret) can't be extracted") }
    for kept in ["Name: John", "SSN", "Account", "done", "HIDDENOCR"] { check(text.contains(kept), "\(kept) is still there") }
    func boundsOf(_ word: String, in page: PDFKit.PDFPage?) -> CGRect {
        guard let page, let string = page.string, let range = string.range(of: word) else { return .null }
        return page.characterBounds(at: string.distance(from: string.startIndex, to: range.lowerBound))
    }
    let before = boundsOf("done", in: doc.pdf.page(at: 0)), after = boundsOf("done", in: pdf.page(at: 0))
    check(abs(before.minX - after.minX) < 0.5 && abs(before.minY - after.minY) < 0.5, "text after a removed word stays put: \(before) → \(after)")

    // Raw bytes: no object of the file holds the removed text (streams decoded).
    let bytes = decodedBytes(out)
    for secret in ["Secretname", "TOPSECRET42", "123-45-6789"] { check(!containsAnyForm(bytes, secret), "no raw bytes hold \(secret)") }
    check(bytes.contains("XXXXXXXXXX chapter") && bytes.contains("About XXXXXXXXXX"), "the bookmark and the other note no longer name it")
    // The form on page 1 was rewritten as a copy; page 2 keeps the original.
    if let model = try? PDFModel(data: out), let page1 = model.page(at: 0), let page2 = model.page(at: 1) {
        func formTexts(_ page: PDFModelKit.PDFPage) -> String {
            let names = ((try? page.contentStream())?.operations ?? []).filter { $0.operator == "Do" }.compactMap { $0.operands.first?.nameValue }
            return names.compactMap { page.resources?["XObject"]?[$0] }.filter { $0["Subtype"]?.name == "Form" }
                .compactMap { try? $0.streamData() }.map { String(decoding: $0, as: UTF8.self) }.joined()
        }
        check(!formTexts(page1).contains("FORMSECRET"), "page 1's form no longer holds the secret")
        check(formTexts(page2).contains("FORMSECRET"), "page 2's copy of the shared form is untouched")
        check(pdf.page(at: 1)?.string?.contains("FORMSECRET") == true, "page 2 still shows the form")
        // Picture: the samples under the mark are overwritten, the rest are as they were.
        if let picture = page1.imageXObjects().first(where: { $0.width == 100 }), let samples = try? picture.samples() {
            let px = { (x: Int, y: Int) -> [UInt8] in let i = (y * 100 + x) * 3; return Array(samples[i..<(i + 3)]) }
            check(px(5, 50) == [0, 0, 0] && px(25, 10) == [0, 0, 0], "picture pixels under the mark are gone")
            check(px(60, 50) == [255, 0, 0] && px(95, 95) == [255, 0, 0], "picture pixels outside the mark stay")
        } else {
            check(false, "the picture is still on page 1")
        }
        let annotations = page1.annotations.compactMap { $0["Contents"]?.text }
        check(!annotations.contains("Covered note"), "the note over a mark is gone")
    } else {
        check(false, "the output opens in QPDF")
    }

    // Render: boxes are black, the blue rectangle and green line survive outside the box.
    if let render = renderPixels(out, page: 0) {
        let blue = colour(render, 100, 325), boxed = colour(render, 175, 325), rightBlue = colour(render, 250, 325)
        check(blue.b > 200 && blue.r < 60, "the rectangle left of the box stays blue: \(blue)")
        check(rightBlue.b > 200 && rightBlue.r < 60, "the rectangle right of the box stays blue: \(rightBlue)")
        check(boxed.r < 30 && boxed.g < 30 && boxed.b < 30, "inside the box is black: \(boxed)")
        let line = colour(render, 350, 250)
        check(line.g > 150 && line.r < 80, "the line past the box stays green: \(line)")
    } else {
        check(false, "the output renders")
    }

    // With words over the boxes and hidden information removed.
    let second = protectFile("blackout words.pdf")
    let options = RedactionOptions(overlayText: "(b)(6)", fillColor: "#000000", removeHiddenInformation: true)
    let report2 = protectRun("apply with words") {
        try await service.apply(found, to: .file(doc.url!), options: options, destination: second, progress: .ignored)
    }
    check(report2?.verified == true, "verified with words over the boxes")
    if let out2 = try? Data(contentsOf: second), let model = try? PDFModel(data: out2), let pdf2 = PDFDocument(data: out2) {
        let text2 = pdf2.page(at: 0)?.string ?? ""
        check(text2.contains("(b)(6)"), "the exemption code is written over the boxes")
        check(!text2.contains("HIDDENOCR"), "hidden text went with the hidden information")
        check(model.info("Title") == nil && model.embeddedFiles().isEmpty && model.root["OpenAction"] == nil,
              "metadata, attachments and scripts went with the hidden information")
        check(model.page(at: 0)?.annotations.contains { $0["Subtype"]?.name == "Text" } == false, "comments went too")
    } else {
        check(false, "the second output opens")
    }

    // A file that limits changes needs its owner password.
    let model = try! PDFModel(data: data)
    let restricted = try! model.data(options: PDFWriteOptions(encryption: .encrypt(PDFEncryption(
        userPassword: "", ownerPassword: "owner", permissions: DocumentPermissions(pageChanges: false)))))
    let refused = complete(60) {
        try await service.apply(found, to: .data(restricted), options: RedactionOptions(), destination: protectFile("refused.pdf"), progress: .ignored)
    }
    if case .failure(let error)? = refused {
        check((error as? ToolError)?.message.text == Strings.Errors.ownerRestricted(.pageChanges), "restricted files explain the limit: \(error)")
    } else {
        check(false, "a file that limits changes is refused without its owner password")
    }
    check(protectRun("owner") {
        try await service.apply(found, to: .data(restricted, password: "owner"), options: RedactionOptions(), destination: protectFile("owner.pdf"),
                                progress: .ignored)
    }?.verified == true, "with the owner password it works")
}

@MainActor
private func protectBlackOutPanel() {
    _ = protectSetUp()
    let doc = document(blackOutFixture(), name: "panel.pdf")
    let provider = Services.toolProviders[0]
    let session = ToolSession(tool: .blackOut, provider: provider, document: doc)
    check(session.panel.archetype == .mode && !session.canRun, "Black out starts in hand mode with nothing to black out")
    session.set("marks", .strings(["0|295.00|395.00|35.00|110.00|", "0|150.00|240.00|50.00|120.00|"]))
    check(session.panel.primary.title == "Black out 2 items" && session.panel.primary.isDestructive && session.canRun, "hand marks count on the button")
    check(session.panel.confirmation?.message == Strings.Errors.redactConfirm(items: 2), "the confirmation names the count")

    session.set("mode", .string("find"))
    session.set("query", .string("Secretname"))
    _ = protectRun("preview") { await session.updatePreview() }
    check(session.panel.primary.title == "Black out 3 items", "found marks add to hand marks: \(session.panel.primary.title)")
    let notes = session.panel.controls.compactMap { if case .note(let text) = $0 { text } else { nil } }
    check(notes.contains("1 found on 1 page"), "the live count: \(notes)")
    guard case .checklist(let id, let items, _)? = session.panel.controls.first(where: { if case .checklist = $0 { true } else { false } }) else {
        check(false, "the results list"); return
    }
    check(items.count == 1 && items.first?.value == "p. 1", "a result row with its page")
    session.set(id, .strings([]))
    check(session.panel.primary.title == "Black out 2 items", "unticking a result leaves it out")
    session.set(id, .strings(items.map(\.id)))
    session.set("words", .bool(true))

    var saved: Data?
    session.onFinish = { result in if case .newFile(let url, _) = result { saved = try? Data(contentsOf: url) } }
    let result = protectRun("run") { await session.run() }
    guard case .newFile(_, let banner)?? = result, let out = saved, let pdf = PDFDocument(data: out) else { check(false, "Black out saves a file"); return }
    check(banner.text == "Blacked out 3 items on 1 page and saved “panel (blacked out).pdf”.", "the banner: \(banner.text)")
    check(!(pdf.page(at: 0)?.string ?? "").contains("Secretname") && (pdf.page(at: 0)?.string ?? "").contains("REDACTED"),
          "the found name is gone and REDACTED is written over it")
}

/// A scanned page (a picture of text, no text layer): Find and mark reads it with Vision, and the picture's pixels go.
@MainActor
private func protectBlackOutScan() {
    let service = protectSetUp()
    // Render the text into a bitmap, then make a page that only holds that picture.
    let width = 1200, height = 300
    let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0, space: CGColorSpaceCreateDeviceGray(),
                            bitmapInfo: CGImageAlphaInfo.none.rawValue)!
    context.setFillColor(gray: 1, alpha: 1)
    context.fill(CGRect(x: 0, y: 0, width: width, height: height))
    Fixture.text("Patient Zebediah Quartermaine visited", at: CGPoint(x: 40, y: 130), font: NSFont(name: "Helvetica", size: 60)!, in: context)
    let image = context.makeImage()!
    let data = Fixture.pdf([(Fixture.letter, { c in c.draw(image, in: CGRect(x: 36, y: 500, width: 540, height: 135)) })])
    let doc = document(data, name: "scan.pdf")
    let marks = protectRun("find in scan") { try await service.find(.text("Zebediah", wholeWords: true, matchCase: false), in: doc, pages: [0]) } ?? []
    check(marks.count == 1, "Vision finds the name on a page without text: \(marks.map(\.rect))")
    guard let mark = marks.first else { return }
    let output = protectFile("scan (blacked out).pdf")
    let report = protectRun("apply scan") {
        try await service.apply(marks, to: .file(doc.url!), options: RedactionOptions(removeHiddenInformation: false), destination: output, progress: .ignored)
    }
    check(report?.verified == true, "the scanned page checks out")
    guard let out = try? Data(contentsOf: output), let model = try? PDFModel(data: out), let picture = model.page(at: 0)?.imageXObjects().first,
          let samples = try? picture.samples() else { check(false, "the scanned picture is still there"); return }
    // Map the mark's centre into the picture's pixels: the picture fills (36, 500, 540 × 135).
    let px = Int((mark.rect.midX - 36) / 540 * CGFloat(picture.width)), py = Int((1 - (mark.rect.midY - 500) / 135) * CGFloat(picture.height))
    let components = samples.count / (picture.width * picture.height)
    let value = samples[(py * picture.width + px) * components]
    check(value == 0, "the picture's pixels under the name are overwritten (\(value))")
    let rescan = protectRun("rescan") {
        try await service.find(.text("Zebediah", wholeWords: true, matchCase: false), in: DocumentHandle(url: nil, pdf: PDFDocument(data: out)!), pages: [0])
    } ?? []
    check(rescan.isEmpty, "Vision can't read the name in the result")
}

// MARK: - Hidden information

@MainActor
private func protectHiddenInfo() {
    let service = protectSetUp()
    let data = blackOutFixture()
    let inventory = protectRun("inventory") { try await service.inventory(of: .data(data)) }
    let counts = inventory?.counts ?? [:]
    check(counts[.metadata] ?? 0 > 0 && counts[.comments] == 2 && counts[.links] == 1 && counts[.attachments] == 1, "inventory: \(counts)")
    check(counts[.bookmarks] == 1 && counts[.scripts] == 1 && counts[.thumbnails] == 1 && counts[.hiddenText] == 1, "inventory: \(counts)")
    check(counts[.overlappingObjects] ?? 0 > 0, "text under the opaque picture is found: \(counts)")

    let output = protectFile("hidden (clean).pdf")
    let kinds: Set<HiddenInfoKind> = Set(HiddenInfoKind.allCases).subtracting([.bookmarks, .links])
    guard protectRun("remove", { try await service.remove(kinds, from: .data(data), to: output) }) != nil,
          let out = try? Data(contentsOf: output), let model = try? PDFModel(data: out), let pdf = PDFDocument(data: out) else {
        check(false, "Remove hidden info writes a file"); return
    }
    let text = pdf.page(at: 0)?.string ?? ""
    check(!text.contains("HIDDENOCR") && !text.contains("UNDERIMAGE"), "hidden text and text under the picture are gone")
    check(text.contains("Secretname") && text.contains("Account"), "visible text stays")
    check(!decodedBytes(out).contains("HIDDENOCR"), "no bytes of the hidden text remain")
    check(model.info("Title") == nil && model.info("Author") == nil, "document info is gone")
    check(model.embeddedFiles().isEmpty && model.root["OpenAction"] == nil, "attachments and scripts are gone")
    check(model.outlines().count == 1, "bookmarks stay unless ticked")
    let annots = model.page(at: 0)?.annotations ?? []
    check(annots.count == 1 && annots.first?["Subtype"]?.name == "Link", "comments are gone, links stay")
    check(model.page(at: 0)?.object["Thumb"] == nil, "thumbnails are gone")
    let after = protectRun("inventory after") { try await service.inventory(of: .data(out)) }?.counts ?? [:]
    check(after[.hiddenText] == nil && after[.comments] == nil && after[.metadata] == nil && after[.unreferencedObjects] == nil,
          "a second look finds none of it: \(after)")

    // The panel: the findings as a checklist, bookmarks and links not ticked.
    let session = ToolSession(tool: .removeHiddenInfo, provider: Services.toolProviders[0], document: document(data, name: "Hidden.pdf"))
    check(!session.canRun, "Remove hidden info waits for its findings")
    _ = protectRun("inventory preview") { await session.updatePreview() }
    guard case .checklist(_, let items, let selected)? = session.panel.controls.first else { check(false, "the findings list"); return }
    check(items.contains { $0.title == "Comments" && $0.value == "2" } && items.contains { $0.title == "Hidden text (OCR layer)" },
          "findings with counts: \(items.map { "\($0.title) \($0.value ?? "")" })")
    check(!selected.contains("bookmarks") && !selected.contains("links") && selected.contains("metadata"), "all on except bookmarks and links")
    var saved: Data?
    session.onFinish = { result in if case .newFile(let url, _) = result { saved = try? Data(contentsOf: url) } }
    _ = protectRun("clean run") { await session.run() }
    check(saved.flatMap { try? PDFModel(data: $0) }.map { $0.info("Title") == nil && $0.outlines().count == 1 } == true, "Save clean copy")
}

// MARK: - Passwords

@MainActor
private func protectPasswords() {
    let service = protectSetUp()
    let source = PDFSource.data(makePDF(pages: 2))
    let output = protectFile("protected.pdf")
    let restricted = DocumentPermissions(printing: .lowResolution, copyingText: false, fillingFormsAndSigning: true, commenting: true,
                                         pageChanges: false, screenReaders: false)
    _ = protectRun("add") {
        try await service.addPassword(to: source, options: PasswordOptions(openPassword: "pa55word", permissionsPassword: "owner-pw",
                                                                           permissions: restricted), destination: output)
    }
    let data = (try? Data(contentsOf: output)) ?? Data()
    do {
        _ = try PDFModel(data: data)
        check(false, "the protected file needs its password")
    } catch {
        check((error as? PDFModelError) == .passwordRequired, "no password: \(error)")
    }
    if let user = try? PDFModel(data: data, password: "pa55word") {
        let p = user.permissions
        check(user.trailer["Encrypt"]?["R"]?.int == 6 && user.trailer["Encrypt"]?["V"]?.int == 5, "AES-256 (R6) by default")
        check(p.printing == .lowResolution && !p.copyingText && !p.pageChanges && p.commenting && p.fillingFormsAndSigning,
              "permission bits round-trip: \(p)")
        check(p.screenReaders, "screen readers are always allowed")
        check(!user.hasOwnerAccess, "the open password isn't the owner password")
    } else {
        check(false, "the open password opens it")
    }
    check((try? PDFModel(data: data, password: "owner-pw"))?.hasOwnerAccess == true, "the change password is the owner password")
    if let pdf = PDFDocument(data: data) {
        check(pdf.isLocked && pdf.unlock(withPassword: "pa55word") && !pdf.allowsCopying, "PDFKit opens it with the password and honours the limits")
    } else {
        check(false, "PDFKit reads the protected file")
    }

    // The permissions view (features #90) reads PDFKit.
    let ownerOnly = protectFile("owner-only.pdf")
    _ = protectRun("owner only") {
        try await service.addPassword(to: source, options: PasswordOptions(permissionsPassword: "boss", permissions: DocumentPermissions(printing: .none)),
                                      destination: ownerOnly)
    }
    if let pdf = PDFDocument(url: ownerOnly) {
        let handle = DocumentHandle(url: ownerOnly, pdf: pdf)
        let view = service.permissions(of: handle)
        check(view.printing == .none && view.copyingText, "the permissions view: \(view)")
    } else {
        check(false, "a file with only a change password opens without one")
    }

    // AES-128 for old readers, metadata left readable.
    let old = protectFile("old.pdf")
    _ = protectRun("aes128") {
        try await service.addPassword(to: source, options: PasswordOptions(openPassword: "abc", encryption: .aes128, keepMetadataReadable: true),
                                      destination: old)
    }
    let oldModel = try? PDFModel(data: (try? Data(contentsOf: old)) ?? Data(), password: "abc")
    check(oldModel?.trailer["Encrypt"]?["R"]?.int == 4 && oldModel?.trailer["Encrypt"]?["EncryptMetadata"]?.bool == false, "AES-128 (R4) when asked")

    // Remove password: the user password lifts it when nothing is limited; limits need the owner password.
    let unlocked = protectFile("no password.pdf")
    _ = protectRun("remove") { try await service.removePassword(from: .file(old, password: "abc"), destination: unlocked) }
    check((try? PDFModel(url: unlocked))?.isEncrypted == false, "the copy has no password")
    let refused = complete(60) { try await service.removePassword(from: .file(output, password: "pa55word"), destination: protectFile("nope.pdf")) }
    if case .failure(let error)? = refused {
        check((error as? ToolError)?.message.text == Strings.Errors.ownerRestricted(.printing), "limits need the owner password: \(error)")
    } else {
        check(false, "the open password alone can't lift the limits")
    }
    let wrong = complete(60) { try await service.removePassword(from: .file(output, password: "guess"), destination: protectFile("nope.pdf")) }
    if case .failure(let error)? = wrong { check((error as? ToolError)?.message.text == Strings.Errors.invalidPassword, "a wrong password") }
    else { check(false, "a wrong password fails") }
    let lifted = protectFile("lifted.pdf")
    _ = protectRun("remove owner") { try await service.removePassword(from: .file(output, password: "owner-pw"), destination: lifted) }
    let liftedModel = try? PDFModel(url: lifted)
    check(liftedModel?.isEncrypted == false && liftedModel?.permissions == .all, "the owner password lifts password and limits")
}

@MainActor
private func protectPasswordPanels() {
    _ = protectSetUp()
    let provider = Services.toolProviders[0]
    let doc = document(makePDF(pages: 1), name: "Report.pdf")
    let add = ToolSession(tool: .addPassword, provider: provider, document: doc)
    check(!add.canRun && add.panel.primary.title == "Save protected copy", "Add a password waits for a password")
    add.set("password", .string("Sesame-2026!"))
    check(!add.canRun, "and for it to be typed again")
    add.set("verify", .string("Sesame-2027!"))
    check(add.message?.text == "The two passwords don’t match." && !add.canRun, "a mismatch says so")
    add.set("verify", .string("Sesame-2026!"))
    check(add.canRun && add.message == nil, "matching passwords can run")
    check(add.panel.controls.contains { if case .custom(let id, _) = $0 { id.hasPrefix("strength.") } else { false } }, "a strength bar")
    add.set("password", .string("pässwörd")); add.set("verify", .string("pässwörd"))
    check(add.message?.text == "Some apps can’t open files with this password. Use only letters and numbers to be safe.", "non-ASCII passwords warn")
    add.set("password", .string("plain-pass")); add.set("verify", .string("plain-pass"))
    add.set("needChange", .bool(true))
    check(!add.canRun, "a change password is needed once asked for")
    add.set("changePassword", .string("boss-pass"))
    add.set("allowPrinting", .bool(false))
    var saved: URL?
    add.onFinish = { result in
        if case .newFile(let url, let banner) = result {
            saved = protectFile("panel protected.pdf"); try? FileManager.default.copyItem(at: url, to: saved!)
            check(banner.text == "Saved “Report (protected).pdf”. Keep the password somewhere safe.", "the banner: \(banner.text)")
        }
    }
    _ = protectRun("add run") { await add.run() }
    if let saved, let model = try? PDFModel(url: saved, password: "plain-pass") {
        check(model.permissions.printing == .none, "the panel's limits are written")
    } else {
        check(false, "Add a password saves a file")
    }

    // Remove password, on a file that only limits printing.
    guard let saved, let pdf = PDFDocument(url: saved), pdf.unlock(withPassword: "plain-pass") else { return }
    let locked = DocumentHandle(url: saved, pdf: pdf, state: DocumentState(isEncrypted: true), password: "plain-pass")
    let remove = ToolSession(tool: .removePassword, provider: provider, document: locked)
    let note = remove.panel.controls.compactMap { if case .note(let text) = $0 { text } else { nil } }.first
    check(note == "This file needs a password to open." && remove.canRun, "Remove password: \(String(describing: note))")
    remove.set("password", .string("boss-pass"))
    var removed: Data?
    remove.onFinish = { result in if case .newFile(let url, _) = result { removed = try? Data(contentsOf: url) } }
    _ = protectRun("remove run") { await remove.run() }
    check(removed.flatMap { try? PDFModel(data: $0) }?.isEncrypted == false, "the copy opens without a password")

    let plain = ToolSession(tool: .removePassword, provider: provider, document: doc)
    check(!plain.canRun && plain.panel.controls.contains { if case .note(let t) = $0 { t == "This file doesn’t have a password." } else { false } },
          "a file without a password says so")
}

@MainActor
private func protectEnvelope() {
    let service = protectSetUp()
    let first = protectFile("Contract.pdf", makePDF(pages: 3))
    let second = protectFile("photo.txt", Data("not really a photo".utf8))
    let output = protectFile("envelope.pdf")
    _ = protectRun("envelope") { try await service.makeEnvelope([first, second], password: "letmein", destination: output) }
    let data = (try? Data(contentsOf: output)) ?? Data()
    check((try? PDFModel(data: data)) == nil, "the envelope needs its password")
    guard let model = try? PDFModel(data: data, password: "letmein") else { check(false, "the envelope opens with the password"); return }
    let files = model.embeddedFiles().map(\.fileName).sorted()
    check(files == ["Contract.pdf", "photo.txt"], "it carries both files: \(files)")
    check((try? model.embeddedFileData(named: "Contract.pdf")) == (try? Data(contentsOf: first)), "byte for byte")
    check(model.root["PageMode"]?.name == "UseAttachments", "it opens on the attachments")
    if let pdf = PDFDocument(data: data), pdf.unlock(withPassword: "letmein") {
        check(pdf.page(at: 0)?.string?.contains("Contract.pdf") == true, "the cover lists the files")
    } else {
        check(false, "PDFKit opens the envelope with the password")
    }

    // Through Add a password's "Only attachments".
    let provider = Services.toolProviders[0]
    let doc = document(makePDF(pages: 1), name: "Letter.pdf")
    let session = ToolSession(tool: .addPassword, provider: provider, document: doc)
    session.set("password", .string("pw")); session.set("verify", .string("pw")); session.set("envelope", .bool(true))
    var saved: Data?
    session.onFinish = { result in if case .newFile(let url, _) = result { saved = try? Data(contentsOf: url) } }
    _ = protectRun("envelope panel") { await session.run() }
    check(saved.flatMap { try? PDFModel(data: $0, password: "pw") }?.embeddedFiles().map(\.fileName) == ["Letter.pdf"], "the document goes in the envelope")
}

// MARK: - Lock in notes & fields

@MainActor
private func protectLockIn() {
    let service = protectSetUp()
    let model = PDFModel()
    let page = try! model.addBlankPage(size: CGSize(width: 612, height: 792))
    let font = helvetica(model)
    page.setContentData(Data("BT /F0 12 Tf 72 740 Td (Form page) Tj ET".utf8))
    page.addResource(font, category: "Font", prefix: "F")
    let square = model.makeStream(["Type": .name("XObject"), "Subtype": .name("Form"), "BBox": .rect(CGRect(x: 0, y: 0, width: 100, height: 100))],
                                  data: Data("1 0 0 rg 0 0 100 100 re f".utf8))
    page.addAnnotation(model.make(.dictionary(["Type": .name("Annot"), "Subtype": .name("Square"),
                                               "Rect": .rect(CGRect(x: 100, y: 600, width: 100, height: 100)), "AP": .dictionary(["N": square.reference!])])))
    let fieldAppearance = model.makeStream(["Type": .name("XObject"), "Subtype": .name("Form"), "BBox": .rect(CGRect(x: 0, y: 0, width: 200, height: 30)),
                                            "Resources": .dictionary(["Font": .dictionary(["F0": font.reference!])])],
                                           data: Data("BT /F0 12 Tf 2 8 Td (FIELDVALUE) Tj ET".utf8))
    model.addField(.dictionary(["Type": .name("Annot"), "Subtype": .name("Widget"), "FT": .name("Tx"), "T": .text("name"), "V": .text("FIELDVALUE"),
                                "Rect": .rect(CGRect(x: 100, y: 500, width: 200, height: 30)), "AP": .dictionary(["N": fieldAppearance.reference!])]), on: page)
    model.addField(.dictionary(["Type": .name("Annot"), "Subtype": .name("Widget"), "FT": .name("Tx"), "T": .text("auto"), "V": .text("AUTOVALUE"),
                                "DA": .ascii("/F0 12 Tf 0 g"), "Rect": .rect(CGRect(x: 100, y: 450, width: 200, height: 30))]), on: page)
    model.ensureAcroForm().set("DR", .dictionary(["Font": .dictionary(["F0": font.reference!])]))
    model.ensureAcroForm().set("NeedAppearances", .bool(true))
    let data = try! model.data()

    let output = protectFile("form (locked in).pdf")
    _ = protectRun("flatten") { try await service.flatten(.data(data), options: FlattenOptions(), to: output) }
    guard let out = try? Data(contentsOf: output), let result = try? PDFModel(data: out), let pdf = PDFDocument(data: out) else {
        check(false, "Lock in writes a file"); return
    }
    check(result.page(at: 0)?.annotations.isEmpty == true && result.acroForm == nil, "notes, widgets and the form are gone")
    let text = pdf.page(at: 0)?.string ?? ""
    check(text.contains("FIELDVALUE") && text.contains("AUTOVALUE") && text.contains("Form page"), "field entries are part of the page: \(text)")
    if let render = renderPixels(out, page: 0) {
        let c = colour(render, 150, 650)
        check(c.r > 200 && c.g < 60, "the note's appearance is drawn where it was: \(c)")
    }

    let notesOnly = protectFile("notes only.pdf")
    _ = protectRun("notes only") { try await service.flatten(.data(data), options: FlattenOptions(annotations: true, formFields: false), to: notesOnly) }
    let notesModel = try? PDFModel(url: notesOnly)
    check(notesModel?.page(at: 0)?.annotations.count == 2 && notesModel?.acroForm != nil, "only notes: the fields stay")

    let pictures = protectFile("pictures.pdf")
    _ = protectRun("pictures") { try await service.flatten(.data(data), options: FlattenOptions(rasterizeDPI: 100), to: pictures) }
    let picturePDF = PDFDocument(url: pictures)
    check((picturePDF?.page(at: 0)?.string ?? "").trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, "pages into pictures: no text left")
    if let picturesData = try? Data(contentsOf: pictures), let render = renderPixels(picturesData, page: 0) {
        let c = colour(render, 150, 650)
        check(c.r > 200 && c.g < 60, "the picture still shows the note: \(c)")
    }

    // The panel.
    let provider = Services.toolProviders[0]
    let session = ToolSession(tool: .lockIn, provider: provider, document: document(data, name: "Form.pdf"))
    check(session.canRun && session.panel.primary.title == "Save locked-in copy", "Lock in is ready with its defaults")
    session.set("notes", .bool(false)); session.set("fields", .bool(false))
    check(!session.canRun, "nothing ticked, nothing to do")
}

// MARK: - Certificate encryption

@MainActor
private func protectCertificate() {
    let service = protectSetUp()
    guard let (privateKey, certificate) = makeTestCertificate() else { check(false, "a test certificate"); return }
    let model = PDFModel()
    let page = try! model.addBlankPage(size: CGSize(width: 612, height: 792))
    page.addResource(helvetica(model), category: "Font", prefix: "F")
    page.setContentData(Data("BT /F0 18 Tf 72 700 Td (Locked content) Tj ET".utf8))
    model.setInfo("Title", "Recipient only title")
    let output = protectFile("certificate.pdf")
    _ = protectRun("encrypt") { try await service.encrypt(.data(try! model.data()), forRecipients: [certificate], destination: output) }
    guard let data = try? Data(contentsOf: output) else { check(false, "certificate encryption writes a file"); return }
    let text = String(decoding: data.map { $0 }, as: Unicode.ASCII.self)
    check(text.contains("/Adobe.PubSec") && text.contains("/adbe.pkcs7.s5") && text.contains("/AESV3"), "public-key security, AES-256")
    check(!text.contains("Recipient only title"), "strings are encrypted")
    check(!(PDFDocument(data: data)?.page(at: 0)?.string ?? "").contains("Locked content"), "nothing reads it without the key")

    // Open it as the recipient: unwrap the seed with the private key, derive the file key, decrypt the page content.
    guard let range = text.range(of: "/Recipients\\s*\\[\\s*<([0-9a-f]+)>", options: .regularExpression),
          let hexStart = text[range].firstIndex(of: "<"), let hexEnd = text[range].lastIndex(of: ">") else { check(false, "recipients listed"); return }
    let recipient = Data(hex: String(text[text.index(after: hexStart)..<hexEnd]))
    guard let seed = openEnvelope(recipient, with: privateKey), seed.count == 24 else { check(false, "the recipient's key opens the envelope"); return }
    let key = Array(SHA256.hash(data: seed.prefix(20) + recipient))
    var plaintexts: [String] = []
    var cursor = data.startIndex
    while let start = data.range(of: Data("stream\n".utf8), in: cursor..<data.endIndex),
          let end = data.range(of: Data("\nendstream".utf8), in: start.upperBound..<data.endIndex) {
        let body = data[start.upperBound..<end.lowerBound]
        cursor = end.upperBound
        guard body.count > 16, let plain = aesDecrypt(Data(body.dropFirst(16)), key: key, iv: Array(body.prefix(16))) else { continue }
        // Flate: a two-byte zlib header and an Adler-32 around raw DEFLATE.
        let inflated = (try? (Data(plain.dropFirst(2).dropLast(4)) as NSData).decompressed(using: .zlib) as Data) ?? plain
        plaintexts.append(String(decoding: inflated.map { $0 }, as: Unicode.ASCII.self))
    }
    check(plaintexts.contains { $0.contains("(Locked content)") }, "the recipient reads the page content")
}

private extension Data {
    init(hex: String) {
        var bytes: [UInt8] = []
        var index = hex.startIndex
        while index < hex.endIndex, let next = hex.index(index, offsetBy: 2, limitedBy: hex.endIndex) {
            bytes.append(UInt8(hex[index..<next], radix: 16) ?? 0)
            index = next
        }
        self.init(bytes)
    }
}

private func aesDecrypt(_ data: Data, key: [UInt8], iv: [UInt8]) -> Data? {
    var out = [UInt8](repeating: 0, count: data.count + 16)
    var moved = 0
    let input = [UInt8](data)
    let status = CCCrypt(CCOperation(kCCDecrypt), CCAlgorithm(kCCAlgorithmAES), CCOptions(kCCOptionPKCS7Padding), key, key.count, iv,
                         input, input.count, &out, out.count, &moved)
    return status == kCCSuccess ? Data(out.prefix(moved)) : nil
}

/// DER for the test certificate and for reading the envelope back.
private enum TestDER {
    static func tlv(_ tag: UInt8, _ content: Data) -> Data {
        var length: [UInt8]
        if content.count < 0x80 { length = [UInt8(content.count)] } else {
            var bytes: [UInt8] = []
            var rest = content.count
            while rest > 0 { bytes.insert(UInt8(rest & 0xFF), at: 0); rest >>= 8 }
            length = [0x80 | UInt8(bytes.count)] + bytes
        }
        return Data([tag] + length) + content
    }
    static func seq(_ items: Data...) -> Data { tlv(0x30, items.reduce(Data(), +)) }
    static func oid(_ bytes: [UInt8]) -> Data { tlv(0x06, Data(bytes)) }
    static let rsaEncryption = oid([0x2A, 0x86, 0x48, 0x86, 0xF7, 0x0D, 0x01, 0x01, 0x01])
    static let sha256WithRSA = oid([0x2A, 0x86, 0x48, 0x86, 0xF7, 0x0D, 0x01, 0x01, 0x0B])

    /// The children of the constructed element at `offset`.
    static func children(_ bytes: [UInt8], _ offset: Int) -> [(tag: UInt8, start: Int, end: Int, offset: Int)] {
        guard let parent = element(bytes, offset) else { return [] }
        var result: [(UInt8, Int, Int, Int)] = []
        var cursor = parent.start
        while cursor < parent.end, let child = element(bytes, cursor) {
            result.append((child.tag, child.start, child.end, cursor))
            cursor = child.end
        }
        return result
    }
    static func element(_ bytes: [UInt8], _ offset: Int) -> (tag: UInt8, start: Int, end: Int)? {
        guard offset + 1 < bytes.count else { return nil }
        var i = offset + 1
        var count = Int(bytes[i]); i += 1
        if count & 0x80 != 0 {
            let n = count & 0x7F
            count = bytes[i..<(i + n)].reduce(0) { ($0 << 8) | Int($1) }
            i += n
        }
        return (bytes[offset], i, i + count)
    }
}

/// An in-memory RSA key and a self-signed certificate for it (nothing goes into the Keychain).
private func makeTestCertificate() -> (SecKey, Data)? {
    let attributes: [String: Any] = [kSecAttrKeyType as String: kSecAttrKeyTypeRSA, kSecAttrKeySizeInBits as String: 2048,
                                     kSecPrivateKeyAttrs as String: [kSecAttrIsPermanent as String: false]]
    guard let privateKey = SecKeyCreateRandomKey(attributes as CFDictionary, nil), let publicKey = SecKeyCopyPublicKey(privateKey),
          let publicBits = SecKeyCopyExternalRepresentation(publicKey, nil) as Data? else { return nil }
    let name = TestDER.seq(TestDER.tlv(0x31, TestDER.seq(TestDER.oid([0x55, 0x04, 0x03]), TestDER.tlv(0x0C, Data("Super PDF test".utf8)))))
    let algorithm = TestDER.seq(TestDER.sha256WithRSA, Data([0x05, 0x00]))
    let tbs = TestDER.seq(
        TestDER.tlv(0xA0, TestDER.tlv(0x02, Data([2]))),
        TestDER.tlv(0x02, Data([0x01, 0x23, 0x45])),
        algorithm, name,
        TestDER.seq(TestDER.tlv(0x17, Data("250101000000Z".utf8)), TestDER.tlv(0x17, Data("350101000000Z".utf8))),
        name,
        TestDER.seq(TestDER.seq(TestDER.rsaEncryption, Data([0x05, 0x00])), TestDER.tlv(0x03, Data([0]) + publicBits)))
    guard let signature = SecKeyCreateSignature(privateKey, .rsaSignatureMessagePKCS1v15SHA256, tbs as CFData, nil) as Data? else { return nil }
    let certificate = TestDER.seq(tbs, algorithm, TestDER.tlv(0x03, Data([0]) + signature))
    guard SecCertificateCreateWithData(nil, certificate as CFData) != nil else { return nil }
    return (privateKey, certificate)
}

/// The content of a CMS EnvelopedData for our RSA key (key transport, AES-256-CBC content).
private func openEnvelope(_ der: Data, with privateKey: SecKey) -> Data? {
    let bytes = [UInt8](der)
    let info = TestDER.children(bytes, 0)                          // contentType, [0]
    guard info.count == 2, let enveloped = TestDER.children(bytes, info[1].offset).first else { return nil }
    let parts = TestDER.children(bytes, enveloped.offset)          // version, recipientInfos, encryptedContentInfo
    guard parts.count == 3, let recipient = TestDER.children(bytes, parts[1].offset).first else { return nil }
    let fields = TestDER.children(bytes, recipient.offset)         // version, issuerAndSerial, algorithm, encryptedKey
    guard fields.count == 4 else { return nil }
    let wrapped = Data(bytes[fields[3].start..<fields[3].end])
    guard let contentKey = SecKeyCreateDecryptedData(privateKey, .rsaEncryptionPKCS1, wrapped as CFData, nil) as Data? else { return nil }
    let content = TestDER.children(bytes, parts[2].offset)         // contentType, algorithm, [0] encrypted
    guard content.count == 3 else { return nil }
    let algorithm = TestDER.children(bytes, content[1].offset)
    guard algorithm.count == 2 else { return nil }
    let iv = Array(bytes[algorithm[1].start..<algorithm[1].end])
    return aesDecrypt(Data(bytes[content[2].start..<content[2].end]), key: [UInt8](contentKey), iv: iv)
}
