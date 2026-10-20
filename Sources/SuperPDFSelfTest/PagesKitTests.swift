import AppKit
import Combine
@testable import PagesKit
import PDFKit
import PDFModelKit
import RenderKit
import SuperPDFCore
@testable import ToolsKit

// PagesKit's checks (WP6): every page edit and its undo, the panels of the Pages tiles driven headlessly through
// ToolsKit's `ToolSession` as the app drives them, and their outputs re-opened from disk: combine, split (every N,
// ranges, contents entries, blank pages, size plans) with its naming, extract, insert, crop with white-margin
// detection and the crop box maths, number pages with page labels, booklet and resize. Fixtures are generated into
// fresh temporary folders.
func registerPagesKitTests() {
    SelfTest.cases.append(("PagesKit.install", { pagesKitInstall() }))
    SelfTest.cases.append(("PagesKit.editor", { pagesKitEditor() }))
    SelfTest.cases.append(("PagesKit.rotateDelete", { pagesKitRotateDelete() }))
    SelfTest.cases.append(("PagesKit.extract", { pagesKitExtract() }))
    SelfTest.cases.append(("PagesKit.split", { pagesKitSplit() }))
    SelfTest.cases.append(("PagesKit.blankPages", { pagesKitBlankPages() }))
    SelfTest.cases.append(("PagesKit.combine", { pagesKitCombine() }))
    SelfTest.cases.append(("PagesKit.insert", { pagesKitInsert() }))
    SelfTest.cases.append(("PagesKit.crop", { pagesKitCrop() }))
    SelfTest.cases.append(("PagesKit.numberPages", { pagesKitNumberPages() }))
    SelfTest.cases.append(("PagesKit.booklet", { pagesKitBooklet() }))
    SelfTest.cases.append(("PagesKit.resize", { pagesKitResize() }))
}

// MARK: - Fixtures

private func pagesFolder(_ name: String) -> URL {
    SuperPDFPaths.ensure(scratch.appendingPathComponent("PagesKit-\(name)-\(UUID().uuidString)", isDirectory: true))
}

/// A PDF whose pages say the given words (nil: a blank page), Letter size unless `size` says otherwise.
private func pagesPDF(_ texts: [String?], size: CGSize = CGSize(width: 612, height: 792)) -> Data {
    let data = NSMutableData()
    var box = CGRect(origin: .zero, size: size)
    guard let consumer = CGDataConsumer(data: data as CFMutableData), let context = CGContext(consumer: consumer, mediaBox: &box, nil) else { return Data() }
    for text in texts {
        context.beginPDFPage(nil)
        if let text {
            let line = CTLineCreateWithAttributedString(NSAttributedString(string: text, attributes: [.font: NSFont.systemFont(ofSize: 24)]))
            context.textPosition = CGPoint(x: 72, y: size.height - 96)
            CTLineDraw(line, context)
        }
        context.endPDFPage()
    }
    context.closePDF()
    return data as Data
}

/// "Page 1" … "Page n".
private func numbered(_ n: Int) -> [String?] { (1...n).map { "Page \($0)" } }

/// An open document saved as "Report.pdf" in a fresh folder.
@MainActor
private func savedDocument(_ texts: [String?], folder: URL, name: String = "Report.pdf") -> DocumentHandle {
    let url = folder.appendingPathComponent(name)
    try? pagesPDF(texts).write(to: url)
    return DocumentHandle(url: url, pdf: PDFDocument(url: url)!, undoManager: makeUndoManager())
}

/// The words on each page, in order.
@MainActor
private func texts(_ pdf: PDFDocument?) -> [String] {
    guard let pdf else { return [] }
    return (0..<pdf.pageCount).map { (pdf.page(at: $0)?.string ?? "").trimmingCharacters(in: .whitespacesAndNewlines) }
}

/// DocumentKit as far as these checks need it: names from `FakeDocuments`, undo registered as DocumentKit does
/// (`.contents` results swap the PDF), new files moved to their destination so they can be re-opened, new documents kept.
@MainActor
private final class PagesTestDocuments: DocumentManaging {
    let names = FakeDocuments()
    var openDocuments: [DocumentHandle] { names.openDocuments }
    var frontmost: DocumentHandle? { names.frontmost }
    var events: AnyPublisher<DocumentEvent, Never> { names.events }
    var recentDocuments: [RecentDocument] { [] }
    var placed: [URL] = []
    var newDocuments: [(data: Data, name: String, banner: ResultBanner?)] = []
    var banners: [ResultBanner] = []

    func open(_ url: URL) async throws -> DocumentHandle { try await names.open(url) }
    func openUntitled(_ data: Data, name: String) throws -> DocumentHandle { try names.openUntitled(data, name: name) }
    func destination(for policy: OutputPolicy, of document: DocumentHandle?, source: URL?) -> URL? {
        names.destination(for: policy, of: document, source: source)
    }
    func removeRecent(_ url: URL) {}
    func viewState(for url: URL) -> DocumentViewState? { nil }
    func saveViewState(_ state: DocumentViewState, for url: URL) {}

    func apply(_ result: ToolResult, of request: ToolRequest) async throws {
        switch result {
        case .inPlace(let group, _):
            guard let document = request.document else { return }
            let manager = document.undoManager
            manager?.beginUndoGrouping()
            switch group.change {
            case .actions: manager?.register(group)
            case .contents(let before, let after):
                document.pdf = PDFDocument(data: after)!
                swap(document, back: before, forth: after)
            }
            manager?.endUndoGrouping()
        case .newFile(let file, let banner):
            let target = request.destination ?? file
            if target != file { try FileManager.default.copyItem(at: file, to: target) }
            placed.append(target); banners.append(banner)
        case .newFiles(let files, let banner):
            let folder = SuperPDFPaths.ensure(request.destination!)
            for file in files {
                let target = folder.appendingPathComponent(file.lastPathComponent)
                try FileManager.default.copyItem(at: file, to: target)
                placed.append(target)
            }
            banners.append(banner)
        case .newDocument(let data, let name, let banner):
            newDocuments.append((data, name, banner))
        case .none:
            break
        }
    }

    private func swap(_ document: DocumentHandle, back: Data, forth: Data) {
        document.undoManager?.registerUndo(withTarget: self) { target in
            MainActor.assumeIsolated {
                document.pdf = PDFDocument(data: back)!
                target.swap(document, back: forth, forth: back)
            }
        }
    }
}

/// Fakes everywhere, the test DocumentKit, and a fresh PagesKit; choices remembered by earlier sessions forgotten.
@MainActor
private func installPages() -> (tools: PagesTools, documents: PagesTestDocuments) {
    installFakes()
    let documents = PagesTestDocuments()
    Services.documents = documents
    PagesKitModule.install()
    for tool in ToolCatalog.tiles(ownedBy: .pagesKit).map(\.id) { Defaults.reset(ToolSession.valuesKey(tool)) }
    return (Services.toolProviders.compactMap { $0 as? PagesTools }.first!, documents)
}

@MainActor
private func session(_ tool: ToolID, _ tools: PagesTools, _ document: DocumentHandle?, inputs: [URL] = [], selection: [Int] = [],
                     currentPage: Int = 0) -> ToolSession {
    ToolSession(tool: tool, provider: tools, document: document, inputs: inputs, selection: selection, currentPage: currentPage)
}

/// Runs a session to the end; nil when it failed (its message is checked by the caller).
@MainActor
@discardableResult
private func run(_ session: ToolSession) -> ToolResult? {
    guard case .success(let result)? = (complete { await session.run() }) else { return nil }
    return result
}

// MARK: - Install and coverage

@MainActor
private func pagesKitInstall() {
    let (tools, _) = installPages()
    check(Services.pages is PageEditor, "Services.pages is PagesKit's editor")
    check(Set(tools.tools) == Set(ToolCatalog.tiles(ownedBy: .pagesKit).map(\.id)) && tools.tools.count == 11, "all eleven Pages tiles")
    check(ToolCoverage.issues(Services.toolProviders, requireAll: false).isEmpty, "PagesKit covers its tiles exactly once")
    let document = makeDocument(pages: 4)
    for tool in tools.tools {
        let panel = tools.panel(for: tool, context: ToolContext(tool: tool, document: document))
        check(panel.archetype == ToolCatalog.tile(tool).archetype, "\(tool.rawValue): archetype \(panel.archetype.letter)")
        check(panel.controls.filter(\.isChoice).count <= 3, "\(tool.rawValue): at most three visible choices")
        check(!["OK", "Apply", "Process", "Export"].contains(panel.primary.title), "\(tool.rawValue): the button is a verb")
    }
    installFakes()
}

// MARK: - Page edits (Services.pages)

@MainActor
private func pagesKitEditor() {
    let editor = PageEditor()
    let document = DocumentHandle(url: nil, displayName: "Report", pdf: PDFDocument(data: pagesPDF(numbered(5)))!, undoManager: makeUndoManager())
    let start = texts(document.pdf)
    func perform(_ operation: PageOperation) -> UndoGroup? {
        guard case .success(let group)? = (complete { try await editor.perform(operation, in: document) }) else { return nil }
        return group
    }
    func roundTrip(_ operation: PageOperation, expect: [String], _ what: String) {
        guard let group = perform(operation) else { check(false, "\(what) failed"); return }
        check(texts(document.pdf) == expect, "\(what): \(texts(document.pdf))")
        group.undo()
        check(texts(document.pdf) == start, "\(what) undone: \(texts(document.pdf))")
        group.redo()
        check(texts(document.pdf) == expect, "\(what) redone")
        group.undo()
    }
    roundTrip(.move([0, 1], to: 3), expect: ["Page 3", "Page 4", "Page 5", "Page 1", "Page 2"], "move to the end")
    roundTrip(.move([4], to: 0), expect: ["Page 5", "Page 1", "Page 2", "Page 3", "Page 4"], "move to the front")
    roundTrip(.delete([1, 3]), expect: ["Page 1", "Page 3", "Page 5"], "delete")
    roundTrip(.duplicate([1]), expect: ["Page 1", "Page 2", "Page 2", "Page 3", "Page 4", "Page 5"], "duplicate")
    roundTrip(.reverse, expect: ["Page 5", "Page 4", "Page 3", "Page 2", "Page 1"], "reverse")
    roundTrip(.insertBlank(after: -1), expect: ["", "Page 1", "Page 2", "Page 3", "Page 4", "Page 5"], "blank at the front")
    roundTrip(.insertBlank(after: 2), expect: ["Page 1", "Page 2", "Page 3", "", "Page 4", "Page 5"], "blank after page 3")
    let other = PDFSource.data(pagesPDF(["A", "B", "C"]))
    roundTrip(.insertFile(other, pages: [2, 0], at: 1), expect: ["Page 1", "C", "A", "Page 2", "Page 3", "Page 4", "Page 5"], "insert from a file")
    roundTrip(.insertFile(other, pages: [], at: 5), expect: ["Page 1", "Page 2", "Page 3", "Page 4", "Page 5", "A", "B", "C"], "append a file")
    roundTrip(.replace(1...2, with: other, pages: []), expect: ["Page 1", "A", "B", "C", "Page 4", "Page 5"], "replace")

    // Rotation turns and turns back; saved as /Rotate.
    if let group = perform(.rotate([0, 2], quarterTurns: -1)) {
        check(document.pdf.page(at: 0)?.rotation == 270 && document.pdf.page(at: 1)?.rotation == 0 && document.pdf.page(at: 2)?.rotation == 270, "rotate left")
        group.undo()
        check(document.pdf.page(at: 0)?.rotation == 0, "rotate undone")
    }
    // Comments stay on replaced pages of the same size.
    let note = PDFAnnotation(bounds: CGRect(x: 100, y: 100, width: 20, height: 20), forType: .text, withProperties: nil)
    note.contents = "keep me"
    document.pdf.page(at: 1)?.addAnnotation(note)
    if let group = perform(.replace(1...1, with: other, pages: [0])) {
        check(document.pdf.page(at: 1)?.annotations.contains { $0.contents == "keep me" } == true, "comments kept on the replacing page")
        group.undo()
    }

    // Refusals.
    if case .failure(let error)? = (complete { try await editor.perform(.delete([0, 1, 2, 3, 4]), in: document) }) {
        check(error as? PageEditError == .lastPage && error.localizedDescription == "A PDF needs at least one page.", "never the last page")
    } else { check(false, "deleting every page is refused") }
    if case .failure(let error)? = (complete { try await editor.perform(.rotate([9], quarterTurns: 1), in: document) }) {
        check(error as? PageEditError == .pagesOutOfRange, "pages out of range")
    } else { check(false, "a page past the end is refused") }
    document.state.permissions.pageChanges = false
    if case .failure(let error)? = (complete { try await editor.perform(.reverse, in: document) }) {
        check(error as? PageEditError == .notAllowed, "owner-restricted page changes")
    } else { check(false, "page changes the file forbids are refused") }
    document.state.permissions.pageChanges = true

    // Extract and copy between documents.
    if let data = try? editor.extract([3, 0], from: document) {
        check(texts(PDFDocument(data: data)) == ["Page 4", "Page 1"], "extract keeps the order asked")
    } else { check(false, "extract") }
    let target = DocumentHandle(url: nil, displayName: "Other", pdf: PDFDocument(data: pagesPDF(["X", "Y"]))!, undoManager: makeUndoManager())
    if let group = try? editor.copy([4], from: document, to: target, at: 1) {
        check(texts(target.pdf) == ["X", "Page 5", "Y"] && document.pageCount == 5, "copy pages to another document")
        group.undo()
        check(texts(target.pdf) == ["X", "Y"], "copy undone")
    } else { check(false, "copy") }
}

// MARK: - Rotate and Delete (A)

@MainActor
private func pagesKitRotateDelete() {
    let (tools, _) = installPages()
    let document = makeDocument(pages: 4)
    let rotate = session(.rotatePages, tools, document, selection: [0, 2])
    check(rotate.panel.primary.title == "Rotate 2 pages" && rotate.panel.showsScope, "Rotate: \(rotate.panel.primary.title)")
    run(rotate)
    check(document.pdf.page(at: 0)?.rotation == 90 && document.pdf.page(at: 1)?.rotation == 0 && document.pdf.page(at: 2)?.rotation == 90, "rotated right")
    document.undoManager?.undo()
    check(document.pdf.page(at: 0)?.rotation == 0 && document.pdf.page(at: 2)?.rotation == 0, "⌘Z turns them back")

    // "All sideways pages": the pages seen wider than tall.
    document.pdf.page(at: 3)?.rotation = 90
    let sideways = session(.rotatePages, tools, document)
    sideways.set(PagesTools.Key.sideways, .bool(true))
    sideways.set(PagesTools.Key.direction, .string("left"))
    check(sideways.panel.primary.title == "Rotate 1 page", "one sideways page: \(sideways.panel.primary.title)")
    run(sideways)
    check(document.pdf.page(at: 3)?.rotation == 0, "the sideways page is upright")
    let none = session(.rotatePages, tools, document)
    check(!none.canRun && none.message?.text == "No pages are sideways.", "nothing sideways")
    none.set(PagesTools.Key.sideways, .bool(false))

    let all = session(.deletePages, tools, document)
    check(!all.canRun && all.message?.text == "A PDF needs at least one page." && all.panel.primary.isDestructive, "never delete every page")
    let some = session(.deletePages, tools, document, selection: [1, 2])
    check(some.panel.primary.title == "Delete 2 pages" && some.canRun, "Delete 2 pages")
    run(some)
    check(texts(document.pdf) == ["Page 1", "Page 4"], "deleted: \(texts(document.pdf))")
    document.undoManager?.undo()
    check(document.pageCount == 4, "delete undone")
    installFakes()
}

// MARK: - Extract (A)

@MainActor
private func pagesKitExtract() {
    let (tools, documents) = installPages()
    let folder = pagesFolder("extract")
    let document = savedDocument(numbered(6), folder: folder)
    let extract = session(.extractPages, tools, document, selection: [1, 2, 3])
    check(extract.panel.primary.title == "Save pages as PDF…", "Extract's button")
    check(extract.outputLine?.fileName == "Report – pages 2-4.pdf", "naming: \(extract.outputLine?.fileName ?? "-")")
    run(extract)
    let file = folder.appendingPathComponent("Report – pages 2-4.pdf")
    check(texts(PDFDocument(url: file)) == ["Page 2", "Page 3", "Page 4"] && document.pageCount == 6, "the pages saved, the document unchanged")
    check(documents.banners.last?.text == "Saved “Report – pages 2-4.pdf”.", "banner: \(documents.banners.last?.text ?? "-")")

    // Each page as its own file, removed from the document (one undo step).
    let each = session(.extractPages, tools, document, selection: [0, 5])
    each.set(PagesTools.Key.each, .bool(true))
    each.set(PagesTools.Key.remove, .bool(true))
    check(each.outputLine?.fileName == "Report parts", "a folder: \(each.outputLine?.fileName ?? "-")")
    run(each)
    let parts = folder.appendingPathComponent("Report parts")
    check(texts(PDFDocument(url: parts.appendingPathComponent("Report – pages 1.pdf"))) == ["Page 1"]
          && texts(PDFDocument(url: parts.appendingPathComponent("Report – pages 6.pdf"))) == ["Page 6"], "one file per page")
    check(texts(document.pdf) == ["Page 2", "Page 3", "Page 4", "Page 5"], "removed from the document")
    document.undoManager?.undo()
    check(document.pageCount == 6, "removal undone")

    let everything = session(.extractPages, tools, document)
    everything.set(PagesTools.Key.remove, .bool(true))
    check(!everything.canRun && everything.message?.text == "A PDF needs at least one page.", "can't remove every page")
    everything.set(PagesTools.Key.remove, .bool(false))
    everything.set(PagesTools.Key.each, .bool(false))
    installFakes()
}

// MARK: - Split (B)

@MainActor
private func pagesKitSplit() {
    let (tools, documents) = installPages()
    let folder = pagesFolder("split")
    let document = savedDocument(numbered(6), folder: folder)
    let split = session(.split, tools, document)
    check(split.panel.archetype == .presetAndMore && split.outputLine?.fileName == "Report parts", "Split writes a folder")
    split.set(PagesTools.Key.every, .int(2))
    check(split.panel.primary.title == "Split into 3 files", "every 2: \(split.panel.primary.title)")
    run(split)
    let parts = folder.appendingPathComponent("Report parts")
    check(texts(PDFDocument(url: parts.appendingPathComponent("Report – part 1.pdf"))) == ["Page 1", "Page 2"]
          && texts(PDFDocument(url: parts.appendingPathComponent("Report – part 3.pdf"))) == ["Page 5", "Page 6"], "parts named and filled")
    check(documents.banners.last?.text == "Saved 3 files in “Report parts”.", "banner: \(documents.banners.last?.text ?? "-")")

    // Ranges, and a range that isn't one.
    let ranges = session(.split, tools, document)
    ranges.set(PagesTools.Key.mode, .string("ranges"))
    ranges.set(PagesTools.Key.ranges, .string("1-2, 5–6"))
    check(ranges.panel.primary.title == "Split into 2 files", "ranges: \(ranges.panel.primary.title)")
    run(ranges)
    let second = folder.appendingPathComponent("Report parts 2")
    check(texts(PDFDocument(url: second.appendingPathComponent("Report – part 2.pdf"))) == ["Page 5", "Page 6"], "a range part")
    ranges.set(PagesTools.Key.ranges, .string("1-9"))
    check(!ranges.canRun && ranges.message?.text == "Type pages like “1-3, 4-9”.", "bad ranges")

    // Every page in one part is not a split.
    let one = session(.split, tools, document)
    one.set(PagesTools.Key.mode, .string("every"))
    one.set(PagesTools.Key.every, .int(5))
    check(one.panel.primary.title == "Split into 2 files", "5 + 1")

    // Contents entries: a part per top-level entry, pages before the first one their own part.
    let model = try! PDFModel(data: pagesPDF(numbered(6)))
    model.setOutlines([PDFOutlineItem(title: "One", destination: PDFDestination(page: 1)), PDFOutlineItem(title: "Two", destination: PDFDestination(page: 4))])
    let chaptered = folder.appendingPathComponent("Chapters.pdf")
    try? model.data().write(to: chaptered)
    let chapters = DocumentHandle(url: chaptered, pdf: PDFDocument(url: chaptered)!, undoManager: makeUndoManager())
    let byContents = session(.split, tools, chapters)
    byContents.set(PagesTools.Key.mode, .string("contents"))
    check(byContents.panel.primary.title == "Split into 3 files", "by contents: \(byContents.panel.primary.title)")
    run(byContents)
    check(texts(PDFDocument(url: folder.appendingPathComponent("Chapters parts/Chapters – part 2.pdf"))) == ["Page 2", "Page 3", "Page 4"],
          "a chapter part")
    let noContents = session(.split, tools, document)
    noContents.set(PagesTools.Key.mode, .string("contents"))
    check(!noContents.canRun && noContents.message?.text == "This PDF has no table of contents to split by.", "no contents")

    // Size plans.
    check(PageEngine.groups(sizes: [40, 40, 40, 100, 10], limit: 90) == [[0, 1], [2], [3], [4]], "size groups")
    check(PageEngine.groups(every: 4, count: 10) == [[0, 1, 2, 3], [4, 5, 6, 7], [8, 9]], "every N groups")
    check(PageEngine.groups(startingAt: [0, 3, 3, 9], count: 5) == [[0, 1, 2], [3, 4]], "start groups")
    if let sizes = try? PageEngine.pageSizes(.file(document.url!)) {
        check(sizes.count == 6 && sizes.allSatisfy { $0 > 0 }, "page sizes")
    } else { check(false, "page sizes") }
    let bySize = session(.split, tools, document)
    bySize.set(PagesTools.Key.mode, .string("size"))
    _ = complete { await bySize.updatePreview() }
    check(bySize.panel.primary.title == "Split" && bySize.message?.text == "This would make just one file. Choose fewer pages per file.",
          "a small file in one part: \(bySize.panel.primary.title)")
    bySize.set(PagesTools.Key.mode, .string("every"))
    installFakes()
}

// MARK: - Blank pages

@MainActor
private func pagesKitBlankPages() {
    let (tools, _) = installPages()
    let folder = pagesFolder("blank")
    let source = PDFSource.data(pagesPDF(["Page 1", "Page 2", nil, "Page 3", nil, nil, "Page 4"]))
    check((try? PageEngine.blankPages(source)) == [2, 4, 5], "blank pages found by ink")
    let document = savedDocument(["Page 1", "Page 2", nil, "Page 3", nil, nil, "Page 4"], folder: folder, name: "Scans.pdf")
    let split = session(.split, tools, document)
    split.set(PagesTools.Key.mode, .string("blanks"))
    _ = complete { await split.updatePreview() }
    check(split.panel.primary.title == "Split into 3 files" && split.summary == ["3 blank pages found. They are left out."],
          "split at blank pages: \(split.panel.primary.title) \(split.summary)")
    run(split)
    let parts = folder.appendingPathComponent("Scans parts")
    check(texts(PDFDocument(url: parts.appendingPathComponent("Scans – part 1.pdf"))) == ["Page 1", "Page 2"]
          && texts(PDFDocument(url: parts.appendingPathComponent("Scans – part 3.pdf"))) == ["Page 4"], "blank pages left out")
    split.set(PagesTools.Key.mode, .string("every"))
    installFakes()
}

// MARK: - Combine (E)

@MainActor
private func pagesKitCombine() {
    let (tools, documents) = installPages()
    let folder = pagesFolder("combine")
    let document = savedDocument(numbered(3), folder: folder)
    let budget = folder.appendingPathComponent("Budget.pdf")
    try? pagesPDF(["A", "B"]).write(to: budget)
    let photo = folder.appendingPathComponent("Photo.png")
    try? Data([0x89, 0x50, 0x4E, 0x47]).write(to: photo)

    let alone = session(.combineFiles, tools, document)
    check(!alone.canRun && alone.message?.text == "Add at least two files to combine." && alone.panel.output == .newDocument(name: "Combined"),
          "one file is not a combination")
    let combine = session(.combineFiles, tools, document, inputs: [budget])
    combine.set(PagesTools.Key.files, .files([photo]))
    check(combine.panel.primary.title == "Combine 3 files", "Combine: \(combine.panel.primary.title)")
    run(combine)
    guard let made = documents.newDocuments.last, let pdf = PDFDocument(data: made.data) else { check(false, "combined"); return }
    check(made.name == "Combined" && made.banner?.text == "Combined 3 files into 6 pages.", "banner: \(made.banner?.text ?? "-")")
    check(texts(pdf).prefix(5) == ["Page 1", "Page 2", "Page 3", "A", "B"] && pdf.pageCount == 6, "pages in queue order")
    check((Services.convert as? FakeConvert)?.jobs.first?.inputs == [photo], "the picture went through the converter")
    let entries = (try? PDFModel(data: made.data).outlines())?.map { "\($0.title)@\($0.destination?.page ?? -1)" }
    check(entries == ["Report@0", "Budget@3", "Photo@5"], "a contents entry per file: \(entries ?? [])")

    // Without contents entries; files only (no document).
    let plain = session(.combineFiles, tools, nil, inputs: [budget, budget])
    plain.set(PagesTools.Key.contents, .bool(false))
    run(plain)
    check((try? PDFModel(data: documents.newDocuments.last!.data).outlines())?.isEmpty == true && documents.newDocuments.last?.data.isEmpty == false,
          "no contents entries")
    plain.set(PagesTools.Key.contents, .bool(true))
    installFakes()
}

// MARK: - Insert (A)

@MainActor
private func pagesKitInsert() {
    let (tools, _) = installPages()
    let folder = pagesFolder("insert")
    let document = savedDocument(numbered(3), folder: folder)
    let extra = folder.appendingPathComponent("Extra.pdf")
    try? pagesPDF(["X", "Y"]).write(to: extra)

    let insert = session(.insertPages, tools, document, currentPage: 0)
    check(!insert.canRun && insert.message?.text == "Choose a file to insert.", "a file is needed")
    insert.set(PagesTools.Key.files, .files([extra]))
    check(insert.canRun && insert.panel.primary.title == "Insert", "Insert")
    run(insert)
    check(texts(document.pdf) == ["Page 1", "X", "Y", "Page 2", "Page 3"], "inserted after page 1: \(texts(document.pdf))")
    document.undoManager?.undo()
    check(texts(document.pdf) == ["Page 1", "Page 2", "Page 3"], "insert undone")

    let blank = session(.insertPages, tools, document, currentPage: 2)
    blank.set(PagesTools.Key.source, .string("blank"))
    blank.set(PagesTools.Key.after, .int(3))
    run(blank)
    check(texts(document.pdf) == ["Page 1", "Page 2", "Page 3", ""], "a blank page at the end")
    document.undoManager?.undo()

    let replace = session(.insertPages, tools, document, selection: [1, 2])
    replace.set(PagesTools.Key.source, .string("file"))
    replace.set(PagesTools.Key.files, .files([extra]))
    replace.set(PagesTools.Key.replace, .bool(true))
    check(replace.panel.primary.title == "Replace 2 pages" && replace.panel.showsScope, "Replace: \(replace.panel.primary.title)")
    run(replace)
    check(texts(document.pdf) == ["Page 1", "X", "Y"], "replaced: \(texts(document.pdf))")
    document.undoManager?.undo()
    replace.set(PagesTools.Key.replace, .bool(false))

    _ = complete { await replace.perform(PagesTools.Action.reverse) }
    check(texts(document.pdf) == ["Page 3", "Page 2", "Page 1"], "reversed")
    document.undoManager?.undo()
    check(texts(document.pdf) == ["Page 1", "Page 2", "Page 3"], "reverse undone")

    let scan = session(.insertPages, tools, document)
    scan.set(PagesTools.Key.source, .string("iphone"))
    check(!scan.canRun && scan.layout.body.contains { if case .control(.action(let id, _, _, _)) = $0 { id == "scan" } else { false } }, "scan action")
    _ = complete { await scan.perform(PagesTools.Action.scan) }
    check((Services.tools as? FakeTools)?.openedPanels.last == .scanWithIPhone, "From iPhone opens the iPhone scan")
    scan.set(PagesTools.Key.source, .string("file"))
    installFakes()
}

// MARK: - Crop (C)

@MainActor
private func pagesKitCrop() {
    // Margins as seen → the page's own box, for every rotation.
    let box = CGRect(x: 0, y: 0, width: 600, height: 800)
    let insets = Insets(top: 10, left: 20, bottom: 30, right: 40)
    check(CropMath.crop(box, insets: insets, rotation: 0) == CGRect(x: 20, y: 30, width: 540, height: 760), "crop upright")
    check(CropMath.crop(box, insets: insets, rotation: 90) == CGRect(x: 10, y: 20, width: 560, height: 740), "crop turned right")
    check(CropMath.crop(box, insets: insets, rotation: 180) == CGRect(x: 40, y: 10, width: 540, height: 760), "crop upside down")
    check(CropMath.crop(box, insets: insets, rotation: 270) == CGRect(x: 30, y: 40, width: 560, height: 740), "crop turned left")
    check(CropMath.crop(box.offsetBy(dx: 5, dy: 5), insets: insets, rotation: -90) == CGRect(x: 35, y: 45, width: 560, height: 740), "offset box, -90")
    check(CropMath.crop(box, insets: Insets(top: 0, left: 300, bottom: 0, right: 300), rotation: 0) == nil, "nothing left")

    // White margins: the text sits 72 pt from the left and about 96 pt from the top of a Letter page.
    if let margins = try? PageEngine.sharedWhiteMargins(.data(pagesPDF(["Page 1", "Page 2"])), pages: [0, 1]) {
        check(abs(margins.left - 72) <= 3 && margins.top > 60 && margins.top < 96 && margins.bottom > 600 && margins.right > 400, "white margins: \(margins)")
    } else { check(false, "white margins found") }
    check((try? PageEngine.sharedWhiteMargins(.data(pagesPDF([nil])), pages: [0])) == .some(nil), "a blank page has no margins")

    let (tools, _) = installPages()
    let document = makeDocument(pages: 3)
    let crop = session(.crop, tools, document, selection: [0, 1])
    check(crop.panel.notice == "Cropping hides content without removing it. Use Black out to remove it." && !crop.canRun, "Crop starts with nothing")
    _ = complete { await crop.perform(PagesTools.Action.whiteMargins) }
    check(abs(crop.values.int(PagesTools.Key.left) - 72) <= 3 && crop.canRun, "Remove white margins fills the fields: \(crop.values.int(PagesTools.Key.left))")
    if case .overlay = crop.preview { } else { _ = complete { await crop.updatePreview() } }
    if case .overlay = crop.preview { } else { check(false, "the crop is previewed on the page") }
    crop.set(PagesTools.Key.unit, .string("mm"))
    crop.set(PagesTools.Key.top, .int(10)); crop.set(PagesTools.Key.left, .int(10)); crop.set(PagesTools.Key.bottom, .int(10)); crop.set(PagesTools.Key.right, .int(10))
    run(crop)
    let cropped = document.pdf.page(at: 0)!.bounds(for: .cropBox)
    check(abs(cropped.minX - 28.35) < 0.1 && abs(cropped.width - (612 - 56.69)) < 0.1, "10 mm off each side: \(cropped)")
    check(document.pdf.page(at: 2)!.bounds(for: .cropBox).width == 612 && document.pdf.page(at: 0)!.bounds(for: .mediaBox).width == 612,
          "other pages and the media box untouched")
    document.undoManager?.undo()
    check(document.pdf.page(at: 0)!.bounds(for: .cropBox).width == 612, "Undo crop restores")

    crop.set(PagesTools.Key.left, .int(400))
    run(crop)
    check(crop.message?.text == "That leaves nothing of the page. Make the margins smaller.", "cropping everything is refused")
    crop.set(PagesTools.Key.unit, .string("pt"))
    installFakes()
}

// MARK: - Number pages (C)

@MainActor
private func pagesKitNumberPages() {
    let numbering = PageNumbering(style: .pageOfTotal, startAt: 1, skipFirst: 1)
    check(PagesTools.numberTexts(numbering, pages: [0, 1, 2, 3]) == [1: "Page 1 of 3", 2: "Page 2 of 3", 3: "Page 3 of 3"], "numbers skip the cover")
    let labels = PagesTools.labelRanges(PageNumbering(style: .plain, startAt: 1, skipFirst: 2), firstNumbered: 2)
    check(labels == [PDFPageLabelRange(startPage: 0, style: .lowerRoman), PDFPageLabelRange(startPage: 2, style: .decimal)], "labels: \(labels)")

    let (tools, _) = installPages()
    let document = makeDocument(pages: 4)
    let number = session(.numberPages, tools, document)
    check(number.panel.primary.title == "Add numbers" && number.values.int(PagesTools.Key.position) == 4, "bottom centre by default")
    number.set(PagesTools.Key.style, .string(PageNumberStyle.dashed.rawValue))
    number.set(PagesTools.Key.position, .int(2))
    number.set(PagesTools.Key.start, .int(5))
    _ = complete { await number.updatePreview() }
    if case .overlay = number.preview { } else { check(false, "numbers previewed on the page") }
    run(number)
    if case .pageNumbers(let applied)? = (Services.edit as? FakeEdit)?.applied.last {
        check(applied.style == .dashed && applied.position == .topRight && applied.startAt == 5, "numbers drawn by EditKit: \(applied)")
    } else { check(false, "Services.edit draws the numbers") }

    // Page labels with the numbers: one step that swaps the bytes.
    let labelled = session(.numberPages, tools, document)
    labelled.set(PagesTools.Key.skip, .int(1))
    labelled.set(PagesTools.Key.labels, .bool(true))
    labelled.set(PagesTools.Key.style, .string(PageNumberStyle.plain.rawValue))
    labelled.set(PagesTools.Key.start, .int(1))
    if case .inPlace(let group, _)? = run(labelled), case .contents(_, let after) = group.change, let model = try? PDFModel(data: after) {
        check(model.pageLabel(at: 0) == "i" && model.pageLabel(at: 1) == "1" && model.pageLabel(at: 3) == "3", "labels match the numbers")
        check(document.pdf.page(at: 1)?.label == "1", "the sidebar shows the labels")
        document.undoManager?.undo()
        check(document.pdf.page(at: 1)?.label == "2", "labels undone")
    } else { check(false, "labels written") }
    labelled.set(PagesTools.Key.labels, .bool(false))
    labelled.set(PagesTools.Key.skip, .int(0))
    installFakes()
}

// MARK: - Booklet (B)

@MainActor
private func pagesKitBooklet() {
    let (tools, documents) = installPages()
    RenderKitModule.install()
    let document = makeDocument(pages: 6)
    let booklet = session(.booklet, tools, document)
    booklet.set(PagesTools.Key.paper, .string("a4"))
    check(booklet.panel.primary.title == "Make booklet PDF" && booklet.panel.output == .newDocument(name: "Report (booklet)"), "Booklet")
    run(booklet)
    if let made = documents.newDocuments.last, let pdf = PDFDocument(data: made.data), let sheet = pdf.page(at: 0) {
        let size = sheet.bounds(for: .mediaBox).size
        check(pdf.pageCount == 4 && abs(size.width - 841.89) < 1 && abs(size.height - 595.28) < 1, "2 sheets, both sides, A4 landscape")
        check(sheet.string?.contains("Page 1") == true && sheet.string?.contains("Page 8") == false, "saddle-stitch order: \(sheet.string ?? "")")
    } else { check(false, "booklet made") }
    booklet.set(PagesTools.Key.layout, .string("contact"))
    check(booklet.panel.primary.title == "Make contact sheet", "contact sheet")
    run(booklet)
    check(PDFDocument(data: documents.newDocuments.last?.data ?? Data())?.pageCount == 1, "six pages on one contact sheet")
    booklet.set(PagesTools.Key.layout, .string("booklet"))
    installFakes()
}

// MARK: - Resize (B)

@MainActor
private func pagesKitResize() {
    let fit = PageEngine.fitTransform(CGRect(x: 0, y: 0, width: 612, height: 792), into: CGSize(width: 1224, height: 1584), padOnly: false)
    check(fit.a == 2 && fit.tx == 0 && fit.ty == 0, "scale to fit doubles")
    let pad = PageEngine.fitTransform(CGRect(x: 0, y: 0, width: 612, height: 792), into: CGSize(width: 1224, height: 1584), padOnly: true)
    check(pad.a == 1 && pad.tx == 306 && pad.ty == 396, "space around keeps the size and centres")

    let (tools, _) = installPages()
    let document = makeDocument(pages: 2)
    document.pdf.page(at: 1)?.rotation = 90
    let resize = session(.resizePages, tools, document)
    resize.set(PagesTools.Key.paper, .string("a4"))
    check(resize.panel.primary.title == "Resize 2 pages", "Resize: \(resize.panel.primary.title)")
    run(resize)
    let first = document.pdf.page(at: 0)!.bounds(for: .mediaBox).size, second = document.pdf.page(at: 1)!.bounds(for: .mediaBox).size
    check(abs(first.width - 595.28) < 0.5 && abs(first.height - 841.89) < 0.5, "A4 portrait: \(first)")
    check(abs(second.width - 595.28) < 0.5 && abs(second.height - 841.89) < 0.5 && document.pdf.page(at: 1)?.rotation == 90,
          "a turned page keeps its turn: \(second)")
    check(texts(document.pdf) == ["Page 1", "Page 2"], "the content is still there")
    document.undoManager?.undo()
    check(document.pdf.page(at: 0)!.bounds(for: .mediaBox).width == 612, "resize undone")
    installFakes()
}
