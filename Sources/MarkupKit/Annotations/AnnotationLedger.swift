import Foundation
import PDFKit
import PDFModelKit
import SuperPDFCore

// What PDFKit loses (measured: a PDFKit read and write of a QPDF-made file): /NM names, /IRT reply and review-status
// links, a paper clip's file (/FS → /EF) and its /Name icon, a voice note's /Sound. PDFKit keeps unknown keys with
// direct values, so each annotation carries MarkupKit's id (`/SuperPDFID`) while the document is open, and this ledger
// keeps the rest by id. Saves keep the file's own annotation objects (DocumentKit writes PDFKit's changes into them), so
// the restorer only puts the data back into the annotations whose dictionaries a save took from PDFKit (new or changed
// ones), writes the id as /NM and drops the private key, so saved files are plain standard PDF.

/// A file clipped to a page (features #79).
struct AttachedFile: Hashable, Sendable {
    var fileName: String
    var data: Data
    var mimeType: String?
    var modified: Date?
}

/// A voice note's samples, as PDF sound objects store them (big-endian, uncompressed).
struct SoundClip: Hashable, Sendable {
    var samples: Data
    var rate: Double
    var channels: Int
    var bits: Int
    /// /Raw (unsigned), /Signed, /muLaw or /ALaw.
    var encoding: String
}

/// What MarkupKit knows about one annotation beyond what PDFKit holds.
struct LedgerRecord: Hashable, Sendable {
    /// The annotation this one replies to or sets the review status of (/IRT).
    var parent: String?
    /// /RT: "R" (a reply) or "Group".
    var replyType: String?
    /// The /F flags to write back: replies show as Acrobat writes them although Super PDF hides their icons.
    var flags: Int?
    /// /Name of paper clips and voice notes ("Paperclip", "Speaker").
    var icon: String?
    var file: AttachedFile?
    var sound: SoundClip?

    var isEmpty: Bool { parent == nil && replyType == nil && flags == nil && icon == nil && file == nil && sound == nil }
}

@MainActor
final class AnnotationLedger {
    private(set) var records: [String: LedgerRecord] = [:]

    subscript(id: String) -> LedgerRecord {
        get { records[id] ?? LedgerRecord() }
        set { records[id] = newValue.isEmpty ? nil : newValue }
    }

    func remove(_ id: String) { records[id] = nil }

    /// Ids of the annotations that reply to or set the status of `id`.
    func children(of id: String) -> [String] { records.filter { $0.value.parent == id }.map(\.key) }

    // MARK: Identity

    /// The annotation's id: its private key, else its /NM, else the one it was given, else a new one; stamped on it so
    /// it survives PDFKit writes.
    @discardableResult
    static func id(of annotation: PDFAnnotation) -> String {
        if let id = annotation.value(forAnnotationKey: .superPDFID) as? String, !id.isEmpty { return id }
        let id = existingID(of: annotation) ?? UUID().uuidString.lowercased()
        annotation.setValue(id, forAnnotationKey: .superPDFID)
        annotation.setValue(id, forAnnotationKey: .name)
        return id
    }

    /// The annotation's id without changing it: the same as `id(of:)`, but an annotation without one is given its id
    /// here instead of carrying it. Changing an annotation is a change DocumentKit compares at the next save, so reading
    /// and listing use this; markup about to change uses `id(of:)`.
    @discardableResult
    static func key(of annotation: PDFAnnotation) -> String {
        if let id = existingID(of: annotation) { return id }
        let id = UUID().uuidString.lowercased()
        given.setObject(id as NSString, forKey: annotation)
        return id
    }

    /// The id the annotation already answers to (its private key, else its /NM, else the one it was given); nil when it
    /// has none yet.
    static func existingID(of annotation: PDFAnnotation) -> String? {
        if let id = annotation.value(forAnnotationKey: .superPDFID) as? String, !id.isEmpty { return id }
        if let name = annotation.value(forAnnotationKey: .name) as? String, !name.isEmpty { return name }
        return given.object(forKey: annotation) as String?
    }

    /// Ids given to annotations that don't carry one, by annotation object.
    private static let given = NSMapTable<PDFAnnotation, NSString>(keyOptions: [.weakMemory, .objectPointerPersonality], valueOptions: .strongMemory)

    static func isMarkup(_ annotation: PDFAnnotation) -> Bool {
        !["Popup", "Link", "Widget"].contains(annotation.type ?? "")
    }

    // MARK: Reading what PDFKit dropped

    /// Pages whose file annotations were read into the ledger, and pages whose markup all carries ids.
    private let readPages = NSHashTable<PDFKit.PDFPage>.weakObjects()
    private let preparedPages = NSHashTable<PDFKit.PDFPage>.weakObjects()
    /// File annotations without /NM by their dictionary, for replies to them; the documents those dictionaries belong
    /// to are kept so the addresses stay theirs.
    private var unnamed: [UnsafeRawPointer: PDFAnnotation] = [:]
    private var waiting: [UnsafeRawPointer: [(child: String, type: String)]] = [:]
    private var sources: [ObjectIdentifier: CGPDFDocument] = [:]

    /// Reads `page`'s annotations from the page's own file objects (once) and pairs them with PDFKit's: names, reply
    /// links, clipped files and sounds come into the ledger, replies stop drawing as extra note icons. Only replies and
    /// what they reply to are stamped with their ids (hiding a reply changes it), so reading a page doesn't count as
    /// changing it (DocumentKit compares only pages something may have changed).
    func read(_ page: PDFKit.PDFPage) {
        guard !readPages.contains(page) else { return }
        readPages.add(page)
        var unmatched = page.annotations.filter(Self.isMarkup)
        guard !unmatched.isEmpty else { return }
        if let cgPage = page.pageRef, let document = cgPage.document { sources[ObjectIdentifier(document)] = document }
        for object in FileDictionary.annotations(of: page.pageRef) {
            guard let subtype = object.name("Subtype"), !["Popup", "Link", "Widget"].contains(subtype),
                  let match = Self.match(object, subtype: subtype, in: unmatched) else { continue }
            unmatched.removeAll { $0 === match }
            var id = Self.key(of: match)
            let named = object.text("NM").map { !$0.isEmpty } ?? false
            if !named { unnamed[object.address] = match }
            if let links = waiting.removeValue(forKey: object.address) {
                id = Self.id(of: match)
                for link in links { setParent(id, of: link.child, type: link.type) }
            }
            var record = self[id]
            if let parent = object.dictionary("IRT") {
                let type = object.name("RT") ?? "R"
                let parentID = parent.text("NM").flatMap { $0.isEmpty ? nil : $0 } ?? unnamed[parent.address].map(Self.id(of:))
                if let parentID {
                    record.parent = parentID
                    record.replyType = type
                } else {
                    waiting[parent.address, default: []].append((id, type))
                }
                record.flags = object.int("F") ?? 4
                // Hidden here, so a save writes it from PDFKit: it carries its id for the link to be put back.
                Self.id(of: match)
                if match.shouldDisplay { match.shouldDisplay = false }
            }
            if subtype == "FileAttachment" || subtype == "Sound" { record.icon = object.name("Name") }
            if subtype == "FileAttachment", let spec = object.dictionary("FS"),
               let stream = spec.dictionary("EF")?.stream("UF") ?? spec.dictionary("EF")?.stream("F") {
                record.file = AttachedFile(fileName: spec.text("UF") ?? spec.text("F") ?? "Attachment", data: stream.data,
                                           mimeType: stream.dictionary.name("Subtype"),
                                           modified: stream.dictionary.dictionary("Params")?.text("ModDate").flatMap(PDFDate.date))
            }
            if subtype == "Sound", let stream = object.stream("Sound") {
                let info = stream.dictionary
                record.sound = SoundClip(samples: stream.data, rate: info.number("R") ?? 8000, channels: info.int("C") ?? 1,
                                         bits: info.int("B") ?? 8, encoding: info.name("E") ?? "Raw")
            }
            self[id] = record
        }
    }

    /// `read`, and every markup annotation on `page` stamped with its id: what a page needs before markup on it changes
    /// (a save puts names, links and payloads back only into annotations that carry their id).
    func prepare(_ page: PDFKit.PDFPage) {
        read(page)
        guard !preparedPages.contains(page) else { return }
        preparedPages.add(page)
        for annotation in page.annotations where AnnotationLedger.isMarkup(annotation) { Self.id(of: annotation) }
    }

    /// Reads every page not read yet.
    func readAll(_ document: DocumentHandle) {
        for index in 0..<document.pageCount { if let page = document.pdf.page(at: index) { read(page) } }
    }

    /// Whether every page of `document` was read.
    func hasRead(_ document: DocumentHandle) -> Bool {
        readPages.count >= document.pageCount && (0..<document.pageCount).allSatisfy { document.pdf.page(at: $0).map(readPages.contains) ?? true }
    }

    func hasRead(_ page: PDFKit.PDFPage) -> Bool { readPages.contains(page) }

    private func setParent(_ parent: String, of child: String, type: String) {
        var record = self[child]
        record.parent = parent
        record.replyType = type
        self[child] = record
    }

    /// PDFKit's annotation for a file object: the same type, the same /NM, else the nearest top-left corner (PDFKit
    /// moves note icons to its own size), else the next one of that type.
    private static func match(_ object: FileDictionary, subtype: String, in candidates: [PDFAnnotation]) -> PDFAnnotation? {
        let sameType = candidates.filter { $0.type == subtype }
        if let name = object.text("NM"), let named = sameType.first(where: { ($0.value(forAnnotationKey: .name) as? String) == name }) {
            return named
        }
        guard let rect = object.rect("Rect")?.standardized else { return sameType.first }
        let scored = sameType.map { ($0, abs($0.bounds.minX - rect.minX) + abs($0.bounds.maxY - rect.maxY)) }
        if let best = scored.min(by: { $0.1 < $1.1 }), best.1 < 8 { return best.0 }
        return sameType.first
    }

    // MARK: Putting it back

    /// What DocumentKit runs on the document it writes. It acts only on annotations carrying an id, so it isn't worth
    /// looking for them first (that would read every page of a long file at every save).
    var restorer: AnnotationRestorer {
        let records = records
        return AnnotationRestorer(idKey: "SuperPDFID") { model, annotations, written in
            guard let model = model as? PDFModel else { return }
            Self.restore(in: model, annotations: annotations.compactMapValues { $0 as? PDFObject }, written: written, records: records)
        }
    }

    /// Writes each written annotation's id as /NM and puts back its reply link, flags, icon, file and sound. Links point
    /// at the annotations' objects in `model`, whether a save wrote them or kept them from the file.
    nonisolated static func restore(in model: PDFModel, annotations: [String: PDFObject], written: Set<String>, records: [String: LedgerRecord]) {
        // Parents on pages a save kept but nobody stamped answer to their /NM.
        var byName: [String: PDFObject]?
        func target(_ id: String) -> PDFObject? {
            if let annotation = annotations[id] { return annotation }
            if byName == nil {
                var names: [String: PDFObject] = [:]
                for index in 0..<model.pageCount {
                    for annotation in model.page(at: index)?.annotations ?? [] {
                        if let name = annotation["NM"]?.text, names[name] == nil { names[name] = annotation }
                    }
                }
                byName = names
            }
            return byName?[id]
        }
        for id in written {
            guard let annotation = annotations[id] else { continue }
            annotation.remove("SuperPDFID")
            if annotation["NM"] == nil { annotation.set("NM", .text(id)) }
            guard let record = records[id] else { continue }
            if let parent = record.parent, let target = target(parent)?.reference {
                annotation.set("IRT", target)
                annotation.set("RT", .name(record.replyType ?? "R"))
            }
            if let flags = record.flags { annotation.set("F", .integer(flags)) }
            if let icon = record.icon { annotation.set("Name", .name(icon)) }
            // A changed annotation keeps the file's own file and sound objects.
            if let file = record.file, annotation["FS"] == nil { annotation.set("FS", fileSpecification(file, in: model)) }
            if let sound = record.sound, annotation["Sound"] == nil { annotation.set("Sound", soundStream(sound, in: model)) }
        }
    }

    private nonisolated static func fileSpecification(_ file: AttachedFile, in model: PDFModel) -> PDFObject {
        var params: [String: PDFValue] = ["Size": .integer(file.data.count)]
        if let modified = file.modified { params["ModDate"] = .ascii(PDFDate.string(modified)) }
        var streamDictionary: [String: PDFValue] = ["Type": .name("EmbeddedFile"), "Params": .dictionary(params)]
        if let mime = file.mimeType { streamDictionary["Subtype"] = .name(mime) }
        let stream = model.makeStream(streamDictionary, data: file.data)
        let spec = model.makeIndirect(.dictionary(["Type": .name("Filespec"), "F": .text(file.fileName), "UF": .text(file.fileName)]))
        if let reference = stream.reference { spec.set("EF", .dictionary(["F": reference, "UF": reference])) }
        return spec
    }

    private nonisolated static func soundStream(_ sound: SoundClip, in model: PDFModel) -> PDFObject {
        model.makeStream(["Type": .name("Sound"), "R": .real(sound.rate), "C": .integer(sound.channels), "B": .integer(sound.bits),
                          "E": .name(sound.encoding)], data: sound.samples)
    }
}

/// A dictionary of the file a PDFKit page was read from (CoreGraphics' view of its objects): what the ledger reads of
/// a page's annotations without parsing the whole file.
struct FileDictionary {
    let ref: CGPDFDictionaryRef

    /// The same object of the same file has the same address while its document is alive.
    var address: UnsafeRawPointer { unsafeBitCast(ref, to: UnsafeRawPointer.self) }

    /// The page's /Annots dictionaries.
    static func annotations(of page: CGPDFPage?) -> [FileDictionary] {
        var array: CGPDFArrayRef?
        guard let dictionary = page?.dictionary, CGPDFDictionaryGetArray(dictionary, "Annots", &array), let array else { return [] }
        return (0..<CGPDFArrayGetCount(array)).compactMap { index in
            var item: CGPDFDictionaryRef?
            return CGPDFArrayGetDictionary(array, index, &item) ? item.map(FileDictionary.init) : nil
        }
    }

    func name(_ key: String) -> String? {
        var value: UnsafePointer<CChar>?
        guard CGPDFDictionaryGetName(ref, key, &value), let value else { return nil }
        return String(cString: value)
    }

    /// A text string (a name also reads as text, as QPDF's `text` does).
    func text(_ key: String) -> String? {
        var value: CGPDFStringRef?
        if CGPDFDictionaryGetString(ref, key, &value), let value, let text = CGPDFStringCopyTextString(value) { return text as String }
        return name(key)
    }

    func int(_ key: String) -> Int? {
        var value: CGPDFInteger = 0
        return CGPDFDictionaryGetInteger(ref, key, &value) ? Int(value) : nil
    }

    func number(_ key: String) -> Double? {
        var value: CGPDFReal = 0
        return CGPDFDictionaryGetNumber(ref, key, &value) ? Double(value) : nil
    }

    func dictionary(_ key: String) -> FileDictionary? {
        var value: CGPDFDictionaryRef?
        return CGPDFDictionaryGetDictionary(ref, key, &value) ? value.map(FileDictionary.init) : nil
    }

    func rect(_ key: String) -> CGRect? {
        var array: CGPDFArrayRef?
        guard CGPDFDictionaryGetArray(ref, key, &array), let array, CGPDFArrayGetCount(array) == 4 else { return nil }
        var v = [CGPDFReal](repeating: 0, count: 4)
        for i in 0..<4 { guard CGPDFArrayGetNumber(array, i, &v[i]) else { return nil } }
        return CGRect(x: min(v[0], v[2]), y: min(v[1], v[3]), width: abs(v[2] - v[0]), height: abs(v[3] - v[1]))
    }

    /// A stream's decoded data and its dictionary.
    func stream(_ key: String) -> (data: Data, dictionary: FileDictionary)? {
        var value: CGPDFStreamRef?
        guard CGPDFDictionaryGetStream(ref, key, &value), let value, let info = CGPDFStreamGetDictionary(value) else { return nil }
        var format = CGPDFDataFormat.raw
        guard let data = CGPDFStreamCopyData(value, &format) else { return nil }
        return (data as Data, FileDictionary(ref: info))
    }
}
