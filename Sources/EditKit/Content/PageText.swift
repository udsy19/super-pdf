import CoreGraphics
import Foundation
import LayoutKit
import PDFModelKit
import SuperPDFCore

// The text of a page as blocks people click on (features #60: "click a paragraph → it becomes an editable block"):
// the interpreter's runs become words, LayoutKit groups them into lines and paragraphs, and every word keeps the
// runs and glyphs it came from so a block can be rewritten in place.

/// Glyph units `range` of run `run`.
struct TextSpan: Hashable {
    var run: Int
    var range: Range<Int>
}

/// How a block's lines sit in it.
enum TextAlignment: String, Codable, Sendable {
    case left, center, right, justified
}

/// A line of a block.
struct EditableLine {
    var spans: [TextSpan]
    var words: [LayoutWord]
    var bounds: CGRect
    /// The baseline's start, page space.
    var baselineStart: CGPoint
    var text: String { words.map(\.text).joined(separator: " ") }
}

/// The look of a block's text, taken from its longest run.
struct BlockStyle {
    var fontName: String
    var font: PDFFont
    /// Tfs.
    var fontSize: Double
    /// Page-space font size.
    var pageFontSize: Double
    /// The run's text-space basis (rotation and scale, no translation).
    var basis: CGAffineTransform
    var colorOps: [PDFContentOperation]
    var extGState: String?
    var charSpacing: Double
    /// The colour as "#RRGGBB" when the colour operations say it plainly (gray, RGB or CMYK fills).
    var colorHex: String? { BlockStyle.hex(of: colorOps) }

    static func hex(of ops: [PDFContentOperation]) -> String? {
        guard let last = ops.last(where: { $0.operator != "cs" }) else { return "#000000" }
        let n = last.operands.compactMap(\.numberValue)
        func h(_ r: Double, _ g: Double, _ b: Double) -> String {
            String(format: "#%02X%02X%02X", Int((min(max(r, 0), 1) * 255).rounded()), Int((min(max(g, 0), 1) * 255).rounded()), Int((min(max(b, 0), 1) * 255).rounded()))
        }
        switch (last.operator, n.count) {
        case ("g", 1), ("sc", 1), ("scn", 1): return h(n[0], n[0], n[0])
        case ("rg", 3), ("sc", 3), ("scn", 3): return h(n[0], n[1], n[2])
        case ("k", 4), ("sc", 4), ("scn", 4): return h((1 - n[0]) * (1 - n[3]), (1 - n[1]) * (1 - n[3]), (1 - n[2]) * (1 - n[3]))
        default: return nil
        }
    }

    /// Colour operations for "#RRGGBB".
    static func colorOps(for hex: String) -> [PDFContentOperation] {
        var value = hex.hasPrefix("#") ? String(hex.dropFirst()) : hex
        if value.count == 3 { value = value.map { "\($0)\($0)" }.joined() }
        guard value.count >= 6, let number = UInt32(value.prefix(6), radix: 16) else { return [PDFContentOperation("g", [.integer(0)])] }
        let r = Double((number >> 16) & 0xFF) / 255, g = Double((number >> 8) & 0xFF) / 255, b = Double(number & 0xFF) / 255
        if r == g, g == b { return [PDFContentOperation("g", [.number((r * 1000).rounded() / 1000)])] }
        return [PDFContentOperation("rg", [.number((r * 1000).rounded() / 1000), .number((g * 1000).rounded() / 1000), .number((b * 1000).rounded() / 1000)])]
    }
}

/// A paragraph (or heading, list item…) that can be clicked and retyped.
struct TextBlock: Identifiable {
    var id: Int
    var kind: LayoutBlockKind
    var bounds: CGRect
    var lines: [EditableLine]
    var style: BlockStyle
    var alignment: TextAlignment
    /// Baseline to baseline, page space.
    var linePitch: Double
    /// False when any of its text lives in a form XObject (shown, not editable here).
    var isEditable: Bool

    /// The paragraph as it is typed: lines that wrapped join with a space, lines broken short of the box keep the break,
    /// so retyping reflows the text in its box. One character between lines either way.
    var text: String {
        var out = ""
        for (index, line) in lines.enumerated() {
            if index > 0 { out += endsShort(lines[index - 1], before: line) ? "\n" : " " }
            out += line.text
        }
        return out
    }

    var spans: [TextSpan] { lines.flatMap(\.spans) }

    /// Whether `line` stopped although the next line's first word would have fitted after it: a typed line break.
    private func endsShort(_ line: EditableLine, before next: EditableLine) -> Bool {
        guard let word = next.words.first else { return true }
        let size = max(style.pageFontSize, 1)
        let needed = word.bounds.width + size * 0.25
        return bounds.width - line.bounds.width > needed + max(2, size * 0.15)
    }
}

/// The blocks of one page.
struct PageText {
    var content: PageContent
    var blocks: [TextBlock]
    /// Crop box, page space.
    var cropBox: CGRect

    /// Words of a page's runs: units joined across runs when they continue a word (a kerned "W" "orld").
    static func words(of content: PageContent) -> [(word: LayoutWord, spans: [TextSpan])] {
        struct Fragment { var span: TextSpan; var text: String; var bounds: CGRect; var run: TextRun }
        var fragments: [Fragment] = []
        for run in content.runs where run.renderMode != 3 && run.renderMode != 7 {
            var start: Int?
            func flush(_ end: Int) {
                guard let s = start else { return }
                start = nil
                let range = s..<end
                let text = run.units[range].map(\.text).joined()
                guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
                fragments.append(Fragment(span: TextSpan(run: run.id, range: range), text: text, bounds: run.bounds(of: range), run: run))
            }
            for (i, unit) in run.units.enumerated() {
                let isSpace = unit.text.isEmpty ? false : unit.text.allSatisfy(\.isWhitespace)
                if isSpace || unit.isWordSpace && unit.text.isEmpty { flush(i) } else if start == nil { start = i }
            }
            flush(run.units.count)
        }
        var out: [(LayoutWord, [TextSpan])] = []
        var current: [Fragment] = []
        func emit() {
            guard let first = current.first else { return }
            let run = first.run
            let bounds = current.dropFirst().reduce(first.bounds) { $0.union($1.bounds) }
            var word = LayoutWord(text: current.map(\.text).joined(), bounds: bounds, fontName: run.font.baseFont, fontSize: run.pageFontSize,
                                  isBold: run.font.facts.isBold, isItalic: run.font.facts.isItalic, color: BlockStyle.hex(of: run.colorOps))
            if word.text.isEmpty { word.text = " " }
            out.append((word, current.map(\.span)))
            current = []
        }
        for fragment in fragments {
            if let last = current.last {
                let run = last.run
                let sameLine = abs(fragment.run.baselinePoint(x: 0).y - run.baselinePoint(x: 0).y) < run.pageFontSize * 0.25
                    && abs(fragment.run.pageFontSize - run.pageFontSize) < 0.6
                let gap = fragment.bounds.minX - last.bounds.maxX
                let rotatedAlike = abs(fragment.run.matrix.b - run.matrix.b) < 0.01 && abs(fragment.run.matrix.c - run.matrix.c) < 0.01
                if sameLine, rotatedAlike, gap > -run.pageFontSize * 0.5, gap < run.pageFontSize * 0.12, run.matrix.b == 0 {
                    current.append(fragment)
                    continue
                }
                emit()
            }
            current.append(fragment)
        }
        emit()
        return out
    }

    /// Reads a page into blocks.
    static func analyze(_ page: PDFPage, content: PageContent) -> PageText {
        let crop = page.box(.crop)
        let words = words(of: content)
        var spansByWord: [LayoutWord: [TextSpan]] = [:]
        var shifted: [LayoutWord] = []
        for (word, spans) in words {
            var w = word
            w.bounds.origin.x -= crop.minX; w.bounds.origin.y -= crop.minY
            spansByWord[w] = spans
            shifted.append(w)
        }
        let input = PageInput(index: page.index ?? 0, size: crop.size, rotation: 0, words: shifted)
        let options = LayoutOptions(recognition: .never, languages: [], detectTables: false, excludeHeadersAndFooters: false)
        let layout = LayoutAnalyzer.analyze(input, options: options)
        var blocks: [TextBlock] = []
        for block in layout.blocks {
            var lines: [EditableLine] = []
            for line in block.lines {
                let spans = line.words.flatMap { spansByWord[$0] ?? [] }
                guard let firstSpan = spans.first else { continue }
                let run = content.runs[firstSpan.run]
                var bounds = line.bounds
                bounds.origin.x += crop.minX; bounds.origin.y += crop.minY
                let words = line.words.map { word -> LayoutWord in
                    var w = word
                    w.bounds.origin.x += crop.minX; w.bounds.origin.y += crop.minY
                    return w
                }
                let start = run.baselinePoint(x: run.offsets[firstSpan.range.lowerBound])
                lines.append(EditableLine(spans: spans, words: words, bounds: bounds, baselineStart: start))
            }
            guard !lines.isEmpty else { continue }
            var bounds = block.bounds
            bounds.origin.x += crop.minX; bounds.origin.y += crop.minY
            let runs = lines.flatMap(\.spans).map { content.runs[$0.run] }
            let dominant = runs.max { $0.units.count < $1.units.count }!
            let editable = runs.allSatisfy { !$0.inForm && $0.opIndex != nil }
            var basis = dominant.matrix
            basis.tx = 0; basis.ty = 0
            let style = BlockStyle(fontName: dominant.fontName, font: dominant.font, fontSize: dominant.fontSize, pageFontSize: dominant.pageFontSize,
                                   basis: basis, colorOps: dominant.colorOps, extGState: dominant.extGState, charSpacing: dominant.charSpacing)
            blocks.append(TextBlock(id: blocks.count, kind: block.kind, bounds: bounds, lines: lines, style: style,
                                    alignment: alignment(of: lines, in: bounds, fontSize: dominant.pageFontSize),
                                    linePitch: pitch(of: lines, fontSize: dominant.pageFontSize), isEditable: editable))
        }
        return PageText(content: content, blocks: blocks, cropBox: crop)
    }

    /// Left, centred, right or justified, from how the lines sit in the block.
    static func alignment(of lines: [EditableLine], in bounds: CGRect, fontSize: Double) -> TextAlignment {
        guard lines.count > 1 else { return .left }
        let tolerance = max(1.5, fontSize * 0.15)
        let lefts = lines.allSatisfy { abs($0.bounds.minX - bounds.minX) < tolerance }
        // Justified needs several full lines flush on both sides; two ragged lines of nearly equal length are not it.
        let rights = lines.dropLast().allSatisfy { abs($0.bounds.maxX - bounds.maxX) < 0.75 }
        let centers = lines.allSatisfy { abs($0.bounds.midX - bounds.midX) < tolerance }
        if lefts && rights && lines.count > 3 { return .justified }
        if lefts { return .left }
        if lines.allSatisfy({ abs($0.bounds.maxX - bounds.maxX) < tolerance }) { return .right }
        if centers { return .center }
        return .left
    }

    /// The baseline pitch: the median of the line steps, else 1.2 × the font size.
    static func pitch(of lines: [EditableLine], fontSize: Double) -> Double {
        let steps = zip(lines, lines.dropFirst()).map { hypot($0.baselineStart.x - $1.baselineStart.x, $0.baselineStart.y - $1.baselineStart.y) }
            .filter { $0 > fontSize * 0.5 }.sorted()
        guard !steps.isEmpty else { return (fontSize * 1.2 * 100).rounded() / 100 }
        return steps[steps.count / 2]
    }

    /// The block under a page point (the smallest when several overlap).
    func block(at point: CGPoint) -> TextBlock? {
        blocks.filter { $0.bounds.insetBy(dx: -2, dy: -2).contains(point) }.min { $0.bounds.width * $0.bounds.height < $1.bounds.width * $1.bounds.height }
    }
}
