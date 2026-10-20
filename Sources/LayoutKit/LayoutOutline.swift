import Foundation
import SuperPDFCore

// A compact, line-per-element description of a page: what golden fixtures compare and what a developer reads when a
// detection looks wrong. JSON (`LayoutDocument` is Codable) stays the full form.

public enum LayoutOutline {
    /// One line per element in reading order, then the excluded running blocks, e.g.
    /// `H1 c0 "Quarterly report"`, `P c1 3L "Dear Ms Smith, thank you for…"`, `LI• c0 "First item"`,
    /// `T 5x3 hdr "Item | Qty | Price"`, `F image 200x120`, `HDR "Acme Corp"`, `PN "3"`.
    public static func describe(_ page: LayoutPage, maxCharacters: Int = 40) -> String {
        var lines: [String] = []
        let ordered = Set(page.readingOrder.compactMap { if case .block(let id) = $0 { return id } else { return nil } })
        func describe(block: LayoutBlock) -> String {
            let kind: String
            switch block.kind {
            case .paragraph: kind = "P"
            case .heading(let level): kind = "H\(level)"
            case .listItem(let level, let marker): kind = "LI\(marker)" + (level > 0 ? "/\(level)" : "")
            case .caption: kind = "CAP"
            case .header: kind = "HDR"
            case .footer: kind = "FTR"
            case .pageNumber: kind = "PN"
            }
            let text = block.text.replacingOccurrences(of: "\n", with: " ")
            let clipped = text.count > maxCharacters ? String(text.prefix(maxCharacters)) + "…" : text
            let count = block.lines.count > 1 ? " \(block.lines.count)L" : ""
            return "\(kind) c\(block.column)\(count) \"\(clipped)\""
        }
        for element in page.readingOrder {
            switch element {
            case .block(let id): if let block = page.blocks.first(where: { $0.id == id }) { lines.append(describe(block: block)) }
            case .table(let id):
                if let table = page.tables.first(where: { $0.id == id }) {
                    let header = table.cells.filter { $0.row == 0 }.sorted { $0.column < $1.column }.map(\.text).joined(separator: " | ")
                    lines.append("T \(table.rowCount)x\(table.columnCount)\(table.hasHeaderRow ? " hdr" : "") \"\(header.count > maxCharacters ? String(header.prefix(maxCharacters)) + "…" : header)\"")
                }
            case .figure(let id):
                if let figure = page.figures.first(where: { $0.id == id }) {
                    lines.append("F \(figure.kind.rawValue) \(Int(figure.bounds.width))x\(Int(figure.bounds.height))" + (figure.captionBlockID.map { " cap:\($0)" } ?? ""))
                }
            }
        }
        for block in page.blocks where !ordered.contains(block.id) { lines.append(describe(block: block)) }
        return lines.joined(separator: "\n")
    }

    /// Stable JSON for fixtures (sorted keys, pretty printed).
    public static func json(_ document: LayoutDocument) throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        return try encoder.encode(document)
    }

    public static func document(fromJSON data: Data) throws -> LayoutDocument { try JSONDecoder().decode(LayoutDocument.self, from: data) }
}
