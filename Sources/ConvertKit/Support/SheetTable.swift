import CoreGraphics
import CoreText
import Foundation
import SuperPDFCore

// Tables on paper (features #36 Excel → PDF, #43 CSV/TSV → PDF): a grid of styled cells with column widths, row
// heights, merged cells and borders, laid out on pages "down, then over" as Excel prints, with header rows repeated on
// every page when asked and landscape chosen automatically for wide tables. Off the main actor; Core Text only.

/// An sRGB colour, 0…1.
struct SheetRGB: Hashable, Sendable {
    var red: CGFloat
    var green: CGFloat
    var blue: CGFloat

    static let black = SheetRGB(red: 0, green: 0, blue: 0)
    static let white = SheetRGB(red: 1, green: 1, blue: 1)

    /// "FFRRGGBB" (ARGB, Excel's way) or "RRGGBB"; nil when malformed.
    init?(hex: String) {
        let digits = hex.count == 8 ? String(hex.dropFirst(2)) : hex
        guard digits.count == 6, let value = UInt32(digits, radix: 16) else { return nil }
        red = CGFloat((value >> 16) & 0xFF) / 255; green = CGFloat((value >> 8) & 0xFF) / 255; blue = CGFloat(value & 0xFF) / 255
    }

    init(red: CGFloat, green: CGFloat, blue: CGFloat) { self.red = red; self.green = green; self.blue = blue }

    var cgColor: CGColor { CGColor(srgbRed: red, green: green, blue: blue, alpha: 1) }

    /// Excel's tint: towards white for positive values, towards black for negative ones (in HSL lightness).
    func tinted(_ tint: Double) -> SheetRGB {
        guard tint != 0 else { return self }
        let maxC = max(red, green, blue), minC = min(red, green, blue)
        var l = (maxC + minC) / 2
        let d = maxC - minC
        var h: CGFloat = 0, s: CGFloat = 0
        if d > 0 {
            s = l > 0.5 ? d / (2 - maxC - minC) : d / (maxC + minC)
            if maxC == red { h = (green - blue) / d + (green < blue ? 6 : 0) } else if maxC == green { h = (blue - red) / d + 2 } else { h = (red - green) / d + 4 }
            h /= 6
        }
        l = tint < 0 ? l * (1 + CGFloat(tint)) : l * (1 - CGFloat(tint)) + CGFloat(tint)
        func hue(_ p: CGFloat, _ q: CGFloat, _ t: CGFloat) -> CGFloat {
            var t = t
            if t < 0 { t += 1 }
            if t > 1 { t -= 1 }
            if t < 1.0 / 6 { return p + (q - p) * 6 * t }
            if t < 1.0 / 2 { return q }
            if t < 2.0 / 3 { return p + (q - p) * (2.0 / 3 - t) * 6 }
            return p
        }
        guard s > 0 else { return SheetRGB(red: l, green: l, blue: l) }
        let q = l < 0.5 ? l * (1 + s) : l + s - l * s, p = 2 * l - q
        return SheetRGB(red: hue(p, q, h + 1.0 / 3), green: hue(p, q, h), blue: hue(p, q, h - 1.0 / 3))
    }
}

struct SheetFont: Hashable, Sendable {
    /// The family the file asks for; nil (or one this Mac doesn't have) uses the system font.
    var name: String?
    var size: CGFloat
    var bold = false
    var italic = false
}

enum SheetHorizontal: Sendable { case general, left, center, right }
enum SheetVertical: Sendable { case top, center, bottom }

/// One side of a cell's border.
struct SheetEdge: Hashable, Sendable {
    var width: CGFloat
    var color: SheetRGB
}

struct SheetStyle: Hashable, Sendable {
    var font: SheetFont
    var color: SheetRGB?
    var fill: SheetRGB?
    var horizontal: SheetHorizontal = .general
    var vertical: SheetVertical = .bottom
    var wrap = false
    var indent = 0
    var top: SheetEdge?
    var left: SheetEdge?
    var bottom: SheetEdge?
    var right: SheetEdge?

    var hasBorder: Bool { top != nil || left != nil || bottom != nil || right != nil }
}

struct SheetCell: Sendable {
    var text: String
    /// Index into `SheetGrid.styles`.
    var style: Int
    /// Numbers align right under "general" alignment and shrink rather than spill.
    var isNumber = false
}

struct SheetRow: Sendable {
    /// Points; nil measures the cells.
    var height: CGFloat?
    /// Up to the row's last cell; missing cells are empty.
    var cells: [SheetCell?]
}

/// A merged area, in the grid's row and column indices, inclusive.
struct SheetMerge: Hashable, Sendable {
    var top: Int, left: Int, bottom: Int, right: Int
}

/// One sheet (or one CSV file) ready to lay out.
struct SheetGrid: Sendable {
    var name: String
    var styles: [SheetStyle]
    /// Points, one per column.
    var columns: [CGFloat]
    var rows: [SheetRow]
    var merges: [SheetMerge] = []
    /// Rows repeated at the top of every page (CSV's header row).
    var repeatRows = 0
    /// Light grid lines around every cell; off when the sheet draws its own borders.
    var gridlines = true
    /// The sheet's own page setup asked for landscape.
    var prefersLandscape = false
    /// Row height when nothing in the row needs more.
    var defaultRowHeight: CGFloat = 15

    var isEmpty: Bool { rows.isEmpty || columns.isEmpty }
}

enum SheetTableError: Error { case cannotCreatePDF }

enum SheetRenderer {
    static let padding: CGFloat = 2.5
    static let gridColor = SheetRGB(red: 0.82, green: 0.82, blue: 0.82)

    /// Draws every grid onto pages of `paper` (portrait size) with `margins`, into one PDF at `url`. Returns, per grid,
    /// the 0-based index of its first page (nil for an empty grid, which gets no pages).
    static func render(_ grids: [SheetGrid], paper: CGSize, margins: CGFloat, title: String?, to url: URL) throws -> [Int?] {
        var box = CGRect(origin: .zero, size: paper)
        var info: [CFString: Any] = [kCGPDFContextCreator: Strings.appName]
        if let title, !title.isEmpty { info[kCGPDFContextTitle] = title }
        guard let context = CGContext(url as CFURL, mediaBox: &box, info as CFDictionary) else { throw SheetTableError.cannotCreatePDF }
        var fonts = SheetFonts()
        var firstPages: [Int?] = []
        var pageCount = 0
        for grid in grids {
            guard !grid.isEmpty else { firstPages.append(nil); continue }
            let layout = SheetLayout(grid: grid, paper: paper, margins: margins, fonts: &fonts)
            firstPages.append(pageCount)
            for page in layout.pages {
                var media = CGRect(origin: .zero, size: layout.paper)
                let pageInfo = [kCGPDFContextMediaBox: Data(bytes: &media, count: MemoryLayout<CGRect>.size) as CFData] as CFDictionary
                context.beginPDFPage(pageInfo)
                draw(page, layout: layout, grid: grid, fonts: &fonts, in: context)
                context.endPDFPage()
                pageCount += 1
            }
        }
        context.closePDF()
        return firstPages
    }

    // MARK: Drawing

    private static func draw(_ page: SheetLayout.Page, layout: SheetLayout, grid: SheetGrid, fonts: inout SheetFonts, in context: CGContext) {
        let left = layout.margins, top = layout.paper.height - layout.margins
        let header = page.headerRows
        let headerHeight = header.isEmpty ? 0 : layout.rowY[header.upperBound] - layout.rowY[header.lowerBound]
        let bandWidth = layout.colX[page.columns.upperBound] - layout.colX[page.columns.lowerBound]

        /// Page x of a column's left edge (columns outside the band extrapolate, for merges that cross pages).
        func x(_ column: Int) -> CGFloat { left + layout.colX[column] - layout.colX[page.columns.lowerBound] }
        /// Page y (top edge, y up) of a row in the header or the body band.
        func y(_ row: Int, header isHeader: Bool) -> CGFloat {
            isHeader ? top - (layout.rowY[row] - layout.rowY[header.lowerBound])
                : top - headerHeight - (layout.rowY[row] - layout.rowY[page.rows.lowerBound])
        }

        var areas: [(rows: Range<Int>, isHeader: Bool, clip: CGRect)] = []
        if !header.isEmpty {
            areas.append((header, true, CGRect(x: left, y: top - headerHeight, width: bandWidth, height: headerHeight)))
        }
        let bodyHeight = layout.rowY[page.rows.upperBound] - layout.rowY[page.rows.lowerBound]
        areas.append((page.rows, false, CGRect(x: left, y: top - headerHeight - bodyHeight, width: bandWidth, height: bodyHeight)))

        for area in areas {
            context.saveGState()
            context.clip(to: area.clip)
            // Fills.
            for row in area.rows {
                let cells = grid.rows[row].cells
                for column in page.columns where column < cells.count {
                    guard let cell = cells[column], let fill = grid.styles[cell.style].fill, layout.merge(at: row, column) == nil else { continue }
                    context.setFillColor(fill.cgColor)
                    context.fill(CGRect(x: x(column), y: y(row + 1, header: area.isHeader), width: layout.widths[column], height: layout.heights[row]))
                }
            }
            // Merged areas: fill and text, clipped to this page's part.
            for (index, merge) in grid.merges.enumerated() where merge.right >= page.columns.lowerBound && merge.left < page.columns.upperBound
                && merge.bottom >= area.rows.lowerBound && merge.top < area.rows.upperBound && layout.validMerges.contains(index) {
                let rect = CGRect(x: x(merge.left), y: y(merge.bottom + 1, header: area.isHeader), width: layout.colX[merge.right + 1] - layout.colX[merge.left],
                                  height: layout.rowY[merge.bottom + 1] - layout.rowY[merge.top])
                guard merge.top < grid.rows.count, let cell = grid.rows[merge.top].cells[sheetAt: merge.left] ?? nil else { continue }
                let style = grid.styles[cell.style]
                if let fill = style.fill { context.setFillColor(fill.cgColor); context.fill(rect) }
                drawText(cell, style: style, in: rect, clip: rect, fonts: &fonts, context: context)
            }
            // Grid lines.
            if grid.gridlines {
                context.setStrokeColor(gridColor.cgColor)
                context.setLineWidth(0.4)
                for row in area.rows {
                    let rowTop = y(row, header: area.isHeader), rowBottom = rowTop - layout.heights[row]
                    for column in page.columns {
                        let cellLeft = x(column), cellRight = cellLeft + layout.widths[column]
                        let merge = layout.merge(at: row, column)
                        // Top edge, unless inside a merge; left edge likewise.
                        if merge == nil || merge!.top == row { context.sheetStroke(cellLeft, rowTop, cellRight, rowTop) }
                        if merge == nil || merge!.left == column { context.sheetStroke(cellLeft, rowTop, cellLeft, rowBottom) }
                        if row == area.rows.upperBound - 1 && (merge == nil || merge!.bottom == row) { context.sheetStroke(cellLeft, rowBottom, cellRight, rowBottom) }
                        if column == page.columns.upperBound - 1 && (merge == nil || merge!.right == column) { context.sheetStroke(cellRight, rowTop, cellRight, rowBottom) }
                    }
                }
            }
            // Borders and text.
            for row in area.rows {
                let cells = grid.rows[row].cells
                let rowTop = y(row, header: area.isHeader), height = layout.heights[row]
                for column in page.columns where column < cells.count {
                    guard let cell = cells[column] else { continue }
                    let style = grid.styles[cell.style]
                    let rect = CGRect(x: x(column), y: rowTop - height, width: layout.widths[column], height: height)
                    if style.hasBorder { drawBorders(style, rect: layout.merge(at: row, column).map { m in
                        CGRect(x: x(m.left), y: y(m.bottom + 1, header: area.isHeader), width: layout.colX[m.right + 1] - layout.colX[m.left],
                               height: layout.rowY[m.bottom + 1] - layout.rowY[m.top])
                    } ?? rect, context: context) }
                    guard layout.merge(at: row, column) == nil, !cell.text.isEmpty else { continue }
                    var clip = rect
                    // Text spills into empty cells to its right, as Excel prints it.
                    if !style.wrap, !cell.isNumber, style.horizontal == .general || style.horizontal == .left {
                        var next = column + 1
                        while next < page.columns.upperBound, (cells[sheetAt: next] ?? nil)?.text.isEmpty ?? true, layout.merge(at: row, next) == nil {
                            clip.size.width += layout.widths[next]
                            next += 1
                        }
                    }
                    drawText(cell, style: style, in: rect, clip: clip, fonts: &fonts, context: context)
                }
            }
            context.restoreGState()
        }
    }

    private static func drawBorders(_ style: SheetStyle, rect: CGRect, context: CGContext) {
        func stroke(_ edge: SheetEdge?, _ x1: CGFloat, _ y1: CGFloat, _ x2: CGFloat, _ y2: CGFloat) {
            guard let edge else { return }
            context.setStrokeColor(edge.color.cgColor)
            context.setLineWidth(edge.width)
            context.sheetStroke(x1, y1, x2, y2)
        }
        stroke(style.top, rect.minX, rect.maxY, rect.maxX, rect.maxY)
        stroke(style.bottom, rect.minX, rect.minY, rect.maxX, rect.minY)
        stroke(style.left, rect.minX, rect.minY, rect.minX, rect.maxY)
        stroke(style.right, rect.maxX, rect.minY, rect.maxX, rect.maxY)
    }

    private static func drawText(_ cell: SheetCell, style: SheetStyle, in rect: CGRect, clip: CGRect, fonts: inout SheetFonts, context: CGContext) {
        guard !cell.text.isEmpty else { return }
        let horizontal: SheetHorizontal = style.horizontal == .general ? (cell.isNumber ? .right : .left) : style.horizontal
        let inner = rect.insetBy(dx: padding, dy: min(padding, rect.height / 4))
        let indent = CGFloat(style.indent) * 9
        context.saveGState()
        context.clip(to: clip)
        context.textMatrix = .identity
        if style.wrap || cell.text.contains("\n") {
            let text = attributed(cell.text, style: style, fonts: &fonts, alignment: horizontal)
            let setter = CTFramesetterCreateWithAttributedString(text)
            let width = max(inner.width - indent, 1)
            let needed = CTFramesetterSuggestFrameSizeWithConstraints(setter, CFRange(), nil, CGSize(width: width, height: .greatestFiniteMagnitude), nil).height
            let height = min(needed, inner.height)
            let originY: CGFloat
            switch style.vertical {
            case .top: originY = inner.maxY - height
            case .center: originY = inner.midY - height / 2
            case .bottom: originY = inner.minY
            }
            let frameRect = CGRect(x: inner.minX + (horizontal == .left ? indent : 0), y: originY, width: width, height: max(needed, height) + 1)
            // A frame taller than the cell keeps its first lines at the top: shift it down by the overflow.
            let shifted = frameRect.offsetBy(dx: 0, dy: height - frameRect.height + 1)
            let frame = CTFramesetterCreateFrame(setter, CFRange(), CGPath(rect: shifted, transform: nil), nil)
            CTFrameDraw(frame, context)
        } else {
            var font = fonts.font(style.font)
            var line = CTLineCreateWithAttributedString(attributed(cell.text, style: style, font: font))
            var ascent: CGFloat = 0, descent: CGFloat = 0, leading: CGFloat = 0
            var width = CGFloat(CTLineGetTypographicBounds(line, &ascent, &descent, &leading))
            // Numbers never spill or cut off: they shrink to fit (down to half size).
            if cell.isNumber, width > inner.width, width > 0 {
                let scale = max(inner.width / width, 0.5)
                font = CTFontCreateCopyWithAttributes(font, CTFontGetSize(font) * scale, nil, nil)
                line = CTLineCreateWithAttributedString(attributed(cell.text, style: style, font: font))
                width = CGFloat(CTLineGetTypographicBounds(line, &ascent, &descent, &leading))
            }
            let x: CGFloat
            switch horizontal {
            case .general, .left: x = inner.minX + indent
            case .center: x = inner.midX - width / 2
            case .right: x = inner.maxX - width
            }
            let baseline: CGFloat
            switch style.vertical {
            case .top: baseline = inner.maxY - ascent
            case .center: baseline = inner.midY - (ascent - descent) / 2
            case .bottom: baseline = inner.minY + descent
            }
            context.textPosition = CGPoint(x: x, y: baseline)
            CTLineDraw(line, context)
        }
        context.restoreGState()
    }

    static func attributed(_ text: String, style: SheetStyle, font: CTFont) -> CFAttributedString {
        let attributes: [CFString: Any] = [kCTFontAttributeName: font, kCTForegroundColorAttributeName: (style.color ?? .black).cgColor]
        return CFAttributedStringCreate(nil, text as CFString, attributes as CFDictionary)
    }

    static func attributed(_ text: String, style: SheetStyle, fonts: inout SheetFonts, alignment: SheetHorizontal) -> CFAttributedString {
        var align: CTTextAlignment
        switch alignment {
        case .general, .left: align = .left
        case .center: align = .center
        case .right: align = .right
        }
        let paragraph = withUnsafeBytes(of: &align) { bytes in
            var setting = CTParagraphStyleSetting(spec: .alignment, valueSize: MemoryLayout<CTTextAlignment>.size, value: bytes.baseAddress!)
            return CTParagraphStyleCreate(&setting, 1)
        }
        let attributes: [CFString: Any] = [kCTFontAttributeName: fonts.font(style.font), kCTForegroundColorAttributeName: (style.color ?? .black).cgColor,
                                           kCTParagraphStyleAttributeName: paragraph]
        return CFAttributedStringCreate(nil, text as CFString, attributes as CFDictionary)
    }
}

/// Fonts by style, made once per render.
struct SheetFonts {
    private var cache: [SheetFont: CTFont] = [:]
    private var lineHeights: [SheetFont: CGFloat] = [:]

    mutating func font(_ spec: SheetFont) -> CTFont {
        if let font = cache[spec] { return font }
        let size = min(max(spec.size, 4), 144)
        var font: CTFont
        if let name = spec.name, !name.isEmpty {
            let candidate = CTFontCreateWithName(name as CFString, size, nil)
            let family = CTFontCopyFamilyName(candidate) as String
            // A family this Mac lacks (Calibri, Aptos) becomes the system font, a little smaller: it is wider.
            font = family.caseInsensitiveCompare(name) == .orderedSame ? candidate : CTFontCreateUIFontForLanguage(.system, size * 0.92, nil)!
        } else {
            font = CTFontCreateUIFontForLanguage(.system, size, nil)!
        }
        var traits: CTFontSymbolicTraits = []
        if spec.bold { traits.insert(.traitBold) }
        if spec.italic { traits.insert(.traitItalic) }
        if !traits.isEmpty, let styled = CTFontCreateCopyWithSymbolicTraits(font, 0, nil, traits, traits) { font = styled }
        cache[spec] = font
        return font
    }

    mutating func lineHeight(_ spec: SheetFont) -> CGFloat {
        if let height = lineHeights[spec] { return height }
        let f = font(spec)
        let height = ceil(CTFontGetAscent(f) + CTFontGetDescent(f) + CTFontGetLeading(f))
        lineHeights[spec] = height
        return height
    }

    /// The width of `text` on one line.
    mutating func width(_ text: String, _ spec: SheetFont) -> CGFloat {
        let line = CTLineCreateWithAttributedString(CFAttributedStringCreate(nil, text as CFString, [kCTFontAttributeName: font(spec)] as CFDictionary))
        return CGFloat(CTLineGetTypographicBounds(line, nil, nil, nil))
    }
}

/// Where every row and column of a grid falls, and how the grid splits into pages.
struct SheetLayout {
    struct Page {
        var rows: Range<Int>
        var columns: Range<Int>
        /// The repeated header rows drawn above `rows` (empty on pages that start with them).
        var headerRows: Range<Int>
    }

    let paper: CGSize
    let margins: CGFloat
    /// Column widths and row heights after fitting (points).
    let widths: [CGFloat]
    let heights: [CGFloat]
    /// Prefix sums: colX[i] is the left of column i, rowY[i] the top of row i (from the grid's top).
    let colX: [CGFloat]
    let rowY: [CGFloat]
    let pages: [Page]
    /// Merges whose cells are all in the grid; covered cells map to their merge.
    let validMerges: Set<Int>
    private let mergeIndex: [Int: SheetMerge]
    private let columnCount: Int

    func merge(at row: Int, _ column: Int) -> SheetMerge? {
        mergeIndex.isEmpty ? nil : mergeIndex[row * columnCount + column]
    }

    init(grid: SheetGrid, paper portrait: CGSize, margins: CGFloat, fonts: inout SheetFonts) {
        let portraitWidth = portrait.width - 2 * margins
        let total = grid.columns.reduce(0, +)
        let isPortrait = portrait.height >= portrait.width
        let landscape = isPortrait && (grid.prefersLandscape || total > portraitWidth)
        paper = landscape ? CGSize(width: portrait.height, height: portrait.width) : portrait
        self.margins = margins
        let content = CGSize(width: max(paper.width - 2 * margins, 36), height: max(paper.height - 2 * margins, 36))
        columnCount = grid.columns.count

        // Merges: keep those inside the grid; index every covered cell (bounded, so a sheet-sized merge can't explode).
        var index: [Int: SheetMerge] = [:]
        var valid: Set<Int> = []
        var budget = 2_000_000
        for (i, merge) in grid.merges.enumerated() {
            guard merge.top <= merge.bottom, merge.left <= merge.right, merge.top >= 0, merge.left >= 0,
                  merge.bottom < grid.rows.count, merge.right < grid.columns.count else { continue }
            let area = (merge.bottom - merge.top + 1) * (merge.right - merge.left + 1)
            guard area > 1, area <= budget else { continue }
            budget -= area
            valid.insert(i)
            for r in merge.top...merge.bottom { for c in merge.left...merge.right { index[r * grid.columns.count + c] = merge } }
        }
        mergeIndex = index
        validMerges = valid

        let widths = grid.columns.map { min(max($0, 0), content.width) }
        // Row heights: the row's own, else what its cells need.
        var heights: [CGFloat] = []
        heights.reserveCapacity(grid.rows.count)
        for (r, row) in grid.rows.enumerated() {
            var height = row.height ?? grid.defaultRowHeight
            if row.height == nil {
                for (c, cell) in row.cells.enumerated() {
                    guard let cell, !cell.text.isEmpty, c < widths.count, index[r * grid.columns.count + c] == nil else { continue }
                    let style = grid.styles[cell.style]
                    let lineHeight = fonts.lineHeight(style.font)
                    var needed = lineHeight + 2
                    if style.wrap || cell.text.contains("\n") {
                        let text = SheetRenderer.attributed(cell.text, style: style, fonts: &fonts, alignment: .left)
                        let setter = CTFramesetterCreateWithAttributedString(text)
                        let size = CTFramesetterSuggestFrameSizeWithConstraints(setter, CFRange(), nil,
                                                                                CGSize(width: max(widths[c] - 2 * SheetRenderer.padding, 1), height: .greatestFiniteMagnitude), nil)
                        needed = ceil(size.height) + 2 * SheetRenderer.padding
                    }
                    height = max(height, needed)
                }
            }
            heights.append(height)
        }
        let headerCount = min(grid.repeatRows, grid.rows.count)
        let headerHeight = heights.prefix(headerCount).reduce(0, +)
        // A header taller than half a page isn't repeated.
        let repeats = headerCount > 0 && headerHeight <= content.height / 2
        let bodyLimit = content.height - (repeats ? headerHeight : 0)
        heights = heights.enumerated().map { r, h in min(h, r < headerCount ? content.height : bodyLimit) }
        self.widths = widths
        self.heights = heights

        var colX: [CGFloat] = [0]
        for w in widths { colX.append(colX.last! + w) }
        var rowY: [CGFloat] = [0]
        for h in heights { rowY.append(rowY.last! + h) }
        self.colX = colX
        self.rowY = rowY

        // Column bands across, row bands down; pages go down each column band, then over.
        var columnBands: [Range<Int>] = []
        var start = 0
        while start < widths.count {
            var end = start, used: CGFloat = 0
            while end < widths.count, used + widths[end] <= content.width + 0.01 || end == start { used += widths[end]; end += 1 }
            columnBands.append(start..<end)
            start = end
        }
        var rowBands: [Range<Int>] = []
        start = 0
        while start < heights.count {
            let limit = (repeats && start >= headerCount) ? bodyLimit : content.height
            var end = start, used: CGFloat = 0
            while end < heights.count, used + heights[end] <= limit + 0.01 || end == start { used += heights[end]; end += 1 }
            rowBands.append(start..<end)
            start = end
        }
        var pages: [Page] = []
        for columns in columnBands {
            for rows in rowBands {
                let header = repeats && rows.lowerBound >= headerCount ? 0..<headerCount : 0..<0
                pages.append(Page(rows: rows, columns: columns, headerRows: header))
            }
        }
        self.pages = pages
    }
}

extension CGContext {
    fileprivate func sheetStroke(_ x1: CGFloat, _ y1: CGFloat, _ x2: CGFloat, _ y2: CGFloat) {
        beginPath()
        move(to: CGPoint(x: x1, y: y1))
        addLine(to: CGPoint(x: x2, y: y2))
        strokePath()
    }
}

extension Array {
    fileprivate subscript(sheetAt index: Int) -> Element? { indices.contains(index) ? self[index] : nil }
}
