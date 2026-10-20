import CoreGraphics
import Foundation
import SuperPDFCore

// Table detection (features §2.4, #51): first from ruling lines (a grid of horizontal and vertical strokes, or
// horizontal row separators alone), then from alignment (three or more consecutive rows whose segments fall into the
// same column intervals). Cells take the words whose centres lie inside them.

enum TableDetector {
    /// Tables on the page. `lines` are baseline rows (words on one baseline regardless of distance), since a table's
    /// columns look like gutters to the line builder.
    static func detect(lines: [TextLine], rulings: [Ruling], bodySize: CGFloat, pageSize: CGSize) -> [LayoutTable] {
        var tables: [LayoutTable] = []
        var claimed = Set<LayoutWord>()
        var consumedRulings = Set<Ruling>()

        for component in rulingComponents(rulings) {
            let horizontal = component.filter(\.isHorizontal), vertical = component.filter { !$0.isHorizontal }
            let bounds = CGRect.union(component.map(\.bounds))
            guard bounds.width >= 4 * bodySize else { continue }
            if horizontal.count >= 2, vertical.count >= 2 {
                if let table = gridTable(horizontal: horizontal, vertical: vertical, bounds: bounds, lines: lines, claimed: claimed, id: tables.count) {
                    tables.append(table); claimed.formUnion(wordsInside(table.bounds, lines: lines)); consumedRulings.formUnion(component)
                }
            } else if horizontal.count >= 2, vertical.isEmpty {
                // Row separators only: columns come from alignment of the text between the top and bottom rule.
                let region = bounds.insetBy(dx: -bodySize, dy: -bodySize * 0.6)
                let inside = lines.filter { region.containsCenter(of: $0.bounds) && !$0.words.contains(where: claimed.contains) }
                if let table = alignmentTable(rows: inside, bodySize: bodySize, minimumRows: 2, id: tables.count, rowSeparators: horizontal) {
                    tables.append(table); claimed.formUnion(wordsInside(table.bounds, lines: lines)); consumedRulings.formUnion(component)
                }
            }
        }

        // Alignment grids with no rulings at all.
        let free = lines.filter { !$0.words.contains(where: claimed.contains) }
        for run in candidateRuns(free, bodySize: bodySize) {
            if let table = alignmentTable(rows: run, bodySize: bodySize, minimumRows: 3, id: tables.count, rowSeparators: []) {
                tables.append(table); claimed.formUnion(wordsInside(table.bounds, lines: lines))
            }
        }
        return tables
    }

    static func wordsInside(_ bounds: CGRect, lines: [TextLine]) -> Set<LayoutWord> {
        Set(lines.flatMap(\.words).filter { bounds.containsCenter(of: $0.bounds) })
    }

    // MARK: Rulings

    /// Rulings grouped by touching or crossing (within 2 pt).
    static func rulingComponents(_ rulings: [Ruling]) -> [[Ruling]] {
        guard !rulings.isEmpty else { return [] }
        var sets = DisjointSets(count: rulings.count)
        for i in rulings.indices {
            for j in (i + 1)..<rulings.count where rulings[i].bounds.insetBy(dx: -2, dy: -2).intersects(rulings[j].bounds) {
                sets.union(i, j)
            }
        }
        return sets.groups().map { $0.map { rulings[$0] } }
    }

    /// Distinct positions of parallel rulings, merged within 2 pt.
    static func positions(_ rulings: [Ruling]) -> [CGFloat] {
        var result: [CGFloat] = []
        for position in rulings.map(\.position).sorted() {
            if let last = result.last, position - last < 2 { continue }
            result.append(position)
        }
        return result
    }

    static func gridTable(horizontal: [Ruling], vertical: [Ruling], bounds: CGRect, lines: [TextLine], claimed: Set<LayoutWord>, id: Int) -> LayoutTable? {
        let ys = positions(horizontal).reversed().map { $0 }   // top to bottom
        let xs = positions(vertical)
        guard ys.count >= 2, xs.count >= 2 else { return nil }
        let rowCount = ys.count - 1, columnCount = xs.count - 1
        // Merge cells whose shared boundary is not drawn.
        var sets = DisjointSets(count: rowCount * columnCount)
        func index(_ row: Int, _ column: Int) -> Int { row * columnCount + column }
        func drawn(_ ruling: Ruling, at position: CGFloat, covering range: ClosedRange<CGFloat>) -> Bool {
            abs(ruling.position - position) < 2 && ruling.span.lowerBound <= range.lowerBound + 2 && ruling.span.upperBound >= range.upperBound - 2
        }
        for row in 0..<rowCount {
            for column in 0..<columnCount {
                if column + 1 < columnCount {
                    let band = ys[row + 1]...ys[row]
                    if !vertical.contains(where: { drawn($0, at: xs[column + 1], covering: band) }) { sets.union(index(row, column), index(row, column + 1)) }
                }
                if row + 1 < rowCount {
                    let band = xs[column]...xs[column + 1]
                    if !horizontal.contains(where: { drawn($0, at: ys[row + 1], covering: band) }) { sets.union(index(row, column), index(row + 1, column)) }
                }
            }
        }
        var cells: [LayoutTableCell] = []
        for group in sets.groups() {
            let rows = group.map { $0 / columnCount }, columns = group.map { $0 % columnCount }
            let r0 = rows.min()!, r1 = rows.max()!, c0 = columns.min()!, c1 = columns.max()!
            let cellBounds = CGRect(x: xs[c0], y: ys[r1 + 1], width: xs[c1 + 1] - xs[c0], height: ys[r0] - ys[r1 + 1])
            let text = cellText(in: cellBounds, lines: lines, claimed: claimed)
            cells.append(LayoutTableCell(row: r0, column: c0, rowSpan: r1 - r0 + 1, columnSpan: c1 - c0 + 1, bounds: cellBounds.rounded, text: text))
        }
        cells.sort { $0.row < $1.row || ($0.row == $1.row && $0.column < $1.column) }
        guard cells.contains(where: { !$0.text.isEmpty }) else { return nil }
        let header = cells.filter { $0.row == 0 }
        let hasHeaderRow = rowCount > 1 && !header.isEmpty && header.allSatisfy { !$0.text.isEmpty } && headerLooksLikeHeader(header, lines: lines)
        return LayoutTable(id: id, bounds: CGRect(x: xs[0], y: ys.last!, width: xs.last! - xs[0], height: ys[0] - ys.last!).rounded,
                           rowCount: rowCount, columnCount: columnCount, cells: cells, hasHeaderRow: hasHeaderRow)
    }

    /// Text of the words inside a cell, in line order.
    static func cellText(in bounds: CGRect, lines: [TextLine], claimed: Set<LayoutWord>) -> String {
        lines.compactMap { line -> String? in
            let words = line.words.filter { bounds.containsCenter(of: $0.bounds) && !claimed.contains($0) }
            return words.isEmpty ? nil : words.map(\.text).joined(separator: " ")
        }.joined(separator: " ")
    }

    static func headerLooksLikeHeader(_ header: [LayoutTableCell], lines: [TextLine]) -> Bool {
        let headerWords = lines.flatMap(\.words).filter { word in header.contains { $0.bounds.containsCenter(of: word.bounds) } }
        let bold = headerWords.allSatisfy(\.isBold) && !headerWords.isEmpty
        let numeric = header.filter { Self.isNumeric($0.text) }.count
        return bold || numeric == 0
    }

    static func isNumeric(_ text: String) -> Bool {
        let stripped = text.replacingOccurrences(of: "[\\s,$€£%()]", with: "", options: .regularExpression)
        return !stripped.isEmpty && Double(stripped.replacingOccurrences(of: "−", with: "-")) != nil
    }

    // MARK: Alignment

    /// Runs of vertically consecutive rows with two or more segments each (candidate table rows); a leading list
    /// marker is not a cell.
    static func candidateRuns(_ lines: [TextLine], bodySize: CGFloat) -> [[TextLine]] {
        let rows = lines.filter { $0.segments.count >= 2 && !($0.segments.count == 2 && ListMarkers.marker(of: $0) != nil) }.sorted { $0.bounds.maxY > $1.bounds.maxY }
        var runs: [[TextLine]] = []
        var current: [TextLine] = []
        for row in rows {
            if let last = current.last, last.bounds.minY - row.bounds.maxY > 1.6 * max(last.fontSize, bodySize) || last.bounds.horizontalOverlap(row.bounds) <= 0 {
                runs.append(current); current = []
            }
            current.append(row)
        }
        if !current.isEmpty { runs.append(current) }
        return runs.filter { $0.count >= 3 }
    }

    /// A table from rows whose segments align into column intervals; nil when the rows do not share a column structure.
    static func alignmentTable(rows: [TextLine], bodySize: CGFloat, minimumRows: Int, id: Int, rowSeparators: [Ruling]) -> LayoutTable? {
        let rows = rows.sorted { $0.bounds.maxY > $1.bounds.maxY }
        guard rows.count >= minimumRows else { return nil }
        let segments = rows.flatMap(\.segments)
        let columns = mergeIntervals(segments.map { $0.bounds.minX...$0.bounds.maxX }, slack: 0)
        guard columns.count >= 2, columns.count <= 24 else { return nil }
        // Cells are short: body text in two columns has long segments, a list has a marker in front.
        let runWidth = CGRect.union(rows.map(\.bounds)).width
        guard median(segments.map(\.bounds.width)) <= 0.45 * runWidth, median(segments.map { CGFloat($0.text.count) }) <= 30 else { return nil }
        guard rows.filter({ ListMarkers.marker(of: $0) != nil }).count * 2 < rows.count else { return nil }
        // Every segment must sit in exactly one column interval (merging guarantees it), and most rows must use ≥ 2.
        let multi = rows.filter { $0.segments.count >= 2 }.count
        guard multi * 10 >= rows.count * 6 else { return nil }
        // Wrapped cells: a row with a single segment that is not the first row joins the row above.
        var grouped: [[TextLine]] = []
        for row in rows {
            if row.segments.count == 1, let last = grouped.last?.last, last.bounds.minY - row.bounds.maxY < 0.8 * max(row.fontSize, 1),
               rowSeparators.allSatisfy({ !($0.position < last.bounds.minY && $0.position > row.bounds.maxY) }) {
                grouped[grouped.count - 1].append(row)
            } else {
                grouped.append([row])
            }
        }
        guard grouped.count >= minimumRows else { return nil }
        var cells: [LayoutTableCell] = []
        for (rowIndex, group) in grouped.enumerated() {
            for (columnIndex, column) in columns.enumerated() {
                let words = group.flatMap(\.words).filter { column.contains($0.bounds.midX) }
                guard !words.isEmpty else { continue }
                let bounds = CGRect.union(words.map(\.bounds))
                let text = group.compactMap { line -> String? in
                    let inColumn = line.words.filter { column.contains($0.bounds.midX) }
                    return inColumn.isEmpty ? nil : inColumn.map(\.text).joined(separator: " ")
                }.joined(separator: " ")
                cells.append(LayoutTableCell(row: rowIndex, column: columnIndex, bounds: bounds.rounded, text: text))
            }
        }
        let bounds = CGRect.union(rows.map(\.bounds))
        let header = cells.filter { $0.row == 0 }
        let firstWords = grouped[0].flatMap(\.words)
        let laterNumeric = cells.filter { $0.row > 0 && isNumeric($0.text) }.count
        let hasHeaderRow = grouped.count > 1 && (firstWords.allSatisfy(\.isBold) || (header.allSatisfy { !isNumeric($0.text) } && laterNumeric > 0))
        return LayoutTable(id: id, bounds: bounds.rounded, rowCount: grouped.count, columnCount: columns.count, cells: cells, hasHeaderRow: hasHeaderRow)
    }
}
