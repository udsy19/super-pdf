import Foundation
import PDFModelKit
import SuperPDFCore

/// Form answers as files (features #59). ConvertKit writes FDF, XFDF and JSON out of a PDF (`Services.convert`);
/// FormsKit writes CSV (a row of names over a row of values, as Acrobat's "Export data" does) and reads all four back
/// into a form. Values are by fully qualified field name; tick boxes carry their state name or "Off".
enum FormData {
    enum Failure: Error, Equatable { case unreadable }

    static func csv(_ values: [(name: String, value: String)]) -> Data {
        let header = values.map { csvField($0.name) }.joined(separator: ",")
        let row = values.map { csvField($0.value) }.joined(separator: ",")
        return Data((header + "\r\n" + row + "\r\n").utf8)
    }

    static func decode(_ data: Data, as format: FormDataFormat) throws -> [String: String] {
        let values: [String: String]?
        switch format {
        case .json: values = json(data)
        case .csv: values = csv(data)
        case .xfdf: values = XFDFReader.read(data)
        case .fdf: values = fdf(data)
        }
        guard let values, !values.isEmpty else { throw Failure.unreadable }
        return values
    }

    /// The format a file's extension names.
    static func format(of url: URL) -> FormDataFormat? { FormDataFormat(rawValue: url.pathExtension.lowercased()) }

    // MARK: JSON and CSV

    private static func json(_ data: Data) -> [String: String]? {
        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return nil }
        var values: [String: String] = [:]
        for (name, value) in object {
            switch value {
            case let text as String: values[name] = text
            case let list as [String]: values[name] = list.first ?? ""
            case let number as NSNumber:
                values[name] = CFGetTypeID(number) == CFBooleanGetTypeID() ? (number.boolValue ? "Yes" : "Off") : number.stringValue
            default: continue
            }
        }
        return values
    }

    private static func csvField(_ text: String) -> String {
        text.contains(where: { $0 == "," || $0 == "\"" || $0 == "\n" || $0 == "\r" }) ? "\"" + text.replacingOccurrences(of: "\"", with: "\"\"") + "\"" : text
    }

    private static func csv(_ data: Data) -> [String: String]? {
        guard let text = String(data: data, encoding: .utf8) ?? String(data: data, encoding: .isoLatin1) else { return nil }
        let rows = csvRows(text.hasPrefix("\u{FEFF}") ? String(text.dropFirst()) : text).filter { !($0.count == 1 && $0[0].isEmpty) }
        guard rows.count >= 2 else { return nil }
        let names = rows[0], row = rows[1]
        var values: [String: String] = [:]
        for (i, name) in names.enumerated() where !name.isEmpty { values[name] = i < row.count ? row[i] : "" }
        return values
    }

    private static func csvRows(_ text: String) -> [[String]] {
        var rows: [[String]] = [], row: [String] = [], field = ""
        var quoted = false
        var iterator = Array(text).makeIterator()
        var pending: Character? = nil
        while let ch = pending ?? iterator.next() {
            pending = nil
            if quoted {
                if ch == "\"" {
                    if let next = iterator.next() { if next == "\"" { field.append("\"") } else { quoted = false; pending = next } } else { quoted = false }
                } else { field.append(ch) }
            } else if ch == "\"" { quoted = true } else if ch == "," { row.append(field); field = "" } else if ch == "\n" || ch == "\r\n" || ch == "\r" {
                row.append(field); rows.append(row); row = []; field = ""
            } else { field.append(ch) }
        }
        if !field.isEmpty || !row.isEmpty { row.append(field); rows.append(row) }
        return rows
    }

    // MARK: XFDF

    private final class XFDFReader: NSObject, XMLParserDelegate {
        var path: [String] = []
        var values: [String: String] = [:]
        var text: String?

        static func read(_ data: Data) -> [String: String]? {
            let reader = XFDFReader()
            let parser = XMLParser(data: data)
            parser.delegate = reader
            guard parser.parse() else { return nil }
            return reader.values
        }

        func parser(_ parser: XMLParser, didStartElement element: String, namespaceURI: String?, qualifiedName: String?, attributes: [String: String] = [:]) {
            switch element {
            case "field": path.append(attributes["name"] ?? "")
            case "value": text = ""
            default: break
            }
        }

        func parser(_ parser: XMLParser, foundCharacters string: String) { text?.append(string) }

        func parser(_ parser: XMLParser, didEndElement element: String, namespaceURI: String?, qualifiedName: String?) {
            switch element {
            case "field": _ = path.popLast()
            case "value" where !path.isEmpty:
                let name = path.joined(separator: ".")
                // A list with several choices has a <value> each; the first is kept.
                if values[name] == nil { values[name] = text ?? "" }
                text = nil
            default: break
            }
        }
    }

    // MARK: FDF

    /// Reads /FDF /Fields (with /Kids) from the file's objects; values that are names (tick boxes) or text.
    private static func fdf(_ data: Data) -> [String: String]? {
        guard data.starts(with: Data("%FDF".utf8)) else { return nil }
        let operations = PDFContentStream(parsing: data).operations
        guard let fields = operations.lazy.flatMap(\.operands).compactMap({ $0["FDF"]?["Fields"]?.arrayValue }).first else { return nil }
        var values: [String: String] = [:]
        func visit(_ items: [PDFValue], prefix: String) {
            for item in items {
                guard let partial = item["T"]?.textValue else { continue }
                let name = prefix.isEmpty ? partial : prefix + "." + partial
                switch item["V"] {
                case .name(let state)?: values[name] = state
                case .string(let bytes)?: values[name] = PDFText.decode(bytes)
                case .array(let list)?: values[name] = list.first?.textValue ?? list.first?.nameValue ?? ""
                default: break
                }
                if let kids = item["Kids"]?.arrayValue { visit(kids, prefix: name) }
            }
        }
        visit(fields, prefix: "")
        return values
    }
}
