import Foundation
import SuperPDFCore

/// Adobe's `AF*` form helpers, emulated natively (features #80; never a JavaScript engine, features #74): number,
/// percent, date, time and special formats with their keystroke checks, range validation, `AFSimple_Calculate` and
/// simplified field notation. A script we don't recognise is `.unsupported` ("This form uses scripts we don’t run.").
///
/// Values that pass through a format are stored formatted (what the page shows is what is saved, so viewers that run
/// no scripts show the same thing); every format parses its own output, so formatting twice changes nothing, and
/// `rawValue(of:format:)` turns a shown value back into the number calculations use.
public struct AFEmulator: AFScriptEmulator {
    public init() {}

    public func run(_ script: String, action: AFAction, value: String, fields: [String: String]) -> AFOutcome {
        if action == .calculate {
            if let expression = AFScript.simplifiedNotation(in: script) ?? AFScript.eventValueExpression(in: script) {
                return SimpleCalc.evaluate(expression.text, names: expression.names, fields: fields).map { .value(Self.plain($0)) } ?? .unsupported
            }
        }
        guard let call = AFScript.firstCall(in: script) else { return .unsupported }
        switch (action, call.name) {
        case (.format, "AFNumber_Format"): return .value(numberFormat(value, call.arguments))
        case (.keystroke, "AFNumber_Keystroke"):
            return isNumber(value, sepStyle: call.arguments.int(1)) ? .value(value) : .rejected(FormsStrings.Invalid.number)
        case (.format, "AFPercent_Format"): return .value(percentFormat(value, call.arguments))
        case (.keystroke, "AFPercent_Keystroke"):
            return isNumber(value, sepStyle: call.arguments.int(1)) ? .value(value) : .rejected(FormsStrings.Invalid.number)
        case (.format, "AFDate_FormatEx"), (.format, "AFDate_Format"), (.format, "AFTime_FormatEx"), (.format, "AFTime_Format"):
            guard let format = AFDates.format(of: call) else { return .unsupported }
            return .value(AFDates.parse(value, format: format).map { AFDates.string($0, format: format) } ?? value)
        case (.keystroke, "AFDate_KeystrokeEx"), (.keystroke, "AFDate_Keystroke"), (.keystroke, "AFTime_KeystrokeEx"), (.keystroke, "AFTime_Keystroke"):
            guard let format = AFDates.format(of: call) else { return .unsupported }
            return value.isEmpty || AFDates.parse(value, format: format) != nil ? .value(value) : .rejected(FormsStrings.Invalid.date(format))
        case (.format, "AFSpecial_Format"), (.keystroke, "AFSpecial_Keystroke"):
            guard let mask = AFSpecial.mask(call.arguments.int(0)) else { return .unsupported }
            return special(value, masks: mask, action: action)
        case (.format, "AFSpecial_KeystrokeEx"), (.keystroke, "AFSpecial_KeystrokeEx"):
            return special(value, masks: [call.arguments.string(0)], action: action)
        case (.validate, "AFRange_Validate"): return rangeValidate(value, call.arguments)
        case (.calculate, "AFSimple_Calculate"): return simpleCalculate(call.arguments, fields: fields)
        default: return .unsupported
        }
    }

    /// The number a calculation reads from a shown value, given the field's format script ("$1,234.50" → "1234.5",
    /// "50.00%" → "0.5"); dates and plain text come back as they are.
    public static func rawValue(of shown: String, format script: String?) -> String {
        guard let script, let call = AFScript.firstCall(in: script) else { return shown }
        switch call.name {
        case "AFNumber_Format", "AFPercent_Format":
            return AFNumbers.parse(shown, sepStyle: call.arguments.int(1)).map(plain) ?? shown
        default:
            return shown
        }
    }

    /// "12", "12.5", "0.3": no float noise, no trailing zeros.
    static func plain(_ value: Double) -> String {
        guard value.isFinite else { return "" }
        if value == value.rounded(), abs(value) < 1e15 { return String(Int64(value)) }
        var text = String(format: "%.10f", value)
        while text.hasSuffix("0") { text.removeLast() }
        if text.hasSuffix(".") { text.removeLast() }
        return text == "-0" ? "0" : text
    }

    // MARK: Number and percent

    /// An entry a number field takes: empty, or digits with separators, a sign, a currency symbol or a percent sign.
    private func isNumber(_ value: String, sepStyle: Int) -> Bool {
        value.isEmpty || (!value.contains(where: \.isLetter) && AFNumbers.parse(value, sepStyle: sepStyle) != nil)
    }

    /// AFNumber_Format(nDec, sepStyle, negStyle, currStyle, strCurrency, bCurrencyPrepend).
    private func numberFormat(_ value: String, _ args: [AFScript.Argument]) -> String {
        let sepStyle = args.int(1)
        guard !value.isEmpty, let number = AFNumbers.parse(value, sepStyle: sepStyle) else { return value }
        let decimals = max(0, min(args.int(0), 10))
        var body = AFNumbers.format(abs(number), decimals: decimals, sepStyle: sepStyle)
        let currency = args.string(4)
        if !currency.isEmpty { body = args.bool(5, default: true) ? currency + body : body + currency }
        let isNegative = number < 0 && AFNumbers.format(abs(number), decimals: decimals, sepStyle: 1).contains { $0 != "0" && $0 != "." }
        guard isNegative else { return body }
        // Styles 1 and 3 are red in Acrobat; the colour can't travel in the value, so 1 keeps the minus sign.
        return args.int(2) >= 2 ? "(\(body))" : "-" + body
    }

    /// AFPercent_Format(nDec, sepStyle, bPercentPrepend): the value times 100 with "%".
    private func percentFormat(_ value: String, _ args: [AFScript.Argument]) -> String {
        let sepStyle = args.int(1)
        guard !value.isEmpty, let number = AFNumbers.parse(value, sepStyle: sepStyle) else { return value }
        let body = AFNumbers.format(abs(number * 100), decimals: max(0, min(args.int(0), 10)), sepStyle: sepStyle)
        let shown = args.bool(2, default: false) ? "%" + body : body + "%"
        return number < 0 ? "-" + shown : shown
    }

    // MARK: Special masks

    private func special(_ value: String, masks: [String], action: AFAction) -> AFOutcome {
        guard !value.isEmpty else { return .value(value) }
        for mask in masks {
            if let masked = AFSpecial.apply(mask, to: value) { return .value(action == .format ? masked : value) }
        }
        return action == .format ? .value(value) : .rejected(FormsStrings.Invalid.mask(masks[masks.count - 1]))
    }

    // MARK: Validate and calculate

    /// AFRange_Validate(bGreaterThan, nGreaterThan, bLessThan, nLessThan).
    private func rangeValidate(_ value: String, _ args: [AFScript.Argument]) -> AFOutcome {
        guard !value.isEmpty else { return .value(value) }
        guard let number = AFNumbers.parse(value, sepStyle: nil) else { return .rejected(FormsStrings.Invalid.number) }
        let low = args.bool(0, default: false) ? args.double(1) : nil
        let high = args.bool(2, default: false) ? args.double(3) : nil
        let tooLow = low.map { number < $0 } ?? false, tooHigh = high.map { number > $0 } ?? false
        guard tooLow || tooHigh else { return .value(value) }
        return .rejected(FormsStrings.Invalid.range(low: low.map(Self.plain), high: high.map(Self.plain)))
    }

    /// AFSimple_Calculate("SUM" | "PRD" | "AVG" | "MIN" | "MAX", names): a name that is a field group stands for every
    /// field under it ("price" → "price.0", "price.1"); empty fields count as 0.
    private func simpleCalculate(_ args: [AFScript.Argument], fields: [String: String]) -> AFOutcome {
        let names = args.strings(1).flatMap { name -> [String] in
            if fields[name] != nil { return [name] }
            return fields.keys.filter { $0.hasPrefix(name + ".") }.sorted()
        }
        let numbers = names.map { AFNumbers.parse(fields[$0] ?? "", sepStyle: nil) ?? 0 }
        let result: Double
        switch args.string(0).uppercased() {
        case "SUM": result = numbers.reduce(0, +)
        case "PRD": result = numbers.isEmpty ? 0 : numbers.reduce(1, *)
        case "AVG": result = numbers.isEmpty ? 0 : numbers.reduce(0, +) / Double(numbers.count)
        case "MIN": result = numbers.min() ?? 0
        case "MAX": result = numbers.max() ?? 0
        default: return .unsupported
        }
        return .value(Self.plain(result))
    }
}

// MARK: - Script parsing

/// The parts of a form script we read: its first `AF*` call with the arguments, a simplified-field-notation
/// expression, or an `event.value = …` expression over `getField("…").value`.
enum AFScript {
    enum Argument: Equatable {
        case number(Double)
        case string(String)
        case bool(Bool)
        case list([String])
    }

    struct Call: Equatable {
        var name: String
        var arguments: [Argument]
    }

    /// An arithmetic expression whose identifiers stand for field names.
    struct Expression {
        var text: String
        var names: [String: String]
    }

    static func firstCall(in script: String) -> Call? {
        let scalars = Array(script.unicodeScalars)
        var i = 0
        while i < scalars.count {
            guard scalars[i] == "A", i + 2 < scalars.count, scalars[i + 1] == "F",
                  i == 0 || !(CharacterSet.alphanumerics.contains(scalars[i - 1]) || scalars[i - 1] == "_" || scalars[i - 1] == ".") else { i += 1; continue }
            var j = i
            while j < scalars.count, CharacterSet.alphanumerics.contains(scalars[j]) || scalars[j] == "_" { j += 1 }
            let name = String(String.UnicodeScalarView(scalars[i..<j]))
            var k = j
            while k < scalars.count, scalars[k] == " " { k += 1 }
            if k < scalars.count, scalars[k] == "(", let (arguments, _) = parseArguments(scalars, from: k + 1) {
                return Call(name: name, arguments: arguments)
            }
            i = j
        }
        return nil
    }

    /// Arguments up to the matching ")": numbers, quoted strings, true/false, `new Array(…)` and `[…]` of strings.
    private static func parseArguments(_ s: [Unicode.Scalar], from start: Int) -> ([Argument], Int)? {
        var arguments: [Argument] = []
        var i = start
        func skipSpace() { while i < s.count, s[i] == " " || s[i] == "\n" || s[i] == "\r" || s[i] == "\t" { i += 1 } }
        while i < s.count {
            skipSpace()
            guard i < s.count else { return nil }
            if s[i] == ")" { return (arguments, i + 1) }
            if s[i] == "," { i += 1; continue }
            if s[i] == "\"" || s[i] == "'" {
                guard let (text, next) = quoted(s, from: i) else { return nil }
                arguments.append(.string(text)); i = next
            } else if s[i] == "[" {
                guard let (list, next) = stringList(s, from: i + 1, closing: "]") else { return nil }
                arguments.append(.list(list)); i = next
            } else if hasWord(s, at: i, "new") {
                i += 3; skipSpace()
                guard hasWord(s, at: i, "Array") else { return nil }
                i += 5; skipSpace()
                guard i < s.count, s[i] == "(", let (list, next) = stringList(s, from: i + 1, closing: ")") else { return nil }
                arguments.append(.list(list)); i = next
            } else if hasWord(s, at: i, "true") {
                arguments.append(.bool(true)); i += 4
            } else if hasWord(s, at: i, "false") {
                arguments.append(.bool(false)); i += 5
            } else {
                var j = i
                while j < s.count, "+-.0123456789eE".unicodeScalars.contains(s[j]) { j += 1 }
                guard j > i, let number = Double(String(String.UnicodeScalarView(s[i..<j]))) else { return nil }
                arguments.append(.number(number)); i = j
            }
        }
        return nil
    }

    private static func hasWord(_ s: [Unicode.Scalar], at i: Int, _ word: String) -> Bool {
        let w = Array(word.unicodeScalars)
        guard i + w.count <= s.count, Array(s[i..<i + w.count]) == w else { return false }
        return i + w.count == s.count || !CharacterSet.alphanumerics.contains(s[i + w.count])
    }

    private static func quoted(_ s: [Unicode.Scalar], from start: Int) -> (String, Int)? {
        let quote = s[start]
        var text = String.UnicodeScalarView()
        var i = start + 1
        while i < s.count {
            if s[i] == "\\", i + 1 < s.count { text.append(s[i + 1]); i += 2; continue }
            if s[i] == quote { return (String(text), i + 1) }
            text.append(s[i]); i += 1
        }
        return nil
    }

    private static func stringList(_ s: [Unicode.Scalar], from start: Int, closing: Unicode.Scalar) -> ([String], Int)? {
        var items: [String] = []
        var i = start
        while i < s.count {
            if s[i] == closing { return (items, i + 1) }
            if s[i] == "\"" || s[i] == "'" {
                guard let (text, next) = quoted(s, from: i) else { return nil }
                items.append(text); i = next
            } else { i += 1 }
        }
        return nil
    }

    /// Acrobat's simplified field notation: `/** BVCALC price * qty EVCALC **/ …`; field names with spaces or symbols
    /// are written with backslashes ("unit\ price").
    static func simplifiedNotation(in script: String) -> Expression? {
        guard let begin = script.range(of: "BVCALC"), let end = script.range(of: "EVCALC", range: begin.upperBound..<script.endIndex) else { return nil }
        let source = String(script[begin.upperBound..<end.lowerBound])
        var text = "", names: [String: String] = [:]
        var name = ""
        func flush() {
            guard !name.isEmpty else { return }
            if Double(name) != nil { text += name } else {
                let key = "f\(names.count)"
                names[key] = name
                text += key
            }
            name = ""
        }
        var escaped = false
        for ch in source {
            if escaped { name.append(ch); escaped = false; continue }
            if ch == "\\" { escaped = true; continue }
            if "+-*/() \t\n\r".contains(ch) { flush(); text.append(ch) } else { name.append(ch) }
        }
        flush()
        return Expression(text: text, names: names)
    }

    /// `event.value = AFMakeNumber(getField("a").value) + this.getField("b").value;` and the like.
    static func eventValueExpression(in script: String) -> Expression? {
        guard let assign = script.range(of: #"event\.value\s*=\s*"#, options: .regularExpression) else { return nil }
        var rest = String(script[assign.upperBound...])
        if let semicolon = rest.firstIndex(of: ";") { rest = String(rest[..<semicolon]) }
        var names: [String: String] = [:]
        let pattern = try! NSRegularExpression(pattern: #"(?:this\.)?getField\(\s*["']([^"']+)["']\s*\)\.value"#)
        for match in pattern.matches(in: rest, range: NSRange(rest.startIndex..., in: rest)).reversed() {
            guard let whole = Range(match.range, in: rest), let nameRange = Range(match.range(at: 1), in: rest) else { continue }
            let key = "f\(names.count)"
            names[key] = String(rest[nameRange])
            rest.replaceSubrange(whole, with: key)
        }
        guard !names.isEmpty else { return nil }
        for wrapper in ["AFMakeNumber", "Number"] { rest = rest.replacingOccurrences(of: wrapper, with: "") }
        return Expression(text: rest, names: names)
    }
}

extension [AFScript.Argument] {
    func double(_ i: Int, default fallback: Double = 0) -> Double {
        guard indices.contains(i) else { return fallback }
        switch self[i] {
        case .number(let v): return v
        case .bool(let v): return v ? 1 : 0
        case .string(let v): return Double(v) ?? fallback
        case .list: return fallback
        }
    }

    func int(_ i: Int, default fallback: Int = 0) -> Int { Int(double(i, default: Double(fallback))) }

    func bool(_ i: Int, default fallback: Bool) -> Bool {
        guard indices.contains(i) else { return fallback }
        switch self[i] {
        case .bool(let v): return v
        case .number(let v): return v != 0
        case .string(let v): return v == "true"
        case .list: return fallback
        }
    }

    func string(_ i: Int) -> String {
        guard indices.contains(i) else { return "" }
        switch self[i] {
        case .string(let v): return v
        case .number(let v): return AFEmulator.plain(v)
        case .bool(let v): return v ? "true" : "false"
        case .list(let v): return v.joined(separator: ",")
        }
    }

    /// A list argument, or a string of comma-separated names.
    func strings(_ i: Int) -> [String] {
        guard indices.contains(i) else { return [] }
        if case .list(let names) = self[i] { return names }
        return string(i).split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
    }
}
