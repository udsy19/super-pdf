import AppKit
import CoreGraphics
import Foundation
import PDFModelKit
import SuperPDFCore

// Rewrites text on a page (features #60, #62, #72): a block retyped and reflowed in its own box with its own font
// (or a stand-in when the font can't show the new characters), a word replaced in place when it fits, and new text
// boxes. Only the operations that drew the old text change; everything else on the page stays as it was.

/// Something that turns text into glyphs with widths.
protocol TextEncoding: AnyObject {
    func units(of text: String) -> [GlyphUnit]?
    var ascent: Double { get }
    var descent: Double { get }
}

extension PDFFont: TextEncoding {}
extension WritableFont: TextEncoding {}

/// What to put in a block.
struct TextEdit {
    var text: String
    /// A font chosen in the properties strip (family, bold, italic); nil keeps the block's.
    var font: NSFont?
    /// Page-space font size; nil keeps the block's.
    var size: Double?
    /// "#RRGGBB"; nil keeps the block's.
    var color: String?
    var alignment: TextAlignment?

    init(text: String, font: NSFont? = nil, size: Double? = nil, color: String? = nil, alignment: TextAlignment? = nil) {
        self.text = text; self.font = font; self.size = size; self.color = color; self.alignment = alignment
    }
}

/// What a rewrite did.
struct TextEditOutcome {
    /// The PDF font's family and the stand-in used, when the block's font couldn't show the new text.
    var substitution: (from: String, to: String)?
    /// Where the new text is, page space.
    var bounds: CGRect
}

enum TextRewriteError: Error, Equatable {
    case notEditable
    case cannotShowText
}

enum TextRewriter {
    // MARK: Blocks

    /// Retypes a block: its old glyphs go, the new text is laid out in the block's box (left, centred, right or
    /// justified as before), in the block's font when it has the glyphs, else in the closest font on this Mac.
    static func replace(block: TextBlock, with edit: TextEdit, in pageText: PageText, page: PDFPage) throws -> TextEditOutcome {
        guard block.isEditable else { throw TextRewriteError.notEditable }
        let content = pageText.content
        let replacements = removals(of: block.spans, in: content)
        var ops: [PDFContentOperation] = []
        var outcome = TextEditOutcome(substitution: nil, bounds: block.bounds)
        let trimmed = edit.text.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmed.isEmpty {
            let (encoder, resourceName, substitution) = try font(for: block, edit: edit, page: page)
            outcome.substitution = substitution
            let style = block.style
            let scaleY = hypot(style.basis.c, style.basis.d)
            let scaleX = hypot(style.basis.a, style.basis.b)
            var fontSize = style.fontSize
            if let size = edit.size, style.pageFontSize > 0 { fontSize = size / max(scaleY, 0.0001) }
            let origin = block.lines[0].baselineStart
            let toText = CGAffineTransform(translationX: -origin.x, y: -origin.y).concatenating(style.basis.inverted())
            let corners = [CGPoint(x: block.bounds.minX, y: block.bounds.minY), CGPoint(x: block.bounds.maxX, y: block.bounds.minY),
                           CGPoint(x: block.bounds.minX, y: block.bounds.maxY), CGPoint(x: block.bounds.maxX, y: block.bounds.maxY)].map { $0.applying(toText) }
            let left = corners.map(\.x).min() ?? 0, right = corners.map(\.x).max() ?? 0
            var width = max(right - left, fontSize)
            let pitchText = block.linePitch / max(scaleY, 0.0001) * (fontSize / max(style.fontSize, 0.0001))
            // A single line keeps growing to the right until the page's edge: it had no wrap to tell us its box.
            if block.lines.count == 1 {
                let edge = CGPoint(x: pageText.cropBox.maxX - 36, y: origin.y).applying(toText).x
                if scaleX > 0, edge > right { width = max(width, edge - left) }
            }
            let layout = layoutLines(edit.text, encoder: encoder, fontSize: fontSize, charSpacing: style.charSpacing, width: width,
                                     alignment: edit.alignment ?? block.alignment)
            var colorOps = style.colorOps
            if let color = edit.color { colorOps = BlockStyle.colorOps(for: color) }
            let (textOps, bounds) = emit(layout, resourceName: resourceName, fontSize: fontSize, charSpacing: style.charSpacing, basis: style.basis,
                                         origin: origin, left: left, width: width, pitch: pitchText, colorOps: colorOps, extGState: style.extGState,
                                         rise: 0, ascent: encoder.ascent, descent: encoder.descent)
            ops = textOps
            outcome.bounds = bounds
            if let writable = encoder as? WritableFont { writable.finish() }
        } else {
            outcome.bounds = .null
        }
        let stream = ContentSurgery.rewrite(content.stream, replacing: replacements, appending: ops)
        page.setContentStream(stream)
        return outcome
    }

    /// A new block of text at `origin` (its first baseline's start), wrapped to `width`.
    static func addTextBox(_ text: String, at origin: CGPoint, width: Double, font: NSFont, size: Double, color: String, alignment: TextAlignment = .left,
                           page: PDFPage) throws -> CGRect {
        let content = try ContentInterpreter.read(page)
        let (encoder, resourceName) = writableFont(font, on: page)
        guard encoder.canShow(glyphText(text)) else { throw TextRewriteError.cannotShowText }
        let layout = layoutLines(text, encoder: encoder, fontSize: size, charSpacing: 0, width: width, alignment: alignment)
        let (ops, bounds) = emit(layout, resourceName: resourceName, fontSize: size, charSpacing: 0, basis: .identity, origin: origin, left: 0,
                                 width: width, pitch: size * 1.2, colorOps: BlockStyle.colorOps(for: color), extGState: nil, rise: 0,
                                 ascent: encoder.ascent, descent: encoder.descent)
        encoder.finish()
        page.setContentStream(ContentSurgery.rewrite(content.stream, replacing: [:], appending: ops))
        return bounds
    }

    /// The resource for a font on this Mac: by name for the standard 14 families, else embedded.
    static func writableFont(_ font: NSFont, on page: any ResourceHolder) -> (WritableFont, String) {
        if let standard = standardName(for: font) { return FontEmbedder.standardFont(standard, on: page) }
        return FontEmbedder.embeddedFont(font, on: page)
    }

    /// "Helvetica-Bold" for Helvetica/Arial bold, "Times-Italic" for Times, "Courier" for Courier; nil for other fonts.
    static func standardName(for font: NSFont) -> String? {
        let family = (font.familyName ?? "").lowercased()
        let traits = font.fontDescriptor.symbolicTraits
        let bold = traits.contains(.bold), italic = traits.contains(.italic)
        func name(_ base: String, _ boldSuffix: String, _ italicSuffix: String, _ bothSuffix: String, _ plain: String) -> String {
            bold && italic ? base + bothSuffix : bold ? base + boldSuffix : italic ? base + italicSuffix : base + plain
        }
        switch family {
        case "helvetica", "arial": return name("Helvetica", "-Bold", "-Oblique", "-BoldOblique", "")
        case "times", "times new roman": return name("Times", "-Bold", "-Italic", "-BoldItalic", "-Roman")
        case "courier", "courier new": return name("Courier", "-Bold", "-Oblique", "-BoldOblique", "")
        default: return nil
        }
    }

    private static func font(for block: TextBlock, edit: TextEdit, page: PDFPage) throws -> (TextEncoding, String, (from: String, to: String)?) {
        let original = block.style.font
        let text = glyphText(edit.text)
        if let chosen = edit.font {
            let (writable, name) = writableFont(chosen, on: page)
            guard writable.canShow(text) else { throw TextRewriteError.cannotShowText }
            return (writable, name, nil)
        }
        if !block.style.fontName.isEmpty, original.canShow(text) { return (original, block.style.fontName, nil) }
        let (match, substituted) = FontMatcher.match(original.facts, size: CGFloat(block.style.pageFontSize))
        var candidate = match
        if !canShow(candidate, text) {
            // The matched family lacks a character: fall back through the standard faces.
            for fallback in ["Helvetica", "Georgia", "Times New Roman", "Arial Unicode MS"] {
                if let f = FontMatcher.installedFont(family: fallback, bold: original.facts.isBold, italic: original.facts.isItalic, size: CGFloat(block.style.pageFontSize)), canShow(f, text) {
                    candidate = f; break
                }
            }
        }
        let (writable, name) = writableFont(candidate, on: page)
        guard writable.canShow(text) else { throw TextRewriteError.cannotShowText }
        let from = original.facts.familyName, to = candidate.familyName ?? candidate.fontName
        return (writable, name, substituted || from.caseInsensitiveCompare(to) != .orderedSame ? (from, to) : nil)
    }

    /// The characters a font has to draw: line breaks start new lines and need no glyph.
    static func glyphText(_ text: String) -> String { text.components(separatedBy: .newlines).joined(separator: " ") }

    private static func canShow(_ font: NSFont, _ text: String) -> Bool {
        let ct = font as CTFont
        var units = Array(text.utf16)
        var glyphs = [CGGlyph](repeating: 0, count: units.count)
        return CTFontGetGlyphsForCharacters(ct, &units, &glyphs, units.count)
    }

    // MARK: Removing old glyphs

    /// The operations that drew `spans`, rewritten without those glyphs (their advance kept so other text stays put).
    static func removals(of spans: [TextSpan], in content: PageContent) -> [Int: [PDFContentOperation]] {
        var removedUnits: [Int: Set<Int>] = [:]   // run id → unit indices
        for span in spans { removedUnits[span.run, default: []].formUnion(span.range) }
        var byOp: [Int: [TextRun]] = [:]
        for runID in removedUnits.keys {
            let run = content.runs[runID]
            guard let opIndex = run.opIndex else { continue }
            byOp[opIndex, default: []].append(run)
        }
        var replacements: [Int: [PDFContentOperation]] = [:]
        for (opIndex, runs) in byOp {
            let op = content.stream.operations[opIndex]
            let fontSize = runs[0].fontSize
            var out: [PDFContentOperation] = []
            switch op.operator {
            case "'":
                out.append(PDFContentOperation("T*"))
            case "\"":
                out.append(PDFContentOperation("Tw", [op.operands.first ?? .integer(0)]))
                out.append(PDFContentOperation("Tc", [op.operands.count > 1 ? op.operands[1] : .integer(0)]))
                out.append(PDFContentOperation("T*"))
            default:
                break
            }
            if op.operator == "TJ", let array = op.operands.first?.arrayValue {
                var all: [ContentSurgery.Piece] = []
                let runsByElement = Dictionary(uniqueKeysWithValues: runs.map { ($0.elementIndex ?? -1, $0) })
                for (i, item) in array.enumerated() {
                    if let run = runsByElement[i] {
                        all.append(contentsOf: pieces(of: run, removing: removedUnits[run.id] ?? []))
                    } else if let n = item.numberValue {
                        all.append(.skip(-n / 1000 * fontSize))
                    } else if let bytes = item.stringValue {
                        all.append(.keep(bytes))
                    }
                }
                out.append(ContentSurgery.tj(all, fontSize: fontSize))
            } else {
                let run = runs[0]
                out.append(ContentSurgery.tj(pieces(of: run, removing: removedUnits[run.id] ?? []), fontSize: fontSize))
            }
            replacements[opIndex] = out
        }
        return replacements
    }

    private static func pieces(of run: TextRun, removing removed: Set<Int>) -> [ContentSurgery.Piece] {
        var pieces: [ContentSurgery.Piece] = []
        var kept = Data()
        var skipped = 0.0
        for (i, unit) in run.units.enumerated() {
            if removed.contains(i) {
                if !kept.isEmpty { pieces.append(.keep(kept)); kept = Data() }
                skipped += run.advances[i]
            } else {
                if skipped != 0 { pieces.append(.skip(skipped)); skipped = 0 }
                kept.append(unit.bytes)
            }
        }
        if !kept.isEmpty { pieces.append(.keep(kept)) }
        if skipped != 0 { pieces.append(.skip(skipped)) }
        return pieces
    }

    // MARK: Laying out new text

    struct LaidOutWord {
        var units: [GlyphUnit]
        var width: Double
    }

    struct LaidOutLine {
        var words: [LaidOutWord]
        var width: Double
        var endsParagraph: Bool
    }

    struct Layout {
        var lines: [LaidOutLine]
        var space: [GlyphUnit]?
        var spaceWidth: Double
        var alignment: TextAlignment
    }

    /// Wraps `text` into lines of at most `width` (text space): explicit line breaks are kept, words wrap, and a word
    /// wider than the box breaks between characters.
    static func layoutLines(_ text: String, encoder: TextEncoding, fontSize: Double, charSpacing: Double, width: Double, alignment: TextAlignment) -> Layout {
        func advance(_ units: [GlyphUnit]) -> Double { units.reduce(0) { $0 + $1.width / 1000 * fontSize + charSpacing } }
        let space = encoder.units(of: " ")
        let spaceWidth = space.map(advance) ?? fontSize * 0.25
        var lines: [LaidOutLine] = []
        for paragraph in text.replacingOccurrences(of: "\r\n", with: "\n").split(separator: "\n", omittingEmptySubsequences: false) {
            var current: [LaidOutWord] = []
            var currentWidth = 0.0
            func flush(endsParagraph: Bool) {
                lines.append(LaidOutLine(words: current, width: currentWidth, endsParagraph: endsParagraph))
                current = []; currentWidth = 0
            }
            for word in paragraph.split(separator: " ", omittingEmptySubsequences: true) {
                guard let units = encoder.units(of: String(word)) else { continue }
                var pieces: [[GlyphUnit]] = [units]
                if advance(units) > width, units.count > 1 {
                    pieces = []
                    var piece: [GlyphUnit] = []
                    for unit in units {
                        if advance(piece + [unit]) > width, !piece.isEmpty { pieces.append(piece); piece = [] }
                        piece.append(unit)
                    }
                    pieces.append(piece)
                }
                for piece in pieces {
                    let w = advance(piece)
                    let needed = current.isEmpty ? w : currentWidth + spaceWidth + w
                    if needed > width + 0.01, !current.isEmpty { flush(endsParagraph: false) }
                    currentWidth = current.isEmpty ? w : currentWidth + spaceWidth + w
                    current.append(LaidOutWord(units: piece, width: w))
                }
            }
            flush(endsParagraph: true)
        }
        return Layout(lines: lines, space: space, spaceWidth: spaceWidth, alignment: alignment)
    }

    /// The operations that draw a layout, and their page-space bounds.
    static func emit(_ layout: Layout, resourceName: String, fontSize: Double, charSpacing: Double, basis: CGAffineTransform, origin: CGPoint,
                     left: Double, width: Double, pitch: Double, colorOps: [PDFContentOperation], extGState: String?, rise: Double,
                     ascent: Double, descent: Double) -> ([PDFContentOperation], CGRect) {
        var ops: [PDFContentOperation] = [PDFContentOperation("q")]
        if let extGState { ops.append(PDFContentOperation("gs", [.name(extGState)])) }
        ops.append(contentsOf: colorOps)
        ops.append(PDFContentOperation("BT"))
        ops.append(PDFContentOperation("Tf", [.name(resourceName), .number(ContentSurgery.round(fontSize))]))
        ops.append(PDFContentOperation("Tc", [.number(ContentSurgery.round(charSpacing))]))
        ops.append(PDFContentOperation("Tw", [.integer(0)]))
        ops.append(PDFContentOperation("Tz", [.integer(100)]))
        ops.append(PDFContentOperation("Ts", [.number(ContentSurgery.round(rise))]))
        ops.append(PDFContentOperation("Tr", [.integer(0)]))
        var bounds = CGRect.null
        for (i, line) in layout.lines.enumerated() {
            let y = -Double(i) * pitch
            var x = left
            var gap = layout.spaceWidth
            switch layout.alignment {
            case .center: x = left + (width - line.width) / 2
            case .right: x = left + width - line.width
            case .justified where line.words.count > 1 && !line.endsParagraph:
                gap = layout.spaceWidth + min((width - line.width) / Double(line.words.count - 1), layout.spaceWidth * 3)
            default: break
            }
            let p = CGPoint(x: x, y: y).applying(basis)
            ops.append(PDFContentOperation("Tm", [.number(ContentSurgery.round(basis.a)), .number(ContentSurgery.round(basis.b)),
                                                  .number(ContentSurgery.round(basis.c)), .number(ContentSurgery.round(basis.d)),
                                                  .number(ContentSurgery.round(p.x + origin.x)), .number(ContentSurgery.round(p.y + origin.y))]))
            var pieces: [ContentSurgery.Piece] = []
            var lineWidth = 0.0
            for (w, word) in line.words.enumerated() {
                if w > 0 {
                    if let space = layout.space {
                        pieces.append(.keep(space.reduce(Data()) { $0 + $1.bytes }))
                        if gap > layout.spaceWidth { pieces.append(.skip(gap - layout.spaceWidth)) }
                    } else {
                        pieces.append(.skip(gap))
                    }
                    lineWidth += gap
                }
                pieces.append(.keep(word.units.reduce(Data()) { $0 + $1.bytes }))
                lineWidth += word.width
            }
            ops.append(ContentSurgery.tj(pieces, fontSize: fontSize))
            let matrix = basis.concatenating(CGAffineTransform(translationX: origin.x, y: origin.y))
            let box = TextRun.box(x0: x, x1: x + lineWidth, fontSize: fontSize, rise: rise + y, ascent: ascent, descent: descent, matrix: matrix)
            bounds = bounds.union(box)
        }
        ops.append(PDFContentOperation("ET"))
        ops.append(PDFContentOperation("Q"))
        return (ops, bounds)
    }

    // MARK: Find and replace

    struct ReplaceOutcome {
        var replaced = 0
        var notFitting = 0
        var substitutions: [String: String] = [:]
    }

    /// Replaces `find` with `replacement` on the page: in place when the new word fits where the old one was (the
    /// text after it stays put), else by reflowing its block; the font stays the same (features #72).
    static func replaceAll(_ find: String, with replacement: String, options: FindReplaceOptions, page: PDFPage) throws -> ReplaceOutcome {
        guard !find.isEmpty else { return ReplaceOutcome() }
        var outcome = ReplaceOutcome()
        var pattern = NSRegularExpression.escapedPattern(for: find)
        if options.wholeWords { pattern = "\\b" + pattern + "\\b" }
        let regex = try NSRegularExpression(pattern: pattern, options: options.matchCase ? [] : [.caseInsensitive])
        var passes = 0
        // Each in-place pass rewrites the content, so the page is read again until nothing is left to replace.
        while passes < 50 {
            passes += 1
            let content = try ContentInterpreter.read(page)
            let pageText = PageText.analyze(page, content: content)
            var done = false
            for block in pageText.blocks {
                let text = block.text as NSString
                let matches = regex.matches(in: block.text, range: NSRange(location: 0, length: text.length))
                guard !matches.isEmpty else { continue }
                guard block.isEditable else { outcome.notFitting += matches.count; continue }
                // Try the first match in place; when it doesn't fit, reflow the whole block with every match replaced.
                if let match = matches.first, let inPlace = try replaceInPlace(match.range, in: block, pageText: pageText, replacement: replacement, page: page) {
                    outcome.replaced += 1
                    if let s = inPlace { outcome.substitutions[s.from] = s.to }
                    done = true
                    break
                }
                let newText = regex.stringByReplacingMatches(in: block.text, range: NSRange(location: 0, length: text.length), withTemplate: NSRegularExpression.escapedTemplate(for: replacement))
                do {
                    let result = try replace(block: block, with: TextEdit(text: newText), in: pageText, page: page)
                    outcome.replaced += matches.count
                    if let s = result.substitution { outcome.substitutions[s.from] = s.to }
                } catch {
                    outcome.notFitting += matches.count
                    continue
                }
                done = true
                break
            }
            if !done { break }
        }
        return outcome
    }

    /// Replaces one match inside its run(s) when the replacement fits before the next word; nil when it doesn't.
    /// Returns a substitution when the font couldn't show the replacement and a stand-in was embedded.
    private static func replaceInPlace(_ range: NSRange, in block: TextBlock, pageText: PageText, replacement: String, page: PDFPage) throws -> (from: String, to: String)?? {
        let content = pageText.content
        // Map each character of the block's text to the glyph unit that draws it (nil for the joins between words
        // and lines); spans come in word order, so a word's characters are counted off its spans.
        var map: [(run: Int, unit: Int)?] = []
        for (l, line) in block.lines.enumerated() {
            if l > 0 { map.append(nil) }
            var wordIndex = 0
            var spanIndex = 0
            var charsLeft = line.words.first.map { $0.text.count } ?? 0
            while spanIndex < line.spans.count, wordIndex < line.words.count {
                let span = line.spans[spanIndex]
                let run = content.runs[span.run]
                for unit in span.range {
                    for _ in run.units[unit].text { map.append((span.run, unit)); charsLeft -= 1 }
                }
                spanIndex += 1
                if charsLeft <= 0 {
                    wordIndex += 1
                    if wordIndex < line.words.count { map.append(nil); charsLeft = line.words[wordIndex].text.count }
                }
            }
        }
        guard range.location + range.length <= map.count else { return nil }
        let covered = map[range.location..<(range.location + range.length)]
        guard let first = covered.compactMap({ $0 }).first, let last = covered.compactMap({ $0 }).last else { return nil }
        // A ligature can't be split.
        if range.location > 0, let before = map[range.location - 1], let f = covered.first ?? nil, before == f { return nil }
        if range.location + range.length < map.count, let after = map[range.location + range.length], let l = covered.last ?? nil, after == l { return nil }
        guard first.run == last.run else { return nil }   // across runs: the block reflow handles it
        let run = content.runs[first.run]
        guard run.opIndex != nil, !run.inForm else { return nil }
        let removed = first.unit...last.unit
        let oldWidth = removed.reduce(0.0) { $0 + run.advances[$1] }
        let font = run.font
        guard let newUnits = font.units(of: replacement) else { return nil }
        let newWidth = newUnits.reduce(0.0) { $0 + $1.width / 1000 * run.fontSize + run.charSpacing }
        // Slack: up to the next glyph after the match (in this run or the next on the line), less a space.
        var slack = 0.0
        let lineRuns = block.lines.first { $0.spans.contains { $0.run == run.id } }?.spans.map { content.runs[$0.run] } ?? []
        let endX = run.baselinePoint(x: run.offsets[last.unit] + run.advances[last.unit]).x
        var nextX: Double?
        if last.unit + 1 < run.units.count {
            let next = run.units[(last.unit + 1)...].enumerated().first { !$0.element.text.allSatisfy(\.isWhitespace) }
            if let next { nextX = run.baselinePoint(x: run.offsets[last.unit + 1 + next.offset]).x }
        }
        if nextX == nil {
            let later = lineRuns.filter { $0.id != run.id && $0.bounds.minX > endX - 0.5 }.min { $0.bounds.minX < $1.bounds.minX }
            nextX = later?.bounds.minX ?? block.bounds.maxX
        }
        if let nextX {
            let scaleX = max(hypot(run.matrix.a, run.matrix.b), 0.0001)
            slack = (nextX - endX) / scaleX
            if last.unit + 1 < run.units.count, run.units[last.unit + 1].text.allSatisfy(\.isWhitespace), !run.units[last.unit + 1].text.isEmpty {
                slack -= run.advances[last.unit + 1]
            } else if nextX != block.bounds.maxX {
                slack -= run.fontSize * 0.25
            }
        }
        let shifts = restOfLineShifts(run, by: newWidth - oldWidth, endX: endX, block: block, pageText: pageText)
        guard shifts || newWidth <= oldWidth + max(slack, 0) + 0.01 else { return nil }
        // Rebuild the run's op: kept glyphs before, the replacement, kept glyphs after. When the rest of the line is in
        // this op it moves with the new width, as typing would; else the width difference becomes an adjustment so
        // the text drawn after it keeps its place.
        var pieces: [ContentSurgery.Piece] = []
        let before = run.units[..<first.unit].reduce(Data()) { $0 + $1.bytes }
        let after = run.units[(last.unit + 1)...].reduce(Data()) { $0 + $1.bytes }
        if !before.isEmpty { pieces.append(.keep(before)) }
        pieces.append(.keep(newUnits.reduce(Data()) { $0 + $1.bytes }))
        if !shifts, oldWidth - newWidth != 0 { pieces.append(.skip(oldWidth - newWidth)) }
        if !after.isEmpty { pieces.append(.keep(after)) }
        var replacements: [Int: [PDFContentOperation]] = [:]
        let op = content.stream.operations[run.opIndex!]
        var out: [PDFContentOperation] = []
        if op.operator == "'" { out.append(PDFContentOperation("T*")) }
        if op.operator == "\"" {
            out.append(PDFContentOperation("Tw", [op.operands.first ?? .integer(0)]))
            out.append(PDFContentOperation("Tc", [op.operands.count > 1 ? op.operands[1] : .integer(0)]))
            out.append(PDFContentOperation("T*"))
        }
        if op.operator == "TJ", let array = op.operands.first?.arrayValue {
            var all: [ContentSurgery.Piece] = []
            for (i, item) in array.enumerated() {
                if i == run.elementIndex { all.append(contentsOf: pieces) } else if let n = item.numberValue { all.append(.skip(-n / 1000 * run.fontSize)) } else if let bytes = item.stringValue { all.append(.keep(bytes)) }
            }
            out.append(ContentSurgery.tj(all, fontSize: run.fontSize))
        } else {
            out.append(ContentSurgery.tj(pieces, fontSize: run.fontSize))
        }
        replacements[run.opIndex!] = out
        page.setContentStream(ContentSurgery.rewrite(content.stream, replacing: replacements, appending: []))
        return .some(nil)
    }

    /// Whether the text after a replacement can move by `delta` (text space): the op draws only this line of the block,
    /// the line is upright, and a longer word still ends before the next text on the baseline or the block's edge (a
    /// one-line block may grow to the page margin, as when it is retyped).
    private static func restOfLineShifts(_ run: TextRun, by delta: Double, endX: Double, block: TextBlock, pageText: PageText) -> Bool {
        let content = pageText.content
        guard abs(run.matrix.b) < 1e-6, abs(run.matrix.c) < 1e-6, run.matrix.a > 0,
              let line = block.lines.first(where: { $0.spans.contains { $0.run == run.id } }) else { return false }
        let opRuns = content.runs.filter { $0.opIndex == run.opIndex }
        guard opRuns.allSatisfy({ r in line.spans.contains { $0.run == r.id } }) else { return false }
        if delta <= 0 { return true }
        let opEnd = Double(opRuns.map(\.bounds.maxX).max() ?? CGFloat(endX))
        let next = content.runs.filter {
            $0.opIndex != run.opIndex && $0.bounds.minX >= opEnd - 0.5 && $0.bounds.midY > run.bounds.minY && $0.bounds.midY < run.bounds.maxY
        }.map { Double($0.bounds.minX) }.min()
        let edge = Double(block.lines.count == 1 ? pageText.cropBox.maxX - 36 : block.bounds.maxX)
        let limit = next.map { $0 - run.fontSize * 0.25 * run.matrix.a } ?? edge
        return delta <= (limit - opEnd) / run.matrix.a + 0.01
    }
}
