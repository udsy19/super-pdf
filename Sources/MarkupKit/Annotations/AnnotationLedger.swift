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

    /// The annotation's id: its private key, else its /NM, else a new one; stamped on it so it survives PDFKit writes.
    @discardableResult
    static func id(of annotation: PDFAnnotation) -> String {
        if let id = annotation.value(forAnnotationKey: .superPDFID) as? String, !id.isEmpty { return id }
        let id = (annotation.value(forAnnotationKey: .name) as? String).flatMap { $0.isEmpty ? nil : $0 } ?? UUID().uuidString.lowercased()
        annotation.setValue(id, forAnnotationKey: .superPDFID)
        annotation.setValue(id, forAnnotationKey: .name)
        return id
    }

    static func isMarkup(_ annotation: PDFAnnotation) -> Bool {
        !["Popup", "Link", "Widget"].contains(annotation.type ?? "")
    }

    // MARK: Reading what PDFKit dropped

    /// Reads the file's own annotation objects (QPDF) and pairs them with PDFKit's: names, reply links, clipped files
    /// and sounds come back into the ledger, replies stop drawing as extra note icons. Every markup annotation gets
    /// an id.
    func index(_ document: DocumentHandle) {
        // The file itself while it is unchanged (a snapshot would ask this ledger to restore, and loop).
        let model: PDFModel? = if let url = document.url, !document.state.isEdited {
            try? PDFModel(url: url, password: document.password)
        } else {
            document.pdf.dataRepresentation().flatMap { try? PDFModel(data: $0, password: document.password) }
        }
        var idsByObject: [Int: String] = [:]
        var links: [(child: String, parentObject: Int, type: String)] = []
        for index in 0..<document.pageCount {
            guard let page = document.pdf.page(at: index) else { continue }
            var unmatched = page.annotations.filter(Self.isMarkup)
            for object in model?.page(at: index)?.annotations ?? [] {
                guard let subtype = object["Subtype"]?.name, !["Popup", "Link", "Widget"].contains(subtype),
                      let match = Self.match(object, subtype: subtype, in: unmatched) else { continue }
                unmatched.removeAll { $0 === match }
                let id = Self.id(of: match)
                if let objectID = object.objectID { idsByObject[objectID] = id }
                var record = self[id]
                if let irt = object["IRT"], let parentObject = irt.objectID {
                    links.append((id, parentObject, object["RT"]?.name ?? "R"))
                    record.flags = object["F"]?.int ?? 4
                    match.shouldDisplay = false
                }
                if subtype == "FileAttachment" || subtype == "Sound" { record.icon = object["Name"]?.name }
                if subtype == "FileAttachment", let spec = object["FS"], let stream = spec["EF"]?["UF"] ?? spec["EF"]?["F"],
                   let data = try? stream.streamData(decode: .specialized) {
                    record.file = AttachedFile(fileName: spec["UF"]?.text ?? spec["F"]?.text ?? "Attachment", data: data,
                                               mimeType: stream["Subtype"]?.name, modified: stream["Params"]?["ModDate"]?.text.flatMap(PDFDate.date))
                }
                if subtype == "Sound", let stream = object["Sound"], let samples = try? stream.streamData(decode: .specialized) {
                    record.sound = SoundClip(samples: samples, rate: stream["R"]?.number ?? 8000, channels: stream["C"]?.int ?? 1,
                                             bits: stream["B"]?.int ?? 8, encoding: stream["E"]?.name ?? "Raw")
                }
                self[id] = record
            }
            unmatched.forEach { Self.id(of: $0) }
        }
        for link in links {
            guard let parent = idsByObject[link.parentObject] else { continue }
            var record = self[link.child]
            record.parent = parent
            record.replyType = link.type
            self[link.child] = record
        }
    }

    /// PDFKit's annotation for a file object: the same type, the same /NM, else the nearest top-left corner (PDFKit
    /// moves note icons to its own size), else the next one of that type.
    private static func match(_ object: PDFObject, subtype: String, in candidates: [PDFAnnotation]) -> PDFAnnotation? {
        let sameType = candidates.filter { $0.type == subtype }
        if let name = object["NM"]?.text, let named = sameType.first(where: { ($0.value(forAnnotationKey: .name) as? String) == name }) {
            return named
        }
        guard let rect = object["Rect"]?.rect?.standardized else { return sameType.first }
        let scored = sameType.map { ($0, abs($0.bounds.minX - rect.minX) + abs($0.bounds.maxY - rect.maxY)) }
        if let best = scored.min(by: { $0.1 < $1.1 }), best.1 < 8 { return best.0 }
        return sameType.first
    }

    // MARK: Putting it back

    /// What DocumentKit runs on the document it writes; nil when no annotation carries an id.
    func restorer(for document: DocumentHandle) -> AnnotationRestorer? {
        let hasMarkup = (0..<document.pageCount).contains { index in
            document.pdf.page(at: index)?.annotations.contains { $0.value(forAnnotationKey: .superPDFID) != nil } ?? false
        }
        guard hasMarkup else { return nil }
        let records = records
        return AnnotationRestorer(idKey: "SuperPDFID") { model, annotations, written in
            guard let model = model as? PDFModel else { return }
            Self.restore(in: model, annotations: annotations.compactMapValues { $0 as? PDFObject }, written: written, records: records)
        }
    }

    /// Writes each written annotation's id as /NM and puts back its reply link, flags, icon, file and sound. Links point
    /// at the annotations' objects in `model`, whether a save wrote them or kept them from the file.
    nonisolated static func restore(in model: PDFModel, annotations: [String: PDFObject], written: Set<String>, records: [String: LedgerRecord]) {
        for id in written {
            guard let annotation = annotations[id] else { continue }
            annotation.remove("SuperPDFID")
            if annotation["NM"] == nil { annotation.set("NM", .text(id)) }
            guard let record = records[id] else { continue }
            if let parent = record.parent, let target = annotations[parent]?.reference {
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
