import AppKit
import PDFKit
import SuperPDFCore
import UniformTypeIdentifiers

/// The page edits of one document window: thumbnails, the workspace, the toolbar's Rotate, the context menu and the
/// menus all come through here. Each edit runs through PagesKit (`Services.pages`) and is handed to DocumentKit as an
/// in-place result, so it is one undo step and marks the document edited (ARCHITECTURE "Output policy").
@MainActor
final class PageActions {
    let document: DocumentHandle
    private let environment: () -> ViewerEnvironment
    private weak var window: NSWindow?
    /// Pages mixed in from other files, by page identity, until the document is saved (the workspace's files and pills).
    private(set) var origins: [ObjectIdentifier: PageOrigin] = [:]
    /// The selection the next reload should show (the moved, inserted or remaining pages).
    var pendingSelection: IndexSet?
    /// Files still turning into PDFs on their way in, with the page they go before (nil: the end).
    private var converting: [(file: PendingFile, before: PDFPage?)] = []
    /// Called when a file starts or finishes converting, or reports progress (the workspace shows it on its card).
    var onPendingChange: (() -> Void)?

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

    /// The workspace's view of the document: its pages with their files, and the files still converting.
    func workspaceModel() -> WorkspaceModel {
        WorkspaceModel(entries: model(selection: []).entries, documentName: document.url?.lastPathComponent ?? document.displayName, pending: pending)
    }

    /// The files converting now, with the gap each will go into.
    var pending: [PendingFile] {
        converting.map { item in
            var file = item.file
            file.gap = gap(before: item.before)
            return file
        }
    }

    /// Where the page is now (the end when it's gone or nil).
    private func gap(before page: PDFPage?) -> Int {
        guard let page else { return document.pageCount }
        let index = document.pdf.index(for: page)
        return index == NSNotFound ? document.pageCount : index
    }

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

    func insertBlank(after index: Int) {
        perform(.insertBlank(after: index), tool: .insertPages, select: [index + 1])
    }

    /// Files dropped or chosen: each file's pages in order before `gap`, converting non-PDFs first (ux §3). Each file
    /// waits as a card in the workspace while it converts, then goes in as its own undo step. When `tagged`, its pages
    /// keep the file's name and colour until the next save (`firstColor` onwards, else the next free colours).
    func insertFiles(_ urls: [URL], atGap gap: Int, tagged: Bool, firstColor: Int? = nil) {
        guard !urls.isEmpty else { return }
        let before = document.pdf.page(at: min(max(gap, 0), document.pageCount))
        var color = firstColor ?? model(selection: []).nextOriginColor
        let files = urls.map { url -> PendingFile in
            defer { color = (color + 1) % PageOrigin.palette.count }
            return PendingFile(name: url.lastPathComponent, colorIndex: color, gap: gap)
        }
        converting += files.map { ($0, before) }
        onPendingChange?()
        Task {
            var inserted = IndexSet()
            for (url, file) in zip(urls, files) {
                defer { finish(file.id) }
                do {
                    let pdf = try await pdfFile(for: url, progress: ToolProgress { [weak self] update in
                        Task { @MainActor in self?.progress(file.id, update.total > 0 ? update.fraction : nil) }
                    })
                    guard let count = CGPDFDocument(pdf as CFURL)?.numberOfPages, count > 0 else { continue }
                    let at = self.gap(before: before)
                    let group = try await Services.pages.perform(.insertFile(.file(pdf), pages: [], at: at), in: document)
                    if tagged { tag(at..<at + count, as: PageOrigin(fileName: file.name, colorIndex: file.colorIndex)) }
                    inserted = IndexSet(integersIn: at..<at + count)
                    // Leave the card before the document reloads, so the file's pages take its place.
                    finish(file.id)
                    await apply([group], name: group.actionName, tool: .insertPages, select: inserted)
                } catch {
                    environment().alert(error.localizedDescription, window)
                }
            }
        }
    }

    private func progress(_ id: UUID, _ fraction: Double?) {
        guard let index = converting.firstIndex(where: { $0.file.id == id }) else { return }
        converting[index].file.fraction = fraction
        onPendingChange?()
    }

    private func finish(_ id: UUID) {
        guard converting.contains(where: { $0.file.id == id }) else { return }
        converting.removeAll { $0.file.id == id }
        onPendingChange?()
    }

    /// Copies of pages right after the last of them. In the workspace's Files view the copies are a file of their own
    /// (`asNewFile`: the same name, the next colour); otherwise each copy belongs where its page does.
    func duplicate(_ pages: [Int], asNewFile: Bool) {
        let pages = pages.sorted()
        guard let last = pages.last else { return }
        let sources = pages.compactMap { document.pdf.page(at: $0) }
        let newFile = asNewFile ? sources.first.map { page in
            PageOrigin(fileName: origin(of: page)?.fileName ?? document.url?.lastPathComponent ?? document.displayName,
                       colorIndex: model(selection: []).nextOriginColor)
        } : nil
        Task {
            do {
                let group = try await Services.pages.perform(.duplicate(pages), in: document)
                for (offset, source) in sources.enumerated() {
                    guard let copy = document.pdf.page(at: last + 1 + offset) else { continue }
                    if let origin = newFile ?? origin(of: source) { origins[ObjectIdentifier(copy)] = origin }
                }
                await apply([group], name: group.actionName, tool: .insertPages, select: IndexSet(integersIn: last + 1..<last + 1 + pages.count))
            } catch {
                environment().alert(error.localizedDescription, window)
            }
        }
    }

    /// Puts the pages in a new order given as runs of current indices (a sort in the workspace), as one undo step.
    func arrange(_ blocks: [[Int]]) {
        Task {
            var order = Array(0..<document.pageCount)
            var groups: [UndoGroup] = []
            var position = 0
            do {
                for block in blocks where !block.isEmpty {
                    let current = block.compactMap { order.firstIndex(of: $0) }.sorted()
                    if current != Array(position..<position + current.count) {
                        groups.append(try await Services.pages.perform(.move(current, to: position), in: document))
                        let moving = current.map { order[$0] }
                        order = order.enumerated().filter { !current.contains($0.offset) }.map(\.element)
                        order.insert(contentsOf: moving, at: position)
                    }
                    position += current.count
                }
            } catch {
                environment().alert(error.localizedDescription, window)
            }
            guard !groups.isEmpty else { return }
            await apply(groups, name: groups[0].actionName, tool: .rearrangePages, select: nil)
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
    private func pdfFile(for url: URL, progress: ToolProgress) async throws -> URL {
        if (try? url.resourceValues(forKeys: [.contentTypeKey]))?.contentType?.conforms(to: .pdf) == true || url.pathExtension.lowercased() == "pdf" {
            return url
        }
        guard let convert = Services.convert, convert.canConvertToPDF(url) else {
            throw ToolError(Strings.Errors.notConvertible(url.pathExtension.lowercased()))
        }
        let folder = SuperPDFPaths.ensure(SuperPDFPaths.work.appendingPathComponent(UUID().uuidString, isDirectory: true))
        let destination = folder.appendingPathComponent(url.deletingPathExtension().lastPathComponent + ".pdf")
        let result = try await convert.convert(ConversionJob(inputs: [url], output: .pdf, destination: destination), progress: progress)
        guard let output = result.outputs.first else { throw ToolError(Strings.Errors.conversionFailed(url.lastPathComponent)) }
        return output
    }
}
