import CoreGraphics
import Foundation
import PDFModelKit
import SuperPDFCore

// Excel → PDF, built in (features #36, §3.2 "own OOXML reader → table layout"): sheets, cells, merged cells, column
// widths, row heights, number formats and basic styles (fonts, fills, borders, alignment) drawn as tables, one contents
// entry per sheet. Charts aren't drawn (a notice says so); `.xls` goes to LibreOffice or Excel.

enum SheetImportError: Error, Equatable {
    case notAWorkbook
    case empty
}

enum XLSXImporter {
    /// Bounds that keep a hostile or enormous workbook from filling memory.
    static let maxRows = 100_000
    static let maxColumns = 500

    static func convert(_ input: URL, to output: URL, options: ImportOptions) throws -> ImportReport {
        let archive = try ZipArchive(url: input)
        let book = try SheetWorkbook(archive: archive)
        var report = ImportReport()
        var grids: [SheetGrid] = []
        var truncated = false
        for sheet in book.sheets where sheet.visible {
            guard let path = sheet.path, let data = try archive.data(path) else { continue }
            let parsed = SheetWorksheetParser.parse(data, maxRows: maxRows, maxColumns: maxColumns)
            truncated = truncated || parsed.truncated
            grids.append(book.grid(named: sheet.name, from: parsed))
        }
        guard grids.contains(where: { !$0.isEmpty }) else { throw SheetImportError.empty }
        let firstPages = try SheetRenderer.render(grids, paper: options.textPaper, margins: CGFloat(options.margins),
                                                  title: String.baseName(input), to: output)
        report.outline = zip(grids, firstPages).compactMap { grid, page in
            page.map { PDFOutlineItem(title: grid.name, destination: PDFDestination(page: $0)) }
        }
        let name = input.lastPathComponent
        let charts = archive.entries.contains { $0.path.hasPrefix("xl/charts/") || $0.path.hasPrefix("xl/chartsheets/") }
        let pictures = archive.entries.contains { $0.path.hasPrefix("xl/media/") }
        if charts && pictures {
            report.notices.append("Charts and pictures in \(Strings.quoted(name)) aren’t in the PDF, only the cells.")
        } else if charts {
            report.notices.append("Charts in \(Strings.quoted(name)) aren’t in the PDF, only the cells.")
        } else if pictures {
            report.notices.append("Pictures in \(Strings.quoted(name)) aren’t in the PDF, only the cells.")
        }
        if truncated {
            report.notices.append("\(Strings.quoted(name)) is very large, so only its first \(maxRows.formatted()) rows and \(maxColumns) columns are in the PDF.")
        }
        return report
    }
}

// MARK: - Workbook

/// The workbook-level parts: sheets in order, shared strings, styles, the theme's colours and the date system.
struct SheetWorkbook {
    struct Sheet {
        var name: String
        var path: String?
        var visible: Bool
    }

    var sheets: [Sheet] = []
    var sharedStrings: [String] = []
    /// One style and one number format per cell format (`cellXfs` index).
    var styles: [SheetStyle] = []
    var formats: [SheetNumberFormat] = []
    var date1904 = false

    init(archive: ZipArchive) throws {
        let rootRels = SheetRels(archive: archive, part: "")
        let workbookPath = rootRels.target(ofType: "/officeDocument") ?? "xl/workbook.xml"
        guard let workbookData = try archive.data(workbookPath) else { throw SheetImportError.notAWorkbook }
        let workbook = try XML.parse(workbookData)
        guard workbook.name == "workbook" else { throw SheetImportError.notAWorkbook }
        let rels = SheetRels(archive: archive, part: workbookPath)
        if let pr = workbook.child("workbookPr"), let flag = pr.attr("date1904") { date1904 = flag == "1" || flag == "true" }
        for sheet in workbook.child("sheets")?.children("sheet") ?? [] {
            let state = sheet.attr("state") ?? "visible"
            sheets.append(Sheet(name: sheet.attr("name") ?? "Sheet \(sheets.count + 1)", path: sheet.attr("r:id").flatMap { rels.target(id: $0) },
                                visible: state == "visible"))
        }
        if let path = rels.target(ofType: "/sharedStrings") ?? (archive.entry("xl/sharedStrings.xml") != nil ? "xl/sharedStrings.xml" : nil),
           let data = try archive.data(path) {
            sharedStrings = SheetSharedStringsParser.parse(data)
        }
        var theme: [SheetRGB] = []
        if let path = rels.target(ofType: "/theme"), let data = try? archive.data(path), let root = try? XML.parse(data) {
            theme = Self.themeColors(root)
        }
        if let path = rels.target(ofType: "/styles") ?? (archive.entry("xl/styles.xml") != nil ? "xl/styles.xml" : nil),
           let data = try archive.data(path), let root = try? XML.parse(data) {
            readStyles(root, theme: theme)
        }
        if styles.isEmpty {
            styles = [SheetStyle(font: SheetFont(name: "Calibri", size: 11))]
            formats = [SheetNumberFormat(code: "General")]
        }
    }

    /// The theme's colours in Excel's index order: lt1, dk1, lt2, dk2, accent1–6, hlink, folHlink.
    private static func themeColors(_ root: XMLNode) -> [SheetRGB] {
        guard let scheme = root.first("clrScheme") else { return [] }
        func color(_ name: String) -> SheetRGB {
            guard let node = scheme.child(name) else { return .black }
            if let hex = node.child("srgbClr")?.attr("val"), let rgb = SheetRGB(hex: hex) { return rgb }
            if let hex = node.child("sysClr")?.attr("lastClr"), let rgb = SheetRGB(hex: hex) { return rgb }
            return .black
        }
        return ["lt1", "dk1", "lt2", "dk2", "accent1", "accent2", "accent3", "accent4", "accent5", "accent6", "hlink", "folHlink"].map(color)
    }

    private mutating func readStyles(_ root: XMLNode, theme: [SheetRGB]) {
        var codes: [Int: String] = [:]
        for fmt in root.child("numFmts")?.children("numFmt") ?? [] {
            if let id = fmt.attr("numFmtId").flatMap(Int.init), let code = fmt.attr("formatCode") { codes[id] = code }
        }
        func color(_ node: XMLNode?) -> SheetRGB? {
            guard let node, node.attr("auto") != "1" else { return nil }
            var rgb: SheetRGB?
            if let hex = node.attr("rgb") { rgb = SheetRGB(hex: hex) }
            else if let index = node.attr("theme").flatMap(Int.init), index < theme.count { rgb = theme[index] }
            else if let index = node.attr("indexed").flatMap(Int.init) { rgb = SheetPalette.indexed(index) }
            if let tint = node.attr("tint").flatMap(Double.init) { rgb = rgb?.tinted(tint) }
            return rgb
        }
        let fonts: [(SheetFont, SheetRGB?)] = (root.child("fonts")?.children("font") ?? []).map { font in
            func flag(_ name: String) -> Bool { font.child(name).map { $0.attr("val").map { $0 != "0" && $0 != "false" } ?? true } ?? false }
            let size = font.child("sz")?.attr("val").flatMap(Double.init) ?? 11
            return (SheetFont(name: font.child("name")?.attr("val"), size: CGFloat(size), bold: flag("b"), italic: flag("i")), color(font.child("color")))
        }
        let fills: [SheetRGB?] = (root.child("fills")?.children("fill") ?? []).map { fill in
            if let pattern = fill.child("patternFill") {
                guard pattern.attr("patternType") == "solid" else { return nil }
                let fg = color(pattern.child("fgColor"))
                // Indexed 64 is "automatic": no fill.
                if pattern.child("fgColor")?.attr("indexed") == "64" { return color(pattern.child("bgColor")) }
                return fg ?? color(pattern.child("bgColor"))
            }
            return fill.child("gradientFill")?.child("stop").flatMap { color($0.child("color")) }
        }
        let borders: [[String: SheetEdge]] = (root.child("borders")?.children("border") ?? []).map { border in
            var edges: [String: SheetEdge] = [:]
            for side in ["top", "left", "bottom", "right"] {
                guard let node = border.child(side), let style = node.attr("style"), style != "none" else { continue }
                let width: CGFloat
                switch style {
                case "hair": width = 0.25
                case "medium", "mediumDashed", "mediumDashDot", "mediumDashDotDot", "slantDashDot": width = 1
                case "thick", "double": width = 1.5
                default: width = 0.5
                }
                edges[side] = SheetEdge(width: width, color: color(node.child("color")) ?? .black)
            }
            return edges
        }
        for xf in root.child("cellXfs")?.children("xf") ?? [] {
            let fontIndex = xf.attr("fontId").flatMap(Int.init) ?? 0
            let (font, fontColor) = fontIndex < fonts.count ? fonts[fontIndex] : (SheetFont(name: "Calibri", size: 11), nil)
            var style = SheetStyle(font: font, color: fontColor)
            if let fill = xf.attr("fillId").flatMap(Int.init), fill < fills.count { style.fill = fills[fill] }
            if let border = xf.attr("borderId").flatMap(Int.init), border < borders.count {
                let edges = borders[border]
                style.top = edges["top"]; style.left = edges["left"]; style.bottom = edges["bottom"]; style.right = edges["right"]
            }
            if let alignment = xf.child("alignment") {
                switch alignment.attr("horizontal") {
                case "left": style.horizontal = .left
                case "center", "centerContinuous", "distributed", "fill", "justify": style.horizontal = .center
                case "right": style.horizontal = .right
                default: break
                }
                switch alignment.attr("vertical") {
                case "top": style.vertical = .top
                case "center", "justify", "distributed": style.vertical = .center
                default: break
                }
                style.wrap = alignment.attr("wrapText") == "1" || alignment.attr("wrapText") == "true"
                style.indent = min(alignment.attr("indent").flatMap(Int.init) ?? 0, 15)
                if style.horizontal == .general, style.indent > 0 { style.horizontal = .left }
            }
            styles.append(style)
            let id = xf.attr("numFmtId").flatMap(Int.init) ?? 0
            formats.append(SheetNumberFormat(code: codes[id] ?? SheetNumberFormat.builtIn(id), builtInID: codes[id] == nil ? id : nil))
        }
    }

    /// A parsed worksheet as a grid: its used range, without hidden rows and columns.
    func grid(named name: String, from sheet: SheetWorksheetParser.Result) -> SheetGrid {
        var grid = SheetGrid(name: name, styles: styles, columns: [], rows: [])
        func styleIndex(_ s: Int) -> Int { s >= 0 && s < styles.count ? s : 0 }
        // The used range: cells with something to show (text, a fill or a border).
        var minRow = Int.max, maxRow = -1, minCol = Int.max, maxCol = -1
        for (row, cells) in sheet.cells {
            for (col, cell) in cells {
                let style = styles[styleIndex(cell.style)]
                guard !cell.value.isEmpty || !cell.inline.isEmpty || style.fill != nil || style.hasBorder else { continue }
                minRow = min(minRow, row); maxRow = max(maxRow, row); minCol = min(minCol, col); maxCol = max(maxCol, col)
            }
        }
        guard maxRow >= 0 else { return grid }
        // Merges anchored inside the range widen it to their far corner (sane-sized ones: a sheet-sized merge doesn't
        // make thousands of empty pages).
        for merge in sheet.merges where merge.top >= minRow && merge.top <= maxRow && merge.left >= minCol && merge.left <= maxCol
            && (merge.bottom - merge.top + 1) * (merge.right - merge.left + 1) <= 10_000 {
            maxRow = min(max(maxRow, merge.bottom), XLSXImporter.maxRows - 1)
            maxCol = min(max(maxCol, merge.right), XLSXImporter.maxColumns - 1)
        }
        let visibleColumns = (minCol...maxCol).filter { !(sheet.columns[$0]?.hidden ?? false) }
        let visibleRows = (minRow...maxRow).filter { !(sheet.rows[$0]?.hidden ?? false) }
        guard !visibleColumns.isEmpty, !visibleRows.isEmpty else { return grid }
        var columnIndex: [Int: Int] = [:]
        for (i, c) in visibleColumns.enumerated() { columnIndex[c] = i }
        var rowIndex: [Int: Int] = [:]
        for (i, r) in visibleRows.enumerated() { rowIndex[r] = i }

        let defaultPixels = sheet.defaultColumnPixels
        grid.columns = visibleColumns.map { c in
            let pixels = sheet.columns[c]?.width.map { ($0 * 7).rounded() } ?? defaultPixels
            return CGFloat(max(pixels, 0)) * 0.75
        }
        grid.defaultRowHeight = CGFloat(sheet.defaultRowHeight)
        grid.prefersLandscape = sheet.landscape
        grid.gridlines = !sheet.cells.values.contains { row in row.values.contains { styles[styleIndex($0.style)].hasBorder } }
        grid.rows = visibleRows.map { r in
            var row = SheetRow(height: sheet.rows[r]?.height.map { CGFloat($0) }, cells: [])
            guard let cells = sheet.cells[r] else { return row }
            var out = [SheetCell?](repeating: nil, count: visibleColumns.count)
            var last = -1
            for (c, raw) in cells {
                guard let index = columnIndex[c] else { continue }
                out[index] = cell(raw, style: styleIndex(raw.style))
                last = max(last, index)
            }
            row.cells = Array(out.prefix(last + 1))
            return row
        }
        grid.merges = sheet.merges.compactMap { merge in
            // Map to visible indices, dropping hidden edges.
            let rows = (merge.top...merge.bottom).compactMap { rowIndex[$0] }, cols = (merge.left...merge.right).compactMap { columnIndex[$0] }
            guard let top = rows.first, let bottom = rows.last, let left = cols.first, let right = cols.last,
                  rowIndex[merge.top] != nil, columnIndex[merge.left] != nil else { return nil }
            return SheetMerge(top: top, left: left, bottom: bottom, right: right)
        }
        return grid
    }

    /// A cell's text as Excel shows it.
    private func cell(_ raw: SheetWorksheetParser.RawCell, style: Int) -> SheetCell {
        let format = formats[style]
        switch raw.type {
        case "s":
            let text = Int(raw.value).flatMap { $0 >= 0 && $0 < sharedStrings.count ? sharedStrings[$0] : nil } ?? ""
            return SheetCell(text: format.format(text: text), style: style)
        case "inlineStr":
            return SheetCell(text: format.format(text: raw.inline.isEmpty ? raw.value : raw.inline), style: style)
        case "str":
            return SheetCell(text: format.format(text: raw.value), style: style)
        case "b":
            var cell = SheetCell(text: raw.value == "1" || raw.value == "true" ? "TRUE" : "FALSE", style: style)
            cell.isNumber = true
            return cell
        case "e":
            return SheetCell(text: raw.value, style: style)
        case "d":
            if let serial = SheetNumberFormat.serial(iso: raw.value, date1904: date1904) {
                let display = format.isDate ? format.format(serial, date1904: date1904) : SheetNumberFormat(code: "yyyy-mm-dd").format(serial, date1904: date1904)
                return SheetCell(text: display, style: style, isNumber: true)
            }
            return SheetCell(text: raw.value, style: style)
        default:
            guard let value = Double(raw.value.trimmingCharacters(in: .whitespaces)) else {
                return SheetCell(text: raw.inline.isEmpty ? raw.value : raw.inline, style: style)
            }
            return SheetCell(text: format.format(value, date1904: date1904), style: style, isNumber: !format.isText)
        }
    }
}

/// A part's relationships (`_rels/*.rels`), with targets resolved to archive paths.
struct SheetRels {
    private var targets: [String: (type: String, target: String)] = [:]

    init(archive: ZipArchive, part: String) {
        let folder = (part as NSString).deletingLastPathComponent
        let relsPath = (folder.isEmpty ? "" : folder + "/") + "_rels/" + (part as NSString).lastPathComponent + ".rels"
        guard let data = try? archive.data(relsPath), let root = try? XML.parse(data) else { return }
        for rel in root.children("Relationship") {
            guard let id = rel.attr("Id"), let target = rel.attr("Target"), rel.attr("TargetMode") != "External" else { continue }
            targets[id] = (rel.attr("Type") ?? "", Self.resolve(target, from: folder))
        }
    }

    func target(id: String) -> String? { targets[id]?.target }

    /// The first target whose relationship type ends with `suffix` ("/styles").
    func target(ofType suffix: String) -> String? {
        targets.values.filter { $0.type.hasSuffix(suffix) }.map(\.target).sorted().first
    }

    static func resolve(_ target: String, from folder: String) -> String {
        if target.hasPrefix("/") { return String(target.dropFirst()) }
        var parts = folder.split(separator: "/").map(String.init)
        for piece in target.split(separator: "/").map(String.init) {
            if piece == ".." { _ = parts.popLast() } else if piece != "." { parts.append(piece) }
        }
        return parts.joined(separator: "/")
    }
}

/// Excel's 64-colour legacy palette (`indexed`), plus 64/65 for the system foreground/background.
enum SheetPalette {
    private static let colors: [UInt32] = [
        0x000000, 0xFFFFFF, 0xFF0000, 0x00FF00, 0x0000FF, 0xFFFF00, 0xFF00FF, 0x00FFFF,
        0x000000, 0xFFFFFF, 0xFF0000, 0x00FF00, 0x0000FF, 0xFFFF00, 0xFF00FF, 0x00FFFF,
        0x800000, 0x008000, 0x000080, 0x808000, 0x800080, 0x008080, 0xC0C0C0, 0x808080,
        0x9999FF, 0x993366, 0xFFFFCC, 0xCCFFFF, 0x660066, 0xFF8080, 0x0066CC, 0xCCCCFF,
        0x000080, 0xFF00FF, 0xFFFF00, 0x00FFFF, 0x800080, 0x800000, 0x008080, 0x0000FF,
        0x00CCFF, 0xCCFFFF, 0xCCFFCC, 0xFFFF99, 0x99CCFF, 0xFF99CC, 0xCC99FF, 0xFFCC99,
        0x3366FF, 0x33CCCC, 0x99CC00, 0xFFCC00, 0xFF9900, 0xFF6600, 0x666699, 0x969696,
        0x003366, 0x339966, 0x003300, 0x333300, 0x993300, 0x993366, 0x333399, 0x333333,
    ]

    static func indexed(_ index: Int) -> SheetRGB? {
        if index == 64 { return .black }
        if index == 65 { return .white }
        guard index >= 0, index < colors.count else { return nil }
        let v = colors[index]
        return SheetRGB(red: CGFloat((v >> 16) & 0xFF) / 255, green: CGFloat((v >> 8) & 0xFF) / 255, blue: CGFloat(v & 0xFF) / 255)
    }
}

// MARK: - Streaming parsers (worksheets and shared strings can be large)

enum SheetSharedStringsParser {
    static func parse(_ data: Data) -> [String] {
        let delegate = Delegate()
        let parser = XMLParser(data: data)
        parser.shouldResolveExternalEntities = false
        parser.delegate = delegate
        parser.parse()
        return delegate.strings
    }

    private final class Delegate: NSObject, XMLParserDelegate {
        var strings: [String] = []
        private var current = ""
        private var inItem = false, inText = false, phonetic = 0

        func parser(_ parser: XMLParser, didStartElement name: String, namespaceURI: String?, qualifiedName: String?, attributes: [String: String] = [:]) {
            switch SheetWorksheetParser.local(name) {
            case "si": inItem = true; current = ""
            case "rPh": phonetic += 1
            case "t": inText = inItem && phonetic == 0
            default: break
            }
        }

        func parser(_ parser: XMLParser, didEndElement name: String, namespaceURI: String?, qualifiedName: String?) {
            switch SheetWorksheetParser.local(name) {
            case "si": strings.append(current); inItem = false
            case "rPh": phonetic -= 1
            case "t": inText = false
            default: break
            }
        }

        func parser(_ parser: XMLParser, foundCharacters string: String) { if inText { current += string } }
    }
}

enum SheetWorksheetParser {
    struct RawCell {
        var value = ""
        /// Inline string text (`<is>`).
        var inline = ""
        var type: String?
        var style = 0
    }

    struct RowInfo { var height: Double?; var hidden = false }
    struct ColumnInfo { var width: Double?; var hidden = false }

    struct Result {
        var cells: [Int: [Int: RawCell]] = [:]
        var rows: [Int: RowInfo] = [:]
        var columns: [Int: ColumnInfo] = [:]
        var merges: [SheetMerge] = []
        var defaultRowHeight = 15.0
        var defaultColumnPixels = 64.0
        var landscape = false
        /// Cells past the row or column limit were left out.
        var truncated = false
    }

    static func parse(_ data: Data, maxRows: Int, maxColumns: Int) -> Result {
        let delegate = Delegate(maxRows: maxRows, maxColumns: maxColumns)
        let parser = XMLParser(data: data)
        parser.shouldResolveExternalEntities = false
        parser.delegate = delegate
        parser.parse()
        return delegate.result
    }

    static func local(_ name: String) -> Substring {
        guard let colon = name.lastIndex(of: ":") else { return Substring(name) }
        return name[name.index(after: colon)...]
    }

    /// "AB12" → (row 11, column 27); nil when malformed.
    static func reference(_ ref: String) -> (row: Int, column: Int)? {
        var column = 0, row = 0, sawLetter = false, sawDigit = false
        for scalar in ref.unicodeScalars {
            switch scalar.value {
            case 65...90, 97...122:
                guard !sawDigit else { return nil }
                column = column * 26 + Int((scalar.value & 0xDF) - 64)
                sawLetter = true
                if column > 20_000 { return nil }
            case 48...57:
                row = row * 10 + Int(scalar.value - 48)
                sawDigit = true
                if row > 2_000_000 { return nil }
            case 36: continue   // "$A$1"
            default: return nil
            }
        }
        guard sawLetter, sawDigit, row > 0 else { return nil }
        return (row - 1, column - 1)
    }

    private final class Delegate: NSObject, XMLParserDelegate {
        var result = Result()
        let maxRows: Int, maxColumns: Int
        private var row = -1, nextColumn = 0
        private var cell: RawCell?
        private var cellPosition: (row: Int, column: Int)?
        private var inValue = false, inInline = false, inInlineText = false, phonetic = 0
        private var cellCount = 0

        init(maxRows: Int, maxColumns: Int) { self.maxRows = maxRows; self.maxColumns = maxColumns }

        func parser(_ parser: XMLParser, didStartElement name: String, namespaceURI: String?, qualifiedName: String?, attributes: [String: String] = [:]) {
            switch local(name) {
            case "row":
                row = attributes["r"].flatMap(Int.init).map { $0 - 1 } ?? row + 1
                nextColumn = 0
                var info = RowInfo()
                if let ht = attributes["ht"].flatMap(Double.init), ht >= 0, ht < 2000 { info.height = ht }
                info.hidden = attributes["hidden"] == "1" || attributes["hidden"] == "true"
                if (info.height != nil || info.hidden), row >= 0, row < maxRows { result.rows[row] = info }
            case "c":
                var position = attributes["r"].flatMap(SheetWorksheetParser.reference) ?? (row, nextColumn)
                if position.row < 0 { position.row = max(row, 0) }
                nextColumn = position.column + 1
                cellPosition = position
                cell = RawCell(type: attributes["t"], style: attributes["s"].flatMap(Int.init) ?? 0)
            case "v": inValue = cell != nil
            case "is": inInline = cell != nil
            case "rPh": phonetic += 1
            case "t": inInlineText = inInline && phonetic == 0
            case "col":
                guard let min = attributes["min"].flatMap(Int.init), let max = attributes["max"].flatMap(Int.init), min >= 1, max >= min else { return }
                let info = ColumnInfo(width: attributes["width"].flatMap(Double.init).map { Swift.min(Swift.max($0, 0), 255) },
                                      hidden: attributes["hidden"] == "1" || attributes["hidden"] == "true")
                let upper = Swift.min(max, maxColumns)
                if min - 1 < upper { for c in (min - 1)..<upper { result.columns[c] = info } }
            case "sheetFormatPr":
                if let height = attributes["defaultRowHeight"].flatMap(Double.init), height > 0, height < 500 { result.defaultRowHeight = height }
                if let width = attributes["defaultColWidth"].flatMap(Double.init), width > 0, width < 255 {
                    result.defaultColumnPixels = (width * 7).rounded()
                } else if let base = attributes["baseColWidth"].flatMap(Double.init), base > 0, base < 255 {
                    result.defaultColumnPixels = base * 7 + 8
                }
            case "mergeCell":
                guard let ref = attributes["ref"] else { return }
                let corners = ref.split(separator: ":").map(String.init)
                guard let a = corners.first.flatMap(SheetWorksheetParser.reference) else { return }
                let b = corners.count > 1 ? SheetWorksheetParser.reference(corners[1]) ?? a : a
                let merge = SheetMerge(top: Swift.min(a.row, b.row), left: Swift.min(a.column, b.column),
                                       bottom: Swift.max(a.row, b.row), right: Swift.max(a.column, b.column))
                if merge.top < maxRows, merge.left < maxColumns, result.merges.count < 50_000 { result.merges.append(merge) }
            case "pageSetup":
                result.landscape = attributes["orientation"] == "landscape"
            default: break
            }
        }

        func parser(_ parser: XMLParser, didEndElement name: String, namespaceURI: String?, qualifiedName: String?) {
            switch local(name) {
            case "c":
                defer { cell = nil; cellPosition = nil }
                guard let cell, let position = cellPosition else { return }
                guard position.row < maxRows, position.column < maxColumns, cellCount < 2_000_000 else { result.truncated = true; return }
                guard !cell.value.isEmpty || !cell.inline.isEmpty || cell.style != 0 else { return }
                result.cells[position.row, default: [:]][position.column] = cell
                cellCount += 1
            case "v": inValue = false
            case "is": inInline = false
            case "rPh": phonetic -= 1
            case "t": inInlineText = false
            default: break
            }
        }

        func parser(_ parser: XMLParser, foundCharacters string: String) {
            if inValue { cell?.value += string } else if inInlineText { cell?.inline += string }
        }
    }
}

// MARK: - Number formats

/// An Excel number format code ("#,##0.00", "0.0%", "yyyy-mm-dd", "$#,##0;($#,##0)", "h:mm AM/PM") applied to a value.
/// Separators follow the person's locale, as Excel shows them.
struct SheetNumberFormat: Sendable {
    let code: String
    private let sections: [String]
    /// Built-in 14 and 22 follow the system's short date (and time), as Excel does.
    private let localeTemplate: String?
    let isDate: Bool
    let isText: Bool

    init(code: String, builtInID: Int? = nil) {
        self.code = code
        sections = Self.split(code)
        localeTemplate = builtInID == 14 ? "yMd" : builtInID == 22 ? "yMdjm" : nil
        isDate = localeTemplate != nil || sections.first.map(Self.hasDateTokens) ?? false
        isText = code == "@"
    }

    /// The codes of Excel's built-in formats.
    static func builtIn(_ id: Int) -> String {
        switch id {
        case 1: "0"
        case 2: "0.00"
        case 3: "#,##0"
        case 4: "#,##0.00"
        case 5: "$#,##0_);($#,##0)"
        case 6: "$#,##0_);[Red]($#,##0)"
        case 7: "$#,##0.00_);($#,##0.00)"
        case 8: "$#,##0.00_);[Red]($#,##0.00)"
        case 9: "0%"
        case 10: "0.00%"
        case 11: "0.00E+00"
        case 12: "# ?/?"
        case 13: "# ??/??"
        case 14: "m/d/yyyy"
        case 15: "d-mmm-yy"
        case 16: "d-mmm"
        case 17: "mmm-yy"
        case 18: "h:mm AM/PM"
        case 19: "h:mm:ss AM/PM"
        case 20: "h:mm"
        case 21: "h:mm:ss"
        case 22: "m/d/yyyy h:mm"
        case 37: "#,##0 ;(#,##0)"
        case 38: "#,##0 ;[Red](#,##0)"
        case 39: "#,##0.00;(#,##0.00)"
        case 40: "#,##0.00;[Red](#,##0.00)"
        case 41: "_(* #,##0_);_(* (#,##0);_(* \"-\"_);_(@_)"
        case 42: "_(\"$\"* #,##0_);_(\"$\"* (#,##0);_(\"$\"* \"-\"_);_(@_)"
        case 43: "_(* #,##0.00_);_(* (#,##0.00);_(* \"-\"??_);_(@_)"
        case 44: "_(\"$\"* #,##0.00_);_(\"$\"* (#,##0.00);_(\"$\"* \"-\"??_);_(@_)"
        case 45: "mm:ss"
        case 46: "[h]:mm:ss"
        case 47: "mm:ss.0"
        case 48: "##0.0E+0"
        case 49: "@"
        default: "General"
        }
    }

    // MARK: Text

    /// Text through the format's text section ("\"Note: \"@"); other formats show text as it is.
    func format(text: String) -> String {
        guard sections.count >= 4 || (sections.count == 1 && sections[0].contains("@") && sections[0] != "@") else { return text }
        let section = sections.count >= 4 ? sections[3] : sections[0]
        var out = ""
        for token in Self.tokens(section) {
            switch token {
            case .literal(let s): out += s
            case .at: out += text
            default: break
            }
        }
        return out
    }

    // MARK: Numbers

    func format(_ value: Double, date1904: Bool) -> String {
        guard value.isFinite else { return "#NUM!" }
        if let localeTemplate { return Self.localeDate(value, template: localeTemplate, date1904: date1904) }
        // Pick the section: one for all; two: ≥ 0 / < 0; three: > 0 / < 0 / = 0 (conditions are read as these).
        var section = sections.first ?? "General"
        var number = value
        var signShown = true
        if sections.count >= 2, value < 0 {
            section = sections[1]; number = -value; signShown = false
        } else if sections.count >= 3, value == 0 {
            section = sections[2]
        }
        if Self.hasDateTokens(section) { return Self.formatDate(value, section: section, date1904: date1904) }
        let trimmed = Self.strip(section)
        if trimmed.lowercased() == "general" || trimmed.isEmpty && section.lowercased().contains("general") {
            return Self.general(signShown ? value : number)
        }
        let text = Self.formatNumber(number, section: section)
        if signShown, value < 0, Self.roundsToNonZero(text) { return "-" + text }
        return text
    }

    private static func roundsToNonZero(_ text: String) -> Bool { text.contains { $0.isNumber && $0 != "0" } }

    /// Excel's "General": up to 11 significant characters, scientific for very large or small numbers.
    static func general(_ value: Double) -> String {
        let magnitude = abs(value)
        if magnitude == 0 { return "0" }
        let decimal = Locale.current.decimalSeparator ?? "."
        if magnitude >= 1e11 || magnitude < 1e-9 {
            var text = String(format: "%.5E", value)
            // "1.23450E+11" → "1.2345E+11"
            if let e = text.firstIndex(of: "E") {
                var mantissa = String(text[..<e]), exponent = String(text[text.index(after: e)...])
                while mantissa.contains("."), mantissa.hasSuffix("0") { mantissa.removeLast() }
                if mantissa.hasSuffix(".") { mantissa.removeLast() }
                let sign = exponent.hasPrefix("-") ? "-" : "+"
                exponent = exponent.trimmingCharacters(in: CharacterSet(charactersIn: "+-"))
                while exponent.count > 2, exponent.hasPrefix("0") { exponent.removeFirst() }
                text = mantissa + "E" + sign + exponent
            }
            return text.replacingOccurrences(of: ".", with: decimal)
        }
        if value == value.rounded(), magnitude < 1e15 { return String(Int64(value)) }
        let integerDigits = max(1, Int(log10(magnitude)) + 1)
        var text = String(format: "%.\(max(0, 10 - integerDigits))f", value)
        if text.contains(".") {
            while text.hasSuffix("0") { text.removeLast() }
            if text.hasSuffix(".") { text.removeLast() }
        }
        return text.replacingOccurrences(of: ".", with: decimal)
    }

    private enum Token {
        case literal(String)
        case digit(Character)   // 0 # ?
        case point, comma, percent, slash, at
        case exponent(sign: Bool)
    }

    /// A section's tokens; brackets other than currency are dropped, "_x" becomes a space and "*x" nothing.
    private static func tokens(_ section: String) -> [Token] {
        var tokens: [Token] = []
        let chars = Array(section)
        var i = 0
        while i < chars.count {
            let c = chars[i]
            switch c {
            case "\"":
                var j = i + 1, text = ""
                while j < chars.count, chars[j] != "\"" { text.append(chars[j]); j += 1 }
                tokens.append(.literal(text)); i = j + 1
            case "\\":
                if i + 1 < chars.count { tokens.append(.literal(String(chars[i + 1]))) }
                i += 2
            case "_":
                tokens.append(.literal(" ")); i += 2
            case "*":
                i += 2
            case "[":
                var j = i + 1, inner = ""
                while j < chars.count, chars[j] != "]" { inner.append(chars[j]); j += 1 }
                if inner.hasPrefix("$") {
                    let symbol = inner.dropFirst().split(separator: "-", maxSplits: 1, omittingEmptySubsequences: false).first.map(String.init) ?? ""
                    if !symbol.isEmpty { tokens.append(.literal(symbol)) }
                }
                i = j + 1
            case "0", "#", "?": tokens.append(.digit(c)); i += 1
            case ".": tokens.append(.point); i += 1
            case ",": tokens.append(.comma); i += 1
            case "%": tokens.append(.percent); i += 1
            case "/": tokens.append(.slash); i += 1
            case "@": tokens.append(.at); i += 1
            case "E", "e":
                if i + 1 < chars.count, chars[i + 1] == "+" || chars[i + 1] == "-" {
                    tokens.append(.exponent(sign: chars[i + 1] == "+")); i += 2
                } else {
                    tokens.append(.literal(String(c))); i += 1
                }
            default:
                tokens.append(.literal(String(c))); i += 1
            }
        }
        return tokens
    }

    private static func formatNumber(_ value: Double, section: String) -> String {
        let tokens = tokens(section)
        let decimalSep = Locale.current.decimalSeparator ?? ".", groupSep = Locale.current.groupingSeparator ?? ","
        var number = value
        let percents = tokens.filter { if case .percent = $0 { true } else { false } }.count
        for _ in 0..<min(percents, 3) { number *= 100 }

        // Where the number's parts are.
        guard let firstDigit = tokens.firstIndex(where: { if case .digit = $0 { true } else { false } }) else {
            // No placeholders: literals only (";;;" hides, "\"-\"" shows a dash).
            return tokens.compactMap { if case .literal(let s) = $0 { s } else if case .percent = $0 { "%" } else { nil } }.joined()
        }
        let lastDigit = tokens.lastIndex(where: { if case .digit = $0 { true } else { false } })!
        if let slash = tokens.firstIndex(where: { if case .slash = $0 { true } else { false } }), slash > firstDigit, slash < lastDigit {
            return formatFraction(number, tokens: tokens, firstDigit: firstDigit, lastDigit: lastDigit, slash: slash)
        }
        let exponentIndex = tokens.firstIndex(where: { if case .exponent = $0 { true } else { false } })
        let pointIndex = tokens.firstIndex(where: { if case .point = $0 { true } else { false } })
        let mantissaEnd = exponentIndex ?? tokens.count
        func digits(_ range: Range<Int>) -> [Character] {
            tokens[range].compactMap { if case .digit(let d) = $0 { d } else { nil } }
        }
        let intEnd = min(pointIndex ?? mantissaEnd, mantissaEnd)
        let intPlaceholders = digits(firstDigit..<intEnd)
        let fracPlaceholders = pointIndex.map { digits(($0 + 1)..<mantissaEnd) } ?? []
        // Commas between integer placeholders group thousands; commas right after the last one scale by 1,000.
        var grouping = false
        var scaleCommas = 0
        var lastIntDigit = firstDigit
        for i in firstDigit..<intEnd { if case .digit = tokens[i] { lastIntDigit = i } }
        for i in firstDigit..<intEnd {
            if case .comma = tokens[i] { if i < lastIntDigit { grouping = true } else { scaleCommas += 1 } }
        }
        for _ in 0..<min(scaleCommas, 4) { number /= 1000 }

        var exponent = 0
        if exponentIndex != nil, number != 0 {
            let intCount = max(intPlaceholders.count, 1)
            // "##0.0E+0": exponents in multiples of the integer placeholders' count (engineering notation).
            let step = intPlaceholders.count > 1 && intPlaceholders.first == "#" ? intCount : 1
            exponent = Int(floor(log10(abs(number))))
            exponent = Int((Double(exponent) / Double(step)).rounded(.down)) * step
            if step == 1 { exponent -= max(intPlaceholders.filter { $0 == "0" }.count - 1, 0) }
            number /= pow(10, Double(exponent))
        }

        let maxFraction = fracPlaceholders.count, minFraction = fracPlaceholders.filter { $0 == "0" }.count
        let rounded = String(format: "%.\(maxFraction)f", abs(number))
        var intPart = rounded, fracPart = ""
        if let dot = rounded.firstIndex(of: ".") { intPart = String(rounded[..<dot]); fracPart = String(rounded[rounded.index(after: dot)...]) }
        while fracPart.count > minFraction, fracPart.hasSuffix("0") { fracPart.removeLast() }
        let minInt = intPlaceholders.filter { $0 == "0" }.count
        if intPart == "0", minInt == 0 { intPart = "" }
        while intPart.count < minInt { intPart = "0" + intPart }
        if grouping, intPart.count > 3 {
            var grouped = "", count = 0
            for ch in intPart.reversed() {
                if count > 0, count % 3 == 0 { grouped = groupSep + grouped }
                grouped = String(ch) + grouped
                count += 1
            }
            intPart = grouped
        }

        var out = ""
        var emittedInt = false, emittedFrac = false
        for (i, token) in tokens.enumerated() {
            switch token {
            case .literal(let s): out += s
            case .percent: out += "%"
            case .digit:
                if i < intEnd || pointIndex == nil && i < mantissaEnd {
                    if !emittedInt { out += intPart; emittedInt = true }
                } else if i < mantissaEnd {
                    if !emittedFrac { out += fracPart; emittedFrac = true }
                } else if let exponentIndex, i > exponentIndex {
                    continue
                }
            case .point:
                if !emittedInt { out += intPart; emittedInt = true }
                out += decimalSep
            case .comma:
                if i >= intEnd { out += "," }
            case .exponent(let sign):
                let expDigits = tokens[(i + 1)...].prefix { if case .digit = $0 { true } else { false } }.count
                var e = String(abs(exponent))
                while e.count < max(expDigits, 1) { e = "0" + e }
                out += "E" + (exponent < 0 ? "-" : sign ? "+" : "") + e
            case .slash: out += "/"
            case .at: break
            }
        }
        return out
    }

    /// "# ?/?" and "?/??" fractions.
    private static func formatFraction(_ value: Double, tokens: [Token], firstDigit: Int, lastDigit: Int, slash: Int) -> String {
        // An integer part exists when a literal space separates placeholders before the numerator.
        var integerEnd: Int?
        for i in firstDigit..<slash {
            if case .literal(let s) = tokens[i], s.trimmingCharacters(in: .whitespaces).isEmpty { integerEnd = i; break }
        }
        let denominatorDigits = tokens[(slash + 1)...lastDigit].filter { if case .digit = $0 { true } else { false } }.count
        let fixedDenominator: Int? = {
            let literal = tokens[(slash + 1)...lastDigit].compactMap { if case .literal(let s) = $0 { s } else { nil } }.joined()
            return Int(literal)
        }()
        let magnitude = abs(value)
        var whole = integerEnd != nil ? floor(magnitude) : 0
        let fraction = magnitude - whole
        var numerator = 0, denominator = 1
        if let fixed = fixedDenominator, fixed > 0 {
            numerator = Int((fraction * Double(fixed)).rounded()); denominator = fixed
        } else {
            let limit = max(Int(pow(10, Double(max(denominatorDigits, 1)))) - 1, 1)
            var best = (n: 0, d: 1, error: fraction)
            for d in 1...limit {
                let n = Int((fraction * Double(d)).rounded())
                let error = abs(fraction - Double(n) / Double(d))
                if error < best.error - 1e-12 { best = (n, d, error) }
                if error < 1e-12 { break }
            }
            numerator = best.n; denominator = best.d
        }
        if numerator == denominator, integerEnd != nil { whole += 1; numerator = 0 }
        var out = ""
        if integerEnd != nil, whole > 0 || numerator == 0 { out += String(Int(whole)) }
        if numerator != 0 { out += (out.isEmpty ? "" : " ") + "\(numerator)/\(denominator)" }
        if out.isEmpty { out = "0" }
        return out
    }

    // MARK: Dates

    /// The serial number of an ISO 8601 date-time ("2024-03-15T10:30:00Z").
    static func serial(iso: String, date1904: Bool) -> Double? {
        let formatter = ISO8601DateFormatter()
        formatter.timeZone = TimeZone(identifier: "UTC")
        var date = formatter.date(from: iso)
        if date == nil {
            formatter.formatOptions = [.withFullDate]
            date = formatter.date(from: String(iso.prefix(10)))
        }
        guard let date else { return nil }
        let base = date1904 ? -2_082_844_800.0 : -2_209_161_600.0   // 1904-01-01 / 1899-12-30, UTC
        var serial = (date.timeIntervalSince1970 - base) / 86_400
        if !date1904, serial < 61 { serial -= 1 }
        return serial
    }

    private struct DateParts { var year, month, day, hour, minute, second, weekday: Int; var fraction: Double }

    private static func parts(_ serial: Double, date1904: Bool) -> DateParts? {
        guard serial >= 0, serial < 2_958_466 else { return nil }
        var days = floor(serial)
        var seconds = ((serial - days) * 86_400 * 1000).rounded() / 1000
        if seconds >= 86_400 { days += 1; seconds -= 86_400 }
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        // Excel's 1900 system counts a 29 February 1900 that never was (serial 60).
        if !date1904, days == 60 {
            return DateParts(year: 1900, month: 2, day: 29, hour: Int(seconds) / 3600, minute: Int(seconds) / 60 % 60, second: Int(seconds) % 60,
                             weekday: 4, fraction: seconds - floor(seconds))
        }
        let base = date1904 ? DateComponents(year: 1904, month: 1, day: 1) : days < 60 ? DateComponents(year: 1899, month: 12, day: 31) : DateComponents(year: 1899, month: 12, day: 30)
        guard let start = calendar.date(from: base), let date = calendar.date(byAdding: .day, value: Int(days), to: start) else { return nil }
        let c = calendar.dateComponents([.year, .month, .day, .weekday], from: date)
        let whole = Int(floor(seconds))
        return DateParts(year: c.year ?? 1900, month: c.month ?? 1, day: c.day ?? 1, hour: whole / 3600, minute: whole / 60 % 60,
                         second: whole % 60, weekday: c.weekday ?? 1, fraction: seconds - Double(whole))
    }

    private static let symbols: (months: [String], shortMonths: [String], weekdays: [String], shortWeekdays: [String], am: String, pm: String) = {
        let formatter = DateFormatter()
        formatter.locale = Locale.current
        return (formatter.monthSymbols, formatter.shortMonthSymbols, formatter.weekdaySymbols, formatter.shortWeekdaySymbols,
                formatter.amSymbol, formatter.pmSymbol)
    }()

    private static func localeDate(_ serial: Double, template: String, date1904: Bool) -> String {
        guard let p = parts(serial, date1904: date1904) else { return general(serial) }
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        guard let date = calendar.date(from: DateComponents(year: p.year, month: p.month, day: p.day, hour: p.hour, minute: p.minute,
                                                            second: p.second)) else { return general(serial) }
        let formatter = DateFormatter()
        formatter.locale = Locale.current
        formatter.timeZone = calendar.timeZone
        formatter.setLocalizedDateFormatFromTemplate(template)
        return formatter.string(from: date)
    }

    /// Whether a section reads as a date or time (y, m, d, h, s outside quotes and brackets other than [h] [m] [s]).
    private static func hasDateTokens(_ section: String) -> Bool {
        let bare = strip(section).lowercased()
        if bare.contains("general") { return false }
        if section.lowercased().range(of: #"\[(h+|m+|s+)\]"#, options: .regularExpression) != nil { return true }
        return bare.contains { "ymdhs".contains($0) }
    }

    /// The section without quoted text, escapes and brackets.
    private static func strip(_ section: String) -> String {
        var out = "", inQuote = false, inBracket = false, escape = false
        for c in section {
            if escape { escape = false; continue }
            if inQuote { if c == "\"" { inQuote = false }; continue }
            if inBracket { if c == "]" { inBracket = false }; continue }
            switch c {
            case "\"": inQuote = true
            case "[": inBracket = true
            case "\\", "_", "*": escape = true
            default: out.append(c)
            }
        }
        return out
    }

    private static func formatDate(_ serial: Double, section: String, date1904: Bool) -> String {
        guard let p = parts(serial, date1904: date1904) else { return String(repeating: "#", count: 8) }
        let chars = Array(section)
        let lower = chars.map { $0.lowercased().first ?? $0 }
        let twelveHour = section.lowercased().contains("am/pm") || section.lowercased().contains("a/p")
        func starts(_ word: String, at index: Int) -> Bool {
            let w = Array(word)
            return index + w.count <= lower.count && Array(lower[index..<index + w.count]) == w
        }
        // Tokens: runs of the same letter, literals, brackets, AM/PM.
        enum Piece { case run(Character, Int), literal(String), elapsed(Character, Int), ampm(Bool), fraction(Int) }
        var pieces: [Piece] = []
        var i = 0
        while i < chars.count {
            let c = chars[i], lc = lower[i]
            if c == "\"" {
                var j = i + 1, text = ""
                while j < chars.count, chars[j] != "\"" { text.append(chars[j]); j += 1 }
                pieces.append(.literal(text)); i = j + 1
            } else if c == "\\" {
                if i + 1 < chars.count { pieces.append(.literal(String(chars[i + 1]))) }
                i += 2
            } else if c == "_" { pieces.append(.literal(" ")); i += 2
            } else if c == "*" { i += 2
            } else if c == "[" {
                var j = i + 1, inner = ""
                while j < chars.count, chars[j] != "]" { inner.append(chars[j]); j += 1 }
                let lowered = inner.lowercased()
                if let first = lowered.first, "hms".contains(first), lowered.allSatisfy({ $0 == first }) {
                    pieces.append(.elapsed(first, lowered.count))
                }
                i = j + 1
            } else if starts("am/pm", at: i) {
                pieces.append(.ampm(true)); i += 5
            } else if starts("a/p", at: i) {
                pieces.append(.ampm(false)); i += 3
            } else if "ymdhse".contains(lc) {
                var j = i
                while j < chars.count, lower[j] == lc { j += 1 }
                pieces.append(.run(lc == "e" ? "y" : lc, j - i)); i = j
            } else if c == ".", i + 1 < chars.count, chars[i + 1] == "0", case .run("s", _)? = pieces.last {
                var j = i + 1
                while j < chars.count, chars[j] == "0" { j += 1 }
                pieces.append(.fraction(j - i - 1)); i = j
            } else {
                pieces.append(.literal(String(c))); i += 1
            }
        }
        // "m" is minutes right after an hour or right before a second.
        func isMinute(_ index: Int) -> Bool {
            var k = index - 1
            while k >= 0 { if case .run(let l, _) = pieces[k] { return l == "h" }; if case .elapsed(let l, _) = pieces[k] { return l == "h" }; k -= 1 }
            k = index + 1
            while k < pieces.count { if case .run(let l, _) = pieces[k] { return l == "s" }; if case .elapsed(let l, _) = pieces[k] { return l == "s" }; k += 1 }
            return false
        }
        func pad(_ n: Int, _ width: Int) -> String { width >= 2 && n < 10 ? "0\(n)" : "\(n)" }
        let totalSeconds = serial * 86_400
        var out = ""
        for (index, piece) in pieces.enumerated() {
            switch piece {
            case .literal(let s): out += s
            case .ampm(let full):
                let pm = p.hour >= 12
                out += full ? (pm ? symbols.pm : symbols.am) : (pm ? "P" : "A")
            case .fraction(let digits):
                let value = Int((p.fraction * pow(10, Double(digits))).rounded())
                out += Self.decimalSeparator + String(format: "%0\(digits)d", min(value, Int(pow(10, Double(digits))) - 1))
            case .elapsed(let letter, let width):
                let value: Int
                switch letter {
                case "h": value = Int(totalSeconds / 3600)
                case "m": value = Int(totalSeconds / 60)
                default: value = Int(totalSeconds.rounded())
                }
                out += pad(value, width)
            case .run(let letter, let count):
                switch letter {
                case "y": out += count <= 2 ? pad(p.year % 100, 2) : String(p.year)
                case "m" where count <= 2 && isMinute(index): out += pad(p.minute, count)
                case "m":
                    switch count {
                    case 1, 2: out += pad(p.month, count)
                    case 3: out += symbols.shortMonths[p.month - 1]
                    case 5: out += String(symbols.months[p.month - 1].prefix(1))
                    default: out += symbols.months[p.month - 1]
                    }
                case "d":
                    switch count {
                    case 1, 2: out += pad(p.day, count)
                    case 3: out += symbols.shortWeekdays[p.weekday - 1]
                    default: out += symbols.weekdays[p.weekday - 1]
                    }
                case "h":
                    var hour = p.hour
                    if twelveHour { hour = hour % 12; if hour == 0 { hour = 12 } }
                    out += pad(hour, count)
                case "s": out += pad(p.second, count)
                default: break
                }
            }
        }
        return out
    }

    private static var decimalSeparator: String { Locale.current.decimalSeparator ?? "." }

    /// Splits a code into its sections at ";" outside quotes and brackets.
    private static func split(_ code: String) -> [String] {
        var sections: [String] = [], current = "", inQuote = false, inBracket = false, escape = false
        for c in code {
            if escape { current.append(c); escape = false; continue }
            switch c {
            case "\\": escape = true; current.append(c)
            case "\"": inQuote.toggle(); current.append(c)
            case "[" where !inQuote: inBracket = true; current.append(c)
            case "]" where !inQuote: inBracket = false; current.append(c)
            case ";" where !inQuote && !inBracket: sections.append(current); current = ""
            default: current.append(c)
            }
        }
        sections.append(current)
        return sections
    }
}
