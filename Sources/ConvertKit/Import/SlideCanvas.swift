import CoreGraphics
import Foundation

// One slide drawn into a PDF page: the background (slide → layout → master), the master's and the layout's own shapes
// unless hidden, then the slide's shapes, pictures, groups and tables. Placeholders take their position, body and list
// styles from the matching placeholder on the layout and the master. Page space is points with y down.

/// A placeholder reference (`p:ph`).
struct SlidePlaceholder: Equatable {
    var type: String
    var idx: String?

    /// The master placeholder kind a type inherits from.
    var masterType: String {
        switch type {
        case "title", "ctrTitle": "title"
        case "dt", "ftr", "sldNum", "hdr": type
        default: "body"
        }
    }

    var layoutType: String { type == "ctrTitle" ? "title" : type }
}

final class SlideCanvas {
    let deck: SlideDeck
    let slide: SlidePart
    let layout: SlidePart?
    let master: SlidePart?
    let number: Int
    let cg: CGContext
    let colors: SlideColorContext
    private var shapeCount = 0
    private var title: String?
    private var leftOut = false

    init(deck: SlideDeck, slide: SlidePart, number: Int, context: CGContext) throws {
        self.deck = deck
        self.slide = slide
        self.number = number
        cg = context
        layout = try deck.part(slide.target(ofType: "/slideLayout"))
        master = try deck.part(layout?.target(ofType: "/slideMaster"))
        var map = SlideColorContext.defaultMap
        for (key, value) in master?.root.child("clrMap")?.attributes ?? [:] { map[key] = value }
        for part in [layout, slide] {
            for (key, value) in part?.root.child("clrMapOvr")?.child("overrideClrMapping")?.attributes ?? [:] { map[key] = value }
        }
        colors = SlideColorContext(theme: deck.theme(for: master), map: map, placeholder: nil)
    }

    /// Draws the slide; returns its title (the title placeholder's text) and whether something was left out.
    func draw() throws -> (text: String?, leftOut: Bool) {
        drawBackground()
        let top = CGAffineTransform(scaleX: 1 / slideEMU, y: 1 / slideEMU)
        let slideShowsMaster = SlideRunProps.flag(slide.root.attr("showMasterSp")) ?? true
        let layoutShowsMaster = SlideRunProps.flag(layout?.root.attr("showMasterSp")) ?? true
        if slideShowsMaster, layoutShowsMaster, let master, let tree = master.root.path("cSld/spTree") {
            drawTree(tree, part: master, mapper: top, decorations: true, depth: 0, group: nil)
        }
        if slideShowsMaster, let layout, let tree = layout.root.path("cSld/spTree") {
            drawTree(tree, part: layout, mapper: top, decorations: true, depth: 0, group: nil)
        }
        if let tree = slide.root.path("cSld/spTree") {
            drawTree(tree, part: slide, mapper: top, decorations: false, depth: 0, group: nil)
        }
        return (title, leftOut)
    }

    // MARK: Background

    private func drawBackground() {
        var fill: SlideFill = .solid(.white)
        for part in [slide, layout, master].compactMap({ $0 }) {
            guard let bg = part.root.path("cSld/bg") else { continue }
            let paint = SlidePaint(deck: deck, part: part, colors: colors)
            if let found = paint.fill(in: bg.child("bgPr")) ?? paint.themeFill(bg.child("bgRef")) { fill = found; break }
        }
        SlideDraw.fill(CGPath(rect: CGRect(origin: .zero, size: deck.size), transform: nil), with: fill, in: cg)
    }

    // MARK: Trees

    private func drawTree(_ tree: XMLNode, part: SlidePart, mapper: CGAffineTransform, decorations: Bool, depth: Int, group: SlideFill?) {
        guard depth <= SlideLimits.groupDepth else { return }
        for child in tree.children {
            guard shapeCount < SlideLimits.shapesPerSlide else { return }
            switch child.name {
            case "sp", "cxnSp":
                if decorations, Self.placeholder(child) != nil { continue }
                shapeCount += 1
                drawShape(child, part: part, mapper: mapper, group: group)
            case "pic":
                if decorations, Self.placeholder(child) != nil { continue }
                shapeCount += 1
                drawPicture(child, part: part, mapper: mapper)
            case "grpSp":
                shapeCount += 1
                drawGroup(child, part: part, mapper: mapper, decorations: decorations, depth: depth, group: group)
            case "graphicFrame":
                if decorations, Self.placeholder(child) != nil { continue }
                shapeCount += 1
                drawGraphicFrame(child, part: part, mapper: mapper)
            case "AlternateContent":
                if let branch = Self.branch(child) { drawTree(branch, part: part, mapper: mapper, decorations: decorations, depth: depth + 1, group: group) }
            default:
                continue
            }
        }
    }

    /// `mc:AlternateContent`: the choice when everything in it is something drawn here, else the fallback.
    static func branch(_ node: XMLNode) -> XMLNode? {
        let choice = node.child("Choice"), fallback = node.child("Fallback")
        if let choice, choice.children.allSatisfy(isDrawable) { return choice }
        return fallback ?? choice
    }

    private static func isDrawable(_ node: XMLNode) -> Bool {
        switch node.name {
        case "sp", "cxnSp", "pic", "grpSp": true
        case "graphicFrame": node.child("graphic")?.child("graphicData")?.child("tbl") != nil
        default: false
        }
    }

    private func drawGroup(_ group: XMLNode, part: SlidePart, mapper: CGAffineTransform, decorations: Bool, depth: Int, group parentFill: SlideFill?) {
        let props = group.child("grpSpPr")
        let groupFill = SlidePaint(deck: deck, part: part, colors: colors).fill(in: props, group: parentFill) ?? parentFill
        guard let xfrm = SlideXfrm(props?.child("xfrm")) else {
            drawTree(group, part: part, mapper: mapper, decorations: decorations, depth: depth + 1, group: groupFill)
            return
        }
        let child = xfrm.childRect ?? xfrm.rect
        let sx = child.width != 0 ? xfrm.rect.width / child.width : 1
        let sy = child.height != 0 ? xfrm.rect.height / child.height : 1
        let childToParent = CGAffineTransform(translationX: -child.minX, y: -child.minY)
            .concatenating(CGAffineTransform(scaleX: sx, y: sy))
            .concatenating(CGAffineTransform(translationX: xfrm.rect.minX, y: xfrm.rect.minY))
        let frame = xfrm.rect.applying(mapper)
        cg.saveGState()
        cg.concatenate(SlideXfrm.transform(for: frame, rotation: xfrm.rotation, flipH: xfrm.flipH, flipV: xfrm.flipV))
        drawTree(group, part: part, mapper: childToParent.concatenating(mapper), decorations: decorations, depth: depth + 1, group: groupFill)
        cg.restoreGState()
    }

    // MARK: Placeholders

    static func placeholder(_ shape: XMLNode) -> SlidePlaceholder? {
        guard let ph = shape.children.first(where: { $0.name.hasPrefix("nv") })?.child("nvPr")?.child("ph") else { return nil }
        return SlidePlaceholder(type: ph.attr("type") ?? "obj", idx: ph.attr("idx"))
    }

    /// The placeholders a shape of `part` inherits from: on the layout (by index, then type) and on the master (by kind).
    private func inherited(_ placeholder: SlidePlaceholder, in part: SlidePart) -> [(node: XMLNode, part: SlidePart)] {
        var chain: [(XMLNode, SlidePart)] = []
        if part === slide, let layout, let match = Self.find(placeholder, in: layout, byIndex: true) { chain.append((match, layout)) }
        if part !== master, let master, let match = Self.find(placeholder, in: master, byIndex: false) { chain.append((match, master)) }
        return chain
    }

    private static func find(_ placeholder: SlidePlaceholder, in part: SlidePart, byIndex: Bool) -> XMLNode? {
        let candidates = (part.root.path("cSld/spTree")?.children ?? []).filter { Self.placeholder($0) != nil }
        if byIndex, let idx = placeholder.idx, let match = candidates.first(where: { Self.placeholder($0)?.idx == idx }) { return match }
        return candidates.first { candidate in
            guard let other = Self.placeholder(candidate) else { return false }
            return byIndex ? other.layoutType == placeholder.layoutType : other.masterType == placeholder.masterType
        }
    }

    /// The master text style a shape's text starts from.
    private func masterStyle(_ placeholder: SlidePlaceholder?) -> XMLNode? {
        let styles = master?.root.child("txStyles")
        switch placeholder?.masterType {
        case "title": return styles?.child("titleStyle")
        case "body": return styles?.child("bodyStyle")
        default: return styles?.child("otherStyle")
        }
    }

    private func textContext(placeholder: SlidePlaceholder?, chain: [(node: XMLNode, part: SlidePart)], style: XMLNode?,
                             extra: [SlideStyleLayer] = [], bodies: [XMLNode] = []) -> SlideTextContext {
        var layers = extra
        if let fontRef = style?.child("fontRef") {
            var run = SlideRunProps()
            run.color = colors.color(fontRef)
            switch fontRef.attr("idx") {
            case "major": run.typeface = "+mj-lt"
            case "minor": run.typeface = "+mn-lt"
            default: break
            }
            layers.append(.run(run))
        }
        for (node, _) in chain {
            if let list = node.child("txBody")?.child("lstStyle") { layers.append(.list(list)) }
        }
        if let style = masterStyle(placeholder) { layers.append(.list(style)) }
        if let defaults = deck.presentation.root.child("defaultTextStyle") { layers.append(.list(defaults)) }
        return SlideTextContext(layers: layers, bodies: bodies + chain.compactMap { $0.node.child("txBody")?.child("bodyPr") }, colors: colors,
                                slideNumber: number, defaultTypeface: placeholder?.masterType == "title" ? "+mj-lt" : "+mn-lt")
    }

    // MARK: Shapes

    private func drawShape(_ shape: XMLNode, part: SlidePart, mapper: CGAffineTransform, group: SlideFill?) {
        let placeholder = Self.placeholder(shape)
        let chain = placeholder.map { inherited($0, in: part) } ?? []
        let spPr = shape.child("spPr")
        guard let xfrm = SlideXfrm(spPr?.child("xfrm")) ?? chain.lazy.compactMap({ SlideXfrm($0.node.child("spPr")?.child("xfrm")) }).first else { return }
        let frame = xfrm.rect.applying(mapper)
        guard frame.minX.isFinite, frame.minY.isFinite, frame.width.isFinite, frame.height.isFinite else { return }
        let paint = SlidePaint(deck: deck, part: part, colors: colors)
        let style = shape.child("style")

        let geometryOwner = ([spPr] + chain.map { $0.node.child("spPr") }).first { $0?.child("prstGeom") != nil || $0?.child("custGeom") != nil } ?? spPr
        let geometry = SlideGeometry.path(in: geometryOwner, rect: frame)
        var fill = paint.fill(in: spPr, group: group) ?? paint.themeFill(style?.child("fillRef"))
        var line = paint.line(spPr?.child("ln"), fallback: paint.themeLine(style?.child("lnRef")))
        if fill == nil || (spPr?.child("ln") == nil && style == nil) {
            for (node, owner) in chain {
                let inheritedPaint = SlidePaint(deck: deck, part: owner, colors: colors)
                if fill == nil { fill = inheritedPaint.fill(in: node.child("spPr")) ?? inheritedPaint.themeFill(node.child("style")?.child("fillRef")) }
                if line == nil { line = inheritedPaint.line(node.child("spPr")?.child("ln"), fallback: inheritedPaint.themeLine(node.child("style")?.child("lnRef"))) }
            }
        }

        cg.saveGState()
        cg.concatenate(SlideXfrm.transform(for: frame, rotation: xfrm.rotation, flipH: xfrm.flipH, flipV: xfrm.flipV))
        if !geometry.isOpen { SlideDraw.fill(geometry.path, with: fill, in: cg) }
        SlideDraw.stroke(geometry.path, with: line, in: cg, ends: geometry.ends)
        cg.restoreGState()

        guard let body = shape.child("txBody") else { return }
        cg.saveGState()
        cg.concatenate(SlideXfrm.transform(for: frame, rotation: xfrm.rotation + (xfrm.flipV ? 180 : 0), flipH: false, flipV: false))
        let text = SlideText.draw(body, in: frame, context: textContext(placeholder: placeholder, chain: chain, style: style), cg: cg)
        cg.restoreGState()
        if part === slide, title == nil, placeholder?.masterType == "title" { title = Self.outlineTitle(text) }
    }

    /// Text as a contents entry: one line, at most 200 characters; nil when empty.
    static func outlineTitle(_ text: String) -> String? {
        let words = text.components(separatedBy: CharacterSet.whitespacesAndNewlines.union(CharacterSet(charactersIn: "\u{2028}\u{2029}")))
            .filter { !$0.isEmpty }
        guard !words.isEmpty else { return nil }
        return String(words.joined(separator: " ").prefix(200))
    }

    // MARK: Pictures

    private func drawPicture(_ picture: XMLNode, part: SlidePart, mapper: CGAffineTransform) {
        let placeholder = Self.placeholder(picture)
        let chain = placeholder.map { inherited($0, in: part) } ?? []
        let spPr = picture.child("spPr")
        guard let xfrm = SlideXfrm(spPr?.child("xfrm")) ?? chain.lazy.compactMap({ SlideXfrm($0.node.child("spPr")?.child("xfrm")) }).first else { return }
        let frame = xfrm.rect.applying(mapper)
        guard let blipFill = picture.child("blipFill") else { return }
        cg.saveGState()
        cg.concatenate(SlideXfrm.transform(for: frame, rotation: xfrm.rotation, flipH: xfrm.flipH, flipV: xfrm.flipV))
        let geometry = SlideGeometry.path(in: spPr, rect: frame)
        drawBlip(blipFill, part: part, in: frame, clip: geometry.path)
        SlideDraw.stroke(geometry.path, with: SlidePaint(deck: deck, part: part, colors: colors).line(spPr?.child("ln")), in: cg)
        cg.restoreGState()
    }

    /// A `blipFill` inside `frame`, cropped by `srcRect`, clipped to the shape.
    private func drawBlip(_ blipFill: XMLNode, part: SlidePart, in frame: CGRect, clip: CGPath) {
        guard let blip = blipFill.child("blip"), let id = blip.attr("r:embed"), let image = deck.image(part, id) else { return }
        func fraction(_ key: String) -> Double {
            guard let v = Double(blipFill.child("srcRect")?.attr(key) ?? ""), v.isFinite else { return 0 }
            return min(max(v / 100_000, -10), 0.99)
        }
        let l = fraction("l"), t = fraction("t"), r = fraction("r"), b = fraction("b")
        let w = 1 - l - r, h = 1 - t - b
        guard w > 0.001, h > 0.001 else { return }
        let imageRect = CGRect(x: frame.minX - frame.width * l / w, y: frame.minY - frame.height * t / h, width: frame.width / w, height: frame.height / h)
        cg.saveGState()
        if let amount = blip.child("alphaModFix")?.attr("amt").flatMap(Double.init), amount.isFinite { cg.setAlpha(CGFloat(min(max(amount / 100_000, 0), 1))) }
        cg.addPath(clip)
        cg.clip()
        SlideDraw.drawImage(image, in: imageRect, context: cg)
        cg.restoreGState()
    }

    // MARK: Graphic frames (tables, charts, diagrams, embedded objects)

    private func drawGraphicFrame(_ node: XMLNode, part: SlidePart, mapper: CGAffineTransform) {
        let placeholder = Self.placeholder(node)
        let chain = placeholder.map { inherited($0, in: part) } ?? []
        guard let xfrm = SlideXfrm(node.child("xfrm")) ?? chain.lazy.compactMap({ SlideXfrm($0.node.child("spPr")?.child("xfrm")) }).first else { return }
        let frame = xfrm.rect.applying(mapper)
        let data = node.child("graphic")?.child("graphicData")
        if let table = data?.child("tbl") {
            drawTable(table, at: frame, part: part)
        } else if let picture = data?.first("pic"), let blipFill = picture.child("blipFill") {
            // Embedded objects carry the picture Office last drew of them.
            drawBlip(blipFill, part: part, in: frame, clip: CGPath(rect: frame, transform: nil))
        } else {
            leftOut = true
        }
    }

    // MARK: Tables

    private func drawTable(_ table: XMLNode, at frame: CGRect, part: SlidePart) {
        let columns = (table.child("tblGrid")?.children("gridCol") ?? []).map { CGFloat(max(min((Double($0.attr("w") ?? "") ?? 0) / slideEMU, 14_400), 0)) }
        let rows = table.children("tr")
        guard !columns.isEmpty, !rows.isEmpty, rows.count * columns.count <= SlideLimits.tableCells else {
            if !rows.isEmpty { leftOut = true }
            return
        }
        let style = SlideTableStyle(table.child("tblPr"), deck: deck, colors: colors, rows: rows.count, columns: columns.count)
        var xs: [CGFloat] = [frame.minX]
        for width in columns { xs.append(xs[xs.count - 1] + width) }
        func cellWidth(_ column: Int, _ span: Int) -> CGFloat { xs[min(column + span, columns.count)] - xs[min(column, columns.count)] }

        let paint = SlidePaint(deck: deck, part: part, colors: colors)
        var heights = rows.map { CGFloat(max(min((Double($0.attr("h") ?? "") ?? 0) / slideEMU, 14_400), 0)) }
        for (r, row) in rows.enumerated() {
            for (c, cell) in row.children("tc").prefix(columns.count).enumerated() {
                guard !Self.isCovered(cell), Int(cell.attr("rowSpan") ?? "") ?? 1 <= 1, let body = cell.child("txBody") else { continue }
                let span = max(Int(cell.attr("gridSpan") ?? "") ?? 1, 1)
                let context = cellTextContext(cell, row: r, column: c, style: style)
                heights[r] = max(heights[r], SlideText.height(body, width: cellWidth(c, span), context: context))
            }
        }
        var ys: [CGFloat] = [frame.minY]
        for height in heights { ys.append(ys[ys.count - 1] + height) }

        var borders: [(CGPoint, CGPoint, SlideLine)] = []
        for (r, row) in rows.enumerated() {
            for (c, cell) in row.children("tc").prefix(columns.count).enumerated() where !Self.isCovered(cell) {
                let span = max(Int(cell.attr("gridSpan") ?? "") ?? 1, 1)
                let rowSpan = max(Int(cell.attr("rowSpan") ?? "") ?? 1, 1)
                let rect = CGRect(x: xs[c], y: ys[r], width: cellWidth(c, span), height: ys[min(r + rowSpan, rows.count)] - ys[r])
                let tcPr = cell.child("tcPr")
                let fill = paint.fill(in: tcPr) ?? style.fill(row: r, column: c)
                SlideDraw.fill(CGPath(rect: rect, transform: nil), with: fill, in: cg)
                if let body = cell.child("txBody") {
                    SlideText.draw(body, in: rect, context: cellTextContext(cell, row: r, column: c, style: style), cg: cg)
                }
                let lastRow = r + rowSpan >= rows.count, lastColumn = c + span >= columns.count
                let edges: [(String, String, CGPoint, CGPoint)] = [
                    ("lnL", c == 0 ? "left" : "insideV", CGPoint(x: rect.minX, y: rect.minY), CGPoint(x: rect.minX, y: rect.maxY)),
                    ("lnR", lastColumn ? "right" : "insideV", CGPoint(x: rect.maxX, y: rect.minY), CGPoint(x: rect.maxX, y: rect.maxY)),
                    ("lnT", r == 0 ? "top" : "insideH", CGPoint(x: rect.minX, y: rect.minY), CGPoint(x: rect.maxX, y: rect.minY)),
                    ("lnB", lastRow ? "bottom" : "insideH", CGPoint(x: rect.minX, y: rect.maxY), CGPoint(x: rect.maxX, y: rect.maxY)),
                ]
                for (own, styled, start, end) in edges {
                    let line: SlideLine?
                    if let explicit = tcPr?.child(own) { line = paint.line(explicit) } else { line = style.border(styled, row: r, column: c) }
                    if let line { borders.append((start, end, line)) }
                }
            }
        }
        for (start, end, line) in borders {
            let path = CGMutablePath()
            path.addLines(between: [start, end])
            SlideDraw.stroke(path, with: line, in: cg)
        }
    }

    /// Cells hidden under a merged neighbour.
    private static func isCovered(_ cell: XMLNode) -> Bool {
        ["1", "true"].contains(cell.attr("hMerge") ?? "") || ["1", "true"].contains(cell.attr("vMerge") ?? "")
    }

    private func cellTextContext(_ cell: XMLNode, row: Int, column: Int, style: SlideTableStyle) -> SlideTextContext {
        let tcPr = cell.child("tcPr")
        var attributes: [String: String] = ["lIns": "91440", "rIns": "91440", "tIns": "45720", "bIns": "45720", "anchor": tcPr?.attr("anchor") ?? "t"]
        for (own, key) in [("marL", "lIns"), ("marR", "rIns"), ("marT", "tIns"), ("marB", "bIns")] {
            if let value = tcPr?.attr(own) { attributes[key] = value }
        }
        return textContext(placeholder: nil, chain: [], style: nil, extra: [.run(style.text(row: row, column: column))],
                           bodies: [XMLNode("a:bodyPr", attributes: attributes)])
    }
}

/// A table style (`ppt/tableStyles.xml`, or PowerPoint's default "Medium Style 2 – Accent 1" when the file names a
/// style it doesn't include): fills, cell text and borders for the whole table and its banded parts.
struct SlideTableStyle {
    struct Part {
        var fill: SlideFill?
        var text = SlideRunProps()
        var borders: [String: SlideLine] = [:]
    }

    var parts: [String: Part] = [:]
    let firstRow: Bool, lastRow: Bool, firstColumn: Bool, lastColumn: Bool, bandRows: Bool, bandColumns: Bool
    let rows: Int, columns: Int

    static let defaultStyleID = "{5C22544A-7EE6-4342-B048-85BDC9FD1C3A}"

    init(_ tblPr: XMLNode?, deck: SlideDeck, colors: SlideColorContext, rows: Int, columns: Int) {
        func on(_ key: String) -> Bool { SlideRunProps.flag(tblPr?.attr(key)) ?? false }
        firstRow = on("firstRow"); lastRow = on("lastRow"); firstColumn = on("firstCol"); lastColumn = on("lastCol")
        bandRows = on("bandRow"); bandColumns = on("bandCol")
        self.rows = rows; self.columns = columns
        guard let id = tblPr?.child("tableStyleId")?.text.trimmingCharacters(in: .whitespacesAndNewlines), !id.isEmpty else { return }
        let stylesPath = deck.presentation.target(ofType: "/tableStyles")
        let stylesPart = (try? deck.part(stylesPath)) ?? nil
        if let stylesPart, let style = stylesPart.root.children("tblStyle").first(where: { $0.attr("styleId") == id }) {
            let paint = SlidePaint(deck: deck, part: stylesPart, colors: colors)
            for node in style.children {
                var part = Part()
                if let tcStyle = node.child("tcStyle") {
                    part.fill = paint.fill(in: tcStyle.child("fill")) ?? paint.themeFill(tcStyle.child("fillRef"))
                    for edge in tcStyle.child("tcBdr")?.children ?? [] {
                        if let line = paint.line(edge.child("ln")) ?? paint.themeLine(edge.child("lnRef")) { part.borders[edge.name] = line }
                    }
                }
                if let text = node.child("tcTxStyle") {
                    part.text.bold = SlideRunProps.flag(text.attr("b"))
                    part.text.italic = SlideRunProps.flag(text.attr("i"))
                    part.text.color = colors.color(text)
                    if text.child("fontRef")?.attr("idx") == "major" { part.text.typeface = "+mj-lt" }
                }
                parts[node.name] = part
            }
        } else {
            // PowerPoint's default style, which files name without always including it.
            let accent = colors.scheme("accent1") ?? SlideColor(r: 0.27, g: 0.45, b: 0.77)
            let light = colors.scheme("lt1") ?? .white
            let white = SlideLine(width: 1, fill: .solid(light))
            let borders = ["left": white, "right": white, "top": white, "bottom": white, "insideH": white, "insideV": white]
            var header = SlideRunProps(); header.bold = true; header.color = light
            var body = SlideRunProps(); body.color = colors.scheme("dk1") ?? .black
            parts["wholeTbl"] = Part(fill: .solid(SlideColor.white.mixed(with: accent, 0.2)), text: body, borders: borders)
            parts["band1H"] = Part(fill: .solid(SlideColor.white.mixed(with: accent, 0.4)))
            parts["band1V"] = Part(fill: .solid(SlideColor.white.mixed(with: accent, 0.4)))
            parts["firstRow"] = Part(fill: .solid(accent), text: header, borders: ["bottom": SlideLine(width: 3, fill: .solid(light))])
            parts["lastRow"] = Part(fill: .solid(accent), text: header)
            parts["firstCol"] = Part(fill: .solid(accent), text: header)
            parts["lastCol"] = Part(fill: .solid(accent), text: header)
        }
    }

    /// The style parts that apply to a cell, weakest first.
    private func applicable(row: Int, column: Int) -> [Part] {
        var names = ["wholeTbl"]
        let dataRow = row - (firstRow ? 1 : 0), dataColumn = column - (firstColumn ? 1 : 0)
        if bandColumns, dataColumn >= 0 { names.append(dataColumn % 2 == 0 ? "band1V" : "band2V") }
        if bandRows, dataRow >= 0 { names.append(dataRow % 2 == 0 ? "band1H" : "band2H") }
        if lastColumn, column == columns - 1 { names.append("lastCol") }
        if firstColumn, column == 0 { names.append("firstCol") }
        if lastRow, row == rows - 1 { names.append("lastRow") }
        if firstRow, row == 0 { names.append("firstRow") }
        return names.compactMap { parts[$0] }
    }

    func fill(row: Int, column: Int) -> SlideFill? {
        applicable(row: row, column: column).compactMap(\.fill).last
    }

    func text(row: Int, column: Int) -> SlideRunProps {
        applicable(row: row, column: column).reduce(SlideRunProps()) { $1.text.merged(over: $0) }
    }

    func border(_ edge: String, row: Int, column: Int) -> SlideLine? {
        applicable(row: row, column: column).compactMap { $0.borders[edge] }.last
    }
}
