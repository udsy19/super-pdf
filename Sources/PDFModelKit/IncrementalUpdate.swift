import Foundation

// Appended (incremental) saves and revision analysis (ISO 32000-2 §7.5.6). QPDF only writes whole files, so the
// appended update is written here: every object reachable from the trailer is compared with the same object in the
// original bytes, and the changed and new ones are appended with a cross-reference section of the original's kind
// (table or stream) whose /Prev chains to the original. Existing bytes are never touched, so earlier signatures stay
// valid. The same comparison reports what a later revision changed (for signature verification).

/// What a revision changed in one object.
public struct PDFObjectChange: Hashable, Sendable {
    public enum Kind: Sendable { case added, modified, removed }

    public var objectID: Int
    public var generation: Int
    public var kind: Kind
    /// /Type of the object (the old one for removals).
    public var type: String?
    public var subtype: String?
    public var isStream: Bool
}

/// Revisions of a file made of appended updates.
public enum PDFRevisions {
    /// The byte length at which each revision ends (after "%%EOF" and its line end), oldest first. Linearized files'
    /// first-page section (whose startxref is 0) is not a revision.
    public static func ends(in data: Data) -> [Int] {
        let bytes = [UInt8](data)
        let marker = Array("%%EOF".utf8)
        var ends: [Int] = []
        var i = 0
        while i + marker.count <= bytes.count {
            guard bytes[i] == marker[0], Array(bytes[i..<(i + marker.count)]) == marker else { i += 1; continue }
            if let offset = IncrementalWriter.startxref(in: bytes, before: i), offset > 0 {
                var end = i + marker.count
                if end < bytes.count, bytes[end] == 13 { end += 1 }
                if end < bytes.count, bytes[end] == 10 { end += 1 }
                ends.append(end)
            }
            i += marker.count
        }
        return ends
    }

    /// What the bytes after `length` changed relative to the revision `data[0..<length]`.
    public static func changes(in data: Data, since length: Int, password: String? = nil) throws -> [PDFObjectChange] {
        guard length > 0, length <= data.count else { throw PDFModelError.invalidOperation("revision length \(length)") }
        let old = try PDFModel(data: data.prefix(length), password: password)
        let new = try PDFModel(data: data, password: password)
        let diff = try IncrementalWriter.compare(new, with: old)
        var changes = diff.changed.map { item in
            PDFObjectChange(objectID: item.id, generation: item.generation, kind: item.isNew ? .added : .modified,
                            type: item.object["Type"]?.name, subtype: item.object["Subtype"]?.name, isStream: item.object.type == .stream)
        }
        let oldReachable = try IncrementalWriter.compare(old, with: nil).reachable
        for key in oldReachable.subtracting(diff.reachable).sorted(by: { $0.id < $1.id }) where new.object(id: key.id, generation: key.generation).isNull {
            let gone = old.object(id: key.id, generation: key.generation)
            changes.append(PDFObjectChange(objectID: key.id, generation: key.generation, kind: .removed,
                                           type: gone["Type"]?.name, subtype: gone["Subtype"]?.name, isStream: gone.type == .stream))
        }
        return changes
    }
}

extension PDFModel {
    /// Whether `incrementalData()` can append to the original bytes.
    public var canSaveIncrementally: Bool { (try? IncrementalWriter.preconditions(self)) != nil }

    /// The original bytes with this model's changes appended as one update; the original bytes when nothing changed.
    public func incrementalData() throws -> Data {
        try IncrementalWriter.append(self, signatureObject: nil).data
    }
}

struct IncrementalWriter {
    struct Key: Hashable { var id: Int; var generation: Int }

    struct Changed {
        var id: Int
        var generation: Int
        var object: PDFObject
        var isNew: Bool
    }

    /// Offsets of a signature dictionary's placeholders in the written file.
    struct SignatureOffsets {
        /// The fixed-width "[0 … … …]" text.
        var byteRange: Range<Int>
        /// The hex string including "<" and ">".
        var contents: Range<Int>
    }

    static let byteRangePlaceholder = "[0 0000000000 0000000000 0000000000]"

    /// The offset of the original's last cross-reference section and whether it is a table, or why an update
    /// cannot be appended. Reads only the file's tail and that section's first bytes.
    static func preconditions(_ model: PDFModel) throws -> (prevXref: Int, previousIsTable: Bool) {
        guard let original = model.originalBytes else { throw PDFModelError.incrementalUnavailable("new document") }
        guard !model.isEncrypted else { throw PDFModelError.incrementalUnavailable("encrypted") }
        guard !model.wasRepaired else { throw PDFModelError.incrementalUnavailable("rebuilt by recovery") }
        let tailStart = max(0, original.count - 65_536)
        let tail = [UInt8](original[tailStart...])
        guard let eof = lastIndex(of: Array("%%EOF".utf8), in: tail), let prev = startxref(in: tail, before: eof),
              prev > 0, prev < original.count else {
            throw PDFModelError.incrementalUnavailable("no cross-reference offset")
        }
        var start = prev
        while start < original.count, PDFSyntax.isWhitespace(original[start]) { start += 1 }
        let isTable = original.count >= start + 4 && [UInt8](original[start..<(start + 4)]) == Array("xref".utf8)
        return (prev, isTable)
    }

    /// Compares every object reachable from `model`'s trailer with `base` (nil: every object counts as new).
    static func compare(_ model: PDFModel, with base: PDFModel?) throws -> (changed: [Changed], reachable: Set<Key>) {
        var reachable: Set<Key> = []
        var changed: [Changed] = []
        var pending: [PDFValue] = [model.trailer.value]
        while let value = pending.popLast() {
            var refs: [Key] = []
            collectReferences(value, into: &refs)
            for key in refs where !reachable.contains(key) {
                reachable.insert(key)
                let object = model.object(id: key.id, generation: key.generation)
                guard !object.isNull else { continue }
                let current = object.value
                pending.append(current)
                guard let base else { changed.append(Changed(id: key.id, generation: key.generation, object: object, isNew: true)); continue }
                let old = base.object(id: key.id, generation: key.generation)
                if old.isNull {
                    changed.append(Changed(id: key.id, generation: key.generation, object: object, isNew: true))
                } else if old.type != object.type || old.value != current {
                    changed.append(Changed(id: key.id, generation: key.generation, object: object, isNew: false))
                } else if object.type == .stream, try object.streamData(decode: .none) != old.streamData(decode: .none) {
                    changed.append(Changed(id: key.id, generation: key.generation, object: object, isNew: false))
                }
            }
        }
        return (changed.sorted { $0.id < $1.id }, reachable)
    }

    private static func collectReferences(_ value: PDFValue, into refs: inout [Key]) {
        switch value {
        case .reference(let id, let gen): refs.append(Key(id: id, generation: gen))
        case .array(let items): for item in items { collectReferences(item, into: &refs) }
        case .dictionary(let dict): for item in dict.values { collectReferences(item, into: &refs) }
        default: break
        }
    }

    /// Appends the model's changes to its original bytes. `signatureObject` is written with fixed-width
    /// /ByteRange and zero-filled /Contents placeholders whose offsets are returned.
    static func append(_ model: PDFModel, signatureObject: (id: Int, capacity: Int)?) throws -> (data: Data, signature: SignatureOffsets?) {
        let (prevXref, previousIsTable) = try preconditions(model)
        guard let original = model.originalData else { throw PDFModelError.incrementalUnavailable("new document") }
        let base = try PDFModel(data: original, password: model.password)
        let changed = try compare(model, with: base).changed
        guard !changed.isEmpty else { return (original, nil) }

        var out = original
        if let last = out.last, last != 10, last != 13 { out.append(10) }
        var offsets: [Key: Int] = [:]
        var signature: SignatureOffsets?
        for item in changed {
            offsets[Key(id: item.id, generation: item.generation)] = out.count
            out.append(contentsOf: Array("\(item.id) \(item.generation) obj\n".utf8))
            if let sig = signatureObject, sig.id == item.id {
                signature = writeSignatureDictionary(item.object.value.dictionaryValue ?? [:], capacity: sig.capacity, into: &out)
            } else if item.object.type == .stream {
                try writeStream(item.object, into: &out)
            } else {
                item.object.value.write(into: &out)
            }
            out.append(contentsOf: Array("\nendobj\n".utf8))
        }

        let trailer = model.trailer
        let oldSize = base.trailer["Size"]?.int ?? 0
        var size = max(oldSize, (changed.map(\.id).max() ?? 0) + 1)
        var trailerDict: [String: PDFValue] = ["Prev": .integer(prevXref)]
        if let rootRef = trailer["Root"]?.reference { trailerDict["Root"] = rootRef }
        if let info = trailer["Info"] { trailerDict["Info"] = info.reference ?? info.value }
        if let id = base.trailer["ID"]?.value, id.arrayValue?.count == 2 { trailerDict["ID"] = id }

        let xrefOffset = out.count
        var keysByID = Dictionary(offsets.keys.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        if previousIsTable {
            out.append(contentsOf: Array("xref\n".utf8))
            for run in runs(offsets.keys.map(\.id).sorted()) {
                out.append(contentsOf: Array("\(run.lowerBound) \(run.count)\n".utf8))
                for id in run {
                    let key = keysByID[id]!
                    out.append(contentsOf: Array(String(format: "%010d %05d n\r\n", offsets[key]!, key.generation).utf8))
                }
            }
            trailerDict["Size"] = .integer(size)
            out.append(contentsOf: Array("trailer\n".utf8))
            PDFValue.dictionary(trailerDict).write(into: &out)
            out.append(10)
        } else {
            // A cross-reference stream: the stream is itself the next new object.
            let xrefID = size
            size += 1
            offsets[Key(id: xrefID, generation: 0)] = xrefOffset
            keysByID[xrefID] = Key(id: xrefID, generation: 0)
            let maxOffset = offsets.values.max() ?? 0
            var offsetWidth = 1
            while offsetWidth < 8 && maxOffset >= 1 << (8 * offsetWidth) { offsetWidth += 1 }
            let ids = offsets.keys.map(\.id).sorted()
            var rows = Data()
            for id in ids {
                let key = keysByID[id]!
                rows.append(1)
                let offset = offsets[key]!
                for shift in stride(from: (offsetWidth - 1) * 8, through: 0, by: -8) { rows.append(UInt8((offset >> shift) & 0xFF)) }
                rows.append(UInt8((key.generation >> 8) & 0xFF)); rows.append(UInt8(key.generation & 0xFF))
            }
            trailerDict["Type"] = .name("XRef")
            trailerDict["Size"] = .integer(size)
            trailerDict["W"] = .array([.integer(1), .integer(offsetWidth), .integer(2)])
            trailerDict["Index"] = .array(runs(ids).flatMap { [PDFValue.integer($0.lowerBound), .integer($0.count)] })
            trailerDict["Length"] = .integer(rows.count)
            out.append(contentsOf: Array("\(xrefID) 0 obj\n".utf8))
            PDFValue.dictionary(trailerDict).write(into: &out)
            out.append(contentsOf: Array("\nstream\n".utf8))
            out.append(rows)
            out.append(contentsOf: Array("\nendstream\nendobj\n".utf8))
        }
        out.append(contentsOf: Array("startxref\n\(xrefOffset)\n%%EOF\n".utf8))
        return (out, signature)
    }

    private static func writeStream(_ stream: PDFObject, into out: inout Data) throws {
        var dict = stream.value.dictionaryValue ?? [:]
        var data = try stream.streamData(decode: .none)
        // XMP stays readable as it is (PDF/A-1 forbids a filter on it), as QPDF's own writer leaves it.
        if dict["Filter"] == nil, dict["DecodeParms"] == nil, dict["Type"]?.nameValue != "Metadata", data.count > 64, let compressed = Flate.compress(data), compressed.count < data.count {
            data = compressed
            dict["Filter"] = .name("FlateDecode")
        }
        dict["Length"] = .integer(data.count)
        PDFValue.dictionary(dict).write(into: &out)
        out.append(contentsOf: Array("\nstream\n".utf8))
        out.append(data)
        out.append(contentsOf: Array("\nendstream".utf8))
    }

    private static func writeSignatureDictionary(_ dict: [String: PDFValue], capacity: Int, into out: inout Data) -> SignatureOffsets {
        var rest = dict
        rest["ByteRange"] = nil
        rest["Contents"] = nil
        out.append(contentsOf: Array("<<".utf8))
        for key in rest.keys.sorted() {
            PDFSyntax.writeName(key, into: &out)
            out.append(UInt8(ascii: " "))
            rest[key]!.write(into: &out)
            out.append(UInt8(ascii: " "))
        }
        out.append(contentsOf: Array("/ByteRange ".utf8))
        let byteRangeStart = out.count
        out.append(contentsOf: Array(byteRangePlaceholder.utf8))
        let byteRange = byteRangeStart..<out.count
        out.append(contentsOf: Array(" /Contents ".utf8))
        let contentsStart = out.count
        out.append(UInt8(ascii: "<"))
        out.append(Data(repeating: UInt8(ascii: "0"), count: capacity * 2))
        out.append(UInt8(ascii: ">"))
        let contents = contentsStart..<out.count
        out.append(contentsOf: Array(">>".utf8))
        return SignatureOffsets(byteRange: byteRange, contents: contents)
    }

    /// Consecutive runs of sorted ids.
    private static func runs(_ ids: [Int]) -> [ClosedRange<Int>] {
        var result: [ClosedRange<Int>] = []
        for id in ids {
            if let last = result.last, last.upperBound + 1 == id { result[result.count - 1] = last.lowerBound...id } else { result.append(id...id) }
        }
        return result
    }

    static func lastIndex(of needle: [UInt8], in bytes: [UInt8]) -> Int? {
        guard bytes.count >= needle.count else { return nil }
        var i = bytes.count - needle.count
        while i >= 0 {
            if bytes[i] == needle[0], Array(bytes[i..<(i + needle.count)]) == needle { return i }
            i -= 1
        }
        return nil
    }

    /// The number after the last "startxref" in the 1 KB before `index`.
    static func startxref(in bytes: [UInt8], before index: Int) -> Int? {
        let window = Array(bytes[max(0, index - 1024)..<index])
        guard let at = lastIndex(of: Array("startxref".utf8), in: window) else { return nil }
        var i = at + 9
        while i < window.count, PDFSyntax.isWhitespace(window[i]) { i += 1 }
        var value = 0, digits = 0
        while i < window.count, window[i] >= 48, window[i] <= 57, digits < 18 {
            value = value * 10 + Int(window[i] - 48); i += 1; digits += 1
        }
        return digits > 0 ? value : nil
    }
}
