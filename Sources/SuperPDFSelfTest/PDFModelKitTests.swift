import AppKit
import ImageIO
import PDFKit
import PDFModelKit
import SuperPDFCore
import UniformTypeIdentifiers

// PDFModelKit's checks (WP0c): a fixture corpus made here with Quartz (clean, damaged, encrypted, xref-stream,
// object-stream, linearized, signed), every operation saved and re-opened with QPDF and with PDFKit.
func registerPDFModelKitTests() {
    SelfTest.cases.append(("PDFModelKit.openAndSave", { pmkOpenAndSave() }))
    SelfTest.cases.append(("PDFModelKit.damaged", { pmkDamaged() }))
    SelfTest.cases.append(("PDFModelKit.encryption", { pmkEncryption() }))
    SelfTest.cases.append(("PDFModelKit.xrefAndObjectStreams", { pmkXrefAndObjectStreams() }))
    SelfTest.cases.append(("PDFModelKit.incremental", { pmkIncremental() }))
    SelfTest.cases.append(("PDFModelKit.objects", { pmkObjects() }))
    SelfTest.cases.append(("PDFModelKit.pageTree", { pmkPageTree() }))
    SelfTest.cases.append(("PDFModelKit.contentStream", { pmkContentStream() }))
    SelfTest.cases.append(("PDFModelKit.overlay", { pmkOverlay() }))
    SelfTest.cases.append(("PDFModelKit.images", { pmkImages() }))
    SelfTest.cases.append(("PDFModelKit.embeddedFiles", { pmkEmbeddedFiles() }))
    SelfTest.cases.append(("PDFModelKit.outlines", { pmkOutlines() }))
    SelfTest.cases.append(("PDFModelKit.pageLabels", { pmkPageLabels() }))
    SelfTest.cases.append(("PDFModelKit.trees", { pmkTrees() }))
    SelfTest.cases.append(("PDFModelKit.structureTree", { pmkStructureTree() }))
    SelfTest.cases.append(("PDFModelKit.acroForm", { pmkAcroForm() }))
    SelfTest.cases.append(("PDFModelKit.linearize", { pmkLinearize() }))
    SelfTest.cases.append(("PDFModelKit.signatures", { pmkSignatures() }))
}

// MARK: - Fixtures and helpers

/// A Quartz PDF whose pages each draw one line of text (and optionally an opaque RGB image on the first page).
private func pmkFixture(_ texts: [String], size: CGSize = CGSize(width: 612, height: 792), image: CGImage? = nil) -> Data {
    let data = NSMutableData()
    var box = CGRect(origin: .zero, size: size)
    guard let consumer = CGDataConsumer(data: data as CFMutableData),
          let context = CGContext(consumer: consumer, mediaBox: &box, nil) else { return Data() }
    for (i, text) in texts.enumerated() {
        context.beginPDFPage(nil)
        let line = CTLineCreateWithAttributedString(NSAttributedString(string: text, attributes: [.font: NSFont.systemFont(ofSize: 24)]))
        context.textPosition = CGPoint(x: 72, y: size.height - 96)
        CTLineDraw(line, context)
        if i == 0, let image { context.draw(image, in: CGRect(x: 72, y: 300, width: 200, height: 150)) }
        context.endPDFPage()
    }
    context.closePDF()
    return data as Data
}

private func pmkImage(width: Int, height: Int) -> CGImage {
    let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                            space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue)!
    context.setFillColor(CGColor(red: 0.9, green: 0.2, blue: 0.1, alpha: 1))
    context.fill(CGRect(x: 0, y: 0, width: width, height: height))
    context.setFillColor(CGColor(red: 0.1, green: 0.3, blue: 0.9, alpha: 1))
    context.fill(CGRect(x: 0, y: 0, width: width / 2, height: height / 2))
    return context.makeImage()!
}

private func pmkJPEG(_ image: CGImage) -> Data {
    let data = NSMutableData()
    let destination = CGImageDestinationCreateWithData(data as CFMutableData, UTType.jpeg.identifier as CFString, 1, nil)!
    CGImageDestinationAddImage(destination, image, [kCGImageDestinationLossyCompressionQuality: 0.8] as CFDictionary)
    CGImageDestinationFinalize(destination)
    return data as Data
}

/// Runs `body`, recording a failure (with `label`) when it throws.
@discardableResult
private func pmk<T>(_ label: String, file: String = #fileID, line: Int = #line, _ body: () throws -> T) -> T? {
    do { return try body() } catch {
        check(false, "\(label) threw \(error)", file: file, line: line)
        return nil
    }
}

private func pmkThrows(_ expected: PDFModelError, _ label: String, file: String = #fileID, line: Int = #line, _ body: () throws -> Void) {
    do {
        try body()
        check(false, "\(label) did not throw", file: file, line: line)
    } catch let error as PDFModelError {
        check(error == expected, "\(label) threw \(error), expected \(expected)", file: file, line: line)
    } catch {
        check(false, "\(label) threw \(error)", file: file, line: line)
    }
}

private func pdfKitText(_ data: Data, page: Int, password: String? = nil) -> String {
    guard let doc = PDFDocument(data: data) else { return "<unopenable>" }
    if let password { _ = doc.unlock(withPassword: password) }
    return doc.page(at: page)?.string ?? ""
}

private func pdfKitPageCount(_ data: Data, password: String? = nil) -> Int {
    guard let doc = PDFDocument(data: data) else { return -1 }
    if let password { _ = doc.unlock(withPassword: password) }
    return doc.isLocked ? -1 : doc.pageCount
}

private func contains(_ data: Data, _ text: String) -> Bool { data.range(of: Data(text.utf8)) != nil }

// MARK: - Cases

@MainActor
private func pmkOpenAndSave() {
    let fixture = pmkFixture(["Alpha", "Beta", "Gamma"])
    guard let model = pmk("open", { try PDFModel(data: fixture) }) else { return }
    check(model.pageCount == 3, "three pages")
    check(!model.isEncrypted && !model.wasRepaired && model.warnings.isEmpty, "clean file opens cleanly")
    check(model.version.hasPrefix("1."), "header version \(model.version)")
    check(model.permissions == .all && model.hasOwnerAccess, "unencrypted allows everything")
    check(model.root.isDictionary(ofType: "Catalog"), "catalog")
    check(model.check().isEmpty, "check finds nothing")
    model.setInfo("Title", "Résumé – draft")
    check(model.info("Title") == "Résumé – draft", "info round-trips in memory")
    guard let saved = pmk("save", { try model.data() }) else { return }
    check(pdfKitPageCount(saved) == 3, "PDFKit opens the saved file")
    check(pdfKitText(saved, page: 1).contains("Beta"), "page 2 keeps its text")
    check(PDFDocument(data: saved)?.documentAttributes?[PDFDocumentAttribute.titleAttribute] as? String == "Résumé – draft", "PDFKit reads the title")
    let url = scratch.appendingPathComponent("pmk-open.pdf")
    try? FileManager.default.createDirectory(at: scratch, withIntermediateDirectories: true)
    pmk("write to url") { try model.write(to: url) }
    check(PDFDocument(url: url)?.pageCount == 3, "file written to disk opens")
    check((try? PDFModel(.file(url)))?.pageCount == 3, "PDFSource.file opens")
}

@MainActor
private func pmkDamaged() {
    let clean = pmkFixture(["One", "Two", "Three"])
    var bytes = [UInt8](clean)
    // Break every cross-reference entry.
    if let xref = clean.range(of: Data("\nxref\n".utf8), options: .backwards) {
        for i in xref.upperBound..<min(xref.upperBound + 200, bytes.count) where bytes[i] >= 49 && bytes[i] <= 57 { bytes[i] = 57 }
    }
    let damaged = Data(bytes)
    pmkThrows(.damaged(""), "strict open of a damaged file") {
        do { _ = try PDFModel(data: damaged, attemptRecovery: false) } catch PDFModelError.damaged { throw PDFModelError.damaged("") }
    }
    guard let model = pmk("recovery open", { try PDFModel(data: damaged) }) else { return }
    check(model.wasRepaired && !model.warnings.isEmpty, "recovery is reported")
    check(model.pageCount == 3, "recovery finds the pages")
    check(!model.canSaveIncrementally, "no appended save onto a rebuilt file")
    pmkThrows(.incrementalUnavailable("rebuilt by recovery"), "incremental after recovery") { _ = try model.incrementalData() }
    guard let repaired = pmk("save repaired", { try model.data() }) else { return }
    check(pdfKitPageCount(repaired) == 3 && pdfKitText(repaired, page: 2).contains("Three"), "repaired file opens in PDFKit")
    check((try? PDFModel(data: repaired, attemptRecovery: false))?.wasRepaired == false, "the repaired file is sound")
    pmkThrows(.damaged(""), "garbage") {
        do { _ = try PDFModel(data: Data("not a pdf at all".utf8)) } catch PDFModelError.damaged { throw PDFModelError.damaged("") }
    }
}

@MainActor
private func pmkEncryption() {
    let fixture = pmkFixture(["Secret one", "Secret two"])
    guard let model = pmk("open", { try PDFModel(data: fixture) }) else { return }
    let restricted = DocumentPermissions(printing: .lowResolution, copyingText: false, fillingFormsAndSigning: true,
                                         commenting: false, pageChanges: false, screenReaders: true)
    let r6 = PDFEncryption(userPassword: "open sesame", ownerPassword: "the owner", permissions: restricted)
    guard let encrypted = pmk("encrypt R6", { try model.data(options: PDFWriteOptions(encryption: .encrypt(r6))) }) else { return }
    check(contains(encrypted, "/V 5") || contains(encrypted, "/V 5 "), "AES-256 security handler (V 5)")
    pmkThrows(.passwordRequired, "no password") { _ = try PDFModel(data: encrypted) }
    pmkThrows(.wrongPassword, "wrong password") { _ = try PDFModel(data: encrypted, password: "nope") }
    if let user = pmk("user password", { try PDFModel(data: encrypted, password: "open sesame") }) {
        check(user.isEncrypted && user.pageCount == 2, "opens with the user password")
        check(user.permissions == restricted, "permissions round-trip: \(user.permissions)")
        check(!user.hasOwnerAccess, "the user password is not the owner's")
    }
    if let owner = pmk("owner password", { try PDFModel(data: encrypted, password: "the owner") }) {
        check(owner.hasOwnerAccess && owner.permissions == restricted, "the owner password is recognised (R6)")
        if let plain = pmk("remove encryption", { try owner.data(options: PDFWriteOptions(encryption: .remove)) }) {
            check((try? PDFModel(data: plain))?.isEncrypted == false, "decrypted copy opens without a password")
            check(pdfKitText(plain, page: 0).contains("Secret one"), "decrypted copy keeps its text")
        }
    }
    let doc = PDFDocument(data: encrypted)
    check(doc?.isEncrypted == true && doc?.isLocked == true, "PDFKit sees a locked file")
    check(doc?.unlock(withPassword: "open sesame") == true && doc?.pageCount == 2, "PDFKit unlocks with the user password")
    check(doc?.allowsCopying == false, "PDFKit honours no copying")

    // Non-ASCII passwords: UTF-8 for R6, Latin-1 for R4.
    let umlaut = PDFEncryption(userPassword: "pässwörd", ownerPassword: "öwner", method: .aes256)
    if let data = pmk("R6 non-ASCII", { try model.data(options: PDFWriteOptions(encryption: .encrypt(umlaut))) }) {
        check((try? PDFModel(data: data, password: "pässwörd"))?.pageCount == 2, "R6 opens with a non-ASCII password")
        check((try? PDFModel(data: data, password: "öwner"))?.hasOwnerAccess == true, "non-ASCII owner password recognised")
    }
    var r4 = umlaut
    r4.method = .aes128
    if let data = pmk("R4 non-ASCII", { try model.data(options: PDFWriteOptions(encryption: .encrypt(r4))) }) {
        check(contains(data, "/V 4"), "AES-128 security handler (V 4)")
        check((try? PDFModel(data: data, password: "pässwörd"))?.pageCount == 2, "R4 opens with a Latin-1 password")
        check((try? PDFModel(data: data, password: "pässwörd"))?.hasOwnerAccess == false, "R4 user password is not the owner's")
        check((try? PDFModel(data: data, password: "öwner"))?.hasOwnerAccess == true, "R4 owner password recognised")
    }
    let openOnly = PDFEncryption(userPassword: "", ownerPassword: "boss", permissions: DocumentPermissions(printing: .none))
    if let data = pmk("owner-only", { try model.data(options: PDFWriteOptions(encryption: .encrypt(openOnly))) }) {
        let opened = try? PDFModel(data: data)
        check(opened?.isEncrypted == true && opened?.permissions.printing == DocumentPermissions.PrintingPermission.none,
              "an empty user password opens with restrictions")
        check(opened?.canSaveIncrementally == false, "no appended save onto an encrypted file")
        check(opened?.hasOwnerAccess == false && (try? PDFModel(data: data, password: "boss"))?.hasOwnerAccess == true, "owner access")
    }
}

@MainActor
private func pmkXrefAndObjectStreams() {
    guard let model = pmk("open", { try PDFModel(data: pmkFixture(["X1", "X2", "X3"])) }) else { return }
    guard let streams = pmk("generate object streams", { try model.data(options: PDFWriteOptions(objectStreams: .generate)) }) else { return }
    check(contains(streams, "/ObjStm"), "object streams written")
    check(contains(streams, "/XRef"), "cross-reference stream written")
    check(!contains(streams, "\nxref\n"), "no cross-reference table")
    check(pdfKitPageCount(streams) == 3, "PDFKit opens the object-stream file")
    guard let reopened = pmk("reopen", { try PDFModel(data: streams) }) else { return }
    check(reopened.pageCount == 3 && reopened.check().isEmpty, "QPDF reads it back cleanly")
    reopened.setInfo("Subject", "Streams")
    reopened.page(at: 2)?.setRotation(-90)
    guard let updated = pmk("append to an xref-stream file", { try reopened.incrementalData() }) else { return }
    check(updated.prefix(streams.count) == streams, "the original bytes are untouched")
    let tail = updated.suffix(from: streams.count)
    check(contains(Data(tail), "/Type/XRef") || contains(Data(tail), "/Type /XRef"), "the update ends in a cross-reference stream")
    check(!contains(Data(tail), "\nxref\n"), "no table appended to a stream file")
    let after = try? PDFModel(data: updated, attemptRecovery: false)
    check(after?.wasRepaired == false && after?.info("Subject") == "Streams", "the update reads back without recovery")
    check(after?.page(at: 2)?.rotation == 270, "rotation normalised to 270")
    check(PDFDocument(data: updated)?.page(at: 2)?.rotation == 270, "PDFKit sees the appended rotation")
    check(PDFRevisions.ends(in: updated).count == 2, "two revisions")
}

@MainActor
private func pmkIncremental() {
    let original = pmkFixture(["First", "Second"])
    guard let model = pmk("open", { try PDFModel(data: original) }) else { return }
    check(model.canSaveIncrementally, "a clean file takes appended saves")
    check(pmk("unchanged", { try model.incrementalData() }) == original, "nothing changed: the original bytes")
    model.setInfo("Title", "Appended")
    model.page(at: 1)?.setRotation(90)
    guard let updated = pmk("append", { try model.incrementalData() }) else { return }
    check(updated.count > original.count && updated.prefix(original.count) == original, "appended after the original bytes")
    check(contains(Data(updated.suffix(from: original.count)), "\nxref\n"), "a table update for a table file")
    let after = try? PDFModel(data: updated, attemptRecovery: false)
    check(after?.wasRepaired == false && after?.check().isEmpty == true, "the update is sound")
    check(after?.info("Title") == "Appended" && after?.page(at: 1)?.rotation == 90, "changes read back")
    let pdf = PDFDocument(data: updated)
    check(pdf?.page(at: 1)?.rotation == 90 && pdf?.pageCount == 2, "PDFKit sees the appended change")
    check(PDFRevisions.ends(in: updated) == [original.count, updated.count], "revision ends: \(PDFRevisions.ends(in: updated))")
    if let changes = pmk("changes", { try PDFRevisions.changes(in: updated, since: original.count) }) {
        check(changes.contains { $0.type == "Page" && $0.kind == .modified }, "the rotated page is a modified object")
        check(changes.allSatisfy { $0.kind != .removed }, "nothing removed")
    }
    // A second update on top of the first.
    guard let second = try? PDFModel(data: updated) else { check(false, "reopen"); return }
    second.page(at: 0)?.setBox(.crop, CGRect(x: 36, y: 36, width: 540, height: 720))
    if let twice = pmk("second append", { try second.incrementalData() }) {
        check(PDFRevisions.ends(in: twice).count == 3, "three revisions")
        check(PDFDocument(data: twice)?.page(at: 0)?.bounds(for: .cropBox) == CGRect(x: 36, y: 36, width: 540, height: 720), "PDFKit reads the crop box")
    }
    pmkThrows(.incrementalUnavailable("new document"), "new document") { _ = try PDFModel().incrementalData() }
}

@MainActor
private func pmkObjects() {
    guard let model = pmk("open", { try PDFModel(data: pmkFixture(["Objects"])) }) else { return }
    let value: PDFValue = .dictionary([
        "Bool": .bool(true),
        "Int": .integer(-42),
        "Real": .real(3.25),
        "Name": .name("A B#C/D"),
        "Bytes": .string(Data([0, 1, 2, 0xFF, 0x28])),
        "Text": .text("naïve ☃"),
        "Array": .array([.integer(1), .null, .name("X"), .array([])]),
        "Nested": .dictionary(["Deep": .string(Data("(paren) \\ back".utf8))]),
    ])
    let indirect = model.makeIndirect(value)
    model.root.set("SPTest", indirect)
    check(indirect.isIndirect && indirect.objectID != nil, "indirect object")
    check(model.root["SPTest"]?.isSameObject(as: indirect) == true, "the catalog refers to it")
    let expected = value.dictionaryValue!
    check(indirect.value == value, "value round-trips in memory: \(indirect.value)")
    check(indirect["Text"]?.text == "naïve ☃", "text decodes")
    check(indirect["Name"]?.name == "A B#C/D", "name keeps its characters")
    check(indirect["Real"]?.number == 3.25 && indirect["Int"]?.int == -42, "numbers")
    check(indirect.keys.sorted() == expected.keys.sorted(), "keys")
    indirect["Array"]?.append(.integer(9))
    indirect["Array"]?.insert(.integer(0), at: 0)
    indirect["Array"]?.removeItem(at: 2)
    check(indirect["Array"]?.value == .array([.integer(0), .integer(1), .name("X"), .array([]), .integer(9)]), "array edits")
    indirect.remove("Bool")
    check(!indirect.has("Bool"), "remove key")
    let stream = model.makeStream(["Type": .name("SPData")], data: Data("hello stream".utf8))
    model.root.set("SPStream", stream)
    for options in [PDFWriteOptions(), PDFWriteOptions(objectStreams: .generate)] {
        guard let saved = pmk("save", { try model.data(options: options) }), let back = try? PDFModel(data: saved) else { continue }
        let reread = back.root["SPTest"]
        check(reread?["Bytes"]?.stringData == Data([0, 1, 2, 0xFF, 0x28]), "binary string survives a save")
        check(reread?["Name"]?.name == "A B#C/D" && reread?["Text"]?.text == "naïve ☃", "name and text survive a save")
        check(reread?["Nested"]?["Deep"]?.stringData == Data("(paren) \\ back".utf8), "escaped literal survives")
        check((try? back.root["SPStream"]?.streamData()) == Data("hello stream".utf8), "stream data survives")
        check(back.root["SPStream"]?["Type"]?.name == "SPData", "stream dictionary survives")
        check(pdfKitPageCount(saved) == 1, "PDFKit opens it")
    }
    // The serializer's own syntax parses back through QPDF.
    let serialized = String(decoding: value.serialized(), as: UTF8.self)
    check(serialized.contains("/A#20B#23C#2FD") && serialized.contains("<000102ff28>"), "serializer escapes: \(serialized)")
    check(PDFContentStream(parsing: value.serialized() + Data(" X".utf8)).operations.first?.operands == [value],
          "the content parser reads the serializer's output")
    check(PDFValue.number(2.0) == .integer(2) && PDFValue.number(0.5) == .real(0.5), "number picks integer or real")
    check(PDFDate.date("D:20240131235959+05'30'") == ISO8601DateFormatter().date(from: "2024-01-31T23:59:59+05:30"), "PDF date parses")
    let now = Date(timeIntervalSince1970: 1_700_000_000)
    check(PDFDate.date(PDFDate.string(now)) == now, "PDF date round-trips")
    check(PDFText.decode(Data([0x80, 0x41, 0xA0])) == "•A€", "PDFDocEncoding decodes")
}

@MainActor
private func pmkPageTree() {
    guard let a = pmk("open A", { try PDFModel(data: pmkFixture(["A1", "A2", "A3"])) }),
          let b = pmk("open B", { try PDFModel(data: pmkFixture(["B1", "B2"], size: CGSize(width: 400, height: 300))) }) else { return }
    pmk("insert from B") { try a.insertPages(from: b, pages: [1, 0], at: 1) }          // A1 B2 B1 A2 A3
    check(a.pageCount == 5, "five pages after inserting two")
    pmk("remove") { try a.removePage(at: 4) }                                            // A1 B2 B1 A2
    pmk("move") { try a.movePage(from: 0, to: 3) }                                       // B2 B1 A2 A1
    if let page = a.page(at: 1) { pmk("duplicate") { try a.insertPage(page, at: 2) } }   // B2 B1 B1 A2 A1
    let blank = pmk("blank") { try a.addBlankPage(size: CGSize(width: 200, height: 100), at: 0) }  // _ B2 B1 B1 A2 A1
    check(blank?.index == 0 && blank?.box(.media).size == CGSize(width: 200, height: 100), "blank page at the front")
    check(a.page(at: 2)?.object.isSameObject(as: a.page(at: 3)!.object) == false, "a duplicate is its own object")
    a.page(at: 4)?.setRotation(450)
    a.page(at: 5)?.setBox(.crop, CGRect(x: 10, y: 20, width: 500, height: 760))
    check(a.page(at: 4)?.rotation == 90 && a.page(at: 4)?.displaySize == CGSize(width: 792, height: 612), "rotation and shown size")
    check(a.page(at: 5)?.box(.trim) == CGRect(x: 10, y: 20, width: 500, height: 760), "trim box defaults to the crop box")
    pmkThrows(.invalidOperation("page index 9 of 6"), "out of range") { _ = try a.insertPage(a.page(at: 0)!, at: 9) }
    guard let saved = pmk("save", { try a.data() }), let pdf = PDFDocument(data: saved) else { return }
    let texts = (0..<pdf.pageCount).map { pdf.page(at: $0)?.string ?? "" }
    check(pdf.pageCount == 6, "PDFKit sees six pages")
    check(texts[1].contains("B2") && texts[2].contains("B1") && texts[3].contains("B1") && texts[4].contains("A2") && texts[5].contains("A1"),
          "page order: \(texts)")
    check(pdf.page(at: 1)?.bounds(for: .mediaBox).size == CGSize(width: 400, height: 300), "B's size travels with its page")
    check(pdf.page(at: 4)?.rotation == 90, "PDFKit sees the rotation")
    check(pdf.page(at: 5)?.bounds(for: .cropBox) == CGRect(x: 10, y: 20, width: 500, height: 760), "PDFKit sees the crop box")
    check((try? PDFModel(data: saved))?.check().isEmpty == true, "QPDF finds the result sound")
}

@MainActor
private func pmkContentStream() {
    let source = """
        % a comment
        q 1 0 0 1 72.5 -.5 cm /F1 12 Tf (Hello \\(world\\)\\n\\101) Tj <48656C6C6F> Tj [(A) -120 (B)] TJ
        /Span <</ActualText (x) /MCID 3>> BDC /P#20Q BMC EMC EMC
        BI /W 4 /H 1 /CS /G /BPC 8 ID \u{01}EI\u{02} EI Q
        true false null 0 d
        """
    let parsed = PDFContentStream(parsing: Data(source.utf8))
    let ops = parsed.operations.map(\.operator)
    check(ops == ["q", "cm", "Tf", "Tj", "Tj", "TJ", "BDC", "BMC", "EMC", "EMC", "BI", "Q", "d"], "operators: \(ops)")
    check(parsed.operations[1].operands == [.integer(1), .integer(0), .integer(0), .integer(1), .real(72.5), .real(-0.5)], "numbers")
    check(parsed.operations[3].operands == [.string(Data("Hello (world)\nA".utf8))], "literal string escapes")
    check(parsed.operations[4].operands == [.string(Data("Hello".utf8))], "hex string")
    check(parsed.operations[5].operands == [.array([.string(Data("A".utf8)), .integer(-120), .string(Data("B".utf8))])], "TJ array")
    check(parsed.operations[7].operands == [.name("P Q")], "name escapes")
    check(parsed.operations[10].inlineImageData == Data([1, 0x45, 0x49, 2]), "inline image data with EI bytes inside")
    let spans = parsed.markedContent
    check(spans.count == 2 && spans[0].tag == "Span" && spans[0].mcid == 3 && spans[0].range == 6...9 && spans[1].depth == 1, "marked content: \(spans)")
    let reparsed = PDFContentStream(parsing: parsed.serialized())
    check(reparsed == parsed, "serialize → parse round-trips")
    var trimmed = parsed
    check(trimmed.removeMarkedContent { $0.tag == "Span" } == 1 && !trimmed.operations.contains { $0.operator == "BDC" }, "remove a span")

    guard let model = pmk("open", { try PDFModel(data: pmkFixture(["Tagged words", "Untouched"])) }),
          let page = model.page(at: 0), var content = pmk("parse page", { try page.contentStream() }) else { return }
    check(!content.operations.isEmpty, "page content parses")
    content.operations = PDFContentStream.markedContent(content.operations, tag: "P", properties: .dictionary(["MCID": .integer(0)]))
    page.setContentStream(content)
    guard let saved = pmk("save", { try model.data() }) else { return }
    check(pdfKitText(saved, page: 0).contains("Tagged words"), "rewritten content keeps its text")
    guard let back = try? PDFModel(data: saved), let backPage = back.page(at: 0) else { return }
    check((try? backPage.contentStream().markedContent.first?.mcid) == 0, "the MCID is in the saved content")
    check(pmk("remove") { try back.removeMarkedContent(on: backPage) { $0.tag == "P" } } == 1, "one span removed")
    if let removed = pmk("save removed", { try back.data() }) {
        check(!pdfKitText(removed, page: 0).contains("Tagged"), "removed content is gone in PDFKit")
        check(pdfKitText(removed, page: 1).contains("Untouched"), "other pages untouched")
    }
}

@MainActor
private func pmkOverlay() {
    guard let model = pmk("open", { try PDFModel(data: pmkFixture(["Body one", "Body two"])) }),
          let stamp = pmk("open stamp", { try PDFModel(data: pmkFixture(["Watermark text"], size: CGSize(width: 300, height: 200))) }),
          let rotated = pmk("open rotated", { try PDFModel(data: pmkFixture(["Sideways"])) }) else { return }
    rotated.page(at: 0)?.setRotation(90)
    guard let page0 = model.page(at: 0), let page1 = model.page(at: 1), let stampPage = stamp.page(at: 0) else { return }
    let name = pmk("overlay") { try model.overlay(stampPage, on: page0, tag: .artifact(subtype: "Watermark")) }
    check(name == "Fx0", "resource name \(name ?? "nil")")
    pmk("underlay") { try model.overlay(stampPage, on: page1, layer: .under, tag: PDFMarkedContentTag("SPBackground")) }
    if let form = pmk("form from a rotated page", { try model.formXObject(from: rotated.page(at: 0)!) }) {
        check(model.formBounds(form).size == CGSize(width: 792, height: 612), "a rotated page's form is shown upright: \(model.formBounds(form))")
        pmk("place") { try model.place(form, on: page1, in: CGRect(x: 0, y: 0, width: 200, height: 200)) }
    }
    check(model.formBounds(model.page(at: 0)!.resources!["XObject"]!["Fx0"]!).size == CGSize(width: 300, height: 200), "form keeps its page's size")
    guard let saved = pmk("save", { try model.data() }) else { return }
    let first = pdfKitText(saved, page: 0), second = pdfKitText(saved, page: 1)
    check(first.contains("Body one") && first.contains("Watermark text"), "overlay text shows: \(first)")
    check(second.contains("Body two") && second.contains("Watermark text") && second.contains("Sideways"), "underlay and placement show: \(second)")
    guard let back = try? PDFModel(data: saved), let backPage = back.page(at: 0) else { return }
    let removed = pmk("remove watermark") {
        try back.removeMarkedContent(on: backPage) { $0.tag == "Artifact" && $0.properties?["Subtype"] == .name("Watermark") }
    }
    check(removed == 1, "the tagged overlay is found again")
    if let clean = pmk("save clean", { try back.data() }) {
        check(!pdfKitText(clean, page: 0).contains("Watermark") && pdfKitText(clean, page: 0).contains("Body one"), "watermark removed, body kept")
        check(pdfKitText(clean, page: 1).contains("Watermark text"), "the other page's background stays")
    }
}

@MainActor
private func pmkImages() {
    let image = pmkImage(width: 40, height: 30)
    guard let model = pmk("open", { try PDFModel(data: pmkFixture(["Picture"], image: image)) }), let page = model.page(at: 0) else { return }
    let images = page.imageXObjects()
    check(images.count == 1, "one image XObject (\(images.count))")
    guard let found = images.first else { return }
    check(found.width == 40 && found.height == 30 && found.bitsPerComponent == 8, "geometry \(found.width)×\(found.height)")
    if let samples = pmk("samples", { try found.samples() }) {
        let components = samples.count / (40 * 30)
        check(samples.count == 40 * 30 * components && components >= 1, "decoded samples (\(samples.count) bytes)")
    }
    let replacement = pmkImage(width: 20, height: 16)
    pmk("replace with JPEG") {
        try model.replaceImage(found.object, with: .jpeg(pmkJPEG(replacement)), width: 20, height: 16, colorSpace: .name("DeviceRGB"))
    }
    guard let saved = pmk("save", { try model.data() }), let back = try? PDFModel(data: saved),
          let again = back.page(at: 0)?.imageXObjects().first else { return }
    check(again.width == 20 && again.height == 16 && again.filters == ["DCTDecode"], "JPEG replacement reads back")
    check((try? again.encodedData().prefix(2)) == Data([0xFF, 0xD8]), "DCT data is a JPEG file")
    check((try? again.samples().count) == 20 * 16 * 3, "the JPEG decodes to RGB samples")
    let pdf = PDFDocument(data: saved)
    check(pdf?.page(at: 0)?.thumbnail(of: CGSize(width: 100, height: 100), for: .mediaBox).size.width ?? 0 > 0, "PDFKit draws the page")
    pmk("replace with samples") {
        try back.replaceImage(again.object, with: .samples(Data(repeating: 0x80, count: 10 * 10)), width: 10, height: 10, colorSpace: .name("DeviceGray"))
    }
    if let gray = pmk("save gray", { try back.data() }), let grayImage = (try? PDFModel(data: gray))?.page(at: 0)?.imageXObjects().first {
        check(grayImage.colorSpace == .name("DeviceGray") && grayImage.filters == ["FlateDecode"], "Flate samples read back")
        check((try? grayImage.samples()) == Data(repeating: 0x80, count: 100), "samples round-trip")
        check(pdfKitPageCount(gray) == 1, "PDFKit opens it")
    }
}

@MainActor
private func pmkEmbeddedFiles() {
    guard let model = pmk("open", { try PDFModel(data: pmkFixture(["Attachments"])) }) else { return }
    let csv = Data("a,b\n1,2\n".utf8), notes = Data(repeating: 0x41, count: 5000)
    let date = Date(timeIntervalSince1970: 1_700_000_000)
    model.addEmbeddedFile(csv, name: "data.csv", mimeType: "text/csv", description: "Figures", modificationDate: date, relationship: "Data")
    model.addEmbeddedFile(notes, name: "notes – é.txt", mimeType: "text/plain")
    model.addEmbeddedFile(Data("old".utf8), name: "gone.txt")
    check(model.removeEmbeddedFile(named: "gone.txt") && !model.removeEmbeddedFile(named: "gone.txt"), "remove once")
    guard let saved = pmk("save", { try model.data() }), let back = try? PDFModel(data: saved) else { return }
    let files = back.embeddedFiles()
    check(files.map(\.name) == ["data.csv", "notes – é.txt"], "names in tree order: \(files.map(\.name))")
    check(files.first?.mimeType == "text/csv" && files.first?.description == "Figures" && files.first?.size == csv.count, "metadata")
    check(files.first?.modificationDate == date && files.first?.relationship == "Data", "date and relationship")
    check((try? back.embeddedFileData(named: "data.csv")) == csv, "csv bytes")
    check((try? back.embeddedFileData(named: "notes – é.txt")) == notes, "compressed bytes")
    check(back.root["AF"]?.count == 1, "associated file listed")
    check(pdfKitPageCount(saved) == 1, "PDFKit opens it")
    check(back.removeEmbeddedFile(named: "data.csv") && back.root["AF"] == nil, "removing drops the /AF entry")
}

@MainActor
private func pmkOutlines() {
    guard let model = pmk("open", { try PDFModel(data: pmkFixture(["One", "Two", "Three"])) }) else { return }
    let tree = [
        PDFOutlineItem(title: "Introduction", destination: PDFDestination(page: 0, view: .xyz(left: 0, top: 792, zoom: nil)), isOpen: true, children: [
            PDFOutlineItem(title: "Background – ü", destination: PDFDestination(page: 1, view: .fitH(top: 500))),
        ]),
        PDFOutlineItem(title: "Website", uri: "https://example.com", flags: 2),
        PDFOutlineItem(title: "End", destination: PDFDestination(page: 2), color: [1, 0, 0], children: [
            PDFOutlineItem(title: "Hidden child", destination: PDFDestination(page: 2, view: .fitR(CGRect(x: 10, y: 10, width: 100, height: 50)))),
        ]),
    ]
    model.setOutlines(tree)
    check(model.outlines() == tree, "outlines round-trip in memory")
    guard let saved = pmk("save", { try model.data() }), let back = try? PDFModel(data: saved) else { return }
    check(back.outlines() == tree, "outlines round-trip through a save: \(back.outlines())")
    check(back.root["Outlines"]?["Count"]?.int == 4, "visible count")
    // The outline holds its document weakly: keep the document alive while reading it.
    guard let document = PDFDocument(data: saved), let root = document.outlineRoot else { check(false, "PDFKit outline"); return }
    check(root.numberOfChildren == 3 && root.child(at: 0)?.label == "Introduction" && root.child(at: 0)?.child(at: 0)?.label == "Background – ü",
          "PDFKit reads the titles")
    check(root.child(at: 2)?.destination?.page.map(document.index(for:)) == 2, "PDFKit resolves the destination")
    model.setOutlines([])
    check(model.root["Outlines"] == nil, "empty list removes the outlines")
}

@MainActor
private func pmkPageLabels() {
    guard let model = pmk("open", { try PDFModel(data: pmkFixture(["1", "2", "3", "4", "5", "6"])) }) else { return }
    let ranges = [
        PDFPageLabelRange(startPage: 0, style: .lowerRoman),
        PDFPageLabelRange(startPage: 2, style: .decimal, prefix: "A-"),
        PDFPageLabelRange(startPage: 5, style: .upperLetters, firstNumber: 27),
    ]
    model.setPageLabels(ranges)
    let expected = ["i", "ii", "A-1", "A-2", "A-3", "AA"]
    check((0..<6).map { model.pageLabel(at: $0) ?? "" } == expected, "labels: \((0..<6).map { model.pageLabel(at: $0) ?? "" })")
    guard let saved = pmk("save", { try model.data() }) else { return }
    check((try? PDFModel(data: saved))?.pageLabels() == ranges, "ranges round-trip")
    if let pdf = PDFDocument(data: saved) {
        check((0..<6).map { pdf.page(at: $0)?.label ?? "" } == expected, "PDFKit shows the labels: \((0..<6).map { pdf.page(at: $0)?.label ?? "" })")
    }
    model.setPageLabels([PDFPageLabelRange(startPage: 3, style: .upperRoman, firstNumber: 4)])
    check(model.pageLabels().first?.startPage == 0 && model.pageLabel(at: 3) == "IV", "a range covering page 0 is added")
    check(PDFPageLabelRange(startPage: 0, style: .upperRoman, firstNumber: 1994).label(forPage: 0) == "MCMXCIV"
          && PDFPageLabelRange(startPage: 0, style: .lowerLetters, firstNumber: 53).label(forPage: 0) == "aaa", "numbering styles")
}

@MainActor
private func pmkTrees() {
    let model = PDFModel()
    // A two-level name tree as other writers make them.
    let leaf1 = model.makeIndirect(.dictionary(["Names": .array([.ascii("apple"), .integer(1), .ascii("banana"), .integer(2)]),
                                                "Limits": .array([.ascii("apple"), .ascii("banana")])]))
    let leaf2 = model.makeIndirect(.dictionary(["Names": .array([.ascii("cherry"), .integer(3)]),
                                                "Limits": .array([.ascii("cherry"), .ascii("cherry")])]))
    let tree = model.make(.dictionary(["Kids": .array([leaf1.reference!, leaf2.reference!])]))
    let entries = PDFNameTree.entries(of: tree)
    check(entries.map { String(decoding: $0.key, as: UTF8.self) } == ["apple", "banana", "cherry"], "name tree in order")
    check(PDFNameTree.value(for: Data("cherry".utf8), in: tree)?.int == 3, "lookup through kids")
    let flat = PDFNameTree.make(in: model, entries: entries.reversed())
    check(PDFNameTree.entries(of: flat).map(\.value).compactMap(\.int) == [1, 2, 3], "a written tree is sorted")
    let numbers = PDFNumberTree.make(in: model, entries: [(5, model.make(.ascii("five"))), (1, model.make(.ascii("one")))])
    check(PDFNumberTree.entries(of: numbers).map(\.key) == [1, 5], "number tree sorted")
    // A loop in /Kids does not hang.
    leaf2.set("Kids", .array([leaf2.reference!]))
    check(PDFNameTree.entries(of: tree).count == 3, "cycles are cut")
}

@MainActor
private func pmkStructureTree() {
    guard let model = pmk("open", { try PDFModel(data: pmkFixture(["Heading text", "Figure page"])) }) else { return }
    for (i, page) in model.pages.enumerated() {
        guard var content = pmk("parse", { try page.contentStream() }) else { return }
        content.operations = PDFContentStream.markedContent(content.operations, tag: i == 0 ? "H1" : "Figure", properties: .dictionary(["MCID": .integer(0)]))
        page.setContentStream(content)
    }
    let link = model.page(at: 1)!.addAnnotation(model.make(.dictionary([
        "Type": .name("Annot"), "Subtype": .name("Link"), "Rect": .rect(CGRect(x: 10, y: 10, width: 50, height: 20)),
        "A": .dictionary(["S": .name("URI"), "URI": .ascii("https://example.com")]),
    ])))
    let tree = PDFStructureTree(roleMap: ["Title": "H1"], elements: [
        PDFStructureElement(type: "Document", language: "en-GB", kids: [
            .element(PDFStructureElement(type: "H1", title: "Top", page: 0, kids: [.markedContent(page: 0, mcid: 0)])),
            .element(PDFStructureElement(type: "Figure", alternateText: "A chart of sales", page: 1, kids: [.markedContent(page: 1, mcid: 0)])),
            .element(PDFStructureElement(type: "Link", kids: [.annotation(page: 1, objectID: link.objectID!), .markedContent(page: 1, mcid: 1)])),
        ]),
    ])
    pmk("write tree") { try model.setStructureTree(tree) }
    check(model.structureTree() == tree, "tree round-trips in memory: \(String(describing: model.structureTree()))")
    guard let saved = pmk("save", { try model.data() }), let back = try? PDFModel(data: saved) else { return }
    // A full save renumbers objects: the link annotation keeps its place, not its number.
    var renumbered = tree
    if let linkID = back.page(at: 1)?.annotations.first?.objectID, case .element(var linkElement) = renumbered.elements[0].kids[2] {
        linkElement.kids[0] = .annotation(page: 1, objectID: linkID)
        renumbered.elements[0].kids[2] = .element(linkElement)
    }
    check(back.structureTree() == renumbered, "tree round-trips through a save")
    check(back.page(at: 0)?.object["StructParents"]?.int == 0 && back.page(at: 1)?.object["StructParents"]?.int == 1, "page StructParents")
    check(back.page(at: 1)?.annotations.first?["StructParent"]?.int == 2, "annotation StructParent")
    let parentTree = back.root["StructTreeRoot"]?["ParentTree"]
    check(parentTree.map { PDFNumberTree.entries(of: $0).map(\.key) } == [0, 1, 2], "parent tree keys")
    check(back.root["MarkInfo"]?["Marked"]?.bool == true && back.root["StructTreeRoot"]?["ParentTreeNextKey"]?.int == 3, "marked")
    check(pdfKitText(saved, page: 0).contains("Heading text"), "PDFKit opens the tagged file")
    pmk("remove tree") { try back.setStructureTree(nil) }
    check(back.structureTree() == nil && back.page(at: 0)?.object["StructParents"] == nil, "tree removed")
    pmkThrows(.invalidOperation("structure refers to page 7"), "bad page") {
        try back.setStructureTree(PDFStructureTree(elements: [PDFStructureElement(type: "P", page: 7)]))
    }
}

@MainActor
private func pmkAcroForm() {
    guard let model = pmk("open", { try PDFModel(data: pmkFixture(["Form"])) }), let page = model.page(at: 0) else { return }
    check(model.acroForm == nil && model.formFields().isEmpty, "no form yet")
    let parent = model.makeIndirect(.dictionary(["T": .text("address"), "FT": .name("Tx")]))
    model.ensureAcroForm().array("Fields").append(parent)
    let city = page.addAnnotation(model.make(.dictionary([
        "Type": .name("Annot"), "Subtype": .name("Widget"), "T": .text("city"), "Rect": .rect(CGRect(x: 72, y: 600, width: 200, height: 24)),
        "DA": .ascii("/Helv 12 Tf 0 g"),
    ])))
    city.set("Parent", parent)
    parent.set("Kids", .array([city.reference!]))
    let on = model.makeStream(["Type": .name("XObject"), "Subtype": .name("Form"), "BBox": .rect(CGRect(x: 0, y: 0, width: 12, height: 12))],
                              data: Data("0 g 2 2 8 8 re f".utf8))
    let off = model.makeStream(["Type": .name("XObject"), "Subtype": .name("Form"), "BBox": .rect(CGRect(x: 0, y: 0, width: 12, height: 12))], data: Data())
    model.addField(.dictionary([
        "Type": .name("Annot"), "Subtype": .name("Widget"), "FT": .name("Btn"), "T": .text("agree"),
        "Rect": .rect(CGRect(x: 72, y: 560, width: 12, height: 12)), "V": .name("Off"), "AS": .name("Off"),
        "AP": .dictionary(["N": .dictionary(["Yes": on.reference!, "Off": off.reference!])]),
    ]), on: page)
    model.ensureAcroForm().set("DA", .ascii("/Helv 0 Tf 0 g"))
    let fields = model.formFields()
    check(fields.map(\.name) == ["address.city", "agree"], "qualified names: \(fields.map(\.name))")
    check(fields.first?.type == "Tx" && fields.first?.defaultAppearance == "/Helv 12 Tf 0 g" && fields.first?.widgets.first?.page == 0, "inherited type and widget page")
    check(fields.last?.isCheckBox == true && fields.last?.widgets.first?.onStates == ["Yes"], "check box states")
    pmk("fill text") { try model.setFieldValue("address.city", .text("Zürich")) }
    pmk("tick") { try model.setFieldValue("agree", .name("Yes")) }
    pmkThrows(.invalidOperation("no field nope"), "unknown field") { try model.setFieldValue("nope", .null) }
    guard let saved = pmk("save", { try model.data() }), let back = try? PDFModel(data: saved) else { return }
    let backFields = back.formFields()
    check(backFields.first?.value == .text("Zürich"), "text value reads back")
    check(backFields.last?.value == .name("Yes") && backFields.last?.widgets.first?.appearanceState == "Yes", "check box ticked")
    check(back.acroForm?["NeedAppearances"]?.bool == true, "NeedAppearances on")
    let widgets = PDFDocument(data: saved)?.page(at: 0)?.annotations.filter { $0.type == "Widget" } ?? []
    check(widgets.count == 2, "PDFKit sees two widgets")
    check(widgets.contains { $0.fieldName == "agree" && $0.buttonWidgetState == .onState }, "PDFKit sees the ticked box")
    check(widgets.contains { $0.widgetStringValue == "Zürich" }, "PDFKit reads the text value")
    check(back.removeField(named: "agree") && back.formFields().map(\.name) == ["address.city"] && back.page(at: 0)?.annotations.count == 1,
          "remove a field and its widget")
}

@MainActor
private func pmkLinearize() {
    guard let model = pmk("open", { try PDFModel(data: pmkFixture(["L1", "L2", "L3"])) }), !model.isLinearized else { return }
    guard let linear = pmk("linearize", { try model.data(options: PDFWriteOptions(linearize: true)) }) else { return }
    let back = try? PDFModel(data: linear)
    check(back?.isLinearized == true && back?.check().isEmpty == true, "linearized and sound")
    check(pdfKitPageCount(linear) == 3, "PDFKit opens it")
    check(PDFRevisions.ends(in: linear) == [linear.count], "the first-page section is not a revision")
    // An appended update onto a linearized file chains through its first-page cross-reference.
    back?.setInfo("Title", "After linearize")
    if let updated = pmk("append to linearized", { try back!.incrementalData() }) {
        check((try? PDFModel(data: updated, attemptRecovery: false))?.info("Title") == "After linearize", "update reads back")
        check(pdfKitPageCount(updated) == 3, "PDFKit opens the update")
    }
    let url = scratch.appendingPathComponent("pmk-linear.pdf")
    pmk("write linearized") { try model.write(to: url, options: PDFWriteOptions(objectStreams: .generate, linearize: true)) }
    check((try? PDFModel(url: url))?.isLinearized == true, "linearized with object streams on disk")
}

@MainActor
private func pmkSignatures() {
    let original = pmkFixture(["Contract page one", "Contract page two"])
    guard let model = pmk("open", { try PDFModel(data: original) }) else { return }
    let appearance = model.makeStream(["Type": .name("XObject"), "Subtype": .name("Form"), "BBox": .rect(CGRect(x: 0, y: 0, width: 150, height: 50)),
                                       "Resources": .dictionary([:])], data: Data("0 0 1 rg 0 0 150 50 re f".utf8))
    let request = PDFSignatureRequest(fieldName: "Signature1", page: 1, rect: CGRect(x: 72, y: 72, width: 150, height: 50),
                                      appearance: appearance, kind: .certification(permissions: 2), contentsCapacity: 4096,
                                      signerName: "Ada Lovelace", reason: "Approved", location: "London",
                                      signingTime: Date(timeIntervalSince1970: 1_700_000_000))
    guard let placeholder = pmk("prepare", { try model.prepareSignature(request) }) else { return }
    let data = placeholder.data
    let br = placeholder.byteRange
    check(data.prefix(original.count) == original, "the original bytes are untouched")
    check(br[0] == 0 && br[1] == placeholder.contentsRange.lowerBound && br[2] == placeholder.contentsRange.upperBound && br[2] + br[3] == data.count,
          "ByteRange covers everything but /Contents: \(br)")
    check(data[placeholder.contentsRange.lowerBound] == UInt8(ascii: "<") && data[placeholder.contentsRange.upperBound - 1] == UInt8(ascii: ">")
          && placeholder.contentsRange.count == 4096 * 2 + 2, "the hex placeholder is where the range says")
    check(placeholder.signedBytes.count == data.count - placeholder.contentsRange.count, "signed bytes exclude /Contents")
    check(contains(data, "/ByteRange [0 \(br[1]) \(br[2]) \(br[3])]"), "ByteRange patched in place")
    pmkThrows(.signatureTooLarge(needed: 5000, capacity: 4096), "CMS too large") { _ = try placeholder.embedding(Data(count: 5000)) }

    // A stand-in CMS (SignKit makes the real one); the engine only places bytes.
    let cms = Data((0..<1500).map { UInt8(truncatingIfNeeded: $0 * 7 + 1) })
    guard let signed = pmk("embed", { try placeholder.embedding(cms) }) else { return }
    check(signed.count == data.count, "embedding keeps the length")
    check(signed.subdata(in: 0..<br[1]) == data.subdata(in: 0..<br[1]) && signed.suffix(br[3]) == data.suffix(br[3]), "signed ranges unchanged")
    guard let back = pmk("reopen signed", { try PDFModel(data: signed, attemptRecovery: false) }) else { return }
    check(!back.wasRepaired && back.check().isEmpty, "the signed file is sound")
    let sigs = back.signatures()
    check(sigs.count == 1, "one signature")
    if let sig = sigs.first {
        check(sig.fieldName == "Signature1" && sig.page == 1 && sig.rect == CGRect(x: 72, y: 72, width: 150, height: 50), "field, page and rect")
        check(sig.byteRange == br && sig.contents.prefix(cms.count) == cms && sig.contents.count == 4096, "ByteRange and CMS read back")
        check(sig.signedBytes(of: signed) == placeholder.signedBytes, "signed bytes from the file match")
        check(sig.subFilter == "ETSI.CAdES.detached" && sig.filter == "Adobe.PPKLite", "filters")
        check(sig.signerName == "Ada Lovelace" && sig.reason == "Approved" && sig.location == "London", "signer details")
        check(sig.signingTime == Date(timeIntervalSince1970: 1_700_000_000) && sig.certificationPermissions == 2, "time and DocMDP level")
        check(sig.revisionLength == signed.count, "covers the whole file")
    }
    check(back.root["Perms"]?["DocMDP"] != nil && back.acroForm?["SigFlags"]?.int == 3, "certification and SigFlags")
    let pdf = PDFDocument(data: signed)
    check(pdf?.pageCount == 2 && pdf?.page(at: 1)?.annotations.contains { $0.fieldName == "Signature1" } == true, "PDFKit opens the signed file")
    check(PDFRevisions.ends(in: signed) == [original.count, signed.count], "two revisions")
    if let changes = pmk("changes in the signing update", { try PDFRevisions.changes(in: signed, since: original.count) }) {
        check(changes.contains { $0.kind == .added && $0.type == "Sig" }, "the signature dictionary was added")
        check(changes.contains { $0.kind == .added && $0.subtype == "Widget" }, "the widget was added")
    }

    // A later update: the signed revision stays intact and the change shows up after it.
    back.setInfo("Title", "Changed after signing")
    back.page(at: 0)?.addAnnotation(back.make(.dictionary(["Type": .name("Annot"), "Subtype": .name("Text"),
                                                          "Rect": .rect(CGRect(x: 10, y: 10, width: 20, height: 20)), "Contents": .text("Note")])))
    guard let later = pmk("append after signing", { try back.incrementalData() }) else { return }
    check(later.prefix(signed.count) == signed, "signed bytes untouched by the later update")
    check(PDFRevisions.ends(in: later) == [original.count, signed.count, later.count], "three revisions")
    if let laterSig = (try? PDFModel(data: later))?.signatures().first {
        check(laterSig.revisionLength == signed.count && laterSig.signedBytes(of: later) == placeholder.signedBytes, "the signature still covers its revision")
    }
    if let changes = pmk("changes after signing", { try PDFRevisions.changes(in: later, since: signed.count) }) {
        check(changes.contains { $0.kind == .added && $0.subtype == "Text" }, "the new annotation is reported")
        check(changes.contains { $0.kind == .modified && $0.type == "Page" }, "the page's /Annots change is reported")
        check(!changes.contains { $0.type == "Sig" }, "the signature dictionary is unchanged")
    }

    // Signing a cross-reference-stream file, invisibly, as a document time stamp.
    guard let streamsData = try? PDFModel(data: original).data(options: PDFWriteOptions(objectStreams: .generate)),
          let streams = try? PDFModel(data: streamsData) else { check(false, "object-stream fixture"); return }
    guard let stamp = pmk("prepare a time stamp", { try streams.prepareSignature(PDFSignatureRequest(fieldName: "TS", kind: .documentTimeStamp, contentsCapacity: 2048)) }) else { return }
    check(contains(Data(stamp.data.suffix(from: streamsData.count)), "/Type/XRef") || contains(Data(stamp.data.suffix(from: streamsData.count)), "/Type /XRef"),
          "a stream file gets a stream update")
    if let stamped = pmk("embed stamp", { try stamp.embedding(Data(repeating: 0x30, count: 100)) }) {
        let info = (try? PDFModel(data: stamped, attemptRecovery: false))?.signatures().first
        check(info?.isDocumentTimeStamp == true && info?.subFilter == "ETSI.RFC3161" && info?.rect == .zero, "an invisible time stamp")
        check(pdfKitPageCount(stamped) == 2, "PDFKit opens the stamped file")
    }
    pmkThrows(.invalidOperation("field TS exists"), "duplicate field") {
        _ = try PDFModel(data: try streams.data()).prepareSignature(PDFSignatureRequest(fieldName: "TS"))
    }
}
