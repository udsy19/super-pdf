import Foundation
import PDFModelKit
import SuperPDFCore

// The PDF/A check (features #93, run after "For archiving" #56): the rules of ISO 19005 parts 1–3 that decide whether a
// file opens the same way in decades, checked over the object model (QPDF). Each finding names a stable rule, says in
// plain words what is wrong (ux §1.1) and lists the pages it concerns. It is not a full veraPDF: it covers what the
// writer controls and what makes real files fail.

enum PDFAVerifier {
    static func verify(_ source: PDFSource, level: PDFALevel) throws -> [PDFAProblem] {
        try verify(PDFModel(source, attemptRecovery: false), level: level)
    }

    static func verify(_ model: PDFModel, level: PDFALevel) -> [PDFAProblem] {
        let part = level.archivePart
        var problems: [PDFAProblem] = []
        func add(_ rule: String, _ message: String, pages: Set<Int> = []) {
            problems.append(PDFAProblem(rule: rule, message: message, pages: pages.sorted()))
        }

        if model.isEncrypted { add("encrypted", ArchiveCopy.encrypted) }

        // Identification and metadata (ISO 19005-1 §6.7, -2 §6.6).
        switch ArchiveXMP.identification(of: model) {
        case .missing:
            add("metadata", ArchiveCopy.metadata)
        case .found(let foundPart, let conformance, let filtered):
            if part == 1 && filtered { add("metadata", ArchiveCopy.metadata) }
            if foundPart != part || conformance?.uppercased() != level.archiveConformance {
                add("pdfa-identification", ArchiveCopy.identification(level))
            }
        }

        // The colour profile the file was made for (§6.2.2 / §6.2.3).
        let intents = model.root["OutputIntents"]?.items ?? []
        if !intents.contains(where: { $0["S"]?.name == "GTS_PDFA1" && $0["DestOutputProfile"]?.type == .stream }) {
            add("output-intent", ArchiveCopy.outputIntent)
        }

        if (model.trailer["ID"]?.count ?? 0) < 2 { add("file-id", ArchiveCopy.fileID) }

        // Fonts, transparency and Unicode, per page.
        var unembedded: Set<Int> = [], transparent: Set<Int> = [], unmapped: Set<Int> = []
        for (index, page) in model.pages.enumerated() {
            let scan = ArchivePageScan(page)
            if scan.fonts.contains(where: { !ArchivePageScan.isEmbedded($0) }) { unembedded.insert(index) }
            if part == 1 && scan.usesTransparency(includingGroups: true) { transparent.insert(index) }
            if level.archiveNeedsUnicode && scan.fonts.contains(where: { !ArchivePageScan.mapsToUnicode($0) }) { unmapped.insert(index) }
        }
        if !unembedded.isEmpty { add("fonts-not-embedded", ArchiveCopy.fontsNotEmbedded, pages: unembedded) }
        if !transparent.isEmpty { add("transparency", ArchiveCopy.transparency, pages: transparent) }
        if !unmapped.isEmpty { add("unicode", ArchiveCopy.unicode, pages: unmapped) }

        // Scripts and actions that do things (§6.6).
        let actions = ArchiveActions.scan(model)
        if actions.javascript { add("javascript", ArchiveCopy.javascript, pages: actions.javascriptPages) }
        if actions.forbidden { add("actions", ArchiveCopy.actions, pages: actions.forbiddenPages) }

        // LZW (part 1 only; §6.1.10).
        if part == 1 && ArchiveObjects.streams(of: model).contains(where: { $0.filters.contains("LZWDecode") }) {
            add("lzw", ArchiveCopy.lzw)
        }

        // Attachments (part 1: none; part 2: PDF/A files only; part 3: any, with a relationship).
        let files = model.embeddedFiles()
        switch part {
        case 1:
            if !files.isEmpty { add("attachments", ArchiveCopy.attachments(level)) }
        case 2:
            let foreign = files.contains { file in
                guard let data = try? model.embeddedFileData(named: file.name), let inner = try? PDFModel(data: data, attemptRecovery: false) else { return true }
                if case .found = ArchiveXMP.identification(of: inner) { return false }
                return true
            }
            if foreign { add("attachments", ArchiveCopy.attachmentsNotArchived) }
        default:
            if files.contains(where: { $0.relationship == nil }) { add("attachment-relationship", ArchiveCopy.attachmentRelationship) }
        }

        // Notes and other annotations (§6.5 / §6.3).
        var badType: Set<Int> = [], noLook: Set<Int> = [], noPrint: Set<Int> = [], hidden: Set<Int> = []
        let forbiddenTypes: Set<String> = part == 1 ? ArchiveObjects.forbiddenAnnotations.union(["FileAttachment"]) : ArchiveObjects.forbiddenAnnotations
        for (index, page) in model.pages.enumerated() {
            for annotation in page.annotations {
                let subtype = annotation["Subtype"]?.name ?? ""
                if forbiddenTypes.contains(subtype) { badType.insert(index) }
                guard subtype != "Popup" else { continue }
                let flags = annotation["F"]?.int ?? 0
                if flags & 4 == 0 { noPrint.insert(index) }
                if flags & (1 | 2 | 32) != 0 { hidden.insert(index) }
                let rect = annotation["Rect"]?.rect ?? .zero
                if subtype != "Link", rect.width > 0, rect.height > 0, annotation["AP"]?["N"] == nil { noLook.insert(index) }
            }
        }
        if !badType.isEmpty { add("annotation-type", ArchiveCopy.annotationType, pages: badType) }
        if !noLook.isEmpty { add("annotation-appearance", ArchiveCopy.annotationAppearance, pages: noLook) }
        if !noPrint.isEmpty { add("annotation-print", ArchiveCopy.annotationPrint, pages: noPrint) }
        if !hidden.isEmpty { add("annotation-hidden", ArchiveCopy.annotationHidden, pages: hidden) }

        // The accessible levels need tags whose marked content is really in the pages.
        if level.requiresTags {
            let marked = model.root["MarkInfo"]?["Marked"]?.bool == true
            let tree = model.root["StructTreeRoot"] != nil
            let contentTagged = model.pages.contains { page in
                (try? page.contentStream().markedContent.contains { $0.mcid != nil }) == true
            }
            if !(marked && tree && contentTagged) { add("tags", ArchiveCopy.tags(level)) }
        }
        return problems
    }
}

// MARK: - Levels

extension PDFALevel {
    /// 1, 2 or 3.
    var archivePart: Int { Int(String(rawValue.prefix(1))) ?? 2 }
    /// "B", "U" or "A", as `pdfaid:conformance` writes it.
    var archiveConformance: String { rawValue.suffix(1).uppercased() }
    /// The "u" and "a" levels need every character mapped to Unicode.
    var archiveNeedsUnicode: Bool { rawValue.hasSuffix("u") || rawValue.hasSuffix("a") }
}

// MARK: - Copy (ux §1.1)

enum ArchiveCopy {
    static let encrypted = "The file is locked with a password. Archive copies can’t be locked."
    static let metadata = "The file’s description (its XMP metadata) is missing or can’t be read."
    static func identification(_ level: PDFALevel) -> String { "The file doesn’t say it is \(level.title)." }
    static let outputIntent = "The file doesn’t say which colours it was made for."
    static let fileID = "The file has no identifier."
    static let fontsNotEmbedded = "Some fonts aren’t inside the file, so the text could look different on another computer."
    static let unicode = "Some text can’t be matched to letters, so it can’t be searched or read aloud."
    static let transparency = "Some pages use see-through effects, which PDF/A-1 doesn’t allow."
    static let lzw = "Some parts use an old kind of compression (LZW) that PDF/A-1 doesn’t allow."
    static let javascript = "The file has scripts, which archive copies can’t have."
    static let actions = "The file has actions that open apps, play media or reset forms, which archive copies can’t have."
    static func attachments(_ level: PDFALevel) -> String { "The file has attachments, which \(level.title) doesn’t allow." }
    static let attachmentsNotArchived = "Some attachments aren’t archive copies themselves, which PDF/A-2 doesn’t allow."
    static let attachmentRelationship = "Some attachments don’t say how they relate to the document."
    static let annotationType = "Some notes hold sound, video or 3D, which archive copies can’t have."
    static let annotationAppearance = "Some notes have no saved look, so they could look different elsewhere."
    static let annotationPrint = "Some notes are set not to print."
    static let annotationHidden = "Some notes are hidden."
    static func tags(_ level: PDFALevel) -> String { "The file isn’t tagged for screen readers, which \(level.title) needs." }
}

// MARK: - Page resources

/// What a page draws with: its fonts, graphics states, pictures and transparency groups, through form XObjects,
/// patterns, Type 3 glyphs and annotation appearances.
struct ArchivePageScan {
    var fonts: [PDFObject] = []
    var graphicsStates: [PDFObject] = []
    var images: [PDFObject] = []
    /// Page and form transparency groups.
    var groups: [PDFObject] = []

    init(_ page: PDFPage) {
        var visited: Set<Int> = []
        if let group = page.object["Group"] { groups.append(group) }
        walk(page.resources, visited: &visited, depth: 0)
        for annotation in page.annotations {
            for appearance in Self.appearanceStreams(annotation) { walkForm(appearance, visited: &visited, depth: 0) }
        }
    }

    private mutating func walk(_ resources: PDFObject?, visited: inout Set<Int>, depth: Int) {
        guard let resources, resources.type == .dictionary, depth < 24 else { return }
        if let id = resources.objectID { guard visited.insert(id).inserted else { return } }
        for key in resources["Font"]?.keys ?? [] {
            guard let font = resources["Font"]?[key], font.type == .dictionary else { continue }
            if let id = font.objectID, !visited.insert(id).inserted { continue }
            fonts.append(font)
            if font["Subtype"]?.name == "Type3" { walk(font["Resources"], visited: &visited, depth: depth + 1) }
        }
        for key in resources["ExtGState"]?.keys ?? [] {
            if let state = resources["ExtGState"]?[key], state.type == .dictionary { graphicsStates.append(state) }
        }
        for key in resources["XObject"]?.keys ?? [] {
            guard let object = resources["XObject"]?[key], object.type == .stream else { continue }
            switch object["Subtype"]?.name {
            case "Image": images.append(object)
            case "Form": walkForm(object, visited: &visited, depth: depth + 1)
            default: break
            }
        }
        for key in resources["Pattern"]?.keys ?? [] {
            guard let pattern = resources["Pattern"]?[key] else { continue }
            walk(pattern["Resources"], visited: &visited, depth: depth + 1)
        }
    }

    private mutating func walkForm(_ form: PDFObject, visited: inout Set<Int>, depth: Int) {
        if let id = form.objectID { guard visited.insert(id).inserted else { return } }
        if let group = form["Group"] { groups.append(group) }
        walk(form["Resources"], visited: &visited, depth: depth + 1)
    }

    /// The normal, rollover and down appearances of an annotation (each a stream, or a dictionary of states).
    static func appearanceStreams(_ annotation: PDFObject) -> [PDFObject] {
        guard let ap = annotation["AP"] else { return [] }
        return ["N", "R", "D"].flatMap { key -> [PDFObject] in
            guard let entry = ap[key] else { return [] }
            if entry.type == .stream { return [entry] }
            return entry.keys.compactMap { entry[$0] }.filter { $0.type == .stream }
        }
    }

    /// Whether anything on the page is see-through: soft masks, constant alpha below 1, blend modes, transparency
    /// groups (only counted with `includingGroups`, since a group alone changes nothing that is drawn opaque).
    func usesTransparency(includingGroups: Bool) -> Bool {
        if includingGroups, groups.contains(where: { $0["S"]?.name == "Transparency" }) { return true }
        for state in graphicsStates {
            if let mask = state["SMask"], mask.name != "None" { return true }
            if let ca = state["ca"]?.number, ca < 1 { return true }
            if let ca = state["CA"]?.number, ca < 1 { return true }
            if let mode = state["BM"]?.name ?? state["BM"]?[0]?.name, mode != "Normal", mode != "Compatible" { return true }
        }
        return images.contains { $0["SMask"] != nil || ($0["SMaskInData"]?.int ?? 0) > 0 }
    }

    /// The font program is in the file (Type 3 fonts are drawings and need none).
    static func isEmbedded(_ font: PDFObject) -> Bool {
        switch font["Subtype"]?.name {
        case "Type3":
            return true
        case "Type0":
            guard let descendant = font["DescendantFonts"]?[0] else { return false }
            return hasFontFile(descendant["FontDescriptor"])
        default:
            return hasFontFile(font["FontDescriptor"])
        }
    }

    private static func hasFontFile(_ descriptor: PDFObject?) -> Bool {
        guard let descriptor else { return false }
        return ["FontFile", "FontFile2", "FontFile3"].contains { descriptor[$0]?.type == .stream }
    }

    /// Text in this font can be turned into Unicode: a /ToUnicode map, or a simple font in a standard encoding.
    static func mapsToUnicode(_ font: PDFObject) -> Bool {
        if font["ToUnicode"]?.type == .stream { return true }
        let subtype = font["Subtype"]?.name
        guard subtype != "Type0", subtype != "Type3" else { return false }
        let standard: Set<String> = ["WinAnsiEncoding", "MacRomanEncoding", "StandardEncoding"]
        if let name = font["Encoding"]?.name { return standard.contains(name) }
        if let base = font["Encoding"]?["BaseEncoding"]?.name { return standard.contains(base) }
        return false
    }
}

// MARK: - Actions and objects

/// Scripts and actions anywhere they can hide: the catalog, pages, annotations, form fields and bookmarks.
struct ArchiveActions {
    var javascript = false
    var forbidden = false
    var javascriptPages: Set<Int> = []
    var forbiddenPages: Set<Int> = []

    /// Actions ISO 19005 doesn't allow (part 1 §6.6.1, part 2 §6.5.1).
    static let forbiddenTypes: Set<String> = ["Launch", "Sound", "Movie", "ResetForm", "ImportData", "Hide", "SetOCGState", "Rendition",
                                              "Trans", "GoTo3DView", "RichMediaExecute"]

    static func scan(_ model: PDFModel) -> ArchiveActions {
        var result = ArchiveActions()
        if model.root["Names"]?["JavaScript"] != nil { result.javascript = true }
        result.check(model.root["OpenAction"], page: nil)
        if model.root["AA"] != nil { result.forbidden = true }
        for (index, page) in model.pages.enumerated() {
            if page.object["AA"] != nil { result.forbidden = true; result.forbiddenPages.insert(index) }
            for annotation in page.annotations {
                result.check(annotation["A"], page: index)
                if annotation["AA"] != nil { result.forbidden = true; result.forbiddenPages.insert(index) }
            }
        }
        for field in model.formFields() where field.object["AA"] != nil {
            result.forbidden = true
            result.forbiddenPages.formUnion(field.widgets.compactMap(\.page))
        }
        // Bookmarks.
        var item = model.root["Outlines"]?["First"]
        var stack: [PDFObject] = []
        var seen: Set<Int> = []
        while let current = item ?? stack.popLast() {
            item = nil
            if let id = current.objectID, !seen.insert(id).inserted { continue }
            result.check(current["A"], page: nil)
            if let next = current["Next"] { stack.append(next) }
            if let first = current["First"] { item = first }
            if seen.count > 100_000 { break }
        }
        return result
    }

    /// An action and the actions chained after it with /Next.
    private mutating func check(_ action: PDFObject?, page: Int?, depth: Int = 0) {
        guard let action, action.type == .dictionary, depth < 32 else { return }
        if let type = action["S"]?.name {
            if type == "JavaScript" {
                javascript = true
                if let page { javascriptPages.insert(page) }
            } else if Self.forbiddenTypes.contains(type) {
                forbidden = true
                if let page { forbiddenPages.insert(page) }
            }
        }
        if let next = action["Next"] {
            if next.type == .array { for item in next.items { check(item, page: page, depth: depth + 1) } } else { check(next, page: page, depth: depth + 1) }
        }
    }
}

enum ArchiveObjects {
    /// Annotation kinds no PDF/A part allows.
    static let forbiddenAnnotations: Set<String> = ["Sound", "Movie", "Screen", "3D", "RichMedia", "TrapNet"]

    /// Every stream in the file (objects 1 up to the trailer's /Size).
    static func streams(of model: PDFModel) -> [PDFObject] {
        let size = model.trailer["Size"]?.int ?? 0
        return (1..<max(size, 1)).compactMap { id in
            let object = model.object(id: id)
            return object.type == .stream ? object : nil
        }
    }
}

// MARK: - XMP

enum ArchiveXMP {
    enum Identification {
        case missing
        /// `filtered`: the metadata stream is compressed (part 1 wants it plain).
        case found(part: Int?, conformance: String?, filtered: Bool)
    }

    /// The `pdfaid` entries of the catalog's metadata, as elements or as attributes.
    static func identification(of model: PDFModel) -> Identification {
        guard let stream = model.root["Metadata"], stream.type == .stream, let data = try? stream.streamData(decode: .all),
              let xml = try? XML.parse(data) else { return .missing }
        let part = value(xml, "pdfaid:part").flatMap { Int($0) }
        let conformance = value(xml, "pdfaid:conformance")
        guard part != nil || conformance != nil else { return .missing }
        return .found(part: part, conformance: conformance, filtered: !stream.filters.isEmpty)
    }

    /// An XMP property by qualified name, written as an element or as an attribute of an rdf:Description.
    static func value(_ root: XMLNode, _ qualifiedName: String) -> String? {
        let local = String(qualifiedName.split(separator: ":").last ?? "")
        if let element = root.all(local).first(where: { $0.qualifiedName == qualifiedName }) {
            return element.allText.trimmingCharacters(in: .whitespacesAndNewlines)
        }
        for description in root.all("Description") {
            if let value = description.attributes[qualifiedName] { return value.trimmingCharacters(in: .whitespacesAndNewlines) }
        }
        return nil
    }

    /// An XMP packet for the archive and print standards: identification properties, Dublin Core title, creator and
    /// description, XMP dates and creator tool, and the PDF producer and keywords, matching /Info.
    static func packet(identification: [(String, String)], namespaces: [String: String], title: String?, author: String?, subject: String?,
                       keywords: String?, creatorTool: String?, producer: String, created: Date, modified: Date, extra: [(String, String)] = []) -> Data {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        formatter.timeZone = .current
        func element(_ name: String, _ value: String) -> String { "   <\(name)>\(XML.escape(value))</\(name)>\n" }
        var body = ""
        for (name, value) in identification + extra { body += element(name, value) }
        if let title, !title.isEmpty {
            body += "   <dc:title><rdf:Alt><rdf:li xml:lang=\"x-default\">\(XML.escape(title))</rdf:li></rdf:Alt></dc:title>\n"
        }
        if let author, !author.isEmpty { body += "   <dc:creator><rdf:Seq><rdf:li>\(XML.escape(author))</rdf:li></rdf:Seq></dc:creator>\n" }
        if let subject, !subject.isEmpty {
            body += "   <dc:description><rdf:Alt><rdf:li xml:lang=\"x-default\">\(XML.escape(subject))</rdf:li></rdf:Alt></dc:description>\n"
        }
        body += element("xmp:CreateDate", formatter.string(from: created))
        body += element("xmp:ModifyDate", formatter.string(from: modified))
        body += element("xmp:MetadataDate", formatter.string(from: modified))
        if let creatorTool, !creatorTool.isEmpty { body += element("xmp:CreatorTool", creatorTool) }
        body += element("pdf:Producer", producer)
        if let keywords, !keywords.isEmpty { body += element("pdf:Keywords", keywords) }
        var allNamespaces = ["dc": "http://purl.org/dc/elements/1.1/", "xmp": "http://ns.adobe.com/xap/1.0/", "pdf": "http://ns.adobe.com/pdf/1.3/"]
        allNamespaces.merge(namespaces) { $1 }
        let declarations = allNamespaces.sorted { $0.key < $1.key }.map { "xmlns:\($0.key)=\"\($0.value)\"" }.joined(separator: "\n    ")
        let xml = """
        <?xpacket begin="\u{FEFF}" id="W5M0MpCehiHzreSzNTczkc9d"?>
        <x:xmpmeta xmlns:x="adobe:ns:meta/">
         <rdf:RDF xmlns:rdf="http://www.w3.org/1999/02/22-rdf-syntax-ns#">
          <rdf:Description rdf:about=""
            \(declarations)>
        \(body)  </rdf:Description>
         </rdf:RDF>
        </x:xmpmeta>
        <?xpacket end="w"?>
        """
        return Data(xml.utf8)
    }
}
