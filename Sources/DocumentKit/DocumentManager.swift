import AppKit
import Combine
import PDFKit
import SuperPDFCore
import UniformTypeIdentifiers

/// `Services.documents` (ARCHITECTURE "Core contracts"): open documents, the open flows, output naming, applying tool
/// results with undo, recents and view state. Open documents are the `PDFFileDocument`s of the document controller, so
/// File › Open, Open Recent, Finder and restoration all end up in the same list.
@MainActor
public final class DocumentManager: DocumentManaging {
    /// The installed manager, for documents NSDocument creates on its own (versions browser, restoration).
    static weak var current: DocumentManager?

    let controller: NSDocumentController
    public var prompter: DocumentPrompting
    let loader: DocumentLoader
    let recents: RecentsStore
    /// Where autosaves go before the first save choice (never next to the original).
    let autosaveFolder: URL
    /// Where outputs go when the original's folder can't be written, and where unsaved documents propose to save.
    let fallbackFolder: URL
    /// Off in the self-test: documents open without windows.
    let displaysWindows: Bool
    let eventSubject = PassthroughSubject<DocumentEvent, Never>()

    public init(controller: NSDocumentController, prompter: DocumentPrompting, repairer: @escaping @MainActor () -> Repairing? = { Services.fix },
                autosaveFolder: URL, fallbackFolder: URL, displaysWindows: Bool = true, notesSystemRecents: Bool = true) {
        self.controller = controller
        self.prompter = prompter
        loader = DocumentLoader(prompter: prompter, repairer: repairer, workFolder: { SuperPDFPaths.work })
        recents = RecentsStore(notesSystemRecents: notesSystemRecents)
        self.autosaveFolder = autosaveFolder
        self.fallbackFolder = fallbackFolder
        self.displaysWindows = displaysWindows
        (controller as? PDFDocumentController)?.manager = self
    }

    // MARK: Open documents

    var documents: [PDFFileDocument] { controller.documents.compactMap { $0 as? PDFFileDocument }.filter { $0.handle != nil } }
    public var openDocuments: [DocumentHandle] { documents.map(\.handle) }
    public var frontmost: DocumentHandle? { (controller.currentDocument as? PDFFileDocument)?.handle }
    public var events: AnyPublisher<DocumentEvent, Never> { eventSubject.eraseToAnyPublisher() }

    public func document(for handle: DocumentHandle) -> PDFFileDocument? { documents.first { $0.handle === handle } }

    /// The open document showing this file (by file identity, so another path to the same file counts).
    func document(at url: URL) -> PDFFileDocument? {
        let identity = Self.identity(of: url)
        return documents.first { document in
            guard let open = document.fileURL else { return false }
            if open.standardizedFileURL == url.standardizedFileURL { return true }
            guard let identity, let other = Self.identity(of: open) else { return false }
            return identity.isEqual(other)
        }
    }

    private static func identity(of url: URL) -> NSObjectProtocol? {
        (try? url.resourceValues(forKeys: [.fileResourceIdentifierKey]))?.fileResourceIdentifier
    }

    func knownPassword(for url: URL) -> String? { document(at: url)?.handle.password }

    // MARK: Opening (ux §7.4)

    @discardableResult
    public func open(_ url: URL) async throws -> DocumentHandle {
        let url = url.standardizedFileURL
        if let open = document(at: url) { show(open); return open.handle }
        guard Self.isPDF(url) else { return try await convertAndOpen(url) }
        let loaded = try await loader.load(url, fileName: url.lastPathComponent)
        // The same file may have opened by another route while a prompt was up.
        if let open = document(at: url) { show(open); return open.handle }
        let handle = DocumentHandle(url: url, pdf: loaded.pdf, state: PDFFileDocument.state(for: loaded.pdf, origin: .opened, repaired: loaded.wasRepaired),
                                    password: loaded.password)
        let document = PDFFileDocument(handle: handle, manager: self)
        document.fileURL = url
        document.fileType = PDFFileDocument.pdfType
        document.fileModificationDate = (try? url.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate
        add(document, beside: nil, bytes: loaded.bytes)
        if loaded.wasRepaired {
            // The repaired bytes live only in memory and the work folder until the person saves them.
            document.updateChangeCount(.changeDone)
            Services.viewer?.showBanner(ResultBanner(Strings.Errors.repaired(url.lastPathComponent)), in: handle)
        }
        recents.note(url, pageCount: handle.pageCount)
        return handle
    }

    /// Restoration after a quit or crash: `contents` holds the autosaved changes of `original` (nil for a document
    /// that was never saved).
    func reopen(_ original: URL?, contents: URL) async throws -> PDFFileDocument {
        if let original, let open = document(at: original) { show(open); return open }
        let name = original?.lastPathComponent ?? contents.lastPathComponent
        let loaded = try await loader.load(contents, fileName: name)
        let state = PDFFileDocument.state(for: loaded.pdf, origin: original == nil ? .createdHere : .opened, repaired: false)
        let handle = DocumentHandle(url: original, displayName: (name as NSString).deletingPathExtension, pdf: loaded.pdf, state: state,
                                    password: loaded.password)
        let document = PDFFileDocument(handle: handle, manager: self)
        document.fileURL = original
        document.fileType = PDFFileDocument.pdfType
        document.autosavedContentsFileURL = contents
        add(document, beside: nil, bytes: loaded.bytes)
        document.updateChangeCount(.changeReadOtherContents)
        return document
    }

    @discardableResult
    public func openUntitled(_ data: Data, name: String) throws -> DocumentHandle {
        guard let pdf = PDFDocument(data: data) else { throw DocumentError.damaged(name) }
        return openUntitled(pdf, name: name, beside: nil, bytes: data)
    }

    private func openUntitled(_ pdf: PDFDocument, name: String, beside source: DocumentHandle?, bytes: Data?) -> DocumentHandle {
        let handle = DocumentHandle(url: nil, displayName: name, pdf: pdf, state: PDFFileDocument.state(for: pdf, origin: .createdHere, repaired: false))
        let document = PDFFileDocument(handle: handle, manager: self)
        document.fileType = PDFFileDocument.pdfType
        add(document, beside: source, bytes: bytes)
        // Unsaved until ⌘S: closing asks, autosave keeps it.
        document.updateChangeCount(.changeDone)
        return handle
    }

    /// Other file types become a PDF through ConvertKit and open as a new unsaved document ("converts then opens").
    private func convertAndOpen(_ url: URL) async throws -> DocumentHandle {
        guard let convert = Services.convert, convert.canConvertToPDF(url) else { throw DocumentError.notConvertible(url.pathExtension) }
        let base = url.deletingPathExtension().lastPathComponent
        let folder = SuperPDFPaths.ensure(SuperPDFPaths.work.appendingPathComponent(UUID().uuidString, isDirectory: true))
        let result = try await convert.convert(ConversionJob(inputs: [url], output: .pdf, destination: folder.appendingPathComponent(base + ".pdf")),
                                               progress: .ignored)
        guard let output = result.outputs.first, let pdf = PDFDocument(url: output) else { throw DocumentError.damaged(url.lastPathComponent) }
        return openUntitled(pdf, name: base, beside: nil, bytes: try? Data(contentsOf: output))
    }

    /// Adds and shows a document; `bytes` (what its PDFKit document was read from) become its authoritative contents once
    /// the modules have seen it open (MarkupKit hides reply icons then, which is not a change to save).
    private func add(_ document: PDFFileDocument, beside source: DocumentHandle?, bytes: Data?) {
        controller.addDocument(document)
        if displaysWindows {
            document.makeWindowControllers()
            if let source, let window = self.document(for: source)?.window, let newWindow = document.window, window !== newWindow {
                window.addTabbedWindow(newWindow, ordered: .above)
            }
            document.showWindows()
        }
        eventSubject.send(.opened(document.handle.id))
        if let bytes { DocumentBaseline.attach(bytes, to: document.handle) }
    }

    private func show(_ document: PDFFileDocument) {
        if displaysWindows { document.showWindows() }
    }

    func documentWillClose(_ handle: DocumentHandle) {
        eventSubject.send(.closed(handle.id))
    }

    /// A PDF by its extension, or by its first bytes when the name says nothing ("%PDF-" within the first kilobyte,
    /// as readers accept).
    static func isPDF(_ url: URL) -> Bool {
        if let type = UTType(filenameExtension: url.pathExtension), type.conforms(to: .pdf) { return true }
        guard let file = try? FileHandle(forReadingFrom: url) else { return false }
        defer { try? file.close() }
        let head = (try? file.read(upToCount: 1024)) ?? Data()
        return head.range(of: Data("%PDF-".utf8)) != nil
    }

    // MARK: Enter Password… (owner password lifts the file's limits, ux §7.4)

    func enterOwnerPassword(for handle: DocumentHandle) async {
        let name = handle.url?.lastPathComponent ?? handle.displayName
        var retry = false
        while let password = await prompter.ownerPassword(for: name, retry: retry, window: document(for: handle)?.window) {
            if handle.pdf.unlock(withPassword: password), handle.pdf.permissionsStatus == .owner {
                handle.password = password
                handle.state.permissions = DocumentPermissions(handle.pdf)
                eventSubject.send(.changed(handle.id))
                return
            }
            retry = true
        }
    }

    // MARK: Output naming (ux §7.2)

    public func destination(for policy: OutputPolicy, of document: DocumentHandle?, source: URL?) -> URL? {
        let original = document?.url ?? source
        let base = document?.displayName ?? source?.deletingPathExtension().lastPathComponent ?? "Untitled"
        guard let name = OutputNaming.name(for: policy, base: base) else { return nil }
        return OutputNaming.unique(name, in: OutputNaming.folder(for: original, fallback: fallbackFolder))
    }

    /// "Report (edited).pdf" next to the original (ux §7.1).
    public func copyProposal(for handle: DocumentHandle) -> URL {
        destination(for: .sibling(.edited, ext: "pdf"), of: handle, source: nil)!
    }

    /// "Combined.pdf" in the fallback folder, for documents made here.
    func untitledProposal(for handle: DocumentHandle) -> URL {
        OutputNaming.unique(handle.displayName + ".pdf", in: fallbackFolder)
    }

    func autosaveURL(for handle: DocumentHandle) -> URL {
        SuperPDFPaths.ensure(autosaveFolder.appendingPathComponent(handle.id.uuidString, isDirectory: true))
            .appendingPathComponent(handle.displayName + ".pdf")
    }

    // MARK: Applying results (ARCHITECTURE "End-to-end tool flow")

    public func apply(_ result: ToolResult, of request: ToolRequest) async throws {
        defer { cleanUp(request.workFolder) }
        switch result {
        case .inPlace(let group, let banner):
            guard let handle = request.document else { return }
            register(group, in: handle)
            if let banner { Services.viewer?.showBanner(banner, in: handle) }

        case .newFile(let file, let banner):
            let target = request.destination
                ?? OutputNaming.folder(for: request.document?.url ?? request.inputs.first, fallback: fallbackFolder).appendingPathComponent(file.lastPathComponent)
            let placed = try OutputNaming.place(file, at: target)
            let finalBanner = Self.banner(banner, placedAt: placed, planned: target)
            // A new PDF opens in a tab next to its source; a locked one (Add a password) stays closed rather than
            // asking at once for the password just set.
            if Self.isPDF(placed), let pdf = PDFDocument(url: placed), !pdf.isLocked {
                let opened = try await open(placed)
                if let source = request.document, let newWindow = document(for: opened)?.window,
                   let window = document(for: source)?.window, window !== newWindow, displaysWindows {
                    window.addTabbedWindow(newWindow, ordered: .above)
                }
                Services.viewer?.showBanner(finalBanner, in: opened)
            } else if let source = request.document {
                Services.viewer?.showBanner(finalBanner, in: source)
            }

        case .newFiles(let files, let banner):
            let planned = request.destination
                ?? OutputNaming.folder(for: request.document?.url ?? request.inputs.first, fallback: fallbackFolder)
                    .appendingPathComponent(request.document?.displayName ?? "Super PDF")
            let folder = try OutputNaming.makeFolder(at: planned)
            for file in files { _ = try OutputNaming.place(file, at: folder.appendingPathComponent(file.lastPathComponent)) }
            if let source = request.document { Services.viewer?.showBanner(Self.banner(banner, placedAt: folder, planned: planned), in: source) }

        case .newDocument(let data, let name, let banner):
            guard let pdf = PDFDocument(data: data) else { throw DocumentError.damaged(name) }
            let handle = openUntitled(pdf, name: name, beside: request.document, bytes: data)
            if let banner { Services.viewer?.showBanner(banner, in: handle) }

        case .none:
            break
        }
    }

    /// The banner with its file set and, when a file appeared under the planned name meanwhile, the real name in its
    /// text.
    static func banner(_ banner: ResultBanner, placedAt placed: URL, planned: URL) -> ResultBanner {
        var banner = banner
        banner.file = placed
        if placed.lastPathComponent != planned.lastPathComponent {
            banner.text = banner.text.replacingOccurrences(of: Strings.quoted(planned.lastPathComponent), with: Strings.quoted(placed.lastPathComponent))
        }
        return banner
    }

    /// Run folders are scratch: removed once their outputs are in place (only ever inside `SuperPDFPaths.work`).
    private func cleanUp(_ folder: URL) {
        let work = SuperPDFPaths.work.standardizedFileURL.path + "/"
        guard folder.standardizedFileURL.path.hasPrefix(work) else { return }
        try? FileManager.default.removeItem(at: folder)
    }

    // MARK: Undo (features §2.3: every change is on the undo stack)

    /// Registers an in-place result as one undo step named after the tool ("Undo Rotate Pages"). `.contents` results
    /// are applied here (the engine rewrote the bytes) and swap back and forth on undo and redo.
    func register(_ group: UndoGroup, in handle: DocumentHandle) {
        let undoManager = handle.undoManager
        undoManager?.beginUndoGrouping()
        switch group.change {
        case .actions:
            undoManager?.register(group)
        case .contents(let before, let after):
            swapContents(of: handle, to: after)
            registerSwap(of: handle, back: before, forth: after, undoManager: undoManager)
        }
        undoManager?.setActionName(group.actionName)
        undoManager?.endUndoGrouping()
        if undoManager == nil { eventSubject.send(.changed(handle.id)) }
    }

    private func registerSwap(of handle: DocumentHandle, back: Data, forth: Data, undoManager: UndoManager?) {
        undoManager?.registerUndo(withTarget: self) { manager in
            MainActor.assumeIsolated {
                manager.swapContents(of: handle, to: back)
                manager.registerSwap(of: handle, back: forth, forth: back, undoManager: undoManager)
            }
        }
    }

    private func swapContents(of handle: DocumentHandle, to data: Data) {
        guard let pdf = PDFDocument(data: data) else { return }
        if pdf.isLocked, let password = handle.password { pdf.unlock(withPassword: password) }
        replaceContents(of: handle, with: pdf, bytes: data)
    }

    /// Shows new contents in place of the old (undo of an engine edit, Revert To), keeping the page and zoom; `bytes`
    /// (what `pdf` was read from) become the authoritative contents.
    func replaceContents(of handle: DocumentHandle, with pdf: PDFDocument, bytes: Data?) {
        let view = Services.viewer?.pdfView(for: handle)
        let pageIndex = view?.currentPage.map { handle.pdf.index(for: $0) }
        let scale = view?.scaleFactor, autoScales = view?.autoScales ?? true
        handle.pdf = pdf
        let forms = FormScan.scan(pdf)
        handle.state.hasFormFields = forms.hasFields
        handle.state.hasSignatures = forms.hasSignatures
        if let view {
            view.document = pdf
            if let pageIndex, pdf.pageCount > 0, let page = pdf.page(at: min(pageIndex, pdf.pageCount - 1)) { view.go(to: page) }
            if !autoScales, let scale { view.scaleFactor = scale }
        }
        eventSubject.send(.changed(handle.id))
        if let bytes { DocumentBaseline.attach(bytes, to: handle) } else { handle.contents = nil }
    }

    // MARK: Recents and view state

    public var recentDocuments: [RecentDocument] { recents.documents }
    public func removeRecent(_ url: URL) { recents.remove(url) }
    public func viewState(for url: URL) -> DocumentViewState? { ViewStateStore.read(url) }
    public func saveViewState(_ state: DocumentViewState, for url: URL) { ViewStateStore.write(state, to: url) }
}

/// Routes every open — File › Open, Open Recent, Finder, the Dock, restoration — through `DocumentManager`, so the
/// password and repair flows always run.
@MainActor
final class PDFDocumentController: NSDocumentController {
    weak var manager: DocumentManager?

    override func openDocument(withContentsOf url: URL, display displayDocument: Bool,
                               completionHandler: @escaping (NSDocument?, Bool, Error?) -> Void) {
        guard let manager else { return super.openDocument(withContentsOf: url, display: displayDocument, completionHandler: completionHandler) }
        let wasOpen = manager.document(at: url) != nil
        Task {
            do {
                let handle = try await manager.open(url)
                completionHandler(manager.document(for: handle), wasOpen, nil)
            } catch {
                completionHandler(nil, false, error)
            }
        }
    }

    override func reopenDocument(for urlOrNil: URL?, withContentsOf contentsURL: URL, display displayDocument: Bool,
                                 completionHandler: @escaping (NSDocument?, Bool, Error?) -> Void) {
        guard let manager else {
            return super.reopenDocument(for: urlOrNil, withContentsOf: contentsURL, display: displayDocument, completionHandler: completionHandler)
        }
        Task {
            do { completionHandler(try await manager.reopen(urlOrNil, contents: contentsURL), false, nil) } catch { completionHandler(nil, false, error) }
        }
    }

    override var documentClassNames: [String] { [NSStringFromClass(PDFFileDocument.self)] }
    override var defaultType: String? { PDFFileDocument.pdfType }
    override func documentClass(forType typeName: String) -> AnyClass? { PDFFileDocument.self }
    override func typeForContents(of url: URL) throws -> String { PDFFileDocument.pdfType }
}
