import CoreGraphics
import Combine
import Foundation

// Signatures (SignKit: `Services.sign`, `Services.requests`; features #82–#85, §3.6). Signing keys stay in the Keychain;
// requests are a local file exchange, no server (features #84).

// MARK: - Signature library and certificates

public enum SignatureKind: String, Codable, Sendable {
    case signature, initials
}

/// A saved hand-drawn, typed, photographed or imported signature (Preview's library).
public struct SavedSignature: Codable, Hashable, Identifiable, Sendable {
    public var id: UUID
    public var kind: SignatureKind
    /// Transparent PNG.
    public var image: Data
    public var created: Date

    public init(id: UUID = UUID(), kind: SignatureKind, image: Data, created: Date = Date()) {
        self.id = id; self.kind = kind; self.image = image; self.created = created
    }
}

/// A certificate with a private key the user can sign with.
public struct SigningIdentity: Codable, Hashable, Identifiable, Sendable {
    /// The Keychain persistent reference, hex.
    public var id: String
    public var commonName: String
    public var email: String?
    public var issuer: String
    public var notAfter: Date
    public var isSelfSigned: Bool

    public init(id: String, commonName: String, email: String? = nil, issuer: String, notAfter: Date, isSelfSigned: Bool) {
        self.id = id; self.commonName = commonName; self.email = email; self.issuer = issuer; self.notAfter = notAfter
        self.isSelfSigned = isSelfSigned
    }
}

/// A certificate someone sent that the user chose to trust ("People I trust").
public struct TrustedCertificate: Codable, Hashable, Identifiable, Sendable {
    /// SHA-256 of the DER, hex.
    public var id: String
    public var commonName: String
    public var email: String?
    public var der: Data

    public init(id: String, commonName: String, email: String? = nil, der: Data) {
        self.id = id; self.commonName = commonName; self.email = email; self.der = der
    }
}

/// "Sign with a certificate" options (ux §5.3 Sign).
public struct CertificateSignOptions: Codable, Hashable, Sendable {
    public var identityID: String
    public var page: Int
    /// The visible appearance's rectangle; nil signs invisibly.
    public var rect: CGRect?
    public var reason: String
    public var location: String
    /// DocMDP: no changes allowed after signing.
    public var lockDocument: Bool
    /// RFC 3161, only when the user turned it on and named a server (features §3.5 item 4).
    public var timestampServer: URL?

    public init(identityID: String, page: Int = 0, rect: CGRect? = nil, reason: String = "", location: String = "", lockDocument: Bool = false,
                timestampServer: URL? = nil) {
        self.identityID = identityID; self.page = page; self.rect = rect; self.reason = reason; self.location = location
        self.lockDocument = lockDocument; self.timestampServer = timestampServer
    }
}

/// One signature in a file, as the Signatures sidebar and "Certificates & signatures" show it (features #83).
public struct SignatureReport: Codable, Hashable, Sendable {
    public enum Validity: String, Codable, Sendable {
        case valid
        /// The bytes covered by the signature changed (ux §7.4 "Signature invalid").
        case modified
        /// Valid maths, but the certificate isn't trusted on this Mac.
        case untrusted
        case invalid
    }

    public var fieldName: String
    public var signerName: String
    public var signedAt: Date?
    public var validity: Validity
    /// Later incremental updates exist (allowed form fills or comments, or changes).
    public var changedAfterSigning: Bool
    /// The chain from the signer up, common names.
    public var chain: [String]
    /// The signer's certificate, for "Trust this person".
    public var certificate: Data

    public init(fieldName: String, signerName: String, signedAt: Date?, validity: Validity, changedAfterSigning: Bool,
                chain: [String], certificate: Data) {
        self.fieldName = fieldName; self.signerName = signerName; self.signedAt = signedAt; self.validity = validity
        self.changedAfterSigning = changedAfterSigning; self.chain = chain; self.certificate = certificate
    }
}

@MainActor
public protocol SignatureLibrary: AnyObject {
    var savedSignatures: [SavedSignature] { get }
    func save(_ signature: SavedSignature) throws
    func delete(_ id: UUID) throws
    /// Places a saved signature on a page as a stamp with an appearance stream (features #82, first level).
    func place(_ signature: SavedSignature, on page: Int, in rect: CGRect, document: DocumentHandle) throws -> UndoGroup
}

@MainActor
public protocol CertificateSigning: AnyObject {
    var identities: [SigningIdentity] { get }
    /// "Create my certificate…": a self-signed X.509 for 10 years in the login Keychain (features #85).
    func createIdentity(name: String, email: String?) async throws -> SigningIdentity
    func importIdentity(p12: URL, password: String) async throws -> SigningIdentity
    func exportCertificate(of identityID: String, to destination: URL) throws
    /// PAdES-B-B over `source`, written incrementally to `destination` (features #82, second level).
    func sign(_ source: PDFSource, options: CertificateSignOptions, to destination: URL) async throws
}

@MainActor
public protocol SignatureVerifying: AnyObject {
    func verify(_ source: PDFSource) async throws -> [SignatureReport]
    var trustedCertificates: [TrustedCertificate] { get }
    func trust(_ certificate: Data) throws -> TrustedCertificate
    func untrust(_ id: String) throws
}

/// Signatures (SignKit).
@MainActor
public protocol Signing: SignatureLibrary, CertificateSigning, SignatureVerifying {}

// MARK: - Request signatures (features #84)

/// Where a signer is in a request (ux §5.3: Waiting · Returned · Done).
public enum SignerState: String, Codable, CaseIterable, Sendable {
    case waiting, returned, done
}

public struct Signer: Codable, Hashable, Identifiable, Sendable {
    public var id: UUID
    public var name: String
    public var email: String
    /// The signer's colour chip and field tint, "#RRGGBB".
    public var color: String
    /// Position when "Sign in this order" is on.
    public var order: Int
    public var state: SignerState
    public var returnedAt: Date?

    public init(id: UUID = UUID(), name: String, email: String, color: String, order: Int, state: SignerState = .waiting,
                returnedAt: Date? = nil) {
        self.id = id; self.name = name; self.email = email; self.color = color; self.order = order; self.state = state
        self.returnedAt = returnedAt
    }
}

public enum RequestFieldKind: String, Codable, CaseIterable, Sendable {
    case signature, initials, date, name, checkbox
}

/// A field placed for one signer (step 2 "Where").
public struct RequestField: Codable, Hashable, Identifiable, Sendable {
    public var id: UUID
    public var kind: RequestFieldKind
    public var signerID: UUID
    public var page: Int
    public var rect: CGRect

    public init(id: UUID = UUID(), kind: RequestFieldKind, signerID: UUID, page: Int, rect: CGRect) {
        self.id = id; self.kind = kind; self.signerID = signerID; self.page = page; self.rect = rect
    }
}

/// A request and its progress, stored under `SuperPDFPaths.request(id)`.
public struct SignatureRequest: Codable, Hashable, Identifiable, Sendable {
    public var id: UUID
    public var documentName: String
    public var created: Date
    public var signers: [Signer]
    public var signInOrder: Bool
    public var fields: [RequestField]
    public var message: String
    /// The final certified copy, once sealed.
    public var sealedAt: Date?

    public init(id: UUID = UUID(), documentName: String, created: Date = Date(), signers: [Signer], signInOrder: Bool = false,
                fields: [RequestField] = [], message: String = "", sealedAt: Date? = nil) {
        self.id = id; self.documentName = documentName; self.created = created; self.signers = signers; self.signInOrder = signInOrder
        self.fields = fields; self.message = message; self.sealedAt = sealedAt
    }

    /// Everyone has signed: "Seal and finish" appears.
    public var isComplete: Bool { !signers.isEmpty && signers.allSatisfy { $0.state == .done } }

    /// The manifest embedded in the signing package, by which returned files are recognised.
    public var manifest: SigningPackageManifest {
        SigningPackageManifest(requestID: id, created: created, signInOrder: signInOrder,
                               signers: signers.sorted { $0.order < $1.order }.map { .init(id: $0.id, name: $0.name, email: $0.email) })
    }
}

/// `request.json`, embedded in the PDF of a signing package (features #84 step 2).
public struct SigningPackageManifest: Codable, Hashable, Sendable {
    public struct Entry: Codable, Hashable, Sendable {
        public var id: UUID
        public var name: String
        public var email: String

        public init(id: UUID, name: String, email: String) { self.id = id; self.name = name; self.email = email }
    }

    /// Bumped when the format changes.
    public var version: Int = 1
    public var requestID: UUID
    public var created: Date
    public var signInOrder: Bool
    public var signers: [Entry]

    public init(requestID: UUID, created: Date, signInOrder: Bool, signers: [Entry]) {
        self.requestID = requestID; self.created = created; self.signInOrder = signInOrder; self.signers = signers
    }

    public static let attachmentName = "request.json"
}

/// The "Signatures I asked for" store and flow (SignKit).
@MainActor
public protocol SignatureRequesting: AnyObject {
    var requests: [SignatureRequest] { get }
    var changes: AnyPublisher<SignatureRequest, Never> { get }
    func save(_ request: SignatureRequest) throws
    /// Builds the signing package for `request` from the document (fields, cover page, embedded manifest).
    func makePackage(for request: SignatureRequest, from document: DocumentHandle) async throws -> URL
    /// A file opened or dropped that answers a request: merges its signatures and returns the updated request; nil when
    /// the file belongs to no request.
    func receive(_ file: URL) async throws -> SignatureRequest?
    /// Seals the finished request with the sender's certificate and appends the audit page.
    func seal(_ request: SignatureRequest, identityID: String) async throws -> URL
    /// Window › Signature Requests.
    func showRequestsWindow()
}
