import Foundation
import SuperPDFCore

// PDF → Excel (features #51): an own .xlsx writer over LayoutKit's tables, one sheet per table or per page, numbers
// stored as numbers with a matching number format, the header row in bold; when the file has no tables, all its text
// on one sheet (lines → rows, words split into cells at wide gaps). And .csv (RFC 4180, UTF-8 with a byte-order mark).

enum SpreadsheetWriter {
    static func writeXLSX(_ layout: LayoutDocument, oneSheetPerTable: Bool, to url: URL) throws {
        let sheets = OfficeSheets.sheets(layout, oneSheetPerTable: oneSheetPerTable)
        try OfficeXLSX.package(sheets, title: url.deletingPathExtension().lastPathComponent).write(to: url, options: .atomic)
    }

    static func writeCSV(_ layout: LayoutDocument, to url: URL) throws {
        var text = "\u{FEFF}"
        for row in OfficeSheets.csvRows(layout) {
            text += row.map(OfficeCSV.field).joined(separator: ",") + "\r\n"
        }
        try Data(text.utf8).write(to: url, options: .atomic)
    }
}

/// One sheet: rows of cells (nil = empty), merged ranges, rows in bold.
struct OfficeSheet {
    struct Merge: Hashable { var row: Int; var column: Int; var lastRow: Int; var lastColumn: Int }

    var name: String
    var rows: [[String?]] = []
    var merges: [Merge] = []
    var boldRows: Set<Int> = []

    /// Appends a table's grid: text in each cell's first position, spans merged.
    mutating func append(_ table: LayoutTable) {
        let top = rows.count
        let width = max(table.columnCount, 1)
        rows += [[String?]](repeating: [String?](repeating: nil, count: width), count: max(table.rowCount, 1))
        for cell in table.cells where cell.row < table.rowCount && cell.column < width {
            rows[top + cell.row][cell.column] = cell.text.replacingOccurrences(of: "\n", with: " ")
            if cell.rowSpan > 1 || cell.columnSpan > 1 {
                merges.append(Merge(row: top + cell.row, column: cell.column,
                                    lastRow: top + min(cell.row + cell.rowSpan, table.rowCount) - 1,
                                    lastColumn: min(cell.column + cell.columnSpan, width) - 1))
            }
        }
        if table.hasHeaderRow { boldRows.insert(top) }
    }
}

enum OfficeSheets {
    static func sheets(_ layout: LayoutDocument, oneSheetPerTable: Bool) -> [OfficeSheet] {
        var sheets: [OfficeSheet] = []
        let hasTables = layout.pages.contains { !$0.tables.isEmpty }
        if oneSheetPerTable {
            if hasTables {
                for page in layout.pages {
                    for table in OfficeDocxBuilder.tablesInOrder(page) {
                        var sheet = OfficeSheet(name: "Table \(sheets.count + 1)")
                        sheet.append(table)
                        sheets.append(sheet)
                    }
                }
            } else {
                var sheet = OfficeSheet(name: "Text")
                for (index, page) in layout.pages.enumerated() {
                    if index > 0, !sheet.rows.isEmpty { sheet.rows.append([]) }
                    sheet.rows += textRows(page)
                }
                sheets.append(sheet)
            }
        } else {
            for page in layout.pages {
                var sheet = OfficeSheet(name: "Page \(page.index + 1)")
                let tables = OfficeDocxBuilder.tablesInOrder(page)
                if tables.isEmpty {
                    sheet.rows = textRows(page)
                } else {
                    for (index, table) in tables.enumerated() {
                        if index > 0 { sheet.rows.append([]) }
                        sheet.append(table)
                    }
                }
                sheets.append(sheet)
            }
        }
        if sheets.isEmpty { sheets.append(OfficeSheet(name: "Sheet1")) }
        return uniqueNames(sheets)
    }

    /// The CSV's rows: every table in order with a blank line between; all text when there are none.
    static func csvRows(_ layout: LayoutDocument) -> [[String]] {
        var rows: [[String]] = []
        let tables = layout.pages.flatMap(OfficeDocxBuilder.tablesInOrder)
        if tables.isEmpty {
            for page in layout.pages { rows += textRows(page).map { $0.map { $0 ?? "" } } }
            return rows
        }
        for (index, table) in tables.enumerated() {
            if index > 0 { rows.append([]) }
            var sheet = OfficeSheet(name: "")
            sheet.append(table)
            rows += sheet.rows.map { $0.map { $0 ?? "" } }
        }
        return rows
    }

    /// A page's text as rows: each line a row, its words split into cells where the gap is wider than the font size.
    static func textRows(_ page: LayoutPage) -> [[String?]] {
        var rows: [[String?]] = []
        for block in OfficeDocxBuilder.blocksInOrder(page) {
            for line in block.lines {
                var cells: [String] = []
                var previous: LayoutWord?
                for word in line.words {
                    if let previous, word.bounds.minX - previous.bounds.maxX <= max(word.fontSize, previous.fontSize, 4), !cells.isEmpty {
                        cells[cells.count - 1] += " " + word.text
                    } else {
                        cells.append(word.text)
                    }
                    previous = word
                }
                if !cells.isEmpty { rows.append(cells) }
            }
        }
        return rows
    }

    /// Excel's sheet-name rules: no []:*?/\, at most 31 characters, not empty, unique without regard to case.
    static func uniqueNames(_ sheets: [OfficeSheet]) -> [OfficeSheet] {
        var used: Set<String> = []
        return sheets.map { sheet in
            var sheet = sheet
            var base = String(sheet.name.filter { !"[]:*?/\\".contains($0) }.trimmingCharacters(in: CharacterSet(charactersIn: "' ")).prefix(31))
            if base.isEmpty { base = "Sheet" }
            var name = base
            var n = 2
            while used.contains(name.lowercased()) {
                let suffix = " \(n)"
                name = String(base.prefix(31 - suffix.count)) + suffix
                n += 1
            }
            used.insert(name.lowercased())
            sheet.name = name
            return sheet
        }
    }
}

/// Numbers as printed ("1,234.50", "(12)", "$9.99", "12%", "12,5") → the value and an Excel number format that prints
/// it the same way; nil for text (including codes with leading zeros, phone numbers and over-long digit runs).
enum OfficeNumber {
    struct Parsed: Equatable {
        var value: Double
        /// nil: General.
        var format: String?
    }

    static func parse(_ text: String) -> Parsed? {
        var s = text.trimmingCharacters(in: .whitespacesAndNewlines).replacingOccurrences(of: "\u{2212}", with: "-")
            .replacingOccurrences(of: "\u{00A0}", with: "").replacingOccurrences(of: "\u{202F}", with: "")
        guard !s.isEmpty, s.count <= 32 else { return nil }
        var negative = false, parentheses = false, percent = false
        var currency: (symbol: String, before: Bool)?
        if s.hasPrefix("("), s.hasSuffix(")") { parentheses = true; negative = true; s = String(s.dropFirst().dropLast()).trimmingCharacters(in: .whitespaces) }
        if s.hasSuffix("%") { percent = true; s = String(s.dropLast()).trimmingCharacters(in: .whitespaces) }
        if s.hasPrefix("-") { negative.toggle(); s = String(s.dropFirst()).trimmingCharacters(in: .whitespaces) }
        for symbol in ["$", "€", "£", "¥", "₹"] {
            if s.hasPrefix(symbol) { currency = (symbol, true); s = String(s.dropFirst()).trimmingCharacters(in: .whitespaces); break }
            if s.hasSuffix(symbol) { currency = (symbol, false); s = String(s.dropLast()).trimmingCharacters(in: .whitespaces); break }
        }
        if s.hasPrefix("-") { negative.toggle(); s = String(s.dropFirst()) }
        guard !s.isEmpty, s.first!.isNumber || s.first == "." else { return nil }

        var thousands = false
        var normalized: String
        if s.range(of: #"^\d{1,3}(,\d{3})+(\.\d+)?$"#, options: .regularExpression) != nil {
            thousands = true; normalized = s.replacingOccurrences(of: ",", with: "")
        } else if s.range(of: #"^\d{1,3}(\.\d{3})+(,\d+)?$"#, options: .regularExpression) != nil {
            thousands = true; normalized = s.replacingOccurrences(of: ".", with: "").replacingOccurrences(of: ",", with: ".")
        } else if s.range(of: #"^\d+,\d{1,2}$"#, options: .regularExpression) != nil {
            normalized = s.replacingOccurrences(of: ",", with: ".")
        } else if s.range(of: #"^(\d+(\.\d*)?|\.\d+)$"#, options: .regularExpression) != nil {
            normalized = s
        } else {
            return nil
        }
        let integerPart = normalized.split(separator: ".", omittingEmptySubsequences: false).first.map(String.init) ?? ""
        if integerPart.count > 1, integerPart.hasPrefix("0") { return nil }
        guard normalized.filter(\.isNumber).count <= 15, var value = Double(normalized) else { return nil }
        let decimals = normalized.split(separator: ".", omittingEmptySubsequences: false).dropFirst().first?.count ?? 0
        if negative { value = -value }
        if percent { value /= 100 }

        guard thousands || decimals > 0 || percent || currency != nil || parentheses else { return Parsed(value: value, format: nil) }
        var body = (thousands ? "#,##0" : "0") + (decimals > 0 ? "." + String(repeating: "0", count: decimals) : "")
        if percent { body += "%" }
        if let currency {
            let quoted = "\"\(currency.symbol)\""
            body = currency.before ? quoted + body : body + quoted
        }
        return Parsed(value: value, format: parentheses ? "\(body);(\(body))" : body)
    }
}

enum OfficeCSV {
    /// A field quoted when it holds a comma, quote, line break or edge spaces (RFC 4180).
    static func field(_ text: String) -> String {
        guard text.contains(where: { $0 == "," || $0 == "\"" || $0 == "\n" || $0 == "\r" }) || text.hasPrefix(" ") || text.hasSuffix(" ") else { return text }
        return "\"" + text.replacingOccurrences(of: "\"", with: "\"\"") + "\""
    }
}

enum OfficeXLSX {
    static let builtInFormats: [String: Int] = ["0": 1, "0.00": 2, "#,##0": 3, "#,##0.00": 4, "0%": 9, "0.00%": 10]

    /// "A", "Z", "AA"…
    static func column(_ index: Int) -> String {
        var n = index + 1, name = ""
        while n > 0 {
            let r = (n - 1) % 26
            name = String(UnicodeScalar(65 + r)!) + name
            n = (n - 1) / 26
        }
        return name
    }

    static func package(_ sheets: [OfficeSheet], title: String) -> Data {
        // Styles: index 0 default; one entry per (number format, bold) pair met.
        var customFormats: [String: Int] = [:]
        var xfs: [(numFmt: Int, bold: Bool)] = [(0, false)]
        func style(format: String?, bold: Bool) -> Int {
            var id = 0
            if let format {
                if let builtIn = builtInFormats[format] { id = builtIn } else {
                    if customFormats[format] == nil { customFormats[format] = 164 + customFormats.count }
                    id = customFormats[format]!
                }
            }
            if let index = xfs.firstIndex(where: { $0.numFmt == id && $0.bold == bold }) { return index }
            xfs.append((id, bold))
            return xfs.count - 1
        }

        var package = OfficePackage()
        var workbookRelationships: [OfficeRelationship] = []
        var sheetEntries = ""
        for (index, sheet) in sheets.enumerated() {
            let maxColumns = sheet.rows.map(\.count).max() ?? 0
            var widths = [Int](repeating: 0, count: maxColumns)
            var data = "<sheetData>"
            for (r, row) in sheet.rows.enumerated() {
                let bold = sheet.boldRows.contains(r)
                var cells = ""
                for (c, value) in row.enumerated() {
                    guard let value, !value.isEmpty else { continue }
                    widths[c] = max(widths[c], value.count)
                    let ref = column(c) + "\(r + 1)"
                    if let number = OfficeNumber.parse(value) {
                        let s = style(format: number.format, bold: bold)
                        cells += "<c r=\"\(ref)\"\(s > 0 ? " s=\"\(s)\"" : "")><v>\(number.value)</v></c>"
                    } else {
                        let s = style(format: nil, bold: bold)
                        cells += "<c r=\"\(ref)\" t=\"inlineStr\"\(s > 0 ? " s=\"\(s)\"" : "")><is><t xml:space=\"preserve\">\(XML.escape(value))</t></is></c>"
                    }
                }
                if !cells.isEmpty { data += "<row r=\"\(r + 1)\">\(cells)</row>" }
            }
            data += "</sheetData>"
            var xml = #"<worksheet xmlns="http://schemas.openxmlformats.org/spreadsheetml/2006/main" xmlns:r="http://schemas.openxmlformats.org/officeDocument/2006/relationships">"#
            if maxColumns > 0, !sheet.rows.isEmpty {
                xml += "<dimension ref=\"A1:\(column(maxColumns - 1))\(sheet.rows.count)\"/>"
            }
            if maxColumns > 0 {
                xml += "<cols>" + widths.enumerated().map { c, chars in
                    let width = min(max(Double(chars) * 1.1 + 2, 8), 60)
                    return "<col min=\"\(c + 1)\" max=\"\(c + 1)\" width=\"\(String(format: "%.2f", width))\" customWidth=\"1\"/>"
                }.joined() + "</cols>"
            }
            xml += data
            if !sheet.merges.isEmpty {
                xml += "<mergeCells count=\"\(sheet.merges.count)\">" + sheet.merges.map {
                    "<mergeCell ref=\"\(column($0.column))\($0.row + 1):\(column($0.lastColumn))\($0.lastRow + 1)\"/>"
                }.joined() + "</mergeCells>"
            }
            xml += "</worksheet>"
            package.add("xl/worksheets/sheet\(index + 1).xml", xml: xml,
                        contentType: "application/vnd.openxmlformats-officedocument.spreadsheetml.worksheet+xml")
            workbookRelationships.append(OfficeRelationship(id: "rId\(index + 1)", type: OfficeRelationship.worksheet, target: "worksheets/sheet\(index + 1).xml"))
            sheetEntries += "<sheet name=\"\(XML.escape(sheet.name))\" sheetId=\"\(index + 1)\" r:id=\"rId\(index + 1)\"/>"
        }
        package.add("xl/workbook.xml", xml: """
            <workbook xmlns="http://schemas.openxmlformats.org/spreadsheetml/2006/main" \
            xmlns:r="http://schemas.openxmlformats.org/officeDocument/2006/relationships"><bookViews><workbookView/></bookViews>\
            <sheets>\(sheetEntries)</sheets></workbook>
            """, contentType: "application/vnd.openxmlformats-officedocument.spreadsheetml.sheet.main+xml")

        var styles = #"<styleSheet xmlns="http://schemas.openxmlformats.org/spreadsheetml/2006/main">"#
        if !customFormats.isEmpty {
            styles += "<numFmts count=\"\(customFormats.count)\">" + customFormats.sorted { $0.value < $1.value }.map {
                "<numFmt numFmtId=\"\($0.value)\" formatCode=\"\(XML.escape($0.key))\"/>"
            }.joined() + "</numFmts>"
        }
        styles += #"<fonts count="2"><font><sz val="11"/><name val="Calibri"/><family val="2"/></font><font><b/><sz val="11"/><name val="Calibri"/><family val="2"/></font></fonts>"#
        styles += #"<fills count="2"><fill><patternFill patternType="none"/></fill><fill><patternFill patternType="gray125"/></fill></fills>"#
        styles += #"<borders count="1"><border><left/><right/><top/><bottom/><diagonal/></border></borders>"#
        styles += #"<cellStyleXfs count="1"><xf numFmtId="0" fontId="0" fillId="0" borderId="0"/></cellStyleXfs>"#
        styles += "<cellXfs count=\"\(xfs.count)\">" + xfs.map { xf in
            "<xf numFmtId=\"\(xf.numFmt)\" fontId=\"\(xf.bold ? 1 : 0)\" fillId=\"0\" borderId=\"0\" xfId=\"0\"\(xf.numFmt > 0 ? " applyNumberFormat=\"1\"" : "")\(xf.bold ? " applyFont=\"1\"" : "")/>"
        }.joined() + "</cellXfs>"
        styles += #"<cellStyles count="1"><cellStyle name="Normal" xfId="0" builtinId="0"/></cellStyles></styleSheet>"#
        package.add("xl/styles.xml", xml: styles, contentType: "application/vnd.openxmlformats-officedocument.spreadsheetml.styles+xml")
        workbookRelationships.append(OfficeRelationship(id: "rId\(sheets.count + 1)", type: OfficeRelationship.styles, target: "styles.xml"))
        package.addRelationships("xl/_rels/workbook.xml.rels", workbookRelationships)
        package.addProperties(title: title, mainPart: "xl/workbook.xml")
        return package.finish()
    }
}
