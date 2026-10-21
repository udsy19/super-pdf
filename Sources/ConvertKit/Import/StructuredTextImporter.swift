import AppKit
import SuperPDFCore

/// JSON and XML → PDF (features §3.2 "pretty-printed"): re-indented, keys in their original order, in a monospaced face.
/// Files that don't parse are printed as they are.
enum StructuredTextImporter {
    static func convert(_ input: URL, to output: URL, options: ImportOptions) throws -> ImportReport {
        let raw = try AttributedTextImporter.decodeText(at: input)
        let pretty = input.pathExtension.lowercased() == "json" ? prettyJSON(raw) : prettyXML(raw)
        guard !pretty.isEmpty else { throw ComposeError.nothingToConvert }
        let text = AttributedTextImporter.plainText(pretty, monospaced: true)
        try TextPaginator.write(text, to: output, paper: options.textPaper, margins: CGFloat(options.margins), title: String.baseName(input))
        return ImportReport()
    }

    /// Re-indents JSON by its tokens (two spaces a level), keeping key order and number spelling; text that isn't JSON
    /// comes back unchanged.
    static func prettyJSON(_ text: String) -> String {
        guard (try? JSONSerialization.jsonObject(with: Data(text.utf8), options: [.fragmentsAllowed])) != nil else { return text }
        var out = ""
        var depth = 0
        var inString = false, escaped = false
        let chars = Array(text)
        func newline() { out += "\n" + String(repeating: "  ", count: depth) }
        var i = 0
        while i < chars.count {
            let c = chars[i]
            defer { i += 1 }
            if inString {
                out.append(c)
                if escaped { escaped = false } else if c == "\\" { escaped = true } else if c == "\"" { inString = false }
                continue
            }
            switch c {
            case "\"":
                inString = true
                out.append(c)
            case "{", "[":
                out.append(c)
                // "{}" and "[]" stay on one line.
                var j = i + 1
                while j < chars.count, chars[j].isWhitespace { j += 1 }
                if j < chars.count, chars[j] == (c == "{" ? "}" : "]") {
                    out.append(chars[j]); i = j
                } else {
                    depth += 1; newline()
                }
            case "}", "]":
                depth = max(depth - 1, 0); newline(); out.append(c)
            case ",":
                out.append(c); newline()
            case ":":
                out += ": "
            default:
                if !c.isWhitespace { out.append(c) }
            }
        }
        return out
    }

    /// Re-indents XML with Foundation's tree; text that doesn't parse comes back unchanged.
    static func prettyXML(_ text: String) -> String {
        guard let document = try? XMLDocument(xmlString: text, options: [.nodeLoadExternalEntitiesNever, .nodePreserveCDATA, .nodePreserveEmptyElements])
        else { return text }
        return document.xmlString(options: [.nodePrettyPrint, .nodePreserveCDATA])
    }
}
