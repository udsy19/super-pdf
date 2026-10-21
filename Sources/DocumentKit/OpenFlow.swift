import AppKit
import PDFKit
import SuperPDFCore

/// The questions DocumentKit asks while opening, saving and closing (ux §7.1, §7.4). The app answers them with alerts
/// and sheets (`AlertPrompter`); the self-test answers from a script. Every answer can be "Cancel" (nil / false).
@MainActor
public protocol DocumentPrompting: AnyObject {
    /// "This document is password protected. Please enter the password below." — after a wrong one, `retry` is true
    /// and the sheet says "Invalid password. Please try again." Nil is Cancel.
    func password(for fileName: String, retry: Bool) async -> String?
    /// "“Report.pdf” couldn’t be opened. It may be damaged. We can try to repair it." — true is Repair. With
    /// `canRepair` false (no repairer installed) only OK is offered and the answer is false.
    func confirmRepair(of fileName: String, canRepair: Bool) async -> Bool
    /// "Save changes to “Report.pdf”?" — Save a copy… / Replace original / Cancel (nil), with "Always do this".
    func firstSave(of fileName: String, window: NSWindow?) async -> (answer: FirstSaveAnswer, always: Bool)?
    /// Closing with unsaved changes (Preview's wording): Review Changes… / Discard Changes / Cancel.
    func closeWithUnsavedChanges(window: NSWindow?) async -> CloseAnswer
    /// The save panel, proposing a name and folder ("Report (edited).pdf" next to the original). Nil is Cancel.
    func saveLocation(proposing proposal: URL, window: NSWindow?) async -> URL?
    /// The owner password for "Enter Password…" (same copy as the open prompt). Nil is Cancel.
    func ownerPassword(for fileName: String, retry: Bool, window: NSWindow?) async -> String?
}

public enum CloseAnswer: Equatable, Sendable {
    case review, discard, cancel
}

/// What opening produced: the PDFKit document (lazily backed by the file, so opening stays instant on big files),
/// the file it was read from (the repaired copy after a repair), the password typed and whether QPDF recovery rebuilt
/// it.
struct LoadedPDF {
    var pdf: PDFDocument
    var file: URL
    var password: String?
    var wasRepaired: Bool

    /// The bytes PDFKit read, which become the document's authoritative contents.
    var bytes: Data? { try? Data(contentsOf: file, options: .mappedIfSafe) }
}

/// The open flow of ux §7.4: password prompt with retries, and the damaged-file prompt with Repair. Nothing here
/// writes next to or over the file; a repair is written into the work folder and the original stays untouched.
@MainActor
struct DocumentLoader {
    var prompter: DocumentPrompting
    /// QPDF recovery (FixKit's `Repairing`); nil until a module provides it.
    var repairer: @MainActor () -> Repairing?
    /// Where repaired copies are written.
    var workFolder: @MainActor () -> URL

    /// `contents` is what to read (the file, or its autosaved contents); `fileName` is what people see.
    func load(_ contents: URL, fileName: String) async throws -> LoadedPDF {
        if let pdf = PDFDocument(url: contents) {
            let password = try await unlock(pdf, fileName: fileName)
            return LoadedPDF(pdf: pdf, file: contents, password: password, wasRepaired: false)
        }
        // Not readable as it is: the file is missing or unreadable (say so), or damaged (offer repair).
        _ = try contents.checkResourceIsReachable()
        guard FileManager.default.isReadableFile(atPath: contents.path) else {
            throw CocoaError(.fileReadNoPermission, userInfo: [NSFilePathErrorKey: contents.path])
        }
        let repairer = repairer()
        guard await prompter.confirmRepair(of: fileName, canRepair: repairer != nil), let repairer else {
            throw CocoaError(.userCancelled)
        }
        let folder = SuperPDFPaths.ensure(workFolder().appendingPathComponent(UUID().uuidString, isDirectory: true))
        let repaired = folder.appendingPathComponent(fileName)
        _ = try await repairer.repair(.file(contents), embedFonts: false, to: repaired)
        guard let pdf = PDFDocument(url: repaired) else { throw DocumentError.damaged(fileName) }
        let password = try await unlock(pdf, fileName: fileName)
        return LoadedPDF(pdf: pdf, file: repaired, password: password, wasRepaired: true)
    }

    /// Asks until the password opens the file or the person cancels.
    private func unlock(_ pdf: PDFDocument, fileName: String) async throws -> String? {
        guard pdf.isLocked else { return nil }
        var retry = false
        while true {
            guard let password = await prompter.password(for: fileName, retry: retry) else { throw CocoaError(.userCancelled) }
            if pdf.unlock(withPassword: password) { return password }
            retry = true
        }
    }
}

/// Errors DocumentKit presents, in the copy of ux §7.4.
enum DocumentError: LocalizedError, Equatable {
    case damaged(String)
    case notConvertible(String)
    /// The written bytes didn't read back as the same document; nothing was replaced.
    case writeCheckFailed

    var errorDescription: String? {
        switch self {
        case .damaged(let name): Strings.Errors.damaged(name)
        case .notConvertible(let ext): Strings.Errors.notConvertible(ext)
        case .writeCheckFailed: nil
        }
    }
}

extension DocumentPermissions {
    /// What PDFKit says the file allows (features #86, #90).
    init(_ pdf: PDFDocument) {
        self.init(printing: pdf.allowsPrinting ? .highResolution : .none, copyingText: pdf.allowsCopying,
                  fillingFormsAndSigning: pdf.allowsFormFieldEntry, commenting: pdf.allowsCommenting,
                  pageChanges: pdf.allowsDocumentAssembly, screenReaders: pdf.allowsContentAccessibility)
    }
}

/// Form fields and signature fields, read from the catalog's AcroForm without loading any page, so opening a long
/// document stays instant.
enum FormScan {
    static func scan(_ pdf: PDFDocument) -> (hasFields: Bool, hasSignatures: Bool) {
        guard let catalog = pdf.documentRef?.catalog else { return (false, false) }
        var acroForm: CGPDFDictionaryRef?
        var fields: CGPDFArrayRef?
        guard CGPDFDictionaryGetDictionary(catalog, "AcroForm", &acroForm), let acroForm,
              CGPDFDictionaryGetArray(acroForm, "Fields", &fields), let fields, CGPDFArrayGetCount(fields) > 0 else {
            return (false, false)
        }
        return (true, containsSignature(fields, depth: 0))
    }

    private static func containsSignature(_ fields: CGPDFArrayRef, depth: Int) -> Bool {
        guard depth < 8 else { return false }
        for index in 0..<CGPDFArrayGetCount(fields) {
            var field: CGPDFDictionaryRef?
            guard CGPDFArrayGetDictionary(fields, index, &field), let field else { continue }
            var type: UnsafePointer<CChar>?
            if CGPDFDictionaryGetName(field, "FT", &type), let type, String(cString: type) == "Sig" { return true }
            var kids: CGPDFArrayRef?
            if CGPDFDictionaryGetArray(field, "Kids", &kids), let kids, containsSignature(kids, depth: depth + 1) { return true }
        }
        return false
    }
}
