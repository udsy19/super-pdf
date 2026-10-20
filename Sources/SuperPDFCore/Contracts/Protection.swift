import CoreGraphics
import Foundation

// Protection (ProtectKit: `Services.protect`; features #69, #70, #86–#90, #122). Every operation writes a new file and
// never touches the original (ux §7). We never crack passwords (features #87).

/// "Add a password" (features #86; ux §5.3).
public struct PasswordOptions: Codable, Hashable, Sendable {
    public enum Encryption: String, Codable, Sendable {
        /// AES-256 (R6), the default.
        case aes256
        /// AES-128 for old readers (More options).
        case aes128
    }

    /// Needed to open; nil when only changes are restricted.
    public var openPassword: String?
    /// Needed to change permissions ("Also need a password to change it").
    public var permissionsPassword: String?
    public var permissions: DocumentPermissions
    public var encryption: Encryption
    /// "Encrypt everything except metadata".
    public var keepMetadataReadable: Bool

    public init(openPassword: String? = nil, permissionsPassword: String? = nil, permissions: DocumentPermissions = .all,
                encryption: Encryption = .aes256, keepMetadataReadable: Bool = false) {
        self.openPassword = openPassword; self.permissionsPassword = permissionsPassword; self.permissions = permissions
        self.encryption = encryption; self.keepMetadataReadable = keepMetadataReadable
    }
}

/// Built-in redaction patterns (features #69: Acrobat's set plus IBAN, UK NI and Aadhaar).
public enum RedactionPattern: String, Codable, CaseIterable, Sendable {
    case phoneNumbers, emails, cardNumbers, socialSecurityNumbers, dates, iban, ukNationalInsurance, aadhaar
    /// Names from the address book (ux §5.3 chips).
    case contactNames
}

/// What "Find and mark" looks for.
public enum RedactionQuery: Codable, Hashable, Sendable {
    case text(String, wholeWords: Bool, matchCase: Bool)
    case words([String])
    case pattern(RedactionPattern)
    /// A regular expression the user typed ("Custom pattern…").
    case regularExpression(String)
}

/// An area marked for blacking out (red outline until applied).
public struct RedactionMark: Codable, Hashable, Identifiable, Sendable {
    public var id: UUID
    public var page: Int
    public var rect: CGRect
    /// The matched text, for the results list.
    public var text: String?

    public init(id: UUID = UUID(), page: Int, rect: CGRect, text: String? = nil) {
        self.id = id; self.page = page; self.rect = rect; self.text = text
    }
}

public struct RedactionOptions: Codable, Hashable, Sendable {
    /// Text written over the boxes ("REDACTED" or an exemption code such as "(b)(6)"); nil writes none.
    public var overlayText: String?
    /// "#RRGGBB" box fill (black by default).
    public var fillColor: String
    /// Also run "Remove hidden information" on the result (on by default, ux §5.3).
    public var removeHiddenInformation: Bool

    public init(overlayText: String? = nil, fillColor: String = "#000000", removeHiddenInformation: Bool = true) {
        self.overlayText = overlayText; self.fillColor = fillColor; self.removeHiddenInformation = removeHiddenInformation
    }
}

/// What applying redactions removed, verified by rasterize-and-compare.
public struct RedactionReport: Hashable, Sendable {
    public var items: Int
    public var pages: Int
    /// Every mark's area is clean in text, image pixels and raw bytes.
    public var verified: Bool

    public init(items: Int, pages: Int, verified: Bool) { self.items = items; self.pages = pages; self.verified = verified }
}

/// The things "Remove hidden info" lists (features #88; ux §5.3 checklist).
public enum HiddenInfoKind: String, Codable, CaseIterable, Sendable {
    case metadata, comments, formData, hiddenText, hiddenLayers, attachments, bookmarks, links, scripts, unreferencedObjects
    case thumbnails, overlappingObjects
}

/// What a file holds of each kind, with counts where they mean something ("4 comments").
public struct HiddenInfoInventory: Hashable, Sendable {
    public var counts: [HiddenInfoKind: Int]

    public init(counts: [HiddenInfoKind: Int]) { self.counts = counts }
}

/// "Lock in notes & fields" (features #70).
public struct FlattenOptions: Codable, Hashable, Sendable {
    public var annotations: Bool
    public var formFields: Bool
    /// "Make pages into pictures (strongest)".
    public var rasterizeDPI: Double?

    public init(annotations: Bool = true, formFields: Bool = true, rasterizeDPI: Double? = nil) {
        self.annotations = annotations; self.formFields = formFields; self.rasterizeDPI = rasterizeDPI
    }
}

@MainActor
public protocol Redacting: AnyObject {
    /// Finds marks for a query over `pages` (OCR words on scanned pages).
    func find(_ query: RedactionQuery, in document: DocumentHandle, pages: [Int]) async throws -> [RedactionMark]
    /// Removes the content under the marks for real and writes `destination` (always a new file).
    func apply(_ marks: [RedactionMark], to source: PDFSource, options: RedactionOptions, destination: URL,
               progress: ToolProgress) async throws -> RedactionReport
}

@MainActor
public protocol Sanitizing: AnyObject {
    func inventory(of source: PDFSource) async throws -> HiddenInfoInventory
    func remove(_ kinds: Set<HiddenInfoKind>, from source: PDFSource, to destination: URL) async throws
}

@MainActor
public protocol Flattening: AnyObject {
    func flatten(_ source: PDFSource, options: FlattenOptions, to destination: URL) async throws
}

/// Protection (ProtectKit).
@MainActor
public protocol Protecting: Redacting, Sanitizing, Flattening {
    func addPassword(to source: PDFSource, options: PasswordOptions, destination: URL) async throws
    /// Writes an unprotected copy; `source` carries the password the user typed.
    func removePassword(from source: PDFSource, destination: URL) async throws
    /// What the open file allows (features #90).
    func permissions(of document: DocumentHandle) -> DocumentPermissions
    /// Public-key encryption for named recipients' certificates (features #89).
    func encrypt(_ source: PDFSource, forRecipients certificates: [Data], destination: URL) async throws
    /// An encrypted PDF with a cover page carrying `files` as attachments (features #122).
    func makeEnvelope(_ files: [URL], password: String, destination: URL) async throws
}
