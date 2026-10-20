import CoreGraphics
import Foundation

// Digital signature plumbing (ISO 32000-2 §12.8): the signature field, widget and dictionary appended as one update
// with a zero-filled /Contents and a fixed-width /ByteRange, the ByteRange patched to the final offsets, the signed
// bytes handed out, and the CMS written into the reserved space. Reading back gives each signature's ByteRange and
// CMS for verification; `PDFRevisions` says what changed after it. The CMS itself is SignKit's.

/// What to sign and how (features #82–#84).
public struct PDFSignatureRequest {
    public enum Kind: Hashable, Sendable {
        /// An approval signature.
        case approval
        /// A certification (DocMDP) signature: 1 no changes, 2 form filling and signing, 3 also annotations.
        case certification(permissions: Int)
        /// A document time stamp (ETSI.RFC3161).
        case documentTimeStamp
    }

    /// The signature field's partial name (unique among the form's fields).
    public var fieldName: String
    /// 0-based page of the widget (an invisible widget still sits on a page).
    public var page: Int
    /// The widget's rectangle in page space; empty for an invisible signature.
    public var rect: CGRect
    /// A form XObject of this model drawn as the widget's appearance (an empty one when nil).
    public var appearance: PDFObject?
    public var kind: Kind
    /// Bytes reserved for the CMS (the hex string is twice as long).
    public var contentsCapacity: Int
    public var filter: String
    /// "ETSI.CAdES.detached" (PAdES) or "adbe.pkcs7.detached".
    public var subFilter: String
    public var signerName: String?
    public var reason: String?
    public var location: String?
    public var contactInfo: String?
    public var signingTime: Date?

    public init(fieldName: String, page: Int = 0, rect: CGRect = .zero, appearance: PDFObject? = nil, kind: Kind = .approval,
                contentsCapacity: Int = 16_384, filter: String = "Adobe.PPKLite", subFilter: String = "ETSI.CAdES.detached",
                signerName: String? = nil, reason: String? = nil, location: String? = nil, contactInfo: String? = nil,
                signingTime: Date? = Date()) {
        self.fieldName = fieldName; self.page = page; self.rect = rect; self.appearance = appearance; self.kind = kind
        self.contentsCapacity = contentsCapacity; self.filter = filter; self.subFilter = subFilter
        self.signerName = signerName; self.reason = reason; self.location = location; self.contactInfo = contactInfo
        self.signingTime = signingTime
    }
}

/// A file ready for its CMS: everything but the /Contents hex string is final.
public struct PDFSignaturePlaceholder: Hashable, Sendable {
    /// The whole file, /Contents zero-filled.
    public var data: Data
    /// [start, length, start, length] of the two signed ranges.
    public var byteRange: [Int]
    /// The /Contents hex string including "<" and ">".
    public var contentsRange: Range<Int>
    /// Bytes the CMS may take.
    public var capacity: Int

    /// The bytes the signature covers (what the CMS digests).
    public var signedBytes: Data {
        data.subdata(in: byteRange[0]..<(byteRange[0] + byteRange[1])) + data.subdata(in: byteRange[2]..<(byteRange[2] + byteRange[3]))
    }

    /// The signed file: `cms` (DER) hex-encoded into /Contents, zero-padded.
    public func embedding(_ cms: Data) throws -> Data {
        guard cms.count <= capacity else { throw PDFModelError.signatureTooLarge(needed: cms.count, capacity: capacity) }
        var out = data
        let hex = Array("0123456789ABCDEF".utf8)
        var encoded = [UInt8]()
        encoded.reserveCapacity(cms.count * 2)
        for b in cms { encoded.append(hex[Int(b >> 4)]); encoded.append(hex[Int(b & 0xF)]) }
        let start = contentsRange.lowerBound + 1
        out.replaceSubrange(start..<(start + encoded.count), with: encoded)
        return out
    }
}

/// A signature found in a file.
public struct PDFSignatureInfo: Hashable, Sendable {
    /// The field's fully qualified name.
    public var fieldName: String
    public var page: Int?
    public var rect: CGRect?
    public var filter: String?
    public var subFilter: String?
    public var byteRange: [Int]
    /// The CMS as stored (DER, followed by the zero padding).
    public var contents: Data
    public var signingTime: Date?
    public var signerName: String?
    public var reason: String?
    public var location: String?
    public var contactInfo: String?
    public var isDocumentTimeStamp: Bool
    /// The DocMDP level of a certification signature (1–3).
    public var certificationPermissions: Int?

    /// The covered bytes of `file`; nil when the ByteRange does not fit it.
    public func signedBytes(of file: Data) -> Data? {
        guard byteRange.count == 4, byteRange.allSatisfy({ $0 >= 0 }), byteRange[0] + byteRange[1] <= byteRange[2],
              byteRange[2] + byteRange[3] <= file.count else { return nil }
        return file.subdata(in: byteRange[0]..<(byteRange[0] + byteRange[1])) + file.subdata(in: byteRange[2]..<(byteRange[2] + byteRange[3]))
    }

    /// The length of the revision this signature signs (where its second range ends).
    public var revisionLength: Int? { byteRange.count == 4 ? byteRange[2] + byteRange[3] : nil }
}

extension PDFModel {
    /// Adds the signature field and dictionary and appends them (with any other pending changes) to the original
    /// bytes as one update. The model then holds the unsigned field; use the returned file, not the model.
    public func prepareSignature(_ request: PDFSignatureRequest) throws -> PDFSignaturePlaceholder {
        _ = try IncrementalWriter.preconditions(self)
        guard let page = page(at: request.page) else { throw PDFModelError.invalidOperation("no page \(request.page)") }
        guard request.contentsCapacity > 0 else { throw PDFModelError.invalidOperation("no space for the signature") }
        if formFields().contains(where: { $0.name == request.fieldName }) {
            throw PDFModelError.invalidOperation("field \(request.fieldName) exists")
        }

        var sig: [String: PDFValue] = [
            "Filter": .name(request.filter),
            "SubFilter": .name(request.subFilter),
            // Placeholders with the final types; the writer replaces them with fixed-width text.
            "ByteRange": .array([.integer(0), .integer(0), .integer(0), .integer(0)]),
            "Contents": .string(Data(count: request.contentsCapacity)),
        ]
        switch request.kind {
        case .documentTimeStamp:
            sig["Type"] = .name("DocTimeStamp")
            sig["SubFilter"] = .name("ETSI.RFC3161")
        case .approval, .certification:
            sig["Type"] = .name("Sig")
            if let time = request.signingTime { sig["M"] = .ascii(PDFDate.string(time)) }
            if let v = request.signerName { sig["Name"] = .text(v) }
            if let v = request.reason { sig["Reason"] = .text(v) }
            if let v = request.location { sig["Location"] = .text(v) }
            if let v = request.contactInfo { sig["ContactInfo"] = .text(v) }
        }
        if case .certification(let permissions) = request.kind {
            sig["Reference"] = .array([.dictionary([
                "Type": .name("SigRef"),
                "TransformMethod": .name("DocMDP"),
                "TransformParams": .dictionary(["Type": .name("TransformParams"), "P": .integer(min(max(permissions, 1), 3)), "V": .name("1.2")]),
            ])])
        }
        let signature = makeIndirect(.dictionary(sig))

        let rect = request.rect.standardized
        let appearance = request.appearance.map { makeIndirect($0) }
            ?? makeStream(["Type": .name("XObject"), "Subtype": .name("Form"),
                           "BBox": .rect(CGRect(origin: .zero, size: rect.size)), "Resources": .dictionary([:])], data: Data())
        let widget: PDFValue = .dictionary([
            "Type": .name("Annot"),
            "Subtype": .name("Widget"),
            "FT": .name("Sig"),
            "T": .text(request.fieldName),
            "V": signature.reference!,
            // Print + Locked.
            "F": .integer(132),
            "Rect": .rect(rect),
            "AP": .dictionary(["N": appearance.reference!]),
        ])
        addField(widget, on: page)
        ensureAcroForm().set("SigFlags", .integer(3))
        if case .certification = request.kind {
            root.dictionary("Perms").set("DocMDP", signature)
        }

        let written = try IncrementalWriter.append(self, signatureObject: (signature.objectID!, request.contentsCapacity))
        guard let offsets = written.signature else { throw PDFModelError.failed("signature dictionary not written") }
        var data = written.data
        let byteRange = [0, offsets.contents.lowerBound, offsets.contents.upperBound, data.count - offsets.contents.upperBound]
        var text = "[\(byteRange.map(String.init).joined(separator: " "))]"
        let width = IncrementalWriter.byteRangePlaceholder.utf8.count
        guard text.utf8.count <= width else { throw PDFModelError.failed("file too large to sign") }
        text += String(repeating: " ", count: width - text.utf8.count)
        data.replaceSubrange(offsets.byteRange, with: Array(text.utf8))
        return PDFSignaturePlaceholder(data: data, byteRange: byteRange, contentsRange: offsets.contents, capacity: request.contentsCapacity)
    }

    /// The signatures of signed signature fields, in field order.
    public func signatures() -> [PDFSignatureInfo] {
        formFields().compactMap { field -> PDFSignatureInfo? in
            guard field.type == "Sig", let v = field.object.inherited("V"), v.type == .dictionary else { return nil }
            let widget = field.widgets.first
            var permissions: Int?
            for reference in v["Reference"]?.items ?? [] where reference["TransformMethod"]?.name == "DocMDP" {
                permissions = reference["TransformParams"]?["P"]?.int ?? 2
            }
            return PDFSignatureInfo(
                fieldName: field.name,
                page: widget?.page,
                rect: widget?.rect,
                filter: v["Filter"]?.name,
                subFilter: v["SubFilter"]?.name,
                byteRange: v["ByteRange"]?.items.compactMap(\.int) ?? [],
                contents: v["Contents"]?.stringData ?? Data(),
                signingTime: v["M"]?.text.flatMap(PDFDate.date),
                signerName: v["Name"]?.text,
                reason: v["Reason"]?.text,
                location: v["Location"]?.text,
                contactInfo: v["ContactInfo"]?.text,
                isDocumentTimeStamp: v["Type"]?.name == "DocTimeStamp",
                certificationPermissions: permissions)
        }
    }
}
