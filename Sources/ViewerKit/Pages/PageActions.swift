import AppKit
import PDFKit
import SuperPDFCore
import UniformTypeIdentifiers

/// The page edits of one document window: thumbnails, the organiser, the toolbar's Rotate, the context menu and the
/// menus all come through here. Each edit runs through PagesKit (`Services.pages`) and is handed to DocumentKit as an
/// in-place result, so it is one undo step and marks the document edited (ARCHITECTURE "Output policy").
@MainActor
final class PageActions {
    let document: DocumentHandle
    private let environment: () -> ViewerEnvironment
    private weak var window: NSWindow?
    /// Pages mixed in from other files, by page identity, until the document is saved (organiser colour bars).
    private(set) var origins: [ObjectIdentifier: PageOrigin] = [:]
    /// The selection the next reload should show (the moved, inserted or remaining pages).
    var pendingSelection: IndexSet?

    init(document: DocumentHandle, window: NSWindow?, environment: @escaping () -> ViewerEnvironment) {
        self.document = document
        self.window = window
        self.environment = environment
    }

    func attach(_ window: NSWindow?) { self.window = window }

    /// The document's pages as the grid shows them.
    func model(selection: IndexSet) -> PageGridModel {
        PageGridModel(entries: (0..<document.pageCount).map { index in
            guard let page = document.pdf.page(at: index) else { return PageGridModel.Entry(key: index) }
            let id = ObjectIdentifier(page)
            return PageGridModel.Entry(key: id.hashValue, origin: origins[id])
        }, selection: selection)
    }

    func origin(of page: PDFPage) -> PageOrigin? { origins[ObjectIdentifier(page)] }

    /// Keeps the colour of pages still in the document only (a removed page's identity may be reused).
    func pruneOrigins() {
        guard !origins.isEmpty else { return }
        let present = Set((0..<document.pageCount).compactMap { document.pdf.page(at: $0).map(ObjectIdentifier.init) })
        origins = origins.filter { present.contains($0.key) }
    }

    func clearOrigins() { origins = [:] }

    /// Marks pages as coming from a file (Combine from the welcome window).
    func tag(_ range: Range<Int>, as origin: PageOrigin) {
        for index in range { if let page = document.pdf.page(at: index) { origins[ObjectIdentifier(page)] = origin } }
    }

    // MARK: Edits

    func rotate(_ pages: [Int], quarterTurns: Int) {
        let model = model(selection: [])
        let operation = model.rotation(pages, quarterTurns: quarterTurns)
        guard case .rotate(let indices, _) = operation, !indices.isEmpty else { return }
        perform(operation, tool: .rotatePages, select: nil)
    }

    func delete(_ pages: [Int]) {
        let model = model(selection: IndexSet(pages))
        do {
            let operation = try model.deletion(pages)
            var after = model
            after.applyDelete(pages)
            perform(operation, tool: .deletePages, select: after.selection)
        } catch {
            environment().alert(error.localizedDescription, window)
        }
    }

    func move(_ pages: [Int], toGap gap: Int) {
        let model = model(selection: IndexSet(pages))
        guard let operation = model.move(pages, toGap: gap) else { return }
        var after = model
        after.applyMove(pages, toGap: gap)
        perform(operation, tool: .rearrangePages, select: after.selection)
    }

    func duplicate(_ pages: [Int]) {
        guard let last = pages.max() else { return }
        perform(.duplicate(pages.sorted()), tool: .insertPages, select: IndexSet(integersIn: last + 1..<last + 1 + pages.count))
    }

    func insertBlank(after index: Int) {
        perform(.insertBlank(after: index), tool: .insertPages, select: [index + 1])
    }

    /// Files dropped or chosen: each file's pages in order before `gap`, converting non-PDFs first (ux §3). Pages from
    /// another file keep that file's colour in the organiser until the next save when `tagged`.
    func insertFiles(_ urls: [URL], atGap gap: Int, tagged: Bool) {
        Task {
            var at = min(max(gap, 0), document.pageCount)
            var groups: [UndoGroup] = []
            var tags: [(range: Range<Int>, origin: PageOrigin)] = []
            var nextColor = model(selection: []).nextOriginColor
            do {
                for url in urls {
                    let pdf = try await pdfFile(for: url)
                    guard let count = CGPDFDocument(pdf as CFURL)?.numberOfPages, count > 0 else { continue }
                    groups.append(try await Services.pages.perform(.insertFile(.file(pdf), pages: [], at: at), in: document))
                    if tagged {
                        tags.append((at..<at + count, PageOrigin(fileName: url.lastPathComponent, colorIndex: nextColor)))
                        nextColor = (nextColor + 1) % PageOrigin.palette.count
                    }
                    at += count
                }
            } catch {
                environment().alert(error.localizedDescription, window)
            }
            guard !groups.isEmpty else { return }
            for (range, origin) in tags {
                for index in range { if let page = document.pdf.page(at: index) { origins[ObjectIdentifier(page)] = origin } }
            }
            let first = min(max(gap, 0), document.pageCount)
            await apply(groups, name: groups.count == 1 ? groups[0].actionName : "Insert Pages", tool: .insertPages,
                        select: IndexSet(integersIn: first..<at))
        }
    }

    /// Thumbnails dragged in from another window: copied, or moved with ⌥ (ux §3).
    func copyPages(_ pages: [Int], from source: DocumentHandle, toGap gap: Int, removingFromSource: Bool) {
        let at = min(max(gap, 0), document.pageCount)
        do {
            let group = try Services.pages.copy(pages.sorted(), from: source, to: document, at: at)
            Task {
                await apply([group], name: group.actionName, tool: .insertPages, select: IndexSet(integersIn: at..<at + pages.count))
                if removingFromSource { Viewer.shared.controller(for: source)?.pageActions.delete(pages) }
            }
        } catch {
            environment().alert(error.localizedDescription, window)
        }
    }

    /// The pages as a PDF of their own (drag to Finder, Share Page…).
    func extract(_ pages: [Int]) -> Data? { try? Services.pages.extract(pages.sorted(), from: document) }

    /// "Report – pages 3-5.pdf" (ux §3).
    func extractName(_ pages: [Int]) -> String {
        OutputSuffix.pages(PageRanges(Self.ranges(pages))).fileName(base: document.displayName, ext: "pdf")
    }

    static func ranges(_ pages: [Int]) -> [ClosedRange<Int>] {
        var ranges: [ClosedRange<Int>] = []
        for page in Array(Set(pages)).sorted() {
            if let last = ranges.last, last.upperBound + 1 == page { ranges[ranges.count - 1] = last.lowerBound...page } else { ranges.append(page...page) }
        }
        return ranges
    }

    /// Text dropped on a page becomes a text box there (ux §3 "Add text").
    func addText(_ text: String, on page: PDFPage, at point: CGPoint) {
        let font = NSFont.systemFont(ofSize: 12)
        let size = (text as NSString).boundingRect(with: NSSize(width: 280, height: 1000), options: [.usesLineFragmentOrigin],
                                                    attributes: [.font: font]).size
        let bounds = CGRect(x: point.x, y: point.y - ceil(size.height) - 4, width: ceil(size.width) + 8, height: ceil(size.height) + 4)
        let annotation = PDFAnnotation(bounds: bounds, forType: .freeText, withProperties: nil)
        annotation.contents = text
        annotation.font = font
        annotation.fontColor = .black
        annotation.color = .clear
        page.addAnnotation(annotation)
        let group = UndoGroup("Add Text", undo: { page.removeAnnotation(annotation) }, redo: { page.addAnnotation(annotation) })
        Task { await apply([group], name: group.actionName, tool: .highlightAndNotes, select: nil) }
    }

    // MARK: Running

    private func perform(_ operation: PageOperation, tool: ToolID, select: IndexSet?) {
        Task {
            do {
                let group = try await Services.pages.perform(operation, in: document)
                await apply([group], name: group.actionName, tool: tool, select: select)
            } catch {
                environment().alert(error.localizedDescription, window)
            }
        }
    }

    private func apply(_ groups: [UndoGroup], name: String, tool: ToolID, select: IndexSet?) async {
        let actions = groups.allSatisfy { if case .actions = $0.change { true } else { false } }
        let steps = actions && groups.count > 1 ? [UndoGroup.combined(name, groups)] : groups
        pendingSelection = select
        for group in steps {
            do {
                try await Services.documents.apply(.inPlace(undoable: group, banner: nil),
                                                   of: ToolRequest(tool: tool, document: document, workFolder: SuperPDFPaths.work))
            } catch {
                environment().alert(error.localizedDescription, window)
            }
        }
    }

    /// A PDF for a dropped file: the file itself, or ConvertKit's conversion into the work folder.
    private func pdfFile(for url: URL) async throws -> URL {
        if (try? url.resourceValues(forKeys: [.contentTypeKey]))?.contentType?.conforms(to: .pdf) == true || url.pathExtension.lowercased() == "pdf" {
            return url
        }
        guard let convert = Services.convert, convert.canConvertToPDF(url) else {
            throw ToolError(Strings.Errors.notConvertible(url.pathExtension.lowercased()))
        }
        let folder = SuperPDFPaths.ensure(SuperPDFPaths.work.appendingPathComponent(UUID().uuidString, isDirectory: true))
        let destination = folder.appendingPathComponent(url.deletingPathExtension().lastPathComponent + ".pdf")
        let result = try await convert.convert(ConversionJob(inputs: [url], output: .pdf, destination: destination), progress: .ignored)
        guard let output = result.outputs.first else { throw ToolError(Strings.Errors.conversionFailed(url.lastPathComponent)) }
        return output
    }
}
