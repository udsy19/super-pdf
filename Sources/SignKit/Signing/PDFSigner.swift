import CryptoKit
import Foundation
import PDFModelKit
import Security
import SuperPDFCore
import SwiftASN1

// Writing a signed copy (features #82): placed signatures, initials, dates and text become stamp annotations with
// their own appearance; a certificate signature becomes a signature field whose /Contents holds a PAdES-B-B CMS over
// the /ByteRange (features §3.6). Everything is appended to the original bytes as one update, so signatures already in
// the file stay valid; a file that can't take an appended update (rebuilt by recovery) is saved whole first.

/// A mark put on a page, in page space.
struct PlacedMark: Hashable, Sendable {
    var mark: Mark
    var page: Int
    var rect: CGRect
    /// The annotation's /Contents: what a screen reader says ("Signature", "Date").
    var label: String
}

/// A certificate signature to add (features #82, second level).
struct CertificateJob: @unchecked Sendable {
    var certificate: Data
    var chain: [Data]
    var key: SecKey
    var page: Int
    /// The visible box; nil signs invisibly.
    var rect: CGRect?
    var appearance: SealAppearance
    var reason: String
    var location: String
    /// "Lock the document after signing": a certification signature that allows no changes (DocMDP P=1), when the file
    /// has no signature yet (ISO 32000-2 §12.8.2.2: the certification signature is the first).
    var lockDocument: Bool
    var signingTime: Date
    var timestamp: TimestampClient?
}

enum SignError: Error, Equatable {
    /// Appended updates can't be encrypted here, and saving the file whole would drop its password.
    case encrypted
}

enum PDFSigner {
    /// The signed copy of `source`.
    static func sign(_ source: PDFSource, marks: [PlacedMark], certificate job: CertificateJob?) async throws -> Data {
        var model = try PDFModel(source)
        if !model.canSaveIncrementally {
            guard !model.isEncrypted else { throw SignError.encrypted }
            // Appended saves need intact cross-references: write the file whole once, then append to that.
            model = try PDFModel(data: try model.data())
        }
        // The appearances' own models stay alive until the file is written (QPDF copies their streams then).
        var sources: [PDFModel] = []
        for mark in marks { try addStamp(mark, to: model, sources: &sources) }
        let data: Data
        if let job {
            data = try await addSignature(job, to: model, sources: &sources)
        } else {
            data = model.canSaveIncrementally ? try model.incrementalData() : try model.data()
        }
        withExtendedLifetime(sources) {}
        return data
    }

    /// A stamp annotation (Preview's signature placement) whose appearance is the mark.
    static func addStamp(_ placed: PlacedMark, to model: PDFModel, sources: inout [PDFModel]) throws {
        guard let page = model.page(at: placed.page) else { throw PDFModelError.invalidOperation("no page \(placed.page)") }
        let rect = placed.rect.standardized
        let form = try Appearance.formXObject(in: model, rect: rect, rotation: page.rotation, sources: &sources) { box, context in
            Appearance.draw(placed.mark, in: box, context: context)
        }
        let annotation = model.makeIndirect(.dictionary([
            "Type": .name("Annot"), "Subtype": .name("Stamp"), "Rect": .rect(rect), "F": .integer(4),
            "NM": .text("superpdf-sign-" + UUID().uuidString.lowercased()), "M": .ascii(PDFDate.string(Date())),
            "Contents": .text(placed.label), "AP": .dictionary(["N": form.reference!]),
        ]))
        page.addAnnotation(annotation)
    }

    /// Adds the signature field, reserves room for the CMS, signs the /ByteRange and fills it in.
    static func addSignature(_ job: CertificateJob, to model: PDFModel, sources: inout [PDFModel]) async throws -> Data {
        let existing = Set(model.formFields().map(\.name))
        var n = 1
        while existing.contains("Signature\(n)") { n += 1 }
        let kind: PDFSignatureRequest.Kind = job.lockDocument && model.signatures().isEmpty ? .certification(permissions: 1) : .approval
        var appearance: PDFObject?
        if let rect = job.rect?.standardized, let page = model.page(at: job.page) {
            appearance = try Appearance.formXObject(in: model, rect: rect, rotation: page.rotation, sources: &sources) { box, context in
                Appearance.drawSeal(job.appearance, in: box, context: context)
            }
        }
        // The CMS holds the certificates, the signed attributes and the signature value; a timestamp token adds a TSA
        // certificate chain of its own.
        let capacity = 4096 + job.certificate.count + job.chain.reduce(0) { $0 + $1.count } + (job.timestamp == nil ? 0 : 12_288)
        let request = PDFSignatureRequest(fieldName: "Signature\(n)", page: job.page, rect: job.rect?.standardized ?? .zero,
                                          appearance: appearance, kind: kind, contentsCapacity: capacity,
                                          signerName: job.appearance.name, reason: job.reason.isEmpty ? nil : job.reason,
                                          location: job.location.isEmpty ? nil : job.location, signingTime: job.signingTime)
        let placeholder = try model.prepareSignature(request)
        let timestamp = job.timestamp.map { client in { @Sendable (value: [UInt8]) async throws -> [UInt8]? in try await client.token(for: value) } }
        let cms = try await CMSWriter.signDetached(placeholder.signedBytes, certificate: job.certificate, chain: job.chain, key: job.key,
                                                   timestamp: timestamp)
        return try placeholder.embedding(cms)
    }
}

// MARK: - RFC 3161 timestamps (features §3.5 item 4: only when the person turned them on and named a server)

struct TimestampClient: Sendable {
    var server: URL
    /// Sends the request and returns the response body; URLSession in the app, a canned answer in the self-test.
    var transport: @Sendable (URLRequest) async throws -> Data

    init(server: URL, transport: (@Sendable (URLRequest) async throws -> Data)? = nil) {
        self.server = server
        self.transport = transport ?? { request in
            let (data, response) = try await URLSession.shared.data(for: request)
            guard (response as? HTTPURLResponse)?.statusCode == 200 else { throw TimestampError.server }
            return data
        }
    }

    enum TimestampError: Error { case server, refused, malformed }

    /// The TimeStampToken (a CMS ContentInfo, DER) for a signature value.
    func token(for signatureValue: [UInt8]) async throws -> [UInt8] {
        var request = URLRequest(url: server, timeoutInterval: 20)
        request.httpMethod = "POST"
        request.setValue("application/timestamp-query", forHTTPHeaderField: "Content-Type")
        request.httpBody = Data(try Self.query(for: signatureValue, nonce: UInt64.random(in: 1...UInt64.max >> 1)))
        return try Self.token(fromResponse: try await transport(request))
    }

    /// TimeStampReq (RFC 3161 §2.4.1) for the SHA-256 of `signatureValue`, asking for the TSA's certificate.
    static func query(for signatureValue: [UInt8], nonce: UInt64) throws -> [UInt8] {
        try CMSWriter.der { coder in
            try coder.appendConstructedNode(identifier: .sequence) { coder in
                try coder.serialize(1)
                try coder.appendConstructedNode(identifier: .sequence) { coder in
                    coder.serializeRawBytes(try CMSWriter.algorithmIdentifier(OID.sha256, nullParameters: false))
                    try coder.serialize(ASN1OctetString(contentBytes: DigestAlgorithm.sha256.hash(signatureValue)[...]))
                }
                try coder.serialize(Int(truncatingIfNeeded: nonce))
                try coder.serialize(true)
            }
        }
    }

    /// The token of a TimeStampResp whose status is granted (0) or granted with modifications (1).
    static func token(fromResponse data: Data) throws -> [UInt8] {
        let bytes = [UInt8](data)
        guard let length = CMSSignature.encodedLength(bytes), let root = try? BER.parse(bytes[0..<length]),
              case .constructed(let parts) = root.content else { throw TimestampError.malformed }
        let all = Array(parts)
        guard let statusInfo = all.first, case .constructed(let statusParts) = statusInfo.content,
              let statusNode = statusParts.first(where: { _ in true }), let status = try? Int(derEncoded: statusNode) else {
            throw TimestampError.malformed
        }
        guard status == 0 || status == 1 else { throw TimestampError.refused }
        guard all.count > 1 else { throw TimestampError.malformed }
        return Array(all[1].encodedBytes)
    }
}
