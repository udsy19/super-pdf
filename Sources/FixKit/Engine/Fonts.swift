import CoreGraphics
import CoreText
import Foundation
import PDFModelKit

// Fonts (features #100, #91 "unembed standard fonts", #94 "fonts not embedded"): which fonts a file uses and which of
// them carry their program; embedding the ones this Mac has (TrueType outlines, the whole face: no subsetting), and
// dropping the embedded program of the standard 14 fonts, which every reader has.

/// A font dictionary and the pages that use it.
struct FontUse {
    var object: PDFObject
    var name: String
    var pages: Set<Int>
}

enum Fonts {
    static let standard14: Set<String> = [
        "Times-Roman", "Times-Bold", "Times-Italic", "Times-BoldItalic", "Helvetica", "Helvetica-Bold", "Helvetica-Oblique",
        "Helvetica-BoldOblique", "Courier", "Courier-Bold", "Courier-Oblique", "Courier-BoldOblique", "Symbol", "ZapfDingbats",
    ]

    /// /BaseFont without a subset tag ("ABCDEF+Garamond" → "Garamond").
    static func name(of font: PDFObject) -> String {
        let base = font["BaseFont"]?.name ?? font["Name"]?.name ?? "Unnamed"
        if base.count > 7, base.dropFirst(6).first == "+", base.prefix(6).allSatisfy({ $0.isUppercase && $0.isASCII }) {
            return String(base.dropFirst(7))
        }
        return base
    }

    /// The descriptor holding the font program (a Type0 font's is its descendant's).
    static func descriptor(of font: PDFObject) -> PDFObject? {
        if font["Subtype"]?.name == "Type0" { return font["DescendantFonts"]?[0]?["FontDescriptor"] }
        return font["FontDescriptor"]
    }

    static func isEmbedded(_ font: PDFObject) -> Bool {
        if font["Subtype"]?.name == "Type3" { return true }
        guard let descriptor = descriptor(of: font) else { return false }
        return ["FontFile", "FontFile2", "FontFile3"].contains { descriptor[$0]?.type == .stream }
    }

    /// Every font the pages use, through their form XObjects and annotation appearances, once each.
    static func all(in model: PDFModel) -> [FontUse] {
        var uses: [FontUse] = []
        var byID: [Int: Int] = [:]
        var visited: Set<Int> = []
        func add(_ font: PDFObject, page: Int) {
            if let id = font.objectID {
                if let at = byID[id] { uses[at].pages.insert(page); return }
                byID[id] = uses.count
            }
            uses.append(FontUse(object: font, name: name(of: font), pages: [page]))
        }
        func scan(_ resources: PDFObject?, page: Int, depth: Int) {
            guard let resources, depth < 10 else { return }
            if let fonts = resources["Font"] { for key in fonts.keys { if let f = fonts[key], f.type == .dictionary { add(f, page: page) } } }
            if let xobjects = resources["XObject"] {
                for key in xobjects.keys {
                    guard let x = xobjects[key], x["Subtype"]?.name == "Form" else { continue }
                    if let id = x.objectID { guard visited.insert(id).inserted else { continue } }
                    scan(x["Resources"], page: page, depth: depth + 1)
                }
            }
        }
        for (index, page) in model.pages.enumerated() {
            visited.removeAll()
            scan(page.resources, page: index, depth: 0)
            for annotation in page.annotations {
                guard let normal = annotation["AP"]?["N"] else { continue }
                let streams = normal.type == .stream ? [normal] : normal.keys.compactMap { normal[$0] }
                for stream in streams where stream.type == .stream { scan(stream["Resources"], page: index, depth: 1) }
            }
        }
        return uses
    }

    /// Fonts without their program, by name, sorted.
    static func notEmbedded(in model: PDFModel) -> [FontUse] {
        all(in: model).filter { !isEmbedded($0.object) }.sorted { $0.name < $1.name }
    }

    // MARK: Unembedding

    /// Drops the embedded programs of the standard 14 fonts (Make smaller's "Remove extra fonts") where the encoding is
    /// a standard one, so every reader's own copy draws the same glyphs. Returns how many were dropped.
    @discardableResult
    static func unembedStandardFonts(in model: PDFModel) -> Int {
        var count = 0
        for use in all(in: model) {
            let font = use.object
            guard ["Type1", "MMType1", "TrueType"].contains(font["Subtype"]?.name ?? ""), standard14.contains(use.name),
                  ["WinAnsiEncoding", "MacRomanEncoding", "StandardEncoding"].contains(font["Encoding"]?.name ?? ""),
                  let descriptor = font["FontDescriptor"], isEmbedded(font) else { continue }
            for key in ["FontFile", "FontFile2", "FontFile3"] { descriptor.remove(key) }
            font.set("BaseFont", .name(use.name))
            descriptor.set("FontName", .name(use.name))
            count += 1
        }
        return count
    }

    // MARK: Embedding

    /// Embeds the simple fonts this Mac has with TrueType outlines. Returns the names embedded and those still missing.
    static func embedMissing(in model: PDFModel) -> (embedded: [String], missing: [String]) {
        var embedded: [String] = [], missing: [String] = []
        for use in notEmbedded(in: model) {
            if embed(use, in: model) { embedded.append(use.name) } else { missing.append(use.name) }
        }
        return (embedded, missing)
    }

    /// The fonts `embedMissing` could embed.
    static func embeddable(_ uses: [FontUse]) -> [FontUse] { uses.filter { systemFont(for: $0) != nil } }

    static func embed(_ use: FontUse, in model: PDFModel) -> Bool {
        let font = use.object
        guard let (ctFont, program) = systemFont(for: use) else { return false }
        let em = Double(CTFontGetUnitsPerEm(ctFont))
        let scale = 1000 / max(em, 1)
        // A simple font with a TrueType program is a TrueType font (ISO 32000-2 §9.6.3).
        if font["Subtype"]?.name != "TrueType" { font.set("Subtype", .name("TrueType")) }
        if font["Encoding"] == nil { font.set("Encoding", .name("WinAnsiEncoding")) }
        if font["Widths"] == nil {
            guard let widths = widths(ctFont, encoding: font["Encoding"]?.name ?? "WinAnsiEncoding") else { return false }
            font.set("FirstChar", .integer(32))
            font.set("LastChar", .integer(255))
            font.set("Widths", .array(widths.map { .number(($0 * scale).rounded()) }))
        }
        let descriptor: PDFObject
        if let existing = font["FontDescriptor"], existing.type == .dictionary {
            descriptor = existing
        } else {
            let box = CTFontGetBoundingBox(ctFont)
            let fontSize = Double(CTFontGetSize(ctFont))
            let unit = 1000 / max(fontSize, 1)
            descriptor = model.makeIndirect(.dictionary([
                "Type": .name("FontDescriptor"),
                "Flags": .integer(32),
                "FontBBox": .array([box.minX, box.minY, box.maxX, box.maxY].map { .number((Double($0) * unit).rounded()) }),
                "ItalicAngle": .number(Double(CTFontGetSlantAngle(ctFont)).rounded()),
                "Ascent": .number((Double(CTFontGetAscent(ctFont)) * unit).rounded()),
                "Descent": .number((-Double(CTFontGetDescent(ctFont)) * unit).rounded()),
                "CapHeight": .number((Double(CTFontGetCapHeight(ctFont)) * unit).rounded()),
                "StemV": .integer(80),
            ]))
            font.set("FontDescriptor", descriptor)
        }
        descriptor.set("FontName", .name(use.name))
        font.set("BaseFont", .name(use.name))
        descriptor.set("FontFile2", model.makeStream(["Length1": .integer(program.count)], data: program))
        return true
    }

    /// The installed face named like the font and its TrueType program: a simple, non-symbolic font, up to 12 MB.
    static func systemFont(for use: FontUse) -> (CTFont, Data)? {
        let font = use.object
        guard ["Type1", "MMType1", "TrueType"].contains(font["Subtype"]?.name ?? ""), !["Symbol", "ZapfDingbats"].contains(use.name) else { return nil }
        if let flags = font["FontDescriptor"]?["Flags"]?.int, flags & 4 != 0 { return nil }
        if let encoding = font["Encoding"], encoding.type != .name || encoding.name == "MacExpertEncoding" { return nil }
        let candidates = [use.name, use.name.replacingOccurrences(of: ",", with: "-"), use.name.replacingOccurrences(of: ",", with: "")]
        for candidate in candidates {
            let ctFont = CTFontCreateWithName(candidate as CFString, 12, nil)
            guard (CTFontCopyPostScriptName(ctFont) as String).caseInsensitiveCompare(candidate) == .orderedSame,
                  let url = CTFontCopyAttribute(ctFont, kCTFontURLAttribute) as? URL,
                  let size = try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize, size < 40 << 20,
                  let file = try? Data(contentsOf: url, options: .mappedIfSafe) else { continue }
            let faces = SFNT.isCollection(file) ? SFNT.faces(ofCollection: file) : [file]
            for face in faces where face.count < 12 << 20 {
                guard let tables = SFNT.tables(of: face), tables.contains(where: { $0.tag == "glyf" }),
                      let provider = CGDataProvider(data: face as CFData), let cgFont = CGFont(provider),
                      (cgFont.postScriptName as String?)?.caseInsensitiveCompare(candidate) == .orderedSame else { continue }
                return (ctFont, face)
            }
        }
        return nil
    }

    /// Advances (font units) of codes 32…255 in `encoding`; nil for encodings not mapped here.
    static func widths(_ font: CTFont, encoding: String) -> [Double]? {
        let stringEncoding: String.Encoding
        switch encoding {
        case "WinAnsiEncoding", "StandardEncoding": stringEncoding = .windowsCP1252
        case "MacRomanEncoding": stringEncoding = .macOSRoman
        default: return nil
        }
        let em = Double(CTFontGetUnitsPerEm(font)), size = Double(CTFontGetSize(font))
        return (32...255).map { code in
            guard let text = String(bytes: [UInt8(code)], encoding: stringEncoding), let unit = text.utf16.first else { return 0 }
            var character = unit
            var glyph: CGGlyph = 0
            guard CTFontGetGlyphsForCharacters(font, &character, &glyph, 1), glyph != 0 else { return 0 }
            var advance = CGSize.zero
            CTFontGetAdvancesForGlyphs(font, .horizontal, &glyph, &advance, 1)
            return Double(advance.width) * em / max(size, 1)
        }
    }
}
