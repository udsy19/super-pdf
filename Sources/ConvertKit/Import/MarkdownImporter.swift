import Foundation
import SuperPDFCore

/// Markdown → PDF (features #46): Markdown → HTML here (blocks by our own parser, inline syntax by Foundation's
/// Markdown reader), then WebKit. Relative pictures load from the file's folder.
enum MarkdownImporter {
    @MainActor
    static func convert(_ input: URL, to output: URL, options: ImportOptions) async throws -> ImportReport {
        let source = try AttributedTextImporter.decodeText(at: input)
        let page = output.deletingLastPathComponent().appendingPathComponent("md-" + UUID().uuidString + ".html")
        defer { try? FileManager.default.removeItem(at: page) }
        let html = HTMLPage.document(title: String.baseName(input), body: Markdown.html(source),
                                     base: input.deletingLastPathComponent())
        try html.write(to: page, atomically: true, encoding: .utf8)
        try await WebRenderer.render(file: page, paper: options.textPaper, margins: CGFloat(options.margins), to: output,
                                     title: String.baseName(input))
        return ImportReport()
    }
}

/// The page around generated HTML (Markdown, mail, exported web pages): readable print typography in points.
enum HTMLPage {
    static let style = """
    :root { color-scheme: light; }
    body { font: 11px/1.45 -apple-system, "Helvetica Neue", Helvetica, sans-serif; color: #111; margin: 0; word-wrap: break-word; }
    h1 { font-size: 22px; margin: 0.6em 0 0.4em; } h2 { font-size: 17px; margin: 1em 0 0.4em; } h3 { font-size: 14px; margin: 1em 0 0.3em; }
    h4, h5, h6 { font-size: 12px; margin: 1em 0 0.3em; }
    p, ul, ol, table, pre, blockquote { margin: 0 0 0.7em; }
    a { color: #0b57d0; text-decoration: none; }
    code, pre { font-family: ui-monospace, Menlo, monospace; font-size: 9.5px; }
    code { background: #f2f2f2; padding: 0 2px; border-radius: 2px; }
    pre { background: #f5f5f5; padding: 6px 8px; border-radius: 4px; white-space: pre-wrap; }
    pre code { background: none; padding: 0; }
    blockquote { border-left: 3px solid #ccc; padding-left: 10px; color: #444; }
    table { border-collapse: collapse; } th, td { border: 1px solid #bbb; padding: 3px 6px; vertical-align: top; } th { background: #f2f2f2; }
    img { max-width: 100%; } hr { border: 0; border-top: 1px solid #ccc; }
    li > input[type=checkbox] { margin: 0 4px 0 0; }
    """

    static func document(title: String, body: String, base: URL? = nil, extraStyle: String = "") -> String {
        let baseTag = base.map { "<base href=\"\(XML.escape($0.absoluteURL.absoluteString.hasSuffix("/") ? $0.absoluteURL.absoluteString : $0.absoluteURL.absoluteString + "/"))\">" } ?? ""
        return """
        <!DOCTYPE html>
        <html><head><meta charset="utf-8">\(baseTag)<title>\(XML.escape(title))</title><style>\(style)\(extraStyle)</style></head>
        <body>
        \(body)
        </body></html>
        """
    }
}

/// CommonMark-style Markdown to HTML: headings (ATX and setext), paragraphs, block quotes, nested lists with task
/// boxes, fenced and indented code, rules, GitHub tables and raw HTML blocks.
enum Markdown {
    static func html(_ source: String) -> String {
        let lines = source.replacingOccurrences(of: "\r\n", with: "\n").replacingOccurrences(of: "\r", with: "\n")
            .replacingOccurrences(of: "\t", with: "    ").components(separatedBy: "\n")
        return blocks(lines[...])
    }

    private static func blocks(_ lines: ArraySlice<String>) -> String {
        var out = ""
        var i = lines.startIndex
        var paragraph: [String] = []
        func flush() {
            guard !paragraph.isEmpty else { return }
            out += "<p>" + inline(paragraph) + "</p>\n"
            paragraph = []
        }
        while i < lines.endIndex {
            let line = lines[i]
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            let indent = line.prefix { $0 == " " }.count

            if trimmed.isEmpty { flush(); i += 1; continue }

            // Fenced code.
            if let fence = ["```", "~~~"].first(where: { trimmed.hasPrefix($0) }) {
                flush()
                var code: [String] = []
                i += 1
                while i < lines.endIndex, !lines[i].trimmingCharacters(in: .whitespaces).hasPrefix(fence) { code.append(lines[i]); i += 1 }
                i += 1
                out += "<pre><code>" + XML.escape(code.joined(separator: "\n")) + "</code></pre>\n"
                continue
            }
            // Indented code (not inside a paragraph).
            if indent >= 4, paragraph.isEmpty {
                var code: [String] = []
                while i < lines.endIndex, lines[i].hasPrefix("    ") || lines[i].trimmingCharacters(in: .whitespaces).isEmpty {
                    code.append(String(lines[i].dropFirst(min(4, lines[i].count)))); i += 1
                }
                while code.last?.isEmpty == true { code.removeLast() }
                out += "<pre><code>" + XML.escape(code.joined(separator: "\n")) + "</code></pre>\n"
                continue
            }
            // ATX heading.
            if let level = atxLevel(trimmed) {
                flush()
                let text = trimmed.dropFirst(level).trimmingCharacters(in: .whitespaces)
                    .replacingOccurrences(of: #"\s+#+\s*$"#, with: "", options: .regularExpression)
                out += "<h\(level)>" + inline([text]) + "</h\(level)>\n"
                i += 1
                continue
            }
            // Setext heading underline.
            if !paragraph.isEmpty, trimmed.allSatisfy({ $0 == "=" }) || (trimmed.allSatisfy({ $0 == "-" }) && trimmed.count >= 2) {
                let level = trimmed.first == "=" ? 1 : 2
                out += "<h\(level)>" + inline(paragraph) + "</h\(level)>\n"
                paragraph = []
                i += 1
                continue
            }
            // Rule.
            if isRule(trimmed) { flush(); out += "<hr>\n"; i += 1; continue }
            // Block quote.
            if trimmed.hasPrefix(">") {
                flush()
                var inner: [String] = []
                while i < lines.endIndex, lines[i].trimmingCharacters(in: .whitespaces).hasPrefix(">") {
                    var text = lines[i].trimmingCharacters(in: .whitespaces).dropFirst()
                    if text.hasPrefix(" ") { text = text.dropFirst() }
                    inner.append(String(text)); i += 1
                }
                out += "<blockquote>\n" + blocks(inner[...]) + "</blockquote>\n"
                continue
            }
            // Table: a header row followed by a delimiter row.
            if trimmed.contains("|"), i + 1 < lines.endIndex, isTableDelimiter(lines[i + 1]) {
                flush()
                let alignments = cells(lines[i + 1]).map { cell -> String in
                    let c = cell.trimmingCharacters(in: .whitespaces)
                    return c.hasPrefix(":") && c.hasSuffix(":") ? "center" : c.hasSuffix(":") ? "right" : "left"
                }
                func row(_ line: String, tag: String) -> String {
                    "<tr>" + cells(line).enumerated().map { index, cell in
                        let align = index < alignments.count ? alignments[index] : "left"
                        return "<\(tag) style=\"text-align:\(align)\">" + inline([cell.trimmingCharacters(in: .whitespaces)]) + "</\(tag)>"
                    }.joined() + "</tr>"
                }
                var table = "<table><thead>" + row(lines[i], tag: "th") + "</thead><tbody>"
                i += 2
                while i < lines.endIndex, lines[i].contains("|"), !lines[i].trimmingCharacters(in: .whitespaces).isEmpty {
                    table += row(lines[i], tag: "td"); i += 1
                }
                out += table + "</tbody></table>\n"
                continue
            }
            // List.
            if listMarker(line) != nil {
                flush()
                let (html, next) = list(lines, from: i)
                out += html
                i = next
                continue
            }
            // Raw HTML block.
            if paragraph.isEmpty, trimmed.hasPrefix("<"), trimmed.range(of: #"^</?[A-Za-z][A-Za-z0-9-]*[\s/>]"#, options: .regularExpression) != nil {
                while i < lines.endIndex, !lines[i].trimmingCharacters(in: .whitespaces).isEmpty { out += lines[i] + "\n"; i += 1 }
                continue
            }
            paragraph.append(line)
            i += 1
        }
        flush()
        return out
    }

    /// A list starting at `start`: items with their continuation lines; deeper-indented lists nest.
    private static func list(_ lines: ArraySlice<String>, from start: Int) -> (String, Int) {
        guard let first = listMarker(lines[start]) else { return ("", start + 1) }
        let tag = first.ordered ? "ol" : "ul"
        var out = first.ordered && first.number != 1 ? "<\(tag) start=\"\(first.number)\">\n" : "<\(tag)>\n"
        var i = start
        while i < lines.endIndex, let marker = listMarker(lines[i]), marker.indent == first.indent, marker.ordered == first.ordered {
            var item: [String] = [String(lines[i].dropFirst(marker.contentOffset))]
            i += 1
            while i < lines.endIndex {
                let line = lines[i]
                let trimmed = line.trimmingCharacters(in: .whitespaces)
                let indent = line.prefix { $0 == " " }.count
                if trimmed.isEmpty {
                    // A blank line ends the item unless the next line is indented under it.
                    if i + 1 < lines.endIndex, lines[i + 1].prefix(while: { $0 == " " }).count > first.indent,
                       !lines[i + 1].trimmingCharacters(in: .whitespaces).isEmpty {
                        item.append(""); i += 1; continue
                    }
                    break
                }
                if let next = listMarker(line), next.indent <= first.indent { _ = next; break }
                if indent <= first.indent, listMarker(line) == nil, isRule(trimmed) || atxLevel(trimmed) != nil { break }
                item.append(String(line.dropFirst(min(indent, marker.contentOffset))))
                i += 1
            }
            var body = item.count == 1 ? inline(item) : blocks(item[...])
            if item.count > 1, !item.dropFirst().contains(where: { $0.isEmpty }), body.hasPrefix("<p>") {
                // Tight item: no paragraph around its first line.
                body = body.replacingOccurrences(of: "<p>", with: "", options: .anchored)
                if let end = body.range(of: "</p>\n") { body.replaceSubrange(end, with: "\n") }
            }
            let task: String
            if body.hasPrefix("[ ] ") { task = "<input type=\"checkbox\" disabled>"; body = String(body.dropFirst(4)) }
            else if body.lowercased().hasPrefix("[x] ") { task = "<input type=\"checkbox\" checked disabled>"; body = String(body.dropFirst(4)) }
            else { task = "" }
            out += "<li>" + task + body + "</li>\n"
            while i < lines.endIndex, lines[i].trimmingCharacters(in: .whitespaces).isEmpty,
                  i + 1 < lines.endIndex, listMarker(lines[i + 1])?.indent == first.indent { i += 1 }
        }
        return (out + "</\(tag)>\n", max(i, start + 1))
    }

    private struct ListMarker { var indent: Int; var ordered: Bool; var number: Int; var contentOffset: Int }

    private static func listMarker(_ line: String) -> ListMarker? {
        let indent = line.prefix { $0 == " " }.count
        let rest = line.dropFirst(indent)
        if let c = rest.first, "-*+".contains(c), rest.dropFirst().first == " ", !isRule(rest.trimmingCharacters(in: .whitespaces)) {
            return ListMarker(indent: indent, ordered: false, number: 1, contentOffset: indent + 2)
        }
        let digits = rest.prefix { $0.isNumber }
        if !digits.isEmpty, digits.count <= 9, let mark = rest.dropFirst(digits.count).first, mark == "." || mark == ")",
           rest.dropFirst(digits.count + 1).first == " " {
            return ListMarker(indent: indent, ordered: true, number: Int(digits) ?? 1, contentOffset: indent + digits.count + 2)
        }
        return nil
    }

    private static func atxLevel(_ trimmed: String) -> Int? {
        let hashes = trimmed.prefix { $0 == "#" }.count
        guard (1...6).contains(hashes), trimmed.count == hashes || trimmed.dropFirst(hashes).first == " " else { return nil }
        return hashes
    }

    private static func isRule(_ trimmed: String) -> Bool {
        let compact = trimmed.replacingOccurrences(of: " ", with: "")
        guard compact.count >= 3, let c = compact.first, "-*_".contains(c) else { return false }
        return compact.allSatisfy { $0 == c }
    }

    private static func isTableDelimiter(_ line: String) -> Bool {
        let parts = cells(line)
        return !parts.isEmpty && line.contains("-") && parts.allSatisfy {
            $0.trimmingCharacters(in: .whitespaces).range(of: #"^:?-+:?$"#, options: .regularExpression) != nil
        }
    }

    private static func cells(_ line: String) -> [String] {
        var text = line.trimmingCharacters(in: .whitespaces)
        if text.hasPrefix("|") { text.removeFirst() }
        if text.hasSuffix("|") && !text.hasSuffix("\\|") { text.removeLast() }
        var cells: [String] = [], current = "", escaped = false
        for c in text {
            if escaped { current.append(c); escaped = false; continue }
            if c == "\\" { escaped = true; current.append(c); continue }
            if c == "|" { cells.append(current); current = "" } else { current.append(c) }
        }
        cells.append(current)
        return cells
    }

    /// Inline Markdown of a paragraph's lines (soft breaks become spaces, two trailing spaces a line break), through
    /// Foundation's reader.
    static func inline(_ lines: [String]) -> String {
        let breakMark = "\u{2028}"
        let joined = lines.enumerated().map { index, line -> String in
            let hard = line.hasSuffix("  ") || line.hasSuffix("\\")
            let text = line.trimmingCharacters(in: .whitespaces)
            let clean = hard && text.hasSuffix("\\") ? String(text.dropLast()) : text
            return clean + (index < lines.count - 1 ? (hard ? breakMark : " ") : "")
        }.joined()
        guard let attributed = try? AttributedString(markdown: joined, options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace,
                                                                                     failurePolicy: .returnPartiallyParsedIfPossible)) else {
            return XML.escape(joined).replacingOccurrences(of: breakMark, with: "<br>")
        }
        var out = ""
        for run in attributed.runs {
            let text = String(attributed[run.range].characters)
            if let image = run.imageURL {
                out += "<img src=\"\(XML.escape(image.relativeString))\" alt=\"\(XML.escape(text))\">"
                continue
            }
            var piece = XML.escape(text).replacingOccurrences(of: breakMark, with: "<br>")
            let intent = run.inlinePresentationIntent ?? []
            if intent.contains(.code) { piece = "<code>\(piece)</code>" }
            if intent.contains(.stronglyEmphasized) { piece = "<strong>\(piece)</strong>" }
            if intent.contains(.emphasized) { piece = "<em>\(piece)</em>" }
            if intent.contains(.strikethrough) { piece = "<del>\(piece)</del>" }
            if let link = run.link { piece = "<a href=\"\(XML.escape(link.relativeString))\">\(piece)</a>" }
            out += piece
        }
        return out
    }
}
