import AppKit
import PDFKit
import PDFModelKit
import SuperPDFCore

// Structure-preserving saves (ARCHITECTURE "Contract notes"). PDFKit redraws every page when it writes and drops what it
// doesn't model: the structure tree and tags, optional content, transitions, named destinations, JavaScript, XMP,
// EditKit's revision and marked content, annotation names, reply links and attached files, form scripts. So a document
// keeps the bytes it was read from (or the bytes an engine edit made) as its authoritative contents, with what PDFKit
// showed for them at that moment: the pages, their rotation and boxes, every annotation's fingerprint, the outline and
// the document attributes. A save or a snapshot compares PDFKit's document with that, and writes only the differences
// into the authoritative bytes with QPDF (`StructureMerge`): page order, rotation and boxes, inserted and deleted
// pages, annotations added, changed and removed, form values, the outline and the attributes. Everything else stays as
// the file had it. PDFKit writes the whole file only when the bytes can't be paired with what it shows, and says why in
// the log.

/// The authoritative bytes of an open document and what PDFKit showed for them (`DocumentHandle.contents`).
@MainActor
public final class DocumentBaseline: DocumentContents {
    /// The bytes; a save appends to them (or rewrites them) and they stay the base of every later save.
    public let bytes: Data
    /// PDFKit's pages for `bytes`, in file order.
    let pages: [PDFKit.PDFPage]
    private let pageIndex: [ObjectIdentifier: Int]
    let pageStates: [PageState]
    /// Per page, PDFKit's annotations in its order, and their fingerprints.
    let annotations: [[PDFAnnotation]]
    let prints: [[String]]
    let outline: String
    let attributes: [String: String]
    /// Per page, which of the file's /Annots entries each PDFKit annotation is (read off the main actor).
    private var pairings: [AnnotationPairing?]?
    private var pairingFailure: String?
    private var cache: (state: String, bytes: Data)?

    /// Captures what PDFKit shows for `bytes` now; `pdf` must have been read from exactly these bytes.
    public init(bytes: Data, password: String?, pdf: PDFDocument) {
        self.bytes = bytes
        var pages: [PDFKit.PDFPage] = [], states: [PageState] = [], annotations: [[PDFAnnotation]] = [], prints: [[String]] = []
        for index in 0..<pdf.pageCount {
            guard let page = pdf.page(at: index) else { continue }
            pages.append(page)
            states.append(PageState(page))
            let list = page.annotations
            annotations.append(list)
            prints.append(list.map(PDFKitState.fingerprint))
        }
        self.pages = pages
        pageIndex = Dictionary(pages.enumerated().map { (ObjectIdentifier($0.element), $0.offset) }, uniquingKeysWith: { a, _ in a })
        pageStates = states
        self.annotations = annotations
        self.prints = prints
        outline = PDFKitState.outline(pdf)
        attributes = PDFKitState.attributes(pdf)
        self.password = password
        // Pairing PDFKit's annotations with the file's objects reads every page of the file: done before the first save.
        let types = annotations.map { $0.map { $0.type ?? "" } }
        Task { @MainActor [weak self, bytes] in
            let fileTypes = await Task.detached(priority: .utility) {
                Result { try StructureMerge.annotationSubtypes(of: bytes, password: password) }
            }.value
            self?.pair(types, with: fileTypes)
        }
    }

    /// The password that opened the bytes when they became authoritative.
    private let password: String?

    /// Attaches new authoritative bytes to `document` (open, revert, engine edits and their undo).
    public static func attach(_ bytes: Data, to document: DocumentHandle) {
        document.contents = DocumentBaseline(bytes: bytes, password: document.password, pdf: document.pdf)
    }

    private func pair(_ types: [[String]], with fileTypes: Result<[[String]], Error>) {
        guard pairings == nil, pairingFailure == nil else { return }
        switch fileTypes {
        case .success(let file):
            guard file.count == types.count else {
                pairingFailure = "QPDF reads \(file.count) pages where PDFKit shows \(types.count)"
                return
            }
            pairings = zip(types, file).map { AnnotationPairing(pdfKit: $0, file: $1) }
        case .failure(let error):
            pairingFailure = "QPDF can't read the file: \(error)"
        }
    }

    private func pairingsNow() -> [AnnotationPairing?]? {
        if pairings == nil, pairingFailure == nil {
            pair(annotations.map { $0.map { $0.type ?? "" } },
                 with: Result { try StructureMerge.annotationSubtypes(of: bytes, password: password) })
        }
        return pairings
    }

    // MARK: DocumentContents

    public func snapshot(of document: DocumentHandle) -> PDFSource {
        let state = PDFKitState.key(of: document.pdf)
        if let cache, cache.state == state { return .data(cache.bytes, password: document.password) }
        let data = Self.saveOutcome(of: document).data
        cache = (state, data)
        return .data(data, password: document.password)
    }

    /// What a save of `document` writes, made at once on the main actor (snapshots; NSDocument's saves run the same job
    /// off it). Without contents, PDFKit writes the file.
    public static func saveOutcome(of document: DocumentHandle) -> SaveOutcome {
        SaveJob(document, baseline: document.contents as? DocumentBaseline).run()
    }

    // MARK: Planning a save

    /// What changed through PDFKit since these bytes, as a plan the merge carries out off the main actor; nil (with the
    /// reason) when PDFKit's document can't be paired with the bytes.
    func plan(for pdf: PDFDocument, restorerKey: String?) -> (plan: SavePlan?, reason: String?) {
        guard let pairings = pairingsNow() else { return (nil, pairingFailure ?? "the file's annotations could not be read") }
        var plan = SavePlan(filePageCount: pages.count)
        var used: Set<Int> = []
        for index in 0..<pdf.pageCount {
            guard let page = pdf.page(at: index) else { continue }
            let live = page.annotations
            var entry = PlannedPage()
            entry.ids = live.map { annotation in restorerKey.flatMap { annotation.value(forAnnotationKey: PDFAnnotationKey(rawValue: "/" + $0)) as? String } }
            if let source = pageIndex[ObjectIdentifier(page)], !used.contains(source) {
                used.insert(source)
                entry.source = source
                let state = PageState(page)
                if state.rotation != pageStates[source].rotation { entry.rotation = state.rotation }
                for (box, rect) in state.boxes where !rect.isClose(to: pageStates[source].boxes[box]) { entry.boxes[box] = rect }
                entry.annotations = plannedAnnotations(live, page: index, source: source, pairing: pairings[source], plan: &plan)
                if entry.annotations == nil { entry.liveFile = pairings[source]?.fileIndex ?? [] }
            } else {
                // A page PDFKit made or brought in from another document: written from PDFKit's copy, with its annotations.
                plan.needsOutput = true
                entry.output = index
                entry.annotations = live.indices.map { PlannedAnnotation(kind: .add, live: $0) }
            }
            plan.pages.append(entry)
        }
        plan.removesPages = used.count < pages.count
        if PDFKitState.outline(pdf) != outline { plan.outline = PDFKitState.outlineNodes(pdf) }
        let now = PDFKitState.attributes(pdf)
        for key in Set(now.keys).union(attributes.keys) where now[key] != attributes[key] { plan.attributes[key] = now[key] ?? "" }
        return (plan, nil)
    }

    /// The page's annotations as the save writes them: the file's own objects for those PDFKit shows unchanged, merged
    /// with PDFKit's dictionary for changed ones, PDFKit's for new ones; objects PDFKit doesn't show stay.
    private func plannedAnnotations(_ live: [PDFAnnotation], page: Int, source: Int, pairing: AnnotationPairing?,
                                    plan: inout SavePlan) -> [PlannedAnnotation]? {
        let originals = annotations[source]
        let known = Dictionary(originals.enumerated().map { (ObjectIdentifier($0.element), $0.offset) }, uniquingKeysWith: { a, _ in a })
        var changed = live.count != originals.count
        var planned: [PlannedAnnotation] = []
        for (j, annotation) in live.enumerated() {
            guard let k = known[ObjectIdentifier(annotation)] else {
                planned.append(PlannedAnnotation(kind: .add, live: j)); changed = true; continue
            }
            if k != j { changed = true }
            let same = PDFKitState.fingerprint(annotation) == prints[source][k]
            if !same { changed = true }
            guard let pairing else { continue }   // the whole list is replaced below
            if let file = pairing.fileIndex[k] {
                planned.append(PlannedAnnotation(kind: same ? .keep(file) : .merge(file), live: j))
            } else if !same {
                planned.append(PlannedAnnotation(kind: .add, live: j))   // PDFKit made it (a popup) and it changed since
            }
        }
        guard changed else { return nil }
        if let pairing {
            planned += pairing.hidden.map { PlannedAnnotation(kind: .keep($0), live: nil) }
        } else {
            // The file's /Annots can't be told apart: PDFKit's whole list replaces them.
            plan.notes.append("page \(page + 1): annotations written from PDFKit (they couldn't be paired with the file's)")
            planned = live.indices.map { PlannedAnnotation(kind: .add, live: $0) }
        }
        if planned.contains(where: \.needsOutput) { plan.needsOutput = true }
        return planned
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
    /// PDFKit's copy must be written (new or changed annotations, pages from elsewhere).
    var needsOutput = false
    var outline: [OutlineNode]?
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
    /// The page's index in PDFKit's copy, for a page written from it.
    var output: Int?
    var rotation: Int?
    var boxes: [PDFBox: CGRect] = [:]
    /// The page's /Annots as written; nil keeps the file's.
    var annotations: [PlannedAnnotation]?
    /// The restorer's name for each of PDFKit's annotations on the page (by its index there).
    var ids: [String?] = []
    /// For a file page whose /Annots are kept, the /Annots index of each of PDFKit's annotations.
    var liveFile: [Int?] = []
}

struct PlannedAnnotation: Sendable {
    enum Kind: Sendable, Equatable {
        /// The file's object, untouched.
        case keep(Int)
        /// The file's object with PDFKit's changes written into it.
        case merge(Int)
        /// PDFKit's dictionary, as a new object.
        case add
    }

    var kind: Kind
    /// Its index in PDFKit's list on the page (nil for file objects PDFKit doesn't show).
    var live: Int?

    var needsOutput: Bool {
        switch kind {
        case .merge, .add: true
        case .keep: false
        }
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

@MainActor
enum PDFKitState {
    /// Keys a fingerprint leaves out: links (PDFKit gives popups a new id on every read) and the app's private keys,
    /// which modules stamp on annotations while a document is open.
    private static func isIgnored(_ key: String) -> Bool {
        ["/NM", "/Popup", "/P", "/Parent", "/IRT"].contains(key) || key.hasPrefix("/SuperPDF")
    }

    /// Everything PDFKit can change about an annotation, as text: equal fingerprints mean nothing changed.
    static func fingerprint(_ annotation: PDFAnnotation) -> String {
        var parts = [annotation.type ?? "", describe(NSValue(rect: annotation.bounds)), annotation.contents ?? "",
                     annotation.widgetStringValue ?? "", "\(annotation.buttonWidgetState.rawValue)",
                     "\(annotation.shouldDisplay)\(annotation.shouldPrint)\(annotation.isReadOnly)"]
        for (key, value) in annotation.annotationKeyValues.map({ ("\($0.key)", $0.value) }).sorted(by: { $0.0 < $1.0 }) where !isIgnored(key) {
            parts.append(key + "=" + describe(value))
        }
        if let paths = annotation.paths { parts.append(paths.map { describe($0) }.joined(separator: ";")) }
        return parts.joined(separator: "|")
    }

    private static func describe(_ value: Any) -> String {
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

    static func outline(_ pdf: PDFDocument) -> String {
        guard let root = pdf.outlineRoot else { return "" }
        return describe(outlineNodes(of: root, in: pdf))
    }

    private static func describe(_ nodes: [OutlineNode]) -> String {
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

    /// Everything a save would compare, as one text: equal keys mean a save would write the same bytes.
    static func key(of pdf: PDFDocument) -> String {
        var parts: [String] = []
        for index in 0..<pdf.pageCount {
            guard let page = pdf.page(at: index) else { continue }
            let state = PageState(page)
            parts.append("p\(ObjectIdentifier(page).hashValue) \(state.rotation) "
                         + PDFBox.allCases.map { state.boxes[$0].map { "\($0)" } ?? "" }.joined(separator: " "))
            for annotation in page.annotations { parts.append("a\(ObjectIdentifier(annotation).hashValue) " + fingerprint(annotation)) }
        }
        parts.append(outline(pdf))
        parts.append(attributes(pdf).sorted { $0.key < $1.key }.map { "\($0.key)=\($0.value)" }.joined(separator: "|"))
        return parts.joined(separator: "\n")
    }
}
