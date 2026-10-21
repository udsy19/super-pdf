import AppKit
import PDFKit
import PDFModelKit
import SuperPDFCore

// Structure-preserving saves (ARCHITECTURE "Contract notes"). PDFKit redraws every page when it writes and drops what it
// doesn't model: the structure tree and tags, optional content, transitions, named destinations, JavaScript, XMP,
// EditKit's revision and marked content, annotation names, reply links and attached files, form scripts. So a document
// keeps the bytes it was read from (or the bytes an engine edit made) as its authoritative contents, with what PDFKit
// showed for them: a page's rotation and boxes and every annotation as it was, recorded the first time something could
// change the page (`ChangeTracking`), and the outline and the document attributes. A save compares PDFKit's document with
// that and writes only the differences into the authoritative bytes with QPDF (`StructureMerge`): page order, rotation and
// boxes, inserted and deleted pages, annotations added, changed and removed, form values, the outline and the
// attributes. Everything else stays as the file had it. PDFKit writes the whole file only when the bytes can't be paired
// with what it shows, and says why in the log.
//
// Nothing is read at open: pages nobody changed are never visited, so opening, editing and saving a long file cost what
// the changed pages cost. A document whose changes aren't reported (made outside DocumentKit) has every page recorded
// when its bytes are attached and compared at every save.

/// The authoritative bytes of an open document and what PDFKit showed for them (`DocumentHandle.contents`).
@MainActor
public final class DocumentBaseline: DocumentContents {
    /// The bytes; a save appends to them (or rewrites them) and they stay the base of every later save.
    public let bytes: Data
    /// The password that opened the bytes when they became authoritative.
    private let password: String?
    /// The file's page count, as PDFKit read it.
    let filePageCount: Int
    /// Pages as they were before their first change, by page object.
    private var recorded: [ObjectIdentifier: RecordedPage] = [:]
    /// Every page was recorded when the bytes were attached: the document doesn't report its changes.
    private let recordsEverything: Bool
    /// Where each page comes from once pages were inserted, removed or moved: its index in the file, nil for a page from
    /// elsewhere. Nil while the pages are the file's, in its order.
    private var order: [Int?]?
    /// Pages of the file taken out of the document, known again if they come back (a move is a removal and an insertion).
    private var removed: [ObjectIdentifier: (page: PDFKit.PDFPage, file: Int)] = [:]
    /// The page order stopped matching PDFKit's (a change that wasn't reported): saves find each page's origin instead.
    private var orderLost = false
    private let attributes: [String: String]
    private let outline: OriginalOutline
    private var cache: (key: SaveKey, bytes: Data)?
    /// Pages with changed annotations, not yet recorded, and those annotations' prints from before their change.
    private var pending: [ObjectIdentifier: PDFKit.PDFPage] = [:]
    private var originals: [ObjectIdentifier: (annotation: PDFAnnotation, print: AnnotationPrint)] = [:]

    /// Takes `bytes` as what `pdf` shows now; `pdf` must have been read from exactly these bytes.
    public init(bytes: Data, password: String?, pdf: PDFDocument) {
        self.bytes = bytes
        self.password = password
        filePageCount = pdf.pageCount
        attributes = PDFKitState.attributes(pdf)
        outline = OriginalOutline(bytes: bytes, password: password)
        let tracker = (pdf as? TrackedDocument)?.tracker
        if let tracker, !tracker.reorderedBeforeAttach {
            recordsEverything = false
            tracker.baseline = self
        } else {
            recordsEverything = true
            tracker?.baseline = nil
            for index in 0..<pdf.pageCount {
                guard let page = pdf.page(at: index) else { continue }
                recorded[ObjectIdentifier(page)] = RecordedPage(page, file: index, originals: [:])
            }
        }
    }

    /// Attaches new authoritative bytes to `document` (open, revert, engine edits and their undo).
    public static func attach(_ bytes: Data, to document: DocumentHandle) {
        document.contents = DocumentBaseline(bytes: bytes, password: document.password, pdf: document.pdf)
    }

    /// PDFKit's document for the PDF at `url`, reporting its changes so saves look only at what changed. DocumentKit
    /// opens every document this way; nil when PDFKit can't read the file.
    public static func document(url: URL) -> PDFDocument? { TrackedDocument.tracking(TrackedDocument(url: url)) }

    /// PDFKit's document for `data`, as `document(url:)`.
    public static func document(data: Data) -> PDFDocument? { TrackedDocument.tracking(TrackedDocument(data: data)) }

    // MARK: Changes as they come

    /// Something may change `page`: it is recorded as it is now, unless it already was.
    func willChange(_ page: PDFKit.PDFPage) {
        let id = ObjectIdentifier(page)
        guard recorded[id] == nil else { return }
        recorded[id] = RecordedPage(page, file: nil, originals: originals)
        pending[id] = nil
    }

    /// Something may change `annotation` on `page`: its print is kept as it is now, and the page is recorded when a save
    /// needs it (reading the page here could wait on PDFKit, which may be the caller).
    func willChange(_ annotation: PDFAnnotation, on page: PDFKit.PDFPage) {
        let id = ObjectIdentifier(page)
        guard recorded[id] == nil else { return }
        let annotationID = ObjectIdentifier(annotation)
        if originals[annotationID] == nil { originals[annotationID] = (annotation, AnnotationPrint(annotation)) }
        pending[id] = page
    }

    /// Records the pages whose annotations changed since the last save (or snapshot) asked.
    private func recordPending() {
        for (id, page) in pending where recorded[id] == nil { recorded[id] = RecordedPage(page, file: nil, originals: originals) }
        pending = [:]
        originals = [:]
    }

    private var pendingOrder: [Int?]?

    func willReorder(_ change: PageOrderChange, in pdf: PDFDocument) {
        var order = order ?? (0..<pdf.pageCount).map { $0 }
        switch change {
        case .insert(let page, let index):
            order.insert(removed.removeValue(forKey: ObjectIdentifier(page))?.file, at: min(max(index, 0), order.count))
        case .remove(let index):
            guard order.indices.contains(index) else { break }
            if let file = order[index], let page = pdf.page(at: index) { removed[ObjectIdentifier(page)] = (page, file) }
            order.remove(at: index)
        case .exchange(let a, let b):
            if order.indices.contains(a), order.indices.contains(b) { order.swapAt(a, b) }
        }
        pendingOrder = order
    }

    func didReorder(in pdf: PDFDocument) {
        order = pendingOrder
        pendingOrder = nil
        if order?.count != pdf.pageCount, !orderLost {
            orderLost = true
            Log.documents.notice("Save tracking: the page order is no longer known; saves find each page's origin")
        }
    }

    // MARK: DocumentContents

    public func snapshot(of document: DocumentHandle) -> PDFSource {
        let restorer = Services.markup?.annotationRestorer(for: document)
        let prepared = prepare(document.pdf, restorerKey: restorer?.idKey)
        if let cache, cache.key == prepared.key { return .data(cache.bytes, password: document.password) }
        let job = SaveJob(document, baseline: self, prepared: prepared, restorer: restorer)
        let data = job.outcome().data
        cache = (prepared.key, data)
        return .data(data, password: document.password)
    }

    /// What a save of `document` writes, made at once on the main actor (snapshots; NSDocument's saves run the same job
    /// off it). Without contents, PDFKit writes the file.
    public static func saveOutcome(of document: DocumentHandle) -> SaveOutcome {
        prepareSave(of: document).run()
    }

    /// A save of `document` as it is now: what changed is read on the main actor here; `run()` writes it, on any thread.
    public static func prepareSave(of document: DocumentHandle) -> PreparedSave {
        PreparedSave(job: SaveJob(document))
    }

    /// A save captured on the main actor (`prepareSave(of:)`).
    public struct PreparedSave: Sendable {
        let job: SaveJob

        /// Writes the save; off the main actor PDFKit's whole document is asked of the main thread only when the
        /// changes can't be written into the file.
        public func run() -> SaveOutcome { job.outcome() }
    }

    // MARK: Planning a save

    /// What changed through PDFKit since these bytes, as a plan the merge carries out off the main actor, the pages
    /// PDFKit must write for it, and a key that is equal when a save would write the same bytes.
    func prepare(_ pdf: PDFDocument, restorerKey: String?) -> PreparedPlan {
        let tracker = (pdf as? TrackedDocument)?.tracker
        return tracker.map { $0.muting { plan(pdf, restorerKey: restorerKey) } } ?? plan(pdf, restorerKey: restorerKey)
    }

    private func plan(_ pdf: PDFDocument, restorerKey: String?) -> PreparedPlan {
        recordPending()
        let count = pdf.pageCount
        // Each page's origin, and the recorded pages by where they are now.
        var sources: [Int?]
        var recordedAt: [Int: RecordedPage] = [:]
        if !recordsEverything, !orderLost, (order?.count ?? filePageCount) != count {
            orderLost = true
            Log.documents.notice("Save tracking: the page order is no longer known; saves find each page's origin")
        }
        if recordsEverything || orderLost {
            sources = []
            var used: Set<Int> = []
            for index in 0..<count {
                guard let page = pdf.page(at: index) else { sources.append(nil); continue }
                let entry = recorded[ObjectIdentifier(page)]
                if let entry { recordedAt[index] = entry }
                let source = recordsEverything ? entry?.file : Self.fileIndex(of: page, in: pdf)
                if let file = source, file < filePageCount, used.insert(file).inserted { sources.append(file) } else { sources.append(nil) }
            }
        } else {
            sources = order ?? (0..<count).map { $0 }
            for entry in recorded.values {
                let index = pdf.index(for: entry.page)
                if index != NSNotFound, index < count { recordedAt[index] = entry }
            }
        }

        var plan = SavePlan(filePageCount: filePageCount)
        var key = SaveKey(sources: sources)
        var output: [Int] = []
        for index in 0..<count {
            var entry = PlannedPage()
            entry.source = sources[index]
            if entry.source != nil, let record = recordedAt[index] {
                let page = record.page
                let state = PageState(page)
                if state.rotation != record.state.rotation { entry.rotation = state.rotation }
                for (box, rect) in state.boxes where !rect.isClose(to: record.state.boxes[box]) { entry.boxes[box] = rect }
                let live = page.annotations
                let prints = live.map(AnnotationPrint.init)
                key.pages.append(.init(index: index, page: ObjectIdentifier(page), state: state, annotations: live.map(ObjectIdentifier.init), prints: prints))
                entry.ids = Self.ids(live, restorerKey)
                entry.pdfKitTypes = record.types
                let known = Dictionary(record.annotations.enumerated().map { (ObjectIdentifier($0.element), $0.offset) }, uniquingKeysWith: { a, _ in a })
                var changed = live.count != record.annotations.count
                var planned: [PlannedAnnotation] = []
                for (j, annotation) in live.enumerated() {
                    guard let k = known[ObjectIdentifier(annotation)] else {
                        planned.append(PlannedAnnotation(kind: .add, live: j)); changed = true; continue
                    }
                    let same = prints[j] == record.prints[k]
                    if k != j || !same { changed = true }
                    planned.append(PlannedAnnotation(kind: same ? .keep(k) : .merge(k), live: j))
                }
                if changed {
                    entry.annotations = planned
                    entry.output = output.count
                    output.append(index)
                } else {
                    entry.liveOriginal = live.map { known[ObjectIdentifier($0)] }
                }
            } else if entry.source == nil, let page = pdf.page(at: index) {
                // A page PDFKit made or brought in from another document: written from PDFKit's copy, with its annotations.
                let live = page.annotations
                key.pages.append(.init(index: index, page: ObjectIdentifier(page), state: PageState(page), annotations: live.map(ObjectIdentifier.init),
                                       prints: live.map(AnnotationPrint.init)))
                entry.ids = Self.ids(live, restorerKey)
                entry.annotations = live.indices.map { PlannedAnnotation(kind: .add, live: $0) }
                entry.output = output.count
                output.append(index)
            }
            plan.pages.append(entry)
        }
        plan.removesPages = Set(sources.compactMap { $0 }).count < filePageCount
        plan.outputPages = output
        // New and changed links that lead to pages PDFKit doesn't write: their destinations are set to those pages. (Only
        // these: resolving a named destination changes what PDFKit shows for the link.)
        let written = Set(output)
        for index in output {
            guard let page = pdf.page(at: index) else { continue }
            let annotations = page.annotations
            for item in plan.pages[index].annotations ?? [] {
                guard let j = item.live, annotations.indices.contains(j), item.isFromPDFKit else { continue }
                // The stored values: the `action` and `destination` getters write a GoTo action into a link that has none.
                let annotation = annotations[j]
                let action = annotation.value(forAnnotationKey: .action) as? PDFActionGoTo
                let destination = action?.destination ?? annotation.value(forAnnotationKey: .destination) as? PDFKit.PDFDestination
                guard let target = destination?.page, target.document === pdf else { continue }
                let targetIndex = pdf.index(for: target)
                if targetIndex != NSNotFound, !written.contains(targetIndex) { plan.pages[index].targets[j] = targetIndex }
            }
        }
        plan.liveOutline = PDFKitState.outlineNodes(pdf)
        plan.liveOutlineKey = PDFKitState.describe(plan.liveOutline)
        let now = PDFKitState.attributes(pdf)
        for key in Set(now.keys).union(attributes.keys) where now[key] != attributes[key] { plan.attributes[key] = now[key] ?? "" }
        key.outline = plan.liveOutlineKey
        key.attributes = now
        return PreparedPlan(plan: plan, key: key, outline: outline)
    }

    /// The file page `page` shows, by the PDF page PDFKit draws it from (when the page order was lost).
    private static func fileIndex(of page: PDFKit.PDFPage, in pdf: PDFDocument) -> Int? {
        guard page is TrackedPage, let reference = page.pageRef, let document = pdf.documentRef, reference.document === document else { return nil }
        return reference.pageNumber - 1
    }

    private static func ids(_ annotations: [PDFAnnotation], _ restorerKey: String?) -> [String?] {
        guard let restorerKey else { return [] }
        let key = PDFAnnotationKey(rawValue: "/" + restorerKey)
        return annotations.map { $0.value(forAnnotationKey: key) as? String }
    }

    /// The pages PDFKit must write for `plan` (stamped so the merge finds each annotation), in a document of their own;
    /// nil when it writes none.
    func output(of pdf: PDFDocument, for plan: SavePlan) -> PDFDocument? {
        guard !plan.outputPages.isEmpty else { return nil }
        let tracker = (pdf as? TrackedDocument)?.tracker
        let copy = { () -> PDFDocument in
            let key = PDFAnnotationKey(rawValue: "/" + saveStampKey)
            let output = PDFDocument()
            for index in plan.outputPages {
                guard let page = pdf.page(at: index) else { continue }
                let annotations = page.annotations
                for (j, annotation) in annotations.enumerated() { annotation.setValue("\(index)/\(j)", forAnnotationKey: key) }
                if let copy = page.copy() as? PDFKit.PDFPage { output.insert(copy, at: output.pageCount) }
                for annotation in annotations { annotation.removeValue(forAnnotationKey: key) }
            }
            return output
        }
        return tracker.map { $0.muting(copy) } ?? copy()
    }
}

/// A page as it was before its first change.
@MainActor
struct RecordedPage {
    /// Kept so the page's identity stays its own.
    let page: PDFKit.PDFPage
    /// Its index in the file, when recorded at attach.
    let file: Int?
    let state: PageState
    /// PDFKit's annotations in its order, their prints, and their types (to pair them with the file's /Annots).
    let annotations: [PDFAnnotation]
    let prints: [AnnotationPrint]
    let types: [String]

    /// `originals`: prints of annotations taken before they changed, which stand for theirs now.
    init(_ page: PDFKit.PDFPage, file: Int?, originals: [ObjectIdentifier: (annotation: PDFAnnotation, print: AnnotationPrint)]) {
        self.page = page
        self.file = file
        state = PageState(page)
        annotations = page.annotations
        prints = annotations.map { originals[ObjectIdentifier($0)]?.print ?? AnnotationPrint($0) }
        types = annotations.map { $0.type ?? "" }
    }
}

/// A save's plan and the pages PDFKit writes for it, made on the main actor.
struct PreparedPlan {
    var plan: SavePlan
    var key: SaveKey
    var outline: OriginalOutline
}

/// Everything a save compares, equal when a save would write the same bytes (snapshots are kept until it changes).
struct SaveKey: Equatable {
    struct Page: Equatable {
        var index: Int
        var page: ObjectIdentifier
        var state: PageState
        var annotations: [ObjectIdentifier]
        var prints: [AnnotationPrint]
    }

    var sources: [Int?]
    var pages: [Page] = []
    var outline = ""
    var attributes: [String: String] = [:]
}

/// The outline as the file has it, as text (`PDFKitState.describe`): read from the bytes off the main actor once.
final class OriginalOutline: @unchecked Sendable {
    private let bytes: Data
    private let password: String?
    private let lock = NSLock()
    private var value: String?

    init(bytes: Data, password: String?) {
        self.bytes = bytes
        self.password = password
        Task.detached(priority: .utility) { [weak self] in _ = self?.key() }
    }

    func key() -> String {
        if let known = lock.withLock({ value }) { return known }
        var key = ""
        if let pdf = PDFDocument(data: bytes) {
            if pdf.isLocked, let password { pdf.unlock(withPassword: password) }
            key = PDFKitState.describe(PDFKitState.outlineNodes(pdf))
        }
        return lock.withLock {
            if value == nil { value = key }
            return value!
        }
    }
}

/// Which file annotation each of PDFKit's annotations on a page is: the longest common run of subtypes, in order
/// (PDFKit reads /Annots in order; it skips entries it can't show and makes popups the file doesn't list).
struct AnnotationPairing: Sendable {
    /// Per PDFKit annotation, its /Annots index (nil: PDFKit made it).
    var fileIndex: [Int?]
    /// /Annots entries PDFKit doesn't show.
    var hidden: [Int]

    init?(pdfKit: [String], file: [String]) {
        let n = pdfKit.count, m = file.count
        guard n * m <= 1_000_000 else { return nil }
        var length = Array(repeating: Array(repeating: 0, count: m + 1), count: n + 1)
        for i in stride(from: n - 1, through: 0, by: -1) {
            for j in stride(from: m - 1, through: 0, by: -1) {
                length[i][j] = pdfKit[i] == file[j] ? length[i + 1][j + 1] + 1 : max(length[i + 1][j], length[i][j + 1])
            }
        }
        var fileIndex = [Int?](repeating: nil, count: n)
        var matched = Set<Int>()
        var i = 0, j = 0
        while i < n && j < m {
            if pdfKit[i] == file[j] { fileIndex[i] = j; matched.insert(j); i += 1; j += 1 } else if length[i + 1][j] >= length[i][j + 1] { i += 1 } else { j += 1 }
        }
        // Every annotation PDFKit made must be a popup; anything else means the lists don't line up.
        for (k, index) in fileIndex.enumerated() where index == nil && pdfKit[k] != "Popup" { return nil }
        self.fileIndex = fileIndex
        hidden = (0..<m).filter { !matched.contains($0) }
    }
}

/// A page's rotation and boxes as PDFKit has them.
struct PageState: Equatable {
    var rotation: Int
    var boxes: [PDFBox: CGRect]

    @MainActor
    init(_ page: PDFKit.PDFPage) {
        rotation = ((page.rotation % 360) + 360) % 360
        boxes = [.media: page.bounds(for: .mediaBox), .crop: page.bounds(for: .cropBox), .bleed: page.bounds(for: .bleedBox),
                 .trim: page.bounds(for: .trimBox), .art: page.bounds(for: .artBox)]
    }
}

extension CGRect {
    func isClose(to other: CGRect?) -> Bool {
        guard let other else { return false }
        return abs(minX - other.minX) < 0.01 && abs(minY - other.minY) < 0.01 && abs(width - other.width) < 0.01 && abs(height - other.height) < 0.01
    }
}

// MARK: - The plan

/// What a save writes into the authoritative bytes: one entry per page of PDFKit's document, in its order.
struct SavePlan: Sendable {
    var filePageCount: Int
    var pages: [PlannedPage] = []
    var removesPages = false
    /// The pages PDFKit writes for the save (by their index in PDFKit's document), in the order it writes them: pages
    /// from elsewhere and pages whose annotations changed.
    var outputPages: [Int] = []
    /// The outline to write; set when it differs from the file's (`liveOutline` compared off the main actor).
    var outline: [OutlineNode]?
    var liveOutline: [OutlineNode] = []
    var liveOutlineKey = ""
    /// Changed document information entries ("Title", "Author"…; empty text removes one).
    var attributes: [String: String] = [:]
    /// What the save couldn't map and wrote from PDFKit instead.
    var notes: [String] = []

    var isEmpty: Bool {
        !removesPages && outline == nil && attributes.isEmpty && pages.count == filePageCount
            && pages.enumerated().allSatisfy { $0.element.source == $0.offset && $0.element.rotation == nil && $0.element.boxes.isEmpty && $0.element.annotations == nil }
    }
}

struct PlannedPage: Sendable {
    /// The page's index in the authoritative bytes; nil for a page written from PDFKit's copy.
    var source: Int?
    /// The page's index among the pages PDFKit writes (`SavePlan.outputPages`), when it writes it.
    var output: Int?
    var rotation: Int?
    var boxes: [PDFBox: CGRect] = [:]
    /// The page's /Annots as written; nil keeps the file's.
    var annotations: [PlannedAnnotation]?
    /// The types of PDFKit's annotations on the file page before it changed, to pair them with the file's /Annots.
    var pdfKitTypes: [String] = []
    /// The restorer's name for each of PDFKit's annotations on the page (by its index there).
    var ids: [String?] = []
    /// For a file page whose /Annots are kept, which of PDFKit's original annotations each one is.
    var liveOriginal: [Int?] = []
    /// PDFKit's annotations (by index) that lead to a page PDFKit doesn't write, with that page's index.
    var targets: [Int: Int] = [:]
}

struct PlannedAnnotation: Sendable {
    enum Kind: Sendable, Equatable {
        /// One of PDFKit's annotations as the page had them (by index), unchanged: the file's object.
        case keep(Int)
        /// One of PDFKit's annotations as the page had them (by index), changed: the file's object with PDFKit's changes.
        case merge(Int)
        /// PDFKit's dictionary, as a new object.
        case add
    }

    var kind: Kind
    /// Its index in PDFKit's list on the page.
    var live: Int?

    /// PDFKit writes its dictionary (a new or changed annotation).
    var isFromPDFKit: Bool {
        if case .keep = kind { return false }
        return true
    }
}

/// A bookmark as PDFKit has it.
struct OutlineNode: Sendable {
    var title: String
    var isOpen: Bool
    var page: Int?
    var point: CGPoint?
    var url: String?
    var children: [OutlineNode]
}

// MARK: - What PDFKit shows

/// Everything PDFKit can change about an annotation: its dictionary as PDFKit has it, without links (PDFKit gives popups a
/// new id on every read) and the app's private keys, which modules stamp on annotations while a document is open. Equal
/// prints mean nothing changed. Values are kept as they are when they can't change in place; others (borders, actions,
/// paths, which PDFKit makes anew for each read) are described as text.
struct AnnotationPrint: Equatable, @unchecked Sendable {
    private let values: NSDictionary

    init(_ annotation: PDFAnnotation) {
        let source = annotation.annotationKeyValues as NSDictionary
        let result = NSMutableDictionary(capacity: source.count + 1)
        source.enumerateKeysAndObjects { key, value, _ in
            guard let name = key as? String, !Self.isIgnored(name) else { return }
            result[name] = Self.normalized(value)
        }
        if annotation.type == "Widget" {
            result["widget"] = [annotation.widgetStringValue ?? "", annotation.buttonWidgetState.rawValue] as NSArray
        }
        values = result
    }

    static func == (a: AnnotationPrint, b: AnnotationPrint) -> Bool { a.values.isEqual(b.values) }

    private static func isIgnored(_ key: String) -> Bool {
        ["/NM", "/Popup", "/P", "/Parent", "/IRT"].contains(key) || key.hasPrefix("/SuperPDF")
    }

    private static func normalized(_ value: Any) -> Any {
        switch value {
        case is NSString, is NSNumber, is NSDate, is NSUUID, is NSData, is NSColor:
            return value
        case let value as NSValue where !(value is NSNumber):
            return value
        case let array as [Any]:
            return array.map(normalized) as NSArray
        case let dictionary as [AnyHashable: Any]:
            return dictionary.mapValues(normalized) as NSDictionary
        default:
            return PDFKitState.describe(value)
        }
    }
}

enum PDFKitState {
    static func describe(_ value: Any) -> String {
        switch value {
        case let text as String:
            return text
        case let number as NSNumber:
            return number.stringValue
        case let date as Date:
            return "\(date.timeIntervalSinceReferenceDate)"
        case let value as NSValue:
            return value.description
        case let characteristics as PDFAppearanceCharacteristics:
            return describe(characteristics.appearanceCharacteristicsKeyValues)
        case let action as PDFAction:
            return describe(action)
        case let destination as PDFKit.PDFDestination:
            return describe(destination)
        case let border as PDFBorder:
            return "border \(border.style.rawValue) \(border.lineWidth) \(border.dashPattern ?? [])"
        case let color as NSColor:
            guard let rgb = color.usingColorSpace(.deviceRGB) else { return "\(color)" }
            return String(format: "rgba %.4f %.4f %.4f %.4f", rgb.redComponent, rgb.greenComponent, rgb.blueComponent, rgb.alphaComponent)
        case let path as NSBezierPath:
            var points = [NSPoint](repeating: .zero, count: 3)
            var text = ""
            for index in 0..<path.elementCount {
                let kind = path.element(at: index, associatedPoints: &points)
                let count = switch kind {
                case .moveTo, .lineTo: 1
                case .closePath: 0
                default: 3
                }
                text += "\(kind.rawValue):" + points.prefix(count)
                    .map { String(format: "%.2f,%.2f", $0.x, $0.y) }.joined(separator: " ") + ";"
            }
            return text
        case let array as [Any]:
            return "[" + array.map(describe).joined(separator: ",") + "]"
        case let dictionary as [AnyHashable: Any]:
            return "{" + dictionary.map { ("\($0.key)", describe($0.value)) }.sorted { $0.0 < $1.0 }.map { "\($0.0)=\($0.1)" }.joined(separator: ",") + "}"
        case is PDFAnnotation, is PDFKit.PDFPage, is NSNull:
            return "-"
        default:
            // Descriptions of other objects carry their address, which says nothing about their content.
            return "\(value)".replacingOccurrences(of: "0x[0-9a-fA-F]+", with: "", options: .regularExpression)
        }
    }

    private static func describe(_ action: PDFAction) -> String {
        switch action {
        case let url as PDFActionURL: return "url \(url.url?.absoluteString ?? "")"
        case let goTo as PDFActionGoTo: return "goto " + describe(goTo.destination)
        case let named as PDFActionNamed: return "named \(named.name.rawValue)"
        case let reset as PDFActionResetForm: return "reset \(reset.fields ?? []) \(reset.fieldsIncludedAreCleared)"
        case let remote as PDFActionRemoteGoTo: return "remote \(remote.url) \(remote.pageIndex) \(remote.point)"
        default: return "action \(action.type)"
        }
    }

    private static func describe(_ destination: PDFKit.PDFDestination) -> String {
        let page = destination.page.flatMap { page in page.document?.index(for: page) } ?? -1
        return "dest \(page) \(destination.point.x),\(destination.point.y) \(destination.zoom)"
    }

    /// The outline as text: equal texts mean the same bookmarks.
    static func describe(_ nodes: [OutlineNode]) -> String {
        nodes.map { node in
            "(\(node.title)|\(node.isOpen)|\(node.page ?? -1)|\(node.point.map { "\($0.x),\($0.y)" } ?? "")|\(node.url ?? "")|\(describe(node.children)))"
        }.joined()
    }

    static func outlineNodes(_ pdf: PDFDocument) -> [OutlineNode] {
        pdf.outlineRoot.map { outlineNodes(of: $0, in: pdf) } ?? []
    }

    private static func outlineNodes(of item: PDFOutline, in pdf: PDFDocument, depth: Int = 0) -> [OutlineNode] {
        guard depth < 64 else { return [] }
        return (0..<item.numberOfChildren).compactMap { index -> OutlineNode? in
            guard let child = item.child(at: index) else { return nil }
            var destination = child.destination
            var url: String?
            switch child.action {
            case let goTo as PDFActionGoTo: destination = destination ?? goTo.destination
            case let link as PDFActionURL: url = link.url?.absoluteString
            default: break
            }
            let page = destination?.page.map { pdf.index(for: $0) }.flatMap { $0 == NSNotFound ? nil : $0 }
            let point = destination.flatMap { d -> CGPoint? in
                let unspecified = kPDFDestinationUnspecifiedValue
                return d.point.x == unspecified && d.point.y == unspecified ? nil : d.point
            }
            return OutlineNode(title: child.label ?? "", isOpen: child.isOpen, page: page, point: point, url: url,
                               children: outlineNodes(of: child, in: pdf, depth: depth + 1))
        }
    }

    /// The document information entries PDFKit lets people change, by their /Info key.
    static func attributes(_ pdf: PDFDocument) -> [String: String] {
        let attributes = pdf.documentAttributes ?? [:]
        let keys: [(PDFDocumentAttribute, String)] = [(.titleAttribute, "Title"), (.authorAttribute, "Author"), (.subjectAttribute, "Subject"),
                                                      (.keywordsAttribute, "Keywords"), (.creatorAttribute, "Creator")]
        var result: [String: String] = [:]
        for (attribute, key) in keys {
            switch attributes[attribute] {
            case let text as String where !text.isEmpty: result[key] = text
            case let list as [Any] where !list.isEmpty: result[key] = list.map { "\($0)" }.joined(separator: ", ")
            default: break
            }
        }
        return result
    }
}
