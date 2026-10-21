import AppKit
import Combine
import PDFKit
import SuperPDFCore
import UniformTypeIdentifiers

// In-memory stand-ins for every `Services` contract, owned with SuperPDFCore: a change to a contract updates its fake in
// the same change. Module tests install the fakes they need (or `installFakes()`), then their own service. Fakes record
// what they were asked and answer with canned values; none opens an app, a URL or the network.

/// Registers a fake for every slot.
@MainActor
func installFakes() {
    Services.documents = FakeDocuments()
    Services.layout = FakeLayout()
    Services.render = FakeRender()
    Services.pages = FakePages()
    Services.convert = FakeConvert()
    Services.helpers = FakeHelpers()
    Services.edit = FakeEdit()
    Services.markup = FakeMarkup()
    Services.forms = FakeForms()
    Services.sign = FakeSign()
    Services.requests = FakeRequests()
    Services.protect = FakeProtect()
    Services.fix = FakeFix()
    Services.scan = FakeScan()
    Services.batch = FakeBatch()
    Services.tools = FakeTools()
    Services.viewer = FakeViewer()
    Services.settings = FakeSettings()
    Services.updates = FakeUpdates()
    Services.toolProviders = []
}

struct FakeError: Error, Equatable { var message = "fake failure" }

/// A stream that yields `values` and finishes.
func fakeStream<T: Sendable>(_ values: [T]) -> AsyncThrowingStream<T, Error> {
    AsyncThrowingStream { continuation in
        values.forEach { continuation.yield($0) }
        continuation.finish()
    }
}

/// A real PDF with `pages` Letter pages, each saying "Page n" (for fakes and module tests).
func makePDF(pages: Int, size: CGSize = CGSize(width: 612, height: 792)) -> Data {
    let data = NSMutableData()
    var box = CGRect(origin: .zero, size: size)
    guard let consumer = CGDataConsumer(data: data as CFMutableData),
          let context = CGContext(consumer: consumer, mediaBox: &box, nil) else { return Data() }
    for n in 1...max(pages, 1) {
        context.beginPDFPage(nil)
        let line = CTLineCreateWithAttributedString(NSAttributedString(string: "Page \(n)", attributes: [.font: NSFont.systemFont(ofSize: 24)]))
        context.textPosition = CGPoint(x: 72, y: size.height - 96)
        CTLineDraw(line, context)
        context.endPDFPage()
    }
    context.closePDF()
    return data as Data
}

/// An undo manager kept alive for the run, as NSDocument keeps its own (`DocumentHandle.undoManager` is weak).
@MainActor
func makeUndoManager() -> UndoManager {
    let manager = UndoManager()
    manager.groupsByEvent = false
    UndoManagers.alive.append(manager)
    return manager
}

@MainActor
private enum UndoManagers { static var alive: [UndoManager] = [] }

/// An open-document handle over a generated PDF.
@MainActor
func makeDocument(pages: Int, url: URL? = nil) -> DocumentHandle {
    DocumentHandle(url: url, displayName: url == nil ? "Report" : nil, pdf: PDFDocument(data: makePDF(pages: pages))!, undoManager: makeUndoManager())
}

/// An undo step that does nothing (fakes that only record).
@MainActor
func noUndo(_ name: String) -> UndoGroup { UndoGroup(name, undo: {}, redo: {}) }

// MARK: - DocumentKit

@MainActor
final class FakeDocuments: DocumentManaging {
    var openDocuments: [DocumentHandle] = []
    var frontmost: DocumentHandle? { openDocuments.last }
    let subject = PassthroughSubject<DocumentEvent, Never>()
    var events: AnyPublisher<DocumentEvent, Never> { subject.eraseToAnyPublisher() }
    var applied: [(ToolID, ToolResult)] = []
    var recentDocuments: [RecentDocument] = []
    var viewStates: [URL: DocumentViewState] = [:]

    func open(_ url: URL) async throws -> DocumentHandle {
        if let open = openDocuments.first(where: { $0.url == url }) { return open }
        guard let pdf = PDFDocument(url: url) else { throw FakeError(message: Strings.Errors.damaged(url.lastPathComponent)) }
        let handle = DocumentHandle(url: url, pdf: pdf, undoManager: makeUndoManager())
        openDocuments.append(handle)
        subject.send(.opened(handle.id))
        return handle
    }

    func openUntitled(_ data: Data, name: String) throws -> DocumentHandle {
        guard let pdf = PDFDocument(data: data) else { throw FakeError() }
        let handle = DocumentHandle(url: nil, displayName: name, pdf: pdf, state: DocumentState(origin: .createdHere), undoManager: makeUndoManager())
        openDocuments.append(handle)
        subject.send(.opened(handle.id))
        return handle
    }

    /// Names as ux §7.2, " 2", " 3"… on collisions with files on disk.
    func destination(for policy: OutputPolicy, of document: DocumentHandle?, source: URL?) -> URL? {
        let original = document?.url ?? source
        let folder = original?.deletingLastPathComponent() ?? SuperPDFPaths.work
        let base = document?.displayName ?? original?.deletingPathExtension().lastPathComponent ?? "Untitled"
        let name: String
        switch policy {
        case .inPlace, .newDocument: return nil
        case .sibling(let suffix, let ext): name = suffix.fileName(base: base, ext: ext)
        case .sameName(let ext): name = "\(base).\(ext)"
        case .folder(let kind): name = kind.folderName(base: base)
        }
        var candidate = folder.appendingPathComponent(name)
        var n = 2
        while FileManager.default.fileExists(atPath: candidate.path) {
            let stem = (name as NSString).deletingPathExtension, ext = (name as NSString).pathExtension
            candidate = folder.appendingPathComponent(ext.isEmpty ? "\(stem) \(n)" : "\(stem) \(n).\(ext)")
            n += 1
        }
        return candidate
    }

    func apply(_ result: ToolResult, of request: ToolRequest) async throws {
        applied.append((request.tool, result))
        switch result {
        case .inPlace(let group, _):
            request.document?.undoManager?.beginUndoGrouping()
            request.document?.undoManager?.register(group)
            request.document?.undoManager?.endUndoGrouping()
            if let id = request.document?.id { subject.send(.changed(id)) }
        case .newDocument(let data, let name, _):
            _ = try openUntitled(data, name: name)
        case .newFile, .newFiles, .none:
            break
        }
    }

    func removeRecent(_ url: URL) { recentDocuments.removeAll { $0.url == url } }
    func viewState(for url: URL) -> DocumentViewState? { viewStates[url] }
    func saveViewState(_ state: DocumentViewState, for url: URL) { viewStates[url] = state }
}

// MARK: - LayoutKit, RenderKit

@MainActor
final class FakeLayout: LayoutAnalyzing {
    var analyzed: [PDFSource] = []

    /// One paragraph block per page holding the page's PDFKit text.
    func analyze(_ source: PDFSource, pages: [Int]?, options: LayoutOptions) async throws -> LayoutDocument {
        analyzed.append(source)
        guard let pdf = PDFDocument(data: try source.bytes()) else { throw FakeError() }
        let indices = pages ?? Array(0..<pdf.pageCount)
        return LayoutDocument(pages: indices.compactMap { index in
            guard let page = pdf.page(at: index) else { return nil }
            let bounds = page.bounds(for: .cropBox)
            let text = page.string ?? ""
            let word = LayoutWord(text: text, bounds: bounds)
            let block = LayoutBlock(id: 0, kind: .paragraph, bounds: bounds, lines: [LayoutLine(words: [word], bounds: bounds, baseline: 0)])
            return LayoutPage(index: index, size: bounds.size, blocks: [block], readingOrder: [.block(0)])
        })
    }

    func analyze(recognized lines: [RecognizedLine], pageIndex: Int, pageSize: CGSize, options: LayoutOptions) async -> LayoutPage {
        let blocks = lines.enumerated().map { index, line in
            LayoutBlock(id: index, kind: .paragraph, bounds: line.bounds,
                        lines: [LayoutLine(words: line.words, bounds: line.bounds, baseline: line.bounds.minY)])
        }
        return LayoutPage(index: pageIndex, size: pageSize, origin: .recognized, blocks: blocks, readingOrder: blocks.map { .block($0.id) })
    }
}

@MainActor
final class FakeRender: Rendering {
    var written: [URL] = []

    func rasterize(_ source: PDFSource, pages: [Int], dpi: Double, format: ImageFormat, quality: Double,
                   colorSpace: RenderColorSpace) async throws -> [RasterPage] {
        pages.map { RasterPage(index: $0, data: Data([0x89, 0x50, 0x4E, 0x47]), pixelSize: CGSize(width: 8.5 * dpi, height: 11 * dpi)) }
    }

    func writePDFA(_ source: PDFSource, level: PDFALevel, to destination: URL) async throws { try copy(source, to: destination) }
    func writePDFX(_ source: PDFSource, level: PDFXLevel, outputIntent: URL?, to destination: URL) async throws { try copy(source, to: destination) }
    func impose(_ source: PDFSource, layout: Imposition, paper: PaperSize, to destination: URL) async throws { try copy(source, to: destination) }
    func printAsImage(_ source: PDFSource, dpi: Double, to destination: URL) async throws { try copy(source, to: destination) }
    func convertColors(_ source: PDFSource, to colorSpace: RenderColorSpace, profile: URL?, flattenTransparencyAt dpi: Double?,
                       to destination: URL) async throws { try copy(source, to: destination) }

    func separation(_ source: PDFSource, page: Int, plate: Separation, dpi: Double) async throws -> (image: RasterPage, maxInk: Double) {
        (RasterPage(index: page, data: Data(), pixelSize: .zero), 0)
    }

    private func copy(_ source: PDFSource, to destination: URL) throws {
        try source.bytes().write(to: destination)
        written.append(destination)
    }
}

// MARK: - PagesKit

@MainActor
final class FakePages: PageEditing {
    var performed: [PageOperation] = []

    /// Rotation and deletion really happen (so undo can be checked); the rest are recorded.
    func perform(_ operation: PageOperation, in document: DocumentHandle) async throws -> UndoGroup {
        performed.append(operation)
        switch operation {
        case .rotate(let pages, let turns):
            let apply = { (sign: Int) in
                for index in pages { document.pdf.page(at: index).map { $0.rotation = (($0.rotation + sign * turns * 90) % 360 + 360) % 360 } }
            }
            apply(1)
            return UndoGroup("Rotate Pages", undo: { apply(-1) }, redo: { apply(1) })
        case .delete(let pages):
            guard pages.count < document.pageCount else { throw PageEditError.lastPage }
            let removed = pages.sorted(by: >).compactMap { index in document.pdf.page(at: index).map { (index, $0) } }
            removed.forEach { document.pdf.removePage(at: $0.0) }
            return UndoGroup("Delete Pages", undo: {
                for (index, page) in removed.reversed() { document.pdf.insert(page, at: index) }
            }, redo: {
                removed.forEach { document.pdf.removePage(at: $0.0) }
            })
        default:
            return noUndo("Change Pages")
        }
    }

    func extract(_ pages: [Int], from document: DocumentHandle) throws -> Data {
        let out = PDFDocument()
        for (n, index) in pages.enumerated() {
            if let page = document.pdf.page(at: index)?.copy() as? PDFPage { out.insert(page, at: n) }
        }
        return out.dataRepresentation() ?? Data()
    }

    func copy(_ pages: [Int], from source: DocumentHandle, to target: DocumentHandle, at index: Int) throws -> UndoGroup {
        noUndo("Copy Pages")
    }
}

// MARK: - ConvertKit

@MainActor
final class FakeConvert: Converting {
    var jobs: [ConversionJob] = []

    func converters(for input: UTType, to output: ConversionFormat) -> [ConverterOffer] {
        ConverterTable.engines(forExtension: input.preferredFilenameExtension ?? "", to: output).map {
            ConverterOffer(engine: $0, availability: $0 == .libreOffice ? .needsLibreOffice : .available)
        }
    }

    func canConvertToPDF(_ url: URL) -> Bool { true }

    func convert(_ job: ConversionJob, progress: ToolProgress) async throws -> ConversionResult {
        jobs.append(job)
        try makePDF(pages: job.inputs.count).write(to: job.destination)
        progress.report(completed: job.inputs.count, of: job.inputs.count)
        return ConversionResult(outputs: [job.destination], engine: .builtIn(.attributedText))
    }
}

@MainActor
final class FakeHelpers: HelperManaging {
    var libreOffice: HelperStatus = .notInstalled
    var officeApps: [OfficeApp: URL] = [:]
    var detections = 0
    let subject = PassthroughSubject<Void, Never>()
    var changes: AnyPublisher<Void, Never> { subject.eraseToAnyPublisher() }

    func detect() { detections += 1 }
    var downloadPagesOpened = 0
    func getLibreOffice() { downloadPagesOpened += 1 }
}

// MARK: - EditKit

@MainActor
final class FakeEdit: ContentEditing {
    var applied: [Decoration] = []

    func apply(_ decoration: Decoration, to pages: [Int], in document: DocumentHandle, replacing: Bool) async throws -> UndoGroup {
        if replacing { applied.removeAll { $0.kind == decoration.kind } }
        applied.append(decoration)
        return UndoGroup("Add \(decoration.kind.rawValue)", undo: { [weak self] in self?.applied.removeLast() },
                         redo: { [weak self] in self?.applied.append(decoration) })
    }

    func decorations(in document: DocumentHandle) -> [DecorationKind] { applied.map(\.kind) }

    func remove(_ kind: DecorationKind, from document: DocumentHandle) async throws -> UndoGroup {
        applied.removeAll { $0.kind == kind }
        return noUndo("Remove \(kind.rawValue)")
    }

    func replaceText(_ find: String, with replacement: String, options: FindReplaceOptions, pages: [Int],
                     in document: DocumentHandle) async throws -> (report: ReplaceReport, undo: UndoGroup) {
        (ReplaceReport(replaced: 0), noUndo("Replace"))
    }

    func scripts(in document: DocumentHandle) async throws -> [String] { [] }
    func removeScripts(from document: DocumentHandle) async throws -> UndoGroup { noUndo("Remove Scripts") }
}

// MARK: - MarkupKit

@MainActor
final class FakeMarkup: Annotating {
    var authorName = "Self Test"
    var items: [CommentItem] = []
    var scales: [Int: MeasureScale] = [:]
    var markupBarVisible = false

    func comments(in document: DocumentHandle) -> [CommentItem] { items }

    func reply(to comment: CommentItem, text: String, in document: DocumentHandle) -> UndoGroup {
        if let i = items.firstIndex(where: { $0.id == comment.id }) {
            items[i].replies.append(CommentReply(id: UUID().uuidString, author: authorName, text: text))
        }
        return noUndo("Reply")
    }

    func setStatus(_ status: ReviewStatus, of comment: CommentItem, in document: DocumentHandle) -> UndoGroup {
        if let i = items.firstIndex(where: { $0.id == comment.id }) { items[i].status = status }
        return noUndo("Set Status")
    }

    func exportComments(from document: DocumentHandle, as format: CommentFormat, to destination: URL) throws {
        try JSONEncoder().encode(items).write(to: destination)
    }

    func importComments(from file: URL, into document: DocumentHandle) throws -> UndoGroup {
        items += try JSONDecoder().decode([CommentItem].self, from: Data(contentsOf: file))
        return noUndo("Import Comments")
    }

    func summarizeComments(of document: DocumentHandle, options: CommentSummaryOptions) async throws -> Data { makePDF(pages: 1) }
    func scale(in document: DocumentHandle, page: Int) -> MeasureScale { scales[page] ?? MeasureScale() }
    func setScale(_ scale: MeasureScale, in document: DocumentHandle, page: Int) -> UndoGroup { scales[page] = scale; return noUndo("Set Scale") }
    func setMarkupBarVisible(_ visible: Bool, in document: DocumentHandle) { markupBarVisible = visible }
    func isMarkupBarVisible(in document: DocumentHandle) -> Bool { markupBarVisible }
    func perform(_ command: MenuCommand, in document: DocumentHandle) -> Bool {
        guard validate(command, in: document) != nil else { return false }
        markupBarVisible = true
        return true
    }
    func validate(_ command: MenuCommand, in document: DocumentHandle) -> Bool? {
        [.highlightText, .underlineText, .strikeThroughText, .rectangle, .oval, .line, .arrow, .text, .note, .loupe].contains(command) ? true : nil
    }
    func annotationRestorer(for document: DocumentHandle) -> (@Sendable (Data) throws -> Data)? { nil }
    func attachFile(_ file: URL, to page: Int, at point: CGPoint, in document: DocumentHandle) throws -> UndoGroup { noUndo("Attach File") }
    func addStamp(_ image: Data, on page: Int, in rect: CGRect, in document: DocumentHandle) throws -> UndoGroup { noUndo("Add Stamp") }
}

// MARK: - FormsKit

struct FakeAFEmulator: AFScriptEmulator {
    /// Sums the named fields for `AFSimple_Calculate("SUM", …)`; everything else is unsupported.
    func run(_ script: String, action: AFAction, value: String, fields: [String: String]) -> AFOutcome {
        guard action == .calculate, script.hasPrefix("AFSimple_Calculate(\"SUM\"") else { return .unsupported }
        let names = script.split(separator: "\"").enumerated().filter { $0.offset % 2 == 1 }.map { String($0.element) }.dropFirst()
        let sum = names.compactMap { fields[$0].flatMap(Double.init) }.reduce(0, +)
        return .value(sum == sum.rounded() ? String(Int(sum)) : String(sum))
    }
}

@MainActor
final class FakeForms: FormServicing {
    var formFields: [FormField] = []
    let emulator: any AFScriptEmulator = FakeAFEmulator()

    func fields(in document: DocumentHandle) -> [FormField] { formFields }

    func setValue(_ value: String, forField id: String, in document: DocumentHandle) -> UndoGroup {
        if let i = formFields.firstIndex(where: { $0.id == id }) { formFields[i].value = value }
        return noUndo("Fill")
    }

    func autoFill(_ profile: AutoFillProfile, in document: DocumentHandle) -> (filled: [String], undo: UndoGroup) {
        var filled: [String] = []
        for i in formFields.indices {
            if let value = profile.values[formFields[i].id.lowercased()] { formFields[i].value = value; filled.append(formFields[i].id) }
        }
        return (filled, noUndo("AutoFill"))
    }

    func clear(_ document: DocumentHandle) -> UndoGroup {
        for i in formFields.indices { formFields[i].value = formFields[i].defaultValue }
        return noUndo("Clear Form")
    }

    func importData(from file: URL, into document: DocumentHandle) throws -> UndoGroup { noUndo("Import Form Data") }
    func exportData(from document: DocumentHandle, as format: FormDataFormat, to destination: URL) throws {
        try JSONEncoder().encode(formFields).write(to: destination)
    }
    func isXFA(_ document: DocumentHandle) -> Bool { false }
    func detectFields(in document: DocumentHandle, pages: [Int]) async throws -> [FormField] { [] }
    func add(_ fields: [FormField], to document: DocumentHandle) throws -> UndoGroup { formFields += fields; return noUndo("Add Fields") }

    func update(_ field: FormField, in document: DocumentHandle) throws -> UndoGroup {
        if let i = formFields.firstIndex(where: { $0.id == field.id }) { formFields[i] = field }
        return noUndo("Update Field")
    }

    func remove(_ fieldIDs: [String], from document: DocumentHandle) throws -> UndoGroup {
        formFields.removeAll { fieldIDs.contains($0.id) }
        return noUndo("Remove Fields")
    }

    func setTabOrder(_ fieldIDs: [String], in document: DocumentHandle) -> UndoGroup {
        for (n, id) in fieldIDs.enumerated() { if let i = formFields.firstIndex(where: { $0.id == id }) { formFields[i].tabIndex = n } }
        return noUndo("Set Tab Order")
    }
}

// MARK: - SignKit

@MainActor
final class FakeSign: Signing {
    var savedSignatures: [SavedSignature] = []
    var identities: [SigningIdentity] = []
    var trustedCertificates: [TrustedCertificate] = []
    var signed: [CertificateSignOptions] = []

    func save(_ signature: SavedSignature) throws { savedSignatures.append(signature) }
    func delete(_ id: UUID) throws { savedSignatures.removeAll { $0.id == id } }
    func place(_ signature: SavedSignature, on page: Int, in rect: CGRect, document: DocumentHandle) throws -> UndoGroup { noUndo("Sign") }

    func createIdentity(name: String, email: String?) async throws -> SigningIdentity {
        let identity = SigningIdentity(id: UUID().uuidString, commonName: name, email: email, issuer: name,
                                       notAfter: Date().addingTimeInterval(10 * 365 * 86_400), isSelfSigned: true)
        identities.append(identity)
        return identity
    }

    func importIdentity(p12: URL, password: String) async throws -> SigningIdentity { throw FakeError() }
    func exportCertificate(of identityID: String, to destination: URL) throws { try Data().write(to: destination) }

    func sign(_ source: PDFSource, options: CertificateSignOptions, to destination: URL) async throws {
        signed.append(options)
        try source.bytes().write(to: destination)
    }

    func verify(_ source: PDFSource) async throws -> [SignatureReport] { [] }

    func trust(_ certificate: Data) throws -> TrustedCertificate {
        let trusted = TrustedCertificate(id: String(certificate.hashValue), commonName: "Someone", der: certificate)
        trustedCertificates.append(trusted)
        return trusted
    }

    func untrust(_ id: String) throws { trustedCertificates.removeAll { $0.id == id } }
}

@MainActor
final class FakeRequests: SignatureRequesting {
    var requests: [SignatureRequest] = []
    let subject = PassthroughSubject<SignatureRequest, Never>()
    var changes: AnyPublisher<SignatureRequest, Never> { subject.eraseToAnyPublisher() }
    var windowShown = false

    func save(_ request: SignatureRequest) throws {
        requests.removeAll { $0.id == request.id }
        requests.append(request)
        subject.send(request)
    }

    func makePackage(for request: SignatureRequest, from document: DocumentHandle) async throws -> URL {
        let url = SuperPDFPaths.request(request.id).appendingPathComponent("\(request.documentName).pdf")
        try (document.pdf.dataRepresentation() ?? Data()).write(to: url)
        return url
    }

    func receive(_ file: URL) async throws -> SignatureRequest? { nil }
    func seal(_ request: SignatureRequest, identityID: String) async throws -> URL { SuperPDFPaths.request(request.id) }
    func showRequestsWindow() { windowShown = true }
}

// MARK: - ProtectKit

@MainActor
final class FakeProtect: Protecting {
    var calls: [String] = []

    func find(_ query: RedactionQuery, in document: DocumentHandle, pages: [Int]) async throws -> [RedactionMark] {
        calls.append("find"); return []
    }

    func apply(_ marks: [RedactionMark], to source: PDFSource, options: RedactionOptions, destination: URL,
               progress: ToolProgress) async throws -> RedactionReport {
        calls.append("apply")
        try source.bytes().write(to: destination)
        return RedactionReport(items: marks.count, pages: Set(marks.map(\.page)).count, verified: true)
    }

    func inventory(of source: PDFSource) async throws -> HiddenInfoInventory { HiddenInfoInventory(counts: [:]) }
    func remove(_ kinds: Set<HiddenInfoKind>, from source: PDFSource, to destination: URL) async throws { try source.bytes().write(to: destination) }
    func flatten(_ source: PDFSource, options: FlattenOptions, to destination: URL) async throws { try source.bytes().write(to: destination) }
    func addPassword(to source: PDFSource, options: PasswordOptions, destination: URL) async throws { try source.bytes().write(to: destination) }
    func removePassword(from source: PDFSource, destination: URL) async throws { try source.bytes().write(to: destination) }
    func permissions(of document: DocumentHandle) -> DocumentPermissions { document.state.permissions }
    func encrypt(_ source: PDFSource, forRecipients certificates: [Data], destination: URL) async throws { try source.bytes().write(to: destination) }
    func makeEnvelope(_ files: [URL], password: String, destination: URL) async throws { try makePDF(pages: 1).write(to: destination) }
}

// MARK: - FixKit

@MainActor
final class FakeFix: Fixing {
    var optimized: [OptimizeOptions] = []

    func estimate(_ source: PDFSource, options: OptimizeOptions) async throws -> Int64 {
        let size = Int64(try source.bytes().count)
        return switch options.preset {
        case .email: size / 4
        case .good: size / 2
        case .best: size * 3 / 4
        }
    }

    func optimize(_ source: PDFSource, options: OptimizeOptions, to destination: URL, progress: ToolProgress) async throws {
        optimized.append(options)
        try source.bytes().write(to: destination)
    }

    func audit(_ source: PDFSource) async throws -> SpaceAudit {
        SpaceAudit(images: 0, fonts: 0, content: Int64(try source.bytes().count), structure: 0, attachments: 0)
    }

    func pagesWithoutText(in document: DocumentHandle) -> [Int] {
        (0..<document.pageCount).filter { (document.pdf.page(at: $0)?.string ?? "").isEmpty }
    }

    func recognize(_ source: PDFSource, pages: [Int], options: OCROptions, progress: ToolProgress) async throws -> OCRReport {
        OCRReport(data: try source.bytes(), recognizedPages: pages.count, emptyPages: 0)
    }

    func check(_ source: PDFSource, profile: CheckProfile, progress: ToolProgress) async throws -> [CheckIssue] {
        [CheckIssue(id: "title", severity: .needsAttention, title: "The document has no title", fixTitle: "Add a title")]
    }

    func fix(_ issueIDs: [String], in source: PDFSource, profile: CheckProfile, to destination: URL) async throws {
        try source.bytes().write(to: destination)
    }

    func diagnose(_ url: URL) async -> RepairDiagnosis? { nil }
    func repair(_ source: PDFSource, embedFonts: Bool, to destination: URL) async throws -> RepairDiagnosis {
        try source.bytes().write(to: destination)
        return RepairDiagnosis(problems: [])
    }
    func linearize(_ source: PDFSource, to destination: URL) async throws { try source.bytes().write(to: destination) }
    func compare(_ old: PDFSource, with new: PDFSource, textOnly: Bool, progress: ToolProgress) async throws -> [ComparisonChange] { [] }
}

// MARK: - ScanKit

@MainActor
final class FakeScan: Scanning {
    var sources: [ScanSource] = [ScanSource(id: "fake-scanner", kind: .scanner, name: "Fake Scanner")]
    let subject = PassthroughSubject<[ScanSource], Never>()
    var sourceChanges: AnyPublisher<[ScanSource], Never> { subject.eraseToAnyPublisher() }
    var browsing = false

    func startBrowsing() { browsing = true; subject.send(sources) }
    func stopBrowsing() { browsing = false }

    func scan(from source: ScanSource, settings: ScanSettings) -> AsyncThrowingStream<ScannedPage, Error> {
        fakeStream([ScannedPage(image: Data(), pixelSize: CGSize(width: 2550, height: 3300), resolution: Double(settings.resolution))])
    }

    func detectDocument(in photo: Data) async throws -> DetectedDocument? { nil }
    func straighten(_ photo: Data, to document: DetectedDocument) async throws -> ScannedPage {
        ScannedPage(image: photo, pixelSize: .zero, resolution: 300)
    }
    func cleanUp(_ page: ScannedPage, options: CleanUpOptions) async throws -> ScannedPage { page }
}

// MARK: - BatchKit

@MainActor
final class FakeBatch: BatchRunning {
    var routines: [Routine] = []
    var runs: [(BatchPipeline, [URL])] = []

    func save(_ routine: Routine) throws {
        routines.removeAll { $0.id == routine.id }
        routines.append(routine)
    }

    func delete(_ routineID: UUID) throws { routines.removeAll { $0.id == routineID } }

    func run(_ pipeline: BatchPipeline, on files: [URL]) -> AsyncThrowingStream<BatchEvent, Error> {
        runs.append((pipeline, files))
        return fakeStream(files.flatMap { [BatchEvent.started($0), .finished($0, outputs: [$0])] })
    }
}

// MARK: - ToolsKit

@MainActor
final class FakeTools: ToolRegistry {
    var providers: [ToolID: any ToolProviding] = [:]
    var uses: [ToolID] = []
    var sheetShown = 0
    var openedPanels: [ToolID] = []

    /// Collects `Services.toolProviders` as ToolsKit's install does.
    func collect() {
        for provider in Services.toolProviders { for tool in provider.tools { providers[tool] = provider } }
    }

    func provider(for tool: ToolID) -> (any ToolProviding)? { providers[tool] }

    /// Name, hint and synonym containment, names first.
    func search(_ query: String) -> [ToolTile] {
        let q = query.lowercased().trimmingCharacters(in: .whitespaces)
        guard !q.isEmpty else { return ToolCatalog.tiles }
        let byName = ToolCatalog.tiles.filter { $0.name.lowercased().contains(q) }
        let rest = ToolCatalog.tiles.filter { tile in
            !byName.contains(tile) && (tile.synonyms.contains { $0.contains(q) } || tile.hint.lowercased().contains(q))
        }
        return byName + rest
    }

    var recentlyUsed: [ToolTile] {
        var seen: Set<ToolID> = []
        return uses.reversed().filter { seen.insert($0).inserted }.prefix(SPMetrics.ToolsSheet.recentTiles).map(ToolCatalog.tile)
    }

    func recordUse(_ tool: ToolID) { uses.append(tool) }
    func showToolsSheet(for document: DocumentHandle?) { sheetShown += 1 }
    func openPanel(_ tool: ToolID, for document: DocumentHandle?, inputs: [URL]) { openedPanels.append(tool) }
    func closePanel(for document: DocumentHandle) {}

    /// A plain label with the banner's text.
    func makeBannerView(_ banner: ResultBanner, in document: DocumentHandle, dismiss: @escaping @MainActor () -> Void) -> NSView {
        NSTextField(labelWithString: banner.text)
    }

    func makeToolbarItem(_ tool: ToolID) -> NSToolbarItem {
        let item = NSToolbarItem(itemIdentifier: tool.toolbarItemIdentifier)
        item.label = ToolCatalog.tile(tool).name
        return item
    }

    func makeDockMenu() -> NSMenu {
        let menu = NSMenu()
        menu.addItem(withTitle: Strings.ToolsSheet.allTools, action: nil, keyEquivalent: "")
        for tool in Defaults[.dockMenuTools] { menu.addItem(withTitle: ToolCatalog.tile(tool).menuTitle, action: nil, keyEquivalent: "") }
        return menu
    }
}

/// A provider for one tile, running a closure (ToolsKit's and modules' host tests).
@MainActor
final class FakeToolProvider: ToolProviding {
    let tools: [ToolID]
    var runs: [ToolID] = []
    let result: @MainActor (ToolRequest) -> ToolResult

    init(_ tools: [ToolID], result: @escaping @MainActor (ToolRequest) -> ToolResult = { _ in .none }) {
        self.tools = tools; self.result = result
    }

    func panel(for tool: ToolID, context: ToolContext) -> ToolPanel {
        ToolPanel(.oneChoice, showsScope: true, controls: [.toggle(id: "all", label: "All sideways pages", isOn: false)],
                  primary: ToolButton(ToolCatalog.tile(tool).name))
    }

    func run(_ request: ToolRequest, progress: ToolProgress) async throws -> ToolResult {
        runs.append(request.tool)
        progress.report(completed: request.pages.count, of: request.pages.count)
        return result(request)
    }
}

// MARK: - ViewerKit, SettingsKit

@MainActor
final class FakeViewer: ViewerPresenting {
    var banners: [ResultBanner] = []
    var selection: [UUID: [Int]] = [:]
    var welcomeShown = 0
    var panels: [UUID: NSViewController] = [:]
    var sidebarModes: [UUID: SidebarMode] = [:]

    func makeWindowController(for document: DocumentHandle) -> NSWindowController { NSWindowController(window: nil) }
    func pdfView(for document: DocumentHandle) -> PDFView? { nil }
    func selectedPages(in document: DocumentHandle) -> [Int] { selection[document.id] ?? [] }
    func currentPage(in document: DocumentHandle) -> Int { 0 }
    func showToolPanel(_ panel: NSViewController?, in document: DocumentHandle) { panels[document.id] = panel }
    func showBanner(_ banner: ResultBanner, in document: DocumentHandle) { banners.append(banner) }
    func showSidebar(_ mode: SidebarMode, in document: DocumentHandle) { sidebarModes[document.id] = mode }
    func showOrganiser(for document: DocumentHandle, adding files: [URL]) {}
    func showWelcome() { welcomeShown += 1 }
    /// Answers locked-PDF prompts from a script (nil: the window was closed) and records each `retry`.
    var lockedPasswords: [String?] = []
    var lockedAsks: [Bool] = []
    func password(forLocked fileName: String, retry: Bool) async -> String? {
        lockedAsks.append(retry)
        return lockedPasswords.isEmpty ? nil : lockedPasswords.removeFirst()
    }
}

@MainActor
final class FakeSettings: SettingsPresenting {
    var shown: [SettingsPane?] = []
    func show(_ pane: SettingsPane?) { shown.append(pane) }
}

// MARK: - App: updates

@MainActor
final class FakeUpdates: UpdateChecking {
    var started = false
    var checks = 0
    var status: UpdateStatus = .idle
    let subject = PassthroughSubject<UpdateStatus, Never>()
    var statusChanges: AnyPublisher<UpdateStatus, Never> { subject.eraseToAnyPublisher() }

    func start() { started = true }
    func checkNow() { checks += 1; status = .upToDate(checkedAt: Date()); subject.send(status) }
    func installNow() {}
}
