import Foundation

// Content streams (ISO 32000-2 §7.8, §8, §14.6): a tolerant tokenizer that turns content into operations (operands +
// operator, inline images with their data), the serializer back to bytes, and marked-content spans (BMC/BDC … EMC)
// for tagged watermarks, artifacts and structure MCIDs.

/// One content-stream operation: `operands operator`. An inline image is operator "BI" with its dictionary as the only
/// operand and its bytes in `inlineImageData` (written back as `BI … ID data EI`).
public struct PDFContentOperation: Hashable, Sendable {
    public var operands: [PDFValue]
    public var `operator`: String
    public var inlineImageData: Data?

    public init(_ op: String, _ operands: [PDFValue] = [], inlineImageData: Data? = nil) {
        self.operator = op; self.operands = operands; self.inlineImageData = inlineImageData
    }
}

/// A marked-content span: the indices of its opening BMC/BDC and closing EMC operations.
public struct PDFMarkedContent: Hashable, Sendable {
    public var tag: String
    /// BDC's property list: an inline dictionary or the name of a /Properties resource.
    public var properties: PDFValue?
    /// Opening operation index.
    public var start: Int
    /// The matching EMC's index (the last operation when the stream ends unbalanced).
    public var end: Int
    /// Nesting depth (0 = outermost).
    public var depth: Int

    /// /MCID from an inline property dictionary.
    public var mcid: Int? { properties?["MCID"]?.intValue }
    public var range: ClosedRange<Int> { start...end }
}

/// A content stream as operations.
public struct PDFContentStream: Hashable, Sendable {
    public var operations: [PDFContentOperation]

    public init(operations: [PDFContentOperation] = []) { self.operations = operations }

    /// Parses content bytes. Never fails: unknown tokens become operators, stray delimiters are skipped, an
    /// unterminated string or image runs to the end.
    public init(parsing data: Data) {
        var lexer = ContentLexer([UInt8](data))
        operations = lexer.parseOperations()
    }

    /// The content as bytes, one operation per line.
    public func serialized() -> Data {
        var out = Data()
        for op in operations {
            if op.operator == "BI", let dict = op.operands.first?.dictionaryValue {
                out.append(contentsOf: Array("BI".utf8))
                for key in dict.keys.sorted() {
                    out.append(UInt8(ascii: " "))
                    PDFSyntax.writeName(key, into: &out)
                    out.append(UInt8(ascii: " "))
                    dict[key]!.write(into: &out)
                }
                out.append(contentsOf: Array(" ID ".utf8))
                out.append(op.inlineImageData ?? Data())
                out.append(contentsOf: Array("\nEI\n".utf8))
                continue
            }
            for operand in op.operands {
                operand.write(into: &out)
                out.append(UInt8(ascii: " "))
            }
            out.append(contentsOf: Array(op.operator.utf8))
            out.append(UInt8(ascii: "\n"))
        }
        return out
    }

    /// Every marked-content span, outermost first in stream order.
    public var markedContent: [PDFMarkedContent] {
        var spans: [PDFMarkedContent] = []
        var open: [Int] = []   // indices into `spans`
        for (i, op) in operations.enumerated() {
            switch op.operator {
            case "BMC", "BDC":
                let tag = op.operands.first?.nameValue ?? ""
                let properties = op.operator == "BDC" ? op.operands.dropFirst().first : nil
                spans.append(PDFMarkedContent(tag: tag, properties: properties, start: i, end: operations.count - 1, depth: open.count))
                open.append(spans.count - 1)
            case "EMC":
                if let last = open.popLast() { spans[last].end = i }
            default: break
            }
        }
        return spans
    }

    /// Removes every span (with its content) that `shouldRemove` picks; returns how many were removed. A removed span
    /// takes its nested spans with it.
    @discardableResult
    public mutating func removeMarkedContent(where shouldRemove: (PDFMarkedContent) -> Bool) -> Int {
        var removed = IndexSet()
        var count = 0
        for span in markedContent where !removed.contains(span.start) && shouldRemove(span) {
            removed.insert(integersIn: span.start...span.end)
            count += 1
        }
        operations = operations.enumerated().filter { !removed.contains($0.offset) }.map(\.element)
        return count
    }

    /// `operations` inside `tag` (BDC with `properties`, else BMC) … EMC.
    public static func markedContent(_ operations: [PDFContentOperation], tag: String, properties: PDFValue? = nil) -> [PDFContentOperation] {
        let open = properties.map { PDFContentOperation("BDC", [.name(tag), $0]) } ?? PDFContentOperation("BMC", [.name(tag)])
        return [open] + operations + [PDFContentOperation("EMC")]
    }

    /// `operations` inside q … Q.
    public static func isolated(_ operations: [PDFContentOperation]) -> [PDFContentOperation] {
        [PDFContentOperation("q")] + operations + [PDFContentOperation("Q")]
    }
}

// MARK: - Lexer

/// A tolerant tokenizer over content bytes (also parses the values inside them).
struct ContentLexer {
    let bytes: [UInt8]
    var pos = 0

    init(_ bytes: [UInt8]) { self.bytes = bytes }

    private enum Token {
        case value(PDFValue)
        case keyword(String)
        case arrayStart, arrayEnd, dictStart, dictEnd
        case end
    }

    mutating func parseOperations() -> [PDFContentOperation] {
        var ops: [PDFContentOperation] = []
        var operands: [PDFValue] = []
        while true {
            switch nextToken() {
            case .end:
                return ops
            case .value(let v):
                operands.append(v)
            case .arrayStart:
                operands.append(parseArray())
            case .dictStart:
                operands.append(parseDictionary())
            case .arrayEnd, .dictEnd:
                continue
            case .keyword(let word):
                if word == "BI" {
                    ops.append(parseInlineImage())
                } else {
                    ops.append(PDFContentOperation(word, operands))
                }
                operands = []
            }
        }
    }

    private mutating func parseArray() -> PDFValue {
        var items: [PDFValue] = []
        while true {
            switch nextToken() {
            case .end, .arrayEnd: return .array(items)
            case .value(let v): items.append(v)
            case .arrayStart: items.append(parseArray())
            case .dictStart: items.append(parseDictionary())
            case .dictEnd: continue
            case .keyword(let word): items.append(keywordValue(word))
            }
        }
    }

    private mutating func parseDictionary() -> PDFValue {
        var dict: [String: PDFValue] = [:]
        var key: String?
        while true {
            let token = nextToken()
            var value: PDFValue?
            switch token {
            case .end, .dictEnd: return .dictionary(dict)
            case .value(let v): value = v
            case .arrayStart: value = parseArray()
            case .dictStart: value = parseDictionary()
            case .arrayEnd: continue
            case .keyword(let word): value = keywordValue(word)
            }
            guard let value else { continue }
            if let k = key {
                if !value.isNull { dict[k] = value }
                key = nil
            } else if let name = value.nameValue {
                key = name
            }
        }
    }

    /// Keywords inside arrays and dictionaries (content streams have no references).
    private func keywordValue(_ word: String) -> PDFValue { .name(word) }

    /// After "BI": key/value pairs up to "ID", one whitespace byte, the data, then "EI".
    private mutating func parseInlineImage() -> PDFContentOperation {
        var dict: [String: PDFValue] = [:]
        var key: String?
        loop: while true {
            let token = nextToken()
            var value: PDFValue?
            switch token {
            case .end: break loop
            case .keyword("ID"): break loop
            case .keyword(let word): value = .name(word)
            case .value(let v): value = v
            case .arrayStart: value = parseArray()
            case .dictStart: value = parseDictionary()
            case .arrayEnd, .dictEnd: continue
            }
            guard let value else { continue }
            if let k = key { dict[k] = value; key = nil } else if let name = value.nameValue { key = name }
        }
        if pos < bytes.count, PDFSyntax.isWhitespace(bytes[pos]) { pos += 1 }
        let start = pos
        let end = inlineImageEnd(from: start, dictionary: dict)
        let data = Data(bytes[start..<end])
        // Skip the whitespace before EI and EI itself.
        pos = end
        while pos < bytes.count, PDFSyntax.isWhitespace(bytes[pos]) { pos += 1 }
        if pos + 1 < bytes.count, bytes[pos] == UInt8(ascii: "E"), bytes[pos + 1] == UInt8(ascii: "I") { pos += 2 }
        return PDFContentOperation("BI", [.dictionary(dict)], inlineImageData: data)
    }

    /// Where the image data ends: /L (PDF 2.0) or the computed size of unfiltered samples when "EI" follows there,
    /// else the first whitespace + "EI" + delimiter after the start.
    private func inlineImageEnd(from start: Int, dictionary dict: [String: PDFValue]) -> Int {
        func isEIAt(_ i: Int) -> Bool {
            var j = i
            while j < bytes.count, PDFSyntax.isWhitespace(bytes[j]) { j += 1 }
            guard j + 1 < bytes.count, bytes[j] == UInt8(ascii: "E"), bytes[j + 1] == UInt8(ascii: "I") else { return false }
            return j + 2 >= bytes.count || PDFSyntax.isWhitespace(bytes[j + 2]) || PDFSyntax.isDelimiter(bytes[j + 2])
        }
        if let length = (dict["L"] ?? dict["Length"])?.intValue, start + length <= bytes.count, isEIAt(start + length) {
            return start + length
        }
        if (dict["F"] ?? dict["Filter"]) == nil, let size = unfilteredSize(dict), start + size <= bytes.count, isEIAt(start + size) {
            return start + size
        }
        var i = start
        while i + 1 < bytes.count {
            if PDFSyntax.isWhitespace(bytes[i]), bytes[i + 1] == UInt8(ascii: "E"), i + 2 < bytes.count, bytes[i + 2] == UInt8(ascii: "I"),
               i + 3 >= bytes.count || PDFSyntax.isWhitespace(bytes[i + 3]) || PDFSyntax.isDelimiter(bytes[i + 3]) {
                return i
            }
            i += 1
        }
        return bytes.count
    }

    private func unfilteredSize(_ dict: [String: PDFValue]) -> Int? {
        guard let w = (dict["W"] ?? dict["Width"])?.intValue, let h = (dict["H"] ?? dict["Height"])?.intValue else { return nil }
        let isMask = (dict["IM"] ?? dict["ImageMask"])?.boolValue == true
        let bpc = isMask ? 1 : (dict["BPC"] ?? dict["BitsPerComponent"])?.intValue ?? 8
        let components: Int
        if isMask {
            components = 1
        } else {
            switch (dict["CS"] ?? dict["ColorSpace"]) {
            case .name("G"), .name("DeviceGray"), .name("CalGray"): components = 1
            case .name("RGB"), .name("DeviceRGB"), .name("CalRGB"): components = 3
            case .name("CMYK"), .name("DeviceCMYK"): components = 4
            case .array(let a) where a.first == .name("I") || a.first == .name("Indexed"): components = 1
            default: return nil
            }
        }
        return h * ((w * bpc * components + 7) / 8)
    }

    // MARK: Tokens

    private mutating func skipWhitespaceAndComments() {
        while pos < bytes.count {
            let b = bytes[pos]
            if PDFSyntax.isWhitespace(b) {
                pos += 1
            } else if b == UInt8(ascii: "%") {
                while pos < bytes.count, bytes[pos] != 10, bytes[pos] != 13 { pos += 1 }
            } else {
                return
            }
        }
    }

    private mutating func nextToken() -> Token {
        skipWhitespaceAndComments()
        guard pos < bytes.count else { return .end }
        let b = bytes[pos]
        switch b {
        case UInt8(ascii: "["): pos += 1; return .arrayStart
        case UInt8(ascii: "]"): pos += 1; return .arrayEnd
        case UInt8(ascii: "<"):
            if pos + 1 < bytes.count, bytes[pos + 1] == UInt8(ascii: "<") { pos += 2; return .dictStart }
            return .value(readHexString())
        case UInt8(ascii: ">"):
            if pos + 1 < bytes.count, bytes[pos + 1] == UInt8(ascii: ">") { pos += 2; return .dictEnd }
            pos += 1
            return nextToken()
        case UInt8(ascii: "("): return .value(readLiteralString())
        case UInt8(ascii: "/"): return .value(readName())
        case UInt8(ascii: ")"), UInt8(ascii: "{"), UInt8(ascii: "}"):
            pos += 1
            return nextToken()
        default:
            let start = pos
            while pos < bytes.count, !PDFSyntax.isWhitespace(bytes[pos]), !PDFSyntax.isDelimiter(bytes[pos]) { pos += 1 }
            let word = String(decoding: bytes[start..<pos], as: UTF8.self)
            if let number = Self.number(bytes[start..<pos]) { return .value(number) }
            switch word {
            case "true": return .value(.bool(true))
            case "false": return .value(.bool(false))
            case "null": return .value(.null)
            default: return .keyword(word)
            }
        }
    }

    /// An integer or real; nil when the word is not a number.
    static func number(_ word: ArraySlice<UInt8>) -> PDFValue? {
        guard !word.isEmpty else { return nil }
        var digits = 0, dots = 0
        for (i, b) in word.enumerated() {
            if b >= UInt8(ascii: "0") && b <= UInt8(ascii: "9") { digits += 1 }
            else if b == UInt8(ascii: ".") { dots += 1 }
            else if (b == UInt8(ascii: "+") || b == UInt8(ascii: "-")) && i == 0 { continue }
            else { return nil }
        }
        guard digits > 0, dots <= 1 else { return nil }
        let text = String(decoding: word, as: UTF8.self)
        if dots == 0, let int = Int(text) { return .integer(int) }
        return Double(text).map { .real($0) }
    }

    private mutating func readName() -> PDFValue {
        pos += 1
        var out: [UInt8] = []
        while pos < bytes.count, !PDFSyntax.isWhitespace(bytes[pos]), !PDFSyntax.isDelimiter(bytes[pos]) {
            if bytes[pos] == UInt8(ascii: "#"), pos + 2 < bytes.count, let hi = Self.hex(bytes[pos + 1]), let lo = Self.hex(bytes[pos + 2]) {
                out.append(hi << 4 | lo)
                pos += 3
            } else {
                out.append(bytes[pos])
                pos += 1
            }
        }
        return .name(String(decoding: out, as: UTF8.self))
    }

    private mutating func readHexString() -> PDFValue {
        pos += 1
        var out = Data()
        var high: UInt8?
        while pos < bytes.count, bytes[pos] != UInt8(ascii: ">") {
            if let v = Self.hex(bytes[pos]) {
                if let h = high { out.append(h << 4 | v); high = nil } else { high = v }
            }
            pos += 1
        }
        if let h = high { out.append(h << 4) }
        pos = min(pos + 1, bytes.count)
        return .string(out)
    }

    private mutating func readLiteralString() -> PDFValue {
        pos += 1
        var out = Data()
        var depth = 1
        while pos < bytes.count {
            let b = bytes[pos]
            pos += 1
            switch b {
            case UInt8(ascii: "("):
                depth += 1; out.append(b)
            case UInt8(ascii: ")"):
                depth -= 1
                if depth == 0 { return .string(out) }
                out.append(b)
            case UInt8(ascii: "\\"):
                guard pos < bytes.count else { return .string(out) }
                let e = bytes[pos]
                pos += 1
                switch e {
                case UInt8(ascii: "n"): out.append(10)
                case UInt8(ascii: "r"): out.append(13)
                case UInt8(ascii: "t"): out.append(9)
                case UInt8(ascii: "b"): out.append(8)
                case UInt8(ascii: "f"): out.append(12)
                case 13:
                    if pos < bytes.count, bytes[pos] == 10 { pos += 1 }
                case 10: break
                case UInt8(ascii: "0")...UInt8(ascii: "7"):
                    var value = Int(e - UInt8(ascii: "0"))
                    var n = 1
                    while n < 3, pos < bytes.count, bytes[pos] >= UInt8(ascii: "0"), bytes[pos] <= UInt8(ascii: "7") {
                        value = value * 8 + Int(bytes[pos] - UInt8(ascii: "0"))
                        pos += 1; n += 1
                    }
                    out.append(UInt8(value & 0xFF))
                default: out.append(e)
                }
            default:
                out.append(b)
            }
        }
        return .string(out)
    }

    static func hex(_ b: UInt8) -> UInt8? {
        switch b {
        case UInt8(ascii: "0")...UInt8(ascii: "9"): b - UInt8(ascii: "0")
        case UInt8(ascii: "a")...UInt8(ascii: "f"): b - UInt8(ascii: "a") + 10
        case UInt8(ascii: "A")...UInt8(ascii: "F"): b - UInt8(ascii: "A") + 10
        default: nil
        }
    }
}
