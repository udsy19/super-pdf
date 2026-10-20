import Foundation

// Embedded files (ISO 32000-2 §7.11.4, §7.7.4 EmbeddedFiles name tree): the document's attachments, as listed in the
// catalog's /Names /EmbeddedFiles tree. File-attachment annotations belong to the annotation layer (MarkupKit).

/// A document-level attachment.
public struct PDFEmbeddedFile: Hashable, Sendable {
    /// The key in the EmbeddedFiles name tree.
    public var name: String
    /// /UF, else /F.
    public var fileName: String
    public var description: String?
    /// /Subtype of the embedded file stream as a MIME type ("application/pdf").
    public var mimeType: String?
    /// /Params /Size (the uncompressed size), when recorded.
    public var size: Int?
    public var creationDate: Date?
    public var modificationDate: Date?
    /// /AFRelationship (PDF/A-3): "Source", "Data", "Alternative", "Supplement", "Unspecified".
    public var relationship: String?
}

extension PDFModel {
    private var embeddedFilesTree: PDFObject? { root["Names"]?["EmbeddedFiles"] }

    public func embeddedFiles() -> [PDFEmbeddedFile] {
        guard let tree = embeddedFilesTree else { return [] }
        return PDFNameTree.entries(of: tree).compactMap { entry in
            let spec = entry.value
            guard spec.type == .dictionary else { return nil }
            let stream = spec["EF"]?["UF"] ?? spec["EF"]?["F"]
            let params = stream?["Params"]
            let mime = stream?["Subtype"]?.name
            return PDFEmbeddedFile(
                name: PDFText.decode(entry.key),
                fileName: spec["UF"]?.text ?? spec["F"]?.text ?? PDFText.decode(entry.key),
                description: spec["Desc"]?.text,
                mimeType: mime,
                size: params?["Size"]?.int,
                creationDate: params?["CreationDate"]?.text.flatMap(PDFDate.date),
                modificationDate: params?["ModDate"]?.text.flatMap(PDFDate.date),
                relationship: spec["AFRelationship"]?.name)
        }
    }

    /// The attachment's bytes, decoded.
    public func embeddedFileData(named name: String) throws -> Data? {
        guard let tree = embeddedFilesTree,
              let spec = PDFNameTree.value(for: PDFText.encode(name), in: tree) ?? PDFNameTree.entries(of: tree).first(where: { PDFText.decode($0.key) == name })?.value,
              let stream = spec["EF"]?["UF"] ?? spec["EF"]?["F"] else { return nil }
        return try stream.streamData(decode: .specialized)
    }

    /// Adds (or replaces, by name) an attachment. With `relationship` the file spec is also listed in the catalog's
    /// /AF array (PDF/A-3 associated files).
    public func addEmbeddedFile(_ data: Data, name: String, fileName: String? = nil, mimeType: String? = nil,
                                description: String? = nil, creationDate: Date? = nil, modificationDate: Date? = nil,
                                relationship: String? = nil) {
        var params: [String: PDFValue] = ["Size": .integer(data.count)]
        if let creationDate { params["CreationDate"] = .ascii(PDFDate.string(creationDate)) }
        if let modificationDate { params["ModDate"] = .ascii(PDFDate.string(modificationDate)) }
        var streamDict: [String: PDFValue] = ["Type": .name("EmbeddedFile"), "Params": .dictionary(params)]
        if let mimeType { streamDict["Subtype"] = .name(mimeType) }
        let stream = Flate.compress(data).map { makeStream(streamDict, data: $0, filter: .name("FlateDecode")) }
            ?? makeStream(streamDict, data: data)
        let file = fileName ?? name
        var spec: [String: PDFValue] = ["Type": .name("Filespec"), "F": .text(file), "UF": .text(file)]
        if let description { spec["Desc"] = .text(description) }
        if let relationship { spec["AFRelationship"] = .name(relationship) }
        let specObject = makeIndirect(.dictionary(spec))
        specObject.set("EF", .dictionary(["F": stream.reference!, "UF": stream.reference!]))
        var entries = embeddedFileEntries().filter { PDFText.decode($0.key) != name }
        entries.append((PDFText.encode(name), specObject))
        setEmbeddedFileEntries(entries)
        if relationship != nil { root.array("AF").append(specObject) }
    }

    /// Removes an attachment; false when there is none of that name.
    @discardableResult
    public func removeEmbeddedFile(named name: String) -> Bool {
        let entries = embeddedFileEntries()
        let kept = entries.filter { PDFText.decode($0.key) != name }
        guard kept.count != entries.count else { return false }
        let removed = entries.filter { PDFText.decode($0.key) == name }.compactMap(\.value.objectID)
        if let af = root["AF"] {
            for i in (0..<af.count).reversed() where af[i]?.objectID.map(removed.contains) == true { af.removeItem(at: i) }
            if af.count == 0 { root.remove("AF") }
        }
        setEmbeddedFileEntries(kept)
        return true
    }

    private func embeddedFileEntries() -> [(key: Data, value: PDFObject)] {
        embeddedFilesTree.map(PDFNameTree.entries) ?? []
    }

    private func setEmbeddedFileEntries(_ entries: [(key: Data, value: PDFObject)]) {
        if entries.isEmpty {
            root["Names"]?.remove("EmbeddedFiles")
            if root["Names"]?.keys.isEmpty == true { root.remove("Names") }
            return
        }
        root.dictionary("Names").set("EmbeddedFiles", makeIndirect(PDFNameTree.make(in: self, entries: entries)))
    }
}
