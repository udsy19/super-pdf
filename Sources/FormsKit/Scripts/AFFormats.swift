import Foundation

// The formats behind the AF* helpers: Acrobat's number separator styles, its date/time pictures, the special masks,
// and the arithmetic of simplified field notation.

/// Numbers as Acrobat's `AFMakeNumber` reads them and `AFNumber_Format` writes them.
enum AFNumbers {
    /// Separator styles: 0 "1,234.56", 1 "1234.56", 2 "1.234,56", 3 "1234,56", 4 "1'234.56".
    static func separators(_ sepStyle: Int) -> (group: String, decimal: String) {
        switch sepStyle {
        case 1: ("", ".")
        case 2: (".", ",")
        case 3: ("", ",")
        case 4: ("'", ".")
        default: (",", ".")
        }
    }

    static func format(_ value: Double, decimals: Int, sepStyle: Int) -> String {
        let (group, decimal) = separators(sepStyle)
        let scale = pow(10, Double(decimals))
        let scaled = (value * scale).rounded(.toNearestOrAwayFromZero)
        let whole = (scaled / scale).rounded(.towardZero)
        var digits = String(format: "%.0f", abs(whole))
        if !group.isEmpty {
            var grouped = ""
            for (n, ch) in digits.reversed().enumerated() {
                if n > 0, n % 3 == 0 { grouped.append(contentsOf: group.reversed()) }
                grouped.append(ch)
            }
            digits = String(grouped.reversed())
        }
        guard decimals > 0 else { return (scaled < 0 ? "-" : "") + digits }
        let fraction = String(format: "%0\(decimals).0f", abs(scaled - whole * scale))
        return (scaled < 0 ? "-" : "") + digits + decimal + fraction
    }

    /// A number from text people type or a format wrote: currency signs and spaces ignored, "(12)" and "-12" negative,
    /// "50%" is 0.5. With a separator style the decimal mark is known; without, a lone comma followed by other than
    /// three digits is a decimal comma.
    static func parse(_ text: String, sepStyle: Int?) -> Double? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        let isNegative = trimmed.contains("-") || trimmed.contains("−") || (trimmed.contains("(") && trimmed.contains(")"))
        let isPercent = trimmed.contains("%")
        var kept = trimmed.filter { $0.isASCII && ($0.isNumber || $0 == "." || $0 == ",") }
        guard kept.contains(where: \.isNumber) else { return nil }
        let decimal: Character
        if let sepStyle, separators(sepStyle).decimal == ",", kept.contains(",") || kept.filter({ $0 == "." }).count > 1 {
            decimal = ","
        } else if let sepStyle, separators(sepStyle).decimal == "." {
            decimal = "."
        } else if let lastDot = kept.lastIndex(of: "."), let lastComma = kept.lastIndex(of: ",") {
            decimal = lastDot > lastComma ? "." : ","
        } else if kept.filter({ $0 == "," }).count == 1, let comma = kept.firstIndex(of: ","), kept.distance(from: comma, to: kept.endIndex) - 1 != 3 {
            decimal = ","
        } else {
            decimal = "."
        }
        kept = kept.filter { $0.isNumber || $0 == decimal }
        if decimal == "," { kept = kept.replacingOccurrences(of: ",", with: ".") }
        guard kept.filter({ $0 == "." }).count <= 1, var number = Double(kept) else { return nil }
        if isPercent { number /= 100 }
        return isNegative ? -number : number
    }
}

/// Acrobat's date and time pictures ("mm/dd/yyyy", "mmmm d, yyyy", "h:MM tt"): formatting, and the forgiving parse
/// of `AFParseDateEx` (numbers in the picture's order, month names, ISO dates, 12/24-hour times).
enum AFDates {
    /// `AFDate_Format(n)`'s pictures.
    static let datePictures = ["m/d", "m/d/yy", "mm/dd/yy", "mm/yy", "d-mmm", "d-mmm-yy", "dd-mmm-yy", "yy-mm-dd", "mmm-yy", "mmmm-yy",
                               "mmm d, yyyy", "mmmm d, yyyy", "m/d/yy h:MM tt", "m/d/yy HH:MM"]
    /// `AFTime_Format(n)`'s pictures.
    static let timePictures = ["HH:MM", "h:MM tt", "HH:MM:ss", "h:MM:ss tt"]

    static let months = ["January", "February", "March", "April", "May", "June", "July", "August", "September", "October", "November", "December"]
    static let weekdays = ["Sunday", "Monday", "Tuesday", "Wednesday", "Thursday", "Friday", "Saturday"]

    struct Stamp: Equatable {
        var year = 2000, month = 1, day = 1, hour = 0, minute = 0, second = 0
    }

    /// The picture an AF date/time call uses.
    static func format(of call: AFScript.Call) -> String? {
        switch call.name {
        case "AFDate_FormatEx", "AFDate_KeystrokeEx", "AFTime_FormatEx", "AFTime_KeystrokeEx":
            let picture = call.arguments.string(0)
            return picture.isEmpty ? nil : picture
        case "AFDate_Format", "AFDate_Keystroke":
            let n = call.arguments.int(0)
            return datePictures.indices.contains(n) ? datePictures[n] : nil
        case "AFTime_Format", "AFTime_Keystroke":
            let n = call.arguments.int(0)
            return timePictures.indices.contains(n) ? timePictures[n] : nil
        default:
            return nil
        }
    }

    /// The picture split into runs of one token letter ("mm", "/", "dd") and literals.
    static func tokens(_ picture: String) -> [String] {
        var tokens: [String] = []
        var escaped = false
        for ch in picture {
            if escaped { tokens.append(String(ch)); escaped = false; continue }
            if ch == "\\" { escaped = true; continue }
            if "dmyHhMstT".contains(ch), let last = tokens.last, last.first == ch { tokens[tokens.count - 1].append(ch) } else { tokens.append(String(ch)) }
        }
        return tokens
    }

    static func string(_ stamp: Stamp, format picture: String) -> String {
        tokens(picture).map { token -> String in
            switch token {
            case "d": "\(stamp.day)"
            case "dd": two(stamp.day)
            case "ddd": String(weekdays[weekday(stamp)].prefix(3))
            case "dddd": weekdays[weekday(stamp)]
            case "m": "\(stamp.month)"
            case "mm": two(stamp.month)
            case "mmm": String(months[stamp.month - 1].prefix(3))
            case "mmmm": months[stamp.month - 1]
            case "yy": two(stamp.year % 100)
            case "yyyy": String(format: "%04d", stamp.year)
            case "H": "\(stamp.hour)"
            case "HH": two(stamp.hour)
            case "h": "\(hour12(stamp.hour))"
            case "hh": two(hour12(stamp.hour))
            case "M": "\(stamp.minute)"
            case "MM": two(stamp.minute)
            case "s": "\(stamp.second)"
            case "ss": two(stamp.second)
            case "t": stamp.hour < 12 ? "a" : "p"
            case "tt": stamp.hour < 12 ? "am" : "pm"
            default: token
            }
        }.joined()
    }

    /// Reads `text` for a picture; nil when it isn't a real date or time. Like Acrobat's parser it tries harder when
    /// the numbers don't fit the picture's order: month-day-year, day-month-year, then year-month-day.
    static func parse(_ text: String, format picture: String) -> Stamp? {
        if let stamp = parse(text, picture: picture) { return stamp }
        let order = tokens(picture).filter { token in token.first.map { "dmy".contains($0) } == true && !(token.first == "d" && token.count > 2) }
        guard order.count == 3 else { return nil }
        for fallback in ["m/d/yyyy", "d/m/yyyy", "yyyy/m/d"] where fallback != picture {
            if let stamp = parse(text, picture: fallback) { return stamp }
        }
        return nil
    }

    private static func parse(_ text: String, picture: String) -> Stamp? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        let tokens = tokens(picture)
        enum Part { case day, month, year, hour, minute, second }
        var order: [Part] = []
        var monthByName = false
        for token in tokens {
            switch token.first {
            case "d" where token.count <= 2: order.append(.day)
            case "m": if token.count >= 3 { monthByName = true }; order.append(.month)
            case "y": order.append(.year)
            case "H", "h": order.append(.hour)
            case "M": order.append(.minute)
            case "s": order.append(.second)
            default: break
            }
        }
        let lower = trimmed.lowercased()
        var numbers: [(value: Int, digits: Int)] = []
        var current = ""
        for ch in lower {
            if ch.isASCII, ch.isNumber { current.append(ch) } else if !current.isEmpty { numbers.append((Int(current)!, current.count)); current = "" }
        }
        if !current.isEmpty { numbers.append((Int(current)!, current.count)) }
        let namedMonth = months.firstIndex { lower.contains($0.lowercased().prefix(3)) }.map { $0 + 1 }
        let pm = lower.range(of: #"\bp\.?m?\.?\b"#, options: .regularExpression) != nil || lower.hasSuffix("p")
        let am = lower.range(of: #"\ba\.?m?\.?\b"#, options: .regularExpression) != nil

        var stamp = Stamp()
        let today = Calendar(identifier: .gregorian).dateComponents([.year], from: Date())
        stamp.year = today.year ?? 2000
        var parts = order
        if namedMonth != nil || monthByName {
            guard let namedMonth else { return nil }
            stamp.month = namedMonth
            parts.removeAll { $0 == .month }
        }
        // An ISO date ("2026-03-15") reads year, month, day whatever the picture.
        if let first = numbers.first, first.digits == 4, parts.first != .year, parts.contains(.year), numbers.count >= 3 {
            let dateParts: [Part] = namedMonth == nil ? [.year, .month, .day] : [.year, .day]
            parts = dateParts + parts.filter { ![.year, .month, .day].contains($0) }
        }
        let assigned = Set(zip(parts, numbers).map(\.0))
        // Day, month and hour must be there when the picture has them; a missing year is this year, missing minutes 0.
        guard parts.allSatisfy({ ![.day, .month, .hour].contains($0) || assigned.contains($0) }) else { return nil }
        for (part, number) in zip(parts, numbers) {
            switch part {
            case .day: stamp.day = number.value
            case .month: stamp.month = number.value
            case .year: stamp.year = number.digits <= 2 ? (number.value < 50 ? 2000 + number.value : 1900 + number.value) : number.value
            case .hour: stamp.hour = number.value
            case .minute: stamp.minute = number.value
            case .second: stamp.second = number.value
            }
        }
        if pm, stamp.hour < 12 { stamp.hour += 12 }
        if am, stamp.hour == 12 { stamp.hour = 0 }
        guard (1...12).contains(stamp.month), (1...days(in: stamp.month, of: stamp.year)).contains(stamp.day),
              (0...23).contains(stamp.hour), (0...59).contains(stamp.minute), (0...59).contains(stamp.second), (1...9999).contains(stamp.year) else { return nil }
        return stamp
    }

    static func days(in month: Int, of year: Int) -> Int {
        switch month {
        case 2: (year % 4 == 0 && year % 100 != 0) || year % 400 == 0 ? 29 : 28
        case 4, 6, 9, 11: 30
        default: 31
        }
    }

    /// 0 = Sunday (Zeller's congruence on the Gregorian calendar).
    static func weekday(_ stamp: Stamp) -> Int {
        var y = stamp.year, m = stamp.month
        if m < 3 { m += 12; y -= 1 }
        let h = (stamp.day + (13 * (m + 1)) / 5 + y % 100 + (y % 100) / 4 + (y / 100) / 4 + 5 * (y / 100)) % 7
        return (h + 6) % 7
    }

    private static func two(_ n: Int) -> String { String(format: "%02d", n) }
    private static func hour12(_ h: Int) -> Int { h % 12 == 0 ? 12 : h % 12 }
}

/// `AFSpecial_Format` and `AFSpecial_KeystrokeEx` masks: 9 a digit, A a letter, O a letter or digit, X anything; other
/// characters are printed as they are.
enum AFSpecial {
    /// 0 ZIP code, 1 ZIP+4, 2 phone number (ten or seven digits), 3 social security number.
    static func mask(_ psf: Int) -> [String]? {
        switch psf {
        case 0: ["99999"]
        case 1: ["99999-9999"]
        case 2: ["(999) 999-9999", "999-9999"]
        case 3: ["999-99-9999"]
        default: nil
        }
    }

    /// The value written into the mask, or nil when it doesn't fit (too few or too many of the wanted characters).
    static func apply(_ mask: String, to value: String) -> String? {
        let slots = mask.filter { "9AOX".contains($0) }
        let wanted: (Character) -> (Character) -> Bool = { slot in
            switch slot {
            case "9": { $0.isASCII && $0.isNumber }
            case "A": { $0.isLetter }
            case "O": { $0.isLetter || ($0.isASCII && $0.isNumber) }
            default: { !$0.isWhitespace }
            }
        }
        // The characters that fill slots: everything of the kinds the mask asks for, literals of the mask left out.
        let literals = Set(mask.filter { !"9AOX".contains($0) })
        let input = value.filter { ch in !literals.contains(ch) && !ch.isWhitespace }
        guard input.count == slots.count, zip(slots, input).allSatisfy({ wanted($0.0)($0.1) }) else { return nil }
        var result = ""
        var iterator = input.makeIterator()
        for ch in mask { result.append("9AOX".contains(ch) ? iterator.next()! : ch) }
        return result
    }
}

/// The arithmetic of simplified field notation: + − × ÷, parentheses, unary minus, numbers and field names (empty
/// fields are 0). Nil when the expression is anything else.
enum SimpleCalc {
    static func evaluate(_ text: String, names: [String: String], fields: [String: String]) -> Double? {
        var parser = Parser(tokens: tokenize(text), names: names, fields: fields)
        guard let tokens = parser.tokens, let value = parser.expression(), parser.position == tokens.count else { return nil }
        return value
    }

    enum Token: Equatable { case number(Double), name(String), op(Character) }

    private static func tokenize(_ text: String) -> [Token]? {
        var tokens: [Token] = []
        var i = text.startIndex
        while i < text.endIndex {
            let ch = text[i]
            if ch.isWhitespace { i = text.index(after: i); continue }
            if "+-*/()".contains(ch) { tokens.append(.op(ch)); i = text.index(after: i); continue }
            var j = i
            while j < text.endIndex, !text[j].isWhitespace, !"+-*/()".contains(text[j]) { j = text.index(after: j) }
            let word = String(text[i..<j])
            if let number = Double(word) { tokens.append(.number(number)) } else if word.allSatisfy({ $0.isLetter || $0.isNumber || $0 == "_" }) {
                tokens.append(.name(word))
            } else { return nil }
            i = j
        }
        return tokens
    }

    private struct Parser {
        var tokens: [Token]?
        var names: [String: String]
        var fields: [String: String]
        var position = 0

        mutating func peek() -> Token? { tokens.flatMap { position < $0.count ? $0[position] : nil } }

        mutating func expression() -> Double? {
            guard var value = term() else { return nil }
            while case .op(let op)? = peek(), op == "+" || op == "-" {
                position += 1
                guard let rhs = term() else { return nil }
                value = op == "+" ? value + rhs : value - rhs
            }
            return value
        }

        mutating func term() -> Double? {
            guard var value = factor() else { return nil }
            while case .op(let op)? = peek(), op == "*" || op == "/" {
                position += 1
                guard let rhs = factor() else { return nil }
                value = op == "*" ? value * rhs : value / rhs
            }
            return value
        }

        mutating func factor() -> Double? {
            guard let token = peek() else { return nil }
            position += 1
            switch token {
            case .number(let v): return v
            case .name(let key):
                guard let name = names[key] else { return nil }
                return AFNumbers.parse(fields[name] ?? "", sepStyle: nil) ?? 0
            case .op("-"): return factor().map { -$0 }
            case .op("+"): return factor()
            case .op("("):
                guard let value = expression(), case .op(")")? = peek() else { return nil }
                position += 1
                return value
            default: return nil
            }
        }
    }
}
