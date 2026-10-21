import CoreGraphics
import CoreText
import Foundation
import ImageIO
import PDFModelKit

// How signatures, initials, dates and text look on the page, and the visible part of a certificate signature (features
// #82: "visible appearance with name/date/reason/location"). The same drawing serves the live preview (PDFKit's overlay,
// page space) and the file (a one-page Quartz PDF turned into the form XObject of a stamp or widget), so what the
// panel shows is what the file holds. Core Graphics and Core Text only: it runs off the main actor.

/// What a placement draws.
enum Mark: Hashable, Sendable {
    /// A transparent PNG (a saved signature or initials).
    case image(Data)
    /// A line of text, set to fill the box's height (today's date, typed text).
    case text(String)
    /// The first page of a PDF, stretched over the box (what a signer's copy shows in their field, features #84).
    case pdf(Data)
}

/// The visible part of a certificate signature: the person's handwritten signature when they have one, and the facts.
struct SealAppearance: Hashable, Sendable {
    var image: Data?
    var name: String
    var date: Date
    var reason: String
    var location: String

    var lines: [String] {
        var lines = [SignStrings.digitallySignedBy, name, SignStrings.sealDate(date)]
        if !reason.isEmpty { lines.append(SignStrings.sealReason(reason)) }
        if !location.isEmpty { lines.append(SignStrings.sealLocation(location)) }
        return lines
    }
}

enum Appearance {
    /// The ink of typed text and of the certificate box's words.
    static let ink = CGColor(srgbRed: 0.10, green: 0.10, blue: 0.12, alpha: 1)

    /// Draws `mark` filling `rect` (images keep their aspect ratio, centred).
    static func draw(_ mark: Mark, in rect: CGRect, context: CGContext) {
        switch mark {
        case .image(let data):
            guard let image = cgImage(data) else { return }
            context.draw(image, in: fit(CGSize(width: image.width, height: image.height), in: rect))
        case .text(let string):
            drawLine(string, in: rect, size: rect.height * 0.72, context: context)
        case .pdf(let data):
            guard let provider = CGDataProvider(data: data as CFData), let document = CGPDFDocument(provider),
                  let page = document.page(at: 1) else { return }
            let box = page.getBoxRect(.mediaBox)
            guard box.width > 0, box.height > 0 else { return }
            context.saveGState()
            context.translateBy(x: rect.minX, y: rect.minY)
            context.scaleBy(x: rect.width / box.width, y: rect.height / box.height)
            context.translateBy(x: -box.minX, y: -box.minY)
            context.drawPDFPage(page)
            context.restoreGState()
        }
    }

    /// The certificate box: the handwritten signature on the left when there is one, the facts on the right.
    static func drawSeal(_ seal: SealAppearance, in rect: CGRect, context: CGContext) {
        var textRect = rect.insetBy(dx: 4, dy: 3)
        if let data = seal.image, let image = cgImage(data) {
            let split = rect.width * 0.48
            let imageRect = CGRect(x: rect.minX + 2, y: rect.minY + 2, width: split - 6, height: rect.height - 4)
            context.draw(image, in: fit(CGSize(width: image.width, height: image.height), in: imageRect))
            textRect = CGRect(x: rect.minX + split + 2, y: rect.minY + 3, width: rect.width - split - 6, height: rect.height - 6)
        }
        let lines = seal.lines
        guard !lines.isEmpty, textRect.width > 4, textRect.height > 4 else { return }
        var size = min(textRect.height / (CGFloat(lines.count) * 1.25), 11)
        // Shrink until the widest line fits.
        while size > 3, lines.map({ lineWidth($0, size: $0 == seal.name ? size * 1.15 : size) }).max() ?? 0 > textRect.width { size -= 0.25 }
        var y = textRect.maxY
        for line in lines {
            let lineSize = line == seal.name ? size * 1.15 : size
            y -= lineSize * 1.2
            drawLine(line, in: CGRect(x: textRect.minX, y: y, width: textRect.width, height: lineSize * 1.2), size: lineSize, context: context,
                     bold: line == seal.name)
        }
    }

    // MARK: Pages

    /// Sets up `context` so that drawing into the returned rectangle shows upright on a page turned by `rotation`
    /// degrees (the page's /Rotate): placements are stored in page space, people see them the way the page is shown.
    static func upright(_ rect: CGRect, rotation: Int, context: CGContext) -> CGRect {
        let r = ((rotation % 360) + 360) % 360
        switch r {
        // The page turns clockwise when shown, so the drawing turns the other way (as `formXObject`'s /Matrix).
        case 90:
            context.translateBy(x: rect.maxX, y: rect.minY)
            context.rotate(by: .pi / 2)
            return CGRect(x: 0, y: 0, width: rect.height, height: rect.width)
        case 180:
            context.translateBy(x: rect.maxX, y: rect.maxY)
            context.rotate(by: .pi)
            return CGRect(x: 0, y: 0, width: rect.width, height: rect.height)
        case 270:
            context.translateBy(x: rect.minX, y: rect.maxY)
            context.rotate(by: -.pi / 2)
            return CGRect(x: 0, y: 0, width: rect.height, height: rect.width)
        default:
            return rect
        }
    }

    /// A form XObject in `model` for a box of `rect` (page space) on a page turned by `rotation`, drawn upright by `draw`
    /// into the rectangle it is given. QPDF copies the drawing's streams (fonts, pictures) only when `model` is written,
    /// so the drawing's own model goes into `sources`, which the caller keeps until then.
    static func formXObject(in model: PDFModel, rect: CGRect, rotation: Int, sources: inout [PDFModel],
                            draw: (CGRect, CGContext) -> Void) throws -> PDFObject {
        let r = ((rotation % 360) + 360) % 360
        let size = r == 90 || r == 270 ? CGSize(width: rect.height, height: rect.width) : rect.size
        let page = try onePagePDF(size: size) { context in draw(CGRect(origin: .zero, size: size), context) }
        let source = try PDFModel(data: page)
        sources.append(source)
        guard let sourcePage = source.page(at: 0) else { throw PDFModelError.failed("appearance page") }
        let form = try model.formXObject(from: sourcePage)
        // The appearance turns with the page so it reads upright; the annotation's /Rect is in page space.
        let turn: CGAffineTransform = switch r {
        case 90: CGAffineTransform(a: 0, b: 1, c: -1, d: 0, tx: 0, ty: 0)
        case 180: CGAffineTransform(a: -1, b: 0, c: 0, d: -1, tx: 0, ty: 0)
        case 270: CGAffineTransform(a: 0, b: -1, c: 1, d: 0, tx: 0, ty: 0)
        default: .identity
        }
        if r != 0 { form.set("Matrix", .matrix(turn)) }
        return form
    }

    /// A one-page PDF drawn by `draw` (Quartz embeds the fonts and images it uses).
    static func onePagePDF(size: CGSize, draw: (CGContext) -> Void) throws -> Data {
        let data = NSMutableData()
        var box = CGRect(origin: .zero, size: CGSize(width: max(size.width, 1), height: max(size.height, 1)))
        guard let consumer = CGDataConsumer(data: data as CFMutableData), let context = CGContext(consumer: consumer, mediaBox: &box, nil) else {
            throw PDFModelError.failed("appearance context")
        }
        context.beginPDFPage(nil)
        draw(context)
        context.endPDFPage()
        context.closePDF()
        return data as Data
    }

    // MARK: Pieces

    static func cgImage(_ data: Data) -> CGImage? {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil) else { return nil }
        return CGImageSourceCreateImageAtIndex(source, 0, nil)
    }

    /// `size` scaled to fit `rect`, centred.
    static func fit(_ size: CGSize, in rect: CGRect) -> CGRect {
        guard size.width > 0, size.height > 0 else { return rect }
        let scale = min(rect.width / size.width, rect.height / size.height)
        let w = size.width * scale, h = size.height * scale
        return CGRect(x: rect.midX - w / 2, y: rect.midY - h / 2, width: w, height: h)
    }

    static func font(size: CGFloat, bold: Bool = false) -> CTFont {
        let base = CTFontCreateUIFontForLanguage(bold ? .emphasizedSystem : .system, size, nil)
            ?? CTFontCreateWithName("Helvetica" as CFString, size, nil)
        return base
    }

    static func lineWidth(_ text: String, size: CGFloat, bold: Bool = false) -> CGFloat {
        let line = CTLineCreateWithAttributedString(attributed(text, size: size, bold: bold, color: ink))
        return CGFloat(CTLineGetTypographicBounds(line, nil, nil, nil))
    }

    /// One line of text in `rect`, left-aligned, at `size` or smaller so it fits the width, centred on the rect's height.
    static func drawLine(_ text: String, in rect: CGRect, size: CGFloat, context: CGContext, bold: Bool = false, color: CGColor = ink) {
        guard !text.isEmpty, rect.width > 0, rect.height > 0 else { return }
        var size = max(size, 1)
        var line = CTLineCreateWithAttributedString(attributed(text, size: size, bold: bold, color: color))
        let width = CGFloat(CTLineGetTypographicBounds(line, nil, nil, nil))
        if width > rect.width {
            size = max(size * rect.width / width, 1)
            line = CTLineCreateWithAttributedString(attributed(text, size: size, bold: bold, color: color))
        }
        var ascent: CGFloat = 0, descent: CGFloat = 0
        CTLineGetTypographicBounds(line, &ascent, &descent, nil)
        let y = rect.midY - (ascent - descent) / 2
        context.saveGState()
        context.textMatrix = .identity
        context.textPosition = CGPoint(x: rect.minX, y: y)
        CTLineDraw(line, context)
        context.restoreGState()
    }

    /// One line of text drawn as filled glyph outlines (no text operators): PDFKit leaves text out of a text field's own
    /// appearance, so a field's label tab is drawn this way.
    static func drawOutlined(_ text: String, in rect: CGRect, size: CGFloat, context: CGContext, bold: Bool = false, color: CGColor = ink) {
        guard !text.isEmpty, rect.width > 0 else { return }
        var fontSize = size
        if lineWidth(text, size: fontSize, bold: bold) > rect.width { fontSize = max(fontSize * rect.width / lineWidth(text, size: fontSize, bold: bold), 1) }
        let line = CTLineCreateWithAttributedString(attributed(text, size: fontSize, bold: bold, color: color))
        var ascent: CGFloat = 0, descent: CGFloat = 0
        CTLineGetTypographicBounds(line, &ascent, &descent, nil)
        let baseline = CGPoint(x: rect.minX, y: rect.midY - (ascent - descent) / 2)
        let path = CGMutablePath()
        for run in CTLineGetGlyphRuns(line) as? [CTRun] ?? [] {
            let attributes = CTRunGetAttributes(run) as NSDictionary
            guard let value = attributes[kCTFontAttributeName], CFGetTypeID(value as CFTypeRef) == CTFontGetTypeID() else { continue }
            let font = value as! CTFont
            let count = CTRunGetGlyphCount(run)
            var glyphs = [CGGlyph](repeating: 0, count: count), positions = [CGPoint](repeating: .zero, count: count)
            CTRunGetGlyphs(run, CFRange(), &glyphs)
            CTRunGetPositions(run, CFRange(), &positions)
            for (glyph, position) in zip(glyphs, positions) {
                guard let outline = CTFontCreatePathForGlyph(font, glyph, nil) else { continue }
                path.addPath(outline, transform: CGAffineTransform(translationX: baseline.x + position.x, y: baseline.y + position.y))
            }
        }
        context.saveGState()
        context.setFillColor(color)
        context.addPath(path)
        context.fillPath()
        context.restoreGState()
    }

    private static func attributed(_ text: String, size: CGFloat, bold: Bool, color: CGColor) -> CFAttributedString {
        let attributes: [CFString: Any] = [kCTFontAttributeName: font(size: size, bold: bold), kCTForegroundColorAttributeName: color]
        return CFAttributedStringCreate(nil, text as CFString, attributes as CFDictionary)
    }
}
