import AppKit
import CoreGraphics
import ImageIO
import PDFModelKit
import SuperPDFCore

// Writing PDFs from converted content, off the main actor: attributed text paginated with TextKit (features #35, #38,
// #40, #45), pictures one per page (#34), and several PDFs joined with a contents entry each (#44, multi-file
// "Any file → PDF").

/// What an importer needs to lay out pages.
struct ImportOptions: Sendable {
    var paper: PaperSize
    /// Points around the text or picture (ux §5.3 "margins").
    var margins: Double

    init(paper: PaperSize = .fitContent, margins: Double = 36) { self.paper = paper; self.margins = margins }

    /// The paper for flowing text: the chosen size, or the locale's (Letter in the US, A4 elsewhere) for "fit".
    var textPaper: CGSize { paper.size ?? Self.localePaper }

    static var localePaper: CGSize {
        (Locale.current.measurementSystem == .us ? PaperSize.letter : PaperSize.a4).size!
    }
}

/// What an importer says besides the PDF it wrote: the panel's or banner's notices, and inputs it left out.
struct ImportReport: Sendable {
    var notices: [String] = []
    var skipped: [URL] = []
    /// Contents entries the PDF should get (EPUB chapters, workbook sheets), page indices 0-based.
    var outline: [PDFOutlineItem] = []
}

enum ComposeError: Error, Equatable {
    case cannotCreatePDF
    case nothingToConvert
}

// MARK: - Text pagination

enum TextPaginator {
    /// Lays `text` out on pages of `paper` with `margins` and writes them to `url`; returns the page count. Pictures
    /// wider or taller than the text area are scaled to fit; links stay clickable.
    @discardableResult
    static func write(_ text: NSAttributedString, to url: URL, paper: CGSize, margins: CGFloat, title: String? = nil) throws -> Int {
        let area = CGSize(width: max(paper.width - 2 * margins, 72), height: max(paper.height - 2 * margins, 72))
        let storage = NSTextStorage(attributedString: fitAttachments(text, in: area))
        let layout = NSLayoutManager()
        layout.allowsNonContiguousLayout = false
        storage.addLayoutManager(layout)

        var containers: [NSTextContainer] = []
        while true {
            let container = NSTextContainer(size: area)
            container.lineFragmentPadding = 0
            layout.addTextContainer(container)
            containers.append(container)
            let range = layout.glyphRange(for: container)
            if range.length == 0 && containers.count > 1 { layout.removeTextContainer(at: containers.count - 1); containers.removeLast(); break }
            if NSMaxRange(range) >= layout.numberOfGlyphs { break }
            if containers.count > 20_000 { break }
        }

        var box = CGRect(origin: .zero, size: paper)
        var info: [CFString: Any] = [kCGPDFContextCreator: Strings.appName]
        if let title, !title.isEmpty { info[kCGPDFContextTitle] = title }
        guard let context = CGContext(url as CFURL, mediaBox: &box, info as CFDictionary) else { throw ComposeError.cannotCreatePDF }
        let graphics = NSGraphicsContext(cgContext: context, flipped: true)
        for container in containers {
            context.beginPDFPage(nil)
            context.saveGState()
            context.translateBy(x: 0, y: paper.height)
            context.scaleBy(x: 1, y: -1)
            NSGraphicsContext.saveGraphicsState()
            NSGraphicsContext.current = graphics
            let glyphs = layout.glyphRange(for: container)
            let origin = CGPoint(x: margins, y: margins)
            layout.drawBackground(forGlyphRange: glyphs, at: origin)
            layout.drawGlyphs(forGlyphRange: glyphs, at: origin)
            NSGraphicsContext.restoreGraphicsState()
            context.restoreGState()
            addLinks(layout: layout, storage: storage, container: container, glyphs: glyphs, origin: origin, pageHeight: paper.height, context: context)
            context.endPDFPage()
        }
        context.closePDF()
        return containers.count
    }

    /// Clickable links where the text carries `.link`.
    private static func addLinks(layout: NSLayoutManager, storage: NSTextStorage, container: NSTextContainer, glyphs: NSRange,
                                 origin: CGPoint, pageHeight: CGFloat, context: CGContext) {
        let characters = layout.characterRange(forGlyphRange: glyphs, actualGlyphRange: nil)
        storage.enumerateAttribute(.link, in: characters) { value, range, _ in
            let target: URL? = (value as? URL) ?? (value as? String).flatMap(URL.init(string:))
            guard let target, let scheme = target.scheme?.lowercased(), ["http", "https", "mailto"].contains(scheme) else { return }
            let glyphRange = layout.glyphRange(forCharacterRange: range, actualCharacterRange: nil)
            layout.enumerateEnclosingRects(forGlyphRange: glyphRange, withinSelectedGlyphRange: NSRange(location: NSNotFound, length: 0),
                                           in: container) { rect, _ in
                let pdfRect = CGRect(x: origin.x + rect.minX, y: pageHeight - origin.y - rect.maxY, width: rect.width, height: rect.height)
                context.setURL(target as CFURL, for: pdfRect)
            }
        }
    }

    /// The text with every picture attachment scaled down to fit `area` (90% of its height, so a caption can follow).
    static func fitAttachments(_ text: NSAttributedString, in area: CGSize) -> NSAttributedString {
        let copy = NSMutableAttributedString(attributedString: text)
        copy.enumerateAttribute(.attachment, in: NSRange(location: 0, length: copy.length)) { value, _, _ in
            guard let attachment = value as? NSTextAttachment else { return }
            var size = attachment.bounds.size
            if size.width <= 0 || size.height <= 0 {
                let image = attachment.image ?? attachment.fileWrapper?.regularFileContents.flatMap(NSImage.init(data:))
                size = image?.size ?? .zero
            }
            guard size.width > 0, size.height > 0 else { return }
            let scale = min(1, area.width / size.width, area.height * 0.9 / size.height)
            if scale < 1 || attachment.bounds.size == .zero {
                attachment.bounds = CGRect(origin: attachment.bounds.origin, size: CGSize(width: size.width * scale, height: size.height * scale))
            }
        }
        return copy
    }
}

// MARK: - Pictures

/// One picture for a page: decoded pixels, or JPEG bytes Quartz embeds as they are (no re-encoding).
struct PagePicture {
    var image: CGImage
    /// The picture's size in points at its own resolution.
    var naturalSize: CGSize
}

enum PicturePages {
    /// Writes one page per picture. `fitContent` makes each page the picture's size; a paper size centres the picture
    /// inside the margins, turning the page to landscape for wide pictures.
    static func write(_ pictures: [PagePicture], paper: PaperSize, margins: CGFloat, to url: URL, title: String? = nil) throws {
        guard !pictures.isEmpty else { throw ComposeError.nothingToConvert }
        var box = CGRect(origin: .zero, size: CGSize(width: 612, height: 792))
        var info: [CFString: Any] = [kCGPDFContextCreator: Strings.appName]
        if let title, !title.isEmpty { info[kCGPDFContextTitle] = title }
        guard let context = CGContext(url as CFURL, mediaBox: &box, info as CFDictionary) else { throw ComposeError.cannotCreatePDF }
        for picture in pictures {
            let natural = clamp(picture.naturalSize)
            let pageSize: CGSize
            let drawRect: CGRect
            if var paper = paper.size {
                if natural.width > natural.height, paper.width < paper.height { paper = CGSize(width: paper.height, height: paper.width) }
                let area = CGRect(origin: .zero, size: paper).insetBy(dx: margins, dy: margins)
                let scale = min(area.width / natural.width, area.height / natural.height, 1)
                let size = CGSize(width: natural.width * scale, height: natural.height * scale)
                pageSize = paper
                drawRect = CGRect(x: area.midX - size.width / 2, y: area.midY - size.height / 2, width: size.width, height: size.height)
            } else {
                pageSize = natural
                drawRect = CGRect(origin: .zero, size: natural)
            }
            var media = CGRect(origin: .zero, size: pageSize)
            let pageInfo = [kCGPDFContextMediaBox: Data(bytes: &media, count: MemoryLayout<CGRect>.size) as CFData] as CFDictionary
            context.beginPDFPage(pageInfo)
            context.interpolationQuality = .high
            context.draw(picture.image, in: drawRect)
            context.endPDFPage()
        }
        context.closePDF()
    }

    /// PDF pages can't exceed 14,400 pt a side; a 4032 × 3024 photo at 72 dpi stays as it is.
    private static func clamp(_ size: CGSize) -> CGSize {
        let limit: CGFloat = 14_400
        let scale = min(1, limit / max(size.width, 1), limit / max(size.height, 1))
        return CGSize(width: max(size.width * scale, 1), height: max(size.height * scale, 1))
    }

    /// Every frame of an image file (multi-page TIFF expands), upright (EXIF orientation applied). JPEGs without a
    /// rotation keep their compressed bytes.
    static func pictures(from url: URL) throws -> [PagePicture] {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, [kCGImageSourceShouldCache: false] as CFDictionary) else {
            throw ComposeError.nothingToConvert
        }
        let count = CGImageSourceGetCount(source)
        let isJPEG = (CGImageSourceGetType(source) as String?) == "public.jpeg"
        var pictures: [PagePicture] = []
        for index in 0..<count {
            let properties = CGImageSourceCopyPropertiesAtIndex(source, index, nil) as? [CFString: Any] ?? [:]
            let width = (properties[kCGImagePropertyPixelWidth] as? NSNumber)?.doubleValue ?? 0
            let height = (properties[kCGImagePropertyPixelHeight] as? NSNumber)?.doubleValue ?? 0
            let orientation = (properties[kCGImagePropertyOrientation] as? NSNumber)?.intValue ?? 1
            let dpi = max((properties[kCGImagePropertyDPIWidth] as? NSNumber)?.doubleValue ?? 72, 1)
            guard width > 0, height > 0 else { continue }
            let image: CGImage?
            if isJPEG, count == 1, orientation == 1, let provider = CGDataProvider(url: url as CFURL) {
                image = CGImage(jpegDataProviderSource: provider, decode: nil, shouldInterpolate: true, intent: .defaultIntent)
            } else {
                let options: [CFString: Any] = [kCGImageSourceCreateThumbnailFromImageAlways: true, kCGImageSourceCreateThumbnailWithTransform: true,
                                                kCGImageSourceThumbnailMaxPixelSize: max(width, height), kCGImageSourceShouldCacheImmediately: true]
                image = CGImageSourceCreateThumbnailAtIndex(source, index, options as CFDictionary)
            }
            guard let image else { continue }
            let rotated = orientation >= 5
            let pixels = rotated ? CGSize(width: height, height: width) : CGSize(width: width, height: height)
            pictures.append(PagePicture(image: image, naturalSize: CGSize(width: pixels.width * 72 / dpi, height: pixels.height * 72 / dpi)))
        }
        guard !pictures.isEmpty else { throw ComposeError.nothingToConvert }
        return pictures
    }
}

// MARK: - Joining PDFs

enum PDFAssembler {
    struct Part {
        var url: URL
        /// The contents entry for this part; nil adds none.
        var title: String?
        /// Entries inside the part (its own outline or an importer's chapters), nested under `title`.
        var outline: [PDFOutlineItem] = []
    }

    /// Joins the parts in order into `destination`, with a contents entry per titled part that holds the part's own
    /// entries, shifted to where its pages landed. Returns the page count.
    @discardableResult
    static func join(_ parts: [Part], to destination: URL, title: String? = nil) throws -> Int {
        guard !parts.isEmpty else { throw ComposeError.nothingToConvert }
        // One part as it is: nothing to join, and its links, attachments and metadata stay.
        if parts.count == 1, parts[0].title == nil, parts[0].outline.isEmpty, title == nil {
            if FileManager.default.fileExists(atPath: destination.path) { try FileManager.default.removeItem(at: destination) }
            try FileManager.default.copyItem(at: parts[0].url, to: destination)
            return try PDFModel(url: destination).pageCount
        }
        let out = PDFModel()
        var outline: [PDFOutlineItem] = []
        // QPDF copies pages from another document lazily: every source stays open until the result is written.
        var sources: [PDFModel] = []
        for part in parts {
            let model = try PDFModel(url: part.url)
            sources.append(model)
            let start = out.pageCount
            try out.insertPages(from: model, pages: Array(0..<model.pageCount), at: start)
            for file in model.embeddedFiles() {
                guard let data = try model.embeddedFileData(named: file.name) else { continue }
                out.addEmbeddedFile(data, name: file.name, fileName: file.fileName, mimeType: file.mimeType, description: file.description,
                                    creationDate: file.creationDate, modificationDate: file.modificationDate)
            }
            let own = (part.outline.isEmpty ? model.outlines() : part.outline).map { shift($0, by: start) }
            if let title = part.title {
                outline.append(PDFOutlineItem(title: title, destination: PDFDestination(page: start), children: own))
            } else {
                outline += own
            }
        }
        if !outline.isEmpty { out.setOutlines(outline) }
        if let title = title ?? (parts.count == 1 ? sources.first?.info("Title") : nil) { out.setInfo("Title", title) }
        out.setInfo("Creator", Strings.appName)
        try withExtendedLifetime(sources) { try out.write(to: destination) }
        return out.pageCount
    }

    private static func shift(_ item: PDFOutlineItem, by offset: Int) -> PDFOutlineItem {
        var item = item
        if var destination = item.destination { destination.page += offset; item.destination = destination }
        item.children = item.children.map { shift($0, by: offset) }
        return item
    }
}

extension String {
    /// A file's name without its extension, for titles and contents entries.
    static func baseName(_ url: URL) -> String { url.deletingPathExtension().lastPathComponent }
}
