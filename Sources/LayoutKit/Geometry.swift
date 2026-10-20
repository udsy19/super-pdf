import CoreGraphics
import Foundation

// Small geometry helpers the analysis steps share. Page space throughout (points, y up).

extension CGRect {
    /// Length of the overlap of the two rects' vertical extents (0 when apart).
    func verticalOverlap(_ other: CGRect) -> CGFloat { max(0, min(maxY, other.maxY) - max(minY, other.minY)) }
    /// Length of the overlap of the two rects' horizontal extents (0 when apart).
    func horizontalOverlap(_ other: CGRect) -> CGFloat { max(0, min(maxX, other.maxX) - max(minX, other.minX)) }

    /// Union of rects, `.null` when empty.
    static func union(_ rects: [CGRect]) -> CGRect { rects.reduce(CGRect.null) { $0.union($1) } }

    /// Whether `other`'s centre lies inside this rect.
    func containsCenter(of other: CGRect) -> Bool { contains(CGPoint(x: other.midX, y: other.midY)) }

    /// Distance between the two rects' edges, 0 when they overlap.
    func gap(to other: CGRect) -> CGFloat {
        let dx = max(0, max(other.minX - maxX, minX - other.maxX))
        let dy = max(0, max(other.minY - maxY, minY - other.maxY))
        return (dx * dx + dy * dy).squareRoot()
    }

    /// Rotates a rect given in the page's unrotated space into the displayed (rotated) space, or back.
    /// `size` is the unrotated page size.
    func rotated(by degrees: Int, pageSize size: CGSize, inverse: Bool = false) -> CGRect {
        let corners = [CGPoint(x: minX, y: minY), CGPoint(x: maxX, y: maxY)].map { $0.rotated(by: degrees, pageSize: size, inverse: inverse) }
        return CGRect(x: min(corners[0].x, corners[1].x), y: min(corners[0].y, corners[1].y),
                      width: abs(corners[0].x - corners[1].x), height: abs(corners[0].y - corners[1].y))
    }

    /// Rounded to a tenth of a point, so fixtures and goldens compare stably.
    var rounded: CGRect {
        CGRect(x: (minX * 10).rounded() / 10, y: (minY * 10).rounded() / 10, width: (width * 10).rounded() / 10, height: (height * 10).rounded() / 10)
    }
}

extension CGPoint {
    /// See `CGRect.rotated(by:pageSize:inverse:)`. /Rotate 90 turns the page clockwise for display.
    func rotated(by degrees: Int, pageSize size: CGSize, inverse: Bool = false) -> CGPoint {
        let turn = ((degrees % 360) + 360) % 360
        switch (turn, inverse) {
        case (90, false): return CGPoint(x: y, y: size.width - x)
        case (90, true): return CGPoint(x: size.width - y, y: x)
        case (180, _): return CGPoint(x: size.width - x, y: size.height - y)
        case (270, false): return CGPoint(x: size.height - y, y: x)
        case (270, true): return CGPoint(x: y, y: size.height - x)
        default: return self
        }
    }
}

extension CGSize {
    /// The displayed size after the page's /Rotate.
    func rotated(by degrees: Int) -> CGSize {
        ((degrees % 360) + 360) % 360 % 180 == 90 ? CGSize(width: height, height: width) : self
    }
}

/// Union–find over `count` items, for clustering (vector clusters, table cells, column intervals).
struct DisjointSets {
    private var parent: [Int]

    init(count: Int) { parent = Array(0..<count) }

    mutating func find(_ i: Int) -> Int {
        var i = i
        while parent[i] != i { parent[i] = parent[parent[i]]; i = parent[i] }
        return i
    }

    mutating func union(_ a: Int, _ b: Int) {
        let ra = find(a), rb = find(b)
        if ra != rb { parent[max(ra, rb)] = min(ra, rb) }
    }

    /// Members grouped by root, in first-seen order.
    mutating func groups() -> [[Int]] {
        var byRoot: [Int: [Int]] = [:], order: [Int] = []
        for i in parent.indices {
            let root = find(i)
            if byRoot[root] == nil { order.append(root) }
            byRoot[root, default: []].append(i)
        }
        return order.map { byRoot[$0]! }
    }
}

/// Merges 1-D intervals that overlap (or touch within `slack`); sorted by start.
func mergeIntervals(_ intervals: [ClosedRange<CGFloat>], slack: CGFloat = 0) -> [ClosedRange<CGFloat>] {
    guard !intervals.isEmpty else { return [] }
    var result: [ClosedRange<CGFloat>] = []
    for interval in intervals.sorted(by: { $0.lowerBound < $1.lowerBound }) {
        if let last = result.last, interval.lowerBound <= last.upperBound + slack {
            result[result.count - 1] = last.lowerBound...max(last.upperBound, interval.upperBound)
        } else {
            result.append(interval)
        }
    }
    return result
}

func median(_ values: [CGFloat]) -> CGFloat {
    guard !values.isEmpty else { return 0 }
    let sorted = values.sorted()
    return sorted.count % 2 == 1 ? sorted[sorted.count / 2] : (sorted[sorted.count / 2 - 1] + sorted[sorted.count / 2]) / 2
}
