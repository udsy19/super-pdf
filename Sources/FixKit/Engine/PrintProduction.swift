import CoreGraphics
import Foundation
import PDFModelKit

// Print production basics (features #94, #120): finding and thickening lines too thin to print (a `0 w` line is the
// thinnest the device can draw), and printer marks: crop marks at the trim corners, registration targets on each side
// and a line of page information in the slug, with the media box grown to hold them and the trim and bleed boxes set.

enum PrintProduction {
    /// Lines thinner than this many points are hairlines.
    static let minimumLineWidth = 0.25
    static let strokes: Set<String> = ["S", "s", "B", "B*", "b", "b*"]

    /// Pages (0-based) that stroke a line thinner than `minimumLineWidth`.
    static func pagesWithHairlines(in model: PDFModel) -> [Int] {
        model.pages.enumerated().compactMap { index, page in
            var found = false
            ContentWalker.walk(page) { op, state, _ in
                if !found, strokes.contains(op.operator), state.drawnLineWidth < minimumLineWidth { found = true }
            }
            return found ? index : nil
        }
    }

    /// Raises every hairline to `minimumLineWidth` (page content and the form XObjects pages draw); returns how many
    /// strokes changed.
    @discardableResult
    static func thickenHairlines(in model: PDFModel) -> Int {
        var changed = 0
        var forms: [Int: PDFObject] = [:]
        for page in model.pages {
            if let operations = ContentWalker.operations(of: page) {
                let (thickened, count) = thicken(operations, ctm: .identity)
                if count > 0 { page.setContentStream(PDFContentStream(operations: thickened)); changed += count }
            }
            ContentWalker.walk(page) { _, _, scope in
                if let form = scope.form, let id = form.objectID { forms[id] = form }
            }
        }
        for form in forms.values {
            guard let operations = ContentWalker.operations(ofForm: form) else { continue }
            let (thickened, count) = thicken(operations, ctm: ContentWalker.matrix(ofForm: form))
            if count > 0 { form.setStreamData(PDFContentStream(operations: thickened).serialized()); changed += count }
        }
        return changed
    }

    /// The operations with a `w` before each stroke drawn thinner than the minimum.
    private static func thicken(_ operations: [PDFContentOperation], ctm: CGAffineTransform) -> ([PDFContentOperation], Int) {
        var insertions: [(Int, Double)] = []
        ContentWalker.walk(operations, ctm: ctm) { index, op, state in
            guard strokes.contains(op.operator), state.drawnLineWidth < minimumLineWidth else { return }
            let scale = Double(min(hypot(state.ctm.a, state.ctm.b), hypot(state.ctm.c, state.ctm.d)))
            guard scale > 0 else { return }
            insertions.append((index, minimumLineWidth / scale))
        }
        guard !insertions.isEmpty else { return (operations, 0) }
        var result = operations
        // A stroke ends a path, so its `w` goes before the path's first construction operator.
        let construction: Set<String> = ["m", "l", "c", "v", "y", "h", "re", "W", "W*"]
        for (index, width) in insertions.reversed() {
            var start = index
            while start > 0, construction.contains(result[start - 1].operator) { start -= 1 }
            result.insert(PDFContentOperation("w", [.number(width)]), at: start)
        }
        return (result, insertions.count)
    }

    // MARK: Printer marks

    /// Adds crop marks, registration targets and a page-information line to every page.
    static func addPrinterMarks(to model: PDFModel, title: String, date: Date = Date()) {
        let font = model.makeIndirect(.dictionary([
            "Type": .name("Font"), "Subtype": .name("Type1"), "BaseFont": .name("Helvetica"), "Encoding": .name("WinAnsiEncoding"),
        ]))
        // A print file wants every font embedded, the slug's too (when this Mac has it).
        _ = Fonts.embed(FontUse(object: font, name: "Helvetica", pages: []), in: model)
        let stamp = DateFormatter.localizedString(from: date, dateStyle: .medium, timeStyle: .short)
        for (index, page) in model.pages.enumerated() {
            let trim = page.object.inherited("TrimBox")?.rect ?? page.box(.crop)
            let bleed = page.object.inherited("BleedBox")?.rect ?? trim
            let slug = 36.0, gap = 3.0, length = 18.0
            let outer = bleed.insetBy(dx: -slug, dy: -slug)
            page.setBox(.media, outer)
            page.setBox(.crop, outer)
            page.setBox(.trim, trim)
            page.setBox(.bleed, bleed)
            let name = page.addResource(font, category: "Font", prefix: "Marks")
            var out = "q\n0.25 w 1 1 1 1 K 1 1 1 1 k\n"
            // Crop marks: two short lines per trim corner, starting outside the bleed.
            let dx = Double(trim.minX - bleed.minX) + gap, dy = Double(trim.minY - bleed.minY) + gap
            let dX = Double(bleed.maxX - trim.maxX) + gap, dY = Double(bleed.maxY - trim.maxY) + gap
            let corners: [(Double, Double, Double, Double)] = [
                (Double(trim.minX), Double(trim.minY), -1, -1), (Double(trim.maxX), Double(trim.minY), 1, -1),
                (Double(trim.minX), Double(trim.maxY), -1, 1), (Double(trim.maxX), Double(trim.maxY), 1, 1),
            ]
            for (x, y, sx, sy) in corners {
                let offX = sx < 0 ? dx : dX, offY = sy < 0 ? dy : dY
                out += "\(f(x + sx * offX)) \(f(y)) m \(f(x + sx * (offX + length))) \(f(y)) l S\n"
                out += "\(f(x)) \(f(y + sy * offY)) m \(f(x)) \(f(y + sy * (offY + length))) l S\n"
            }
            // Registration targets in the middle of each side.
            let mid = [(Double(bleed.midX), Double(bleed.minY) - slug / 2), (Double(bleed.midX), Double(bleed.maxY) + slug / 2),
                       (Double(bleed.minX) - slug / 2, Double(bleed.midY)), (Double(bleed.maxX) + slug / 2, Double(bleed.midY))]
            for (x, y) in mid {
                out += circle(x: x, y: y, r: 5) + " S\n"
                out += "\(f(x - 8)) \(f(y)) m \(f(x + 8)) \(f(y)) l \(f(x)) \(f(y - 8)) m \(f(x)) \(f(y + 8)) l S\n"
            }
            let info = "\(title)   Page \(index + 1)   \(stamp)"
            let encoded = (info.data(using: .windowsCP1252, allowLossyConversion: true) ?? Data()).map { String(format: "%02X", $0) }.joined()
            out += "BT /\(name) 6 Tf \(f(Double(bleed.minX))) \(f(Double(bleed.minY) - slug + 10)) Td <\(encoded)> Tj ET\nQ\n"
            page.addContent(Data("q\n".utf8), prepend: true)
            page.addContent(Data(("Q\n" + out).utf8))
        }
    }

    private static func f(_ value: Double) -> String { TextLayer.format(value) }

    /// A circle as four Bézier curves.
    private static func circle(x: Double, y: Double, r: Double) -> String {
        let k = 0.5523 * r
        return "\(f(x + r)) \(f(y)) m "
            + "\(f(x + r)) \(f(y + k)) \(f(x + k)) \(f(y + r)) \(f(x)) \(f(y + r)) c "
            + "\(f(x - k)) \(f(y + r)) \(f(x - r)) \(f(y + k)) \(f(x - r)) \(f(y)) c "
            + "\(f(x - r)) \(f(y - k)) \(f(x - k)) \(f(y - r)) \(f(x)) \(f(y - r)) c "
            + "\(f(x + k)) \(f(y - r)) \(f(x + r)) \(f(y - k)) \(f(x + r)) \(f(y)) c"
    }
}
