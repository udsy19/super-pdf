import Foundation
import Security
import SuperPDFCore
import SwiftASN1
import X509

// Signing identities (features #85, §3.6): a certificate with its private key. "Create my certificate…" makes a
// self-signed X.509 for 10 years with swift-certificates over a P-256 key from `SecKeyCreateRandomKey`; a `.p12` brings
// one from elsewhere. Where they live is a `SigningKeyStore`: the login Keychain in the app, memory in the self-test
// (which never touches the person's Keychain).

/// Where signing keys and their certificates are kept.
public protocol SigningKeyStore: AnyObject {
    /// A new P-256 private key, kept where this store keeps keys.
    func makePrivateKey(label: String) throws -> SecKey
    /// Keeps `certificate` (DER) for a key made by `makePrivateKey`; returns the identity's id.
    func add(certificate: Data, key: SecKey, label: String) throws -> String
    /// Imports a PKCS #12 file; returns the identity's id.
    func importPKCS12(_ data: Data, password: String) throws -> String
    /// The identities this app made or imported, with their certificates (DER).
    func all() -> [(id: String, certificate: Data)]
    func privateKey(of id: String) throws -> SecKey
}

public enum SigningKeyError: LocalizedError, Equatable {
    case keychain(OSStatus)
    case notFound
    case wrongPassword
    case noIdentity

    public var errorDescription: String? {
        switch self {
        case .keychain(let status): (SecCopyErrorMessageString(status, nil) as String?) ?? "Keychain error \(status)."
        case .notFound: "The certificate isn’t on this Mac any more."
        case .wrongPassword: SignStrings.wrongP12Password
        case .noIdentity: SignStrings.noIdentityInP12
        }
    }
}

/// The login Keychain. Keys are permanent items labelled "Super PDF – <name>"; the identities this app made or
/// imported are listed by persistent reference in `signKit.identities`, so others in the Keychain are left alone.
public final class KeychainSigningKeyStore: SigningKeyStore {
    public init() {}

    private static let index = Defaults.Key<[String]>("signKit.identities", default: [])

    public func makePrivateKey(label: String) throws -> SecKey {
        var error: Unmanaged<CFError>?
        let attributes: [String: Any] = [
            kSecAttrKeyType as String: kSecAttrKeyTypeECSECPrimeRandom,
            kSecAttrKeySizeInBits as String: 256,
            kSecPrivateKeyAttrs as String: [kSecAttrIsPermanent as String: true, kSecAttrLabel as String: label],
        ]
        guard let key = SecKeyCreateRandomKey(attributes as CFDictionary, &error) else {
            throw error.map { $0.takeRetainedValue() as Error } ?? SigningKeyError.keychain(errSecParam)
        }
        return key
    }

    public func add(certificate: Data, key: SecKey, label: String) throws -> String {
        guard let cert = SecCertificateCreateWithData(nil, certificate as CFData) else { throw SigningKeyError.noIdentity }
        let status = SecItemAdd([kSecValueRef as String: cert, kSecAttrLabel as String: label] as CFDictionary, nil)
        guard status == errSecSuccess || status == errSecDuplicateItem else { throw SigningKeyError.keychain(status) }
        return try remember(certificate)
    }

    public func importPKCS12(_ data: Data, password: String) throws -> String {
        var items: CFArray?
        let status = SecPKCS12Import(data as CFData, [kSecImportExportPassphrase as String: password] as CFDictionary, &items)
        if status == errSecAuthFailed || status == errSecPkcs12VerifyFailure { throw SigningKeyError.wrongPassword }
        guard status == errSecSuccess, let first = (items as? [[String: Any]])?.first,
              let identity = first[kSecImportItemIdentity as String] else { throw SigningKeyError.noIdentity }
        var cert: SecCertificate?
        SecIdentityCopyCertificate(identity as! SecIdentity, &cert)
        guard let cert else { throw SigningKeyError.noIdentity }
        // macOS imports into the login Keychain; adding again is harmless.
        let add = SecItemAdd([kSecValueRef as String: identity] as CFDictionary, nil)
        guard add == errSecSuccess || add == errSecDuplicateItem else { throw SigningKeyError.keychain(add) }
        return try remember(SecCertificateCopyData(cert) as Data)
    }

    public func all() -> [(id: String, certificate: Data)] {
        Defaults[Self.index].compactMap { id in
            guard let identity = try? identity(id) else { return nil }
            var cert: SecCertificate?
            SecIdentityCopyCertificate(identity, &cert)
            return cert.map { (id, SecCertificateCopyData($0) as Data) }
        }
    }

    public func privateKey(of id: String) throws -> SecKey {
        var key: SecKey?
        let status = SecIdentityCopyPrivateKey(try identity(id), &key)
        guard status == errSecSuccess, let key else { throw SigningKeyError.keychain(status) }
        return key
    }

    /// Finds the identity of `certificate` and adds its persistent reference (hex) to the index.
    private func remember(_ certificate: Data) throws -> String {
        var result: CFTypeRef?
        let status = SecItemCopyMatching([
            kSecClass as String: kSecClassIdentity, kSecReturnRef as String: true, kSecReturnPersistentRef as String: true,
            kSecMatchLimit as String: kSecMatchLimitAll,
        ] as CFDictionary, &result)
        guard status == errSecSuccess, let rows = result as? [[String: Any]] else { throw SigningKeyError.keychain(status) }
        for row in rows {
            guard let ref = row[kSecValuePersistentRef as String] as? Data, let identity = row[kSecValueRef as String] else { continue }
            var cert: SecCertificate?
            SecIdentityCopyCertificate(identity as! SecIdentity, &cert)
            guard let cert, SecCertificateCopyData(cert) as Data == certificate else { continue }
            let id = ref.map { String(format: "%02x", $0) }.joined()
            if !Defaults[Self.index].contains(id) { Defaults[Self.index].append(id) }
            return id
        }
        throw SigningKeyError.notFound
    }

    private func identity(_ id: String) throws -> SecIdentity {
        guard let ref = Data(hex: id) else { throw SigningKeyError.notFound }
        var result: CFTypeRef?
        let status = SecItemCopyMatching([kSecValuePersistentRef as String: ref, kSecReturnRef as String: true] as CFDictionary, &result)
        guard status == errSecSuccess, let result, CFGetTypeID(result) == SecIdentityGetTypeID() else { throw SigningKeyError.notFound }
        return result as! SecIdentity
    }
}

/// Keys that live only as long as the process (the self-test; never the person's Keychain).
public final class MemorySigningKeyStore: SigningKeyStore {
    private var entries: [(id: String, certificate: Data, key: SecKey)] = []

    public init() {}

    public func makePrivateKey(label: String) throws -> SecKey {
        var error: Unmanaged<CFError>?
        let attributes: [String: Any] = [kSecAttrKeyType as String: kSecAttrKeyTypeECSECPrimeRandom, kSecAttrKeySizeInBits as String: 256]
        guard let key = SecKeyCreateRandomKey(attributes as CFDictionary, &error) else {
            throw error.map { $0.takeRetainedValue() as Error } ?? SigningKeyError.keychain(errSecParam)
        }
        return key
    }

    public func add(certificate: Data, key: SecKey, label: String) throws -> String {
        let id = UUID().uuidString.lowercased()
        entries.append((id, certificate, key))
        return id
    }

    public func importPKCS12(_ data: Data, password: String) throws -> String {
        var items: CFArray?
        var options: [String: Any] = [kSecImportExportPassphrase as String: password]
        if #available(macOS 15, *) { options[kSecImportToMemoryOnly as String] = true } else { throw SigningKeyError.noIdentity }
        let status = SecPKCS12Import(data as CFData, options as CFDictionary, &items)
        if status == errSecAuthFailed || status == errSecPkcs12VerifyFailure { throw SigningKeyError.wrongPassword }
        guard status == errSecSuccess, let first = (items as? [[String: Any]])?.first,
              let identity = first[kSecImportItemIdentity as String] else { throw SigningKeyError.noIdentity }
        var cert: SecCertificate?
        var key: SecKey?
        SecIdentityCopyCertificate(identity as! SecIdentity, &cert)
        SecIdentityCopyPrivateKey(identity as! SecIdentity, &key)
        guard let cert, let key else { throw SigningKeyError.noIdentity }
        return try add(certificate: SecCertificateCopyData(cert) as Data, key: key, label: "")
    }

    public func all() -> [(id: String, certificate: Data)] { entries.map { ($0.id, $0.certificate) } }

    public func privateKey(of id: String) throws -> SecKey {
        guard let entry = entries.first(where: { $0.id == id }) else { throw SigningKeyError.notFound }
        return entry.key
    }
}

// MARK: - Certificates

enum Certificates {
    /// A self-signed signing certificate for `name` (features #85): 10 years, digital signature and non-repudiation.
    static func makeSelfSigned(name: String, email: String?, key: SecKey, now: Date = Date()) throws -> Data {
        let privateKey = try Certificate.PrivateKey(key)
        let subject = try DistinguishedName {
            CommonName(name)
            if let email, !email.isEmpty { EmailAddress(email) }
        }
        let extensions = try Certificate.Extensions {
            Critical(BasicConstraints.notCertificateAuthority)
            Critical(KeyUsage(digitalSignature: true, nonRepudiation: true))
            SubjectKeyIdentifier(hash: privateKey.publicKey)
            if let email, !email.isEmpty { SubjectAlternativeNames([.rfc822Name(email)]) }
        }
        let certificate = try Certificate(
            version: .v3, serialNumber: Certificate.SerialNumber(), publicKey: privateKey.publicKey,
            notValidBefore: now.addingTimeInterval(-300), notValidAfter: Calendar(identifier: .gregorian).date(byAdding: .year, value: 10, to: now)!,
            issuer: subject, subject: subject, signatureAlgorithm: .ecdsaWithSHA256, extensions: extensions, issuerPrivateKey: privateKey)
        var coder = DER.Serializer()
        try coder.serialize(certificate)
        return Data(coder.serializedBytes)
    }

    /// What the panels show of a certificate.
    static func summary(_ der: Data, id: String) -> SigningIdentity? {
        guard let certificate = try? Certificate(derEncoded: [UInt8](der)) else { return nil }
        return SigningIdentity(id: id, commonName: commonName(certificate.subject) ?? SignStrings.unnamed, email: email(certificate),
                               issuer: commonName(certificate.issuer) ?? SignStrings.unnamed, notAfter: certificate.notValidAfter,
                               isSelfSigned: certificate.subject == certificate.issuer)
    }

    static func commonName(_ name: DistinguishedName) -> String? {
        for rdn in name { for attribute in rdn where attribute.type == .RDNAttributeType.commonName { return text(attribute.value) } }
        for rdn in name { for attribute in rdn where attribute.type == .RDNAttributeType.organizationName { return text(attribute.value) } }
        return nil
    }

    static func email(_ certificate: Certificate) -> String? {
        if let names = try? certificate.extensions.subjectAlternativeNames {
            for name in names { if case .rfc822Name(let email) = name { return email } }
        }
        for rdn in certificate.subject {
            for attribute in rdn where attribute.type == .RDNAttributeType.emailAddress { return text(attribute.value) }
        }
        return nil
    }

    private static func text(_ value: RelativeDistinguishedName.Attribute.Value) -> String? {
        String(value).flatMap { $0.isEmpty ? nil : $0 }
    }

    /// The common name of a DER certificate, for lists.
    static func commonName(of der: Data) -> String? {
        (try? Certificate(derEncoded: [UInt8](der))).flatMap { commonName($0.subject) }
    }

    /// SHA-256 of the DER, hex: the id of a trusted certificate.
    static func fingerprint(_ der: Data) -> String {
        DigestAlgorithm.sha256.hash(der).map { String(format: "%02x", $0) }.joined()
    }

    /// DER from a `.cer`/`.crt`/`.pem` file's bytes.
    static func der(fromFile data: Data) -> Data? {
        if let text = String(data: data, encoding: .utf8), text.contains("-----BEGIN CERTIFICATE-----") {
            let body = text.components(separatedBy: "-----BEGIN CERTIFICATE-----").dropFirst().first?
                .components(separatedBy: "-----END CERTIFICATE-----").first?
                .components(separatedBy: .whitespacesAndNewlines).joined()
            return body.flatMap { Data(base64Encoded: $0) }
        }
        return (try? Certificate(derEncoded: [UInt8](data))) != nil ? data : nil
    }
}

extension Data {
    /// Bytes from a hex string; nil when it isn't one.
    init?(hex: String) {
        guard hex.count % 2 == 0 else { return nil }
        var bytes = [UInt8]()
        bytes.reserveCapacity(hex.count / 2)
        var index = hex.startIndex
        while index < hex.endIndex {
            let next = hex.index(index, offsetBy: 2)
            guard let byte = UInt8(hex[index..<next], radix: 16) else { return nil }
            bytes.append(byte)
            index = next
        }
        self.init(bytes)
    }
}
