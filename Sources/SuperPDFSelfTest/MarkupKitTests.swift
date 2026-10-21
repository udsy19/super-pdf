import AVFoundation
import AppKit
@testable import MarkupKit
import PDFKit
import PDFModelKit
import SuperPDFCore
@testable import ToolsKit

// MarkupKit (WP9): every kind of markup made through the bar's gestures, saved the way DocumentKit saves (PDFKit write
// plus MarkupKit's restorer) and read back with PDFKit and QPDF; files made elsewhere (reply threads, attached files,
// voice notes) keep what PDFKit alone would drop; XFDF/FDF/CSV exchange; measuring maths; the Sketch recogniser; the
// menu commands; the five tiles driven through ToolsKit's ToolSession; offscreen renders of pages, the bar, the
// selection layer, the panels and the comment summary ($SUPERPDF_RENDERS, else the scratch folder).

func registerMarkupKitTests() {
    SelfTest.cases.append(("MarkupKit.install", { markupInstall() }))
    SelfTest.cases.append(("MarkupKit.roundTrip", { markupRoundTrip() }))
    SelfTest.cases.append(("MarkupKit.foreignFile", { markupForeignFile() }))
    SelfTest.cases.append(("MarkupKit.undo", { markupUndo() }))
    SelfTest.cases.append(("MarkupKit.exchange", { markupExchange() }))
    SelfTest.cases.append(("MarkupKit.measure", { markupMeasure() }))
    SelfTest.cases.append(("MarkupKit.sketch", { markupSketch() }))
    SelfTest.cases.append(("MarkupKit.commands", { markupCommands() }))
    SelfTest.cases.append(("MarkupKit.panels", { markupPanels() }))
    SelfTest.cases.append(("MarkupKit.layer", { markupLayer() }))
    SelfTest.cases.append(("MarkupKit.renders", { markupRenders() }))
}

// MARK: - Fixtures

private var markupFolder: URL { SuperPDFPaths.ensure(scratch.appendingPathComponent("MarkupKit", isDirectory: true)) }

private var markupRenderFolder: URL {
    if let path = ProcessInfo.processInfo.environment["SUPERPDF_RENDERS"] { return SuperPDFPaths.ensure(URL(fileURLWithPath: path, isDirectory: true)) }
    return SuperPDFPaths.ensure(markupFolder.appendingPathComponent("renders", isDirectory: true))
}

/// A document backed by a real file in the scratch folder, with lines of text to mark up.
@MainActor
private func markupDocument(_ name: String, pages: Int = 2) -> DocumentHandle {
    let data = NSMutableData()
    var box = CGRect(x: 0, y: 0, width: 612, height: 792)
    let consumer = CGDataConsumer(data: data as CFMutableData)!
    let context = CGContext(consumer: consumer, mediaBox: &box, nil)!
    for n in 1...pages {
        context.beginPDFPage(nil)
        let lines = ["Page \(n)", "The quick brown fox jumps over the lazy dog.", "Plans, notes and comments live here.", "Room 4.2 measures ten metres across."]
        for (i, text) in lines.enumerated() {
            let line = CTLineCreateWithAttributedString(NSAttributedString(string: text, attributes: [.font: NSFont(name: "Helvetica", size: i == 0 ? 24 : 14)!]))
            context.textPosition = CGPoint(x: 72, y: 700 - CGFloat(i) * 40)
            CTLineDraw(line, context)
        }
        context.endPDFPage()
    }
    context.closePDF()
    let url = markupFolder.appendingPathComponent(name + ".pdf")
    try? (data as Data).write(to: url)
    return DocumentHandle(url: url, pdf: PDFDocument(url: url)!, undoManager: makeUndoManager())
}

/// MarkupKit's real service over the fakes, as the app installs it.
@MainActor
private func markupService() -> MarkupService {
    installFakes()
    Defaults.reset(.authorName)
    Defaults[.authorName] = "Ada Reviewer"
    MarkupKitModule.install()
    return Services.markup as! MarkupService
}

/// Saves as DocumentKit does: a copy written by PDFKit, then the restorer over the written bytes; reopens it.
@MainActor
private func markupSave(_ document: DocumentHandle, as name: String) -> URL {
    let url = markupFolder.appendingPathComponent(name + ".pdf")
    let restore = Services.markup.annotationRestorer(for: document)
    let copy = document.pdf.copy() as! PDFDocument
    check(copy.write(to: url), "PDFKit writes \(name)")
    if let restore, let written = try? Data(contentsOf: url) {
        do { try restore(written).write(to: url) } catch { check(false, "restorer runs: \(error)") }
    }
    return url
}

private func markupWave(seconds: Double = 0.25) -> URL {
    let url = markupFolder.appendingPathComponent("voice.caf")
    let format = AVAudioFormat(commonFormat: .pcmFormatInt16, sampleRate: 22_050, channels: 1, interleaved: true)!
    let frames = AVAudioFrameCount(22_050 * seconds)
    let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frames)!
    buffer.frameLength = frames
    for i in 0..<Int(frames) { buffer.int16ChannelData![0][i] = Int16(sin(Double(i) * 0.2) * 8000) }
    try? FileManager.default.removeItem(at: url)
    let file = try! AVAudioFile(forWriting: url, settings: format.settings, commonFormat: .pcmFormatInt16, interleaved: true)
    try? file.write(from: buffer)
    return url
}

/// The selection of a line of the fixture text on `page`.
@MainActor
private func markupText(_ page: PDFKit.PDFPage, line: Int) -> PDFSelection {
    return page.selection(for: CGRect(x: 66, y: 700 - CGFloat(line) * 40 - 3, width: 400, height: 14))!
}

/// Every kind of markup on page 1 of `document`, through the session's gestures.
@MainActor
@discardableResult
private func markupEverything(_ document: DocumentHandle, service: MarkupService) -> [String: PDFAnnotation] {
    let session = service.session(for: document)
    let page = document.pdf.page(at: 0)!
    var made: [String: PDFAnnotation] = [:]
    var style = MarkupStyle()
    style.textMarkup = .highlight(.green)
    session.style = style
    made["highlight"] = session.markText(markupText(page, line: 1)).first
    style.textMarkup = .underline; session.style = style
    made["underline"] = session.markText(markupText(page, line: 2)).first
    style.textMarkup = .strikethrough; session.style = style
    made["strike"] = session.markText(page.selection(for: CGRect(x: 66, y: 577, width: 94, height: 14))!).first
    session.style = MarkupStyle()
    made["note"] = session.placeNote(at: CGPoint(x: 520, y: 760), on: page)
    session.setText("Check this paragraph", of: made["note"]!)
    made["text"] = session.placeText(at: CGPoint(x: 400, y: 620), on: page)
    session.setText("Looks good", of: made["text"]!)
    var shapeStyle = MarkupStyle()
    shapeStyle.fill = MarkupColor(hex: "#FFCC0080")
    session.style = shapeStyle
    made["rectangle"] = session.finishShape(.rectangle, from: CGPoint(x: 60, y: 420), to: CGPoint(x: 160, y: 480), on: page)
    session.style = MarkupStyle()
    made["oval"] = session.finishShape(.oval, from: CGPoint(x: 180, y: 420), to: CGPoint(x: 280, y: 480), on: page)
    made["line"] = session.finishShape(.line, from: CGPoint(x: 300, y: 420), to: CGPoint(x: 380, y: 480), on: page)
    made["arrow"] = session.finishShape(.arrow, from: CGPoint(x: 400, y: 420), to: CGPoint(x: 480, y: 480), on: page)
    made["rounded"] = session.finishShape(.roundedRectangle, from: CGPoint(x: 60, y: 320), to: CGPoint(x: 160, y: 380), on: page)
    made["bubble"] = session.finishShape(.speechBubble, from: CGPoint(x: 180, y: 320), to: CGPoint(x: 280, y: 390), on: page)
    made["star"] = session.finishShape(.star, from: CGPoint(x: 300, y: 320), to: CGPoint(x: 370, y: 390), on: page)
    made["polygon"] = session.finishShape(.polygon, from: CGPoint(x: 390, y: 320), to: CGPoint(x: 460, y: 390), on: page)
    made["cloud"] = session.finishShape(.cloud, from: CGPoint(x: 480, y: 320), to: CGPoint(x: 570, y: 390), on: page)
    made["loupe"] = session.finishShape(.loupe, from: CGPoint(x: 210, y: 625), to: CGPoint(x: 280, y: 695), on: page)
    session.choose(.draw)
    made["ink"] = session.finishStroke((0...40).map { CGPoint(x: 60 + CGFloat($0) * 2.5, y: 260 + 20 * sin(CGFloat($0) / 4)) }, on: page)
    session.choose(.sketch)
    let roughBox = [CGPoint(x: 200, y: 240), CGPoint(x: 260, y: 241), CGPoint(x: 261, y: 280), CGPoint(x: 199, y: 279), CGPoint(x: 201, y: 242)]
    made["sketch"] = session.finishStroke(roughBox.flatMap { p in (0..<6).map { _ in p } }, on: page)
    session.choose(.textSelection)
    made["stamp"] = session.placeStamp(.approved, at: CGPoint(x: 400, y: 250), on: page)
    made["caret"] = session.markCorrection(.insertText, selection: nil, insertionPoint: CGPoint(x: 120, y: 664), on: page, text: "very").first
    let replaced = session.markCorrection(.replaceText, selection: page.selection(for: CGRect(x: 250, y: 617, width: 60, height: 14)),
                                          insertionPoint: nil, on: page, text: "reside")
    made["replaceCaret"] = replaced.first { $0.type == "Caret" }
    made["replaceStrike"] = replaced.first { $0.type == "StrikeOut" }
    session.choose(.measure(.distance))
    made["distance"] = session.finishMeasurement(.distance, points: [CGPoint(x: 60, y: 180), CGPoint(x: 204, y: 180)], on: page)
    made["perimeter"] = session.finishMeasurement(.perimeter, points: [CGPoint(x: 240, y: 150), CGPoint(x: 312, y: 150), CGPoint(x: 312, y: 200)], on: page)
    made["area"] = session.finishMeasurement(.area, points: [CGPoint(x: 360, y: 130), CGPoint(x: 432, y: 130), CGPoint(x: 432, y: 202), CGPoint(x: 360, y: 202)], on: page)
    session.choose(.textSelection)
    let notes = markupFolder.appendingPathComponent("notes.txt")
    try? Data("Minutes of the site visit".utf8).write(to: notes)
    session.register(try! service.attachFile(notes, to: 0, at: CGPoint(x: 560, y: 120), in: document))
    session.register(try! service.attachFile(markupWave(), to: 0, at: CGPoint(x: 580, y: 120), in: document))
    let png = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: 40, pixelsHigh: 20, bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true,
                               isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
    for x in 0..<40 { for y in 0..<20 { png.setColor(x < 20 ? NSColor(deviceRed: 0.69, green: 0.32, blue: 0.87, alpha: 1) : NSColor(deviceRed: 0.19, green: 0.69, blue: 0.78, alpha: 1), atX: x, y: y) } }
    session.register(try! service.addStamp(png.representation(using: .png, properties: [:])!, on: 0, in: CGRect(x: 60, y: 60, width: 80, height: 40), in: document))
    // A thread on the rectangle: a reply and a status.
    let rectangleID = service.comments(in: document).first { $0.kind == .shape && $0.bounds == made["rectangle"]!.bounds }!
    session.register(service.reply(to: rectangleID, text: "Agreed, move it left", in: document))
    session.register(service.setStatus(.accepted, of: rectangleID, in: document))
    return made
}

// MARK: - Cases

@MainActor
private func markupInstall() {
    let service = markupService()
    check(Services.markup === service, "Services.markup is MarkupKit's")
    let provider = Services.toolProviders.last
    check(Set(provider?.tools ?? []) == [.highlightAndNotes, .drawAndShapes, .commentsList, .attachFile, .measure], "provider serves the Mark up tiles")
    check(service.authorName == "Ada Reviewer", "author from Settings")
    Defaults.reset(.authorName)
    check(!service.authorName.isEmpty, "author falls back to the account's name")
    let symbols = ["character.cursor.ibeam", "rectangle.dashed", "text.redaction", "scribble.variable", "pencil.tip", "character.textbox",
                   "highlighter", "signature", "note.text", "lineweight", "textformat", "rotate.left", "crop",
                   "rectangle.and.pencil.and.ellipsis", "seal", "ruler", "underline", "strikethrough", "control", "delete.left",
                   "arrow.left.arrow.right", "record.circle"] + ShapeKind.allCases.map(\.symbol)
    for symbol in symbols { check(NSImage(systemSymbolName: symbol, accessibilityDescription: nil) != nil, "SF Symbol \(symbol) exists") }
    let shortcuts = ShapeKind.allCases.compactMap { MarkupKitStrings.shortcut(for: $0)?.description }
    check(shortcuts == ["⌃⌘I", "⌃⌘A", "⌃⌘R", "⌃⌘O", "⌃⌘L"], "shape shortcuts from the menu tree (ux §6.4): \(shortcuts)")
}

@MainActor
private func markupRoundTrip() {
    let service = markupService()
    let document = markupDocument("Round trip")
    let made = markupEverything(document, service: service)
    for (name, annotation) in made { check(annotation.page === document.pdf.page(at: 0), "\(name) is on page 1") }
    check(made["sketch"]?.type == "Square", "a rough box sketches into a rectangle (\(made["sketch"]?.type ?? "nil"))")
    check(made["highlight"]?.color.usingColorSpace(.sRGB)?.hexRGBA.prefix(7) == "#7CC868", "Preview's green highlight")
    let before = service.comments(in: document)
    let thread = before.first { $0.bounds == made["rectangle"]!.bounds }
    check(thread?.replies.map(\.text) == ["Agreed, move it left"] && thread?.status == .accepted, "thread before saving")
    check(before.first { $0.kind == .highlight }?.quotedText?.contains("quick brown fox") == true, "highlight quotes its words")
    check(before.allSatisfy { $0.author == "Ada Reviewer" }, "every kind carries its author: \(before.filter { $0.author.isEmpty }.map(\.kind))")

    let url = markupSave(document, as: "Round trip (saved)")
    // QPDF: standard keys only, links and payloads restored.
    guard let model = try? PDFModel(url: url) else { check(false, "QPDF opens the saved file"); return }
    let annots = model.page(at: 0)!.annotations
    var bySubtype: [String: [PDFObject]] = [:]
    for annot in annots { bySubtype[annot["Subtype"]?.name ?? "", default: []].append(annot) }
    check(annots.allSatisfy { $0["SuperPDFID"] == nil }, "no private keys in the saved file")
    check(annots.filter { $0["Subtype"]?.name != "Popup" }.allSatisfy { ($0["NM"]?.text ?? "").isEmpty == false }, "every annotation has /NM")
    for subtype in ["Highlight", "Underline", "StrikeOut", "Text", "FreeText", "Square", "Circle", "Line", "Polygon", "PolyLine", "Ink", "Stamp",
                    "Caret", "FileAttachment", "Sound"] {
        check(bySubtype[subtype]?.isEmpty == false, "saved file has a /\(subtype)")
    }
    check(annots.filter { $0["Subtype"]?.name != "Popup" }.allSatisfy { $0["AP"]?["N"] != nil }, "every annotation has an appearance stream")
    let rectangleNM = annots.first { $0["Subtype"]?.name == "Square" && $0["IC"] != nil }?["NM"]?.text
    let replies = annots.filter { $0["IRT"] != nil && $0["Subtype"]?.name == "Text" }
    check(replies.count == 2 && replies.allSatisfy { $0["IRT"]?["NM"]?.text == rectangleNM && $0["RT"]?.name == "R" }, "reply and status point at the rectangle (/IRT)")
    check(replies.first { $0["State"] == nil }?["F"]?.int == 4, "the reply is written as Acrobat writes replies (/F 4)")
    check(replies.first { $0["State"] != nil }?["State"]?.text == "Accepted" && replies.first { $0["State"] != nil }?["StateModel"]?.text == "Review",
          "review status /State /StateModel")
    let strike = annots.first { $0["Subtype"]?.name == "StrikeOut" && $0["IT"]?.name == "StrikeOutTextEdit" }
    check(strike?["IRT"]?["Subtype"]?.name == "Caret" && strike?["RT"]?.name == "Group", "replace text: strike grouped under its caret")
    let clip = bySubtype["FileAttachment"]?.first
    check((try? clip?["FS"]?["EF"]?["F"]?.streamData(decode: .specialized)).map { String(decoding: $0!, as: UTF8.self) } == "Minutes of the site visit",
          "the paper clip keeps its file")
    check(clip?["Name"]?.name == "Paperclip" && clip?["FS"]?["UF"]?.text == "notes.txt", "paper clip icon and file name")
    let sound = bySubtype["Sound"]?.first?["Sound"]
    check(sound?["R"]?.number == 22_050 && sound?["B"]?.int == 16 && sound?["E"]?.name == "Signed" && ((try? sound?.streamData())?.count ?? 0) > 10_000,
          "the voice note keeps its samples")
    let polygons = (bySubtype["Polygon"] ?? []).filter { $0["IT"] == nil }
    check(polygons.count == 3 && polygons.allSatisfy { ($0["Vertices"]?.count ?? 0) >= 12 }, "bubble, star and polygon as /Vertices")
    check(bySubtype["Square"]?.contains { $0["BE"]?["S"]?.name == "C" } == true, "cloud as /BE /S /C")
    let distance = bySubtype["Line"]?.first { $0["IT"]?.name == "LineDimension" }
    check(distance?["Measure"]?["X"]?[0]?["U"]?.text == "in" && distance?["Contents"]?.text == "2 in", "distance with its /Measure and value")
    for popup in bySubtype["Popup"] ?? [] {
        check(annots.contains { $0.isSameObject(as: popup["Parent"]!) }, "a popup's parent is the note in /Annots")
    }

    // PDFKit reads the same markup back.
    let reopened = DocumentHandle(url: url, pdf: PDFDocument(url: url)!, undoManager: makeUndoManager())
    let types = reopened.pdf.page(at: 0)!.annotations.compactMap(\.type).filter { $0 != "Popup" }.sorted()
    let madeTypes = document.pdf.page(at: 0)!.annotations.compactMap(\.type).filter { $0 != "Popup" }.sorted()
    check(types == madeTypes, "PDFKit reopens the same kinds: \(types) vs \(madeTypes)")
    let after = service.comments(in: reopened)
    check(after.count == before.count, "comments after reopening: \(after.count) vs \(before.count)")
    let thread2 = after.first { $0.kind == .shape && $0.text.isEmpty && $0.replies.count == 1 }
    check(thread2?.replies.first?.author == "Ada Reviewer" && thread2?.status == .accepted, "the thread survives a reopen")
    check(Set(after.map(\.id)) == Set(before.map(\.id)), "ids survive as /NM")
    let noteText = after.first { $0.kind == .note }?.text
    check(noteText == "Check this paragraph", "note text: \(noteText ?? "nil")")
    check(after.first { $0.kind == .textBox }?.text == "Looks good", "text box text")

    // A second save of the reopened file (PDFKit alone would now drop the links) keeps them.
    let reopenedPage = reopened.pdf.page(at: 0)!
    reopenedPage.addAnnotation(AnnotationProbe.square())
    let url2 = markupSave(reopened, as: "Round trip (saved twice)")
    let model2 = try? PDFModel(url: url2)
    let annots2 = model2?.page(at: 0)?.annotations ?? []
    check(annots2.filter { $0["IRT"] != nil }.count == 3, "links survive a second save (\(annots2.filter { $0["IRT"] != nil }.count))")
    check(annots2.contains { $0["Subtype"]?.name == "FileAttachment" && $0["FS"]?["EF"]?["F"] != nil }, "the clipped file survives a second save")
    check(annots2.contains { $0["Subtype"]?.name == "Sound" && $0["Sound"]?["R"] != nil }, "the voice note survives a second save")

    // Engines see the restored bytes too (DocumentHandle.snapshot).
    document.state.isEdited = true
    if case .data(let data, _) = document.snapshot(), let snapshot = try? PDFModel(data: data) {
        let a = snapshot.page(at: 0)!.annotations
        check(a.allSatisfy { $0["SuperPDFID"] == nil } && a.filter { $0["IRT"] != nil }.count == 3, "engine snapshots carry /IRT and no private keys")
    } else {
        check(false, "snapshot is data for an edited document")
    }
}

@MainActor
private enum AnnotationProbe {
    static func square() -> PDFAnnotation { PDFAnnotation(bounds: CGRect(x: 20, y: 20, width: 10, height: 10), forType: .square, withProperties: nil) }
}

/// A file made elsewhere (Acrobat-style): a reply thread with a status, a paper clip with its file, a voice note.
@MainActor
private func markupForeignFile() {
    let service = markupService()
    let base = markupDocument("Foreign base", pages: 1)
    let model = try! PDFModel(url: base.url!)
    let page = model.page(at: 0)!
    func annot(_ values: [String: PDFValue]) -> PDFObject { page.addAnnotation(model.make(.dictionary(values.merging(["Type": .name("Annot")]) { a, _ in a }))) }
    let parent = annot(["Subtype": .name("Square"), "Rect": .rect(CGRect(x: 100, y: 100, width: 120, height: 80)), "C": .array([.integer(1), .integer(0), .integer(0)]),
                        "NM": .text("acrobat-1"), "T": .text("Bea"), "Contents": .text("Too big"), "F": .integer(4)])
    _ = annot(["Subtype": .name("Text"), "Rect": .rect(CGRect(x: 100, y: 160, width: 20, height: 20)), "IRT": parent.reference!, "RT": .name("R"),
               "NM": .text("acrobat-2"), "T": .text("Cal"), "Contents": .text("Shrink it"), "F": .integer(4)])
    _ = annot(["Subtype": .name("Text"), "Rect": .rect(CGRect(x: 100, y: 160, width: 20, height: 20)), "IRT": parent.reference!, "RT": .name("R"),
               "NM": .text("acrobat-3"), "T": .text("Bea"), "State": .text("Completed"), "StateModel": .text("Review"), "F": .integer(30)])
    let spec = model.makeIndirect(.dictionary(["Type": .name("Filespec"), "F": .text("budget.csv"), "UF": .text("budget.csv")]))
    let file = model.makeStream(["Type": .name("EmbeddedFile"), "Subtype": .name("text/csv")], data: Data("a,b\n1,2\n".utf8))
    spec.set("EF", .dictionary(["F": file.reference!]))
    _ = annot(["Subtype": .name("FileAttachment"), "Rect": .rect(CGRect(x: 400, y: 600, width: 14, height: 20)), "FS": spec.reference!,
               "Name": .name("Graph"), "NM": .text("acrobat-4")])
    let sound = model.makeStream(["Type": .name("Sound"), "R": .integer(8000), "C": .integer(1), "B": .integer(8), "E": .name("Raw")], data: Data(repeating: 128, count: 800))
    _ = annot(["Subtype": .name("Sound"), "Rect": .rect(CGRect(x: 430, y: 600, width: 20, height: 20)), "Sound": sound.reference!, "NM": .text("acrobat-5")])
    let url = markupFolder.appendingPathComponent("Foreign.pdf")
    try! model.write(to: url)

    let document = DocumentHandle(url: url, pdf: PDFDocument(url: url)!, undoManager: makeUndoManager())
    let comments = service.comments(in: document)
    let thread = comments.first { $0.id == "acrobat-1" }
    check(thread?.replies.map(\.text) == ["Shrink it"] && thread?.replies.first?.author == "Cal" && thread?.status == .completed, "an Acrobat thread reads as one comment")
    check(comments.count == 3, "replies and states fold into their comment (\(comments.map(\.id)))")
    check(document.pdf.page(at: 0)!.annotations.filter { ($0.value(forAnnotationKey: .name) as? String) == "acrobat-2" }.allSatisfy { !$0.shouldDisplay },
          "replies don't draw as extra note icons")
    // Edit something unrelated and save: PDFKit alone would drop the thread, the file and the sound.
    document.pdf.page(at: 0)!.addAnnotation(AnnotationProbe.square())
    let saved = markupSave(document, as: "Foreign (saved)")
    let back = try! PDFModel(url: saved).page(at: 0)!.annotations
    let reply = back.first { $0["NM"]?.text == "acrobat-2" }
    check(reply?["IRT"]?["NM"]?.text == "acrobat-1" && reply?["F"]?.int == 4, "the reply keeps its /IRT and its /F")
    check(back.first { $0["NM"]?.text == "acrobat-3" }?["F"]?.int == 30, "the status keeps Acrobat's flags")
    let clip = back.first { $0["NM"]?.text == "acrobat-4" }
    check((try? clip?["FS"]?["EF"]?["F"]?.streamData(decode: .specialized)) == Data("a,b\n1,2\n".utf8) && clip?["Name"]?.name == "Graph"
          && clip?["FS"]?["EF"]?["F"]?["Subtype"]?.name == "text/csv", "the attached file, its type and its icon survive")
    check((try? back.first { $0["NM"]?.text == "acrobat-5" }?["Sound"]?.streamData())?.count == 800, "the sound survives")
}

@MainActor
private func markupUndo() {
    let service = markupService()
    let document = markupDocument("Undo")
    let undo = document.undoManager!
    let session = service.session(for: document)
    let page = document.pdf.page(at: 0)!
    let box = session.finishShape(.rectangle, from: CGPoint(x: 100, y: 100), to: CGPoint(x: 200, y: 150), on: page)
    check(undo.undoActionName == "Add Rectangle", "undo name: \(undo.undoActionName)")
    session.select(box, on: page)
    session.moveSelection(by: 10, 20)
    check(box.bounds.origin == CGPoint(x: 110, y: 120) && undo.undoActionName == "Move", "move")
    session.restyle("Color") { $0.stroke = MarkupColor(hex: "#007AFF") }
    check(MarkupColor(box.color).hexRGB == "#007AFF", "restyle")
    session.resizeSelection(to: CGRect(x: 110, y: 120, width: 50, height: 50))
    check(box.bounds.size == CGSize(width: 50, height: 50), "resize")
    undo.undo(); undo.undo(); undo.undo()
    check(box.bounds == CGRect(x: 100, y: 100, width: 100, height: 50) && MarkupColor(box.color).hexRGB == "#FF3B30", "undo resize, colour and move")
    undo.redo()
    check(box.bounds.origin == CGPoint(x: 110, y: 120), "redo move")
    session.select(box, on: page)
    session.deleteSelection()
    check(!page.annotations.contains { $0 === box } && undo.undoActionName == "Delete", "delete")
    undo.undo()
    check(page.annotations.contains { $0 === box }, "undo delete")
    // A star from the file (drawn from its appearance) becomes redrawable before it moves.
    let star = session.finishShape(.star, from: CGPoint(x: 300, y: 300), to: CGPoint(x: 360, y: 360), on: page)
    let url = markupSave(document, as: "Undo (saved)")
    let reopened = DocumentHandle(url: url, pdf: PDFDocument(url: url)!, undoManager: makeUndoManager())
    let reopenedSession = service.session(for: reopened)
    let reopenedPage = reopened.pdf.page(at: 0)!
    let plainStar = reopenedPage.annotations.first { $0.type == "Polygon" }!
    check(!(plainStar is DrawnAnnotation), "reopened star is PDFKit's own")
    reopenedSession.select(plainStar, on: reopenedPage)
    reopenedSession.moveSelection(by: 0, -200)
    let movedURL = markupSave(reopened, as: "Undo (moved star)")
    let movedStar = try! PDFModel(url: movedURL).page(at: 0)!.annotations.first { $0["Subtype"]?.name == "Polygon" }
    let appearance = (try? movedStar?["AP"]?["N"]?.streamData()).map { String(decoding: $0, as: UTF8.self) } ?? ""
    check(appearance.contains(" l") && appearance.count > 40, "a moved star still has its drawing (\(appearance.count) bytes)")
    let vertices = movedStar?["Vertices"]?.items.compactMap(\.number) ?? []
    check(vertices.count == 20 && abs((vertices[1]) - (Double(star.bounds.maxY) - 6 - 200)) < 2, "its /Vertices moved with it")
}

@MainActor
private func markupExchange() {
    let service = markupService()
    let document = markupDocument("Exchange")
    markupEverything(document, service: service)
    let xfdf = markupFolder.appendingPathComponent("Exchange.xfdf")
    try? service.exportComments(from: document, as: .xfdf, to: xfdf)
    let xml = (try? String(contentsOf: xfdf, encoding: .utf8)) ?? ""
    check(xml.contains("<xfdf xmlns=\"http://ns.adobe.com/xfdf/\"") && xml.contains("inreplyto=") && xml.contains("statemodel=\"Review\""), "XFDF with threads")
    check(xml.contains("<highlight") && xml.contains("coords=") && xml.contains("<ink") && xml.contains("<gesture>") && xml.contains("<vertices>"), "XFDF geometry")

    let target = markupDocument("Exchange target")
    let group = try? service.importComments(from: xfdf, into: target)
    check(group != nil, "XFDF imports")
    let original = service.comments(in: document).sorted { $0.id < $1.id }
    let imported = service.comments(in: target).sorted { $0.id < $1.id }
    check(imported.map(\.id) == original.map(\.id), "same comments after import (\(imported.count) vs \(original.count))")
    check(imported.map(\.kind) == original.map(\.kind) && imported.map(\.author) == original.map(\.author) && imported.map(\.text) == original.map(\.text),
          "kinds, authors and words: \(zip(original, imported).filter { $0.kind != $1.kind || $0.author != $1.author || $0.text != $1.text }.map { "\($0.kind)/\($0.text) → \($1.kind)/\($1.text)" })")
    check(imported.map { $0.replies.map(\.text) } == original.map { $0.replies.map(\.text) } && imported.map(\.status) == original.map(\.status), "replies and states")
    let count = target.pdf.page(at: 0)!.annotations.count
    _ = try? service.importComments(from: xfdf, into: target)
    check(target.pdf.page(at: 0)!.annotations.count == count, "importing again adds nothing twice")
    let clip = target.pdf.page(at: 0)!.annotations.first { $0.type == "FileAttachment" }
    check(clip.map { service.attachment(of: $0, in: target).file?.data } == Data("Minutes of the site visit".utf8), "the clipped file travels in XFDF")
    check(target.pdf.page(at: 0)!.annotations.first { $0.type == "Sound" }.map { (service.attachment(of: $0, in: target).sound?.samples.count ?? 0) > 10_000 } == true,
          "the voice note travels in XFDF")
    group?.undo()
    check(service.comments(in: target).isEmpty, "undo removes the import")
    check((try? service.importComments(from: markupFolder.appendingPathComponent("x.csv"), into: target)) == nil, "CSV doesn't import")

    let fdf = markupFolder.appendingPathComponent("Exchange.fdf")
    try? service.exportComments(from: document, as: .fdf, to: fdf)
    let fdfText = String(decoding: (try? Data(contentsOf: fdf)) ?? Data(), as: UTF8.self)
    check(fdfText.hasPrefix("%FDF-1.2") && fdfText.contains("/Annots") && fdfText.contains("/IRT") && fdfText.contains("/QuadPoints"), "FDF")
    let csv = markupFolder.appendingPathComponent("Exchange.csv")
    try? service.exportComments(from: document, as: .csv, to: csv)
    let rows = ((try? String(contentsOf: csv, encoding: .utf8)) ?? "").components(separatedBy: "\r\n").filter { !$0.isEmpty }
    check(rows.first == "Page,Type,Author,Date,Status,Comment,Text,Replies" && rows.count == original.count + 1, "CSV rows")

    for layout in [CommentSummaryOptions.Layout.connectorLines, .commentsOnly, .sequenceNumbers] {
        let data = complete { try await service.summarizeComments(of: document, options: CommentSummaryOptions(layout: layout)) }
        guard case .success(let pdfData)? = data, let summary = PDFDocument(data: pdfData) else { check(false, "summary \(layout)"); continue }
        let text = summary.string ?? ""
        check(summary.pageCount >= 1 && text.contains("Ada Reviewer") && text.contains("Agreed, move it left"), "summary \(layout.rawValue): \(summary.pageCount) pages")
        if layout == .commentsOnly { check(text.contains("Summary of comments on"), "summary title") }
        if layout == .connectorLines { check(summary.pageCount >= 2 && text.contains("1 sq in"), "a long column continues on another sheet") }
        if let page = summary.page(at: 0) { savePage(page, "markup-summary-\(layout.rawValue)", scale: 1.5) }
    }
}

@MainActor
private func markupMeasure() {
    let tenMetresAnInch = MeasureScale(pageDistance: 72, realDistance: 10, unit: .m)
    check(tenMetresAnInch.length(144) == 20 && tenMetresAnInch.area(72 * 72) == 100, "scale maths")
    let service = markupService()
    let document = markupDocument("Measure")
    let session = service.session(for: document)
    let page = document.pdf.page(at: 0)!
    let line = session.finishMeasurement(.distance, points: [CGPoint(x: 100, y: 100), CGPoint(x: 244, y: 100)], on: page)
    check(line?.contents == "2 in", "default scale is 1:1 inches (\(line?.contents ?? "nil"))")
    check(session.lastDistance?.points == 144, "the last line drawn is kept for Set scale")
    let area = session.finishMeasurement(.area, points: [CGPoint(x: 100, y: 200), CGPoint(x: 172, y: 200), CGPoint(x: 172, y: 272), CGPoint(x: 100, y: 272)], on: page)
    let perimeter = session.finishMeasurement(.perimeter, points: [CGPoint(x: 300, y: 200), CGPoint(x: 336, y: 200), CGPoint(x: 336, y: 248)], on: page)
    session.register(service.setScale(MeasureScale(pageDistance: 144, realDistance: 20, unit: .m), in: document, page: 0))
    let labels = page.annotations.compactMap { Measure.kind(of: $0) != nil ? $0.contents : nil }
    check(labels.sorted() == ["100 sq m", "11.7 m", "20 m"].sorted(), "relabelled in the new scale (84 pt of 144 pt = 20 m): \(labels)")
    check(service.scale(in: document, page: 0).realDistance == 20, "the page keeps its scale")
    document.undoManager?.undo()
    check(page.annotations.compactMap { Measure.kind(of: $0) != nil ? $0.contents : nil }.contains("2 in"), "undo restores the old values")
    document.undoManager?.redo()
    _ = (area, perimeter)
    let url = markupSave(document, as: "Measure (saved)")
    let reopened = DocumentHandle(url: url, pdf: PDFDocument(url: url)!, undoManager: makeUndoManager())
    let scale = service.scale(in: reopened, page: 0)
    check(scale.unit == .m && abs(scale.length(144) - 20) < 0.001, "the scale reads back from /Measure (\(scale))")
    check(Measure.format(12.345, unit: .m, area: false) == Measure.format(12.3, unit: .m, area: false) && Measure.format(2, unit: .ft, area: true) == "2 sq ft",
          "values round to tenths above ten, square units for areas")
}

@MainActor
private func markupSketch() {
    let service = markupService()
    let document = markupDocument("Sketch")
    let session = service.session(for: document)
    let page = document.pdf.page(at: 0)!
    session.choose(.sketch)
    func wobble(_ i: Int) -> CGFloat { CGFloat((i * 37) % 7) - 3 }
    var ring: [CGPoint] = []
    for i in 0...60 { let a = Double(i) / 60 * 2 * .pi; ring.append(CGPoint(x: 300 + 80 * cos(a) + wobble(i) * 0.6, y: 400 + 50 * sin(a) + wobble(i + 3) * 0.6)) }
    check(session.finishStroke(ring, on: page)?.type == "Circle", "a rough ring sketches into an oval")
    let straight = (0...30).map { CGPoint(x: 100 + CGFloat($0) * 6, y: 100 + CGFloat($0) * 2 + wobble($0) * 0.5) }
    check(session.finishStroke(straight, on: page)?.type == "Line", "a nearly straight stroke becomes a line")
    let zigzag = (0...30).map { CGPoint(x: 100 + CGFloat($0) * 6, y: 600 + ($0 % 2 == 0 ? 0 : 30)) }
    check(session.finishStroke(zigzag, on: page)?.type == "Ink", "a scribble stays a drawing")
    session.choose(.draw)
    check(session.finishStroke(ring, on: page)?.type == "Ink", "Draw keeps the ring as drawn")
    check(document.undoManager?.undoActionName == "Add Sketch", "undo name for a drawing")
}

@MainActor
private func markupCommands() {
    let service = markupService()
    let document = markupDocument("Commands")
    check(service.validate(.zoomIn, in: document) == nil && !service.perform(.zoomIn, in: document), "not a markup command")
    check(service.validate(.highlightText, in: document) == true, "Highlight Text is enabled")
    check(service.perform(.underlineText, in: document), "Underline Text performs")
    let session = service.session(for: document)
    check(session.tool == .highlight && session.style.textMarkup == .underline && service.isMarkupBarVisible(in: document), "underline mode, bar shown")
    _ = service.perform(.highlightText, in: document)
    check(session.style.textMarkup == .highlight(.yellow), "Highlight Text goes back to a highlight colour")
    _ = service.perform(.rectangle, in: document)
    check(session.tool == .shape(.rectangle), "⌃⌘R picks the rectangle")
    _ = service.perform(.loupe, in: document)
    check(session.tool == .shape(.loupe), "⌃⌘L picks the loupe")
    service.setMarkupBarVisible(false, in: document)
    check(!service.isMarkupBarVisible(in: document) && session.tool == .textSelection, "hiding the bar returns to Text Selection")
    document.state.permissions.commenting = false
    check(service.validate(.note, in: document) == false && !service.perform(.note, in: document), "no markup when the file doesn't allow commenting")
}

@MainActor
private func markupPanels() {
    let service = markupService()
    let documents = Services.documents as! FakeDocuments
    let document = markupDocument("Panels")
    markupEverything(document, service: service)
    let provider = Services.toolProviders.last as! MarkupToolProvider
    for tool in [ToolID.highlightAndNotes, .drawAndShapes, .commentsList, .attachFile, .measure] { Defaults.reset(ToolSession.valuesKey(tool)) }

    let highlight = ToolSession(tool: .highlightAndNotes, provider: provider, document: document)
    check(highlight.panel.archetype == .mode && highlight.panel.primary.title == Strings.Panel.done, "Highlight & notes is a mode panel with Done")
    check(service.session(for: document).tool == .highlight && service.isMarkupBarVisible(in: document), "opening it picks Highlight and shows the bar")
    let done = complete { await highlight.run() }
    if case .success(.none?)? = done {} else { check(false, "Done closes with nothing to apply") }
    check(service.session(for: document).tool == .textSelection, "Done stops marking")

    let draw = ToolSession(tool: .drawAndShapes, provider: provider, document: document)
    check(service.session(for: document).tool == .sketch, "Draw & shapes starts with Sketch")
    _ = complete { await draw.run() }

    let comments = ToolSession(tool: .commentsList, provider: provider, document: document)
    let chips = comments.panel.controls.compactMap { control -> [ToolOption]? in if case .chips(_, let options, _, _) = control { options } else { nil } }.first ?? []
    let total = service.comments(in: document).count
    check(chips.map(\.id) == ["all", "mine", "unresolved"] && chips.first?.value == String(total), "filter chips with counts: \(chips.map { $0.value ?? "" })")
    check(chips.last?.value == String(total - 1), "the accepted comment isn't unresolved")
    let exported = markupFolder.appendingPathComponent("Panel export.xfdf")
    provider.chooseExport = { _ in exported }
    comments.set("format", .string("xfdf"))
    _ = complete { await comments.perform("export") }
    check(FileManager.default.fileExists(atPath: exported.path), "Export comments… writes the file")
    let before = documents.openDocuments.count
    _ = complete { await comments.perform("summarise") }
    check(documents.openDocuments.count == before + 1 && documents.openDocuments.last?.displayName == "Panels (comments)", "Summarise opens a new document")

    let attach = ToolSession(tool: .attachFile, provider: provider, document: document)
    check(!attach.panel.primary.isEnabled && attach.panel.primary.title == "Attach file", "Attach file waits for a file")
    let file = markupFolder.appendingPathComponent("photo list.txt")
    try? Data("one".utf8).write(to: file)
    attach.set("file", .files([file]))
    check(attach.panel.primary.isEnabled, "a chosen file enables Attach file")
    let clips = { document.pdf.page(at: 0)!.annotations.filter { $0.type == "FileAttachment" }.count }
    let clipsBefore = clips()
    _ = complete { await attach.run() }
    check(clips() == clipsBefore + 1, "the run clips the file to the page")
    attach.set("kind", .string("voice"))
    check(attach.panel.primary.title == "Attach voice note" && !attach.panel.primary.isEnabled, "voice note waits for a recording")

    let measure = ToolSession(tool: .measure, provider: provider, document: document)
    check(service.session(for: document).tool == .measure(.distance), "Measure starts with Distance")
    measure.set("kind", .string("area"))
    check(service.session(for: document).tool == .measure(.area), "the switch picks Area")
    let fresh = markupDocument("Panels measure")
    let measureFresh = ToolSession(tool: .measure, provider: provider, document: fresh)
    _ = complete { await measureFresh.perform("setScale") }
    check(measureFresh.failure?.text == "Draw a line on the page first, then type how long it really is.", "Set scale needs a line first")
    service.session(for: fresh).finishMeasurement(.distance, points: [CGPoint(x: 100, y: 100), CGPoint(x: 172, y: 100)], on: fresh.pdf.page(at: 0)!)
    measureFresh.set("real", .string("5"))
    measureFresh.set("unit", .string("m"))
    _ = complete { await measureFresh.perform("setScale") }
    check(service.scale(in: fresh, page: 0).length(72) == 5, "this line is 5 m")
    measureFresh.refresh()
    check(measureFresh.panel.controls.contains { if case .note(let text) = $0 { text == "Scale: 1 in = 5 m" } else { false } }, "the panel says the scale")
}

/// Drives the layer over a real PDFView with mouse events: a rectangle drag, a highlight drag, a move, a measure.
@MainActor
private func markupLayer() {
    let service = markupService()
    let document = markupDocument("Layer", pages: 1)
    let (window, view) = markupWindow(document)
    let session = service.session(for: document)
    session.setBarVisible(true)
    let accessory = window.titlebarAccessoryViewControllers.first
    check(window.titlebarAccessoryViewControllers.count == 1 && accessory?.layoutAttribute == .bottom && accessory?.view is MarkupBarView
          && (accessory?.view.frame.height ?? 0) >= SPMetrics.MarkupBar.height, "the bar sits under the toolbar (\(accessory?.view.frame.height ?? 0) pt)")
    guard let overlay = view.subviews.compactMap({ $0 as? MarkupOverlayView }).first else { check(false, "the layer is over the PDFView"); return }
    let page = document.pdf.page(at: 0)!
    func viewPoint(_ p: CGPoint) -> CGPoint { overlay.convert(view.convert(p, from: page), from: view) }
    func mouse(_ type: NSEvent.EventType, _ p: CGPoint, clicks: Int = 1, shift: Bool = false) -> NSEvent {
        NSEvent.mouseEvent(with: type, location: overlay.convert(viewPoint(p), to: nil), modifierFlags: shift ? .shift : [], timestamp: 0,
                           windowNumber: window.windowNumber, context: nil, eventNumber: 0, clickCount: clicks, pressure: 1)!
    }
    // In Text Selection mode the layer lets clicks on text through.
    check(overlay.hitTest(overlay.convert(viewPoint(CGPoint(x: 100, y: 660)), to: overlay.superview)) == nil, "text selection passes through")
    session.choose(.shape(.rectangle))
    overlay.mouseDown(with: mouse(.leftMouseDown, CGPoint(x: 100, y: 300)))
    overlay.mouseDragged(with: mouse(.leftMouseDragged, CGPoint(x: 160, y: 340)))
    overlay.mouseUp(with: mouse(.leftMouseUp, CGPoint(x: 200, y: 360)))
    let square = page.annotations.first { $0.type == "Square" }
    check(square.map { abs($0.bounds.minX - 100) < 1 && abs($0.bounds.maxX - 200) < 1 && abs($0.bounds.maxY - 360) < 1 } == true,
          "a drag draws the rectangle where the pointer went (\(square?.bounds ?? .zero))")
    check(session.tool == .textSelection && session.selection?.annotation === square, "the new rectangle is selected")
    // Drag it by its middle.
    overlay.mouseDown(with: mouse(.leftMouseDown, CGPoint(x: 150, y: 330)))
    overlay.mouseDragged(with: mouse(.leftMouseDragged, CGPoint(x: 170, y: 320)))
    overlay.mouseUp(with: mouse(.leftMouseUp, CGPoint(x: 180, y: 310)))
    check(square.map { abs($0.bounds.minX - 130) < 1 && abs($0.bounds.minY - 280) < 1 } == true, "dragging moves it (\(square?.bounds ?? .zero))")
    check(document.undoManager?.undoActionName == "Move", "one Move on the undo stack")
    // Highlight by dragging across a line of text.
    session.choose(.highlight)
    overlay.mouseDown(with: mouse(.leftMouseDown, CGPoint(x: 72, y: 664)))
    overlay.mouseDragged(with: mouse(.leftMouseDragged, CGPoint(x: 200, y: 664)))
    overlay.mouseUp(with: mouse(.leftMouseUp, CGPoint(x: 300, y: 664)))
    let highlight = page.annotations.first { $0.type == "Highlight" }
    check(highlight != nil && service.comments(in: document).first { $0.kind == .highlight }?.quotedText?.contains("quick brown") == true, "a drag across words highlights them")
    // An area: three clicks and a double-click.
    session.choose(.measure(.area))
    for p in [CGPoint(x: 300, y: 100), CGPoint(x: 372, y: 100), CGPoint(x: 372, y: 172)] {
        overlay.mouseDown(with: mouse(.leftMouseDown, p)); overlay.mouseUp(with: mouse(.leftMouseUp, p))
    }
    overlay.mouseDown(with: mouse(.leftMouseDown, CGPoint(x: 300, y: 172)))
    overlay.mouseUp(with: mouse(.leftMouseUp, CGPoint(x: 300, y: 172)))
    overlay.mouseDown(with: mouse(.leftMouseDown, CGPoint(x: 300, y: 172), clicks: 2))
    check(page.annotations.first { Measure.kind(of: $0) == .area }?.contents == "1 sq in", "click, click, double-click measures an area")
    session.choose(.textSelection)
    session.select(square!, on: page)
    renderLayer(window: window, view: view, overlay: overlay, document: document, name: "markup-selection")
    window.close()
}

// MARK: - Renders

@MainActor
private func markupRenders() {
    let service = markupService()
    let document = markupDocument("Renders", pages: 1)
    markupEverything(document, service: service)
    let page = document.pdf.page(at: 0)!
    savePage(page, "markup-page", scale: 1.5)
    let url = markupSave(document, as: "Renders (saved)")
    let reopenedDocument = PDFDocument(url: url)!
    let reopened = reopenedDocument.page(at: 0)!
    savePage(reopened, "markup-page-reopened", scale: 1.5)
    // The saved appearances draw what the live annotations drew.
    let live = pageBitmap(page, scale: 1), saved = pageBitmap(reopened, scale: 1)
    var differing = 0
    for y in stride(from: 0, to: 792, by: 3) {
        for x in stride(from: 0, to: 612, by: 3) {
            let a = live.colorAt(x: x, y: y)!.usingColorSpace(.deviceRGB)!, b = saved.colorAt(x: x, y: y)!.usingColorSpace(.deviceRGB)!
            if abs(a.redComponent - b.redComponent) + abs(a.greenComponent - b.greenComponent) + abs(a.blueComponent - b.blueComponent) > 0.6 { differing += 1 }
        }
    }
    check(differing < 600, "the reopened page looks like the live one (\(differing) of \(204 * 264) samples differ)")
    func inked(_ rep: NSBitmapImageRep, _ rect: CGRect) -> Bool {
        stride(from: Int(rect.minX), to: Int(rect.maxX), by: 2).contains { x in
            stride(from: Int(rect.minY), to: Int(rect.maxY), by: 2).contains { y in
                let c = rep.colorAt(x: x, y: 792 - 1 - y)!.usingColorSpace(.deviceRGB)!
                return c.redComponent + c.greenComponent + c.blueComponent < 2.4
            }
        }
    }
    for (name, rect) in [("star", CGRect(x: 300, y: 320, width: 70, height: 70)), ("cloud", CGRect(x: 480, y: 320, width: 90, height: 70)),
                         ("stamp", CGRect(x: 325, y: 225, width: 150, height: 50)), ("bubble", CGRect(x: 180, y: 320, width: 100, height: 70)),
                         ("area", CGRect(x: 360, y: 130, width: 72, height: 72)), ("paper clip", CGRect(x: 560, y: 100, width: 14, height: 20))] {
        check(inked(saved, rect), "the reopened \(name) draws from its saved appearance")
    }
    // The bar, light and dark.
    for dark in [false, true] {
        let session = service.session(for: document)
        session.choose(.highlight)
        let bar = MarkupBarView(session: session)
        let rep = renderView(bar, size: NSSize(width: 820, height: SPMetrics.MarkupBar.height), dark: dark)
        save(rep, dark ? "markup-bar-dark" : "markup-bar")
        session.choose(.textSelection)
    }
    // The panels, as ToolsKit draws them.
    let provider = Services.toolProviders.last as! MarkupToolProvider
    for tool in [ToolID.highlightAndNotes, .drawAndShapes, .commentsList, .attachFile, .measure] {
        Defaults.reset(ToolSession.valuesKey(tool))
        let session = ToolSession(tool: tool, provider: provider, document: document)
        let controller = ToolPanelController(session: session, onBack: {}, onClose: {})
        save(renderView(controller.view, size: NSSize(width: SPMetrics.ToolPanel.width, height: 760)), "markup-panel-\(tool.rawValue)")
        _ = complete { await session.run() }
    }
}

@MainActor
private func markupWindow(_ document: DocumentHandle) -> (NSWindow, PDFView) {
    let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 900, height: 700), styleMask: [.titled, .closable, .resizable], backing: .buffered, defer: false)
    window.isReleasedWhenClosed = false
    window.toolbar = NSToolbar(identifier: "markup-test")
    let view = PDFView(frame: window.contentView!.bounds)
    view.autoresizingMask = [.width, .height]
    view.document = document.pdf
    view.autoScales = true
    window.contentView!.addSubview(view)
    let viewer = MarkupTestViewer(view: view)
    Services.viewer = viewer
    view.layoutDocumentView()
    return (window, view)
}

/// A viewer whose document shows in a real PDFView (FakeViewer has none).
@MainActor
private final class MarkupTestViewer: ViewerPresenting {
    let view: PDFView
    init(view: PDFView) { self.view = view }
    func makeWindowController(for document: DocumentHandle) -> NSWindowController { NSWindowController(window: view.window) }
    func pdfView(for document: DocumentHandle) -> PDFView? { view }
    func selectedPages(in document: DocumentHandle) -> [Int] { [] }
    func currentPage(in document: DocumentHandle) -> Int { 0 }
    func showToolPanel(_ panel: NSViewController?, in document: DocumentHandle) {}
    func showBanner(_ banner: ResultBanner, in document: DocumentHandle) {}
    func showSidebar(_ mode: SidebarMode, in document: DocumentHandle) {}
    func showOrganiser(for document: DocumentHandle, adding files: [URL]) {}
    func showWelcome() {}
    func password(forLocked fileName: String, retry: Bool) async -> String? { nil }
}

@MainActor
private func pageBitmap(_ page: PDFKit.PDFPage, scale: CGFloat) -> NSBitmapImageRep {
    let size = page.bounds(for: .mediaBox).size
    let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: Int(size.width * scale), pixelsHigh: Int(size.height * scale), bitsPerSample: 8,
                               samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
    NSGraphicsContext.saveGraphicsState()
    let context = NSGraphicsContext(bitmapImageRep: rep)!
    NSGraphicsContext.current = context
    context.cgContext.setFillColor(.white)
    context.cgContext.fill(CGRect(x: 0, y: 0, width: rep.pixelsWide, height: rep.pixelsHigh))
    context.cgContext.scaleBy(x: scale, y: scale)
    page.draw(with: .mediaBox, to: context.cgContext)
    NSGraphicsContext.restoreGraphicsState()
    return rep
}

@MainActor
private func savePage(_ page: PDFKit.PDFPage, _ name: String, scale: CGFloat) { save(pageBitmap(page, scale: scale), name) }

@MainActor
private func renderView(_ view: NSView, size: NSSize, dark: Bool = false) -> NSBitmapImageRep {
    let window = NSWindow(contentRect: NSRect(origin: .zero, size: size), styleMask: [.borderless], backing: .buffered, defer: false)
    window.isReleasedWhenClosed = false
    window.appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
    window.contentView = view
    view.frame = NSRect(origin: .zero, size: size)
    view.layoutSubtreeIfNeeded()
    RunLoop.main.run(until: Date().addingTimeInterval(0.05))
    view.layoutSubtreeIfNeeded()
    let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: Int(size.width * 2), pixelsHigh: Int(size.height * 2), bitsPerSample: 8,
                               samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
    rep.size = size
    window.appearance!.performAsCurrentDrawingAppearance {
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
        (dark ? NSColor(hex: SPColor.windowBackground.dark) : NSColor(hex: SPColor.windowBackground.light)).setFill()
        NSRect(origin: .zero, size: size).fill()
        NSGraphicsContext.restoreGraphicsState()
        view.cacheDisplay(in: view.bounds, to: rep)
    }
    window.close()
    return rep
}

/// The PDFView's pages as the window server would draw them, with the layer (handles, selection) on top.
@MainActor
private func renderLayer(window: NSWindow, view: PDFView, overlay: NSView, document: DocumentHandle, name: String) {
    let size = view.bounds.size
    let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: Int(size.width * 2), pixelsHigh: Int(size.height * 2), bitsPerSample: 8,
                               samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
    rep.size = size
    NSGraphicsContext.saveGraphicsState()
    let context = NSGraphicsContext(bitmapImageRep: rep)!
    NSGraphicsContext.current = context
    NSColor(hex: SPColor.underPageBackground.light).setFill()
    NSRect(origin: .zero, size: size).fill()
    for index in 0..<document.pageCount {
        guard let page = document.pdf.page(at: index) else { continue }
        let rect = view.convert(page.bounds(for: .cropBox), from: page)
        guard rect.intersects(view.bounds) else { continue }
        NSColor.white.setFill()
        rect.fill()
        let cg = context.cgContext
        cg.saveGState()
        cg.translateBy(x: rect.minX, y: rect.minY)
        cg.scaleBy(x: rect.width / page.bounds(for: .cropBox).width, y: rect.height / page.bounds(for: .cropBox).height)
        page.draw(with: .cropBox, to: cg)
        cg.restoreGState()
    }
    overlay.displayIgnoringOpacity(overlay.bounds, in: context)
    NSGraphicsContext.restoreGraphicsState()
    save(rep, name)
}

@discardableResult
private func save(_ rep: NSBitmapImageRep, _ name: String) -> String {
    let url = markupRenderFolder.appendingPathComponent(name + ".png")
    try? rep.representation(using: .png, properties: [:])?.write(to: url)
    print("  render: \(url.path)")
    return url.path
}
