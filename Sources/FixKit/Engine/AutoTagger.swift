import CoreGraphics
import Foundation
import PDFModelKit
import SuperPDFCore

// Auto-tagging (features #97 "Fix for me"): LayoutKit's blocks, tables, figures and reading order become the structure
// tree. Each text object, picture and form drawn on a page is wrapped in marked content with an MCID and hung under
// the element whose block (or table cell, or figure) holds it; running headers and footers, page numbers and plain
// drawing become artifacts. Headings keep their level, list items become L/LI/LBody, tables TR with TH for a header
// row, pictures Figure with their description and bounding box.

/// A picture a description can be given to: on an untagged file a figure LayoutKit found ("l:<page>:<figure id>"), on
/// a tagged one a Figure element of its structure tree ("s:<n>", depth-first).
struct FigureRef: Hashable, Sendable {
    var key: String
    /// 0-based.
    var page: Int
    var hasDescription: Bool
}

enum AutoTagger {
    /// Tags `model` from `layout` (pages without an analysis get one P per text object). `descriptions` are alt texts by
    /// `FigureRef.key`.
    static func tag(_ model: PDFModel, layout: LayoutDocument, descriptions: [String: String]) throws {
        let byIndex = Dictionary(layout.pages.map { ($0.index, $0) }, uniquingKeysWith: { first, _ in first })
        var elements: [PDFStructureElement] = []
        for (index, page) in model.pages.enumerated() {
            guard let operations = ContentWalker.operations(of: page) else { continue }
            let (tagged, pageElements) = tag(operations, page: page, index: index, layout: byIndex[index], descriptions: descriptions)
            page.setContentStream(PDFContentStream(operations: tagged))
            elements += pageElements
            if !page.annotations.isEmpty { page.object.set("Tabs", .name("S")) }
        }
        try model.setStructureTree(PDFStructureTree(elements: [PDFStructureElement(type: "Document", kids: elements.map { .element($0) })]))
    }

    // MARK: One page

    private enum Kind {
        case text(CGPoint)
        case picture(CGRect)
        case form(CGRect)
        case drawing
    }

    private struct Item {
        var start: Int
        var end: Int
        var kind: Kind
    }

    /// Where an item goes.
    private enum Target: Hashable {
        case block(Int)
        case cell(table: Int, row: Int, column: Int)
        case figure(String)
        case orphan(Int)
        case artifact
    }

    private static func tag(_ operations: [PDFContentOperation], page: PDFPage, index: Int, layout: LayoutPage?,
                            descriptions: [String: String]) -> ([PDFContentOperation], [PDFStructureElement]) {
        let items = self.items(operations, resources: page.resources)
        let crop = page.box(.crop)
        let origin = CGPoint(x: crop.minX, y: crop.minY)
        func local(_ p: CGPoint) -> CGPoint { CGPoint(x: p.x - origin.x, y: p.y - origin.y) }
        func local(_ r: CGRect) -> CGRect { r.offsetBy(dx: -origin.x, dy: -origin.y) }

        // Assign every item.
        var targets: [Target] = []
        var orphan = 0
        var figureRects: [String: CGRect] = [:]
        var lastTextTarget: Target?
        for item in items {
            let target: Target
            switch item.kind {
            case .text(let point):
                target = textTarget(local(point), layout: layout) ?? {
                    if case .orphan? = lastTextTarget { return lastTextTarget! }
                    orphan += 1
                    return .orphan(orphan)
                }()
                lastTextTarget = target
            case .picture(let rect):
                if rect.width * rect.height < 64 {
                    target = .artifact
                } else {
                    let key = figure(local(rect), layout: layout).map { "l:\(index):\($0)" } ?? "l:\(index):p\(item.start)"
                    figureRects[key] = rect
                    target = .figure(key)
                }
            case .form(let rect):
                let centre = local(CGPoint(x: rect.midX, y: rect.midY))
                if let text = textTarget(centre, layout: layout) {
                    target = text
                } else if let id = figure(local(rect), layout: layout) {
                    let key = "l:\(index):\(id)"
                    figureRects[key] = rect
                    target = .figure(key)
                } else {
                    target = .artifact
                }
            case .drawing:
                target = .artifact
            }
            targets.append(target)
        }

        // Element types, for the marked-content tags.
        func type(_ target: Target) -> String {
            switch target {
            case .block(let id):
                switch layout?.blocks.first(where: { $0.id == id })?.kind {
                case .heading(let level)?: return "H\(min(max(level, 1), 6))"
                case .listItem?: return "LBody"
                case .caption?: return "Caption"
                default: return "P"
                }
            case .cell(let table, let row, _):
                return layout?.tables.first(where: { $0.id == table })?.hasHeaderRow == true && row == 0 ? "TH" : "TD"
            case .figure: return "Figure"
            case .orphan: return "P"
            case .artifact: return "Artifact"
            }
        }

        // Marked content around each item, MCIDs in content order.
        var opens: [Int: [PDFContentOperation]] = [:], closes: [Int: Int] = [:]
        var mcids: [Target: [Int]] = [:]
        var order: [Target] = []
        var next = 0
        for (item, target) in zip(items, targets) {
            if target == .artifact {
                opens[item.start, default: []].append(PDFContentOperation("BMC", [.name("Artifact")]))
            } else {
                opens[item.start, default: []].append(PDFContentOperation("BDC", [.name(type(target)), .dictionary(["MCID": .integer(next)])]))
                if mcids[target] == nil { order.append(target) }
                mcids[target, default: []].append(next)
                next += 1
            }
            closes[item.end, default: 0] += 1
        }
        var tagged: [PDFContentOperation] = []
        tagged.reserveCapacity(operations.count + items.count * 2)
        for (i, op) in operations.enumerated() {
            tagged += opens[i] ?? []
            tagged.append(op)
            tagged += Array(repeating: PDFContentOperation("EMC"), count: closes[i] ?? 0)
        }

        // The page's elements in reading order.
        func kids(_ target: Target) -> [PDFStructureKid] { (mcids[target] ?? []).map { .markedContent(page: index, mcid: $0) } }
        var elements: [PDFStructureElement] = []
        var placed: Set<Target> = []
        var list: [PDFStructureElement] = []
        func flushList() {
            if !list.isEmpty { elements.append(PDFStructureElement(type: "L", page: index, kids: list.map { .element($0) })); list = [] }
        }
        func place(_ target: Target) {
            guard !placed.contains(target), target != .artifact else { return }
            placed.insert(target)
            switch target {
            case .block(let id) where layout?.blocks.first(where: { $0.id == id }).map({ if case .listItem = $0.kind { true } else { false } }) == true:
                guard mcids[target] != nil else { return }
                list.append(PDFStructureElement(type: "LI", page: index, kids: [.element(PDFStructureElement(type: "LBody", page: index, kids: kids(target)))]))
                return
            case .figure(let key):
                flushList()
                let rect = figureRects[key] ?? .zero
                elements.append(PDFStructureElement(type: "Figure", alternateText: descriptions[key],
                                                    attributes: .dictionary(["O": .name("Layout"), "BBox": .rect(rect)]), page: index, kids: kids(target)))
                return
            default:
                guard mcids[target] != nil else { return }
                flushList()
                elements.append(PDFStructureElement(type: type(target), page: index, kids: kids(target)))
            }
        }
        for element in layout?.readingOrder ?? [] {
            switch element {
            case .block(let id):
                place(.block(id))
            case .figure(let id):
                place(.figure("l:\(index):\(id)"))
            case .table(let id):
                flushList()
                guard let table = layout?.tables.first(where: { $0.id == id }) else { continue }
                var rows: [PDFStructureElement] = []
                for row in 0..<table.rowCount {
                    let cells = table.cells.filter { $0.row == row }.sorted { $0.column < $1.column }.map { cell -> PDFStructureElement in
                        let target = Target.cell(table: id, row: row, column: cell.column)
                        placed.insert(target)
                        return PDFStructureElement(type: type(target), page: index, kids: kids(target))
                    }
                    rows.append(PDFStructureElement(type: "TR", page: index, kids: cells.map { .element($0) }))
                }
                elements.append(PDFStructureElement(type: "Table", page: index, kids: rows.map { .element($0) }))
            }
        }
        // Whatever the reading order didn't name (pictures LayoutKit didn't see, text outside every block), in content order.
        for target in order where !placed.contains(target) { place(target) }
        flushList()
        return (tagged, elements)
    }

    /// The block or table cell a text object starting at `point` (page space from the crop box) belongs to; header,
    /// footer and page-number blocks make it an artifact.
    private static func textTarget(_ point: CGPoint, layout: LayoutPage?) -> Target? {
        guard let layout else { return nil }
        for table in layout.tables where table.bounds.insetBy(dx: -2, dy: -2).contains(point) {
            if let cell = table.cells.first(where: { $0.bounds.insetBy(dx: -2, dy: -2).contains(point) }) {
                return .cell(table: table.id, row: cell.row, column: cell.column)
            }
        }
        let containing = layout.blocks.filter { $0.bounds.insetBy(dx: -2, dy: -3).contains(point) }
        let block = containing.min { $0.bounds.width * $0.bounds.height < $1.bounds.width * $1.bounds.height }
            ?? layout.blocks.map { ($0, distance(point, $0.bounds)) }.filter { $0.1 < 12 }.min { $0.1 < $1.1 }?.0
        guard let block else { return nil }
        switch block.kind {
        case .header, .footer, .pageNumber: return .artifact
        default: return .block(block.id)
        }
    }

    /// The image figure overlapping `rect` most (by area), if any overlaps by a quarter.
    private static func figure(_ rect: CGRect, layout: LayoutPage?) -> Int? {
        guard let layout else { return nil }
        let best = layout.figures.map { figure -> (Int, CGFloat) in
            let overlap = figure.bounds.intersection(rect)
            return (figure.id, overlap.isNull ? 0 : overlap.width * overlap.height)
        }.max { $0.1 < $1.1 }
        guard let best, best.1 >= 0.25 * min(rect.width * rect.height, 1e12) else { return nil }
        return best.0
    }

    private static func distance(_ point: CGPoint, _ rect: CGRect) -> CGFloat {
        let dx = max(rect.minX - point.x, 0, point.x - rect.maxX), dy = max(rect.minY - point.y, 0, point.y - rect.maxY)
        return (dx * dx + dy * dy).squareRoot()
    }

    // MARK: Items

    private static let construction: Set<String> = ["m", "l", "c", "v", "y", "h", "re"]
    private static let painting: Set<String> = ["S", "s", "f", "F", "f*", "B", "B*", "b", "b*", "n"]
    private static let showing: Set<String> = ["Tj", "TJ", "'", "\""]

    /// The text objects, pictures, forms and drawings of a page's own content, skipping what is already marked (an
    /// artifact or an MCID span) and anything whose span crosses a q/Q.
    private static func items(_ operations: [PDFContentOperation], resources: PDFObject?) -> [Item] {
        var marked = IndexSet()
        for span in PDFContentStream(operations: operations).markedContent where span.tag == "Artifact" || span.mcid != nil {
            marked.insert(integersIn: span.start...span.end)
        }
        var items: [Item] = []
        var textStart: Int?, textOrigin: CGPoint?, pathStart: Int?
        ContentWalker.walk(operations, ctm: .identity) { index, op, state in
            switch op.operator {
            case "BT":
                textStart = index; textOrigin = nil
            case let name where showing.contains(name):
                if textOrigin == nil { textOrigin = state.textOrigin }
            case "ET":
                if let start = textStart, let point = textOrigin { items.append(Item(start: start, end: index, kind: .text(point))) }
                textStart = nil
            case "Do":
                guard let name = op.operands.first?.nameValue, let x = resources?["XObject"]?[name] else { return }
                switch x["Subtype"]?.name {
                case "Image": items.append(Item(start: index, end: index, kind: .picture(ContentWalker.unitSquare(state.ctm))))
                case "Form":
                    let box = x["BBox"]?.rect ?? CGRect(x: 0, y: 0, width: 1, height: 1)
                    items.append(Item(start: index, end: index, kind: .form(box.applying(ContentWalker.matrix(ofForm: x).concatenating(state.ctm)))))
                default: break
                }
            case "BI":
                items.append(Item(start: index, end: index, kind: .picture(ContentWalker.unitSquare(state.ctm))))
            case "sh":
                items.append(Item(start: index, end: index, kind: .drawing))
            case let name where construction.contains(name):
                if pathStart == nil, textStart == nil { pathStart = index }
            case let name where painting.contains(name):
                if let start = pathStart { items.append(Item(start: start, end: index, kind: .drawing)) }
                pathStart = nil
            default: break
            }
        }
        return items.filter { item in
            !marked.intersects(integersIn: item.start...item.end)
                && !operations[item.start...item.end].contains { $0.operator == "q" || $0.operator == "Q" }
        }
    }

    // MARK: Tagged files

    /// The Figure elements of a tagged file in depth-first order, with their objects.
    static func figures(in model: PDFModel) -> [(ref: FigureRef, object: PDFObject)] {
        guard let root = model.root["StructTreeRoot"] else { return [] }
        let roles = root["RoleMap"]
        var result: [(FigureRef, PDFObject)] = []
        var seen: Set<Int> = []
        func visit(_ node: PDFObject?, depth: Int) {
            guard let node, depth < 256 else { return }
            if node.type == .array { for item in node.items { visit(item, depth: depth) }; return }
            guard node.type == .dictionary, let type = node["S"]?.name else { return }
            if let id = node.objectID { guard seen.insert(id).inserted else { return } }
            let standard = roles?[type]?.name ?? type
            if standard == "Figure" {
                let page = node["Pg"].flatMap { PDFPage($0).index } ?? 0
                let described = !(node["Alt"]?.text ?? node["ActualText"]?.text ?? "").trimmingCharacters(in: .whitespaces).isEmpty
                result.append((FigureRef(key: "s:\(result.count)", page: page, hasDescription: described), node))
            }
            visit(node["K"], depth: depth + 1)
        }
        visit(root["K"], depth: 0)
        return result
    }
}
