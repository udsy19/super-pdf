import Foundation
import SuperPDFCore

/// The Format popup of Make a form (ux §5.3) as the `AF*` scripts Acrobat writes for it, in this Mac's number and date
/// conventions.
enum FieldFormat: String, CaseIterable, Sendable {
    case none, number, percent, date, time, phone, zip

    var title: String {
        switch self {
        case .none: FormsStrings.Formats.none
        case .number: FormsStrings.Formats.number
        case .percent: FormsStrings.Formats.percent
        case .date: FormsStrings.Formats.date
        case .time: FormsStrings.Formats.time
        case .phone: FormsStrings.Formats.phone
        case .zip: FormsStrings.Formats.zip
        }
    }

    /// The format and keystroke scripts; empty for `.none`.
    func scripts(locale: Locale = .current) -> [AFAction: String] {
        let sepStyle = locale.decimalSeparator == "," ? 2 : 0
        switch self {
        case .none:
            return [:]
        case .number:
            return [.format: "AFNumber_Format(2, \(sepStyle), 0, 0, \"\", true);", .keystroke: "AFNumber_Keystroke(2, \(sepStyle), 0, 0, \"\", true);"]
        case .percent:
            return [.format: "AFPercent_Format(2, \(sepStyle));", .keystroke: "AFPercent_Keystroke(2, \(sepStyle));"]
        case .date:
            let picture = Self.datePicture(locale: locale)
            return [.format: "AFDate_FormatEx(\"\(picture)\");", .keystroke: "AFDate_KeystrokeEx(\"\(picture)\");"]
        case .time:
            let twelveHour = DateFormatter.dateFormat(fromTemplate: "j", options: 0, locale: locale)?.contains("a") ?? true
            return [.format: "AFTime_Format(\(twelveHour ? 1 : 0));", .keystroke: "AFTime_Keystroke(\(twelveHour ? 1 : 0));"]
        case .phone:
            return [.format: "AFSpecial_Format(2);", .keystroke: "AFSpecial_Keystroke(2);"]
        case .zip:
            return [.format: "AFSpecial_Format(0);", .keystroke: "AFSpecial_Keystroke(0);"]
        }
    }

    /// The format a field's scripts carry.
    init(scripts: [AFAction: String]) {
        guard let script = scripts[.format], let call = AFScript.firstCall(in: script) else { self = .none; return }
        switch call.name {
        case "AFNumber_Format": self = .number
        case "AFPercent_Format": self = .percent
        case "AFDate_FormatEx", "AFDate_Format": self = .date
        case "AFTime_FormatEx", "AFTime_Format": self = .time
        case "AFSpecial_Format": self = call.arguments.int(0) == 2 ? .phone : call.arguments.int(0) <= 1 ? .zip : .none
        default: self = .none
        }
    }

    /// Day, month and year in this Mac's order, as an Acrobat picture: "dd/mm/yyyy", "mm/dd/yyyy", "yyyy-mm-dd".
    static func datePicture(locale: Locale) -> String {
        let pattern = DateFormatter.dateFormat(fromTemplate: "ddMMyyyy", options: 0, locale: locale) ?? "MM/dd/yyyy"
        return pattern.replacingOccurrences(of: "MM", with: "mm").replacingOccurrences(of: "'", with: "")
    }
}

/// "Calculate from…" (ux §5.3): the sum, average or product of chosen fields, as `AFSimple_Calculate`.
enum FieldCalculation: String, CaseIterable, Sendable {
    case none, sum, average, product

    var title: String {
        switch self {
        case .none: FormsStrings.Calculations.none
        case .sum: FormsStrings.Calculations.sum
        case .average: FormsStrings.Calculations.average
        case .product: FormsStrings.Calculations.product
        }
    }

    private var operation: String {
        switch self {
        case .none: ""
        case .sum: "SUM"
        case .average: "AVG"
        case .product: "PRD"
        }
    }

    func script(of fields: [String]) -> String? {
        guard self != .none, !fields.isEmpty else { return nil }
        let names = fields.map { "\"" + $0.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"") + "\"" }
        return "AFSimple_Calculate(\"\(operation)\", new Array (\(names.joined(separator: ", "))));"
    }

    /// What a calculate script does, when it is one of these.
    static func parse(_ script: String?) -> (FieldCalculation, [String])? {
        guard let script, let call = AFScript.firstCall(in: script), call.name == "AFSimple_Calculate" else { return nil }
        let kind: FieldCalculation? = switch call.arguments.string(0).uppercased() {
        case "SUM": .sum
        case "AVG": .average
        case "PRD": .product
        default: nil
        }
        return kind.map { ($0, call.arguments.strings(1)) }
    }
}
