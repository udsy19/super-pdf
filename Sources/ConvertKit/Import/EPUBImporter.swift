import Foundation
import PDFModelKit
import SuperPDFCore

/// EPUB → PDF (features #42): unpack, read the package's reading order (spine), render each chapter with WebKit, join
/// them with a contents entry per chapter from the book's own table of contents (EPUB 3 nav or EPUB 2 NCX).
enum EPUBImporter {
    @MainActor
    static func convert(_ input: URL, to output: URL, options: ImportOptions) async throws -> ImportReport {
        let folder = output.deletingLastPathComponent().appendingPathComponent("epub-" + UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let book = try await Task.detached(priority: .userInitiated) { try Book.open(input, into: folder) }.value

        var parts: [PDFAssembler.Part] = []
        for (index, chapter) in book.chapters.enumerated() {
            try Task.checkCancellation()
            let pdf = folder.appendingPathComponent("chapter-\(index).pdf")
            do {
                try await WebRenderer.render(file: chapter.file, paper: options.textPaper, margins: CGFloat(options.margins), to: pdf, title: book.title)
                parts.append(PDFAssembler.Part(url: pdf, title: chapter.title))
            } catch is CancellationError {
                throw CancellationError()
            } catch {
                continue   // one unreadable chapter doesn't lose the book
            }
        }
        guard !parts.isEmpty else { throw ComposeError.nothingToConvert }
        _ = try await Task.detached(priority: .userInitiated) { try PDFAssembler.join(parts, to: output, title: book.title) }.value
        return ImportReport()
    }

    struct Chapter: Sendable {
        var file: URL
        /// The table of contents' name for it; nil when the contents don't list it.
        var title: String?
    }

    struct Book: Sendable {
        var title: String?
        var chapters: [Chapter]

        static func open(_ url: URL, into folder: URL) throws -> Book {
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            let archive = try ZipArchive(url: url)
            if let encryption = try archive.data("META-INF/encryption.xml"), try isProtected(encryption) {
                throw ConvertError.unsupported("protected book")
            }
            try archive.extract(to: folder)
            guard let container = try archive.data("META-INF/container.xml"),
                  let packagePath = try XML.parse(container).first("rootfile")?.attr("full-path"),
                  let packageData = try archive.data(packagePath) else { throw ConvertError.unsupported("no package") }
            let package = try XML.parse(packageData)
            let packageFolder = (packagePath as NSString).deletingLastPathComponent

            func resolve(_ href: String, from base: String) -> String {
                let path = (href.removingPercentEncoding ?? href).components(separatedBy: "#")[0]
                let joined = base.isEmpty ? path : base + "/" + path
                return (joined as NSString).standardizingPath.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
            }

            var manifest: [String: (path: String, type: String, properties: String)] = [:]
            for item in package.all("item") {
                guard let id = item.attr("id"), let href = item.attr("href") else { continue }
                manifest[id] = (resolve(href, from: packageFolder), item.attr("media-type") ?? "", item.attr("properties") ?? "")
            }

            // Chapter names: EPUB 3 nav first, else the EPUB 2 NCX.
            var titles: [String: String] = [:]
            if let nav = manifest.values.first(where: { $0.properties.split(separator: " ").contains("nav") }),
               let data = try archive.data(nav.path), let document = try? XML.parse(data) {
                let navFolder = (nav.path as NSString).deletingLastPathComponent
                let toc = document.all("nav").first { $0.attr("epub:type") == "toc" || $0.attr("type") == "toc" } ?? document.first("nav")
                for link in toc?.all("a") ?? [] {
                    guard let href = link.attr("href") else { continue }
                    let path = resolve(href, from: navFolder)
                    let text = link.allText.trimmingCharacters(in: .whitespacesAndNewlines)
                    if titles[path] == nil, !text.isEmpty { titles[path] = text }
                }
            }
            if titles.isEmpty, let ncxID = package.first("spine")?.attr("toc"), let ncx = manifest[ncxID],
               let data = try archive.data(ncx.path), let document = try? XML.parse(data) {
                let ncxFolder = (ncx.path as NSString).deletingLastPathComponent
                for point in document.all("navPoint") {
                    guard let src = point.child("content")?.attr("src") else { continue }
                    let path = resolve(src, from: ncxFolder)
                    let text = point.child("navLabel")?.allText.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
                    if titles[path] == nil, !text.isEmpty { titles[path] = text }
                }
            }

            var chapters: [Chapter] = []
            for reference in package.first("spine")?.children("itemref") ?? [] where reference.attr("linear") != "no" {
                guard let id = reference.attr("idref"), let item = manifest[id],
                      item.type.contains("html") || item.path.hasSuffix("html") || item.path.hasSuffix("htm") else { continue }
                let file = item.path.split(separator: "/").reduce(folder) { $0.appendingPathComponent(String($1)) }
                guard FileManager.default.fileExists(atPath: file.path) else { continue }
                chapters.append(Chapter(file: file, title: titles[item.path]))
            }
            guard !chapters.isEmpty else { throw ComposeError.nothingToConvert }
            let title = package.first("title")?.allText.trimmingCharacters(in: .whitespacesAndNewlines)
            return Book(title: title?.isEmpty == false ? title : nil, chapters: chapters)
        }

        /// DRM: encrypted content documents (font obfuscation alone is harmless).
        private static func isProtected(_ data: Data) throws -> Bool {
            let document = try XML.parse(data)
            return document.all("EncryptedData").contains { encrypted in
                let algorithm = encrypted.first("EncryptionMethod")?.attr("Algorithm") ?? ""
                let target = encrypted.first("CipherReference")?.attr("URI") ?? ""
                let isFontObfuscation = algorithm.contains("obfuscation") || algorithm.contains("font")
                let isFont = [".otf", ".ttf", ".woff", ".woff2"].contains { target.lowercased().hasSuffix($0) }
                return !(isFontObfuscation || isFont)
            }
        }
    }
}
