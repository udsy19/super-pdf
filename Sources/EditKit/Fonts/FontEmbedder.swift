import AppKit
import CoreText
import Foundation
import PDFModelKit

// New font resources for text we write (edited blocks, new text boxes, headers, watermarks, stamps): the standard 14
// by name with WinAnsiEncoding, and any font on this Mac embedded as a subset (TrueType outlines subset by glyph,
// CFF outlines wrapped whole) as a Type0/Identity-H font with a ToUnicode map, so the text extracts and searches
// everywhere (features #60, #64–#68).

/// A font we can write with: encodes text and measures it.
final class WritableFont {
    enum Kind {
        /// One of the standard 14, written by name; widths measured with the matching system font.
        case standard(String)
        /// A font on this Mac, embedded as a subset.
        case embedded(NSFont)
    }

    let kind: Kind
    /// The resource dictionary (indirect) in its model.
    let object: PDFObject
    private let program: TrueTypeFont?
    private let ctFont: CTFont
    private var measured: [Unicode.Scalar: Double] = [:]
    /// Glyphs the subset holds; grows as text is encoded and is written at `finish()`.
    private(set) var glyphs: Set<Int> = [0]
    private var mappings: [UInt32: String] = [:]
    private var widths: [Int: Double] = [:]
    private var changed = false

    /// The name people see ("Georgia").
    var displayName: String {
        switch kind {
        case .standard(let name): FontMatcher.familyName(of: name)
        case .embedded(let font): font.familyName ?? font.fontName
        }
    }

    fileprivate init(kind: Kind, object: PDFObject, program: TrueTypeFont?, ctFont: CTFont) {
        self.kind = kind; self.object = object; self.program = program; self.ctFont = ctFont
    }

    /// Ascent and descent in 1/1000 text space.
    var ascent: Double { Double(CTFontGetAscent(ctFont)) }
    var descent: Double { -Double(CTFontGetDescent(ctFont)) }

    /// The bytes that show `text`, nil when the font lacks a character.
    func encode(_ text: String) -> Data? {
        switch kind {
        case .standard:
            var out = Data()
            for scalar in text.unicodeScalars {
                guard let code = PDFEncoding.code(for: scalar, in: "WinAnsiEncoding") ?? plainCode(scalar) else { return nil }
                out.append(UInt8(code))
            }
            return out
        case .embedded:
            var out = Data()
            for scalar in text.unicodeScalars {
                guard let glyph = glyph(for: scalar) else { return nil }
                glyphs.insert(glyph)
                if mappings[UInt32(glyph)] == nil { mappings[UInt32(glyph)] = String(scalar); changed = true }
                if widths[glyph] == nil { widths[glyph] = width(ofGlyph: glyph); changed = true }
                out.append(UInt8(glyph >> 8)); out.append(UInt8(glyph & 0xFF))
            }
            return out
        }
    }

    private func plainCode(_ scalar: Unicode.Scalar) -> Int? {
        let plain: [Unicode.Scalar: Unicode.Scalar] = ["\u{00A0}": " ", "\u{2011}": "-", "\u{2212}": "-"]
        return plain[scalar].flatMap { PDFEncoding.code(for: $0, in: "WinAnsiEncoding") }
    }

    func canShow(_ text: String) -> Bool { encode(text) != nil }

    /// Glyph units of `text` (widths in 1/1000 text space), nil when a character is missing.
    func units(of text: String) -> [GlyphUnit]? {
        var out: [GlyphUnit] = []
        for scalar in text.unicodeScalars {
            switch kind {
            case .standard:
                guard let code = PDFEncoding.code(for: scalar, in: "WinAnsiEncoding") ?? plainCode(scalar) else { return nil }
                out.append(GlyphUnit(code: UInt32(code), bytes: Data([UInt8(code)]), text: String(scalar), width: width(of: scalar), isWordSpace: code == 32))
            case .embedded:
                guard let glyph = glyph(for: scalar) else { return nil }
                glyphs.insert(glyph)
                if mappings[UInt32(glyph)] == nil { mappings[UInt32(glyph)] = String(scalar); changed = true }
                let w = width(ofGlyph: glyph)
                if widths[glyph] == nil { widths[glyph] = w; changed = true }
                out.append(GlyphUnit(code: UInt32(glyph), bytes: Data([UInt8(glyph >> 8), UInt8(glyph & 0xFF)]), text: String(scalar), width: w,
                                     isWordSpace: false))
            }
        }
        return out
    }

    /// The width of text in points at `size`.
    func width(of text: String, size: Double) -> Double {
        (units(of: text) ?? []).reduce(0) { $0 + $1.width } * size / 1000
    }

    private func glyph(for scalar: Unicode.Scalar) -> Int? {
        var units = Array(String(scalar).utf16)
        var glyphs = [CGGlyph](repeating: 0, count: units.count)
        guard CTFontGetGlyphsForCharacters(ctFont, &units, &glyphs, units.count), let g = glyphs.first, g != 0 else { return nil }
        return Int(g)
    }

    private func width(ofGlyph glyph: Int) -> Double {
        if let program, let w = program.width(of: glyph) { return w }
        var g = CGGlyph(glyph)
        var advance = CGSize.zero
        CTFontGetAdvancesForGlyphs(ctFont, .horizontal, &g, &advance, 1)
        return Double(advance.width) * 1000 / Double(CTFontGetSize(ctFont))
    }

    private func width(of scalar: Unicode.Scalar) -> Double {
        if let hit = measured[scalar] { return hit }
        let w = glyph(for: scalar).map(width(ofGlyph:)) ?? 500
        measured[scalar] = w
        return w
    }

    /// Writes the subset program, widths and ToUnicode map for everything encoded so far.
    func finish() {
        guard case .embedded = kind, changed else { return }
        changed = false
        FontEmbedder.writeSubset(of: self, glyphs: glyphs, widths: widths, mappings: mappings, program: program, ctFont: ctFont)
    }
}

/// Where font resources go: a page, or a form XObject we draw into.
protocol ResourceHolder {
    var model: PDFModel { get }
    var resources: PDFObject? { get }
    @discardableResult func addResource(_ resource: PDFObject, category: String, prefix: String) -> String
}

extension PDFPage: ResourceHolder {}

/// A form XObject's resources.
struct FormResources: ResourceHolder {
    let form: PDFObject
    var model: PDFModel { form.model }
    var resources: PDFObject? { form["Resources"] }

    @discardableResult func addResource(_ resource: PDFObject, category: String, prefix: String) -> String {
        if form["Resources"]?.type != .dictionary { form.set("Resources", .dictionary([:])) }
        let used = Set(form["Resources"]?[category]?.keys ?? [])
        var n = 0
        while used.contains("\(prefix)\(n)") { n += 1 }
        form["Resources"]!.dictionary(category).set("\(prefix)\(n)", resource)
        return "\(prefix)\(n)"
    }
}

enum FontEmbedder {
    /// Our subset tag: fonts we embedded are found again by it (and re-subset with more glyphs on later edits).
    static let subsetTag = "SPSUB+"
    static let standardNames: Set<String> = ["Helvetica", "Helvetica-Bold", "Helvetica-Oblique", "Helvetica-BoldOblique", "Times-Roman",
                                             "Times-Bold", "Times-Italic", "Times-BoldItalic", "Courier", "Courier-Bold", "Courier-Oblique",
                                             "Courier-BoldOblique", "Symbol", "ZapfDingbats"]

    /// A standard-14 font resource (added to the page's own resources under a fresh name).
    static func standardFont(_ name: String, on page: any ResourceHolder) -> (font: WritableFont, resourceName: String) {
        let model = page.model
        let object = model.makeIndirect(.dictionary([
            "Type": .name("Font"), "Subtype": .name("Type1"), "BaseFont": .name(name), "Encoding": .name("WinAnsiEncoding"),
        ]))
        let resourceName = page.addResource(object, category: "Font", prefix: "SPF")
        let measuring = measuringFont(for: name)
        return (WritableFont(kind: .standard(name), object: object, program: nil, ctFont: measuring), resourceName)
    }

    /// The system font that has the standard face's metrics.
    static func measuringFont(for standardName: String) -> CTFont {
        let (bold, italic) = FontMatcher.traits(in: standardName)
        let family: String = standardName.hasPrefix("Times") ? "Times" : standardName.hasPrefix("Courier") ? "Courier" : standardName.hasPrefix("Symbol") ? "Symbol" : standardName.hasPrefix("Zapf") ? "Zapf Dingbats" : "Helvetica"
        let font = FontMatcher.installedFont(family: family, bold: bold, italic: italic, size: 1000)
            ?? FontMatcher.installedFont(family: family == "Times" ? "Times New Roman" : family == "Courier" ? "Courier New" : "Helvetica", bold: bold, italic: italic, size: 1000)
            ?? NSFont.systemFont(ofSize: 1000)
        return font as CTFont
    }

    /// A font on this Mac embedded as a subset in the page's resources; an earlier subset of the same face (ours) is
    /// reused and grown.
    static func embeddedFont(_ font: NSFont, on page: any ResourceHolder) -> (font: WritableFont, resourceName: String) {
        let model = page.model
        let sized = CTFontCreateCopyWithAttributes(font as CTFont, 1000, nil, nil)
        let postScriptName = (CTFontCopyPostScriptName(sized) as String).replacingOccurrences(of: " ", with: "")
        let baseFont = subsetTag + postScriptName
        let tables = TrueTypeFont.tables(of: sized)
        let program = TrueTypeFont(tables: tables)
        // Reuse ours when the page already has it.
        if let fonts = page.resources?["Font"] {
            for name in fonts.keys {
                guard let existing = fonts[name], existing["BaseFont"]?.name == baseFont, existing["Subtype"]?.name == "Type0" else { continue }
                let writable = WritableFont(kind: .embedded(font), object: existing, program: program, ctFont: sized)
                writable.adopt(existing: existing)
                return (writable, name)
            }
        }
        let object = model.makeIndirect(.dictionary(["Type": .name("Font"), "Subtype": .name("Type0"), "BaseFont": .name(baseFont), "Encoding": .name("Identity-H")]))
        let resourceName = page.addResource(object, category: "Font", prefix: "SPF")
        let writable = WritableFont(kind: .embedded(font), object: object, program: program, ctFont: sized)
        return (writable, resourceName)
    }

    /// Writes (or rewrites) the descendant font, descriptor, program, widths and ToUnicode of a subset.
    static func writeSubset(of font: WritableFont, glyphs: Set<Int>, widths: [Int: Double], mappings: [UInt32: String], program: TrueTypeFont?, ctFont: CTFont) {
        let model = font.object.model
        let baseFont = font.object["BaseFont"]?.name ?? "SPSUB+Font"
        let descendant = font.object["DescendantFonts"]?[0] ?? model.makeIndirect(.dictionary([:]))
        let descriptor = descendant["FontDescriptor"] ?? model.makeIndirect(.dictionary([:]))
        // The font is sized at 1000, so every Core Text metric is already in 1/1000 text space.
        let bbox = CTFontGetBoundingBox(ctFont)
        let traits = CTFontGetSymbolicTraits(ctFont)
        var flags = 1 << 5   // nonsymbolic
        if traits.contains(.traitMonoSpace) { flags |= 1 }
        let serifClasses: [CTFontStylisticClass] = [.classOldStyleSerifs, .classTransitionalSerifs, .classModernSerifs, .classClarendonSerifs,
                                                    .classSlabSerifs, .classFreeformSerifs]
        let stylisticClass = CTFontStylisticClass(rawValue: traits.rawValue & CTFontSymbolicTraits.traitClassMask.rawValue)
        if serifClasses.contains(stylisticClass) { flags |= 2 }
        if traits.contains(.traitItalic) { flags |= 1 << 6 }
        if traits.contains(.traitBold) { flags |= 1 << 18 }
        descriptor.set("Type", .name("FontDescriptor"))
        descriptor.set("FontName", .name(baseFont))
        descriptor.set("Flags", .integer(flags))
        descriptor.set("FontBBox", .rect(bbox))
        descriptor.set("ItalicAngle", .number(Double(CTFontGetSlantAngle(ctFont))))
        descriptor.set("Ascent", .number(Double(CTFontGetAscent(ctFont))))
        descriptor.set("Descent", .number(-Double(CTFontGetDescent(ctFont))))
        descriptor.set("CapHeight", .number(Double(CTFontGetCapHeight(ctFont))))
        descriptor.set("StemV", .integer(traits.contains(.traitBold) ? 140 : 80))

        var fileKey = "FontFile2"
        var fileData: Data?
        var fileDict: [String: PDFValue] = [:]
        if let program {
            switch program.outlines {
            case .glyf:
                fileData = program.subset(keeping: glyphs)
                fileDict["Length1"] = .integer(fileData?.count ?? 0)
            case .cff:
                fileKey = "FontFile3"
                fileData = OpenTypeAssembler.assemble(program.tables.filter { !["GSUB", "GPOS", "GDEF", "kern", "DSIG", "name", "BASE", "JSTF", "MATH"].contains($0.key) }, version: 0x4F54544F)
                fileDict["Subtype"] = .name("OpenType")
            case .none:
                break
            }
        }
        if let fileData {
            for key in ["FontFile", "FontFile2", "FontFile3"] { descriptor.remove(key) }
            descriptor.set(fileKey, model.makeStream(fileDict, data: fileData))
        }

        descendant.set("Type", .name("Font"))
        descendant.set("Subtype", .name("CIDFontType2"))
        descendant.set("BaseFont", .name(baseFont))
        descendant.set("CIDSystemInfo", .dictionary(["Registry": .ascii("Adobe"), "Ordering": .ascii("Identity"), "Supplement": .integer(0)]))
        descendant.set("FontDescriptor", descriptor)
        descendant.set("DW", .integer(1000))
        descendant.set("CIDToGIDMap", .name("Identity"))
        var w: [PDFValue] = []
        for glyph in widths.keys.sorted() { w.append(.integer(glyph)); w.append(.array([.number((widths[glyph]! * 100).rounded() / 100)])) }
        descendant.set("W", .array(w))
        let descendants = model.make(.array([]))
        descendants.append(descendant)
        font.object.set("DescendantFonts", descendants)
        let cmap = ToUnicodeWriter.cmap(mappings.map { (code: $0.key, text: $0.value) }, byteCount: 2)
        font.object.set("ToUnicode", model.makeStream(data: cmap))
    }
}

extension WritableFont {
    /// Takes over the glyphs, widths and mappings of a subset we wrote earlier (so a rewrite keeps them).
    fileprivate func adopt(existing: PDFObject) {
        if let descendant = existing["DescendantFonts"]?[0], let w = descendant["W"] {
            let items = w.items
            var i = 0
            while i + 1 < items.count {
                if let glyph = items[i].int, let width = items[i + 1][0]?.number { glyphs.insert(glyph); widths[glyph] = width }
                i += 2
            }
        }
        if let stream = existing["ToUnicode"], let data = try? stream.streamData(decode: .all) {
            for (code, text) in CMap(parsing: data).allTextMappings() { mappings[code] = text }
        }
        changed = false
    }
}

extension WritableFont {
    /// Opens a subset font we wrote earlier (found by its name) for growing; nil for fonts that are not ours.
    static func reopen(_ object: PDFObject, named baseFont: String) -> WritableFont? {
        guard baseFont.hasPrefix(FontEmbedder.subsetTag) else { return nil }
        let postScript = String(baseFont.dropFirst(FontEmbedder.subsetTag.count))
        guard let nsFont = NSFont(name: postScript, size: 12) else { return nil }
        let sized = CTFontCreateCopyWithAttributes(nsFont as CTFont, 1000, nil, nil)
        let writable = WritableFont(kind: .embedded(nsFont), object: object, program: TrueTypeFont(tables: TrueTypeFont.tables(of: sized)), ctFont: sized)
        writable.adopt(existing: object)
        return writable
    }
}
