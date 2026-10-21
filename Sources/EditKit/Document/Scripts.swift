import Foundation
import PDFModelKit

// Document JavaScript and actions (features #74): listed so people can remove them, never run. Found in the catalog's
// JavaScript name tree, the open action, the document's and pages' additional actions, link and widget actions and
// form fields' actions.

/// Where a script lives, in plain words for the list.
struct ScriptEntry: Hashable {
    enum Place: Hashable {
        case document(name: String)
        case openAction
        case documentEvent(String)
        case page(Int, event: String)
        case annotation(page: Int?, event: String)
        case field(String, event: String)
    }

    var place: Place
    /// The first line of the script, trimmed.
    var excerpt: String

    var description: String {
        switch place {
        case .document(let name): "Document script “\(name)”"
        case .openAction: "Runs when the file opens"
        case .documentEvent(let event): "Runs on \(ScriptEntry.eventName(event))"
        case .page(let page, let event): "Page \(page + 1): runs on \(ScriptEntry.eventName(event))"
        case .annotation(let page, let event): page.map { "Page \($0 + 1): a link or button runs on \(ScriptEntry.eventName(event))" } ?? "A link or button runs on \(ScriptEntry.eventName(event))"
        case .field(let name, let event): "Form field “\(name)”: runs on \(event == "C" ? "calculation" : ScriptEntry.eventName(event))"
        }
    }

    static func eventName(_ key: String) -> String {
        switch key {
        case "O": "open"
        case "C": "close"
        case "WC": "closing the document"
        case "WS", "DS": "saving"
        case "WP", "DP": "printing"
        case "K": "a keystroke"
        case "F": "formatting"
        case "V": "validation"
        case "E": "the pointer entering"
        case "X": "the pointer leaving"
        case "D": "a press"
        case "U": "a release"
        case "Fo": "focus"
        case "Bl": "losing focus"
        case "A": "a click"
        default: key
        }
    }
}

enum ScriptScanner {
    /// Every script and action in the model.
    static func scripts(in model: PDFModel) -> [ScriptEntry] {
        var entries: [ScriptEntry] = []
        if let tree = model.root["Names"]?["JavaScript"] {
            for (key, value) in PDFNameTree.entries(of: tree) {
                entries.append(ScriptEntry(place: .document(name: PDFText.decode(key)), excerpt: excerpt(of: value["JS"])))
            }
        }
        if let open = model.root["OpenAction"], isJavaScript(open) { entries.append(ScriptEntry(place: .openAction, excerpt: excerpt(of: open["JS"]))) }
        if let aa = model.root["AA"] {
            for key in aa.keys { if let action = aa[key], isJavaScript(action) { entries.append(ScriptEntry(place: .documentEvent(key), excerpt: excerpt(of: action["JS"]))) } }
        }
        for (index, page) in model.pages.enumerated() {
            if let aa = page.object["AA"] {
                for key in aa.keys { if let action = aa[key], isJavaScript(action) { entries.append(ScriptEntry(place: .page(index, event: key), excerpt: excerpt(of: action["JS"]))) } }
            }
            for annotation in page.annotations {
                if let action = annotation["A"], isJavaScript(action), annotation["Subtype"]?.name != "Widget" || annotation["T"] == nil {
                    entries.append(ScriptEntry(place: .annotation(page: index, event: "A"), excerpt: excerpt(of: action["JS"])))
                }
                if let aa = annotation["AA"], annotation["Subtype"]?.name != "Widget" {
                    for key in aa.keys { if let action = aa[key], isJavaScript(action) { entries.append(ScriptEntry(place: .annotation(page: index, event: key), excerpt: excerpt(of: action["JS"]))) } }
                }
            }
        }
        for field in model.formFields() {
            if let aa = field.object["AA"] {
                for key in aa.keys { if let action = aa[key], isJavaScript(action) { entries.append(ScriptEntry(place: .field(field.name, event: key), excerpt: excerpt(of: action["JS"]))) } }
            }
            if let action = field.object["A"], isJavaScript(action) { entries.append(ScriptEntry(place: .field(field.name, event: "A"), excerpt: excerpt(of: action["JS"]))) }
            for widget in field.widgets where !widget.object.isSameObject(as: field.object) {
                if let aa = widget.object["AA"] {
                    for key in aa.keys { if let action = aa[key], isJavaScript(action) { entries.append(ScriptEntry(place: .field(field.name, event: key), excerpt: excerpt(of: action["JS"]))) } }
                }
                if let action = widget.object["A"], isJavaScript(action) { entries.append(ScriptEntry(place: .field(field.name, event: "A"), excerpt: excerpt(of: action["JS"]))) }
            }
        }
        return entries
    }

    /// Removes every script and action: the name tree, open and additional actions, annotation and field actions.
    /// Non-script actions (go to a page, open a link) stay. Returns how many went.
    @discardableResult
    static func removeScripts(from model: PDFModel) -> Int {
        let count = scripts(in: model).count
        model.root["Names"]?.remove("JavaScript")
        if let open = model.root["OpenAction"], isJavaScript(open) { model.root.remove("OpenAction") }
        strip(model.root["AA"])
        if model.root["AA"]?.keys.isEmpty == true { model.root.remove("AA") }
        for page in model.pages {
            strip(page.object["AA"])
            if page.object["AA"]?.keys.isEmpty == true { page.object.remove("AA") }
            for annotation in page.annotations {
                if let action = annotation["A"], isJavaScript(action) { annotation.remove("A") }
                strip(annotation["AA"])
                if annotation["AA"]?.keys.isEmpty == true { annotation.remove("AA") }
            }
        }
        for field in model.formFields() {
            strip(field.object["AA"])
            if field.object["AA"]?.keys.isEmpty == true { field.object.remove("AA") }
            if let action = field.object["A"], isJavaScript(action) { field.object.remove("A") }
        }
        // Calculation order points at fields whose scripts are gone.
        model.acroForm?.remove("CO")
        return count
    }

    private static func strip(_ aa: PDFObject?) {
        guard let aa else { return }
        for key in aa.keys where aa[key].map(isJavaScript) == true { aa.remove(key) }
    }

    /// A JavaScript action, or an action chain containing one.
    static func isJavaScript(_ action: PDFObject) -> Bool {
        if action["S"]?.name == "JavaScript" { return true }
        if let next = action["Next"] {
            if next.type == .array { return next.items.contains(where: isJavaScript) }
            return isJavaScript(next)
        }
        return false
    }

    private static func excerpt(of js: PDFObject?) -> String {
        guard let js else { return "" }
        let text = js.type == .stream ? (try? js.streamData(decode: .all)).map { String(decoding: $0, as: UTF8.self) } ?? "" : js.text ?? ""
        return text.split(separator: "\n").first.map { $0.trimmingCharacters(in: .whitespaces) } ?? ""
    }
}
