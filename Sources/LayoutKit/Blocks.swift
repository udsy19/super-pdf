import CoreGraphics
import Foundation
import SuperPDFCore

// Lines → paragraph blocks, then what each block is: running header, footer or page number; heading; list item;
// caption; paragraph. List markers are recognised as printed ("•", "3.", "(b)") and kept in the block kind, not in the
// block's lines, so writers prepend the marker they want and compare/reflow see the item text.

/// A block before its kind is final (heading levels and running headers need the whole document).
struct BlockDraft {
    var lines: [TextLine]
    var bounds: CGRect
    var kind: LayoutBlockKind = .paragraph
    /// The heading's font size, for document-wide level assignment.
    var headingSize: CGFloat?
    /// Marker x for list levels, and the marker word itself (to give back when the item turns out not to be one).
    var markerX: CGFloat?
    var markerWord: LayoutWord?

    init(lines: [TextLine]) { self.lines = lines; bounds = CGRect.union(lines.map(\.bounds)) }

    var fontSize: CGFloat { median(lines.map(\.fontSize)) }
    var text: String { lines.map(\.text).joined(separator: "\n") }
    var isBold: Bool { lines.filter(\.isBold).count * 2 > lines.count }
    var characterCount: Int { lines.reduce(0) { $0 + $1.text.count } }
}

enum ParagraphBuilder {
    /// Groups lines into paragraphs. `obstacles` (tables, figures) never sit inside one block.
    static func blocks(from lines: [TextLine], obstacles: [CGRect]) -> [BlockDraft] {
        var blocks: [BlockDraft] = []
        for line in lines {   // lines come sorted top-down
            var bestIndex: Int?
            var bestPitch = CGFloat.greatestFiniteMagnitude
            for (index, block) in blocks.enumerated() {
                guard let last = block.lines.last, canAppend(line, to: block, after: last, obstacles: obstacles) else { continue }
                let pitch = last.baseline - line.baseline
                if pitch < bestPitch { bestPitch = pitch; bestIndex = index }
            }
            if let bestIndex {
                blocks[bestIndex].lines.append(line)
                blocks[bestIndex].bounds = blocks[bestIndex].bounds.union(line.bounds)
            } else {
                blocks.append(BlockDraft(lines: [line]))
            }
        }
        return blocks
    }

    private static func canAppend(_ line: TextLine, to block: BlockDraft, after last: TextLine, obstacles: [CGRect]) -> Bool {
        let size = max(line.fontSize, last.fontSize, 1)
        // Below the block's last line, on a different baseline.
        guard line.baseline < last.baseline - 0.3 * size else { return false }
        // Same type size.
        let ratio = line.fontSize / max(last.fontSize, 0.1)
        guard ratio >= 0.85, ratio <= 1.18 else { return false }
        // Horizontally in the same column.
        let overlap = line.bounds.horizontalOverlap(last.bounds)
        guard overlap >= min(0.5 * min(line.bounds.width, last.bounds.width), 2 * size) else { return false }
        // Vertical pitch: against the block's own pitch once it has one, else against the type size.
        let pitch = last.baseline - line.baseline
        if block.lines.count >= 2 {
            let pitches = zip(block.lines, block.lines.dropFirst()).map { $0.baseline - $1.baseline }
            guard pitch <= 1.35 * median(pitches) + 0.5 else { return false }
        } else {
            guard pitch <= 2.1 * size else { return false }
            let endsSentence = last.text.last.map { ".!?:".contains($0) } ?? false
            let startsCapital = line.text.first.map { $0.isUppercase } ?? false
            if endsSentence && startsCapital && pitch > 1.3 * size && last.bounds.width < 0.85 * max(line.bounds.width, last.bounds.width) { return false }
        }
        // A change of weight (a bold heading line, a run-in bold line) starts a block.
        guard line.isBold == last.isBold else { return false }
        // Indents: a first-line indent starts a paragraph; an outdent past the block's body edge starts one too.
        // Centred lines (a title wrapping, a centred poem) are compared by their middles instead.
        let centred = abs(line.bounds.midX - last.bounds.midX) < size && abs(line.bounds.minX - last.bounds.minX) > size
        if !centred {
            let bodyLeft = block.lines.count >= 2 ? block.lines.dropFirst().map { textStart($0) }.min()! : textStart(block.lines[0])
            if line.bounds.minX > bodyLeft + 1.0 * size && block.lines.count >= 1 && !startsWithMarker(block.lines[0]) { return false }
            if block.lines.count >= 2 && line.bounds.minX < bodyLeft - 1.0 * size { return false }
        }
        // Nothing drawn between them.
        let between = CGRect(x: min(line.bounds.minX, last.bounds.minX), y: line.bounds.maxY,
                             width: max(line.bounds.maxX, last.bounds.maxX) - min(line.bounds.minX, last.bounds.minX), height: max(last.bounds.minY - line.bounds.maxY, 0))
        guard !obstacles.contains(where: { $0.intersects(between) && $0.verticalOverlap(between) > 1 }) else { return false }
        return true
    }

    /// Where a line's text starts: after its list marker, if it has one.
    static func textStart(_ line: TextLine) -> CGFloat {
        if startsWithMarker(line), line.words.count > 1 { return line.words[1].bounds.minX }
        return line.bounds.minX
    }

    static func startsWithMarker(_ line: TextLine) -> Bool { ListMarkers.marker(of: line) != nil }
}

enum ListMarkers {
    static let bullets: Set<String> = ["•", "◦", "▪", "▫", "■", "□", "●", "○", "‣", "⁃", "·", "∙", "-", "–", "—", "*", "➢", "➤", "►", "▶", "✓", "✔", "☐", "☑", "→", "✦", "✧", "❖"]
    private static let numbered = try! NSRegularExpression(pattern: "^\\(?(\\d{1,3}|[a-zA-Z]|[ivxlcdm]{1,7}|[IVXLCDM]{1,7})[.):]$")
    private static let section = try! NSRegularExpression(pattern: "^\\d{1,2}(\\.\\d{1,2})+\\.?$")

    /// The line's marker when its first word is one and text follows (or the bullet stands alone).
    static func marker(of line: TextLine) -> String? {
        guard let first = line.words.first?.text, !first.isEmpty else { return nil }
        if bullets.contains(first) { return first }
        guard line.words.count > 1 else { return nil }
        let range = NSRange(first.startIndex..., in: first)
        if numbered.firstMatch(in: first, range: range) != nil || section.firstMatch(in: first, range: range) != nil { return first }
        return nil
    }

    static func isBullet(_ marker: String) -> Bool { bullets.contains(marker) }

    /// The family of a non-bullet marker, so a lone "A." on a page is not a list: digits, letters, roman, sections.
    static func family(of marker: String) -> String {
        let core = marker.trimmingCharacters(in: CharacterSet(charactersIn: "().:"))
        if isSectionNumber(marker) { return "section" }
        if core.allSatisfy(\.isNumber) { return "number" }
        if core.lowercased().allSatisfy({ "ivxlcdm".contains($0) }) && core.count > 1 { return "roman" }
        return "letter"
    }

    /// The item as a paragraph again, marker word back in its first line.
    static func unsplit(_ block: BlockDraft) -> BlockDraft {
        guard let markerWord = block.markerWord else { return block }
        var lines = block.lines
        if lines.isEmpty { lines = [TextLine(words: [markerWord])] } else { lines[0] = TextLine(words: [markerWord] + lines[0].words) }
        var draft = BlockDraft(lines: lines)
        draft.bounds = block.bounds
        return draft
    }
    static func isSectionNumber(_ marker: String) -> Bool { section.firstMatch(in: marker, range: NSRange(marker.startIndex..., in: marker)) != nil }

    /// Splits a block at its marker lines: each marker line starts an item; lines before the first marker stay a
    /// paragraph. Items keep their marker in `markerX`; the marker word leaves the lines.
    static func split(_ block: BlockDraft) -> [BlockDraft] {
        let markerLines = block.lines.indices.filter { marker(of: block.lines[$0]) != nil }
        guard !markerLines.isEmpty else { return [block] }
        var result: [BlockDraft] = []
        var groups: [[TextLine]] = []
        for line in block.lines {
            if marker(of: line) != nil || groups.isEmpty { groups.append([line]) } else { groups[groups.count - 1].append(line) }
        }
        for group in groups {
            guard let marker = marker(of: group[0]) else { result.append(BlockDraft(lines: group)); continue }
            var lines = group
            let markerWord = lines[0].words[0]
            lines[0] = TextLine(words: Array(lines[0].words.dropFirst()))
            var draft = BlockDraft(lines: lines.filter { !$0.words.isEmpty })
            if draft.lines.isEmpty { draft = BlockDraft(lines: group) }
            draft.bounds = draft.bounds.union(markerWord.bounds)
            draft.kind = .listItem(level: 0, marker: marker)
            draft.markerX = markerWord.bounds.minX
            draft.markerWord = markerWord
            result.append(draft)
        }
        return result
    }
}

enum PageNumbers {
    private static let patterns = [
        "^(page|p\\.|seite|pág\\.|p)?\\s*\\d{1,4}\\s*((of|/|von|de|sur)\\s*\\d{1,4})?$",
        "^[-–—]\\s*\\d{1,4}\\s*[-–—]$",
        "^[ivxlcdm]{1,8}$",
    ].map { try! NSRegularExpression(pattern: $0, options: .caseInsensitive) }

    static func isPageNumber(_ text: String) -> Bool {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, trimmed.count <= 16 else { return false }
        let range = NSRange(trimmed.startIndex..., in: trimmed)
        return patterns.contains { $0.firstMatch(in: trimmed, range: range) != nil }
    }
}

enum Captions {
    private static let pattern = try! NSRegularExpression(pattern: "^(figure|fig\\.|table|chart|image|photo|exhibit|listing|diagram|abbildung|tabelle)\\s*\\d+", options: .caseInsensitive)

    static func looksLikeCaption(_ block: BlockDraft) -> Bool {
        guard block.lines.count <= 3 else { return false }
        let text = block.text
        return pattern.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)) != nil
    }

    /// Whether a short block sits right below or above a figure of comparable width.
    static func isNextTo(_ block: BlockDraft, figure: CGRect, bodySize: CGFloat) -> Bool {
        guard block.lines.count <= 2, block.fontSize <= bodySize * 1.05 else { return false }
        guard block.bounds.horizontalOverlap(figure) >= 0.5 * block.bounds.width, block.bounds.width <= figure.width * 1.25 + 2 * bodySize else { return false }
        let gap = max(figure.minY - block.bounds.maxY, block.bounds.minY - figure.maxY)
        return gap >= -1 && gap <= 1.8 * max(block.fontSize, bodySize)
    }
}

/// Per-page classification that needs no other page. Document-wide steps (heading levels, repeated headers) run in
/// `LayoutAnalyzer`.
enum BlockClassifier {
    static func classify(_ drafts: [BlockDraft], bodySize: CGFloat, pageSize: CGSize, origin: TextOrigin, figures: [CGRect], tables: [CGRect]) -> [BlockDraft] {
        // Numbered headings ("1. Introduction" in a larger or bold face) are headings, not list items; bullets always
        // split. Numbered markers whose family appears once on the page are text ("A. Author and B. Author").
        var blocks = drafts.flatMap { draft -> [BlockDraft] in
            if let marker = ListMarkers.marker(of: draft.lines[0]), !ListMarkers.isBullet(marker), isHeadingBySize(draft, bodySize: bodySize, origin: origin) || (draft.isBold && ListMarkers.isSectionNumber(marker)) { return [draft] }
            return ListMarkers.split(draft)
        }
        var families: [String: Int] = [:]
        for block in blocks { if case .listItem(_, let marker) = block.kind, !ListMarkers.isBullet(marker) { families[ListMarkers.family(of: marker), default: 0] += 1 } }
        blocks = blocks.map { block in
            if case .listItem(_, let marker) = block.kind, !ListMarkers.isBullet(marker), families[ListMarkers.family(of: marker), default: 0] < 2 { return ListMarkers.unsplit(block) }
            return block
        }
        let elements = blocks.map(\.bounds) + figures + tables
        for index in blocks.indices {
            var block = blocks[index]
            if case .listItem = block.kind { blocks[index] = block; continue }
            let size = block.fontSize
            let text = block.text
            let inTopBand = block.bounds.minY >= pageSize.height * 0.88
            let inBottomBand = block.bounds.maxY <= pageSize.height * 0.12
            let shortBlock = block.lines.count <= 2 && block.characterCount <= 120
            if (inTopBand || inBottomBand) && shortBlock && PageNumbers.isPageNumber(text) {
                block.kind = .pageNumber
            } else if inTopBand && shortBlock && size <= bodySize * 1.1 && clearance(below: block.bounds, among: elements) >= 1.2 * bodySize {
                block.kind = .header
            } else if inBottomBand && shortBlock && size <= bodySize * 1.1 && clearance(above: block.bounds, among: elements) >= 1.2 * bodySize {
                block.kind = .footer
            } else if Captions.looksLikeCaption(block) || figures.contains(where: { Captions.isNextTo(block, figure: $0, bodySize: bodySize) }) {
                block.kind = .caption
            } else if isHeadingBySize(block, bodySize: bodySize, origin: origin) {
                block.kind = .heading(level: 1); block.headingSize = size
            } else if block.lines.count <= 2 && block.isBold && size >= bodySize * 0.95 && block.characterCount <= 120 && !endsLikeSentence(text) {
                block.kind = .heading(level: 1); block.headingSize = size
            }
            blocks[index] = block
        }
        return assignListLevels(blocks, bodySize: bodySize)
    }

    private static func endsLikeSentence(_ text: String) -> Bool { text.last.map { ".,;".contains($0) } ?? false }

    /// OCR sizes come from box heights, so recognised text needs a clearer step up and fewer lines.
    static func isHeadingBySize(_ block: BlockDraft, bodySize: CGFloat, origin: TextOrigin) -> Bool {
        switch origin {
        case .embedded: block.lines.count <= 3 && block.fontSize >= bodySize * 1.12 && block.characterCount <= 200
        case .recognized: block.lines.count <= 2 && block.fontSize >= bodySize * 1.3 && block.characterCount <= 120
        }
    }

    /// Vertical whitespace from the block's bottom edge to the nearest element below that overlaps it horizontally.
    static func clearance(below bounds: CGRect, among elements: [CGRect]) -> CGFloat {
        elements.filter { $0 != bounds && $0.horizontalOverlap(bounds) > 0 && $0.maxY <= bounds.minY + 1 }.map { bounds.minY - $0.maxY }.min() ?? .greatestFiniteMagnitude
    }

    static func clearance(above bounds: CGRect, among elements: [CGRect]) -> CGFloat {
        elements.filter { $0 != bounds && $0.horizontalOverlap(bounds) > 0 && $0.minY >= bounds.maxY - 1 }.map { $0.minY - bounds.maxY }.min() ?? .greatestFiniteMagnitude
    }

    /// List levels from marker indentation: the leftmost marker is level 0, each further 0.8 em step one more.
    static func assignListLevels(_ blocks: [BlockDraft], bodySize: CGFloat) -> [BlockDraft] {
        var blocks = blocks
        let markerXs = blocks.compactMap(\.markerX).sorted()
        var levels: [CGFloat] = []
        for x in markerXs where levels.last.map({ x - $0 > 0.8 * bodySize }) ?? true { levels.append(x) }
        for index in blocks.indices {
            guard case .listItem(_, let marker) = blocks[index].kind, let x = blocks[index].markerX else { continue }
            let level = levels.lastIndex { $0 <= x + 0.5 } ?? 0
            blocks[index].kind = .listItem(level: level, marker: marker)
        }
        return blocks
    }
}
