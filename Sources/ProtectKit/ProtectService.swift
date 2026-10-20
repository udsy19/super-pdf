import Contacts
import Foundation
import PDFKit
import PDFModelKit
import SuperPDFCore

/// `Services.protect` (features #69, #70, #86–#90, #122). Every file-writing operation works off the main actor on a
/// private `PDFModel` of the source's bytes and writes `destination`, never the original; PDFKit is touched only on the
/// main actor (finding text, the permissions view, the text check after Black out).
@MainActor
public final class ProtectService: Protecting {
    /// Full names from the address book for the "Names from the address book" chip; the self-test injects its own.
    public var contactNames: @Sendable () async -> [String]

    public init() {
        contactNames = { await Self.addressBookNames() }
    }

    // MARK: - Redacting

    public func find(_ query: RedactionQuery, in document: DocumentHandle, pages: [Int]) async throws -> [RedactionMark] {
        let names: [String] = if case .pattern(.contactNames) = query { await contactNames() } else { [] }
        var marks: [RedactionMark] = []
        var source: PDFSource?
        for index in pages where index >= 0 && index < document.pageCount {
            try Task.checkCancellation()
            guard let page = document.pdf.page(at: index) else { continue }
            var text = RedactionFinder.pdfKitText(page, index: index)
            if text == nil {
                // A scan: read it with Vision first.
                let snapshot = source ?? document.snapshot()
                source = snapshot
                text = try await Task.detached { try RedactionFinder.recognisedText(snapshot, index: index) }.value
            }
            guard let text else { continue }
            marks += RedactionFinder.marks(for: try RedactionFinder.matches(query, in: text.text, names: names), in: text)
            await Task.yield()
        }
        return marks
    }

    public func apply(_ marks: [RedactionMark], to source: PDFSource, options: RedactionOptions, destination: URL,
                      progress: ToolProgress) async throws -> RedactionReport {
        let phrases = marks.compactMap(\.text)
        let data = try await Task.detached {
            try Redactor.apply(marks, to: source, options: options, phrases: phrases, progress: progress)
        }.value
        let fill = RGB(hex: options.fillColor)
        let withWords = !(options.overlayText ?? "").trimmingCharacters(in: .whitespaces).isEmpty
        let password = source.password
        let solid = await Task.detached { RedactionVerifier.rendersSolid(data, password: password, marks: marks, fill: fill, withWords: withWords) }.value
        let clean = RedactionVerifier.hasNoText(data, password: password, marks: marks, overlay: options.overlayText)
        try data.write(to: destination, options: .atomic)
        return RedactionReport(items: marks.count, pages: Set(marks.map(\.page)).count, verified: solid && clean)
    }

    // MARK: - Sanitizing

    public func inventory(of source: PDFSource) async throws -> HiddenInfoInventory {
        try await Task.detached { try Sanitizer.inventory(of: source) }.value
    }

    public func remove(_ kinds: Set<HiddenInfoKind>, from source: PDFSource, to destination: URL) async throws {
        let data = try await Task.detached { try Sanitizer.remove(kinds, from: source) }.value
        try data.write(to: destination, options: .atomic)
    }

    // MARK: - Flattening

    public func flatten(_ source: PDFSource, options: FlattenOptions, to destination: URL) async throws {
        let data = try await Task.detached { try Flattener.flatten(source, options: options) }.value
        try data.write(to: destination, options: .atomic)
    }

    // MARK: - Passwords

    public func addPassword(to source: PDFSource, options: PasswordOptions, destination: URL) async throws {
        let data = try await Task.detached { try Passwords.add(to: source, options: options) }.value
        try data.write(to: destination, options: .atomic)
    }

    public func removePassword(from source: PDFSource, destination: URL) async throws {
        let data = try await Task.detached { try Passwords.remove(from: source) }.value
        try data.write(to: destination, options: .atomic)
    }

    /// What the open file allows (features #90): PDFKit's view of it, everything when it was unlocked with the owner
    /// password or has no security.
    public func permissions(of document: DocumentHandle) -> DocumentPermissions {
        let pdf = document.pdf
        guard pdf.isEncrypted, pdf.permissionsStatus != .owner else { return .all }
        // An NS_ENUM of bits rather than an option set in Swift.
        let raw = pdf.accessPermissions.rawValue
        func allows(_ bit: PDFAccessPermissions) -> Bool { raw & bit.rawValue != 0 }
        let printing: DocumentPermissions.PrintingPermission =
            allows(.allowsHighQualityPrinting) ? .highResolution : allows(.allowsLowQualityPrinting) ? .lowResolution : .none
        return DocumentPermissions(printing: printing,
                                   copyingText: allows(.allowsContentCopying),
                                   fillingFormsAndSigning: allows(.allowsFormFieldEntry) || allows(.allowsCommenting) || allows(.allowsDocumentChanges),
                                   commenting: allows(.allowsCommenting) || allows(.allowsDocumentChanges),
                                   pageChanges: allows(.allowsDocumentAssembly),
                                   screenReaders: allows(.allowsContentAccessibility) || allows(.allowsContentCopying))
    }

    public func encrypt(_ source: PDFSource, forRecipients certificates: [Data], destination: URL) async throws {
        let data = try await Task.detached { try CertificateEncryption.encrypt(source, recipients: certificates) }.value
        try data.write(to: destination, options: .atomic)
    }

    public func makeEnvelope(_ files: [URL], password: String, destination: URL) async throws {
        let data = try await Task.detached { try Passwords.envelope(files, password: password) }.value
        try data.write(to: destination, options: .atomic)
    }

    // MARK: - Address book

    /// Full names of the people in Contacts, after the system asks once for access (off the main actor).
    nonisolated static func addressBookNames() async -> [String] {
        let store = CNContactStore()
        switch CNContactStore.authorizationStatus(for: .contacts) {
        case .notDetermined:
            guard (try? await store.requestAccess(for: .contacts)) == true else { return [] }
        case .denied, .restricted:
            return []
        default:
            break
        }
        return await Task.detached {
            var names: [String] = []
            let request = CNContactFetchRequest(keysToFetch: [CNContactGivenNameKey as CNKeyDescriptor, CNContactFamilyNameKey as CNKeyDescriptor])
            try? store.enumerateContacts(with: request) { contact, _ in
                let full = [contact.givenName, contact.familyName].filter { !$0.isEmpty }.joined(separator: " ")
                if full.count >= 3 { names.append(full) }
            }
            return names
        }.value
    }
}
