import CoreGraphics
import Foundation
import PDFModelKit

// The invisible text layer of Recognise text (features #92, §3.3): each recognised word written in text render mode 3
// (neither filled nor stroked) at its place, stretched to the word's box, so search, selection and copy land on the
// words of the scan in every reader. The font is a Type0 font with Identity-H codes = UTF-16 code units, a ToUnicode
// map back to the same units (any script Vision reads survives), and a glyphless TrueType program embedded so no
// reader looks for a font it doesn't have.

/// A recognised word in display space (points, origin at the lower-left of the page as shown).
struct PlacedWord {
    var text: String
    /// The box the word fills, before `angle`.
    var bounds: CGRect
    /// Radians, counter-clockwise, about the box's lower-left corner (a skewed scan's baseline).
    var angle: Double = 0
}

enum TextLayer {
    /// Advance of every glyph, in thousandths of the font size.
    static let advance = 500.0
    /// Font descent (thousandths): the baseline sits this far above the box's bottom.
    static let descent = 200.0

    /// How the words are written: invisible over the scan (codes are UTF-16 units of the glyphless font), or as real
    /// black text in a simple font (codes are Windows Latin 1 bytes; `widths` are its advances for 32…255 in
    /// thousandths).
    enum Style {
        case invisible
        case visible(widths: [Double])
    }

    /// Appends the words to `page`, isolating the page's existing content in q … Q first.
    static func add(_ words: [PlacedWord], to page: PDFPage, font: PDFObject, style: Style = .invisible) {
        guard !words.isEmpty else { return }
        let name = page.addResource(font, category: "Font", prefix: "OCR")
        // Display space → the page's user space.
        let toPage = page.displayTransform.inverted()
        let mode = if case .invisible = style { "3 Tr" } else { "0 Tr 0 g" }
        var out = "q\n\(matrix(toPage)) cm\nBT\n\(mode)\n/\(name) 1 Tf\n"
        for (index, word) in words.enumerated() {
            // A trailing space between words on a line, so extraction keeps them apart.
            let next = index + 1 < words.count ? words[index + 1] : nil
            let spaced = next.map { abs($0.bounds.midY - word.bounds.midY) < word.bounds.height / 2 } ?? false
            let codes: [Int], width: Double, hex: String
            switch style {
            case .invisible:
                codes = Array(word.text.utf16).map(Int.init)
                width = Double(codes.count) * advance / 1000
                hex = (codes + (spaced ? [0x20] : [])).map { String(format: "%04X", $0) }.joined()
            case .visible(let widths):
                codes = (word.text.data(using: .windowsCP1252) ?? Data()).map(Int.init)
                width = codes.reduce(0) { $0 + ($1 >= 32 ? widths[$1 - 32] : 0) } / 1000
                hex = (codes + (spaced ? [0x20] : [])).map { String(format: "%02X", $0) }.joined()
            }
            guard !codes.isEmpty, width > 0, word.bounds.width > 0, word.bounds.height > 0 else { continue }
            let height = Double(word.bounds.height)
            let stretch = Double(word.bounds.width) / width
            let cosA = cos(word.angle), sinA = sin(word.angle)
            // Baseline origin: the box's lower-left corner raised by the descent, along the rotated vertical.
            let rise = height * descent / 1000
            let x = Double(word.bounds.minX) - rise * sinA, y = Double(word.bounds.minY) + rise * cosA
            let tm = [stretch * cosA, stretch * sinA, -height * sinA, height * cosA, x, y]
            out += tm.map(format).joined(separator: " ") + " Tm <\(hex)> Tj\n"
        }
        out += "ET\nQ\n"
        page.addContent(Data("q\n".utf8), prepend: true)
        page.addContent(Data(("Q\n" + out).utf8))
    }

    /// The layer's font, made once per document.
    static func makeFont(in model: PDFModel) -> PDFObject {
        let program = model.makeStream(["Length1": .integer(GlyphlessFont.data.count)], data: GlyphlessFont.data)
        let descriptor = model.makeIndirect(.dictionary([
            "Type": .name("FontDescriptor"), "FontName": .name(GlyphlessFont.name), "Flags": .integer(5),
            "FontBBox": .array([.integer(0), .integer(-Int(descent)), .integer(Int(advance)), .integer(1000 - Int(descent))]),
            "ItalicAngle": .integer(0), "Ascent": .integer(1000 - Int(descent)), "Descent": .integer(-Int(descent)),
            "CapHeight": .integer(1000 - Int(descent)), "StemV": .integer(80),
        ]))
        descriptor.set("FontFile2", program)
        let descendant = model.makeIndirect(.dictionary([
            "Type": .name("Font"), "Subtype": .name("CIDFontType2"), "BaseFont": .name(GlyphlessFont.name),
            "CIDSystemInfo": .dictionary(["Registry": .ascii("Adobe"), "Ordering": .ascii("Identity"), "Supplement": .integer(0)]),
            "DW": .integer(Int(advance)), "CIDToGIDMap": .name("Identity"),
        ]))
        descendant.set("FontDescriptor", descriptor)
        let font = model.makeIndirect(.dictionary([
            "Type": .name("Font"), "Subtype": .name("Type0"), "BaseFont": .name(GlyphlessFont.name), "Encoding": .name("Identity-H"),
        ]))
        let array = model.make(.array([]))
        array.append(descendant)
        font.set("DescendantFonts", array)
        font.set("ToUnicode", model.makeStream(data: Data(toUnicode.utf8)))
        return font
    }

    /// Every two-byte code maps to the same UTF-16 unit (surrogate halves pair up again when extracted).
    static let toUnicode: String = {
        var ranges: [String] = []
        for high in 0...0xFF { ranges.append(String(format: "<%02X00> <%02XFF> <%02X00>", high, high, high)) }
        var blocks = ""
        var start = 0
        while start < ranges.count {
            let chunk = ranges[start..<min(start + 100, ranges.count)]
            blocks += "\(chunk.count) beginbfrange\n" + chunk.joined(separator: "\n") + "\nendbfrange\n"
            start += 100
        }
        return """
        /CIDInit /ProcSet findresource begin
        12 dict begin
        begincmap
        /CIDSystemInfo << /Registry (Adobe) /Ordering (UCS) /Supplement 0 >> def
        /CMapName /Adobe-Identity-UCS def
        /CMapType 2 def
        1 begincodespacerange
        <0000> <FFFF>
        endcodespacerange
        \(blocks)endcmap
        CMapName currentdict /CMap defineresource pop
        end
        end
        """
    }()

    static func matrix(_ t: CGAffineTransform) -> String {
        [t.a, t.b, t.c, t.d, t.tx, t.ty].map { format(Double($0)) }.joined(separator: " ")
    }

    /// A number with at most four decimals, no exponent.
    static func format(_ value: Double) -> String {
        let rounded = (value * 10_000).rounded() / 10_000
        if rounded == rounded.rounded(), abs(rounded) < 1e12 { return String(Int(rounded)) }
        var text = String(format: "%.4f", rounded)
        while text.hasSuffix("0") { text.removeLast() }
        return text
    }
}

/// A TrueType font with no outlines (an empty .notdef and one empty glyph, 500 units wide): the program of the text
/// layer's font, so readers that want every font embedded have one. Built here once.
enum GlyphlessFont {
    static let name = "GlyphLessFont"

    static let data: Data = {
        func table(_ build: (inout Data) -> Void) -> Data { var d = Data(); build(&d); return d }
        let head = table { d in
            d.append(u32: 0x0001_0000); d.append(u32: 0x0001_0000); d.append(u32: 0); d.append(u32: 0x5F0F_3CF5)
            d.append(u16: 0x000B); d.append(u16: 1000)
            d.append(Data(count: 16))                                            // created, modified
            d.append(i16: 0); d.append(i16: -200); d.append(i16: 500); d.append(i16: 800)
            d.append(u16: 0); d.append(u16: 8); d.append(i16: 2); d.append(i16: 0); d.append(i16: 0)
        }
        let hhea = table { d in
            d.append(u32: 0x0001_0000); d.append(i16: 800); d.append(i16: -200); d.append(i16: 0); d.append(u16: 500)
            d.append(i16: 0); d.append(i16: 0); d.append(i16: 500); d.append(i16: 1); d.append(i16: 0); d.append(i16: 0)
            d.append(Data(count: 8)); d.append(i16: 0); d.append(u16: 2)
        }
        let maxp = table { d in
            d.append(u32: 0x0001_0000); d.append(u16: 2)
            for value: UInt16 in [0, 0, 0, 0, 2, 0, 0, 0, 0, 0, 0, 0, 0] { d.append(u16: value) }
        }
        let hmtx = table { d in for _ in 0..<2 { d.append(u16: 500); d.append(i16: 0) } }
        let loca = table { d in for _ in 0..<3 { d.append(u16: 0) } }
        let cmap = table { d in
            d.append(u16: 0); d.append(u16: 1); d.append(u16: 3); d.append(u16: 1); d.append(u32: 12)
            // Format 4: U+0020 → glyph 1.
            d.append(u16: 4); d.append(u16: 32); d.append(u16: 0); d.append(u16: 4); d.append(u16: 4); d.append(u16: 1); d.append(u16: 0)
            d.append(u16: 0x0020); d.append(u16: 0xFFFF); d.append(u16: 0)
            d.append(u16: 0x0020); d.append(u16: 0xFFFF)
            d.append(u16: UInt16(bitPattern: Int16(1 - 0x20))); d.append(u16: 1)
            d.append(u16: 0); d.append(u16: 0)
        }
        let nameTable = table { d in
            let text = Data(name.utf16.flatMap { [UInt8($0 >> 8), UInt8($0 & 0xFF)] })
            let ids: [UInt16] = [1, 2, 4, 6]
            d.append(u16: 0); d.append(u16: UInt16(ids.count)); d.append(u16: UInt16(6 + 12 * ids.count))
            var strings = Data()
            for id in ids {
                let value = id == 2 ? Data("Regular".utf16.flatMap { [UInt8($0 >> 8), UInt8($0 & 0xFF)] }) : text
                d.append(u16: 3); d.append(u16: 1); d.append(u16: 0x0409); d.append(u16: id)
                d.append(u16: UInt16(value.count)); d.append(u16: UInt16(strings.count))
                strings.append(value)
            }
            d.append(strings)
        }
        let post = table { d in
            d.append(u32: 0x0003_0000); d.append(u32: 0); d.append(i16: -100); d.append(i16: 50); d.append(u32: 1)
            d.append(Data(count: 16))
        }
        let os2 = table { d in
            d.append(u16: 1); d.append(i16: 500); d.append(u16: 400); d.append(u16: 5); d.append(u16: 0)
            for value: Int16 in [500, 500, 0, 0, 500, 500, 0, 0, 50, 250, 0] { d.append(i16: value) }
            d.append(Data(count: 10))                                            // PANOSE
            d.append(Data(count: 16))                                            // Unicode ranges
            d.append(contentsOf: Array("NONE".utf8))
            d.append(u16: 0x0040); d.append(u16: 0x0020); d.append(u16: 0x0020)
            d.append(i16: 800); d.append(i16: -200); d.append(i16: 0); d.append(u16: 800); d.append(u16: 200)
            d.append(u32: 1); d.append(u32: 0)
        }
        return SFNT.assemble([("head", head), ("hhea", hhea), ("maxp", maxp), ("hmtx", hmtx), ("loca", loca), ("glyf", Data()),
                              ("cmap", cmap), ("name", nameTable), ("post", post), ("OS/2", os2)])
    }()
}
