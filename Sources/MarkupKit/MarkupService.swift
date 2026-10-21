import AVFoundation
import AppKit
import Combine
import Contacts
import PDFKit
import SuperPDFCore
import UniformTypeIdentifiers

/// `Services.markup` (features #8, #15, #76–#79, #116, #117): the markup bar of each open document, the comments with
/// their replies and states, comment exchange and summaries, measuring scales, attachments and stamps.
@MainActor
public final class MarkupService: Annotating {
    private var ledgers: [UUID: AnnotationLedger] = [:]
    private var sessions: [UUID: MarkupSession] = [:]
    private var scales: [UUID: [Int: MeasureScale]] = [:]
    /// The PDFKit document each document's background reading covers (a swapped one is read again).
    private var reading: [UUID: ObjectIdentifier] = [:]
    private var subscription: AnyCancellable?

    public init() {
        subscription = Services.documents?.events.sink { [weak self] event in
            MainActor.assumeIsolated { self?.handle(event) }
        }
    }

    private func handle(_ event: DocumentEvent) {
        switch event {
        case .opened(let id):
            guard let document = Services.documents?.openDocuments.first(where: { $0.id == id }) else { return }
            // Nothing is read here: a long file opens at once. Markup can be clicked, moved and deleted at any time
            // (Preview), so the layer goes over the page once the window shows it, and the pages it shows are read.
            Task { @MainActor [weak self] in
                self?.session(for: document).attach()
                self?.readInBackground(document)
            }
        case .changed(let id):
            sessions[id]?.documentChanged()
            if let document = sessions[id]?.document, reading[id] != ObjectIdentifier(document.pdf) { readInBackground(document) }
        case .closed(let id):
            sessions[id]?.detach()
            sessions[id] = nil
            ledgers[id] = nil
            scales[id] = nil
            reading[id] = nil
        case .saved:
            break
        }
    }

    /// The document's ledger; pages are read into it as they are shown, asked about or marked up.
    func ledger(for document: DocumentHandle) -> AnnotationLedger {
        if let ledger = ledgers[document.id] { return ledger }
        let ledger = AnnotationLedger()
        ledgers[document.id] = ledger
        return ledger
    }

    /// How long one slice of background reading may take before the main thread handles events again.
    static let readingSlice: Duration = .milliseconds(4)

    /// Reads the pages nobody showed yet a few at a time on the main thread (PDFKit's pages and annotations belong to
    /// it), yielding between slices, so the comments list is ready when it is asked for. Reading changes only replies (and
    /// what they reply to), so it doesn't make saves compare the pages it read.
    private func readInBackground(_ document: DocumentHandle) {
        let pdf = ObjectIdentifier(document.pdf)
        guard reading[document.id] != pdf else { return }
        reading[document.id] = pdf
        Task { @MainActor [weak self] in
            var next = 0
            while let self, self.reading[document.id] == pdf, ObjectIdentifier(document.pdf) == pdf, next < document.pageCount {
                let ledger = self.ledger(for: document), clock = ContinuousClock(), start = clock.now
                while next < document.pageCount, clock.now - start < Self.readingSlice {
                    if let page = document.pdf.page(at: next) {
                        ledger.read(page)
                        CommentList.cacheQuotes(on: page)
                    }
                    next += 1
                }
                try? await Task.sleep(for: .milliseconds(1))
            }
        }
    }

    /// The pages the window shows were drawn: their file data is read (replies stop drawing as note icons).
    func pagesShown(_ pages: [PDFPage], in document: DocumentHandle) {
        let ledger = ledger(for: document)
        pages.forEach(ledger.read)
    }

    /// The markup bar and page interaction of a document.
    func session(for document: DocumentHandle) -> MarkupSession {
        if let session = sessions[document.id] { return session }
        let session = MarkupSession(document: document, service: self)
        sessions[document.id] = session
        return session
    }

    func existingSession(for document: DocumentHandle) -> MarkupSession? { sessions[document.id] }

    // MARK: Author (features #76)

    /// Settings › General's name, else the Contacts "Me" card when Contacts access was already given (never asked
    /// for here), else the account's full name, which is what Preview writes.
    public var authorName: String {
        let setting = Defaults[.authorName].trimmingCharacters(in: .whitespaces)
        if !setting.isEmpty { return setting }
        if CNContactStore.authorizationStatus(for: .contacts) == .authorized,
           let me = try? CNContactStore().unifiedMeContactWithKeys(toFetch: [CNContactFormatter.descriptorForRequiredKeys(for: .fullName)]),
           let name = CNContactFormatter.string(from: me, style: .fullName), !name.isEmpty {
            return name
        }
        return NSFullUserName()
    }

    // MARK: Adding with undo

    /// Puts annotations on their pages (with their ledger records) as one undo step; the edit is applied on return.
    func add(_ items: [(PDFAnnotation, PDFPage)], records: [String: LedgerRecord] = [:], named name: String, in document: DocumentHandle) -> UndoGroup {
        let ledger = ledger(for: document)
        for (_, page) in items { ledger.prepare(page) }
        let put = {
            for (annotation, page) in items where !page.annotations.contains(where: { $0 === annotation }) { page.addAnnotation(annotation) }
            for (id, record) in records { ledger[id] = record }
        }
        let take = {
            for (annotation, page) in items { page.removeAnnotation(annotation) }
            for id in records.keys { ledger.remove(id) }
        }
        put()
        return UndoGroup(name, undo: { take(); self.sessions[document.id]?.refresh() }, redo: { put(); self.sessions[document.id]?.refresh() })
    }

    // MARK: Comments review (features #77)

    public func comments(in document: DocumentHandle) -> [CommentItem] { CommentList.items(in: document, ledger: readLedger(for: document)) }

    /// The ledger with every page read (what the comments list, exports and summaries need).
    private func readLedger(for document: DocumentHandle) -> AnnotationLedger {
        let ledger = ledger(for: document)
        ledger.readAll(document)
        return ledger
    }

    /// The annotation a comment id names, its page prepared for a change.
    private func target(_ id: String, in document: DocumentHandle) -> (PDFAnnotation, PDFPage)? {
        let ledger = readLedger(for: document)
        guard let (annotation, page) = CommentList.annotation(id, in: document) else { return nil }
        ledger.prepare(page)
        return (annotation, page)
    }

    public func reply(to comment: CommentItem, text: String, in document: DocumentHandle) -> UndoGroup {
        guard let (parent, page) = target(comment.id, in: document) else { return UndoGroup("Reply", undo: {}, redo: {}) }
        let reply = AnnotationFactory.note(at: CGPoint(x: parent.bounds.minX, y: parent.bounds.maxY), text: text, color: .noteYellow, author: authorName)
        reply.iconType = .comment
        reply.shouldDisplay = false
        let id = AnnotationLedger.id(of: reply)
        let record = LedgerRecord(parent: comment.id, replyType: "R", flags: 4)
        return add([(reply, page)], records: [id: record], named: "Reply", in: document)
    }

    public func setStatus(_ status: ReviewStatus, of comment: CommentItem, in document: DocumentHandle) -> UndoGroup {
        guard let (parent, page) = target(comment.id, in: document) else { return UndoGroup("Set Status", undo: {}, redo: {}) }
        let author = authorName
        let state = CommentList.state(for: status)
        let marker = AnnotationFactory.note(at: CGPoint(x: parent.bounds.minX, y: parent.bounds.maxY), text: "\(state) set by \(author)",
                                            color: .noteYellow, author: author)
        marker.setValue(state, forAnnotationKey: .state)
        marker.setValue("Review", forAnnotationKey: .stateModel)
        marker.shouldDisplay = false
        let id = AnnotationLedger.id(of: marker)
        return add([(marker, page)], records: [id: LedgerRecord(parent: comment.id, replyType: "R")],
                   named: status == .resolved ? "Resolve" : "Set Status", in: document)
    }

    public func exportComments(from document: DocumentHandle, as format: CommentFormat, to destination: URL) throws {
        let ledger = readLedger(for: document)
        let data = switch format {
        case .xfdf: CommentExchange.xfdf(of: document, ledger: ledger)
        case .fdf: CommentExchange.fdf(of: document, ledger: ledger)
        case .csv: CommentExchange.csv(comments(in: document))
        }
        try data.write(to: destination, options: .atomic)
    }

    public func importComments(from file: URL, into document: DocumentHandle) throws -> UndoGroup {
        guard ["xfdf", "xml"].contains(file.pathExtension.lowercased()) else { throw CommentExchangeError.unsupported }
        let ledger = readLedger(for: document)
        let before = ledger.records
        let added = try CommentExchange.importXFDF(try Data(contentsOf: file), into: document, ledger: ledger)
        let records = ledger.records.filter { before[$0.key] != $0.value }
        return add(added, records: records, named: "Import Comments", in: document)
    }

    public func summarizeComments(of document: DocumentHandle, options: CommentSummaryOptions) async throws -> Data {
        CommentSummary.render(document, items: comments(in: document), options: options)
    }

    // MARK: Measuring (features #15)

    public func scale(in document: DocumentHandle, page: Int) -> MeasureScale {
        if let scale = scales[document.id]?[page] { return scale }
        let measured = document.pdf.page(at: page)?.annotations.compactMap(Measure.scale(of:)).last
        return measured ?? MeasureScale(pageDistance: 72, realDistance: 1, unit: .inch)
    }

    public func setScale(_ scale: MeasureScale, in document: DocumentHandle, page: Int) -> UndoGroup {
        let previous = self.scale(in: document, page: page)
        let apply = { (scale: MeasureScale) in
            self.scales[document.id, default: [:]][page] = scale
            self.relabel(document, page: page, scale: scale)
        }
        apply(scale)
        return UndoGroup("Set Scale", undo: { apply(previous) }, redo: { apply(scale) })
    }

    /// Every measurement on the page in the new scale.
    private func relabel(_ document: DocumentHandle, page index: Int, scale: MeasureScale) {
        guard let page = document.pdf.page(at: index) else { return }
        ledger(for: document).prepare(page)
        for annotation in page.annotations {
            guard let kind = Measure.kind(of: annotation) else { continue }
            let drawn = AnnotationEditing.editable(annotation, on: page) as? DrawnAnnotation
            let points = Measure.points(of: drawn ?? annotation)
            let label = Measure.label(kind, points: points, scale: scale)
            drawn?.drawing = .measurement(points, closed: kind == .area, label: label)
            (drawn ?? annotation).contents = label
            (drawn ?? annotation).setValue(Measure.dictionary(scale), forAnnotationKey: .measure)
        }
        sessions[document.id]?.refresh()
    }

    // MARK: The bar (ux §6.4)

    public func setMarkupBarVisible(_ visible: Bool, in document: DocumentHandle) { session(for: document).setBarVisible(visible) }

    public func isMarkupBarVisible(in document: DocumentHandle) -> Bool { sessions[document.id]?.isBarVisible ?? false }

    /// Tools › Annotate's commands and the tool each picks.
    static let commandTools: [MenuCommand: MarkupTool] = [
        .highlightText: .highlight, .underlineText: .highlight, .strikeThroughText: .highlight, .rectangle: .shape(.rectangle),
        .oval: .shape(.oval), .line: .shape(.line), .arrow: .shape(.arrow), .text: .text, .note: .note, .loupe: .shape(.loupe),
    ]

    public func perform(_ command: MenuCommand, in document: DocumentHandle) -> Bool {
        guard validate(command, in: document) == true else { return false }
        let session = session(for: document)
        guard let tool = Self.commandTools[command] else { return false }
        var style = session.style
        switch command {
        case .highlightText: if case .highlight = style.textMarkup {} else { style.textMarkup = .highlight(.yellow) }
        case .underlineText: style.textMarkup = .underline
        case .strikeThroughText: style.textMarkup = .strikethrough
        default: break
        }
        session.style = style
        session.setBarVisible(true)
        session.choose(tool)
        return true
    }

    public func validate(_ command: MenuCommand, in document: DocumentHandle) -> Bool? {
        guard Self.commandTools[command] != nil else { return nil }
        return document.state.permissions.commenting && document.pageCount > 0
    }

    // MARK: Attachments and stamps (features #68, #79)

    public func attachFile(_ file: URL, to page: Int, at point: CGPoint, in document: DocumentHandle) throws -> UndoGroup {
        guard let pdfPage = document.pdf.page(at: page) else { throw PageEditError.pagesOutOfRange }
        let data = try Data(contentsOf: file)
        let type = UTType(filenameExtension: file.pathExtension)
        let annotation: DrawnAnnotation
        var record = LedgerRecord()
        if let type, type.conforms(to: .audio), let clip = try? VoiceNote.clip(from: file) {
            annotation = AnnotationFactory.speaker(at: point, title: file.deletingPathExtension().lastPathComponent, author: authorName)
            record.sound = clip
            record.icon = "Speaker"
        } else {
            annotation = AnnotationFactory.paperclip(at: point, fileName: file.lastPathComponent, author: authorName)
            let modified = (try? file.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate
            record.file = AttachedFile(fileName: file.lastPathComponent, data: data, mimeType: type?.preferredMIMEType, modified: modified)
            record.icon = "Paperclip"
        }
        let id = AnnotationLedger.id(of: annotation)
        return add([(annotation, pdfPage)], records: [id: record], named: "Attach File", in: document)
    }

    public func addStamp(_ image: Data, on page: Int, in rect: CGRect, in document: DocumentHandle) throws -> UndoGroup {
        guard let pdfPage = document.pdf.page(at: page) else { throw PageEditError.pagesOutOfRange }
        let stamp = AnnotationFactory.imageStamp(image, in: rect, author: authorName)
        return add([(stamp, pdfPage)], named: "Add Stamp", in: document)
    }

    /// The file or voice note a paper clip or speaker holds.
    func attachment(of annotation: PDFAnnotation, in document: DocumentHandle) -> LedgerRecord {
        let ledger = ledger(for: document)
        if let page = annotation.page { ledger.read(page) }
        return ledger[AnnotationLedger.key(of: annotation)]
    }

    // MARK: Saving

    public func annotationRestorer(for document: DocumentHandle) -> AnnotationRestorer? {
        ledgers[document.id]?.restorer
    }
}

/// Voice notes as PDF sound objects (features #79): 16-bit signed big-endian samples, mono.
enum VoiceNote {
    static func clip(from url: URL) throws -> SoundClip {
        let file = try AVAudioFile(forReading: url)
        let format = file.processingFormat
        let frames = AVAudioFrameCount(file.length)
        guard frames > 0, let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frames) else { throw CommentExchangeError.unreadable }
        try file.read(into: buffer)
        guard let channels = buffer.floatChannelData else { throw CommentExchangeError.unreadable }
        let count = Int(buffer.frameLength), channelCount = Int(format.channelCount)
        var samples = Data(capacity: count * 2)
        for frame in 0..<count {
            var sum: Float = 0
            for channel in 0..<channelCount { sum += channels[channel][frame] }
            let value = Int16(max(-1, min(1, sum / Float(max(channelCount, 1)))) * Float(Int16.max))
            samples.append(UInt8(truncatingIfNeeded: UInt16(bitPattern: value) >> 8))
            samples.append(UInt8(truncatingIfNeeded: UInt16(bitPattern: value)))
        }
        return SoundClip(samples: samples, rate: format.sampleRate, channels: 1, bits: 16, encoding: "Signed")
    }
}
