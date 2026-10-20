import CoreGraphics
import Foundation
import SuperPDFCore

// Words → lines. A line is a run of words sharing a baseline; it is cut where a page-wide gutter (column gap) or a very
// wide gap crosses it. Finer word gaps stay inside the line as `segments`, which the table detector reads as cells.

/// A run of words on one baseline with no large gap.
struct Segment: Hashable {
    var words: [LayoutWord]
    var bounds: CGRect

    var text: String { words.map(\.text).joined(separator: " ") }
}

struct TextLine: Hashable {
    var words: [LayoutWord]
    var bounds: CGRect
    var baseline: CGFloat
    var fontSize: CGFloat
    var isBold: Bool
    var isItalic: Bool
    var segments: [Segment]

    init(words: [LayoutWord]) {
        let sorted = words.sorted { $0.bounds.minX < $1.bounds.minX }
        self.words = sorted
        bounds = CGRect.union(sorted.map(\.bounds))
        fontSize = Typography.lineFontSize(sorted)
        baseline = median(sorted.map { Typography.baseline(of: $0) })
        let characters = sorted.reduce(0) { $0 + $1.text.count }
        isBold = sorted.filter(\.isBold).reduce(0) { $0 + $1.text.count } * 2 > characters
        isItalic = sorted.filter(\.isItalic).reduce(0) { $0 + $1.text.count } * 2 > characters
        segments = Self.segments(of: sorted, gap: max(fontSize * 1.0, 5))
    }

    var text: String { words.map(\.text).joined(separator: " ") }

    /// Runs of words whose neighbours are closer than `gap`.
    static func segments(of words: [LayoutWord], gap: CGFloat) -> [Segment] {
        var result: [Segment] = []
        var current: [LayoutWord] = []
        for word in words {
            if let last = current.last, word.bounds.minX - last.bounds.maxX > gap {
                result.append(Segment(words: current, bounds: CGRect.union(current.map(\.bounds))))
                current = []
            }
            current.append(word)
        }
        if !current.isEmpty { result.append(Segment(words: current, bounds: CGRect.union(current.map(\.bounds)))) }
        return result
    }

    var layoutLine: LayoutLine { LayoutLine(words: words, bounds: bounds.rounded, baseline: (baseline * 10).rounded() / 10) }
}

enum Typography {
    /// A word's font size, falling back to its box height for OCR words (Vision boxes are about 1.25 × the size).
    static func fontSize(of word: LayoutWord) -> CGFloat {
        word.fontSize > 0 ? CGFloat(word.fontSize) : word.bounds.height * 0.8
    }

    /// Baseline estimate: the box bottom plus a typical descent.
    static func baseline(of word: LayoutWord) -> CGFloat { word.bounds.minY + 0.21 * fontSize(of: word) }

    /// Median font size of the words, by character.
    static func lineFontSize(_ words: [LayoutWord]) -> CGFloat {
        var sizes: [CGFloat] = []
        for word in words { sizes.append(contentsOf: repeatElement(fontSize(of: word), count: max(word.text.count, 1))) }
        return median(sizes)
    }

    /// The body text size: the font size with the most characters, rounded to half a point.
    static func bodyFontSize(_ words: [LayoutWord]) -> CGFloat {
        var weights: [CGFloat: Int] = [:]
        for word in words where !word.text.isEmpty {
            let size = (fontSize(of: word) * 2).rounded() / 2
            weights[size, default: 0] += word.text.count
        }
        return weights.max { $0.value < $1.value || ($0.value == $1.value && $0.key > $1.key) }?.key ?? 10
    }
}

enum LineBuilder {
    /// Groups words into baseline lines, then cuts lines at column gutters and very wide gaps.
    static func lines(from words: [LayoutWord]) -> [TextLine] {
        let rows = baselineRows(words)
        let gutters = Self.gutters(in: rows)
        var lines: [TextLine] = []
        for row in rows {
            var current: [LayoutWord] = []
            for word in row.words {
                if let last = current.last {
                    let gap = word.bounds.minX - last.bounds.maxX
                    let size = max(Typography.fontSize(of: word), Typography.fontSize(of: last))
                    let gapRange = last.bounds.maxX...word.bounds.minX
                    let crossesGutter = gap >= 0.8 * size && gutters.contains { $0.overlaps(gapRange) && $0.lowerBound >= gapRange.lowerBound - 1 && $0.upperBound <= gapRange.upperBound + 1 }
                    if gap > 3 * size || crossesGutter {
                        lines.append(TextLine(words: current))
                        current = []
                    }
                }
                current.append(word)
            }
            if !current.isEmpty { lines.append(TextLine(words: current)) }
        }
        return lines.sorted { $0.bounds.maxY > $1.bounds.maxY || ($0.bounds.maxY == $1.bounds.maxY && $0.bounds.minX < $1.bounds.minX) }
    }

    /// Words sharing a baseline, regardless of horizontal distance.
    static func baselineRows(_ words: [LayoutWord]) -> [TextLine] {
        var rows: [[LayoutWord]] = []
        var rowBounds: [CGRect] = []
        let sorted = words.filter { !$0.text.isEmpty && $0.bounds.width > 0 && $0.bounds.height > 0 }
            .sorted { $0.bounds.maxY > $1.bounds.maxY || ($0.bounds.maxY == $1.bounds.maxY && $0.bounds.minX < $1.bounds.minX) }
        for word in sorted {
            var best: (index: Int, overlap: CGFloat)?
            let baseline = Typography.baseline(of: word)
            let size = Typography.fontSize(of: word)
            for index in stride(from: rows.count - 1, through: max(0, rows.count - 40), by: -1) where rows.indices.contains(index) {
                let bounds = rowBounds[index]
                guard bounds.minY <= word.bounds.maxY + size else { break }
                let overlap = bounds.verticalOverlap(word.bounds)
                guard overlap >= 0.5 * min(bounds.height, word.bounds.height) else { continue }
                let rowBaseline = median(rows[index].map { Typography.baseline(of: $0) })
                guard abs(rowBaseline - baseline) <= 0.45 * max(size, Typography.lineFontSize(rows[index])) else { continue }
                if best == nil || overlap > best!.overlap { best = (index, overlap) }
            }
            if let best {
                rows[best.index].append(word)
                rowBounds[best.index] = rowBounds[best.index].union(word.bounds)
            } else {
                rows.append([word]); rowBounds.append(word.bounds)
            }
        }
        return rows.map { TextLine(words: $0) }
    }

    /// Vertical whitespace channels that many rows share: column gutters. Each is the x-interval common to the gaps.
    static func gutters(in rows: [TextLine]) -> [ClosedRange<CGFloat>] {
        var gaps: [(range: ClosedRange<CGFloat>, y: CGFloat)] = []
        for row in rows {
            for (a, b) in zip(row.words, row.words.dropFirst()) {
                let size = max(Typography.fontSize(of: a), Typography.fontSize(of: b))
                let gap = b.bounds.minX - a.bounds.maxX
                if gap >= max(1.0 * size, 5) { gaps.append((a.bounds.maxX...b.bounds.minX, row.baseline)) }
            }
        }
        guard rows.count >= 4 else { return [] }
        let minimumMembers = max(4, rows.count / 4)
        var result: [ClosedRange<CGFloat>] = []
        var remaining = gaps.sorted { $0.range.lowerBound < $1.range.lowerBound }
        while !remaining.isEmpty {
            // Grow a group from the gap with the most companions overlapping it by at least 4 pt.
            var bestGroup: [Int] = []
            var bestIntersection: ClosedRange<CGFloat>?
            for (seedIndex, seed) in remaining.enumerated() {
                var intersection = seed.range
                var members = [seedIndex]
                for (index, gap) in remaining.enumerated() where index != seedIndex {
                    let lower = max(intersection.lowerBound, gap.range.lowerBound), upper = min(intersection.upperBound, gap.range.upperBound)
                    if upper - lower >= 4 { intersection = lower...upper; members.append(index) }
                }
                if members.count > bestGroup.count { bestGroup = members; bestIntersection = intersection }
            }
            guard let intersection = bestIntersection, bestGroup.count >= minimumMembers else { break }
            result.append(intersection)
            let removed = Set(bestGroup)
            remaining = remaining.enumerated().filter { !removed.contains($0.offset) }.map(\.element)
        }
        return result
    }
}
