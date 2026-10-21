import CoreText
import Foundation
import PDFModelKit

// "Make text editable (replaces the picture with real text)" (ux §5.3 Recognise text, features #92): on a clean scan
// the page's picture is taken out and the recognised words are written as real text in Helvetica, at their places and
// widths, so they can be edited and reflowed like any text. Pages whose words aren't all Windows Latin 1, or whose
// scan isn't one picture covering the page, keep the picture with the invisible layer instead.

enum EditableText {
    /// Helvetica's advances for 32…255 in Windows Latin 1, thousandths of the size.
    static let helveticaWidths: [Double]? = {
        let font = CTFontCreateWithName("Helvetica" as CFString, 1000, nil)
        guard let units = Fonts.widths(font, encoding: "WinAnsiEncoding") else { return nil }
        let em = Double(CTFontGetUnitsPerEm(font))
        return units.map { $0 * 1000 / max(em, 1) }
    }()

    /// Replaces the scan on `page` with `words` as real text; false (nothing changed) when it can't.
    static func replaceScan(on page: PDFPage, with words: [PlacedWord]) -> Bool {
        guard let widths = helveticaWidths, words.allSatisfy({ $0.text.canBeConverted(to: .windowsCP1252) }),
              var operations = ContentWalker.operations(of: page) else { return false }
        let crop = page.box(.crop)
        let resources = page.resources
        var scans: [Int] = []
        ContentWalker.walk(operations, ctm: .identity) { index, op, state in
            guard op.operator == "Do", let name = op.operands.first?.nameValue,
                  resources?["XObject"]?[name]?["Subtype"]?.name == "Image" else { return }
            let drawn = ContentWalker.unitSquare(state.ctm).intersection(crop)
            if !drawn.isNull, drawn.width * drawn.height >= 0.8 * crop.width * crop.height { scans.append(index) }
        }
        guard !scans.isEmpty else { return false }
        for index in scans.reversed() { operations.remove(at: index) }
        page.setContentStream(PDFContentStream(operations: operations))
        let font = page.model.makeIndirect(.dictionary([
            "Type": .name("Font"), "Subtype": .name("Type1"), "BaseFont": .name("Helvetica"), "Encoding": .name("WinAnsiEncoding"),
        ]))
        TextLayer.add(words, to: page, font: font, style: .visible(widths: widths))
        return true
    }
}
