import Foundation
import PDFModelKit
import Security
import SuperPDFCore
import X509

// "Signatures in this file" (features #83): for each signed field, whether the bytes it covers are the bytes it signed
// (the CMS message digest over the /ByteRange), whether the signature value is the certificate's key signing them,
// whether the certificate leads to someone trusted on this Mac (the system's roots plus "People I trust" and the
// person's own certificates; no network), and whether later appended updates changed what the pages show.

enum SignatureVerifier {
    /// Reports for every signature of `data`, in field order. Document timestamps are not people's signatures and are
    /// left out.
    static func verify(_ data: Data, password: String?, anchors: [Data]) throws -> [SignatureReport] {
        let model = try PDFModel(data: data, password: password)
        let signatures = model.signatures()
        // The certification signature's DocMDP level governs what later revisions may change (§12.8.2.2).
        let mdp = signatures.compactMap(\.certificationPermissions).first
        return signatures.filter { !$0.isDocumentTimeStamp }.map { info in
            report(info, in: data, password: password, anchors: anchors, mdp: mdp)
        }
    }

    static func report(_ info: PDFSignatureInfo, in data: Data, password: String?, anchors: [Data], mdp: Int?) -> SignatureReport {
        var report = SignatureReport(fieldName: info.fieldName, signerName: info.signerName ?? SignStrings.unnamed, signedAt: info.signingTime,
                                     validity: .invalid, changedAfterSigning: false, chain: [], certificate: Data())
        guard let cms = try? CMSSignature(info.contents) else { return report }
        report.certificate = cms.signer ?? Data()
        if let signer = cms.signer, let name = Certificates.commonName(of: signer) { report.signerName = name }
        if report.signedAt == nil { report.signedAt = cms.signingTime }
        report.chain = cms.certificates.compactMap(Certificates.commonName(of:))

        guard let signed = info.signedBytes(of: data), coversAllButContents(info.byteRange, of: data), let signer = cms.signer else { return report }
        if let length = info.revisionLength {
            report.changedAfterSigning = RevisionCheck.changedAfterSigning(data, length: length, password: password, mdp: mdp)
        }

        // The bytes: what the signature says it signed against what the file holds.
        if info.subFilter == "adbe.pkcs7.sha1" {
            guard let content = cms.content, content == DigestAlgorithm.sha1.hash(signed) else { report.validity = .modified; return report }
        } else if let digest = cms.messageDigest {
            guard let algorithm = cms.digestAlgorithm, digest == algorithm.hash(signed) else { report.validity = .modified; return report }
        }
        if let essHash = cms.signingCertificateHash, essHash != DigestAlgorithm.sha256.hash(signer) {
            return report
        }
        // The maths: the signer's key made this signature.
        let message = cms.signedAttributes.map { Data($0) } ?? (info.subFilter == "adbe.pkcs7.sha1" ? Data(cms.content ?? []) : signed)
        guard SignatureMaths.isValid(cms.signature, message: message, algorithm: cms.signatureAlgorithm, digest: cms.digestAlgorithm,
                                     pssDigest: cms.pssDigest, certificate: signer) else { return report }
        // The person: a chain to someone trusted, at the time of signing.
        let intermediates = cms.certificates.filter { $0 != signer }
        let trust = Trust.evaluate(signer, intermediates: intermediates, anchors: anchors, at: report.signedAt ?? Date())
        if !trust.chain.isEmpty { report.chain = trust.chain }
        report.validity = trust.trusted ? .valid : .untrusted
        return report
    }

    /// The gap between the two ranges is exactly the /Contents hex string, and the second range runs to its revision's
    /// end: nothing else is left unsigned.
    static func coversAllButContents(_ range: [Int], of data: Data) -> Bool {
        guard range.count == 4, range[0] == 0, range[1] > 0, range[2] > range[1], range[2] <= data.count, range[2] + range[3] <= data.count
        else { return false }
        return data[data.startIndex + range[1]] == UInt8(ascii: "<") && data[data.startIndex + range[2] - 1] == UInt8(ascii: ">")
    }
}

// MARK: - Trust

enum Trust {
    /// Whether `certificate` chains to a system root or to one of `anchors` at `date`, without the network; the chain's
    /// common names from the signer up.
    static func evaluate(_ certificate: Data, intermediates: [Data], anchors: [Data], at date: Date) -> (trusted: Bool, chain: [String]) {
        let certificates = ([certificate] + intermediates).compactMap { SecCertificateCreateWithData(nil, $0 as CFData) }
        guard !certificates.isEmpty else { return (false, []) }
        var trust: SecTrust?
        guard SecTrustCreateWithCertificates(certificates as CFArray, SecPolicyCreateBasicX509(), &trust) == errSecSuccess, let trust else {
            return (false, [])
        }
        let anchorCertificates = anchors.compactMap { SecCertificateCreateWithData(nil, $0 as CFData) }
        SecTrustSetAnchorCertificates(trust, anchorCertificates as CFArray)
        SecTrustSetAnchorCertificatesOnly(trust, false)
        SecTrustSetNetworkFetchAllowed(trust, false)
        SecTrustSetVerifyDate(trust, date as CFDate)
        let trusted = SecTrustEvaluateWithError(trust, nil)
        let chain = (SecTrustCopyCertificateChain(trust) as? [SecCertificate] ?? []).compactMap {
            Certificates.commonName(of: SecCertificateCopyData($0) as Data)
        }
        return (trusted, chain)
    }
}

// MARK: - What changed after signing

enum RevisionCheck {
    /// Whether the updates appended after the first `length` bytes change what the pages show (pages, their content,
    /// boxes, rotation or drawn objects), or anything the certification level forbids: with P=1 any change, with P=2
    /// any annotation that isn't a form field. Form filling, further signatures and (without DocMDP, or with P=3)
    /// annotations are allowed, as Acrobat treats them.
    static func changedAfterSigning(_ data: Data, length: Int, password: String?, mdp: Int?) -> Bool {
        guard length < data.count else { return false }
        if data[(data.startIndex + length)...].allSatisfy({ PDFWhitespace.contains($0) }) { return false }
        guard let old = try? PDFModel(data: data.prefix(length), password: password),
              let new = try? PDFModel(data: data, password: password) else { return true }
        if old.pageCount != new.pageCount { return true }
        for (before, after) in zip(old.pages, new.pages) where pageChanged(before, after) { return true }
        guard let mdp, mdp < 3 else { return false }
        guard let changes = try? PDFRevisions.changes(in: data, since: length, password: password) else { return true }
        if mdp == 1 {
            // Only the validation data a later signer may add (DSS) is allowed.
            return changes.contains { $0.type != "DSS" && $0.type != "VRI" }
        }
        let annotationTypes: Set<String> = ["Text", "Link", "FreeText", "Line", "Square", "Circle", "Polygon", "PolyLine", "Highlight",
                                            "Underline", "Squiggly", "StrikeOut", "Stamp", "Caret", "Ink", "Popup", "FileAttachment",
                                            "Sound", "Redact"]
        return changes.contains { annotationTypes.contains($0.subtype ?? "") }
    }

    private static let PDFWhitespace: Set<UInt8> = [0, 9, 10, 12, 13, 32]

    private static func pageChanged(_ old: PDFModelKit.PDFPage, _ new: PDFModelKit.PDFPage) -> Bool {
        if old.rotation != new.rotation || old.box(.media) != new.box(.media) || old.box(.crop) != new.box(.crop) { return true }
        guard let oldContent = try? old.contentData(), let newContent = try? new.contentData() else { return true }
        if oldContent != newContent { return true }
        return drawnObjects(old) != drawnObjects(new)
    }

    /// The decoded data of the XObjects a page's resources name (what `Do` draws).
    private static func drawnObjects(_ page: PDFModelKit.PDFPage) -> [String: Data] {
        guard let xobjects = page.resources?["XObject"], xobjects.type == .dictionary else { return [:] }
        var result: [String: Data] = [:]
        for key in xobjects.keys {
            guard let object = xobjects[key] else { continue }
            result[key] = (try? object.streamData(decode: .generalized)) ?? Data()
        }
        return result
    }
}
