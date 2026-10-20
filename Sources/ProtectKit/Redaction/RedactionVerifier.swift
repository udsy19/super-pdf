import CoreGraphics
import Foundation
import PDFKit
import RenderKit
import SuperPDFCore

// Black out checks its own work before anything is saved (features #69 "verified by rasterize-compare"): the new file
// is rendered and every box must come out solid in its colour (nothing drawn over or through it), and PDFKit must find
// no character whose centre lies inside a box other than the words written over it.

enum RedactionVerifier {
    /// Every mark renders in the fill colour (off the main actor). With words over the boxes, most of each box must.
    static func rendersSolid(_ data: Data, password: String?, marks: [RedactionMark], fill: RGB, withWords: Bool) -> Bool {
        guard let document = try? PDFPages.open(.data(data, password: password)) else { return false }
        let target = [fill.r, fill.g, fill.b].map { Int(($0 * 255).rounded()) }
        for (index, pageMarks) in Dictionary(grouping: marks, by: \.page) {
            guard let page = try? PDFPages.page(document, at: index), let image = try? Rasterizer.render(page, dpi: 144) else { return false }
            let width = image.width, height = image.height
            var pixels = [UInt8](repeating: 0, count: width * height * 4)
            guard let context = CGContext(data: &pixels, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width * 4,
                                          space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return false }
            context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
            let toPixels = PDFPages.drawingTransform(page, fitting: CGRect(x: 0, y: 0, width: width, height: height))
            for mark in pageMarks {
                let inner = mark.rect.standardized.insetBy(dx: 1, dy: 1)
                guard inner.width > 1, inner.height > 1 else { continue }
                let box = inner.applying(toPixels).standardized
                let x0 = max(Int(box.minX.rounded(.up)), 0), x1 = min(Int(box.maxX.rounded(.down)), width)
                let y0 = max(Int(box.minY.rounded(.up)), 0), y1 = min(Int(box.maxY.rounded(.down)), height)
                guard x0 < x1, y0 < y1 else { continue }
                var solid = 0, total = 0
                for y in y0..<y1 {
                    // Bitmap rows run from the top; page space runs up.
                    let row = (height - 1 - y) * width * 4
                    for x in x0..<x1 {
                        let p = row + x * 4
                        total += 1
                        if abs(Int(pixels[p]) - target[0]) <= 40, abs(Int(pixels[p + 1]) - target[1]) <= 40, abs(Int(pixels[p + 2]) - target[2]) <= 40 {
                            solid += 1
                        }
                    }
                }
                let needed = withWords ? 0.5 : 0.99
                if Double(solid) < Double(total) * needed { return false }
            }
        }
        return true
    }

    /// No character of the new file sits inside a mark, except the words written over the boxes (main actor: PDFKit).
    @MainActor
    static func hasNoText(_ data: Data, password: String?, marks: [RedactionMark], overlay: String?) -> Bool {
        guard let document = PDFDocument(data: data) else { return false }
        if document.isLocked, !(password.map(document.unlock) ?? false) { return false }
        let allowed = (overlay ?? "").filter { !$0.isWhitespace }
        for (index, pageMarks) in Dictionary(grouping: marks, by: \.page) {
            guard let page = document.page(at: index) else { return false }
            let text = (page.string ?? "") as NSString
            var inside = Array(repeating: "", count: pageMarks.count)
            // One selection per character: `characterBounds(at:)` counts without the line breaks `string` has.
            for i in 0..<text.length {
                let character = text.substring(with: NSRange(location: i, length: 1))
                guard !character.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                      let bounds = page.selection(for: NSRange(location: i, length: 1))?.bounds(for: page),
                      bounds.width > 0 || bounds.height > 0 else { continue }
                let centre = CGPoint(x: bounds.midX, y: bounds.midY)
                for (k, mark) in pageMarks.enumerated() where mark.rect.standardized.contains(centre) { inside[k] += character }
            }
            if inside.contains(where: { !$0.isEmpty && $0 != allowed }) { return false }
        }
        return true
    }
}
