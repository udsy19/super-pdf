import CoreText
import Foundation
import PDFModelKit

// What the content rewriter needs to know about a font to place each glyph (ISO 32000-2 §9.2.4, §9.4.4, §9.6–§9.7):
// how a string's bytes split into character codes, each code's advance, and how tall the glyphs stand. Positions come
// from the file's own metrics (/Widths, /W, /FontMatrix, the descriptor); the standard 14 fonts without /Widths take
// their advances from the Mac's copies of the same faces.

/// One character code of a shown string.
struct GlyphCode {
    /// The code's bytes in the string.
    var bytes: Data
    var code: UInt32
    /// A one-byte code 32: word spacing (Tw) applies to it.
    var isSingleByteSpace: Bool
}

final class FontMetrics {
    /// Advance in text space units per unit of font size (glyph width / 1000 for most fonts).
    private let widths: [UInt32: Double]
    private let defaultWidth: Double
    /// Glyph extent above and below the baseline, per unit of font size.
    let ascent: Double
    let descent: Double
    /// Code space: byte lengths a code can have, with the ranges of each length (empty = one byte per code).
    private let codeSpace: [(length: Int, ranges: [ClosedRange<UInt32>])]
    /// Lead bytes of two-byte codes when the code space is only known by its predefined CMap's family.
    private let twoByteLeads: ClosedRange<UInt8>?
    private let isComposite: Bool
    /// Composite fonts with a non-identity CMap: code → CID where the embedded CMap says.
    private let cidOfCode: [UInt32: UInt32]

    init(_ font: PDFObject?) {
        guard let font, font.type == .dictionary else {
            widths = [:]; defaultWidth = 0.5; ascent = 0.75; descent = -0.25; codeSpace = []; twoByteLeads = nil
            isComposite = false; cidOfCode = [:]
            return
        }
        let subtype = font["Subtype"]?.name ?? "Type1"
        if subtype == "Type0" {
            isComposite = true
            let descendant = font["DescendantFonts"]?[0]
            let descriptor = descendant?["FontDescriptor"]
            (ascent, descent) = Self.verticalExtent(descriptor)
            defaultWidth = (descendant?["DW"]?.number ?? 1000) / 1000
            widths = Self.cidWidths(descendant?["W"])
            var cids: [UInt32: UInt32] = [:]
            if let encoding = font["Encoding"], encoding.type == .stream, let data = try? encoding.streamData() {
                let cmap = CMapText(data)
                codeSpace = cmap.codeSpace
                cids = cmap.cids
                twoByteLeads = nil
            } else {
                let name = font["Encoding"]?.name ?? "Identity-H"
                if name.hasPrefix("Identity") || name.contains("UCS2") || name.contains("UTF16") {
                    codeSpace = [(2, [0...0xFFFF])]
                    twoByteLeads = nil
                } else {
                    // Mixed one- and two-byte CJK encodings (RKSJ, EUC, GBK, B5…): high bytes lead two-byte codes.
                    codeSpace = []
                    twoByteLeads = 0x80...0xFF
                }
            }
            cidOfCode = cids
            return
        }
        isComposite = false
        codeSpace = []
        twoByteLeads = nil
        cidOfCode = [:]
        if subtype == "Type3" {
            let matrix = font["FontMatrix"]?.value.matrixValue ?? CGAffineTransform(a: 0.001, b: 0, c: 0, d: 0.001, tx: 0, ty: 0)
            let first = font["FirstChar"]?.int ?? 0
            var table: [UInt32: Double] = [:]
            for (i, w) in (font["Widths"]?.items ?? []).enumerated() {
                table[UInt32(max(first + i, 0))] = (w.number ?? 0) * Double(matrix.a)
            }
            widths = table
            defaultWidth = 0
            if let bbox = font["FontBBox"]?.rect, !bbox.isEmpty {
                let box = bbox.applying(matrix)
                ascent = max(Double(box.maxY), 0.5); descent = min(Double(box.minY), 0)
            } else {
                ascent = 0.75; descent = -0.25
            }
            return
        }
        let descriptor = font["FontDescriptor"]
        (ascent, descent) = Self.verticalExtent(descriptor)
        if let list = font["Widths"]?.items, !list.isEmpty {
            let first = font["FirstChar"]?.int ?? 0
            var table: [UInt32: Double] = [:]
            for (i, w) in list.enumerated() { table[UInt32(max(first + i, 0))] = (w.number ?? 0) / 1000 }
            widths = table
            defaultWidth = (descriptor?["MissingWidth"]?.number ?? 0) / 1000
        } else {
            let base = font["BaseFont"]?.name ?? "Helvetica"
            widths = StandardFonts.widths(for: base)
            defaultWidth = StandardFonts.isMonospaced(base) ? 0.6 : 0.5
        }
    }

    /// The codes of a shown string, in order.
    func codes(_ string: Data) -> [GlyphCode] {
        let bytes = [UInt8](string)
        var result: [GlyphCode] = []
        var i = 0
        while i < bytes.count {
            let length = codeLength(bytes, at: i)
            let slice = bytes[i..<min(i + length, bytes.count)]
            let code = slice.reduce(UInt32(0)) { ($0 << 8) | UInt32($1) }
            result.append(GlyphCode(bytes: Data(slice), code: code, isSingleByteSpace: slice.count == 1 && code == 32))
            i += length
        }
        return result
    }

    /// The code's advance per unit of font size (horizontal writing).
    func width(of code: UInt32) -> Double {
        let key = isComposite ? (cidOfCode[code] ?? code) : code
        return widths[key] ?? defaultWidth
    }

    private func codeLength(_ bytes: [UInt8], at i: Int) -> Int {
        if !codeSpace.isEmpty {
            for (length, ranges) in codeSpace.sorted(by: { $0.length < $1.length }) where i + length <= bytes.count {
                let value = bytes[i..<(i + length)].reduce(UInt32(0)) { ($0 << 8) | UInt32($1) }
                if ranges.contains(where: { $0.contains(value) }) { return length }
            }
            return codeSpace.map(\.length).min() ?? 1
        }
        if let leads = twoByteLeads, leads.contains(bytes[i]), i + 1 < bytes.count { return 2 }
        return 1
    }

    private static func verticalExtent(_ descriptor: PDFObject?) -> (Double, Double) {
        var ascent = (descriptor?["Ascent"]?.number ?? 0) / 1000
        var descent = (descriptor?["Descent"]?.number ?? 0) / 1000
        if ascent <= 0.2 { ascent = 0.75 }
        if descent >= 0 || descent < -0.6 { descent = -0.25 }
        return (ascent, descent)
    }

    /// A descendant font's /W: `c [w1 w2 …]` and `cFirst cLast w` entries.
    private static func cidWidths(_ w: PDFObject?) -> [UInt32: Double] {
        guard let items = w?.value.arrayValue else { return [:] }
        var table: [UInt32: Double] = [:]
        var i = 0
        while i < items.count {
            guard let first = items[i].intValue else { i += 1; continue }
            if i + 1 < items.count, let list = items[i + 1].arrayValue {
                for (k, value) in list.enumerated() { table[UInt32(max(first + k, 0))] = (value.numberValue ?? 0) / 1000 }
                i += 2
            } else if i + 2 < items.count, let last = items[i + 1].intValue, let width = items[i + 2].numberValue {
                if last >= first, last - first < 70_000 {
                    for cid in first...last { table[UInt32(max(cid, 0))] = width / 1000 }
                }
                i += 3
            } else {
                break
            }
        }
        return table
    }
}

/// The parts of an embedded CMap the rewriter needs: code space ranges and code → CID mappings.
private struct CMapText {
    var codeSpace: [(length: Int, ranges: [ClosedRange<UInt32>])] = []
    var cids: [UInt32: UInt32] = [:]

    init(_ data: Data) {
        let tokens = PDFContentStream(parsing: data).operations
        var byLength: [Int: [ClosedRange<UInt32>]] = [:]
        for op in tokens {
            switch op.operator {
            case "endcodespacerange":
                var k = 0
                while k + 1 < op.operands.count {
                    if let low = op.operands[k].stringValue, let high = op.operands[k + 1].stringValue, low.count == high.count {
                        let lo = Self.number(low), hi = Self.number(high)
                        if lo <= hi { byLength[low.count, default: []].append(lo...hi) }
                    }
                    k += 2
                }
            case "endcidrange":
                var k = 0
                while k + 2 < op.operands.count {
                    if let low = op.operands[k].stringValue, let high = op.operands[k + 1].stringValue, let cid = op.operands[k + 2].intValue {
                        let lo = Self.number(low), hi = Self.number(high)
                        if lo <= hi, hi - lo < 70_000 { for code in lo...hi { cids[code] = UInt32(cid) + (code - lo) } }
                    }
                    k += 3
                }
            case "endcidchar":
                var k = 0
                while k + 1 < op.operands.count {
                    if let code = op.operands[k].stringValue, let cid = op.operands[k + 1].intValue { cids[Self.number(code)] = UInt32(max(cid, 0)) }
                    k += 2
                }
            default:
                break
            }
        }
        codeSpace = byLength.map { ($0.key, $0.value) }
    }

    private static func number(_ data: Data) -> UInt32 { data.prefix(4).reduce(UInt32(0)) { ($0 << 8) | UInt32($1) } }
}

/// Advances of the standard 14 fonts for files that name them without /Widths, read from the Mac's faces.
enum StandardFonts {
    private static let lock = NSLock()
    nonisolated(unsafe) private static var cache: [String: [UInt32: Double]] = [:]

    static func isMonospaced(_ base: String) -> Bool { base.hasPrefix("Courier") }

    static func widths(for base: String) -> [UInt32: Double] {
        let name = base.split(separator: "+").last.map(String.init) ?? base
        lock.lock(); defer { lock.unlock() }
        if let cached = cache[name] { return cached }
        var table: [UInt32: Double] = [:]
        if isMonospaced(name) {
            for code in UInt32(0)...255 { table[code] = 0.6 }
        } else {
            let font = CTFontCreateWithName(postScriptName(name) as CFString, 1000, nil)
            for code in UInt32(32)...255 {
                guard let text = String(bytes: [UInt8(code)], encoding: .windowsCP1252), let scalar = text.utf16.first else { continue }
                var character = scalar
                var glyph: CGGlyph = 0
                guard CTFontGetGlyphsForCharacters(font, &character, &glyph, 1), glyph != 0 else { continue }
                var advance = CGSize.zero
                CTFontGetAdvancesForGlyphs(font, .horizontal, &glyph, &advance, 1)
                table[code] = Double(advance.width) / 1000
            }
        }
        cache[name] = table
        return table
    }

    private static func postScriptName(_ name: String) -> String {
        switch name {
        case "Arial", "ArialMT": "Helvetica"
        case "Arial,Bold", "Arial-BoldMT": "Helvetica-Bold"
        case "TimesNewRoman", "TimesNewRomanPSMT": "Times-Roman"
        case "ZapfDingbats": "ZapfDingbatsITC"
        default: name.replacingOccurrences(of: ",", with: "-")
        }
    }
}
