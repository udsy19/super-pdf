import CoreText
import Foundation

// TrueType and OpenType font programs (the sfnt container): enough of head, hhea, maxp, hmtx, loca, glyf and cmap to
// read an embedded font's glyphs and widths, and a subsetter that writes a glyf font with only the glyphs used
// (features #60: "font subsetting for new glyphs via Core Text + own CFF/TrueType subsetter"). CFF-based OpenType
// fonts are wrapped whole (`OpenTypeAssembler`): their glyphs are selected by index, so the file works as it is.

struct TrueTypeFont {
    enum Outlines { case glyf, cff, none }

    private(set) var tables: [String: Data] = [:]
    private(set) var unitsPerEm: Int = 1000
    private(set) var numGlyphs: Int = 0
    private(set) var indexToLocFormat: Int = 0
    private(set) var ascender: Int = 0
    private(set) var descender: Int = 0
    private var loca: [Int] = []
    private var advances: [Int] = []
    /// Unicode → glyph index from the (3,10), (3,1), (0,x) subtables; Mac Roman codes from (1,0).
    private(set) var unicodeMap: [UInt32: Int] = [:]
    private(set) var macRomanMap: [Int: Int] = [:]
    /// Platform 3 encoding 0: symbol fonts map codes to F0xx.
    private(set) var symbolMap: [Int: Int] = [:]
    var hasCmap: Bool { !unicodeMap.isEmpty || !macRomanMap.isEmpty || !symbolMap.isEmpty }

    var outlines: Outlines {
        if tables["glyf"] != nil { return .glyf }
        if tables["CFF "] != nil { return .cff }
        return .none
    }

    /// Parses an sfnt; nil when the bytes are not one (or are a bare CFF, which has no sfnt header).
    init?(data: Data) {
        let bytes = [UInt8](data)
        guard bytes.count >= 12 else { return nil }
        var offset = 0
        var tag = Self.u32(bytes, 0)
        if tag == 0x74746366 {   // 'ttcf': the first font of a collection
            guard bytes.count >= 16 else { return nil }
            offset = Int(Self.u32(bytes, 12))
            guard offset + 12 <= bytes.count else { return nil }
            tag = Self.u32(bytes, offset)
        }
        guard tag == 0x00010000 || tag == 0x74727565 || tag == 0x4F54544F else { return nil }   // 1.0, 'true', 'OTTO'
        let numTables = Int(Self.u16(bytes, offset + 4))
        var record = offset + 12
        var found: [String: Data] = [:]
        for _ in 0..<numTables {
            guard record + 16 <= bytes.count else { break }
            let name = String(bytes: bytes[record..<(record + 4)], encoding: .isoLatin1) ?? "????"
            let start = Int(Self.u32(bytes, record + 8)), length = Int(Self.u32(bytes, record + 12))
            if start < bytes.count { found[name] = Data(bytes[start..<min(start + length, bytes.count)]) }
            record += 16
        }
        self.init(tables: found)
    }

    /// A font from its tables (a system font read through Core Text, or a parsed file).
    init?(tables: [String: Data]) {
        self.tables = tables
        guard let head = tables["head"].map({ [UInt8]($0) }), head.count >= 54 else { return nil }
        unitsPerEm = Int(Self.u16(head, 18))
        if unitsPerEm == 0 { unitsPerEm = 1000 }
        indexToLocFormat = Int(Int16(bitPattern: Self.u16(head, 50)))
        if let maxp = tables["maxp"].map({ [UInt8]($0) }), maxp.count >= 6 { numGlyphs = Int(Self.u16(maxp, 4)) }
        if let hhea = tables["hhea"].map({ [UInt8]($0) }), hhea.count >= 36 {
            ascender = Int(Int16(bitPattern: Self.u16(hhea, 4)))
            descender = Int(Int16(bitPattern: Self.u16(hhea, 6)))
            let metrics = Int(Self.u16(hhea, 34))
            if let hmtx = tables["hmtx"].map({ [UInt8]($0) }) {
                advances = (0..<metrics).compactMap { i in i * 4 + 2 <= hmtx.count ? Int(Self.u16(hmtx, i * 4)) : nil }
            }
        }
        if let locaData = tables["loca"].map({ [UInt8]($0) }) {
            let count = numGlyphs + 1
            if indexToLocFormat == 0 {
                loca = (0..<count).compactMap { i in i * 2 + 2 <= locaData.count ? Int(Self.u16(locaData, i * 2)) * 2 : nil }
            } else {
                loca = (0..<count).compactMap { i in i * 4 + 4 <= locaData.count ? Int(Self.u32(locaData, i * 4)) : nil }
            }
        }
        if let cmap = tables["cmap"] { parseCmap([UInt8](cmap)) }
    }

    // MARK: Glyphs

    /// The advance of a glyph in font units.
    func advance(of glyph: Int) -> Int? {
        guard !advances.isEmpty, glyph >= 0 else { return nil }
        return advances[min(glyph, advances.count - 1)]
    }

    /// The advance in 1/1000 text space.
    func width(of glyph: Int) -> Double? { advance(of: glyph).map { Double($0) * 1000 / Double(unitsPerEm) } }

    /// Whether the glyph has an outline (an empty glyph is a space or a missing one).
    func hasOutline(_ glyph: Int) -> Bool {
        switch outlines {
        case .glyf: return glyph >= 0 && glyph + 1 < loca.count && loca[glyph + 1] > loca[glyph]
        case .cff: return glyph >= 0 && glyph < max(numGlyphs, 1)
        case .none: return false
        }
    }

    /// The glyph for a character through the font's Unicode cmap.
    func glyph(for scalar: Unicode.Scalar) -> Int? { unicodeMap[scalar.value] }

    /// The bytes of a glyph's outline and the glyphs a composite refers to.
    private func glyphData(_ glyph: Int) -> (data: ArraySlice<UInt8>, components: [Int])? {
        guard let glyf = tables["glyf"], glyph + 1 < loca.count else { return nil }
        let bytes = [UInt8](glyf)
        let start = loca[glyph], end = min(loca[glyph + 1], bytes.count)
        guard end > start, start >= 0 else { return ([], []) }
        let data = bytes[start..<end]
        var components: [Int] = []
        if data.count >= 10, Int16(bitPattern: Self.u16(bytes, start)) < 0 {
            var p = start + 10
            while p + 4 <= end {
                let flags = Self.u16(bytes, p), index = Int(Self.u16(bytes, p + 2))
                components.append(index)
                p += 4
                p += flags & 0x0001 != 0 ? 4 : 2
                if flags & 0x0008 != 0 { p += 2 } else if flags & 0x0040 != 0 { p += 4 } else if flags & 0x0080 != 0 { p += 8 }
                if flags & 0x0020 == 0 { break }
            }
        }
        return (data, components)
    }

    // MARK: Subsetting

    /// A glyf font keeping only `glyphs` (and the components they use) at their original indices; the other glyphs
    /// are empty. Glyph 0 (.notdef) is always kept.
    func subset(keeping glyphs: Set<Int>) -> Data? {
        guard outlines == .glyf, tables["head"] != nil, tables["hhea"] != nil, tables["maxp"] != nil, tables["hmtx"] != nil else { return nil }
        var keep: Set<Int> = [0]
        var queue = Array(glyphs)
        while let glyph = queue.popLast() {
            guard glyph >= 0, glyph < numGlyphs, keep.insert(glyph).inserted else { continue }
            if let (_, components) = glyphData(glyph) { queue.append(contentsOf: components) }
        }
        // Glyphs past the last kept one are dropped altogether (Latin glyphs sit low in most fonts), so loca and hmtx
        // shrink with them; hinting programs and the cmap are not needed by a PDF viewer (glyphs are chosen by index).
        let newNumGlyphs = (keep.max() ?? 0) + 1
        var glyf = Data()
        var newLoca: [UInt32] = []
        for glyph in 0..<newNumGlyphs {
            newLoca.append(UInt32(glyf.count))
            if keep.contains(glyph), let (data, _) = glyphData(glyph), !data.isEmpty {
                glyf.append(contentsOf: data)
                while glyf.count % 4 != 0 { glyf.append(0) }
            }
        }
        newLoca.append(UInt32(glyf.count))
        var locaData = Data()
        for offset in newLoca { Self.append(&locaData, u32: offset) }
        var head = tables["head"]!
        head.withUnsafeMutableBytes { (raw: UnsafeMutableRawBufferPointer) in
            raw[50] = 0; raw[51] = 1   // long loca
            for i in 8..<12 { raw[i] = 0 }   // checkSumAdjustment, recomputed below
        }
        var maxp = tables["maxp"]!
        maxp.withUnsafeMutableBytes { (raw: UnsafeMutableRawBufferPointer) in raw[4] = UInt8(newNumGlyphs >> 8); raw[5] = UInt8(newNumGlyphs & 0xFF) }
        let hmtxBytes = [UInt8](tables["hmtx"]!)
        var hhea = tables["hhea"]!
        let oldMetrics = Int(Self.u16([UInt8](hhea), 34))
        let newMetrics = min(oldMetrics, newNumGlyphs)
        hhea.withUnsafeMutableBytes { (raw: UnsafeMutableRawBufferPointer) in raw[34] = UInt8(newMetrics >> 8); raw[35] = UInt8(newMetrics & 0xFF) }
        var hmtx = Data(hmtxBytes.prefix(newMetrics * 4))
        if newNumGlyphs > newMetrics {
            let lsbStart = oldMetrics * 4
            hmtx.append(contentsOf: hmtxBytes[min(lsbStart, hmtxBytes.count)..<min(lsbStart + (newNumGlyphs - newMetrics) * 2, hmtxBytes.count)])
        }
        while hmtx.count < newMetrics * 4 + (newNumGlyphs - newMetrics) * 2 { hmtx.append(0) }
        let out: [String: Data] = ["head": head, "hhea": hhea, "maxp": maxp, "hmtx": hmtx, "loca": locaData, "glyf": glyf]
        return OpenTypeAssembler.assemble(out, version: 0x00010000)
    }

    /// The glyph indices and advances for text through the font's cmap (nil when a character has no glyph).
    func glyphs(for text: String) -> [Int]? {
        var out: [Int] = []
        for scalar in text.unicodeScalars {
            guard let glyph = unicodeMap[scalar.value] else { return nil }
            out.append(glyph)
        }
        return out
    }

    // MARK: cmap

    private mutating func parseCmap(_ bytes: [UInt8]) {
        guard bytes.count >= 4 else { return }
        let count = Int(Self.u16(bytes, 2))
        var best: (score: Int, offset: Int, platform: Int, encoding: Int)?
        var mac: Int?
        var symbol: Int?
        for i in 0..<count {
            let record = 4 + i * 8
            guard record + 8 <= bytes.count else { break }
            let platform = Int(Self.u16(bytes, record)), encoding = Int(Self.u16(bytes, record + 2)), offset = Int(Self.u32(bytes, record + 4))
            guard offset < bytes.count else { continue }
            let score: Int
            switch (platform, encoding) {
            case (3, 10): score = 4
            case (0, 4), (0, 6): score = 3
            case (3, 1): score = 2
            case (0, _): score = 1
            case (3, 0): symbol = offset; continue
            case (1, 0): mac = offset; continue
            default: continue
            }
            if best == nil || score > best!.score { best = (score, offset, platform, encoding) }
        }
        if let best { unicodeMap = parseSubtable(bytes, at: best.offset) }
        if let mac { macRomanMap = parseSubtable(bytes, at: mac).reduce(into: [:]) { $0[Int($1.key)] = $1.value } }
        if let symbol { symbolMap = parseSubtable(bytes, at: symbol).reduce(into: [:]) { $0[Int($1.key)] = $1.value } }
    }

    private func parseSubtable(_ b: [UInt8], at offset: Int) -> [UInt32: Int] {
        guard offset + 4 <= b.count else { return [:] }
        var map: [UInt32: Int] = [:]
        switch Self.u16(b, offset) {
        case 0:
            for code in 0..<256 where offset + 6 + code < b.count {
                let glyph = Int(b[offset + 6 + code])
                if glyph != 0 { map[UInt32(code)] = glyph }
            }
        case 4:
            let segCountX2 = Int(Self.u16(b, offset + 6))
            let segCount = segCountX2 / 2
            let ends = offset + 14, starts = ends + segCountX2 + 2, deltas = starts + segCountX2, rangeOffsets = deltas + segCountX2
            guard rangeOffsets + segCountX2 <= b.count else { return map }
            for seg in 0..<segCount {
                let end = Int(Self.u16(b, ends + seg * 2)), start = Int(Self.u16(b, starts + seg * 2))
                let delta = Int(Self.u16(b, deltas + seg * 2)), rangeOffset = Int(Self.u16(b, rangeOffsets + seg * 2))
                guard start <= end, end - start < 65536 else { continue }
                for code in start...end where code != 0xFFFF {
                    var glyph: Int
                    if rangeOffset == 0 {
                        glyph = (code + delta) & 0xFFFF
                    } else {
                        let address = rangeOffsets + seg * 2 + rangeOffset + (code - start) * 2
                        guard address + 2 <= b.count else { continue }
                        glyph = Int(Self.u16(b, address))
                        if glyph != 0 { glyph = (glyph + delta) & 0xFFFF }
                    }
                    if glyph != 0 { map[UInt32(code)] = glyph }
                }
            }
        case 6:
            let first = Int(Self.u16(b, offset + 6)), count = Int(Self.u16(b, offset + 8))
            for i in 0..<count where offset + 10 + i * 2 + 2 <= b.count {
                let glyph = Int(Self.u16(b, offset + 10 + i * 2))
                if glyph != 0 { map[UInt32(first + i)] = glyph }
            }
        case 12:
            let groups = Int(Self.u32(b, offset + 12))
            for g in 0..<min(groups, 100_000) {
                let p = offset + 16 + g * 12
                guard p + 12 <= b.count else { break }
                let start = Self.u32(b, p), end = Self.u32(b, p + 4), glyph = Int(Self.u32(b, p + 8))
                guard end >= start, end - start < 65536 else { continue }
                for (i, code) in (start...end).enumerated() { map[code] = glyph + i }
            }
        default:
            break
        }
        return map
    }

    // MARK: Bytes

    static func u16(_ b: [UInt8], _ i: Int) -> UInt16 { i + 1 < b.count ? UInt16(b[i]) << 8 | UInt16(b[i + 1]) : 0 }
    static func u32(_ b: [UInt8], _ i: Int) -> UInt32 {
        i + 3 < b.count ? UInt32(b[i]) << 24 | UInt32(b[i + 1]) << 16 | UInt32(b[i + 2]) << 8 | UInt32(b[i + 3]) : 0
    }
    static func append(_ data: inout Data, u32 value: UInt32) {
        data.append(contentsOf: [UInt8(value >> 24), UInt8((value >> 16) & 0xFF), UInt8((value >> 8) & 0xFF), UInt8(value & 0xFF)])
    }
    static func append(_ data: inout Data, u16 value: UInt16) { data.append(contentsOf: [UInt8(value >> 8), UInt8(value & 0xFF)]) }
}

/// Writes an sfnt file from tables (sorted by tag, 4-byte aligned, checksums and head.checkSumAdjustment set).
enum OpenTypeAssembler {
    static func assemble(_ tables: [String: Data], version: UInt32) -> Data {
        let names = tables.keys.sorted()
        let count = names.count
        var entrySelector = 0
        while (1 << (entrySelector + 1)) <= count { entrySelector += 1 }
        let searchRange = (1 << entrySelector) * 16
        var out = Data()
        TrueTypeFont.append(&out, u32: version)
        TrueTypeFont.append(&out, u16: UInt16(count))
        TrueTypeFont.append(&out, u16: UInt16(searchRange))
        TrueTypeFont.append(&out, u16: UInt16(entrySelector))
        TrueTypeFont.append(&out, u16: UInt16(count * 16 - searchRange))
        var offset = 12 + count * 16
        var body = Data()
        var headOffset: Int?
        for name in names {
            var table = tables[name]!
            if name == "head" {
                headOffset = offset + body.count
                table.withUnsafeMutableBytes { (raw: UnsafeMutableRawBufferPointer) in if raw.count >= 12 { for i in 8..<12 { raw[i] = 0 } } }
            }
            out.append(contentsOf: Array(name.utf8.prefix(4)) + Array(repeating: UInt8(0x20), count: max(0, 4 - name.utf8.count)))
            TrueTypeFont.append(&out, u32: checksum(table))
            TrueTypeFont.append(&out, u32: UInt32(offset + body.count))
            TrueTypeFont.append(&out, u32: UInt32(table.count))
            body.append(table)
            while body.count % 4 != 0 { body.append(0) }
        }
        offset = 0
        var file = out + body
        if let headOffset {
            let adjustment = 0xB1B0AFBA &- checksum(file)
            file.withUnsafeMutableBytes { (raw: UnsafeMutableRawBufferPointer) in
                raw[headOffset + 8] = UInt8(adjustment >> 24); raw[headOffset + 9] = UInt8((adjustment >> 16) & 0xFF)
                raw[headOffset + 10] = UInt8((adjustment >> 8) & 0xFF); raw[headOffset + 11] = UInt8(adjustment & 0xFF)
            }
        }
        return file
    }

    static func checksum(_ data: Data) -> UInt32 {
        var sum: UInt32 = 0
        let b = [UInt8](data)
        var i = 0
        while i < b.count {
            let word = UInt32(b[i]) << 24 | UInt32(i + 1 < b.count ? b[i + 1] : 0) << 16 | UInt32(i + 2 < b.count ? b[i + 2] : 0) << 8
                | UInt32(i + 3 < b.count ? b[i + 3] : 0)
            sum = sum &+ word
            i += 4
        }
        return sum
    }
}

extension TrueTypeFont {
    /// The tables of a Core Text font, read with `CTFontCopyTable` (a collection member gives its own tables).
    static func tables(of font: CTFont) -> [String: Data] {
        guard let array = CTFontCopyAvailableTables(font, []) else { return [:] }
        // The array holds the tags themselves (not CFNumbers), so they are read as pointer-sized values.
        let tags = (0..<CFArrayGetCount(array)).map { UInt32(truncatingIfNeeded: UInt(bitPattern: CFArrayGetValueAtIndex(array, $0))) }
        var tables: [String: Data] = [:]
        for tag in tags {
            let name = String(bytes: [UInt8(tag >> 24), UInt8((tag >> 16) & 0xFF), UInt8((tag >> 8) & 0xFF), UInt8(tag & 0xFF)], encoding: .isoLatin1) ?? ""
            if let data = CTFontCopyTable(font, CTFontTableTag(tag), []) as Data? { tables[name] = data }
        }
        return tables
    }
}
