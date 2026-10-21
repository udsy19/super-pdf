import CryptoKit
import Foundation
import Security
import SwiftASN1
import X509

// CMS SignedData for PDF signatures (RFC 5652, ETSI EN 319 122-1 CAdES as PAdES uses it; features §3.6). swift-certificates
// keeps its CMS types internal and its `CMS.sign` cannot add the attributes PAdES baseline B-B needs (content-type,
// message-digest and ESS signing-certificate-v2, and no signing-time: the time is the /M of the signature dictionary),
// so the structure is written here with SwiftASN1 and signed with swift-certificates' `Certificate.PrivateKey` over a
// `SecKey`. Reading takes any producer's encoding (BER lengths, rsaEncryption as the signature algorithm, NULL digest
// parameters) because verification has to accept what Acrobat and other apps write.

/// Object identifiers used by the signer and the reader.
enum OID {
    static let signedData: ASN1ObjectIdentifier = [1, 2, 840, 113549, 1, 7, 2]
    static let data: ASN1ObjectIdentifier = [1, 2, 840, 113549, 1, 7, 1]
    static let contentType: ASN1ObjectIdentifier = [1, 2, 840, 113549, 1, 9, 3]
    static let messageDigest: ASN1ObjectIdentifier = [1, 2, 840, 113549, 1, 9, 4]
    static let signingTime: ASN1ObjectIdentifier = [1, 2, 840, 113549, 1, 9, 5]
    static let signingCertificateV2: ASN1ObjectIdentifier = [1, 2, 840, 113549, 1, 9, 16, 2, 47]
    static let timeStampToken: ASN1ObjectIdentifier = [1, 2, 840, 113549, 1, 9, 16, 2, 14]
    static let tstInfo: ASN1ObjectIdentifier = [1, 2, 840, 113549, 1, 9, 16, 1, 4]

    static let sha1: ASN1ObjectIdentifier = [1, 3, 14, 3, 2, 26]
    static let sha256: ASN1ObjectIdentifier = [2, 16, 840, 1, 101, 3, 4, 2, 1]
    static let sha384: ASN1ObjectIdentifier = [2, 16, 840, 1, 101, 3, 4, 2, 2]
    static let sha512: ASN1ObjectIdentifier = [2, 16, 840, 1, 101, 3, 4, 2, 3]

    static let rsaEncryption: ASN1ObjectIdentifier = [1, 2, 840, 113549, 1, 1, 1]
    static let sha1WithRSA: ASN1ObjectIdentifier = [1, 2, 840, 113549, 1, 1, 5]
    static let rsaPSS: ASN1ObjectIdentifier = [1, 2, 840, 113549, 1, 1, 10]
    static let sha256WithRSA: ASN1ObjectIdentifier = [1, 2, 840, 113549, 1, 1, 11]
    static let sha384WithRSA: ASN1ObjectIdentifier = [1, 2, 840, 113549, 1, 1, 12]
    static let sha512WithRSA: ASN1ObjectIdentifier = [1, 2, 840, 113549, 1, 1, 13]
    static let ecPublicKey: ASN1ObjectIdentifier = [1, 2, 840, 10045, 2, 1]
    static let ecdsaWithSHA256: ASN1ObjectIdentifier = [1, 2, 840, 10045, 4, 3, 2]
    static let ecdsaWithSHA384: ASN1ObjectIdentifier = [1, 2, 840, 10045, 4, 3, 3]
    static let ecdsaWithSHA512: ASN1ObjectIdentifier = [1, 2, 840, 10045, 4, 3, 4]
}

/// The digests a signature may use.
enum DigestAlgorithm: Sendable {
    case sha1, sha256, sha384, sha512

    init?(_ oid: ASN1ObjectIdentifier) {
        switch oid {
        case OID.sha1: self = .sha1
        case OID.sha256: self = .sha256
        case OID.sha384: self = .sha384
        case OID.sha512: self = .sha512
        default: return nil
        }
    }

    var oid: ASN1ObjectIdentifier {
        switch self {
        case .sha1: OID.sha1
        case .sha256: OID.sha256
        case .sha384: OID.sha384
        case .sha512: OID.sha512
        }
    }

    func hash<D: DataProtocol>(_ data: D) -> [UInt8] {
        switch self {
        case .sha1: Array(Insecure.SHA1.hash(data: data))
        case .sha256: Array(SHA256.hash(data: data))
        case .sha384: Array(SHA384.hash(data: data))
        case .sha512: Array(SHA512.hash(data: data))
        }
    }
}

/// Raw DER bytes as a SwiftASN1 node, so prebuilt parts can go into SETs (which the serializer sorts) and sequences.
struct RawDER: DERSerializable {
    var bytes: [UInt8]
    func serialize(into coder: inout DER.Serializer) throws { coder.serializeRawBytes(bytes) }
}

enum CMSError: Error, Equatable {
    case malformed(String)
    case unsupportedKey
    case signingFailed(String)
}

// MARK: - Writing

enum CMSWriter {
    /// A detached PAdES-B-B SignedData over `content` signed by `key` for `certificate` (DER), with `chain` (DER, without
    /// the signer) added for validators. `timestamp` turns the signature value into an RFC 3161 token (PAdES-B-T).
    static func signDetached(_ content: Data, certificate: Data, chain: [Data], key: SecKey,
                             timestamp: (@Sendable (_ signatureValue: [UInt8]) async throws -> [UInt8]?)? = nil) async throws -> Data {
        let signer = try CertificateFields(der: [UInt8](certificate))
        let isRSA = (SecKeyCopyAttributes(key) as? [CFString: Any])?[kSecAttrKeyType] as? String == (kSecAttrKeyTypeRSA as String)
        let digest = DigestAlgorithm.sha256

        let attributes = try [
            attribute(OID.contentType, value: der { try $0.serialize(OID.data) }),
            attribute(OID.messageDigest, value: der { try $0.serialize(ASN1OctetString(contentBytes: digest.hash(content)[...])) }),
            attribute(OID.signingCertificateV2, value: signingCertificateV2(certificate)),
        ]
        let signedSet = try der { try $0.serializeSetOf(attributes.map(RawDER.init)) }

        let privateKey: Certificate.PrivateKey
        do { privateKey = try Certificate.PrivateKey(key) } catch { throw CMSError.unsupportedKey }
        let algorithm: Certificate.SignatureAlgorithm = isRSA ? .sha256WithRSAEncryption : .ecdsaWithSHA256
        let signatureValue: [UInt8]
        do { signatureValue = try privateKey.sign(bytes: signedSet, signatureAlgorithm: algorithm).rawRepresentation } catch {
            throw CMSError.signingFailed(String(describing: error))
        }

        var unsigned: [[UInt8]] = []
        if let timestamp, let token = try await timestamp(signatureValue) {
            unsigned.append(try attribute(OID.timeStampToken, value: token))
        }

        // [0] IMPLICIT SET OF Attribute: the same bytes with the context tag.
        var signedAttrs = signedSet
        signedAttrs[0] = 0xA0
        let signerInfo = try der { coder in
            try coder.appendConstructedNode(identifier: .sequence) { coder in
                try coder.serialize(1)
                coder.appendConstructedNode(identifier: .sequence) { coder in
                    coder.serializeRawBytes(signer.issuer)
                    coder.serializeRawBytes(signer.serialNumber)
                }
                coder.serializeRawBytes(try algorithmIdentifier(digest.oid, nullParameters: false))
                coder.serializeRawBytes(signedAttrs)
                coder.serializeRawBytes(try algorithmIdentifier(isRSA ? OID.sha256WithRSA : OID.ecdsaWithSHA256, nullParameters: isRSA))
                try coder.serialize(ASN1OctetString(contentBytes: signatureValue[...]))
                if !unsigned.isEmpty {
                    try coder.serializeSetOf(unsigned.map(RawDER.init), identifier: ASN1Identifier(tagWithNumber: 1, tagClass: .contextSpecific))
                }
            }
        }

        let certificates = [[UInt8](certificate)] + chain.map { [UInt8]($0) }
        let contentInfo = try der { coder in
            try coder.appendConstructedNode(identifier: .sequence) { coder in
                try coder.serialize(OID.signedData)
                try coder.serialize(explicitlyTaggedWithTagNumber: 0, tagClass: .contextSpecific) { coder in
                    try coder.appendConstructedNode(identifier: .sequence) { coder in
                        try coder.serialize(1)
                        try coder.serializeSetOf([RawDER(bytes: try algorithmIdentifier(digest.oid, nullParameters: false))])
                        try coder.appendConstructedNode(identifier: .sequence) { try $0.serialize(OID.data) }
                        try coder.serializeSetOf(certificates.map(RawDER.init), identifier: ASN1Identifier(tagWithNumber: 0, tagClass: .contextSpecific))
                        try coder.serializeSetOf([RawDER(bytes: signerInfo)])
                    }
                }
            }
        }
        return Data(contentInfo)
    }

    /// ESS signing-certificate-v2 (RFC 5035): the SHA-256 of the signer's certificate, so the certificate can't be
    /// swapped for another with the same key.
    private static func signingCertificateV2(_ certificate: Data) throws -> [UInt8] {
        try der { coder in
            try coder.appendConstructedNode(identifier: .sequence) { coder in          // SigningCertificateV2
                try coder.appendConstructedNode(identifier: .sequence) { coder in      // certs SEQUENCE OF ESSCertIDv2
                    try coder.appendConstructedNode(identifier: .sequence) { coder in  // ESSCertIDv2 (hashAlgorithm defaults to SHA-256)
                        try coder.serialize(ASN1OctetString(contentBytes: DigestAlgorithm.sha256.hash(certificate)[...]))
                    }
                }
            }
        }
    }

    static func attribute(_ type: ASN1ObjectIdentifier, value: [UInt8]) throws -> [UInt8] {
        try der { coder in
            try coder.appendConstructedNode(identifier: .sequence) { coder in
                try coder.serialize(type)
                try coder.serializeSetOf([RawDER(bytes: value)])
            }
        }
    }

    static func algorithmIdentifier(_ oid: ASN1ObjectIdentifier, nullParameters: Bool) throws -> [UInt8] {
        try der { coder in
            try coder.appendConstructedNode(identifier: .sequence) { coder in
                try coder.serialize(oid)
                if nullParameters { try coder.serialize(ASN1Null()) }
            }
        }
    }

    static func der(_ build: (inout DER.Serializer) throws -> Void) throws -> [UInt8] {
        var coder = DER.Serializer()
        try build(&coder)
        return coder.serializedBytes
    }
}

/// The parts of a certificate the SignerInfo copies byte for byte: the issuer name and the serial number.
struct CertificateFields {
    var issuer: [UInt8]
    var serialNumber: [UInt8]

    init(der: [UInt8]) throws {
        let root = try BER.parse(der)
        guard case .constructed(let certificate) = root.content, let tbs = certificate.first(where: { _ in true }),
              case .constructed(let tbsNodes) = tbs.content else { throw CMSError.malformed("certificate") }
        var fields = Array(tbsNodes)
        if fields.first?.identifier == ASN1Identifier(tagWithNumber: 0, tagClass: .contextSpecific) { fields.removeFirst() }
        guard fields.count >= 3 else { throw CMSError.malformed("certificate fields") }
        serialNumber = Array(fields[0].encodedBytes)
        issuer = Array(fields[2].encodedBytes)
    }
}

// MARK: - Reading

/// A CMS SignedData as a PDF signature carries it, read for verification.
struct CMSSignature {
    /// Every certificate in the SignedData (DER).
    var certificates: [Data]
    /// The signer's certificate (DER), found by issuer and serial number or subject key identifier.
    var signer: Data?
    var digestAlgorithm: DigestAlgorithm?
    /// The signature algorithm's OID and, for RSASSA-PSS, its hash.
    var signatureAlgorithm: ASN1ObjectIdentifier
    var pssDigest: DigestAlgorithm?
    var signature: [UInt8]
    /// The DER of the signed attributes as signed (with the SET tag), nil when the content is signed directly.
    var signedAttributes: [UInt8]?
    var messageDigest: [UInt8]?
    var signingTime: Date?
    /// The ESS signing-certificate-v2 hash, when present.
    var signingCertificateHash: [UInt8]?
    /// Encapsulated content (adbe.pkcs7.sha1 puts the document's SHA-1 here).
    var content: [UInt8]?

    /// Parses DER or BER; trailing bytes (the zero padding of /Contents) are ignored.
    init(_ bytes: Data) throws {
        let raw = [UInt8](bytes)
        guard let length = Self.encodedLength(raw) else { throw CMSError.malformed("length") }
        let root = try BER.parse(raw[0..<length])
        guard case .constructed(let contentInfo) = root.content else { throw CMSError.malformed("content info") }
        var nodes = contentInfo.makeIterator()
        guard let type = nodes.next(), (try? ASN1ObjectIdentifier(berEncoded: type)) == OID.signedData,
              let explicit = nodes.next(), case .constructed(let wrapped) = explicit.content,
              let signedData = wrapped.first(where: { _ in true }), case .constructed(let fieldsCollection) = signedData.content
        else { throw CMSError.malformed("not SignedData") }
        let fields = Array(fieldsCollection)
        guard fields.count >= 4 else { throw CMSError.malformed("SignedData fields") }

        // encapContentInfo
        content = nil
        if case .constructed(let encap) = fields[2].content {
            let parts = Array(encap)
            if parts.count > 1, case .constructed(let inner) = parts[1].content, let octets = inner.first(where: { _ in true }) {
                content = Self.octets(octets)
            }
        }

        // certificates [0] IMPLICIT, optional; crls [1] skipped; the last field is signerInfos.
        var certificates: [Data] = []
        for field in fields[3...] where field.identifier == ASN1Identifier(tagWithNumber: 0, tagClass: .contextSpecific) {
            if case .constructed(let certs) = field.content {
                for cert in certs where cert.identifier == .sequence { certificates.append(Data(cert.encodedBytes)) }
            }
        }
        self.certificates = certificates

        guard let signerInfos = fields.last, case .constructed(let infos) = signerInfos.content,
              let first = infos.first(where: { _ in true }), case .constructed(let infoCollection) = first.content
        else { throw CMSError.malformed("no SignerInfo") }
        let info = Array(infoCollection)
        guard info.count >= 5 else { throw CMSError.malformed("SignerInfo fields") }
        let sid = info[1]
        digestAlgorithm = Self.algorithm(info[2]).flatMap(DigestAlgorithm.init)
        var index = 3
        signedAttributes = nil
        messageDigest = nil
        signingTime = nil
        signingCertificateHash = nil
        if info[index].identifier == ASN1Identifier(tagWithNumber: 0, tagClass: .contextSpecific) {
            var der = Array(info[index].encodedBytes)
            der[0] = 0x31
            signedAttributes = der
            if case .constructed(let attributes) = info[index].content {
                for attribute in attributes {
                    guard case .constructed(let parts) = attribute.content else { continue }
                    var it = parts.makeIterator()
                    guard let typeNode = it.next(), let oid = try? ASN1ObjectIdentifier(berEncoded: typeNode),
                          let values = it.next(), case .constructed(let valueSet) = values.content,
                          let value = valueSet.first(where: { _ in true }) else { continue }
                    switch oid {
                    case OID.messageDigest: messageDigest = Self.octets(value)
                    case OID.signingTime: signingTime = Self.time(value)
                    case OID.signingCertificateV2: signingCertificateHash = Self.essHash(value)
                    default: break
                    }
                }
            }
            index += 1
        }
        guard index + 1 < info.count else { throw CMSError.malformed("SignerInfo signature") }
        let signatureAlgorithmNode = info[index]
        signatureAlgorithm = Self.algorithm(signatureAlgorithmNode) ?? OID.rsaEncryption
        pssDigest = signatureAlgorithm == OID.rsaPSS ? Self.pssHash(signatureAlgorithmNode) : nil
        signature = Self.octets(info[index + 1]) ?? []

        signer = Self.findSigner(sid, in: certificates)
    }

    // MARK: Helpers

    /// The length of the outer TLV (definite lengths; an indefinite one takes the whole buffer).
    static func encodedLength(_ bytes: [UInt8]) -> Int? {
        guard bytes.count >= 2, bytes[0] == 0x30 else { return nil }
        let first = bytes[1]
        if first < 0x80 { return min(bytes.count, 2 + Int(first)) }
        if first == 0x80 { return bytes.count }
        let count = Int(first & 0x7F)
        guard count <= 4, bytes.count >= 2 + count else { return nil }
        let length = bytes[2..<(2 + count)].reduce(0) { $0 << 8 | Int($1) }
        return min(bytes.count, 2 + count + length)
    }

    private static func algorithm(_ node: ASN1Node) -> ASN1ObjectIdentifier? {
        guard case .constructed(let parts) = node.content, let first = parts.first(where: { _ in true }) else { return nil }
        return try? ASN1ObjectIdentifier(berEncoded: first)
    }

    /// RSASSA-PSS-params' hashAlgorithm ([0] EXPLICIT AlgorithmIdentifier; SHA-1 when absent).
    private static func pssHash(_ node: ASN1Node) -> DigestAlgorithm? {
        guard case .constructed(let parts) = node.content else { return .sha1 }
        let all = Array(parts)
        guard all.count > 1, case .constructed(let params) = all[1].content else { return .sha1 }
        for param in params where param.identifier == ASN1Identifier(tagWithNumber: 0, tagClass: .contextSpecific) {
            if case .constructed(let inner) = param.content, let algorithm = inner.first(where: { _ in true }) {
                return Self.algorithm(algorithm).flatMap(DigestAlgorithm.init)
            }
        }
        return .sha1
    }

    /// An OCTET STRING's bytes, primitive or constructed (BER).
    static func octets(_ node: ASN1Node) -> [UInt8]? {
        switch node.content {
        case .primitive(let bytes): return Array(bytes)
        case .constructed(let parts): return parts.compactMap { octets($0) }.flatMap { $0 }
        }
    }

    private static func time(_ node: ASN1Node) -> Date? {
        if let utc = try? UTCTime(derEncoded: node) {
            return DateComponents(calendar: Calendar(identifier: .gregorian), timeZone: TimeZone(identifier: "UTC"), year: utc.year,
                                  month: utc.month, day: utc.day, hour: utc.hours, minute: utc.minutes, second: utc.seconds).date
        }
        if let general = try? GeneralizedTime(derEncoded: node) {
            return DateComponents(calendar: Calendar(identifier: .gregorian), timeZone: TimeZone(identifier: "UTC"), year: general.year,
                                  month: general.month, day: general.day, hour: general.hours, minute: general.minutes,
                                  second: general.seconds).date
        }
        return nil
    }

    private static func essHash(_ node: ASN1Node) -> [UInt8]? {
        // SigningCertificateV2 { certs SEQUENCE OF ESSCertIDv2 { [hashAlgorithm], certHash OCTET STRING, … } }
        guard case .constructed(let top) = node.content, let certs = top.first(where: { _ in true }),
              case .constructed(let list) = certs.content, let first = list.first(where: { _ in true }),
              case .constructed(let id) = first.content else { return nil }
        for part in id where part.identifier == .octetString { return octets(part) }
        return nil
    }

    private static func findSigner(_ sid: ASN1Node, in certificates: [Data]) -> Data? {
        if sid.identifier == .sequence, case .constructed(let parts) = sid.content {
            // IssuerAndSerialNumber: compare the encodings.
            let all = Array(parts)
            guard all.count == 2 else { return certificates.first }
            let issuer = Array(all[0].encodedBytes), serial = Array(all[1].encodedBytes)
            return certificates.first { cert in
                guard let fields = try? CertificateFields(der: [UInt8](cert)) else { return false }
                return fields.issuer == issuer && fields.serialNumber == serial
            } ?? certificates.first
        }
        // [0] SubjectKeyIdentifier
        if let keyID = octets(sid) {
            for der in certificates {
                guard let cert = try? Certificate(derEncoded: [UInt8](der)),
                      let ski = try? cert.extensions.subjectKeyIdentifier else { continue }
                if Array(ski.keyIdentifier) == keyID { return der }
            }
        }
        return certificates.first
    }
}

// MARK: - Checking the signature value

enum SignatureMaths {
    /// Whether `signature` is `certificate`'s key signing `message` with `algorithm` (Security.framework, so every
    /// key size and curve the system knows works).
    static func isValid(_ signature: [UInt8], message: Data, algorithm: ASN1ObjectIdentifier, digest: DigestAlgorithm?,
                        pssDigest: DigestAlgorithm?, certificate: Data) -> Bool {
        guard let cert = SecCertificateCreateWithData(nil, certificate as CFData), let key = SecCertificateCopyKey(cert),
              let secAlgorithm = secAlgorithm(algorithm, digest: digest, pssDigest: pssDigest) else { return false }
        return SecKeyVerifySignature(key, secAlgorithm, message as CFData, Data(signature) as CFData, nil)
    }

    private static func secAlgorithm(_ oid: ASN1ObjectIdentifier, digest: DigestAlgorithm?, pssDigest: DigestAlgorithm?) -> SecKeyAlgorithm? {
        switch oid {
        case OID.sha1WithRSA: return .rsaSignatureMessagePKCS1v15SHA1
        case OID.sha256WithRSA: return .rsaSignatureMessagePKCS1v15SHA256
        case OID.sha384WithRSA: return .rsaSignatureMessagePKCS1v15SHA384
        case OID.sha512WithRSA: return .rsaSignatureMessagePKCS1v15SHA512
        case OID.ecdsaWithSHA256: return .ecdsaSignatureMessageX962SHA256
        case OID.ecdsaWithSHA384: return .ecdsaSignatureMessageX962SHA384
        case OID.ecdsaWithSHA512: return .ecdsaSignatureMessageX962SHA512
        case OID.rsaEncryption:
            // Acrobat and others name the key type and leave the hash to digestAlgorithm.
            switch digest {
            case .sha1: return .rsaSignatureMessagePKCS1v15SHA1
            case .sha256: return .rsaSignatureMessagePKCS1v15SHA256
            case .sha384: return .rsaSignatureMessagePKCS1v15SHA384
            case .sha512: return .rsaSignatureMessagePKCS1v15SHA512
            case nil: return nil
            }
        case OID.ecPublicKey:
            switch digest {
            case .sha1: return .ecdsaSignatureMessageX962SHA1
            case .sha256: return .ecdsaSignatureMessageX962SHA256
            case .sha384: return .ecdsaSignatureMessageX962SHA384
            case .sha512: return .ecdsaSignatureMessageX962SHA512
            case nil: return nil
            }
        case OID.rsaPSS:
            switch pssDigest {
            case .sha1: return .rsaSignatureMessagePSSSHA1
            case .sha256: return .rsaSignatureMessagePSSSHA256
            case .sha384: return .rsaSignatureMessagePSSSHA384
            case .sha512: return .rsaSignatureMessagePSSSHA512
            case nil: return nil
            }
        default:
            return nil
        }
    }
}
