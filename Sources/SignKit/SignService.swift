import Foundation
import PDFModelKit
import Security
import SuperPDFCore

/// `Services.sign` (features #82, #83, #85): the signature library, signing identities, signing and verification, and
/// "People I trust".
@MainActor
public final class SignService: Signing {
    let library: SignatureStore
    let keys: SigningKeyStore
    /// Sends RFC 3161 requests (features §3.5 item 4); nil uses URLSession. The self-test answers them itself.
    var timestampTransport: (@Sendable (URLRequest) async throws -> Data)?

    private static let trustedKey = Defaults.Key<[TrustedCertificate]>("signKit.trusted", default: [])

    public init(keys: SigningKeyStore, signatureKey: SignatureKeyProvider, signaturesFolder: URL) {
        self.keys = keys
        library = SignatureStore(folder: signaturesFolder, keys: signatureKey)
    }

    // MARK: Library

    public var savedSignatures: [SavedSignature] { library.all }
    public func save(_ signature: SavedSignature) throws { try library.save(signature) }
    public func delete(_ id: UUID) throws { try library.delete(id) }

    /// The in-place placement other tools use: MarkupKit's stamp with an appearance stream, undoable.
    public func place(_ signature: SavedSignature, on page: Int, in rect: CGRect, document: DocumentHandle) throws -> UndoGroup {
        try Services.markup.addStamp(signature.image, on: page, in: rect, in: document)
    }

    // MARK: Identities

    public var identities: [SigningIdentity] {
        keys.all().compactMap { Certificates.summary($0.certificate, id: $0.id) }
    }

    public func createIdentity(name: String, email: String?) async throws -> SigningIdentity {
        let label = "Super PDF – " + name
        let key = try keys.makePrivateKey(label: label)
        let der = try Certificates.makeSelfSigned(name: name, email: email, key: key)
        let id = try keys.add(certificate: der, key: key, label: label)
        if Defaults[.defaultCertificateID] == nil { Defaults[.defaultCertificateID] = id }
        guard let identity = Certificates.summary(der, id: id) else { throw SigningKeyError.notFound }
        return identity
    }

    public func importIdentity(p12: URL, password: String) async throws -> SigningIdentity {
        let id = try keys.importPKCS12(try Data(contentsOf: p12), password: password)
        guard let identity = identities.first(where: { $0.id == id }) else { throw SigningKeyError.notFound }
        return identity
    }

    /// The public certificate (DER, `.cer`) to send to people who check the signatures.
    public func exportCertificate(of identityID: String, to destination: URL) throws {
        guard let entry = keys.all().first(where: { $0.id == identityID }) else { throw SigningKeyError.notFound }
        try entry.certificate.write(to: destination, options: .atomic)
    }

    /// The identity "Sign with a certificate" proposes: the remembered one, else the first.
    var preferredIdentity: SigningIdentity? {
        let all = identities
        return all.first { $0.id == Defaults[.defaultCertificateID] } ?? all.first
    }

    // MARK: Signing

    public func sign(_ source: PDFSource, options: CertificateSignOptions, to destination: URL) async throws {
        let data = try await signedCopy(source, marks: [], certificate: options, handwriting: nil)
        try data.write(to: destination, options: .atomic)
    }

    /// The signed copy: placed marks as stamps, then the certificate signature (with the person's handwriting in its box
    /// when they chose one).
    func signedCopy(_ source: PDFSource, marks: [PlacedMark], certificate options: CertificateSignOptions?, handwriting: Data?) async throws -> Data {
        var job: CertificateJob?
        if let options {
            guard let entry = keys.all().first(where: { $0.id == options.identityID }),
                  let identity = Certificates.summary(entry.certificate, id: entry.id) else { throw SigningKeyError.notFound }
            let now = Date()
            job = CertificateJob(certificate: entry.certificate, chain: [], key: try keys.privateKey(of: entry.id), page: options.page,
                                 rect: options.rect,
                                 appearance: SealAppearance(image: handwriting, name: identity.commonName, date: now, reason: options.reason,
                                                            location: options.location),
                                 reason: options.reason, location: options.location, lockDocument: options.lockDocument, signingTime: now,
                                 timestamp: options.timestampServer.map { TimestampClient(server: $0, transport: timestampTransport) })
        }
        let finalJob = job
        return try await Task.detached(priority: .userInitiated) {
            try await PDFSigner.sign(source, marks: marks, certificate: finalJob)
        }.value
    }

    // MARK: Verification

    public func verify(_ source: PDFSource) async throws -> [SignatureReport] {
        let anchors = trustedCertificates.map(\.der) + keys.all().map(\.certificate)
        return try await Task.detached(priority: .userInitiated) {
            try SignatureVerifier.verify(try source.bytes(), password: source.password, anchors: anchors)
        }.value
    }

    public var trustedCertificates: [TrustedCertificate] { Defaults[Self.trustedKey] }

    public func trust(_ certificate: Data) throws -> TrustedCertificate {
        let der = Certificates.der(fromFile: certificate) ?? certificate
        guard let name = Certificates.commonName(of: der) else { throw SigningKeyError.noIdentity }
        let trusted = TrustedCertificate(id: Certificates.fingerprint(der), commonName: name,
                                         email: Certificates.summary(der, id: "")?.email, der: der)
        var list = Defaults[Self.trustedKey].filter { $0.id != trusted.id }
        list.append(trusted)
        Defaults[Self.trustedKey] = list
        return trusted
    }

    public func untrust(_ id: String) throws {
        Defaults[Self.trustedKey] = Defaults[Self.trustedKey].filter { $0.id != id }
    }
}
