import AppKit
import SuperPDFCore
import UniformTypeIdentifiers

/// File › New from Clipboard (features #49) and the Services menu's "Open selection as PDF" (§2.5): a PDF, a picture
/// or text on a pasteboard becomes a new document, through the same converters a dropped file uses.
@MainActor
enum PasteboardPDF {
    /// The first thing on the pasteboard that can become a PDF, as a file in `folder`: a PDF as it is, a picture as
    /// PNG, styled text as RTF, plain text as text.
    static func file(from pasteboard: NSPasteboard, in folder: URL) throws -> URL? {
        if let pdf = pasteboard.data(forType: .pdf) {
            return try write(pdf, "pdf", in: folder)
        }
        if let file = (pasteboard.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as? [URL])?.first {
            return file
        }
        if let image = NSImage(pasteboard: pasteboard), let tiff = image.tiffRepresentation,
           let png = NSBitmapImageRep(data: tiff)?.representation(using: .png, properties: [:]) {
            return try write(png, "png", in: folder)
        }
        if let rtf = pasteboard.data(forType: .rtf) {
            return try write(rtf, "rtf", in: folder)
        }
        if let text = pasteboard.string(forType: .string), !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return try write(Data(text.utf8), "txt", in: folder)
        }
        return nil
    }

    /// Whether `file(from:in:)` would find something (the menu item's enabled state).
    static func canMake(from pasteboard: NSPasteboard) -> Bool {
        pasteboard.canReadItem(withDataConformingToTypes: [UTType.pdf.identifier, UTType.image.identifier, UTType.rtf.identifier,
                                                            UTType.plainText.identifier, UTType.fileURL.identifier])
    }

    /// Makes the new document; says so when there is nothing to make one from.
    static func open(from pasteboard: NSPasteboard) async {
        let folder = SuperPDFPaths.ensure(SuperPDFPaths.work.appendingPathComponent("pasteboard-" + UUID().uuidString, isDirectory: true))
        defer { try? FileManager.default.removeItem(at: folder) }
        do {
            guard let file = try file(from: pasteboard, in: folder) else { return say(AppStrings.nothingToMake) }
            let pdf: URL
            if file.pathExtension.lowercased() == "pdf" {
                pdf = file
            } else {
                guard let convert = Services.convert else { return }
                let destination = folder.appendingPathComponent("converted.pdf")
                pdf = try await convert.convert(ConversionJob(inputs: [file], output: .pdf, destination: destination), progress: .ignored)
                    .outputs.first ?? destination
            }
            try Services.documents?.openUntitled(try Data(contentsOf: pdf), name: AppStrings.untitled)
        } catch {
            NSApp.presentError(error)
        }
    }

    private static func write(_ data: Data, _ ext: String, in folder: URL) throws -> URL {
        let url = folder.appendingPathComponent(AppStrings.untitled).appendingPathExtension(ext)
        try data.write(to: url)
        return url
    }

    private static func say(_ message: String) {
        let alert = NSAlert()
        alert.messageText = message
        alert.addButton(withTitle: Strings.Errors.ok)
        alert.runModal()
    }
}

/// The "Save to Super PDF" item of every app's Print dialog (features #48): a link to the app in
/// ~/Library/PDF Services, which the Print dialog lists under PDF and opens the printed PDF with. Offered once.
@MainActor
enum PDFServicesItem {
    static var folder: URL {
        FileManager.default.urls(for: .libraryDirectory, in: .userDomainMask)[0].appendingPathComponent("PDF Services", isDirectory: true)
    }

    static var item: URL { folder.appendingPathComponent(AppStrings.pdfServicesItem) }

    /// Whether the item is there and leads to an app.
    static var isInstalled: Bool {
        (try? FileManager.default.destinationOfSymbolicLink(atPath: item.path)).map { $0.hasSuffix(".app") } ?? false
    }

    /// The first launch of the app bundle asks once; the answer is remembered either way.
    static func offerOnce() {
        guard !Defaults[.pdfServicesOffered], Bundle.main.bundleURL.pathExtension == "app" else { return }
        Defaults[.pdfServicesOffered] = true
        guard !isInstalled else { return }
        let alert = NSAlert()
        alert.messageText = AppStrings.pdfServicesTitle
        alert.informativeText = AppStrings.pdfServicesInfo
        alert.addButton(withTitle: AppStrings.add)
        alert.addButton(withTitle: AppStrings.notNow)
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        do { try install(app: Bundle.main.bundleURL) } catch { NSApp.presentError(error) }
    }

    /// Points the item at `app` (replacing an older link of ours).
    static func install(app: URL) throws {
        let fm = FileManager.default
        try fm.createDirectory(at: folder, withIntermediateDirectories: true)
        if (try? fm.destinationOfSymbolicLink(atPath: item.path)) != nil { try fm.removeItem(at: item) }
        try fm.createSymbolicLink(at: item, withDestinationURL: app)
    }
}
