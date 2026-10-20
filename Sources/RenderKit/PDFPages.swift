import CoreGraphics
import Foundation
import SuperPDFCore

public enum RenderError: Error, Equatable {
    case cannotOpen
    case locked
    case noSuchPage(Int)
    case cannotCreateContext
    /// No ImageIO encoder for the format on this system (WebP has none; `ImageEncoder.supportedFormats` lists them).
    case unsupportedFormat(ImageFormat)
    /// Spot plates need the content stream re-coloured, which Quartz cannot do; `ColorUsage` still lists their names.
    case unsupportedPlate(String)
    /// The raster would exceed `Rasterizer.maxPixels`.
    case tooLarge(width: Int, height: Int)
    case badProfile
}

/// Quartz-level access to a source's pages, off the main actor. Pages are drawn as displayed: /Rotate applied, crop
/// box as the visible area.
public enum PDFPages {
    public static func open(_ source: PDFSource) throws -> CGPDFDocument {
        let data = try source.bytes()
        guard let provider = CGDataProvider(data: data as CFData), let document = CGPDFDocument(provider) else { throw RenderError.cannotOpen }
        if document.isEncrypted, !document.isUnlocked {
            guard let password = source.password, document.unlockWithPassword(password) else { throw RenderError.locked }
        }
        return document
    }

    /// Page `index` (0-based).
    public static func page(_ document: CGPDFDocument, at index: Int) throws -> CGPDFPage {
        guard index >= 0, let page = document.page(at: index + 1) else { throw RenderError.noSuchPage(index) }
        return page
    }

    /// The page's size as displayed (crop box, rotated), in points.
    public static func displayedSize(_ page: CGPDFPage) -> CGSize {
        let crop = page.getBoxRect(.cropBox)
        return page.rotationAngle % 180 == 0 ? crop.size : CGSize(width: crop.height, height: crop.width)
    }

    /// Draws the page as displayed, fitted and centred in `rect` (aspect kept).
    public static func draw(_ page: CGPDFPage, in context: CGContext, fitting rect: CGRect) {
        context.saveGState()
        context.concatenate(drawingTransform(page, fitting: rect))
        context.drawPDFPage(page)
        context.restoreGState()
    }

    /// Crop box (with /Rotate) → `rect`, scaled either way and centred. `CGPDFPageGetDrawingTransform` only ever scales
    /// down, so it is used just for the rotation at the page's own size.
    public static func drawingTransform(_ page: CGPDFPage, fitting rect: CGRect) -> CGAffineTransform {
        let displayed = displayedSize(page)
        let scale = min(rect.width / max(displayed.width, 1), rect.height / max(displayed.height, 1))
        let drawn = CGSize(width: displayed.width * scale, height: displayed.height * scale)
        let placement = CGAffineTransform(translationX: rect.minX + (rect.width - drawn.width) / 2, y: rect.minY + (rect.height - drawn.height) / 2).scaledBy(x: scale, y: scale)
        return page.getDrawingTransform(.cropBox, rect: CGRect(origin: .zero, size: displayed), rotate: 0, preserveAspectRatio: true).concatenating(placement)
    }

    /// Where the page lands inside `rect` when drawn fitted.
    public static func drawnRect(_ page: CGPDFPage, fitting rect: CGRect) -> CGRect {
        page.getBoxRect(.cropBox).applying(drawingTransform(page, fitting: rect)).standardized
    }

    /// The document's Info dictionary strings as PDF-context keys, so re-rendered files keep title, author and the rest.
    public static func metadata(_ document: CGPDFDocument) -> [CFString: Any] {
        guard let info = document.info else { return [:] }
        var result: [CFString: Any] = [:]
        let keys: [(String, CFString)] = [("Title", kCGPDFContextTitle), ("Author", kCGPDFContextAuthor), ("Subject", kCGPDFContextSubject), ("Keywords", kCGPDFContextKeywords), ("Creator", kCGPDFContextCreator)]
        for (name, key) in keys {
            var string: CGPDFStringRef?
            if CGPDFDictionaryGetString(info, name, &string), let string, let value = CGPDFStringCopyTextString(string) { result[key] = value as String }
        }
        return result
    }

    /// A page box in the displayed page's coordinates (origin at the displayed page's lower-left), nil when the page
    /// has none of its own.
    public static func displayedBox(_ box: CGPDFBox, of page: CGPDFPage) -> CGRect? {
        let crop = page.getBoxRect(.cropBox)
        let rect = page.getBoxRect(box)
        guard box != .cropBox, box != .mediaBox, rect != crop, rect != page.getBoxRect(.mediaBox) else { return nil }
        return rect.applying(drawingTransform(page, fitting: CGRect(origin: .zero, size: displayedSize(page)))).standardized
    }
}

/// Writes a PDF with Quartz: one page at a time, each drawn by a closure into a context of the page's size.
public enum PDFWriter {
    public struct Page {
        public var size: CGSize
        public var info: [CFString: Any]
        public var draw: (CGContext) throws -> Void

        public init(size: CGSize, info: [CFString: Any] = [:], draw: @escaping (CGContext) throws -> Void) {
            self.size = size; self.info = info; self.draw = draw
        }
    }

    public static func write(to destination: URL, info: [CFString: Any], pages: [Page]) throws {
        var mediaBox = CGRect(origin: .zero, size: pages.first?.size ?? CGSize(width: 612, height: 792))
        guard let context = CGContext(destination as CFURL, mediaBox: &mediaBox, info as CFDictionary) else { throw RenderError.cannotCreateContext }
        var failure: Error?
        for page in pages {
            var pageInfo = page.info
            pageInfo[kCGPDFContextMediaBox] = boxData(CGRect(origin: .zero, size: page.size))
            context.beginPDFPage(pageInfo as CFDictionary)
            do { try page.draw(context) } catch { failure = error }
            context.endPDFPage()
            if failure != nil { break }
        }
        context.closePDF()
        if let failure { try? FileManager.default.removeItem(at: destination); throw failure }
    }

    /// A page box value for the page-info dictionary.
    public static func boxData(_ rect: CGRect) -> CFData {
        var rect = rect
        return Data(bytes: &rect, count: MemoryLayout<CGRect>.size) as CFData
    }
}
