import CoreGraphics
import CoreText
import Foundation
import SuperPDFCore

// CSV/TSV → PDF, built in (features #43): the delimiter and the text encoding are detected, quoted fields may hold
// delimiters, quotes and line breaks (RFC 4180), and the table is drawn with the header row in bold at the top of
// every page, numbers on the right, landscape when it is wide.

enum DelimitedTextImporter {
    static let maxRows = 200_000
    static let maxColumns = 500
    static let fontSize: CGFloat = 9

    static func convert(_ input: URL, to output: URL, options: ImportOptions) throws -> ImportReport {
        let data = try Data(contentsOf: input, options: .mappedIfSafe)
        let text = SheetDelimited.decode(data)
        let delimiter: Unicode.Scalar = input.pathExtension.lowercased() == "tsv" ? "\t" : SheetDelimited.detectDelimiter(text)
        let parsed = SheetDelimited.parse(text, delimiter: delimiter, maxRows: maxRows, maxColumns: maxColumns)
        guard parsed.rows.contains(where: { $0.contains { !$0.isEmpty } }) else { throw SheetImportError.empty }
        let grid = SheetDelimited.grid(parsed.rows, name: String.baseName(input))
        _ = try SheetRenderer.render([grid], paper: options.textPaper, margins: CGFloat(options.margins), title: String.baseName(input), to: output)
        var report = ImportReport()
        if parsed.truncated {
            report.notices.append("\(Strings.quoted(input.lastPathComponent)) is very large, so only its first \(maxRows.formatted()) rows and \(maxColumns) columns are in the PDF.")
        }
        return report
    }
}

enum SheetDelimited {
    /// Text from bytes: a byte-order mark decides; else UTF-8 when valid; else Windows-1252, then Mac Roman.
    static func decode(_ data: Data) -> String {
        if data.starts(with: [0xEF, 0xBB, 0xBF]) { return String(decoding: data.dropFirst(3), as: UTF8.self) }
        if data.starts(with: [0xFF, 0xFE]), let text = String(data: data.dropFirst(2), encoding: .utf16LittleEndian) { return text }
        if data.starts(with: [0xFE, 0xFF]), let text = String(data: data.dropFirst(2), encoding: .utf16BigEndian) { return text }
        if let text = String(data: data, encoding: .utf8) { return text }
        // UTF-16 without a mark: every other byte is zero in mostly-ASCII text.
        let sample = data.prefix(4096)
        if sample.count >= 4 {
            let odd = stride(from: 1, to: sample.count, by: 2).filter { sample[sample.startIndex + $0] == 0 }.count
            let even = stride(from: 0, to: sample.count, by: 2).filter { sample[sample.startIndex + $0] == 0 }.count
            if odd > sample.count / 4, let text = String(data: data, encoding: .utf16LittleEndian) { return text }
            if even > sample.count / 4, let text = String(data: data, encoding: .utf16BigEndian) { return text }
        }
        if let text = String(data: data, encoding: .windowsCP1252) { return text }
        if let text = String(data: data, encoding: .macOSRoman) { return text }
        return String(decoding: data, as: UTF8.self)
    }

    /// The delimiter that splits the first lines most consistently: comma, semicolon, tab or pipe.
    static func detectDelimiter(_ text: String) -> Unicode.Scalar {
        let candidates: [Unicode.Scalar] = [",", ";", "\t", "|"]
        var counts: [[Int]] = Array(repeating: [], count: candidates.count)
        var current = Array(repeating: 0, count: candidates.count)
        var inQuotes = false, lines = 0
        for scalar in text.unicodeScalars {
            if scalar == "\"" { inQuotes.toggle(); continue }
            if inQuotes { continue }
            if scalar == "\n" {
                for i in candidates.indices { counts[i].append(current[i]) }
                current = Array(repeating: 0, count: candidates.count)
                lines += 1
                if lines >= 50 { break }
                continue
            }
            if let index = candidates.firstIndex(of: scalar) { current[index] += 1 }
        }
        if lines < 50, current.contains(where: { $0 > 0 }) { for i in candidates.indices { counts[i].append(current[i]) } }
        var best: (score: Int, mode: Int, index: Int) = (0, 0, 0)
        for (i, perLine) in counts.enumerated() {
            let nonZero = perLine.filter { $0 > 0 }
            guard !nonZero.isEmpty else { continue }
            var frequency: [Int: Int] = [:]
            for n in nonZero { frequency[n, default: 0] += 1 }
            let mode = frequency.max { $0.value == $1.value ? $0.key < $1.key : $0.value < $1.value }!
            let score = mode.value
            if score > best.score || score == best.score && mode.key > best.mode { best = (score, mode.key, i) }
        }
        return candidates[best.index]
    }

    struct Parsed {
        var rows: [[String]]
        var truncated: Bool
    }

    /// RFC 4180: quoted fields may hold the delimiter, doubled quotes and line breaks; CRLF, LF and CR end rows.
    static func parse(_ text: String, delimiter: Unicode.Scalar, maxRows: Int, maxColumns: Int) -> Parsed {
        var rows: [[String]] = []
        var row: [String] = []
        var field = String.UnicodeScalarView()
        var inQuotes = false, quotedField = false, truncated = false
        let scalars = Array(text.unicodeScalars)
        var i = 0
        func endField() {
            if row.count < maxColumns { row.append(String(field)) } else { truncated = true }
            field = String.UnicodeScalarView()
            quotedField = false
        }
        func endRow() {
            endField()
            rows.append(row)
            row = []
        }
        while i < scalars.count {
            let c = scalars[i]
            if inQuotes {
                if c == "\"" {
                    if i + 1 < scalars.count, scalars[i + 1] == "\"" { field.append("\""); i += 1 } else { inQuotes = false }
                } else if field.count < 100_000 {
                    field.append(c)
                }
            } else if c == "\"" && field.isEmpty && !quotedField {
                inQuotes = true
                quotedField = true
            } else if c == delimiter {
                endField()
            } else if c == "\n" || c == "\r" {
                if c == "\r", i + 1 < scalars.count, scalars[i + 1] == "\n" { i += 1 }
                endRow()
                if rows.count >= maxRows { truncated = i + 1 < scalars.count; break }
            } else if field.count < 100_000 {
                field.append(c)
            }
            i += 1
        }
        if rows.count < maxRows, !field.isEmpty || !row.isEmpty || quotedField { endRow() }
        // Blank lines at the end aren't rows.
        while let last = rows.last, last.allSatisfy(\.isEmpty) { rows.removeLast() }
        return Parsed(rows: rows, truncated: truncated)
    }

    /// Whether a field reads as a number ("1,234.5", "-12", "12%", "$9.99", "(3.50)").
    static func isNumber(_ text: String) -> Bool {
        var s = Substring(text.trimmingCharacters(in: .whitespaces))
        if s.hasPrefix("("), s.hasSuffix(")") { s = s.dropFirst().dropLast() }
        if let first = s.first, "$€£¥-+".contains(first) { s = s.dropFirst() }
        if let first = s.first, "$€£¥".contains(first) { s = s.dropFirst() }
        if s.hasSuffix("%") { s = s.dropLast() }
        guard !s.isEmpty, s.contains(where: \.isNumber) else { return false }
        return s.allSatisfy { $0.isASCII && ($0.isNumber || $0 == "." || $0 == ",") }
    }

    /// The table: the first row bold and repeated on every page, columns as wide as their text (up to three inches,
    /// longer text wraps), numbers on the right.
    static func grid(_ rows: [[String]], name: String) -> SheetGrid {
        let size = DelimitedTextImporter.fontSize
        let body = SheetStyle(font: SheetFont(name: nil, size: size), vertical: .top)
        var bodyWrap = body; bodyWrap.wrap = true
        var header = body; header.font.bold = true
        var headerWrap = header; headerWrap.wrap = true
        let styles = [body, bodyWrap, header, headerWrap]
        let columnCount = rows.map(\.count).max() ?? 0
        var fonts = SheetFonts()
        let minWidth: CGFloat = 28, maxWidth: CGFloat = 216, pad = 2 * SheetRenderer.padding + 2
        // An upper bound on a character's width, so most fields need no measuring.
        let charLimit = size * 0.7
        var widths = Array(repeating: minWidth, count: columnCount)
        for (r, row) in rows.enumerated() where r < 2000 || r % 50 == 0 {
            for (c, text) in row.enumerated() where !text.isEmpty {
                let lines = text.split(separator: Character("\n"), omittingEmptySubsequences: false)
                let longest = lines.max { $0.count < $1.count }.map(String.init) ?? text
                let guess = CGFloat(longest.count) * charLimit + pad
                guard guess > widths[c] else { continue }
                let measured = fonts.width(longest, r == 0 ? header.font : body.font) + pad
                widths[c] = min(max(widths[c], measured), maxWidth)
            }
        }
        var sheetRows: [SheetRow] = []
        sheetRows.reserveCapacity(rows.count)
        for (r, row) in rows.enumerated() {
            let isHeader = r == 0 && rows.count > 1
            var cells: [SheetCell?] = []
            cells.reserveCapacity(row.count)
            for (c, text) in row.enumerated() {
                guard !text.isEmpty else { cells.append(nil); continue }
                let number = !isHeader && isNumber(text)
                var wraps = text.contains("\n") || text.contains("\r")
                if !wraps, !number, CGFloat(text.count) * charLimit + pad > widths[c] {
                    wraps = fonts.width(text, isHeader ? header.font : body.font) + pad > widths[c]
                }
                cells.append(SheetCell(text: text, style: (isHeader ? 2 : 0) + (wraps ? 1 : 0), isNumber: number))
            }
            sheetRows.append(SheetRow(height: nil, cells: cells))
        }
        var grid = SheetGrid(name: name, styles: styles, columns: widths, rows: sheetRows)
        grid.repeatRows = rows.count > 1 ? 1 : 0
        grid.defaultRowHeight = ceil(fonts.lineHeight(body.font)) + 2
        return grid
    }
}
