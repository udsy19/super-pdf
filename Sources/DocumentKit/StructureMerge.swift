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
/// changed through PDFKit, and a private copy of PDFKit's document for the parts PDFKit must write.
struct SaveJob: @unchecked Sendable {
    private let base: Data?
    private let password: String?
    private let plan: SavePlan?
    private let reason: String?
    /// PDFKit's copy, stamped when the plan needs its output. Nil when nothing changed.
    private let copy: PDFDocument?
    private let restorer: AnnotationRestorer?

    @MainActor
    init(_ document: DocumentHandle, baseline: DocumentBaseline?) {
        let restorer = Services.markup?.annotationRestorer(for: document)
        self.restorer = restorer
        password = document.password
        if let baseline {
            let (plan, reason) = baseline.plan(for: document.pdf, restorerKey: restorer?.idKey)
            base = baseline.bytes
            self.plan = plan
            self.reason = reason
        } else {
            base = nil
            plan = nil
            reason = "the document has no file bytes to keep"
        }
        if let plan, plan.isEmpty {
            copy = nil
        } else if plan?.needsOutput == true {
            copy = Self.stampedCopy(of: document.pdf)
        } else {
            copy = document.pdf.copy() as? PDFDocument
        }
    }

    /// A copy of `pdf` whose annotations carry their place ("page/index") under `saveStampKey`; `pdf` is left as it was.
    @MainActor
    private static func stampedCopy(of pdf: PDFDocument) -> PDFDocument? {
        let key = PDFAnnotationKey(rawValue: "/" + saveStampKey)
        var stamped: [PDFAnnotation] = []
        for index in 0..<pdf.pageCount {
            for (j, annotation) in (pdf.page(at: index)?.annotations ?? []).enumerated() {
                annotation.setValue("\(index)/\(j)", forAnnotationKey: key)
                stamped.append(annotation)
            }
        }
        let copy = pdf.copy() as? PDFDocument
        for annotation in stamped { annotation.removeValue(forAnnotationKey: key) }
        return copy
    }

    func run() -> SaveOutcome {
        var reason = reason
        if let base, let plan {
            if plan.isEmpty { return SaveOutcome(data: base, method: .unchanged, notes: []) }
            do {
                var output: Data?
                if plan.needsOutput {
                    guard let written = copy?.dataRepresentation() else { throw PDFModelError.failed("PDFKit wrote nothing") }
                    output = written
                }
                var merge = try StructureMerge(plan: plan, base: base, password: password, output: output, restorer: restorer)
                let (data, method) = try merge.run()
                for note in merge.notes { Log.documents.notice("Save: \(note, privacy: .public)") }
                return SaveOutcome(data: data, method: method, notes: merge.notes)
            } catch {
                reason = "the changes couldn't be written into the file: \(error)"
            }
        }
        let why = reason ?? "unknown"
        Log.documents.notice("Save: PDFKit writes the whole file because \(why, privacy: .public)")
        let data = copy.flatMap { StructureMerge.pdfKitOnly($0, password: password, restorer: restorer) } ?? base ?? Data()
        return SaveOutcome(data: data, method: .pdfKit, notes: [why])
    }
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

    /// The /Annots subtypes of every page ("" for entries that aren't annotations), to pair with PDFKit's.
    static func annotationSubtypes(of bytes: Data, password: String?) throws -> [[String]] {
        let model = try PDFModel(data: bytes, password: password)
        return model.pages.map { page in page.annotations.map { $0["Subtype"]?.name ?? "" } }
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
            for (index, page) in outputPages.enumerated() where index < finalPages.count { importer.map(page.object, to: finalPages[index]) }
        }

        // Every annotation's object in the result, mapped from PDFKit's output first so references between them resolve.
        var finalAnnotations: [[PDFObject]] = Array(repeating: [], count: plan.pages.count)
        var byPlace: [String: PDFObject] = [:]
        var fromPDFKit: [(object: PDFObject, source: PDFObject, merge: Bool, page: Int)] = []
        for (index, entry) in plan.pages.enumerated() {
            let fileAnnotations = entry.source.map { filePages[$0].annotations } ?? []
            let planned = entry.annotations ?? fileAnnotations.indices.map { PlannedAnnotation(kind: .keep($0), live: nil) }
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
                        fromPDFKit.append((fileAnnotations[file], source, true, index))
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
                    fromPDFKit.append((made, source, false, index))
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

        if let outline = plan.outline { writeOutline(outline, matching: oldOutline) }
        for (key, value) in plan.attributes { model.setInfo(key, value.isEmpty ? nil : value) }

        if let restorer {
            var named: [String: AnyObject] = [:]
            var written: Set<String> = []
            let fromPDFKitIDs = Set(fromPDFKit.compactMap(\.object.objectID))
            for (index, entry) in plan.pages.enumerated() {
                for (j, id) in entry.ids.enumerated() {
                    guard let id, let object = byPlace["\(index)/\(j)"] ?? keptObject(entry, live: j, filePages) else { continue }
                    named[id] = object
                    if let objectID = object.objectID, fromPDFKitIDs.contains(objectID) { written.insert(id) }
                }
            }
            try restorer.restore(model, named, written)
        }

        if plan.removesPages || !model.canSaveIncrementally {
            return (try model.data(), .rewritten)
        }
        return (try model.incrementalData(), .appended)
    }

    /// The file's object for PDFKit's `live`-th annotation on a page whose /Annots are kept as they are.
    private func keptObject(_ entry: PlannedPage, live: Int, _ filePages: [PDFModelKit.PDFPage]) -> PDFObject? {
        guard entry.annotations == nil, let source = entry.source, entry.liveFile.indices.contains(live), let file = entry.liveFile[live] else { return nil }
        let annotations = filePages[source].annotations
        return annotations.indices.contains(file) ? annotations[file] : nil
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
    private func writeOutline(_ nodes: [OutlineNode], matching old: [(title: String, page: Int?, object: PDFObject)]) {
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
                if let match = unused.firstIndex(where: { $0.title == node.title && $0.page == page }) {
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
