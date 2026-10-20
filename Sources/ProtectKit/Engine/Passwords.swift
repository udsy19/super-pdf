import CoreGraphics
import Foundation
import PDFModelKit
import SuperPDFCore
import UniformTypeIdentifiers

// Add a password (features #86), Remove password (#87) and the security envelope (#122), written by QPDF.
//
// ARCHITECTURE open question 1 (WP12's decision): every protected file is written by QPDF with explicit AES-256 (R6),
// or AES-128 (R4) when asked, never by PDFKit's write options. PDFKit re-serialises the document through Quartz on
// write (structure, attachments and incremental history can change) and does not let us state the revision or every
// permission bit; QPDF keeps the file as it is and encrypts exactly what the panel says.

enum Passwords {
    static func add(to source: PDFSource, options: PasswordOptions) throws -> Data {
        let model = try PDFModel(source)
        try ProtectionRules.requireOwner(model)
        let open = options.openPassword ?? ""
        let change = options.permissionsPassword ?? ""
        guard !open.isEmpty || !change.isEmpty else { throw PDFModelError.invalidOperation("no password") }
        // Without a separate password to change it, whoever opens the file may change anything: limits would only be
        // a promise, so none are written. The owner password is never empty (an empty one would open the file).
        var permissions = change.isEmpty ? DocumentPermissions.all : options.permissions
        permissions.screenReaders = true
        let encryption = PDFEncryption(userPassword: open, ownerPassword: change.isEmpty ? open : change, permissions: permissions,
                                       method: options.encryption, encryptMetadata: !options.keepMetadataReadable)
        return try model.data(options: PDFWriteOptions(encryption: .encrypt(encryption)))
    }

    /// An unprotected copy. The password in `source` must open the file; when the file also limits what people may
    /// do, it must be the owner password (we never crack passwords).
    static func remove(from source: PDFSource) throws -> Data {
        let model: PDFModel
        do {
            model = try PDFModel(source)
        } catch PDFModelError.wrongPassword, PDFModelError.passwordRequired {
            throw ToolError(Strings.Errors.invalidPassword)
        }
        try ProtectionRules.requireOwner(model)
        return try model.data(options: PDFWriteOptions(encryption: .remove))
    }

    /// A password-protected PDF with a cover page that carries `files` as attachments.
    static func envelope(_ files: [URL], password: String) throws -> Data {
        guard !password.isEmpty else { throw PDFModelError.invalidOperation("no password") }
        let model = PDFModel()
        let page = try model.addBlankPage(size: CGSize(width: 612, height: 792))
        let font = model.makeIndirect(.dictionary(["Type": .name("Font"), "Subtype": .name("Type1"), "BaseFont": .name("Helvetica"),
                                                    "Encoding": .name("WinAnsiEncoding")]))
        let fontName = page.addResource(font, category: "Font", prefix: "F")
        var names: Set<String> = []
        var listed: [String] = []
        for file in files {
            let data = try Data(contentsOf: file)
            var name = file.lastPathComponent
            var n = 2
            while names.contains(name) {
                name = file.deletingPathExtension().lastPathComponent + " \(n)" + (file.pathExtension.isEmpty ? "" : "." + file.pathExtension)
                n += 1
            }
            names.insert(name)
            listed.append(name)
            let modified = (try? file.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate
            model.addEmbeddedFile(data, name: name, mimeType: UTType(filenameExtension: file.pathExtension)?.preferredMIMEType,
                                  modificationDate: modified)
        }
        let lines = ProtectStrings.envelopeCover(files: listed)
        var ops: [PDFContentOperation] = [PDFContentOperation("BT"), PDFContentOperation("Tf", [.name(fontName), .integer(20)]),
                                          PDFContentOperation("Td", [.integer(72), .integer(700)]),
                                          PDFContentOperation("Tj", [.string(cp1252(lines[0]))]),
                                          PDFContentOperation("Tf", [.name(fontName), .integer(12)]),
                                          PDFContentOperation("TL", [.integer(18)])]
        for line in lines.dropFirst() {
            ops += [PDFContentOperation("T*"), PDFContentOperation("Tj", [.string(cp1252(line))])]
        }
        ops.append(PDFContentOperation("ET"))
        page.setContentStream(PDFContentStream(operations: ops))
        model.root.set("PageMode", .name("UseAttachments"))
        model.setInfo("Title", lines[0])
        let encryption = PDFEncryption(userPassword: password, ownerPassword: password)
        return try model.data(options: PDFWriteOptions(encryption: .encrypt(encryption)))
    }

    /// Text in Helvetica's WinAnsi encoding ("?" for what it lacks).
    static func cp1252(_ text: String) -> Data {
        Data(text.map { String($0).data(using: .windowsCP1252)?.first ?? UInt8(ascii: "?") })
    }

    /// Some apps (macOS PDFKit among them) can't open AES-256 files whose password has characters outside ASCII.
    static func needsASCIIWarning(_ password: String) -> Bool { !password.allSatisfy { $0.isASCII } }
}

extension ProtectionRules {
    /// Rewriting the protection of a file that limits what people may do needs its owner password.
    static func requireOwner(_ model: PDFModel) throws {
        guard !model.hasOwnerAccess, let restriction = firstRestriction(model.permissions) else { return }
        throw ToolError(Strings.Errors.ownerRestricted(restriction))
    }

    /// The first thing a file doesn't allow, in the words of the "doesn’t allow" sentence; nil when it allows all.
    static func firstRestriction(_ p: DocumentPermissions) -> Strings.Restriction? {
        if p.printing != .highResolution { return .printing }
        if !p.copyingText || !p.screenReaders { return .copying }
        if !p.pageChanges { return .pageChanges }
        if !p.commenting { return .commenting }
        if !p.fillingFormsAndSigning { return .formFilling }
        return nil
    }
}
