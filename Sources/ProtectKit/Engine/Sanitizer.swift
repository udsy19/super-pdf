import CoreGraphics
import Foundation
import PDFModelKit
import SuperPDFCore

// Remove hidden information (features #88): finds and removes metadata, comments, form data, hidden text, hidden
// layers, attachments, bookmarks, links, scripts, unreferenced objects, thumbnails and objects hidden under opaque
// pictures, by walking the objects with QPDF. The file is always rewritten whole, which also drops earlier revisions.

enum Sanitizer {
    /// What "Remove hidden info" ticks by default (ux §5.3: everything but bookmarks and links), and what Black out's
    /// "Also remove hidden information" removes.
    static let defaultKinds: Set<HiddenInfoKind> = Set(HiddenInfoKind.allCases).subtracting([.bookmarks, .links])

    // MARK: - Inventory

    static func inventory(of source: PDFSource) throws -> HiddenInfoInventory {
        let model = try PDFModel(source)
        var counts: [HiddenInfoKind: Int] = [:]
        counts[.metadata] = metadataCount(model)
        var comments = 0, links = 0, fileAnnotations = 0, thumbnails = 0
        for page in model.pages {
            if page.object["Thumb"] != nil { thumbnails += 1 }
            for annot in page.annotations {
                switch annot["Subtype"]?.name {
                case "Link": links += 1
                case "Widget", "Popup": break
                case "FileAttachment": fileAnnotations += 1; comments += 1
                default: comments += 1
                }
            }
        }
        counts[.comments] = comments
        counts[.links] = links
        counts[.thumbnails] = thumbnails
        counts[.formData] = model.acroForm == nil ? 0 : model.formFields().count
        counts[.attachments] = model.embeddedFiles().count + fileAnnotations
        counts[.bookmarks] = outlineCount(model.outlines())
        counts[.hiddenLayers] = offGroups(model).count
        counts[.scripts] = removeScripts(from: model, dryRun: true)
        counts[.unreferencedObjects] = unreferencedCount(model)
        // Content passes last: they change the (throwaway) model.
        var hiddenTextPages = 0, overlapping = 0
        for page in model.pages {
            if try removeHiddenText(on: page, in: model) > 0 { hiddenTextPages += 1 }
            overlapping += try removeCoveredObjects(on: page, in: model)
        }
        counts[.hiddenText] = hiddenTextPages
        counts[.overlappingObjects] = overlapping
        return HiddenInfoInventory(counts: counts.filter { $0.value > 0 })
    }

    // MARK: - Removal

    static func remove(_ kinds: Set<HiddenInfoKind>, from source: PDFSource) throws -> Data {
        let model = try PDFModel(source)
        try ProtectionRules.requireChanges(model)
        try remove(kinds, from: model)
        return try model.data(options: PDFWriteOptions(encryption: .preserve))
    }

    static func remove(_ kinds: Set<HiddenInfoKind>, from model: PDFModel) throws {
        if kinds.contains(.hiddenLayers) { removeHiddenLayers(from: model) }
        for page in model.pages {
            if kinds.contains(.hiddenText) { try removeHiddenText(on: page, in: model) }
            if kinds.contains(.overlappingObjects) { try removeCoveredObjects(on: page, in: model) }
        }
        if kinds.contains(.formData), model.acroForm != nil {
            try Flattener.flatten(model, annotations: false, formFields: true)
        }
        let annotationKinds: Set<String> = {
            var subtypes: Set<String> = []
            if kinds.contains(.links) { subtypes.insert("Link") }
            if kinds.contains(.attachments) { subtypes.insert("FileAttachment") }
            return subtypes
        }()
        for page in model.pages {
            if kinds.contains(.thumbnails) { page.object.remove("Thumb") }
            guard let annots = page.object["Annots"] else { continue }
            for i in (0..<annots.count).reversed() {
                let subtype = annots[i]?["Subtype"]?.name ?? ""
                let isComment = !["Link", "Widget"].contains(subtype)
                if annotationKinds.contains(subtype) || (kinds.contains(.comments) && isComment) { annots.removeItem(at: i) }
            }
            if annots.count == 0 { page.object.remove("Annots") }
        }
        if kinds.contains(.attachments) {
            for file in model.embeddedFiles() { model.removeEmbeddedFile(named: file.name) }
            model.root.remove("AF")
        }
        if kinds.contains(.bookmarks) {
            model.root.remove("Outlines")
            if model.root["PageMode"]?.name == "UseOutlines" { model.root.set("PageMode", .name("UseNone")) }
        }
        if kinds.contains(.scripts) { removeScripts(from: model, dryRun: false) }
        if kinds.contains(.metadata) { removeMetadata(from: model) }
        // Unreferenced objects and earlier revisions go with the full rewrite (QPDF keeps only what is reachable).
    }

    // MARK: - Metadata

    private static func metadataCount(_ model: PDFModel) -> Int {
        var count = model.trailer["Info"]?.keys.count ?? 0
        for object in ObjectWalk.objects(of: model) where object.has("Metadata") || object.has("PieceInfo") { count += 1 }
        return count
    }

    private static func removeMetadata(from model: PDFModel) {
        model.trailer.remove("Info")
        for object in ObjectWalk.objects(of: model) {
            if object.has("Metadata") { object.remove("Metadata") }
            if object.has("PieceInfo") { object.remove("PieceInfo") }
        }
    }

    // MARK: - Scripts

    /// Removes (or, dry, counts) document JavaScript, open actions that run scripts or launch apps, additional actions
    /// on the document, pages, fields and annotations, and script actions of links and buttons (features #74, #88).
    @discardableResult
    private static func removeScripts(from model: PDFModel, dryRun: Bool) -> Int {
        var count = 0
        if let tree = model.root["Names"]?["JavaScript"] {
            count += max(PDFNameTree.entries(of: tree).count, 1)
            if !dryRun { model.root["Names"]?.remove("JavaScript") }
        }
        let scripted: Set<String> = ["JavaScript", "Launch", "ImportData", "Rendition"]
        for object in ObjectWalk.objects(of: model) where object.type == .dictionary {
            if object.has("AA") { count += 1; if !dryRun { object.remove("AA") } }
            for key in ["A", "OpenAction"] {
                guard let action = object[key], action.type == .dictionary, let kind = action["S"]?.name, scripted.contains(kind) else { continue }
                count += 1
                if !dryRun { object.remove(key) }
            }
        }
        return count
    }

    // MARK: - Hidden text and covered objects

    /// Text drawn invisibly (render mode 3, OCR layers) leaves the page.
    @discardableResult
    private static func removeHiddenText(on page: PDFPage, in model: PDFModel) throws -> Int {
        let rewriter = ContentRewriter(model: model, rules: ContentRules(areas: { _ in [] }, cutsPartially: false, removesInvisibleText: true))
        try rewriter.rewrite(page: page)
        return rewriter.stats.invisibleGlyphs
    }

    /// Text, paths and pictures wholly under an opaque picture drawn after them leave the page.
    @discardableResult
    private static func removeCoveredObjects(on page: PDFPage, in model: PDFModel) throws -> Int {
        var pictures: [(index: Int, box: CGRect)] = []
        let survey = ContentRewriter(model: model, rules: ContentRules(areas: { _ in [] }, cutsPartially: false, onPicture: { index, box, opaque in
            if opaque { pictures.append((index, box)) }
        }))
        try survey.rewrite(page: page)
        guard !pictures.isEmpty else { return 0 }
        let rewriter = ContentRewriter(model: model, rules: ContentRules(areas: { index in
            pictures.filter { $0.index > index }.map(\.box)
        }, cutsPartially: false))
        try rewriter.rewrite(page: page)
        return rewriter.stats.total
    }

    // MARK: - Hidden layers

    /// Optional content groups that are off in the default configuration.
    private static func offGroups(_ model: PDFModel) -> Set<Int> {
        guard let properties = model.root["OCProperties"], let config = properties["D"] else { return [] }
        let all = Set((properties["OCGs"]?.items ?? []).compactMap(\.objectID))
        let on = Set((config["ON"]?.items ?? []).compactMap(\.objectID))
        let off = Set((config["OFF"]?.items ?? []).compactMap(\.objectID))
        return config["BaseState"]?.name == "OFF" ? all.subtracting(on) : off
    }

    /// Whether an /OC value (a group or a membership dictionary) is hidden in the default configuration.
    private static func isHidden(_ oc: PDFObject?, off: Set<Int>) -> Bool {
        guard let oc else { return false }
        if oc["Type"]?.name == "OCMD" {
            let groups: [Int] = {
                guard let value = oc["OCGs"] else { return [] }
                return value.type == .array ? value.items.compactMap(\.objectID) : [value.objectID].compactMap { $0 }
            }()
            guard !groups.isEmpty else { return false }
            let hidden = groups.map(off.contains)
            switch oc["P"]?.name ?? "AnyOn" {
            case "AllOn": return hidden.contains(true)
            case "AnyOff": return !hidden.contains(true)
            case "AllOff": return hidden.contains(false)
            default: return !hidden.contains(false)
            }
        }
        return oc.objectID.map(off.contains) ?? false
    }

    /// Content of hidden layers leaves the pages (marked `/OC` spans, XObjects and annotations with a hidden /OC);
    /// what was visible stays, without the layer machinery.
    private static func removeHiddenLayers(from model: PDFModel) {
        let off = offGroups(model)
        defer { model.root.remove("OCProperties") }
        guard !off.isEmpty else { return }
        for page in model.pages {
            let properties = page.resources?["Properties"]
            let xobjects = page.resources?["XObject"]
            if var content = try? page.contentStream() {
                var changed = content.removeMarkedContent { span in
                    guard span.tag == "OC" else { return false }
                    if let name = span.properties?.nameValue { return isHidden(properties?[name], off: off) }
                    return false
                } > 0
                let before = content.operations.count
                content.operations.removeAll { op in
                    guard op.operator == "Do", let name = op.operands.first?.nameValue else { return false }
                    return isHidden(xobjects?[name]?["OC"], off: off)
                }
                changed = changed || content.operations.count != before
                if changed { page.setContentStream(content) }
            }
            if let annots = page.object["Annots"] {
                for i in (0..<annots.count).reversed() where isHidden(annots[i]?["OC"], off: off) { annots.removeItem(at: i) }
            }
        }
    }

    // MARK: - Counting

    private static func outlineCount(_ items: [PDFOutlineItem]) -> Int {
        items.reduce(0) { $0 + 1 + outlineCount($1.children) }
    }

    private static func unreferencedCount(_ model: PDFModel) -> Int {
        let reachable = ObjectWalk.reachable(in: model)
        return ObjectWalk.objects(of: model).filter { $0.objectID.map { !reachable.contains($0) } ?? false }.count
    }
}
