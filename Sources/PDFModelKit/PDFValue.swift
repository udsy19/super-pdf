import CoreGraphics
import Foundation

// PDF values as Swift data (ISO 32000-2 §7.3): what callers build objects from, what content streams hold and what the
// incremental writer serialises. Names are stored without the leading slash ("Page", not "/Page"); strings are bytes
// (`.text(_:)` and `textValue` convert PDF text strings).

/// A PDF object as a value. Streams are not values: they live in a `PDFModel` (`PDFObject`).
public indirect enum PDFValue: Hashable, Sendable {
    case null
    case bool(Bool)
    case integer(Int)
    case real(Double)
    /// Without the leading slash.
    case name(String)
    /// The string's bytes.
    case string(Data)
    case array([PDFValue])
    case dictionary([String: PDFValue])
    /// An indirect reference: object number and generation.
    case reference(Int, Int)

    /// A PDF text string: PDFDocEncoding when the text is plain ASCII, else UTF-16BE with a byte-order mark.
    public static func text(_ string: String) -> PDFValue { .string(PDFText.encode(string)) }

    /// A byte string from ASCII/Latin-1 text (keys, dates, identifiers).
    public static func ascii(_ string: String) -> PDFValue { .string(Data(string.utf8)) }

    /// An integer when the number is whole, else a real.
    public static func number(_ value: Double) -> PDFValue {
        value.rounded() == value && abs(value) < 1e15 ? .integer(Int(value)) : .real(value)
    }

    public static func number(_ value: CGFloat) -> PDFValue { .number(Double(value)) }

    /// `[x0 y0 x1 y1]`.
    public static func rect(_ rect: CGRect) -> PDFValue {
        let r = rect.standardized
        return .array([.number(r.minX), .number(r.minY), .number(r.maxX), .number(r.maxY)])
    }

    /// `[a b c d e f]`.
    public static func matrix(_ t: CGAffineTransform) -> PDFValue {
        .array([.number(t.a), .number(t.b), .number(t.c), .number(t.d), .number(t.tx), .number(t.ty)])
    }

    public var isNull: Bool { if case .null = self { true } else { false } }

    public var boolValue: Bool? { if case .bool(let v) = self { v } else { nil } }

    public var intValue: Int? {
        switch self {
        case .integer(let v): v
        case .real(let v) where v.rounded() == v && abs(v) < 1e15: Int(v)
        default: nil
        }
    }

    public var numberValue: Double? {
        switch self {
        case .integer(let v): Double(v)
        case .real(let v): v
        default: nil
        }
    }

    public var nameValue: String? { if case .name(let v) = self { v } else { nil } }
    public var stringValue: Data? { if case .string(let v) = self { v } else { nil } }
    /// The string decoded as a PDF text string.
    public var textValue: String? { stringValue.map(PDFText.decode) }
    public var arrayValue: [PDFValue]? { if case .array(let v) = self { v } else { nil } }
    public var dictionaryValue: [String: PDFValue]? { if case .dictionary(let v) = self { v } else { nil } }

    public var referenceValue: (id: Int, generation: Int)? {
        if case .reference(let id, let gen) = self { (id, gen) } else { nil }
    }

    /// A dictionary entry (nil for other values and missing keys).
    public subscript(key: String) -> PDFValue? { dictionaryValue?[key] }

    /// `[x0 y0 x1 y1]` as a standardised rectangle.
    public var rectValue: CGRect? {
        guard let numbers = arrayValue?.compactMap(\.numberValue), numbers.count == 4 else { return nil }
        return CGRect(x: numbers[0], y: numbers[1], width: numbers[2] - numbers[0], height: numbers[3] - numbers[1]).standardized
    }

    /// `[a b c d e f]`.
    public var matrixValue: CGAffineTransform? {
        guard let n = arrayValue?.compactMap(\.numberValue), n.count == 6 else { return nil }
        return CGAffineTransform(a: n[0], b: n[1], c: n[2], d: n[3], tx: n[4], ty: n[5])
    }

    // MARK: Serialisation

    /// PDF syntax for this value. Dictionary keys are written in sorted order so equal values serialise equally.
    public func serialized() -> Data {
        var out = Data()
        write(into: &out)
        return out
    }

    public func write(into out: inout Data) {
        switch self {
        case .null: out.append(contentsOf: Array("null".utf8))
        case .bool(let v): out.append(contentsOf: Array((v ? "true" : "false").utf8))
        case .integer(let v): out.append(contentsOf: Array(String(v).utf8))
        case .real(let v): out.append(contentsOf: Array(PDFSyntax.format(v).utf8))
        case .name(let v): PDFSyntax.writeName(v, into: &out)
        case .string(let v): PDFSyntax.writeString(v, into: &out)
        case .array(let items):
            out.append(UInt8(ascii: "["))
            for (i, item) in items.enumerated() {
                if i > 0 { out.append(UInt8(ascii: " ")) }
                item.write(into: &out)
            }
            out.append(UInt8(ascii: "]"))
        case .dictionary(let dict):
            out.append(contentsOf: Array("<<".utf8))
            for key in dict.keys.sorted() {
                PDFSyntax.writeName(key, into: &out)
                out.append(UInt8(ascii: " "))
                dict[key]!.write(into: &out)
                out.append(UInt8(ascii: " "))
            }
            out.append(contentsOf: Array(">>".utf8))
        case .reference(let id, let gen): out.append(contentsOf: Array("\(id) \(gen) R".utf8))
        }
    }
}

/// Low-level PDF syntax helpers shared by the serialisers.
enum PDFSyntax {
    static func isWhitespace(_ b: UInt8) -> Bool { b == 0 || b == 9 || b == 10 || b == 12 || b == 13 || b == 32 }

    static func isDelimiter(_ b: UInt8) -> Bool {
        switch b {
        case UInt8(ascii: "("), UInt8(ascii: ")"), UInt8(ascii: "<"), UInt8(ascii: ">"), UInt8(ascii: "["),
             UInt8(ascii: "]"), UInt8(ascii: "{"), UInt8(ascii: "}"), UInt8(ascii: "/"), UInt8(ascii: "%"): true
        default: false
        }
    }

    /// A real without an exponent, at most six decimals, trailing zeros dropped.
    static func format(_ value: Double) -> String {
        guard value.isFinite else { return "0" }
        if value.rounded() == value && abs(value) < 1e15 { return String(Int(value)) }
        var text = String(format: "%.6f", value)
        while text.hasSuffix("0") { text.removeLast() }
        if text.hasSuffix(".") { text.removeLast() }
        return text == "-0" ? "0" : text
    }

    static func writeName(_ name: String, into out: inout Data) {
        out.append(UInt8(ascii: "/"))
        let hex = Array("0123456789ABCDEF".utf8)
        for b in name.utf8 {
            if b > 0x20 && b < 0x7F && b != UInt8(ascii: "#") && !isDelimiter(b) {
                out.append(b)
            } else {
                out.append(UInt8(ascii: "#")); out.append(hex[Int(b >> 4)]); out.append(hex[Int(b & 0xF)])
            }
        }
    }

    /// A literal string when the bytes are printable text, else a hex string.
    static func writeString(_ bytes: Data, into out: inout Data) {
        let printable = bytes.allSatisfy { ($0 >= 0x20 && $0 < 0x7F) || $0 == 9 || $0 == 10 || $0 == 13 }
        guard printable else { writeHexString(bytes, into: &out); return }
        out.append(UInt8(ascii: "("))
        for b in bytes {
            switch b {
            case UInt8(ascii: "("), UInt8(ascii: ")"), UInt8(ascii: "\\"): out.append(UInt8(ascii: "\\")); out.append(b)
            case 10: out.append(contentsOf: Array("\\n".utf8))
            case 13: out.append(contentsOf: Array("\\r".utf8))
            case 9: out.append(contentsOf: Array("\\t".utf8))
            default: out.append(b)
            }
        }
        out.append(UInt8(ascii: ")"))
    }

    static func writeHexString(_ bytes: Data, into out: inout Data) {
        let hex = Array("0123456789abcdef".utf8)
        out.append(UInt8(ascii: "<"))
        for b in bytes { out.append(hex[Int(b >> 4)]); out.append(hex[Int(b & 0xF)]) }
        out.append(UInt8(ascii: ">"))
    }
}

/// PDF text strings (ISO 32000-2 §7.9.2.2): PDFDocEncoding, UTF-16BE or UTF-8, each with its marker.
public enum PDFText {
    /// PDFDocEncoding for plain ASCII text, else UTF-16BE with a byte-order mark.
    public static func encode(_ string: String) -> Data {
        if string.unicodeScalars.allSatisfy({ $0.value < 0x7F && ($0.value >= 0x20 || $0 == "\n" || $0 == "\r" || $0 == "\t") }) {
            return Data(string.utf8)
        }
        var out = Data([0xFE, 0xFF])
        for unit in string.utf16 { out.append(UInt8(unit >> 8)); out.append(UInt8(unit & 0xFF)) }
        return out
    }

    public static func decode(_ bytes: Data) -> String {
        let b = [UInt8](bytes)
        if b.count >= 2, b[0] == 0xFE, b[1] == 0xFF {
            var units: [UInt16] = []
            var i = 2
            while i + 1 < b.count { units.append(UInt16(b[i]) << 8 | UInt16(b[i + 1])); i += 2 }
            return String(decoding: units, as: UTF16.self)
        }
        if b.count >= 3, b[0] == 0xEF, b[1] == 0xBB, b[2] == 0xBF {
            return String(decoding: b[3...], as: UTF8.self)
        }
        var scalars = String.UnicodeScalarView()
        for byte in b {
            if let mapped = pdfDocEncoding[byte] { scalars.append(mapped) } else { scalars.append(Unicode.Scalar(byte)) }
        }
        return String(scalars)
    }

    /// The PDFDocEncoding code points that differ from Latin-1 (ISO 32000-2 Annex D.2).
    private static let pdfDocEncoding: [UInt8: Unicode.Scalar] = {
        let table: [(UInt8, UInt32)] = [
            (0x18, 0x02D8), (0x19, 0x02C7), (0x1A, 0x02C6), (0x1B, 0x02D9), (0x1C, 0x02DD), (0x1D, 0x02DB), (0x1E, 0x02DA),
            (0x1F, 0x02DC), (0x80, 0x2022), (0x81, 0x2020), (0x82, 0x2021), (0x83, 0x2026), (0x84, 0x2014), (0x85, 0x2013),
            (0x86, 0x0192), (0x87, 0x2044), (0x88, 0x2039), (0x89, 0x203A), (0x8A, 0x2212), (0x8B, 0x2030), (0x8C, 0x201E),
            (0x8D, 0x201C), (0x8E, 0x201D), (0x8F, 0x2018), (0x90, 0x2019), (0x91, 0x201A), (0x92, 0x2122), (0x93, 0xFB01),
            (0x94, 0xFB02), (0x95, 0x0141), (0x96, 0x0152), (0x97, 0x0160), (0x98, 0x0178), (0x99, 0x017D), (0x9A, 0x0131),
            (0x9B, 0x0142), (0x9C, 0x0153), (0x9D, 0x0161), (0x9E, 0x017E), (0xA0, 0x20AC),
        ]
        var map: [UInt8: Unicode.Scalar] = [:]
        for (byte, code) in table { map[byte] = Unicode.Scalar(code)! }
        return map
    }()
}

/// PDF dates (ISO 32000-2 §7.9.4): `D:YYYYMMDDHHmmSSOHH'mm'`.
public enum PDFDate {
    public static func string(_ date: Date, timeZone: TimeZone = .current) -> String {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = timeZone
        let c = calendar.dateComponents([.year, .month, .day, .hour, .minute, .second], from: date)
        let offset = timeZone.secondsFromGMT(for: date) / 60
        let zone = offset == 0 ? "Z" : String(format: "%@%02d'%02d'", offset < 0 ? "-" : "+", abs(offset) / 60, abs(offset) % 60)
        return String(format: "D:%04d%02d%02d%02d%02d%02d", c.year!, c.month!, c.day!, c.hour!, c.minute!, c.second!) + zone
    }

    /// Parses the full form and its allowed truncations; nil when the text is not a PDF date.
    public static func date(_ text: String) -> Date? {
        var s = Substring(text.trimmingCharacters(in: .whitespaces))
        if s.hasPrefix("D:") { s = s.dropFirst(2) }
        let digits = s.prefix(while: \.isNumber)
        guard digits.count >= 4, let year = Int(digits.prefix(4)) else { return nil }
        func field(_ offset: Int, _ fallback: Int) -> Int {
            let start = digits.index(digits.startIndex, offsetBy: offset, limitedBy: digits.endIndex) ?? digits.endIndex
            let end = digits.index(start, offsetBy: 2, limitedBy: digits.endIndex) ?? digits.endIndex
            return digits.distance(from: start, to: end) == 2 ? Int(digits[start..<end]) ?? fallback : fallback
        }
        var c = DateComponents(year: year, month: field(4, 1), day: field(6, 1), hour: field(8, 0), minute: field(10, 0), second: field(12, 0))
        var rest = s.dropFirst(digits.count)
        var seconds = 0
        if let sign = rest.first, sign == "+" || sign == "-" {
            rest = rest.dropFirst()
            let numbers = rest.split(whereSeparator: { !$0.isNumber }).compactMap { Int($0) }
            seconds = ((numbers.first ?? 0) * 60 + (numbers.dropFirst().first ?? 0)) * 60 * (sign == "-" ? -1 : 1)
        }
        c.timeZone = TimeZone(secondsFromGMT: seconds)
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = c.timeZone!
        return calendar.date(from: c)
    }
}
