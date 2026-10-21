import Foundation
import SuperPDFCore

/// FormsKit's copy (ux §5.3 Fill a form / Make a form, §7.4): sentence case, curly quotes, a real ellipsis on what
/// opens a dialog.
enum FormsStrings {
    // MARK: Fill a form (ux §5.3)

    static let autoFill = "AutoFill from my card"
    static let clearForm = "Clear form"
    static let noFieldsOnPage = "This page has no fields"
    static let fillAnywhere = "Fill anywhere"
    static let placeText = "Text"
    static let placeTick = "Tick"
    static func autoFilled(_ count: Int) -> String { "Filled \(Formatting.count(count, "field", "fields")) from your card." }
    static let autoFillNothing = "Nothing on this form matches your card."
    static let contactsDenied = "Super PDF can’t read your card. Allow it in System Settings › Privacy & Security › Contacts."
    static let noMeCard = "There’s no card for you in Contacts. Choose one with Card › Make This My Card in Contacts."
    static let dataFormat = "File type"
    static let saveData = "Save the answers as a file…"
    static let loadData = "Fill in from a file…"
    static func cantReadData(_ name: String) -> String { "\(Strings.quoted(name)) doesn’t hold answers this form can use." }

    // MARK: Make a form (ux §5.3)

    static let findFields = "Find fields for me"
    static func findFields(found count: Int) -> String { "Find fields for me (\(count))" }
    static func addedFields(_ count: Int) -> String { "Added \(Formatting.count(count, "field", "fields"))." }
    static let noFieldsFound = "No empty lines or boxes to turn into fields."
    static let selectHint = "Click a field to change it, or choose a kind and click the page."
    static let name = "Name"
    static let required = "Required"
    static let defaultValue = "Default"
    static let format = "Format"
    static let calculate = "Calculate"
    static let setTabOrder = "Set tab order"
    static let removeField = "Remove this field"
    static let choices = "Choices"
    static let choicesPlaceholder = "Red, Green, Blue"

    enum Kind {
        static let text = "Text box"
        static let tick = "Tick box"
        static let choice = "Choice"
        static let date = "Date"
        static let signature = "Signature"
        static let number = "Number"
        static let multiline = "Multiple-line text"
        static let picture = "Picture"
    }

    enum Formats {
        static let none = "None"
        static let number = "Number"
        static let percent = "Percentage"
        static let date = "Date"
        static let time = "Time"
        static let phone = "Phone number"
        static let zip = "ZIP code"
    }

    enum Calculations {
        static let none = "Nothing"
        static let sum = "Sum of"
        static let average = "Average of"
        static let product = "Product of"
    }

    // MARK: Invalid entries (what an `AF*` keystroke or validate script rejects)

    enum Invalid {
        static let number = "Enter a number."
        static func date(_ picture: String) -> String {
            let today = Calendar(identifier: .gregorian).dateComponents([.year, .month, .day, .hour, .minute], from: Date())
            let stamp = AFDates.Stamp(year: today.year ?? 2026, month: today.month ?? 1, day: today.day ?? 1, hour: today.hour ?? 9,
                                      minute: today.minute ?? 0)
            return "Enter it like \(Strings.quoted(AFDates.string(stamp, format: picture)))."
        }
        static func mask(_ mask: String) -> String {
            var digits = "1234567890".makeIterator()
            let example = String(mask.map { ch -> Character in
                switch ch {
                case "9":
                    if let d = digits.next() { return d }
                    digits = "1234567890".makeIterator()
                    return digits.next()!
                case "A", "O": return "A"
                case "X": return "x"
                default: return ch
                }
            })
            return "Enter it like \(Strings.quoted(example))."
        }
        static func range(low: String?, high: String?) -> String {
            switch (low, high) {
            case let (low?, high?): "Enter a number from \(low) to \(high)."
            case let (low?, nil): "Enter a number of \(low) or more."
            case let (nil, high?): "Enter a number of \(high) or less."
            default: number
            }
        }
    }

    // MARK: Undo (Edit › Undo “…”)

    enum Undo {
        static let fill = "Fill Form"
        static let autoFill = "AutoFill"
        static let clear = "Clear Form"
        static let importData = "Fill From File"
        static let addFields = "Add Fields"
        static let changeField = "Change Field"
        static let removeFields = "Remove Fields"
        static let tabOrder = "Set Tab Order"
    }
}
