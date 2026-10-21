import AppKit
import CoreGraphics
import CoreText
import Foundation
import PDFKit
import SuperPDFCore

// The live preview of a decoration (ux §5.1: "a watermark appears on the page while you type it"): the same items
// the writer puts in the file, drawn with Core Graphics over a page of the PDFView in page space.

enum DecorationPreview {
    /// Draws `decoration` over `page` (page space, origin at the crop box's lower left as ToolsKit's overlay gives it).
    @MainActor
    static func draw(_ decoration: Decoration, pageIndex index: Int, page: PDFPage, context: DecorationContext, in cg: CGContext) {
        let crop = page.bounds(for: .cropBox)
        let rotation = ((page.rotation % 360) + 360) % 360
        let shown = rotation % 180 == 0 ? crop.size : CGSize(width: crop.height, height: crop.width)
        // The overlay draws in page space with the crop box's origin at 0; items are laid out in the shown page.
        let display = PDFModelKitCompat.displayTransform(box: CGRect(origin: .zero, size: crop.size), rotation: rotation)
        cg.saveGState()
        cg.concatenate(display.inverted())
        for item in DecorationLayout.items(for: decoration, pageIndex: index, pageSize: shown, context: context) {
            draw(item, in: cg)
        }
        cg.restoreGState()
    }

    static func draw(_ item: DecorationItem, in cg: CGContext) {
        cg.saveGState()
        cg.setAlpha(CGFloat(item.opacity))
        cg.concatenate(DecorationLayout.placement(of: item))
        switch item.content {
        case .text(let text, let fontName, let fontSize, let color):
            let font = DecorationLayout.nsFont(fontName, size: fontSize)
            let line = CTLineCreateWithAttributedString(NSAttributedString(string: text, attributes: [.font: font, .foregroundColor: NSColor(hex: color)]))
            cg.textMatrix = .identity
            cg.textPosition = CGPoint(x: item.frame.minX, y: item.frame.minY - Double(font.descender))
            CTLineDraw(line, cg)
        case .fill(let hex):
            cg.setFillColor(NSColor(hex: hex).cgColor)
            cg.fill(item.frame)
        case .picture(let picture):
            switch picture {
            case .image(let image, _):
                cg.draw(image, in: item.frame)
            case .pdfPage(let model, let size, _):
                // The first page, drawn through PDFKit from the model's bytes (Quartz needs a document).
                if let data = try? model.data(), let document = PDFDocument(data: data), let first = document.page(at: 0) {
                    cg.saveGState()
                    cg.translateBy(x: item.frame.minX, y: item.frame.minY)
                    cg.scaleBy(x: item.frame.width / max(size.width, 1), y: item.frame.height / max(size.height, 1))
                    first.draw(with: .cropBox, to: cg)
                    cg.restoreGState()
                }
            }
        }
        cg.restoreGState()
    }
}

/// The page-space ↔ shown-page mapping PDFModelKit uses, repeated for PDFKit pages (whose boxes we read directly).
enum PDFModelKitCompat {
    static func displayTransform(box b: CGRect, rotation: Int) -> CGAffineTransform {
        switch rotation {
        case 90: CGAffineTransform(a: 0, b: -1, c: 1, d: 0, tx: -b.minY, ty: b.maxX)
        case 180: CGAffineTransform(a: -1, b: 0, c: 0, d: -1, tx: b.maxX, ty: b.maxY)
        case 270: CGAffineTransform(a: 0, b: 1, c: -1, d: 0, tx: b.maxY, ty: -b.minX)
        default: CGAffineTransform(translationX: -b.minX, y: -b.minY)
        }
    }
}
