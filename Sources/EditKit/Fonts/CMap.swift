import Foundation
import PDFModelKit

// CMaps (ISO 32000-2 §9.7.5, §9.10.3): the ToUnicode map (codes → text) and embedded CID CMaps (codes → CIDs), read
// from their PostScript-like syntax with PDFModelKit's content tokenizer. Only Identity-H/V and embedded streams are
// understood; the predefined CJK CMaps are not shipped (their text is then read through ToUnicode only).

struct CMap {
    struct CodespaceRange {
        var byteCount: Int
        var low: UInt32
        var high: UInt32
    }

    var codespaces: [CodespaceRange] = []
    /// Single codes → their value (a CID, or the UTF-16 units of the text for ToUnicode).
    var single: [UInt32: [UInt16]] = [:]
    /// Ranges: (low, high, byte count) → the value of `low`; later codes add their offset to the last unit.
    var ranges: [(low: UInt32, high: UInt32, byteCount: Int, value: [UInt16])] = []
    var isVertical = false

    /// Two-byte identity.
    static let identity: CMap = {
        var map = CMap()
        map.codespaces = [CodespaceRange(byteCount: 2, low: 0, high: 0xFFFF)]
        map.isIdentity = true
        return map
    }()

    private(set) var isIdentity = false

    init() {}

    init(parsing data: Data) {
        let stream = PDFContentStream(parsing: data)
        for op in stream.operations {
            switch op.operator {
            case "endcodespacerange":
                let items = op.operands.compactMap(\.stringValue)
                var i = 0
                while i + 1 < items.count {
                    codespaces.append(CodespaceRange(byteCount: max(1, min(4, items[i].count)), low: Self.code(items[i]), high: Self.code(items[i + 1])))
                    i += 2
                }
            case "endbfchar", "endcidchar":
                let items = op.operands
                var i = 0
                while i + 1 < items.count {
                    if let src = items[i].stringValue { single[Self.code(src)] = Self.units(items[i + 1]); noteCodeLength(src.count) }
                    i += 2
                }
            case "endbfrange", "endcidrange":
                let items = op.operands
                var i = 0
                while i + 2 < items.count {
                    guard let lo = items[i].stringValue, let hi = items[i + 1].stringValue else { i += 3; continue }
                    noteCodeLength(lo.count)
                    if let array = items[i + 2].arrayValue {
                        for (offset, item) in array.enumerated() { single[Self.code(lo) + UInt32(offset)] = Self.units(item) }
                    } else {
                        ranges.append((Self.code(lo), Self.code(hi), max(1, min(4, lo.count)), Self.units(items[i + 2])))
                    }
                    i += 3
                }
            case "def":
                if op.operands.count >= 2, op.operands[op.operands.count - 2] == .name("WMode"), op.operands.last?.intValue == 1 { isVertical = true }
            default:
                break
            }
        }
        if codespaces.isEmpty { codespaces = [CodespaceRange(byteCount: inferredByteCount ?? 2, low: 0, high: inferredByteCount == 1 ? 0xFF : 0xFFFF)] }
    }

    private var inferredByteCount: Int?
    private mutating func noteCodeLength(_ count: Int) { if inferredByteCount == nil, (1...4).contains(count) { inferredByteCount = count } }

    private static func code(_ bytes: Data) -> UInt32 {
        var value: UInt32 = 0
        for b in bytes.prefix(4) { value = value << 8 | UInt32(b) }
        return value
    }

    /// A destination as UTF-16 code units (a string's big-endian bytes) or a number (a CID).
    private static func units(_ value: PDFValue) -> [UInt16] {
        switch value {
        case .string(let data):
            var units: [UInt16] = []
            var i = 0
            let b = [UInt8](data)
            while i + 1 < b.count { units.append(UInt16(b[i]) << 8 | UInt16(b[i + 1])); i += 2 }
            if b.count == 1 { units.append(UInt16(b[0])) }
            return units
        case .integer(let n): return [UInt16(truncatingIfNeeded: n)]
        case .real(let n): return [UInt16(truncatingIfNeeded: Int(n))]
        case .name(let n): return GlyphNames.scalar(for: n).map { Array(String($0).utf16) } ?? []
        default: return []
        }
    }

    /// Splits string bytes into codes by the codespace ranges (the shortest range that matches, else one byte).
    func codes(in bytes: Data) -> [(code: UInt32, byteCount: Int)] {
        if isIdentity || codespaces.allSatisfy({ $0.byteCount == 2 }) && codespaces.count == 1 && codespaces[0].low == 0 && codespaces[0].high == 0xFFFF {
            var out: [(UInt32, Int)] = []
            let b = [UInt8](bytes)
            var i = 0
            while i < b.count {
                let code = i + 1 < b.count ? UInt32(b[i]) << 8 | UInt32(b[i + 1]) : UInt32(b[i]) << 8
                out.append((code, 2))
                i += 2
            }
            return out
        }
        var out: [(UInt32, Int)] = []
        let b = [UInt8](bytes)
        var i = 0
        let lengths = Set(codespaces.map(\.byteCount)).sorted()
        while i < b.count {
            var matched = false
            for length in lengths where i + length <= b.count {
                var code: UInt32 = 0
                for j in 0..<length { code = code << 8 | UInt32(b[i + j]) }
                if codespaces.contains(where: { $0.byteCount == length && $0.low <= code && code <= $0.high }) {
                    out.append((code, length)); i += length; matched = true; break
                }
            }
            if !matched {
                // Partial match rule: use the shortest codespace length.
                let length = min(lengths.first ?? 1, b.count - i)
                var code: UInt32 = 0
                for j in 0..<length { code = code << 8 | UInt32(b[i + j]) }
                out.append((code, length)); i += length
            }
        }
        return out
    }

    /// The mapping of a code: UTF-16 units (ToUnicode) or a one-unit CID.
    func lookup(_ code: UInt32) -> [UInt16]? {
        if isIdentity { return [UInt16(truncatingIfNeeded: code)] }
        if let hit = single[code] { return hit }
        for range in ranges where range.low <= code && code <= range.high {
            var value = range.value
            if let last = value.last { value[value.count - 1] = last &+ UInt16(truncatingIfNeeded: code - range.low) }
            return value
        }
        return nil
    }

    /// The text a code maps to, for ToUnicode maps.
    func text(_ code: UInt32) -> String? {
        guard let units = lookup(code), !units.isEmpty else { return nil }
        return String(decoding: units, as: UTF16.self)
    }

    /// The CID a code maps to, for CID CMaps (0 = notdef when unmapped).
    func cid(_ code: UInt32) -> Int { Int(lookup(code)?.first ?? 0) }

    /// Every single-code mapping to text, for building a reverse map (ranges expanded up to a bound).
    func allTextMappings(limit: Int = 65_536) -> [(code: UInt32, text: String)] {
        var out: [(UInt32, String)] = single.compactMap { code, units in units.isEmpty ? nil : (code, String(decoding: units, as: UTF16.self)) }
        for range in ranges where range.high >= range.low && range.high - range.low < 4096 {
            for code in range.low...range.high {
                if let text = text(code) { out.append((code, text)) }
                if out.count > limit { return out }
            }
        }
        return out
    }

    /// The bytes of a code in the first codespace of its length.
    func bytes(for code: UInt32, byteCount: Int) -> Data {
        var out = Data()
        for i in stride(from: byteCount - 1, through: 0, by: -1) { out.append(UInt8((code >> (8 * UInt32(i))) & 0xFF)) }
        return out
    }
}

/// Writes a ToUnicode CMap for codes of `byteCount` bytes.
enum ToUnicodeWriter {
    static func cmap(_ mappings: [(code: UInt32, text: String)], byteCount: Int) -> Data {
        var out = """
        /CIDInit /ProcSet findresource begin
        12 dict begin
        begincmap
        /CIDSystemInfo << /Registry (Adobe) /Ordering (UCS) /Supplement 0 >> def
        /CMapName /Adobe-Identity-UCS def
        /CMapType 2 def
        1 begincodespacerange
        <\(String(repeating: "00", count: byteCount))> <\(String(repeating: "FF", count: byteCount))>
        endcodespacerange

        """
        let sorted = mappings.sorted { $0.code < $1.code }
        for chunk in stride(from: 0, to: sorted.count, by: 100).map({ Array(sorted[$0..<min($0 + 100, sorted.count)]) }) {
            out += "\(chunk.count) beginbfchar\n"
            for (code, text) in chunk {
                let hex = String(format: "%0\(byteCount * 2)X", code)
                let units = text.utf16.map { String(format: "%04X", $0) }.joined()
                out += "<\(hex)> <\(units.isEmpty ? "0000" : units)>\n"
            }
            out += "endbfchar\n"
        }
        out += "endcmap\nCMapName currentdict /CMap defineresource pop\nend\nend\n"
        return Data(out.utf8)
    }
}
