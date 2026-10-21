import AppKit
import CoreGraphics
import CoreText
import Foundation
import PDFModelKit
import SuperPDFCore

// Where a decoration goes on a page (features #64–#67, #30): the same layout feeds the live preview (drawn with
// Core Graphics over the page) and the writer (form XObjects in the content stream), so what you see while typing is
// what gets written. Positions are in the page as shown (upright, origin at the shown page's lower left).

/// What fills the tokens of headers and footers.
struct DecorationContext {
    var title: String
    var fileName: String
    var author: String
    var pageCount: Int
    var date: Date
    /// Bates numbering in force, for the Bates token of headers (nil: plain page numbers).
    var bates: BatesNumbering?

    init(title: String = "", fileName: String = "", author: String = "", pageCount: Int = 1, date: Date = Date(), bates: BatesNumbering? = nil) {
        self.title = title; self.fileName = fileName; self.author = author; self.pageCount = pageCount; self.date = date; self.bates = bates
    }
}

/// A picture for a watermark or background.
enum DecorationPicture {
    case image(CGImage, file: URL)
    /// The first page of a PDF (its model is kept so the page can be imported).
    case pdfPage(PDFModel, size: CGSize, file: URL)

    var aspect: Double {
        switch self {
        case .image(let image, _): Double(image.width) / Double(max(image.height, 1))
        case .pdfPage(_, let size, _): size.width / max(size.height, 1)
        }
    }

    /// Loads an image file or a PDF's first page.
    static func load(_ url: URL) -> DecorationPicture? {
        if url.pathExtension.lowercased() == "pdf" || (try? Data(contentsOf: url, options: .mappedIfSafe))?.prefix(5) == Data("%PDF-".utf8) {
            guard let model = try? PDFModel(url: url), let page = model.page(at: 0) else { return nil }
            return .pdfPage(model, size: page.displaySize, file: url)
        }
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil), let image = CGImageSourceCreateImageAtIndex(source, 0, nil) else { return nil }
        return .image(image, file: url)
    }
}

/// One thing drawn on a page.
struct DecorationItem {
    enum Content {
        case text(String, fontName: String, fontSize: Double, color: String)
        case picture(DecorationPicture)
        case fill(String)
    }

    var content: Content
    /// The box the content fills, in the shown page's space, before rotation.
    var frame: CGRect
    /// Degrees counter-clockwise about the frame's centre.
    var rotation: Double
    var opacity: Double
    var layer: Watermark.Layer
    var visibility: Watermark.Visibility
    var kind: DecorationKind
    /// The pagination artifact subtype written with it.
    var artifactSubtype: String
}

enum DecorationLayout {
    /// The items a decoration puts on page `index` of a document whose pages show at `size`.
    static func items(for decoration: Decoration, pageIndex index: Int, pageSize size: CGSize, context: DecorationContext) -> [DecorationItem] {
        switch decoration {
        case .headerFooter(let header):
            return headerItems(header, pageIndex: index, pageSize: size, context: context)
        case .pageNumbers(let numbering):
            guard index >= numbering.skipFirst else { return [] }
            let number = numbering.startAt + index - numbering.skipFirst
            let text = numbering.style.text(number, of: context.pageCount - numbering.skipFirst + numbering.startAt - 1)
            return [textItem(text, style: numbering.text, position: numbering.position, margins: 36, pageSize: size, kind: .pageNumbers)]
        case .bates(let bates):
            return [textItem(bates.label(bates.start + index), style: bates.style, position: bates.position, margins: 36, pageSize: size, kind: .bates)]
        case .watermark(let watermark):
            return [watermarkItem(watermark, pageSize: size, kind: .watermark, context: context)].compactMap { $0 }
        case .background(let background):
            var item = watermarkItem(background, pageSize: size, kind: .background, context: context)
            item?.layer = .behind
            return [item].compactMap { $0 }
        }
    }

    // MARK: Text

    /// The six fields of a header/footer, each its own item.
    static func headerItems(_ header: HeaderFooter, pageIndex index: Int, pageSize size: CGSize, context: DecorationContext) -> [DecorationItem] {
        var items: [DecorationItem] = []
        for (position, parts) in header.fields.sorted(by: { $0.key.rawValue < $1.key.rawValue }) {
            let text = render(parts, pageIndex: index, header: header, context: context)
            guard !text.isEmpty else { continue }
            items.append(textItem(text, style: header.style, position: position, margins: header.margins, pageSize: size, kind: .headerFooter))
        }
        return items
    }

    /// The text of a field: literal parts and tokens filled in.
    static func render(_ parts: [HeaderFooterPart], pageIndex index: Int, header: HeaderFooter, context: DecorationContext) -> String {
        parts.map { part -> String in
            switch part {
            case .text(let text): return text
            case .pageNumber: return String(header.startNumber + index)
            case .pageCount: return String(context.pageCount + header.startNumber - 1)
            case .date:
                let formatter = DateFormatter()
                formatter.dateFormat = header.dateFormat
                return formatter.string(from: context.date)
            case .title: return context.title.isEmpty ? context.fileName : context.title
            case .fileName: return context.fileName
            case .author: return context.author
            case .batesNumber: return context.bates.map { $0.label($0.start + index) } ?? String(format: "%06d", header.startNumber + index)
            }
        }.joined()
    }

    /// A text item at one of the grid spots, `margins` from the edges.
    static func textItem(_ text: String, style: DecorationStyle, position: PagePosition, margins: Double, pageSize size: CGSize, kind: DecorationKind) -> DecorationItem {
        let font = nsFont(style.fontName, size: style.fontSize)
        let width = textWidth(text, font: font)
        let ascent = Double(font.ascender), descent = -Double(font.descender)
        let height = ascent + descent
        let column = position.rawValue % 3, row = position.rawValue / 3
        let x: Double = switch column {
        case 0: margins
        case 1: (size.width - width) / 2
        default: size.width - margins - width
        }
        let y: Double = switch row {
        case 0: size.height - margins - height
        case 1: (size.height - height) / 2
        default: margins
        }
        let subtype = row == 0 ? "Header" : "Footer"
        return DecorationItem(content: .text(text, fontName: style.fontName, fontSize: style.fontSize, color: style.color),
                              frame: CGRect(x: x, y: y, width: width, height: height), rotation: 0, opacity: 1, layer: .over, visibility: .always,
                              kind: kind, artifactSubtype: subtype)
    }

    // MARK: Watermarks and backgrounds

    static func watermarkItem(_ watermark: Watermark, pageSize size: CGSize, kind: DecorationKind, context: DecorationContext) -> DecorationItem? {
        let margins = 36.0
        let column = watermark.position.rawValue % 3, row = watermark.position.rawValue / 3
        var frame: CGRect
        var content: DecorationItem.Content
        switch watermark.content {
        case .text(let text, let style):
            guard !text.isEmpty else { return nil }
            // The font size that makes the text `scale` of the page width (the style's size is a floor at tiny scales).
            let base = nsFont(style.fontName, size: 100)
            let widthAt100 = max(textWidth(text, font: base), 1)
            let fontSize = max(6, 100 * (watermark.scale * size.width) / widthAt100)
            let font = nsFont(style.fontName, size: fontSize)
            let width = textWidth(text, font: font)
            let height = Double(font.ascender - font.descender)
            frame = CGRect(x: 0, y: 0, width: width, height: height)
            content = .text(text, fontName: style.fontName, fontSize: fontSize, color: style.color)
        case .file(let url):
            guard let picture = DecorationPicture.load(url) else { return nil }
            let width = watermark.scale * size.width
            frame = CGRect(x: 0, y: 0, width: width, height: width / picture.aspect)
            content = .picture(picture)
        case .color(let hex):
            frame = CGRect(origin: .zero, size: size)
            content = .fill(hex)
        }
        if case .fill = content {} else {
            let x: Double = switch column {
            case 0: margins
            case 1: (size.width - frame.width) / 2
            default: size.width - margins - frame.width
            }
            let y: Double = switch row {
            case 0: size.height - margins - frame.height
            case 1: (size.height - frame.height) / 2
            default: margins
            }
            frame.origin = CGPoint(x: x, y: y)
        }
        var rotation = watermark.rotation
        if case .fill = content { rotation = 0 }   // a colour fills the page; turning it would leave corners bare
        return DecorationItem(content: content, frame: frame, rotation: rotation, opacity: watermark.opacity, layer: watermark.layer,
                              visibility: watermark.visibility, kind: kind, artifactSubtype: kind == .background ? "Background" : "Watermark")
    }

    // MARK: Fonts and measuring

    /// The system font that draws (and measures) a decoration font name: the standard 14 by their faces, anything else
    /// by name, Helvetica when unknown.
    static func nsFont(_ name: String, size: Double) -> NSFont {
        if FontEmbedder.standardNames.contains(name) { return NSFont(descriptor: (FontEmbedder.measuringFont(for: name) as NSFont).fontDescriptor, size: size) ?? NSFont.systemFont(ofSize: size) }
        if let font = NSFont(name: name, size: size) { return font }
        return NSFont(name: "Helvetica", size: size) ?? NSFont.systemFont(ofSize: size)
    }

    static func textWidth(_ text: String, font: NSFont) -> Double {
        let line = CTLineCreateWithAttributedString(NSAttributedString(string: text, attributes: [.font: font]))
        return CTLineGetTypographicBounds(line, nil, nil, nil)
    }

    /// The transform that puts an item's frame on the page with its rotation (frame space → shown page space).
    static func placement(of item: DecorationItem) -> CGAffineTransform {
        guard item.rotation != 0 else { return .identity }
        let center = CGPoint(x: item.frame.midX, y: item.frame.midY)
        return CGAffineTransform(translationX: center.x, y: center.y).rotated(by: item.rotation * .pi / 180).translatedBy(x: -center.x, y: -center.y)
    }
}
