import AppKit
import CoreText
import Foundation
import PDFModelKit

// A font as a content stream uses it (ISO 32000-2 §9.6–9.7): decodes string bytes into glyphs with their text and
// widths, and encodes new text back into bytes when the font can show it (its encoding has the characters and the
// embedded program has the glyphs). Simple fonts (Type1, TrueType, Type3) and composite fonts (Type0 with Identity or
// embedded CMaps) are read; the predefined CJK CMaps are not shipped.

/// One shown glyph of a string: its code, bytes, text and advance.
struct GlyphUnit: Hashable {
    var code: UInt32
    var bytes: Data
    /// The text it stands for ("fi" for a ligature; "" for an unknown glyph).
    var text: String
    /// Horizontal advance in 1/1000 text space (before font size, horizontal scaling, character spacing).
    var width: Double
    /// A single-byte code 32: word spacing (Tw) applies (§9.3.3).
    var isWordSpace: Bool
}

/// A font dictionary read for editing.
final class PDFFont {
    let object: PDFObject
    let subtype: String
    let baseFont: String
    let isType0: Bool
    let isType3: Bool
    let fontMatrix: CGAffineTransform
    let facts: FontFacts
    /// Ascent and descent in 1/1000 text space.
    let ascent: Double
    let descent: Double
    private(set) var toUnicode: CMap?
    private var cidMap: CMap = .identity
    private var cidToGID: [Int]?
    private var cidWidths: [Int: Double] = [:]
    private var defaultWidth: Double = 1000
    private var simpleWidths: [Int: Double] = [:]
    private var missingWidth: Double = 0
    private var hasWidths = false
    private var baseEncoding: String?
    private var differences: [Int: String] = [:]
    private var isSymbolicFlag = false
    private(set) var embedded: TrueTypeFont?
    private(set) var embeddedKind: EmbeddedKind = .none
    /// Glyph names a Type1 or CFF program has (for existence checks); nil when unknown.
    private var programGlyphNames: Set<String>?
    private var programCIDs: Set<Int>?
    /// A system font that measures the standard 14 (and other non-embedded) fonts.
    private lazy var measuringFont: CTFont? = {
        let (font, _) = FontMatcher.match(facts, size: 1000)
        return font as CTFont
    }()
    private var measuredCache: [Unicode.Scalar: Double] = [:]
    /// Text → code, from the codes the document uses (filled by the interpreter) and the encoding.
    private var reverse: [String: UInt32] = [:]
    private var reverseBuilt = false

    enum EmbeddedKind { case none, trueType, cff, type1, openType }

    init(_ object: PDFObject) {
        self.object = object
        subtype = object["Subtype"]?.name ?? "Type1"
        isType0 = subtype == "Type0"
        isType3 = subtype == "Type3"
        let descendant = isType0 ? object["DescendantFonts"]?[0] : nil
        let base = object["BaseFont"]?.name ?? descendant?["BaseFont"]?.name ?? "Helvetica"
        baseFont = base
        fontMatrix = isType3 ? (object["FontMatrix"]?.value.matrixValue ?? CGAffineTransform(a: 0.001, b: 0, c: 0, d: 0.001, tx: 0, ty: 0)) : .identity
        let descriptor = (descendant ?? object)["FontDescriptor"]
        let flags = descriptor?["Flags"]?.int ?? 0
        let stem = FontMatcher.traits(in: base)
        let weight = descriptor?["FontWeight"]?.number ?? 0
        isSymbolicFlag = flags & 4 != 0 && flags & 32 == 0
        facts = FontFacts(baseFont: base.count > 7 && base.dropFirst(6).first == "+" ? String(base.dropFirst(7)) : base,
                          isSerif: flags & 2 != 0, isFixedPitch: flags & 1 != 0,
                          isBold: stem.bold || weight >= 600 || flags & (1 << 18) != 0,
                          isItalic: stem.italic || flags & (1 << 6) != 0 || (descriptor?["ItalicAngle"]?.number ?? 0) != 0,
                          isSymbolic: isSymbolicFlag)
        let bbox = descriptor?["FontBBox"]?.rect
        let boxTop: Double = bbox.map { Double($0.maxY) } ?? 900, boxBottom: Double = bbox.map { Double($0.minY) } ?? -200
        var ascent: Double = descriptor?["Ascent"]?.number ?? boxTop
        var descent: Double = descriptor?["Descent"]?.number ?? boxBottom
        if ascent <= 0 { ascent = boxTop > 0 ? boxTop : 900 }
        if descent > 0 { descent = -descent }
        if isType3 {
            let fm = fontMatrix
            ascent = (bbox.map { Double($0.maxY) } ?? 1000) * Double(fm.d) * 1000
            descent = (bbox.map { Double($0.minY) } ?? 0) * Double(fm.d) * 1000
        }
        self.ascent = ascent
        self.descent = descent

        if let stream = object["ToUnicode"], stream.type == .stream, let data = try? stream.streamData(decode: .all) {
            toUnicode = CMap(parsing: data)
        }
        if isType0 {
            readType0(descendant: descendant)
        } else {
            readSimple()
        }
        readProgram(descriptor)
    }

    // MARK: Reading

    private func readType0(descendant: PDFObject?) {
        if let encoding = object["Encoding"] {
            if let name = encoding.name {
                cidMap = .identity
                if name == "Identity-V" { cidMap.isVertical = true }
            } else if encoding.type == .stream, let data = try? encoding.streamData(decode: .all) {
                cidMap = CMap(parsing: data)
            }
        }
        defaultWidth = descendant?["DW"]?.number ?? 1000
        if let w = descendant?["W"] {
            let items = w.items
            var i = 0
            while i < items.count {
                guard let first = items[i].int else { i += 1; continue }
                if i + 1 < items.count, items[i + 1].type == .array {
                    for (offset, width) in items[i + 1].items.enumerated() { if let n = width.number { cidWidths[first + offset] = n } }
                    i += 2
                } else if i + 2 < items.count, let last = items[i + 1].int, let width = items[i + 2].number {
                    if last >= first, last - first < 65536 { for cid in first...last { cidWidths[cid] = width } }
                    i += 3
                } else {
                    i += 1
                }
            }
        }
        if let map = descendant?["CIDToGIDMap"], map.type == .stream, let data = try? map.streamData(decode: .all) {
            let b = [UInt8](data)
            cidToGID = stride(from: 0, to: b.count - 1, by: 2).map { Int(b[$0]) << 8 | Int(b[$0 + 1]) }
        }
    }

    private func readSimple() {
        let first = object["FirstChar"]?.int ?? 0
        if let widths = object["Widths"], widths.type == .array {
            hasWidths = widths.count > 0
            for (i, w) in widths.items.enumerated() {
                if let n = w.number { simpleWidths[first + i] = isType3 ? n * fontMatrix.a * 1000 : n }
            }
        }
        missingWidth = object["FontDescriptor"]?["MissingWidth"]?.number ?? 0
        if let encoding = object["Encoding"] {
            if let name = encoding.name {
                baseEncoding = name
            } else {
                baseEncoding = encoding["BaseEncoding"]?.name
                if let diffs = encoding["Differences"] {
                    var code = 0
                    for item in diffs.items {
                        if let n = item.int, item.type == .integer || item.type == .real { code = n } else if let name = item.name { differences[code] = name; code += 1 }
                    }
                }
            }
        }
        if baseEncoding == nil, !isSymbolicFlag, !isType3 { baseEncoding = "StandardEncoding" }
        // The standard 14 ship no widths; Quartz and others do. A non-embedded TrueType with WinAnsi is the usual case.
    }

    private func readProgram(_ descriptor: PDFObject?) {
        guard let descriptor else { return }
        if let file = descriptor["FontFile2"], file.type == .stream, let data = try? file.streamData(decode: .all) {
            embedded = TrueTypeFont(data: data)
            embeddedKind = .trueType
        } else if let file = descriptor["FontFile3"], file.type == .stream, let data = try? file.streamData(decode: .all) {
            if let font = TrueTypeFont(data: data) {
                embedded = font
                embeddedKind = .openType
                if font.outlines == .cff, let cff = font.tables["CFF "] { readCFF(cff) }
            } else {
                embeddedKind = .cff
                readCFF(data)
            }
        } else if let file = descriptor["FontFile"], file.type == .stream, let data = try? file.streamData(decode: .all) {
            embeddedKind = .type1
            programGlyphNames = Type1Program.glyphNames(in: data)
        }
    }

    private func readCFF(_ data: Data) {
        guard let charset = CFFProgram.charset(of: data) else { return }
        switch charset {
        case .names(let names): programGlyphNames = names
        case .cids(let cids): programCIDs = cids
        }
    }

    var isEmbedded: Bool { embeddedKind != .none }

    // MARK: Decoding

    /// The glyphs of string bytes, with their text and widths.
    func decode(_ bytes: Data) -> [GlyphUnit] {
        if isType0 {
            return cidMap.codes(in: bytes).map { code, byteCount in
                let cid = cidMap.cid(code)
                let text = toUnicode?.text(code) ?? ""
                let width = cidWidths[cid] ?? defaultWidth
                return GlyphUnit(code: code, bytes: cidMap.bytes(for: code, byteCount: byteCount), text: text, width: width,
                                 isWordSpace: byteCount == 1 && code == 32)
            }
        }
        return bytes.map { byte in
            let code = Int(byte)
            return GlyphUnit(code: UInt32(code), bytes: Data([byte]), text: text(forSimpleCode: code), width: width(forSimpleCode: code),
                             isWordSpace: code == 32)
        }
    }

    private func text(forSimpleCode code: Int) -> String {
        if let text = toUnicode?.text(UInt32(code)) { return text }
        if let name = differences[code] {
            if let scalar = GlyphNames.scalar(for: name) { return String(scalar) }
        }
        if let base = baseEncoding, let scalar = PDFEncoding.character(code, in: base) { return String(scalar) }
        if isSymbolicFlag, let embedded, embedded.symbolMap[code] != nil || embedded.symbolMap[0xF000 + code] != nil {
            return ""   // a symbol font's private glyph
        }
        if let scalar = PDFEncoding.character(code, in: "StandardEncoding") { return String(scalar) }
        return ""
    }

    private func width(forSimpleCode code: Int) -> Double {
        if let w = simpleWidths[code], w != 0 || hasWidths { return w }
        if hasWidths { return missingWidth }
        // No /Widths: a standard 14 font (or a careless producer); measure with the matching system font.
        if let embedded, let glyph = embeddedGlyph(forSimpleCode: code), let w = embedded.width(of: glyph) { return w }
        let text = text(forSimpleCode: code)
        guard let scalar = text.unicodeScalars.first else { return missingWidth }
        return measuredWidth(scalar)
    }

    private func measuredWidth(_ scalar: Unicode.Scalar) -> Double {
        if let hit = measuredCache[scalar] { return hit }
        guard let font = measuringFont else { return 500 }
        var units = Array(String(scalar).utf16)
        var glyphs = [CGGlyph](repeating: 0, count: units.count)
        guard CTFontGetGlyphsForCharacters(font, &units, &glyphs, units.count), let glyph = glyphs.first, glyph != 0 else { return 500 }
        var advance = CGSize.zero
        var g = glyph
        CTFontGetAdvancesForGlyphs(font, .horizontal, &g, &advance, 1)
        measuredCache[scalar] = advance.width
        return advance.width
    }

    /// The embedded TrueType glyph a simple-font code selects (§9.6.6.4).
    private func embeddedGlyph(forSimpleCode code: Int) -> Int? {
        guard let embedded else { return nil }
        if isSymbolicFlag || baseEncoding == nil && differences.isEmpty {
            if let g = embedded.symbolMap[0xF000 + code] ?? embedded.symbolMap[code] { return g }
            if let g = embedded.macRomanMap[code] { return g }
        }
        var name = differences[code]
        if name == nil, let base = baseEncoding, let scalar = PDFEncoding.character(code, in: base) { name = GlyphNames.name(for: scalar) ?? String(scalar) }
        if let name, let scalar = GlyphNames.scalar(for: name), let g = embedded.unicodeMap[scalar.value] { return g }
        if let name, let scalar = GlyphNames.scalar(for: name), let mac = PDFEncoding.code(for: scalar, in: "MacRomanEncoding"), let g = embedded.macRomanMap[mac] { return g }
        if let g = embedded.symbolMap[0xF000 + code] ?? embedded.symbolMap[code] { return g }
        if !embedded.hasCmap { return code }
        return nil
    }

    // MARK: Encoding

    /// Records the codes a document uses (their glyphs are known to exist), for the reverse map.
    func noteUsed(_ units: [GlyphUnit]) {
        for unit in units where !unit.text.isEmpty && reverse[unit.text] == nil { reverse[unit.text] = unit.code }
    }

    private func buildReverse() {
        guard !reverseBuilt else { return }
        reverseBuilt = true
        if let toUnicode {
            for (code, text) in toUnicode.allTextMappings() where !text.isEmpty && reverse[text] == nil && glyphExists(code) { reverse[text] = code }
        }
        if !isType0 {
            for (code, name) in differences {
                if let scalar = GlyphNames.scalar(for: name), reverse[String(scalar)] == nil, glyphExists(UInt32(code)) { reverse[String(scalar)] = UInt32(code) }
            }
            if let base = baseEncoding {
                for code in 32...255 {
                    guard differences[code] == nil, let scalar = PDFEncoding.character(code, in: base), reverse[String(scalar)] == nil else { continue }
                    if glyphExists(UInt32(code)) { reverse[String(scalar)] = UInt32(code) }
                }
            }
        } else if cidMap.isIdentity, let embedded, embedded.hasCmap {
            for (scalar, glyph) in embedded.unicodeMap {
                guard let s = Unicode.Scalar(scalar) else { continue }
                let cid = cidToGID.map { map in map.firstIndex(of: glyph) ?? -1 } ?? glyph
                if cid >= 0, reverse[String(s)] == nil, embedded.hasOutline(glyph) || s == " " { reverse[String(s)] = UInt32(cid) }
            }
        }
    }

    /// Whether the embedded program has the glyph for a code (true when nothing is embedded: the viewer's font has it).
    private func glyphExists(_ code: UInt32) -> Bool {
        switch embeddedKind {
        case .none:
            return true
        case .trueType, .openType:
            guard let embedded else { return true }
            if isType0 {
                let cid = cidMap.cid(code)
                let glyph = cidToGID.map { cid < $0.count ? $0[cid] : 0 } ?? cid
                if embedded.outlines == .cff, let cids = programCIDs { return cids.contains(cid) }
                return embedded.hasOutline(glyph) || code == 32
            }
            if embedded.outlines == .cff {
                return programGlyph(forSimpleCode: Int(code))
            }
            guard let glyph = embeddedGlyph(forSimpleCode: Int(code)) else { return false }
            return embedded.hasOutline(glyph) || code == 32
        case .cff, .type1:
            if isType0 { return programCIDs?.contains(cidMap.cid(code)) ?? (hasWidths ? cidWidths[cidMap.cid(code)] != nil : true) }
            return programGlyph(forSimpleCode: Int(code))
        }
    }

    private func programGlyph(forSimpleCode code: Int) -> Bool {
        guard let names = programGlyphNames else { return simpleWidths[code].map { $0 > 0 } ?? false }
        if let name = differences[code] { return names.contains(name) }
        if let base = baseEncoding, let scalar = PDFEncoding.character(code, in: base) {
            if let name = GlyphNames.name(for: scalar), names.contains(name) { return true }
            return names.contains(String(format: "uni%04X", scalar.value))
        }
        return false
    }

    /// The bytes that show `text` with this font, nil when a character has no glyph here.
    func encode(_ text: String) -> Data? {
        buildReverse()
        var out = Data()
        var rest = Substring(text)
        while let first = rest.first {
            // Longest match first (ligatures in ToUnicode: "fi").
            var matched = false
            for length in stride(from: min(3, rest.count), through: 1, by: -1) {
                let candidate = String(rest.prefix(length))
                if let code = reverse[candidate] {
                    out.append(bytes(for: code)); rest = rest.dropFirst(length); matched = true; break
                }
            }
            if matched { continue }
            if let decomposed = decomposedCode(first) { out.append(bytes(for: decomposed)); rest = rest.dropFirst(); continue }
            return nil
        }
        return out
    }

    /// Curly quotes and dashes that a font without them can still show plainly.
    private func decomposedCode(_ ch: Character) -> UInt32? {
        let plain: [Character: String] = ["\u{2019}": "'", "\u{2018}": "'", "\u{201C}": "\"", "\u{201D}": "\"", "\u{00A0}": " ", "\u{2011}": "-"]
        guard let replacement = plain[ch] else { return nil }
        return reverse[replacement]
    }

    private func bytes(for code: UInt32) -> Data {
        if isType0 { return cidMap.bytes(for: code, byteCount: code > 0xFF || cidMap.isIdentity ? 2 : (cidMap.codes(in: Data([UInt8(code)])).first?.byteCount ?? 2)) }
        return Data([UInt8(truncatingIfNeeded: code)])
    }

    /// Whether every character of `text` can be shown.
    func canShow(_ text: String) -> Bool { encode(text) != nil }

    /// Widths of encoded text, per glyph (1/1000 text space).
    func units(of text: String) -> [GlyphUnit]? { encode(text).map(decode) }
}

// MARK: - Type 1 and CFF programs: which glyphs they have

enum Type1Program {
    /// The glyph names of a Type 1 program (PFA/PFB; the charstrings live in the eexec section).
    static func glyphNames(in data: Data) -> Set<String>? {
        var bytes = [UInt8](data)
        // PFB segments: strip the 6-byte headers.
        if bytes.count > 6, bytes[0] == 0x80 {
            var out: [UInt8] = []
            var i = 0
            while i + 6 <= bytes.count, bytes[i] == 0x80, bytes[i + 1] != 3 {
                let length = Int(bytes[i + 2]) | Int(bytes[i + 3]) << 8 | Int(bytes[i + 4]) << 16 | Int(bytes[i + 5]) << 24
                out.append(contentsOf: bytes[(i + 6)..<min(i + 6 + length, bytes.count)])
                i += 6 + length
            }
            bytes = out
        }
        guard let marker = range(of: Array("eexec".utf8), in: bytes) else { return nil }
        var start = marker + 5
        while start < bytes.count, [13, 10, 32, 9].contains(bytes[start]) { start += 1 }
        var encrypted = Array(bytes[start...])
        let isHex = encrypted.prefix(4).allSatisfy { (48...57).contains($0) || (65...70).contains($0) || (97...102).contains($0) }
        if isHex {
            var out: [UInt8] = []
            var high: UInt8?
            for b in encrypted {
                guard let v = hexValue(b) else { continue }
                if let h = high { out.append(h << 4 | v); high = nil } else { high = v }
            }
            encrypted = out
        }
        var r: UInt16 = 55665
        var plain: [UInt8] = []
        plain.reserveCapacity(encrypted.count)
        for c in encrypted {
            plain.append(c ^ UInt8(truncatingIfNeeded: r >> 8))
            r = (UInt16(c) &+ r) &* 52845 &+ 22719
        }
        guard let charStrings = range(of: Array("/CharStrings".utf8), in: plain) else { return nil }
        var names: Set<String> = []
        var i = charStrings + 12
        while i < plain.count {
            guard plain[i] == UInt8(ascii: "/") else { i += 1; continue }
            var j = i + 1
            while j < plain.count, !PDFSyntaxLite.isWhitespace(plain[j]), plain[j] != UInt8(ascii: "{"), plain[j] != UInt8(ascii: "/") { j += 1 }
            let name = String(decoding: plain[(i + 1)..<j], as: UTF8.self)
            if name == "end" || name.isEmpty { break }
            names.insert(name)
            // Skip the binary charstring: "<len> RD <bytes> ND".
            var k = j
            while k < plain.count, PDFSyntaxLite.isWhitespace(plain[k]) { k += 1 }
            var digits = ""
            while k < plain.count, (48...57).contains(plain[k]) { digits.append(Character(Unicode.Scalar(plain[k]))); k += 1 }
            if let length = Int(digits) {
                while k < plain.count, PDFSyntaxLite.isWhitespace(plain[k]) { k += 1 }
                while k < plain.count, !PDFSyntaxLite.isWhitespace(plain[k]) { k += 1 }   // RD / -|
                k += 1 + length
            }
            i = max(k, j)
            if names.count > 70_000 { break }
        }
        return names
    }

    private static func range(of pattern: [UInt8], in bytes: [UInt8]) -> Int? {
        guard pattern.count <= bytes.count else { return nil }
        for i in 0...(bytes.count - pattern.count) where bytes[i] == pattern[0] && Array(bytes[i..<(i + pattern.count)]) == pattern { return i }
        return nil
    }

    private static func hexValue(_ b: UInt8) -> UInt8? {
        switch b {
        case 48...57: b - 48
        case 65...70: b - 55
        case 97...102: b - 87
        default: nil
        }
    }
}

enum PDFSyntaxLite {
    static func isWhitespace(_ b: UInt8) -> Bool { b == 0 || b == 9 || b == 10 || b == 12 || b == 13 || b == 32 }
}

enum CFFProgram {
    enum Charset { case names(Set<String>), cids(Set<Int>) }

    /// The charset of a bare CFF program: glyph names (through the standard strings) or CIDs for a CID-keyed font.
    static func charset(of data: Data) -> Charset? {
        let b = [UInt8](data)
        guard b.count > 4 else { return nil }
        let headerSize = Int(b[2])
        var pos = headerSize
        guard let nameIndex = readIndex(b, &pos), nameIndex.count >= 1 else { return nil }
        guard let topIndex = readIndex(b, &pos), let top = topIndex.first else { return nil }
        guard let stringIndex = readIndex(b, &pos) else { return nil }
        let dict = parseDict(top)
        guard let charStringsOffset = dict[17]?.first.map(Int.init) else { return nil }
        var p = charStringsOffset
        guard let charStrings = readIndexCount(b, &p) else { return nil }
        let nGlyphs = charStrings
        let isCID = dict[1230] != nil
        let charsetOffset = dict[15]?.first.map(Int.init) ?? 0
        var sids: [Int] = [0]
        switch charsetOffset {
        case 0:   // ISOAdobe: SIDs 1…228 in order
            sids = Array(0..<nGlyphs)
        case 1, 2:
            return nil   // Expert charsets: not used for text we edit
        default:
            guard charsetOffset < b.count else { return nil }
            let format = b[charsetOffset]
            var q = charsetOffset + 1
            if format == 0 {
                while sids.count < nGlyphs, q + 1 < b.count { sids.append(Int(b[q]) << 8 | Int(b[q + 1])); q += 2 }
            } else if format == 1 || format == 2 {
                while sids.count < nGlyphs, q + 2 < b.count {
                    let first = Int(b[q]) << 8 | Int(b[q + 1])
                    let left = format == 1 ? Int(b[q + 2]) : (q + 3 < b.count ? Int(b[q + 2]) << 8 | Int(b[q + 3]) : 0)
                    q += format == 1 ? 3 : 4
                    for n in 0...left where sids.count < nGlyphs { sids.append(first + n) }
                }
            }
        }
        if isCID { return .cids(Set(sids)) }
        var names: Set<String> = []
        for sid in sids {
            if sid < standardStrings.count { names.insert(standardStrings[sid]) } else if sid - standardStrings.count < stringIndex.count {
                names.insert(String(decoding: stringIndex[sid - standardStrings.count], as: UTF8.self))
            }
        }
        return .names(names)
    }

    private static func readIndexCount(_ b: [UInt8], _ pos: inout Int) -> Int? {
        guard pos + 2 <= b.count else { return nil }
        return Int(b[pos]) << 8 | Int(b[pos + 1])
    }

    private static func readIndex(_ b: [UInt8], _ pos: inout Int) -> [[UInt8]]? {
        guard pos + 2 <= b.count else { return nil }
        let count = Int(b[pos]) << 8 | Int(b[pos + 1])
        pos += 2
        if count == 0 { return [] }
        guard pos < b.count else { return nil }
        let offSize = Int(b[pos]); pos += 1
        guard (1...4).contains(offSize), pos + (count + 1) * offSize <= b.count else { return nil }
        var offsets: [Int] = []
        for i in 0...count {
            var v = 0
            for j in 0..<offSize { v = v << 8 | Int(b[pos + i * offSize + j]) }
            offsets.append(v)
        }
        pos += (count + 1) * offSize
        let base = pos - 1
        var items: [[UInt8]] = []
        for i in 0..<count {
            let start = base + offsets[i], end = base + offsets[i + 1]
            guard start >= 0, start <= end, end <= b.count else { return nil }
            items.append(Array(b[start..<end]))
        }
        pos = base + offsets[count]
        return items
    }

    /// Top DICT operators → operands; two-byte operators are keyed 1200 + second byte.
    private static func parseDict(_ b: [UInt8]) -> [Int: [Double]] {
        var dict: [Int: [Double]] = [:]
        var operands: [Double] = []
        var i = 0
        while i < b.count {
            let b0 = Int(b[i])
            switch b0 {
            case 0...21:
                if b0 == 12, i + 1 < b.count { dict[1200 + Int(b[i + 1])] = operands; i += 2 } else { dict[b0] = operands; i += 1 }
                operands = []
            case 28: operands.append(Double(Int16(bitPattern: UInt16(b[i + 1]) << 8 | UInt16(b[i + 2])))); i += 3
            case 29: operands.append(Double(Int32(bitPattern: UInt32(b[i + 1]) << 24 | UInt32(b[i + 2]) << 16 | UInt32(b[i + 3]) << 8 | UInt32(b[i + 4])))); i += 5
            case 30:   // real: nibbles until 0xF
                i += 1
                var text = ""
                loop: while i < b.count {
                    for nibble in [b[i] >> 4, b[i] & 0xF] {
                        switch nibble {
                        case 0...9: text.append(String(nibble))
                        case 0xA: text.append(".")
                        case 0xB: text.append("E")
                        case 0xC: text.append("E-")
                        case 0xE: text.append("-")
                        case 0xF: i += 1; break loop
                        default: break
                        }
                    }
                    i += 1
                }
                operands.append(Double(text) ?? 0)
            case 32...246: operands.append(Double(b0 - 139)); i += 1
            case 247...250: operands.append(Double((b0 - 247) * 256 + Int(b[i + 1]) + 108)); i += 2
            case 251...254: operands.append(Double(-(b0 - 251) * 256 - Int(b[i + 1]) - 108)); i += 2
            default: i += 1
            }
            if i > b.count { break }
        }
        return dict
    }

    /// The 391 CFF standard strings.
    static let standardStrings: [String] = """
    .notdef space exclam quotedbl numbersign dollar percent ampersand quoteright parenleft parenright asterisk plus comma hyphen period \
    slash zero one two three four five six seven eight nine colon semicolon less equal greater question at A B C D E F G H I J K L M N O \
    P Q R S T U V W X Y Z bracketleft backslash bracketright asciicircum underscore quoteleft a b c d e f g h i j k l m n o p q r s t u v w \
    x y z braceleft bar braceright asciitilde exclamdown cent sterling fraction yen florin section currency quotesingle quotedblleft \
    guillemotleft guilsinglleft guilsinglright fi fl endash dagger daggerdbl periodcentered paragraph bullet quotesinglbase quotedblbase \
    quotedblright guillemotright ellipsis perthousand questiondown grave acute circumflex tilde macron breve dotaccent dieresis ring \
    cedilla hungarumlaut ogonek caron emdash AE ordfeminine Lslash Oslash OE ordmasculine ae dotlessi lslash oslash oe germandbls \
    onesuperior logicalnot mu trademark Eth onehalf plusminus Thorn onequarter divide brokenbar degree thorn threequarters twosuperior \
    registered minus eth multiply threesuperior copyright Aacute Acircumflex Adieresis Agrave Aring Atilde Ccedilla Eacute Ecircumflex \
    Edieresis Egrave Iacute Icircumflex Idieresis Igrave Ntilde Oacute Ocircumflex Odieresis Ograve Otilde Scaron Uacute Ucircumflex \
    Udieresis Ugrave Yacute Ydieresis Zcaron aacute acircumflex adieresis agrave aring atilde ccedilla eacute ecircumflex edieresis egrave \
    iacute icircumflex idieresis igrave ntilde oacute ocircumflex odieresis ograve otilde scaron uacute ucircumflex udieresis ugrave yacute \
    ydieresis zcaron exclamsmall Hungarumlautsmall dollaroldstyle dollarsuperior ampersandsmall Acutesmall parenleftsuperior \
    parenrightsuperior twodotenleader onedotenleader zerooldstyle oneoldstyle twooldstyle threeoldstyle fouroldstyle fiveoldstyle \
    sixoldstyle sevenoldstyle eightoldstyle nineoldstyle commasuperior threequartersemdash periodsuperior questionsmall asuperior \
    bsuperior centsuperior dsuperior esuperior isuperior lsuperior msuperior nsuperior osuperior rsuperior ssuperior tsuperior ff ffi ffl \
    parenleftinferior parenrightinferior Circumflexsmall hyphensuperior Gravesmall Asmall Bsmall Csmall Dsmall Esmall Fsmall Gsmall Hsmall \
    Ismall Jsmall Ksmall Lsmall Msmall Nsmall Osmall Psmall Qsmall Rsmall Ssmall Tsmall Usmall Vsmall Wsmall Xsmall Ysmall Zsmall \
    colonmonetary onefitted rupiah Tildesmall exclamdownsmall centoldstyle Lslashsmall Scaronsmall Zcaronsmall Dieresissmall Brevesmall \
    Caronsmall Dotaccentsmall Macronsmall figuredash hypheninferior Ogoneksmall Ringsmall Cedillasmall questiondownsmall oneeighth \
    threeeighths fiveeighths seveneighths onethird twothirds zerosuperior foursuperior fivesuperior sixsuperior sevensuperior \
    eightsuperior ninesuperior zeroinferior oneinferior twoinferior threeinferior fourinferior fiveinferior sixinferior seveninferior \
    eightinferior nineinferior centinferior dollarinferior periodinferior commainferior Agravesmall Aacutesmall Acircumflexsmall \
    Atildesmall Adieresissmall Aringsmall AEsmall Ccedillasmall Egravesmall Eacutesmall Ecircumflexsmall Edieresissmall Igravesmall \
    Iacutesmall Icircumflexsmall Idieresissmall Ethsmall Ntildesmall Ogravesmall Oacutesmall Ocircumflexsmall Otildesmall Odieresissmall \
    OEsmall Oslashsmall Ugravesmall Uacutesmall Ucircumflexsmall Udieresissmall Yacutesmall Thornsmall Ydieresissmall 001.000 001.001 \
    001.002 001.003 Black Bold Book Light Medium Regular Roman Semibold
    """.split(separator: " ").map(String.init)
}
