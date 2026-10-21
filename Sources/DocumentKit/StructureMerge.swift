import Foundation
import PDFKit
import PDFModelKit
import SuperPDFCore

/// The direct annotation key a save stamps on PDFKit's copy ("page/index") to find each annotation in what PDFKit
/// writes. PDFKit keeps direct values of keys it doesn't know; nothing written keeps the stamp.
let saveStampKey = "SuperPDFSave"

/// How a save wrote its bytes.
public enum SaveMethod: Equatable, Sendable {
    /// Nothing changed: the authoritative bytes as they are.
    case unchanged
    /// The changes appended to the authoritative bytes as an incremental update (earlier signatures stay valid).
    case appended
    /// The authoritative bytes with the changes, rewritten whole by QPDF (encrypted or repaired files, removed pages).
    case rewritten
    /// PDFKit wrote the file: the bytes couldn't be paired with what PDFKit shows (`SaveOutcome.notes` says why).
    case pdfKit
}

public struct SaveOutcome: Sendable {
    public var data: Data
    public var method: SaveMethod
    /// What the save couldn't map and wrote from PDFKit instead.
    public var notes: [String]
}

/// A save captured on the main actor and run off it (at once for a snapshot): the authoritative bytes, the plan of what
/// changed through PDFKit, and a document of its own with the pages PDFKit must write for it. Nothing here copies the
/// whole of PDFKit's document unless the changes can't be written into the file.
struct SaveJob: @unchecked Sendable {
    private let base: Data?
    private let password: String?
    private let plan: SavePlan?
    private let outline: OriginalOutline?
    /// The pages PDFKit writes for the plan (`SavePlan.outputPages`), stamped; or, without bytes, all of PDFKit's document.
    private let output: PDFDocument?
    private let restorer: AnnotationRestorer?
    /// PDFKit's document, for the rare save it must write whole.
    private let live: LiveDocument

    @MainActor
    init(_ document: DocumentHandle) {
        let restorer = Services.markup?.annotationRestorer(for: document)
        if let baseline = document.contents as? DocumentBaseline {
            self.init(document, baseline: baseline, prepared: baseline.prepare(document.pdf, restorerKey: restorer?.idKey), restorer: restorer)
        } else {
            let live = LiveDocument(document.pdf)
            self.init(base: nil, password: document.password, plan: nil, outline: nil, output: live.copy(), restorer: restorer, live: live)
        }
    }

    @MainActor
    init(_ document: DocumentHandle, baseline: DocumentBaseline, prepared: PreparedPlan, restorer: AnnotationRestorer?) {
        self.init(base: baseline.bytes, password: document.password, plan: prepared.plan, outline: prepared.outline,
                  output: baseline.output(of: document.pdf, for: prepared.plan), restorer: restorer, live: LiveDocument(document.pdf))
    }

    private init(base: Data?, password: String?, plan: SavePlan?, outline: OriginalOutline?, output: PDFDocument?, restorer: AnnotationRestorer?,
                 live: LiveDocument) {
        self.base = base
        self.password = password
        self.plan = plan
        self.outline = outline
        self.output = output
        self.restorer = restorer
        self.live = live
    }

    /// What the save writes. Off the main actor a whole-file PDFKit write (when the changes can't be written into the
    /// file) asks the main thread for PDFKit's document; one that can't be had in time writes the file as it was and
    /// says so (`notes`), which `PendingWrite` refuses.
    func outcome() -> SaveOutcome {
        var reason = "the document has no file bytes to keep"
        if let base, var plan {
            if let outline, outline.key() != plan.liveOutlineKey { plan.outline = plan.liveOutline }
            if plan.isEmpty { return SaveOutcome(data: base, method: .unchanged, notes: []) }
            do {
                var written: Data?
                if !plan.outputPages.isEmpty {
                    guard let data = output?.dataRepresentation() else { throw PDFModelError.failed("PDFKit wrote nothing") }
                    written = data
                }
                var merge = try StructureMerge(plan: plan, base: base, password: password, output: written, restorer: restorer)
                let (data, method) = try merge.run()
                for note in merge.notes { Log.documents.notice("Save: \(note, privacy: .public)") }
                return SaveOutcome(data: data, method: method, notes: merge.notes)
            } catch {
                reason = "the changes couldn't be written into the file: \(error)"
            }
        }
        Log.documents.notice("Save: PDFKit writes the whole file because \(reason, privacy: .public)")
        let whole = plan == nil ? output : live.copy()
        guard let whole, let data = StructureMerge.pdfKitOnly(whole, password: password, restorer: restorer) else {
            return SaveOutcome(data: base ?? Data(), method: .pdfKit, notes: [reason, SaveOutcome.notWritten])
        }
        return SaveOutcome(data: data, method: .pdfKit, notes: [reason])
    }
}

extension SaveOutcome {
    /// The note of a save that couldn't write the changes at all (its data is the file as it was).
    static let notWritten = "PDFKit's document couldn't be written"

    var isWritten: Bool { !notes.contains(Self.notWritten) }
}

/// PDFKit's document, copied whole on the main thread when a save needs it (from any thread).
final class LiveDocument: @unchecked Sendable {
    private weak var pdf: PDFDocument?

    init(_ pdf: PDFDocument) { self.pdf = pdf }

    func copy() -> PDFDocument? {
        let copy = { @MainActor [weak self] () -> PDFDocument? in
            guard let pdf = self?.pdf else { return nil }
            let tracker = (pdf as? TrackedDocument)?.tracker
            return tracker.map { $0.muting { pdf.copy() as? PDFDocument } } ?? pdf.copy() as? PDFDocument
        }
        if Thread.isMainThread { return MainActor.assumeIsolated { copy() } }
        // NSDocument writes on its own thread with the main thread free; waiting is bounded so a main thread that is
        // itself waiting for the write can't hang it.
        let box = CopyBox()
        let done = DispatchSemaphore(value: 0)
        DispatchQueue.main.async {
            MainActor.assumeIsolated { box.document = copy() }
            done.signal()
        }
        guard done.wait(timeout: .now() + 30) == .success else { return nil }
        return box.document
    }

    private final class CopyBox: @unchecked Sendable { var document: PDFDocument? }
}

/// Writes a save plan into the authoritative bytes (off the main actor). Objects of PDFKit's output are brought over by
/// `Importer`, which maps PDFKit's pages and annotations onto the file's own objects so nothing is copied twice.
struct StructureMerge {
    let plan: SavePlan
    let model: PDFModel
    let output: PDFModel?
    let restorer: AnnotationRestorer?
    private(set) var notes: [String]

    init(plan: SavePlan, base: Data, password: String?, output: Data?, restorer: AnnotationRestorer?) throws {
        self.plan = plan
        self.restorer = restorer
        notes = plan.notes
        model = try PDFModel(data: base, password: password)
        self.output = try output.map { data in
            if let plain = try? PDFModel(data: data) { return plain }
            return try PDFModel(data: data, password: password)
        }
    }

    // MARK: Running

    mutating func run() throws -> (Data, SaveMethod) {
        let filePages = model.pages
        guard filePages.count == plan.filePageCount else {
            throw PDFModelError.invalidOperation("the file has \(filePages.count) pages, PDFKit read \(plan.filePageCount)")
        }
        var dropped: Set<String> = [saveStampKey]
        if let key = restorer?.idKey { dropped.insert(key) }
        let importer = output.map { Importer(target: model, source: $0, dropping: dropped) }

        // Stamped annotations of PDFKit's output, by their place in PDFKit's document.
        var stamped: [String: PDFObject] = [:]
        let outputPages = output?.pages ?? []
        for page in outputPages {
            for annotation in page.annotations { if let key = annotation[saveStampKey]?.text, stamped[key] == nil { stamped[key] = annotation } }
        }

        // The pages in their new order: the file's own, and new ones for pages PDFKit brought.
        let finalPages: [PDFObject] = plan.pages.map { entry in
            if let source = entry.source { return filePages[source].object }
            return model.makeIndirect(.dictionary(["Type": .name("Page")]))
        }
        if let importer {
            for (k, page) in outputPages.enumerated() where k < plan.outputPages.count && plan.outputPages[k] < finalPages.count {
                importer.map(page.object, to: finalPages[plan.outputPages[k]])
            }
        }

        // Which of the file's /Annots entries each of PDFKit's annotations was, for the pages whose annotations matter.
        var pairings: [Int: AnnotationPairing?] = [:]
        func pairing(_ index: Int) -> AnnotationPairing? {
            if let known = pairings[index] { return known }
            let entry = plan.pages[index]
            let made = entry.source.flatMap { source in
                AnnotationPairing(pdfKit: entry.pdfKitTypes, file: filePages[source].annotations.map { $0["Subtype"]?.name ?? "" })
            }
            pairings[index] = made
            return made
        }

        // Every annotation's object in the result, mapped from PDFKit's output first so references between them resolve.
        var finalAnnotations: [[PDFObject]] = Array(repeating: [], count: plan.pages.count)
        var byPlace: [String: PDFObject] = [:]
        var fromPDFKit: [(object: PDFObject, source: PDFObject, merge: Bool, page: Int, live: Int?)] = []
        for (index, entry) in plan.pages.enumerated() {
            let fileAnnotations = entry.source.map { filePages[$0].annotations } ?? []
            let planned = resolved(entry, page: index, pairing: entry.annotations == nil || entry.source == nil ? nil : pairing(index))
                ?? fileAnnotations.indices.map { PlannedAnnotation(kind: .keep($0), live: nil) }
            var objects: [PDFObject] = []
            for item in planned {
                let place = item.live.map { "\(index)/\($0)" }
                var object: PDFObject?
                switch item.kind {
                case .keep(let file):
                    object = fileAnnotations.indices.contains(file) ? fileAnnotations[file] : nil
                case .merge(let file):
                    guard fileAnnotations.indices.contains(file) else { break }
                    object = fileAnnotations[file]
                    if let place, let source = stamped[place] {
                        importer?.map(source, to: fileAnnotations[file])
                        fromPDFKit.append((fileAnnotations[file], source, true, index, item.live))
                    } else {
                        notes.append("page \(index + 1): PDFKit didn't write a changed annotation; the file's is kept")
                    }
                case .add:
                    guard let place, let source = stamped[place] else {
                        notes.append("page \(index + 1): PDFKit didn't write an annotation; it is left out")
                        break
                    }
                    let made = model.makeIndirect(.dictionary([:]))
                    importer?.map(source, to: made)
                    fromPDFKit.append((made, source, false, index, item.live))
                    object = made
                }
                guard let object else { continue }
                objects.append(object)
                if let place { byPlace[place] = object }
            }
            finalAnnotations[index] = objects
        }
        // Any stamped dictionary of PDFKit's output resolves to the annotation at its place: unchanged ones to the file's
        // objects, and the copies of notes PDFKit writes as their popups' /Parent to the notes themselves.
        importer?.places = byPlace.compactMapValues(\.reference)

        // Pages brought from PDFKit: their dictionary (content, resources, boxes) from its output.
        if let importer {
            for (index, entry) in plan.pages.enumerated() where entry.source == nil {
                guard let output = entry.output, outputPages.indices.contains(output) else { continue }
                let source = outputPages[output].object
                for (key, value) in source.value.dictionaryValue ?? [:] where !["Parent", "Annots", "StructParents", "B", "Type"].contains(key) {
                    finalPages[index].set(key, importer.value(value))
                }
            }
        }

        // New and changed annotations.
        for item in fromPDFKit {
            guard let importer else { break }
            if item.merge {
                Self.merge(item.source, into: item.object, importer: importer)
            } else {
                for (key, value) in item.source.value.dictionaryValue ?? [:] where !dropped.contains(key) && key != "P" {
                    item.object.set(key, importer.value(value))
                }
                if let page = finalPages[item.page].reference { item.object.set("P", page) }
            }
            // A link to a page PDFKit didn't write leads to that page of the result.
            if let live = item.live, let target = plan.pages[item.page].targets[live], let page = finalPages[target].reference {
                Self.retarget(item.object, to: page)
            }
        }

        // Popups PDFKit made for new annotations go on the page with them.
        for item in fromPDFKit where !item.merge {
            guard let popup = item.object["Popup"], let popupID = popup.objectID,
                  !finalAnnotations[item.page].contains(where: { $0.objectID == popupID }) else { continue }
            finalAnnotations[item.page].append(popup)
            if let page = finalPages[item.page].reference { popup.set("P", page) }
        }

        // /Annots, where the list changed.
        var removedWidgets: Set<Int> = []
        for (index, entry) in plan.pages.enumerated() where entry.annotations != nil {
            let page = finalPages[index]
            let references = finalAnnotations[index].compactMap(\.reference)
            let before = entry.source.map { filePages[$0].annotations } ?? []
            let kept = Set(references.compactMap { $0.referenceValue?.id })
            for gone in before where gone["Subtype"]?.name == "Widget" {
                if let id = gone.objectID, !kept.contains(id) { removedWidgets.insert(id) }
            }
            if references.isEmpty { page.remove("Annots") } else { page.set("Annots", .array(references)) }
        }
        // Removed pages leave the file whole: their widgets leave the form now, everything else once the page tree is final.
        var removedPages: RemovedPages?
        if plan.removesPages {
            let kept = Set(finalPages.compactMap(\.objectID))
            let removed = RemovedPages(model: model, removed: filePages.map(\.object).filter { !kept.contains($0.objectID ?? -1) }, kept: finalPages)
            removedWidgets.formUnion(removed.widgets)
            removedPages = removed
        }
        updateFields(added: fromPDFKit.filter { !$0.merge && $0.object["Subtype"]?.name == "Widget" }.map(\.object), removed: removedWidgets,
                     importer: importer)

        // Outline matches are found by page object, so read the old outline before the page tree changes.
        let oldOutline = plan.outline == nil ? [] : outlineObjects()

        // The page tree, when pages moved, came or went.
        let fileIDs = filePages.map { $0.object.objectID }
        if fileIDs != finalPages.map(\.objectID) {
            for index in stride(from: model.pageCount - 1, through: 0, by: -1) { try model.removePage(at: index) }
            for (index, page) in finalPages.enumerated() { try model.insertPage(PDFModelKit.PDFPage(page), at: index) }
        }
        for (index, entry) in plan.pages.enumerated() {
            guard let page = model.page(at: index) else { continue }
            if let rotation = entry.rotation { page.setRotation(rotation) }
            for (box, rect) in entry.boxes { page.setBox(box, rect) }
        }

        if let outline = plan.outline { writeOutline(outline, matching: oldOutline, removedPages: removedPages?.pages ?? []) }
        for (key, value) in plan.attributes { model.setInfo(key, value.isEmpty ? nil : value) }
        if !plan.attributes.isEmpty { model.updateXMP(forInfo: Set(plan.attributes.keys), modified: Date()) }

        if let restorer {
            var named: [String: AnyObject] = [:]
            var written: Set<String> = []
            let fromPDFKitIDs = Set(fromPDFKit.compactMap(\.object.objectID))
            for (index, entry) in plan.pages.enumerated() {
                for (j, id) in entry.ids.enumerated() {
                    guard let id, let object = byPlace["\(index)/\(j)"] ?? keptObject(entry, live: j, filePages, pairing(index)) else { continue }
                    named[id] = object
                    if let objectID = object.objectID, fromPDFKitIDs.contains(objectID) { written.insert(id) }
                }
            }
            // Pages nobody changed weren't read from PDFKit: their annotations answer to their names in the file (a new
            // reply's note may be on one).
            if !written.isEmpty {
                for (index, entry) in plan.pages.enumerated() where entry.annotations == nil && entry.ids.isEmpty {
                    for annotation in finalPages[index]["Annots"]?.items ?? [] {
                        if let name = annotation["NM"]?.text, named[name] == nil { named[name] = annotation }
                    }
                }
            }
            try restorer.restore(model, named, written)
        }

        if let removedPages {
            let cleared = removedPages.run(sources: plan.pages.map(\.source))
            if cleared > 0 { Log.documents.notice("Save: cleared \(cleared) other references to removed pages") }
        }

        if plan.removesPages || !model.canSaveIncrementally {
            return (try model.data(), .rewritten)
        }
        return (try model.incrementalData(), .appended)
    }

    /// The file's object for PDFKit's `live`-th annotation on a page whose /Annots are kept as they are.
    private func keptObject(_ entry: PlannedPage, live: Int, _ filePages: [PDFModelKit.PDFPage], _ pairing: AnnotationPairing?) -> PDFObject? {
        guard entry.annotations == nil, let source = entry.source, let pairing, entry.liveOriginal.indices.contains(live),
              let original = entry.liveOriginal[live], pairing.fileIndex.indices.contains(original), let file = pairing.fileIndex[original] else { return nil }
        let annotations = filePages[source].annotations
        return annotations.indices.contains(file) ? annotations[file] : nil
    }

    /// The page's planned annotations with PDFKit's annotations as the page had them resolved to the file's /Annots
    /// entries: unchanged ones are the file's objects, changed ones merge into them, and the entries PDFKit doesn't show
    /// stay. Nil keeps the file's /Annots.
    private mutating func resolved(_ entry: PlannedPage, page index: Int, pairing: AnnotationPairing?) -> [PlannedAnnotation]? {
        guard let planned = entry.annotations else { return nil }
        guard entry.source != nil else { return planned }
        guard let pairing else {
            // The file's /Annots can't be told apart: PDFKit's whole list replaces them.
            notes.append("page \(index + 1): annotations written from PDFKit (they couldn't be paired with the file's)")
            return planned.compactMap { $0.live.map { PlannedAnnotation(kind: .add, live: $0) } }
        }
        var result: [PlannedAnnotation] = []
        for item in planned {
            switch item.kind {
            case .add:
                result.append(item)
            case .keep(let original):
                // An unchanged annotation PDFKit made (a popup) isn't written.
                guard pairing.fileIndex.indices.contains(original), let file = pairing.fileIndex[original] else { continue }
                result.append(PlannedAnnotation(kind: .keep(file), live: item.live))
            case .merge(let original):
                if pairing.fileIndex.indices.contains(original), let file = pairing.fileIndex[original] {
                    result.append(PlannedAnnotation(kind: .merge(file), live: item.live))
                } else {
                    result.append(PlannedAnnotation(kind: .add, live: item.live))   // PDFKit made it (a popup) and it changed since
                }
            }
        }
        return result + pairing.hidden.map { PlannedAnnotation(kind: .keep($0), live: nil) }
    }

    /// Points the destination of `annotation` (its /Dest, or its GoTo action's /D) at `page`; named destinations stay.
    private static func retarget(_ annotation: PDFObject, to page: PDFValue) {
        func retargeted(_ array: PDFObject) -> PDFValue {
            var items = array.value.arrayValue ?? []
            if items.isEmpty { items = [page, .name("Fit")] } else { items[0] = page }
            return .array(items)
        }
        if let destination = annotation["Dest"], destination.type == .array { annotation.set("Dest", retargeted(destination)) }
        if let action = annotation["A"], action["S"]?.name == "GoTo", let destination = action["D"], destination.type == .array {
            action.set("D", retargeted(destination))
        }
    }

    // MARK: Annotations

    /// Keys of an annotation PDFKit doesn't model or rewrites on its own: always the file's.
    private static let fileKeys: Set<String> = ["Type", "Subtype", "P", "Parent", "Popup", "IRT", "RT", "NM", "StructParent", "Kids", "AA",
                                                "OC", "FS", "Sound", "Ff", "T", "TU", "TM", "MK", "DR", "Opt", "Lock", "SV"]
    /// Keys PDFKit writes whenever an annotation has them: one it leaves out was removed.
    private static let pdfKitKeys: Set<String> = ["Contents", "C", "IC", "BS", "Border", "AP", "AS", "QuadPoints", "InkList", "L", "LE",
                                                  "Vertices", "CA", "DS", "RC", "Q", "BE"]
    /// Action types PDFKit models; any other action stays the file's (PDFKit drops JavaScript and the like).
    private static let pdfKitActions: Set<String> = ["URI", "GoTo", "GoToR", "Named", "ResetForm", "Launch"]

    /// Writes what PDFKit changed into the file's annotation: its keys over the file's, except those PDFKit can't hold;
    /// a form field's value goes to the field.
    static func merge(_ source: PDFObject, into object: PDFObject, importer: Importer) {
        let new = source.value.dictionaryValue ?? [:]
        if object["Subtype"]?.name == "Widget" {
            let field = object["T"] != nil || object["Parent"] == nil ? object : object["Parent"]!
            if let value = source.inherited("V") {
                field.set("V", importer.value(value.reference ?? value.value))
            } else {
                field.remove("V")
            }
            if let state = new["AS"] { object.set("AS", importer.value(state)) }
            // A check box or radio button keeps the file's appearances and switches state; a text or choice field
            // takes PDFKit's appearance of its new value.
            if let appearance = new["AP"], object.inherited("FT")?.name != "Btn" || object["AP"] == nil {
                object.set("AP", importer.value(appearance))
            }
            return
        }
        let subtype = object["Subtype"]?.name
        for (key, value) in new where !fileKeys.contains(key) && !importer.dropping.contains(key) {
            if key == "A", let kind = object["A"]?["S"]?.name, !pdfKitActions.contains(kind) { continue }
            if key == "Name", subtype != "Text" { continue }
            object.set(key, importer.value(value))
        }
        for key in pdfKitKeys where new[key] == nil && object.has(key) { object.remove(key) }
    }

    /// New widgets join the form; removed ones leave it (with fields left without widgets).
    private func updateFields(added: [PDFObject], removed: Set<Int>, importer: Importer?) {
        if !removed.isEmpty, let fields = model.acroForm?["Fields"] {
            func prune(_ array: PDFObject, depth: Int) {
                guard depth < 32 else { return }
                for index in stride(from: array.count - 1, through: 0, by: -1) {
                    guard let item = array[index] else { continue }
                    if let id = item.objectID, removed.contains(id) { array.removeItem(at: index); continue }
                    if let kids = item["Kids"], kids.type == .array {
                        prune(kids, depth: depth + 1)
                        if kids.count == 0 { array.removeItem(at: index) }
                    }
                }
            }
            prune(fields, depth: 0)
        }
        guard !added.isEmpty else { return }
        let form = model.ensureAcroForm()
        if let importer, let outputForm = output?.acroForm {
            for key in ["DA", "DR"] where form[key] == nil { if let value = outputForm[key] { form.set(key, importer.value(value.reference ?? value.value)) } }
        }
        let fields = form.array("Fields")
        var listed = Set(fields.items.compactMap(\.objectID))
        for widget in added {
            var top = widget
            var depth = 0
            while let parent = top["Parent"], parent.type == .dictionary, depth < 32 { top = parent; depth += 1 }
            guard let id = top.objectID, listed.insert(id).inserted else { continue }
            fields.append(top)
        }
    }

    // MARK: Outline

    /// The file's bookmarks in tree order with their target page object.
    private func outlineObjects() -> [(title: String, page: Int?, object: PDFObject)] {
        var result: [(String, Int?, PDFObject)] = []
        var seen: Set<Int> = []
        func walk(_ parent: PDFObject?, depth: Int) {
            guard depth < 64 else { return }
            var node = parent?["First"]
            while let current = node {
                if let id = current.objectID { guard seen.insert(id).inserted else { return } }
                let destination = model.destination(from: current["Dest"]) ?? (current["A"]?["S"]?.name == "GoTo" ? model.destination(from: current["A"]?["D"]) : nil)
                let page = destination.flatMap { model.page(at: $0.page)?.object.objectID }
                result.append((current["Title"]?.text ?? "", page, current))
                walk(current, depth: depth + 1)
                node = current["Next"]
            }
        }
        walk(model.root["Outlines"], depth: 0)
        return result
    }

    /// Writes PDFKit's bookmarks; one that is still the file's (same title, same page) keeps its own destination
    /// (named destinations stay names), action, colour, style and structure element.
    private func writeOutline(_ nodes: [OutlineNode], matching old: [(title: String, page: Int?, object: PDFObject)], removedPages: Set<Int>) {
        func items(_ nodes: [OutlineNode]) -> [PDFOutlineItem] {
            nodes.map { node in
                let destination = node.page.map { PDFModelKit.PDFDestination(page: $0, view: node.point.map { .xyz(left: $0.x, top: $0.y, zoom: nil) } ?? .fit) }
                return PDFOutlineItem(title: node.title, destination: destination, uri: node.url, isOpen: node.isOpen, children: items(node.children))
            }
        }
        model.setOutlines(items(nodes))
        var unused = old
        var visited: Set<Int> = []
        func apply(_ nodes: [OutlineNode], parent: PDFObject?, depth: Int) {
            guard depth < 64 else { return }
            var current = parent?["First"]
            for node in nodes {
                guard let object = current else { return }
                if let id = object.objectID { guard visited.insert(id).inserted else { return } }
                let page = node.page.flatMap { model.page(at: $0)?.object.objectID }
                // A bookmark PDFKit shows without a page may be one whose page was removed: it gets its destination
                // back so the save can tell, and drops it.
                if let match = unused.firstIndex(where: { $0.title == node.title && $0.page == page })
                    ?? (page == nil ? unused.firstIndex(where: { $0.title == node.title && $0.page.map(removedPages.contains) == true }) : nil) {
                    let original = unused.remove(at: match).object
                    let keep = original.value.dictionaryValue ?? [:]
                    for (key, value) in keep where !["Title", "Parent", "Prev", "Next", "First", "Last", "Count"].contains(key) {
                        if key == "Dest" || key == "A" { object.remove("Dest"); object.remove("A") }
                        object.set(key, value)
                    }
                }
                apply(node.children, parent: object, depth: depth + 1)
                current = object["Next"]
            }
        }
        apply(nodes, parent: model.root["Outlines"], depth: 0)
    }

    // MARK: PDFKit alone

    /// PDFKit's serialisation of `pdf`, with what modules keep for annotations put back and the save stamps removed.
    static func pdfKitOnly(_ pdf: PDFDocument, password: String?, restorer: AnnotationRestorer?) -> Data? {
        guard let data = pdf.dataRepresentation() else { return nil }
        guard let model = (try? PDFModel(data: data)) ?? (try? PDFModel(data: data, password: password)) else { return data }
        var named: [String: AnyObject] = [:]
        var popups: [PDFObject] = []
        for page in model.pages {
            for annotation in page.annotations {
                annotation.remove(saveStampKey)
                if annotation["Subtype"]?.name == "Popup" { popups.append(annotation) }
                if let key = restorer?.idKey, let id = annotation[key]?.text, named[id] == nil { named[id] = annotation }
            }
        }
        if let restorer {
            // PDFKit gives each popup a copy of its note as /Parent; point it at the note itself.
            for popup in popups {
                if let id = popup["Parent"]?[restorer.idKey]?.text, let note = (named[id] as? PDFObject)?.reference { popup.set("Parent", note) }
            }
            try? restorer.restore(model, named, Set(named.keys))
            for case let object as PDFObject in named.values { object.remove(restorer.idKey) }
        }
        return (try? model.data()) ?? data
    }
}

/// Brings objects of PDFKit's output into the file's model. Objects mapped beforehand (pages, annotations) resolve to
/// the file's own; streams are copied whole; dictionaries and arrays are rebuilt so references inside them resolve the
/// same way. Pages and the catalog of the output never come over.
final class Importer {
    let target: PDFModel
    let source: PDFModel
    let dropping: Set<String>
    /// The result's annotation for each save stamp ("page/index").
    var places: [String: PDFValue] = [:]
    private var memo: [Int: PDFValue] = [:]

    init(target: PDFModel, source: PDFModel, dropping: Set<String>) {
        self.target = target
        self.source = source
        self.dropping = dropping
    }

    private static func key(_ id: Int, _ generation: Int) -> Int { id << 16 | generation }

    func map(_ object: PDFObject, to replacement: PDFObject) {
        guard let id = object.objectID, let reference = replacement.reference else { return }
        memo[Self.key(id, object.generation)] = reference
    }

    func value(_ value: PDFValue) -> PDFValue {
        switch value {
        case .reference(let id, let generation):
            let key = Self.key(id, generation)
            if let known = memo[key] { return known }
            let object = source.object(id: id, generation: generation)
            switch object.type {
            case .null:
                return .null
            case .stream:
                let copy = target.importObject(object)
                let reference = copy.reference ?? .null
                memo[key] = reference
                return reference
            case .dictionary:
                if ["Page", "Pages", "Catalog"].contains(object["Type"]?.name ?? "") { memo[key] = .null; return .null }
                if let place = object[saveStampKey]?.text, let annotation = places[place] { memo[key] = annotation; return annotation }
                let made = target.makeIndirect(.dictionary([:]))
                memo[key] = made.reference!
                for (name, item) in object.value.dictionaryValue ?? [:] where !dropping.contains(name) { made.set(name, self.value(item)) }
                return made.reference!
            case .array:
                let made = target.makeIndirect(.array([]))
                memo[key] = made.reference!
                for item in object.value.arrayValue ?? [] { made.append(self.value(item)) }
                return made.reference!
            default:
                let made = target.makeIndirect(object.value)
                memo[key] = made.reference!
                return made.reference!
            }
        case .array(let items):
            return .array(items.map { self.value($0) })
        case .dictionary(let dictionary):
            var result: [String: PDFValue] = [:]
            for (name, item) in dictionary where !dropping.contains(name) { result[name] = self.value(item) }
            return .dictionary(result)
        default:
            return value
        }
    }
}
