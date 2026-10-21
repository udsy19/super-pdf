import CoreGraphics
import Foundation
import PDFModelKit
import RenderKit
import SuperPDFCore

// For archiving (features #56 PDF/A, #57 PDF/X). Quartz re-renders the pages into a PDF/A (or OutputIntent) context:
// fonts embedded, sRGB OutputIntent, no scripts, no encryption. A QPDF pass then makes the file say what it is and keeps
// what the re-render drops: XMP identification matching /Info, the bookmarks, PDF/A-3's attachments, the structure tree
// of a tagged source for the "a" levels. PDF/A-1 can't hold transparency, so pages that use it become pictures; then
// the built-in check (#93) reads the result.

enum ArchiveWriter {
    /// Writes `source` as PDF/A at `level` and returns what the PDF/A check still finds in the result (empty: it passes).
    static func writePDFA(_ source: PDFSource, level: PDFALevel, to url: URL) throws -> [PDFAProblem] {
        let rendered = ArchiveTemp.file()
        defer { try? FileManager.default.removeItem(at: rendered) }
        try PDFOutput.writePDFA(source, to: rendered)

        var model = try PDFModel(url: rendered, attemptRecovery: false)
        if level.archivePart == 1 {
            let transparent = model.pages.indices.filter { ArchivePageScan(model.pages[$0]).usesTransparency(includingGroups: false) }
            if !transparent.isEmpty {
                let flattened = ArchiveTemp.file()
                defer { try? FileManager.default.removeItem(at: flattened) }
                try flatten(.file(rendered), pages: Set(transparent), to: flattened)
                model = try PDFModel(data: try Data(contentsOf: flattened), attemptRecovery: false)
            }
            // A transparency group with nothing see-through in it changes nothing; part 1 doesn't allow the key.
            for page in model.pages {
                page.object.remove("Group")
                for form in ArchivePageScan.forms(of: page) { form.remove("Group") }
            }
        }

        let original = try PDFModel(source)
        removeActions(model)
        ensureOutputIntent(model)
        let outline = original.outlines()
        model.setOutlines(outline)
        if level.archivePart == 3 {
            try copyAttachments(from: original, to: model)
        }
        if level.requiresTags, original.root["StructTreeRoot"] != nil, let tree = original.structureTree() {
            try model.setStructureTree(tree)
            model.root.set("MarkInfo", .dictionary(["Marked": .bool(true)]))
            if let language = original.root["Lang"]?.value { model.root.set("Lang", language) }
        }
        let identification = [("pdfaid:part", String(level.archivePart)), ("pdfaid:conformance", level.archiveConformance)]
        setMetadata(model, original: original, identification: identification, namespaces: ["pdfaid": "http://www.aiim.org/pdfa/ns/id/"])

        try model.write(to: url, options: PDFWriteOptions(objectStreams: level.archivePart == 1 ? .disable : .preserve, encryption: .remove))
        return try PDFAVerifier.verify(.file(url), level: level)
    }

    /// Writes `source` as PDF/X (print): an OutputIntent with its CMYK profile, trim boxes on every page, /Info and XMP
    /// naming the version, Trapped false. X-1a has no RGB: Quartz turned RGB pages into CMYK pictures.
    static func writePDFX(_ source: PDFSource, level: PDFXLevel, to url: URL) throws {
        let rendered = ArchiveTemp.file()
        defer { try? FileManager.default.removeItem(at: rendered) }
        try PDFOutput.writePDFX(source, level: level, outputIntent: nil, to: rendered)

        let model = try PDFModel(url: rendered, attemptRecovery: false)
        let original = try PDFModel(source)
        removeActions(model)
        model.setOutlines(original.outlines())

        let version = level == .x4 ? "PDF/X-4" : "PDF/X-1a:2001"
        let intents = model.root["OutputIntents"]?.items ?? []
        let intent = intents.first { $0["S"]?.name == "GTS_PDFX" }
        let profile = cmykProfile(in: model)
        if let intent {
            if intent["DestOutputProfile"]?.type != .stream { intent.set("DestOutputProfile", profile) }
            if intent["OutputConditionIdentifier"] == nil { intent.set("OutputConditionIdentifier", .text("Generic CMYK")) }
        } else {
            model.root.array("OutputIntents").append(model.makeIndirect(.dictionary([
                "Type": .name("OutputIntent"), "S": .name("GTS_PDFX"), "OutputConditionIdentifier": .text("Generic CMYK"),
                "Info": .text("Generic CMYK"), "RegistryName": .ascii("http://www.color.org"), "DestOutputProfile": profile.reference!,
            ])))
        }
        for page in model.pages where !page.object.has("TrimBox") {
            page.setBox(.trim, page.box(.crop))
        }

        setMetadata(model, original: original, identification: [("pdfxid:GTS_PDFXVersion", version)],
                    namespaces: ["pdfxid": "http://www.npes.org/pdfx/ns/id/"], extra: [("pdf:Trapped", "False")])
        model.setInfo("GTS_PDFXVersion", version)
        if level == .x1a { model.setInfo("GTS_PDFXConformance", version) }
        model.trailer["Info"]?.set("Trapped", .name("False"))
        if model.info("Title") == nil { model.setInfo("Title", original.info("Title") ?? "Untitled") }

        try model.write(to: url, options: PDFWriteOptions(encryption: .remove, minimumVersion: level == .x4 ? "1.6" : nil))
    }

    // MARK: - Steps

    /// Draws `pages` as opaque pictures (300 dpi) and the others as they are, in a PDF/A context.
    private static func flatten(_ source: PDFSource, pages: Set<Int>, to url: URL) throws {
        let document = try PDFPages.open(source)
        var info = PDFPages.metadata(document)
        info[kCGPDFContextCreatePDFA] = true
        let srgb = CGColorSpace(name: CGColorSpace.sRGB)!
        if let profile = srgb.copyICCData() {
            info[kCGPDFContextOutputIntent] = [kCGPDFXOutputIntentSubtype: "GTS_PDFA1", kCGPDFXOutputConditionIdentifier: "sRGB IEC61966-2.1",
                                               kCGPDFXRegistryName: "http://www.color.org", kCGPDFXInfo: "sRGB IEC61966-2.1",
                                               kCGPDFXDestinationOutputProfile: profile] as [CFString: Any]
        }
        var out: [PDFWriter.Page] = []
        for index in 0..<document.numberOfPages {
            let page = try PDFPages.page(document, at: index)
            let size = PDFPages.displayedSize(page)
            let rect = CGRect(origin: .zero, size: size)
            if pages.contains(index) {
                out.append(PDFWriter.Page(size: size) { context in
                    let width = max(Int((size.width * 300 / 72).rounded()), 1), height = max(Int((size.height * 300 / 72).rounded()), 1)
                    guard width * height <= Rasterizer.maxPixels,
                          let bitmap = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0, space: srgb,
                                                 bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue) else { throw RenderError.cannotCreateContext }
                    bitmap.setFillColor(CGColor(gray: 1, alpha: 1))
                    bitmap.fill(CGRect(x: 0, y: 0, width: width, height: height))
                    bitmap.interpolationQuality = .high
                    PDFPages.draw(page, in: bitmap, fitting: CGRect(x: 0, y: 0, width: width, height: height))
                    guard let image = bitmap.makeImage() else { throw RenderError.cannotCreateContext }
                    context.draw(image, in: rect)
                })
            } else {
                out.append(PDFWriter.Page(size: size) { context in PDFPages.draw(page, in: context, fitting: rect) })
            }
        }
        try PDFWriter.write(to: url, info: info, pages: out)
    }

    /// Scripts, document and page actions, and annotations' actions that archive and print files can't hold.
    private static func removeActions(_ model: PDFModel) {
        model.root["Names"]?.remove("JavaScript")
        model.root.remove("AA")
        if let open = model.root["OpenAction"], open.type == .dictionary, let type = open["S"]?.name,
           type == "JavaScript" || ArchiveActions.forbiddenTypes.contains(type) {
            model.root.remove("OpenAction")
        }
        for page in model.pages {
            page.object.remove("AA")
            for annotation in page.annotations {
                annotation.remove("AA")
                if let type = annotation["A"]?["S"]?.name, type == "JavaScript" || ArchiveActions.forbiddenTypes.contains(type) {
                    annotation.remove("A")
                }
            }
        }
    }

    /// Quartz writes the sRGB OutputIntent in PDF/A contexts; this adds one when a file has none.
    private static func ensureOutputIntent(_ model: PDFModel) {
        let intents = model.root["OutputIntents"]?.items ?? []
        guard !intents.contains(where: { $0["S"]?.name == "GTS_PDFA1" && $0["DestOutputProfile"]?.type == .stream }),
              let icc = CGColorSpace(name: CGColorSpace.sRGB)?.copyICCData() as Data? else { return }
        let profile = model.makeStream(["N": .integer(3)], data: icc)
        model.root.set("OutputIntents", .array([model.makeIndirect(.dictionary([
            "Type": .name("OutputIntent"), "S": .name("GTS_PDFA1"), "OutputConditionIdentifier": .text("sRGB IEC61966-2.1"),
            "Info": .text("sRGB IEC61966-2.1"), "RegistryName": .ascii("http://www.color.org"), "DestOutputProfile": profile.reference!,
        ])).reference!]))
    }

    /// The generic CMYK profile as an ICC stream.
    private static func cmykProfile(in model: PDFModel) -> PDFObject {
        let icc = CGColorSpace(name: CGColorSpace.genericCMYK)?.copyICCData() as Data? ?? Data()
        return model.makeStream(["N": .integer(4)], data: icc)
    }

    /// PDF/A-3 keeps the attachments, each saying how it relates to the document (/AFRelationship) and what it is.
    private static func copyAttachments(from original: PDFModel, to model: PDFModel) throws {
        for file in original.embeddedFiles() {
            guard let data = try original.embeddedFileData(named: file.name) else { continue }
            let mime = file.mimeType ?? ArchiveTemp.mimeType(forFileName: file.fileName)
            model.addEmbeddedFile(data, name: file.name, fileName: file.fileName, mimeType: mime, description: file.description,
                                  creationDate: file.creationDate, modificationDate: file.modificationDate ?? Date(),
                                  relationship: file.relationship ?? "Unspecified")
        }
    }

    /// /Info and the XMP packet saying the same things: title, author, subject, keywords, creator tool, producer, dates.
    private static func setMetadata(_ model: PDFModel, original: PDFModel, identification: [(String, String)], namespaces: [String: String],
                                    extra: [(String, String)] = []) {
        let title = model.info("Title") ?? original.info("Title")
        let author = model.info("Author") ?? original.info("Author")
        let subject = model.info("Subject") ?? original.info("Subject")
        let keywords = model.info("Keywords") ?? original.info("Keywords")
        let creator = original.info("Creator") ?? model.info("Creator")
        let now = Date()
        // Whole seconds, so /Info's PDF dates and the XMP dates are the same instant.
        let modified = Date(timeIntervalSince1970: now.timeIntervalSince1970.rounded(.down))
        let created = original.info("CreationDate").flatMap(PDFDate.date) ?? modified
        let producer = Strings.appName

        if let info = model.trailer["Info"] {
            for key in info.keys where !["Title", "Author", "Subject", "Keywords", "Creator", "Producer", "CreationDate", "ModDate", "Trapped",
                                          "GTS_PDFXVersion", "GTS_PDFXConformance"].contains(key) {
                info.remove(key)
            }
        }
        model.setInfo("Title", title)
        model.setInfo("Author", author)
        model.setInfo("Subject", subject)
        model.setInfo("Keywords", keywords)
        model.setInfo("Creator", creator)
        model.setInfo("Producer", producer)
        model.trailer["Info"]?.set("CreationDate", .ascii(PDFDate.string(created)))
        model.trailer["Info"]?.set("ModDate", .ascii(PDFDate.string(modified)))

        let packet = ArchiveXMP.packet(identification: identification, namespaces: namespaces, title: title, author: author, subject: subject,
                                       keywords: keywords, creatorTool: creator, producer: producer, created: created, modified: modified,
                                       extra: extra)
        let stream = model.makeStream(["Type": .name("Metadata"), "Subtype": .name("XML")], data: packet)
        model.root.set("Metadata", stream)
    }
}

extension ArchivePageScan {
    /// The form XObjects a page draws (directly or nested).
    static func forms(of page: PDFPage) -> [PDFObject] {
        var found: [PDFObject] = []
        var visited: Set<Int> = []
        func walk(_ resources: PDFObject?, depth: Int) {
            guard let resources, depth < 24 else { return }
            for key in resources["XObject"]?.keys ?? [] {
                guard let object = resources["XObject"]?[key], object.type == .stream, object["Subtype"]?.name == "Form" else { continue }
                if let id = object.objectID, !visited.insert(id).inserted { continue }
                found.append(object)
                walk(object["Resources"], depth: depth + 1)
            }
        }
        walk(page.resources, depth: 0)
        return found
    }
}

enum ArchiveTemp {
    static func file() -> URL {
        FileManager.default.temporaryDirectory.appendingPathComponent("superpdf-archive-\(UUID().uuidString).pdf")
    }

    /// A MIME type from a file name, for PDF/A-3 attachments that didn't record one.
    static func mimeType(forFileName name: String) -> String {
        let ext = (name as NSString).pathExtension.lowercased()
        let known = ["pdf": "application/pdf", "xml": "application/xml", "json": "application/json", "txt": "text/plain", "csv": "text/csv",
                     "png": "image/png", "jpg": "image/jpeg", "jpeg": "image/jpeg", "html": "text/html"]
        return known[ext] ?? "application/octet-stream"
    }
}
