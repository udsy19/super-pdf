import CoreGraphics
import Foundation
import SuperPDFCore

// Reading order by recursive XY cut: a region is split along the widest whitespace channel that crosses it entirely,
// top-to-bottom for horizontal channels, left-to-right for vertical ones; a vertical channel (column gutter) wins
// over a horizontal one of similar width. Leaves of vertical cuts are the columns.

struct OrderedItem {
    var element: LayoutElement
    var bounds: CGRect
    var column: Int = 0
}

enum ReadingOrder {
    static func order(_ items: [OrderedItem], bodySize: CGFloat) -> [OrderedItem] {
        var items = items
        var result: [OrderedItem] = []
        cut(&items, indices: Array(items.indices), bodySize: bodySize, column: 0, into: &result)
        return result
    }

    private static func cut(_ items: inout [OrderedItem], indices: [Int], bodySize: CGFloat, column: Int, into result: inout [OrderedItem]) {
        guard indices.count > 1 else {
            for index in indices { items[index].column = column; result.append(items[index]) }
            return
        }
        let rects = indices.map { items[$0].bounds }
        let minimumGutter = max(0.6 * bodySize, 4)
        let vertical = widestGap(rects.map { $0.minX...$0.maxX }, minimum: minimumGutter)
        let horizontal = widestGap(rects.map { $0.minY...$0.maxY }, minimum: 0.1)
        if let vertical, vertical.width >= (horizontal?.width ?? 0) * 0.8 {
            let left = indices.filter { items[$0].bounds.midX < vertical.at }, right = indices.filter { items[$0].bounds.midX >= vertical.at }
            cut(&items, indices: left, bodySize: bodySize, column: column, into: &result)
            cut(&items, indices: right, bodySize: bodySize, column: column + 1, into: &result)
        } else if let bands = bands(items, indices: indices, minimumGutter: minimumGutter, horizontalGap: horizontal?.width ?? 0) {
            // Full-width items (a title, an abstract) sit between column bands: read each band in columns, the
            // spanning item, then the next band.
            for band in bands { cut(&items, indices: band, bodySize: bodySize, column: column, into: &result) }
        } else if let horizontal {
            let top = indices.filter { items[$0].bounds.midY >= horizontal.at }, bottom = indices.filter { items[$0].bounds.midY < horizontal.at }
            cut(&items, indices: top, bodySize: bodySize, column: column, into: &result)
            cut(&items, indices: bottom, bodySize: bodySize, column: column, into: &result)
        } else {
            // Overlapping items: top-down, then left-right.
            for index in indices.sorted(by: { items[$0].bounds.maxY > items[$1].bounds.maxY || (items[$0].bounds.maxY == items[$1].bounds.maxY && items[$0].bounds.minX < items[$1].bounds.minX) }) {
                items[index].column = column; result.append(items[index])
            }
        }
    }

    /// When items spanning at least half the region hide a gutter the other items share, the region is read as
    /// bands: the items above the first spanning item, that item, the items between it and the next, and so on.
    /// Nil when there is no such gutter, or the plain horizontal cut is at least as wide as it.
    private static func bands(_ items: [OrderedItem], indices: [Int], minimumGutter: CGFloat, horizontalGap: CGFloat) -> [[Int]]? {
        let region = CGRect.union(indices.map { items[$0].bounds })
        let spanning = indices.filter { items[$0].bounds.width >= 0.5 * region.width }.sorted { items[$0].bounds.midY > items[$1].bounds.midY }
        let others = indices.filter { items[$0].bounds.width < 0.5 * region.width }
        guard !spanning.isEmpty, others.count >= 2, spanning.count < indices.count,
              let gutter = widestGap(others.map { items[$0].bounds.minX...items[$0].bounds.maxX }, minimum: minimumGutter), gutter.width > horizontalGap else { return nil }
        var bands: [[Int]] = []
        var remaining = others
        for span in spanning {
            let above = remaining.filter { items[$0].bounds.midY > items[span].bounds.midY }
            if !above.isEmpty { bands.append(above) }
            bands.append([span])
            remaining.removeAll { above.contains($0) }
        }
        if !remaining.isEmpty { bands.append(remaining) }
        return bands
    }

    /// The widest gap between the merged intervals, at least `minimum` wide; `at` is its middle.
    static func widestGap(_ intervals: [ClosedRange<CGFloat>], minimum: CGFloat) -> (at: CGFloat, width: CGFloat)? {
        let merged = mergeIntervals(intervals)
        var best: (at: CGFloat, width: CGFloat)?
        for (a, b) in zip(merged, merged.dropFirst()) {
            let width = b.lowerBound - a.upperBound
            if width >= minimum, width > (best?.width ?? 0) { best = ((a.upperBound + b.lowerBound) / 2, width) }
        }
        return best
    }
}
