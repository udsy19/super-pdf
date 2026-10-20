import CommonCrypto
import CryptoKit
import Foundation
import PDFModelKit
import Security
import SuperPDFCore

// Encrypt with certificate (features #89): public-key security (ISO 32000-2 §7.6.5, /Filter /Adobe.PubSec, SubFilter
// adbe.pkcs7.s5, AES-256 crypt filter). A random 20-byte seed plus the permission bytes is wrapped for each recipient
// in a CMS EnvelopedData (our own DER: RSA key transport to the recipient's certificate, AES-256-CBC content); the
// file key is SHA-256 of the seed and every recipient blob. QPDF writes only password security, so the encrypted file
// is written here: QPDF first rewrites the document with every object at the top level and no encryption, then each
// object is written with its strings and stream data encrypted (AES-256-CBC, random IV), followed by the
// cross-reference table and a trailer naming the /Encrypt dictionary.

enum CertificateEncryption {
    static func encrypt(_ source: PDFSource, recipients certificates: [Data]) throws -> Data {
        guard !certificates.isEmpty else { throw PDFModelError.invalidOperation("no recipients") }
        let model = try PDFModel(source)
        try ProtectionRules.requireOwner(model)
        let plain = try model.data(options: PDFWriteOptions(objectStreams: .disable, compressStreams: true, encryption: .remove))
        let flat = try PDFModel(data: plain)

        let seed = randomBytes(20)
        // All permissions, most significant byte first.
        let permissions: [UInt8] = [0xFF, 0xFF, 0xFF, 0xFF]
        let recipients = try certificates.map { try CMSEnvelope.make(Data(seed + permissions), for: $0) }
        var digest = SHA256()
        digest.update(data: Data(seed))
        for recipient in recipients { digest.update(data: recipient) }
        let key = Array(digest.finalize())
        return try write(flat, key: key, recipients: recipients)
    }

    // MARK: - Writing

    private static func write(_ model: PDFModel, key: [UInt8], recipients: [Data]) throws -> Data {
        let size = max(model.trailer["Size"]?.int ?? 1, 1)
        var out = Data("%PDF-1.7\n%\u{E2}\u{E3}\u{CF}\u{D3}\n".utf8)
        var offsets = [Int?](repeating: nil, count: size + 1)
        for id in 1..<size {
            let object = model.object(id: id)
            guard !object.isNull else { continue }
            offsets[id] = out.count
            out.append(Data("\(id) 0 obj\n".utf8))
            if object.type == .stream {
                var dictionary = object.value.dictionaryValue ?? [:]
                let data = aes(try object.streamData(decode: .none), key: key)
                dictionary["Length"] = .integer(data.count)
                encryptStrings(.dictionary(dictionary), key: key).write(into: &out)
                out.append(Data("\nstream\n".utf8))
                out.append(data)
                out.append(Data("\nendstream".utf8))
            } else {
                encryptStrings(object.value, key: key).write(into: &out)
            }
            out.append(Data("\nendobj\n".utf8))
        }
        let encryptID = size
        offsets[encryptID] = out.count
        let filter: PDFValue = .dictionary([
            "Type": .name("CryptFilter"), "CFM": .name("AESV3"), "Length": .integer(256), "EncryptMetadata": .bool(true),
            "Recipients": .array(recipients.map { .string($0) }),
        ])
        let encrypt: PDFValue = .dictionary([
            "Filter": .name("Adobe.PubSec"), "SubFilter": .name("adbe.pkcs7.s5"), "V": .integer(5), "Length": .integer(256),
            "CF": .dictionary(["DefaultCryptFilter": filter]),
            "StmF": .name("DefaultCryptFilter"), "StrF": .name("DefaultCryptFilter"),
        ])
        out.append(Data("\(encryptID) 0 obj\n".utf8))
        encrypt.write(into: &out)
        out.append(Data("\nendobj\n".utf8))

        let xref = out.count
        out.append(Data("xref\n0 \(size + 1)\n0000000000 65535 f\r\n".utf8))
        for id in 1...size {
            if let offset = offsets[id] { out.append(Data(String(format: "%010d 00000 n\r\n", offset).utf8)) }
            else { out.append(Data("0000000000 00000 f\r\n".utf8)) }
        }
        var trailer: [String: PDFValue] = ["Size": .integer(size + 1), "Encrypt": .reference(encryptID, 0)]
        if let root = model.trailer["Root"]?.reference { trailer["Root"] = root }
        if let info = model.trailer["Info"]?.reference { trailer["Info"] = info }
        let id = model.trailer["ID"]?.value ?? .array([.string(Data(randomBytes(16))), .string(Data(randomBytes(16)))])
        trailer["ID"] = id
        out.append(Data("trailer\n".utf8))
        PDFValue.dictionary(trailer).write(into: &out)
        out.append(Data("\nstartxref\n\(xref)\n%%EOF\n".utf8))
        return out
    }

    private static func encryptStrings(_ value: PDFValue, key: [UInt8]) -> PDFValue {
        switch value {
        case .string(let bytes): .string(aes(bytes, key: key))
        case .array(let items): .array(items.map { encryptStrings($0, key: key) })
        case .dictionary(let dict): .dictionary(dict.mapValues { encryptStrings($0, key: key) })
        default: value
        }
    }

    /// AES-256-CBC with PKCS#7 padding, the random IV first (ISO 32000-2 §7.6.3, AESV3).
    static func aes(_ data: Data, key: [UInt8]) -> Data {
        let iv = randomBytes(16)
        return Data(iv) + crypt(data, key: key, iv: iv)
    }

    static func crypt(_ data: Data, key: [UInt8], iv: [UInt8]) -> Data {
        var output = [UInt8](repeating: 0, count: data.count + kCCBlockSizeAES128)
        var moved = 0
        let input = [UInt8](data)
        _ = CCCrypt(CCOperation(kCCEncrypt), CCAlgorithm(kCCAlgorithmAES), CCOptions(kCCOptionPKCS7Padding), key, key.count, iv,
                    input, input.count, &output, output.count, &moved)
        return Data(output.prefix(moved))
    }

    static func randomBytes(_ count: Int) -> [UInt8] {
        var bytes = [UInt8](repeating: 0, count: count)
        _ = SecRandomCopyBytes(kSecRandomDefault, count, &bytes)
        return bytes
    }
}

/// CMS (PKCS #7) EnvelopedData for one recipient certificate, written in DER (RFC 5652 §6).
enum CMSEnvelope {
    static func make(_ content: Data, for certificateDER: Data) throws -> Data {
        guard let certificate = SecCertificateCreateWithData(nil, certificateDER as CFData),
              let publicKey = SecCertificateCopyKey(certificate),
              SecKeyIsAlgorithmSupported(publicKey, .encrypt, .rsaEncryptionPKCS1),
              let (issuer, serial) = DER.issuerAndSerial(certificateDER) else {
            throw ToolError(ProtectStrings.certificateUnusable)
        }
        let contentKey = CertificateEncryption.randomBytes(32)
        var error: Unmanaged<CFError>?
        guard let wrapped = SecKeyCreateEncryptedData(publicKey, .rsaEncryptionPKCS1, Data(contentKey) as CFData, &error) as Data? else {
            throw ToolError(ProtectStrings.certificateUnusable)
        }
        let iv = CertificateEncryption.randomBytes(16)
        let encrypted = CertificateEncryption.crypt(content, key: contentKey, iv: iv)

        let recipient = DER.sequence([
            DER.integer(0),
            DER.sequence([issuer, serial]),
            DER.sequence([DER.oid([1, 2, 840, 113549, 1, 1, 1]), DER.null]),
            DER.octetString(wrapped),
        ])
        let encryptedContentInfo = DER.sequence([
            DER.oid([1, 2, 840, 113549, 1, 7, 1]),
            DER.sequence([DER.oid([2, 16, 840, 1, 101, 3, 4, 1, 42]), DER.octetString(Data(iv))]),
            DER.tagged(0x80, encrypted),
        ])
        let enveloped = DER.sequence([DER.integer(0), DER.set([recipient]), encryptedContentInfo])
        return DER.sequence([DER.oid([1, 2, 840, 113549, 1, 7, 3]), DER.tagged(0xA0, enveloped)])
    }
}

/// The few DER pieces CMS needs, and a reader for a certificate's issuer and serial number.
enum DER {
    static func tagged(_ tag: UInt8, _ content: Data) -> Data { Data([tag]) + length(content.count) + content }
    static func sequence(_ items: [Data]) -> Data { tagged(0x30, items.reduce(Data(), +)) }
    static func set(_ items: [Data]) -> Data { tagged(0x31, items.sorted { $0.lexicographicallyPrecedes($1) }.reduce(Data(), +)) }
    static func integer(_ value: Int) -> Data { tagged(0x02, Data([UInt8(value)])) }
    static func octetString(_ data: Data) -> Data { tagged(0x04, data) }
    static let null = Data([0x05, 0x00])

    static func oid(_ arcs: [UInt]) -> Data {
        var body = Data([UInt8(arcs[0] * 40 + arcs[1])])
        for arc in arcs.dropFirst(2) {
            var chunk: [UInt8] = [UInt8(arc & 0x7F)]
            var rest = arc >> 7
            while rest > 0 { chunk.insert(UInt8(rest & 0x7F) | 0x80, at: 0); rest >>= 7 }
            body.append(contentsOf: chunk)
        }
        return tagged(0x06, body)
    }

    static func length(_ count: Int) -> Data {
        if count < 0x80 { return Data([UInt8(count)]) }
        var bytes: [UInt8] = []
        var rest = count
        while rest > 0 { bytes.insert(UInt8(rest & 0xFF), at: 0); rest >>= 8 }
        return Data([0x80 | UInt8(bytes.count)] + bytes)
    }

    /// One element at `offset`: its tag, where its content starts and ends.
    static func element(_ bytes: [UInt8], at offset: Int) -> (tag: UInt8, start: Int, end: Int)? {
        guard offset + 1 < bytes.count else { return nil }
        var i = offset + 1
        var count = Int(bytes[i]); i += 1
        if count & 0x80 != 0 {
            let n = count & 0x7F
            guard n > 0, n <= 4, i + n <= bytes.count else { return nil }
            count = bytes[i..<(i + n)].reduce(0) { ($0 << 8) | Int($1) }
            i += n
        }
        guard i + count <= bytes.count else { return nil }
        return (bytes[offset], i, i + count)
    }

    /// The issuer Name and serialNumber INTEGER of an X.509 certificate, as their full DER encodings.
    static func issuerAndSerial(_ certificate: Data) -> (issuer: Data, serial: Data)? {
        let bytes = [UInt8](certificate)
        guard let cert = element(bytes, at: 0), cert.tag == 0x30,
              let tbs = element(bytes, at: cert.start), tbs.tag == 0x30 else { return nil }
        var cursor = tbs.start
        guard var item = element(bytes, at: cursor) else { return nil }
        if item.tag == 0xA0 { cursor = item.end; guard let next = element(bytes, at: cursor) else { return nil }; item = next }
        guard item.tag == 0x02 else { return nil }
        let serial = Data(bytes[cursor..<item.end])
        cursor = item.end
        guard let algorithm = element(bytes, at: cursor) else { return nil }
        cursor = algorithm.end
        guard let issuer = element(bytes, at: cursor), issuer.tag == 0x30 else { return nil }
        return (Data(bytes[cursor..<issuer.end]), serial)
    }
}
