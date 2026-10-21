import CoreGraphics
import Foundation
import LayoutKit
import SuperPDFCore

/// A field found on a flat page: where it goes, what kind it is and the label printed next to it.
struct DetectedField: Equatable, Sendable {
    var kind: FormFieldKind
    /// Page space, origin at the crop box's lower-left corner (LayoutKit's space).
    var bounds: CGRect
    var label: String
}

/// "Find fields for me" (features #81): the blanks of a printed form, from LayoutKit's words and page graphics. It
/// finds empty boxes (drawn as rectangles or as four lines), small squares and ☐ glyphs (tick boxes), runs of
/// underscores ("Name: ________") and lines to write on, names each after the words beside or above it, and guesses a
/// kind from that label (dates, amounts, signatures). Pure and quick: no AI, no network.
enum FieldDetector {
    static let checkGlyphs: Set<Character> = ["☐", "□", "❏", "❑", "◻", "▢", "⬜", "◽"]

    static func detect(words: [LayoutWord], graphics: PageGraphics, pageSize: CGSize, occupied: [CGRect] = []) -> [DetectedField] {
        let words = words.filter { !$0.text.trimmingCharacters(in: .whitespaces).isEmpty }
        let horizontals = graphics.rulings.filter(\.isHorizontal).map(\.bounds)
        let verticals = graphics.rulings.filter { !$0.isHorizontal }.map(\.bounds)
        var found: [DetectedField] = []
        var usedRulings: Set<Int> = []

        // Boxes drawn with four lines: a top and a bottom of the same width, closed by verticals at both ends.
        for (i, top) in horizontals.enumerated() where !usedRulings.contains(i) {
            let below = horizontals.enumerated().filter { j, bottom in
                j != i && !usedRulings.contains(j) && abs(bottom.minX - top.minX) <= 3 && abs(bottom.maxX - top.maxX) <= 3
                    && (8...400).contains(top.midY - bottom.midY)
            }.min { top.midY - $0.element.midY < top.midY - $1.element.midY }
            guard let (j, bottom) = below else { continue }
            let closes = { (x: CGFloat) in
                verticals.contains { abs($0.midX - x) <= 3 && $0.minY <= bottom.midY + 3 && $0.maxY >= top.midY - 3 }
            }
            guard closes(top.minX), closes(top.maxX) else { continue }
            let box = CGRect(x: top.minX, y: bottom.midY, width: top.width, height: top.midY - bottom.midY)
            usedRulings.insert(i); usedRulings.insert(j)
            if let field = boxField(box, words: words) { found.append(field) }
        }

        // Boxes and squares drawn as shapes.
        for shape in graphics.vectors {
            if let field = boxField(shape, words: words, pageSize: pageSize) { found.append(field) }
        }

        // ☐ glyphs.
        for word in words where word.text.first.map(checkGlyphs.contains) == true {
            let side = min(max(min(word.bounds.width, word.bounds.height), 8), 16)
            let square = CGRect(x: word.bounds.minX, y: word.bounds.midY - side / 2, width: side, height: side)
            found.append(DetectedField(kind: .checkbox, bounds: square, label: label(rightOf: square, in: words)))
        }

        // Runs of underscores, alone or after a label in the same word ("Name:_____").
        for word in words {
            let characters = Array(word.text)
            guard let start = characters.firstIndex(of: "_"), characters[start...].filter({ $0 == "_" }).count >= 3 else { continue }
            let end = characters.lastIndex(of: "_")! + 1
            let unit = word.bounds.width / CGFloat(max(characters.count, 1))
            let height = min(max(word.bounds.height, 14), 24)
            let blank = CGRect(x: word.bounds.minX + unit * CGFloat(start), y: word.bounds.minY, width: unit * CGFloat(end - start), height: height)
            guard blank.width >= 18 else { continue }
            let prefix = String(characters[..<start])
            let printed = prefix.trimmingCharacters(in: CharacterSet(charactersIn: ":_ "))
            let name = printed.isEmpty ? label(leftOf: blank, in: words, excluding: word) : printed
            found.append(DetectedField(kind: kind(for: name, fallback: .text), bounds: blank, label: name))
        }

        // Lines to write on: horizontal rulings that are not a box, not underlined text and not a table's grid.
        for (i, line) in horizontals.enumerated() where !usedRulings.contains(i) && line.width >= 30 {
            let crossing = verticals.filter { $0.minX >= line.minX - 2 && $0.maxX <= line.maxX + 2 && $0.minY <= line.midY + 2 && $0.maxY >= line.midY - 2 }
            guard crossing.count < 2 else { continue }
            let above = words.filter { $0.bounds.minX < line.maxX && $0.bounds.maxX > line.minX && $0.bounds.minY >= line.midY - 3 }
            let sitting = above.filter { $0.bounds.minY <= line.midY + 10 && overlap($0.bounds.minX...$0.bounds.maxX, line.minX...line.maxX) > $0.bounds.width * 0.5 }
            guard sitting.isEmpty else { continue }
            let roof = above.map(\.bounds.minY).min() ?? line.midY + 22
            let height = min(max(roof - line.midY - 2, 10), 20)
            let blank = CGRect(x: line.minX, y: line.midY + 1, width: line.width, height: height)
            let name = label(leftOf: blank, in: words)
            found.append(DetectedField(kind: kind(for: name, fallback: .text), bounds: blank, label: name))
        }

        // One field per place: fields already on the page win, then the order found (boxes, glyphs, underscores, lines).
        var kept: [DetectedField] = []
        for field in found where !(occupied + kept.map(\.bounds)).contains(where: { overlapArea($0, field.bounds) > 0.3 * min(area($0), area(field.bounds)) }) {
            kept.append(field)
        }
        return kept.sorted { a, b in
            abs(a.bounds.midY - b.bounds.midY) > 6 ? a.bounds.midY > b.bounds.midY : a.bounds.minX < b.bounds.minX
        }
    }

    /// An empty rectangle as a field: small squares are tick boxes, wide short ones text boxes, large ones
    /// multiple-line text. Nil for shapes that hold words or look like neither.
    private static func boxField(_ box: CGRect, words: [LayoutWord], pageSize: CGSize? = nil) -> DetectedField? {
        let w = box.width, h = box.height
        if let pageSize, w > pageSize.width * 0.95 || h > pageSize.height * 0.6 { return nil }
        let inside = words.filter { overlapArea($0.bounds, box) > area($0.bounds) * 0.5 }
        let isSquare = (6...24).contains(w) && (6...24).contains(h) && (0.75...1.33).contains(w / h)
        if isSquare {
            guard inside.isEmpty else { return nil }
            let square = box.insetBy(dx: 0.5, dy: 0.5)
            return DetectedField(kind: .checkbox, bounds: square, label: label(rightOf: box, in: words))
        }
        guard w >= 40, h >= 12 else { return nil }
        // A small caption inside the box's top-left corner ("Name") names it; anything more means it isn't empty.
        let captionTop: CGFloat = box.maxY - min(14, h * 0.45)
        let captionRight: CGFloat = box.minX + w * 0.5
        let caption = inside.filter { (word: LayoutWord) -> Bool in word.bounds.minY >= captionTop && word.bounds.minX <= captionRight }
        guard inside.count == caption.count, caption.count <= 4 else { return nil }
        var blank = box.insetBy(dx: 1, dy: 1)
        if let lowest = caption.map({ (word: LayoutWord) -> CGFloat in word.bounds.minY }).min() { blank.size.height = max(lowest - blank.minY - 1, 0) }
        guard blank.height >= 10 else { return nil }
        let ordered = caption.sorted { (a: LayoutWord, b: LayoutWord) -> Bool in a.bounds.minX < b.bounds.minX }
        let printed: String? = caption.isEmpty ? nil : ordered.map { (word: LayoutWord) -> String in word.text }.joined(separator: " ")
        let name = clean(printed ?? label(leftOf: box, in: words, above: true))
        let multiline = blank.height > 40 && w >= 120
        return DetectedField(kind: multiline ? .multilineText : kind(for: name, fallback: .text), bounds: blank, label: name)
    }

    // MARK: Labels

    /// The words just left of a blank on the same line (up to a gap), else the words just above its start.
    static func label(leftOf blank: CGRect, in words: [LayoutWord], excluding: LayoutWord? = nil, above: Bool = true) -> String {
        let line = words.filter { $0 != excluding && $0.bounds.maxX <= blank.minX + 2 && verticalOverlap($0.bounds, blank) > min($0.bounds.height, blank.height) * 0.3 }
            .sorted { $0.bounds.maxX > $1.bounds.maxX }
        var picked: [LayoutWord] = []
        var edge = blank.minX
        for word in line {
            guard edge - word.bounds.maxX <= (picked.isEmpty ? 150 : 12) else { break }
            picked.append(word)
            edge = word.bounds.minX
        }
        if !picked.isEmpty { return clean(picked.reversed().map(\.text).joined(separator: " ")) }
        guard above else { return "" }
        let over = words.filter { $0 != excluding && $0.bounds.minY >= blank.maxY - 2 && $0.bounds.minY <= blank.maxY + 18
            && $0.bounds.minX >= blank.minX - 6 && $0.bounds.minX <= blank.minX + max(blank.width * 0.5, 40) }
        guard let first = over.min(by: { $0.bounds.minY < $1.bounds.minY }) else { return "" }
        let row = over.filter { abs($0.bounds.midY - first.bounds.midY) < 4 }.sorted { $0.bounds.minX < $1.bounds.minX }
        return clean(row.map(\.text).joined(separator: " "))
    }

    /// The words right of a tick box on the same line, up to a gap.
    static func label(rightOf box: CGRect, in words: [LayoutWord]) -> String {
        let line = words.filter { $0.bounds.minX >= box.maxX - 1 && verticalOverlap($0.bounds, box) > min($0.bounds.height, box.height) * 0.3
            && $0.text.first.map(checkGlyphs.contains) != true }
            .sorted { $0.bounds.minX < $1.bounds.minX }
        var picked: [LayoutWord] = []
        var edge = box.maxX
        for word in line {
            guard word.bounds.minX - edge <= (picked.isEmpty ? 40 : 12) else { break }
            picked.append(word)
            edge = word.bounds.maxX
        }
        return clean(picked.map(\.text).joined(separator: " "))
    }

    /// The kind a label suggests.
    static func kind(for label: String, fallback: FormFieldKind) -> FormFieldKind {
        let text = label.lowercased()
        if ["signature", "sign here", "signed"].contains(where: text.contains) { return .signature }
        if ["date", "dob", "d.o.b", "birth"].contains(where: text.contains) { return .date }
        if ["amount", "total", "price", "cost", "qty", "quantity", "$", "£", "€"].contains(where: text.contains) { return .number }
        return fallback
    }

    static func clean(_ label: String) -> String {
        label.trimmingCharacters(in: CharacterSet(charactersIn: ":_*.() ").union(.whitespacesAndNewlines))
    }

    // MARK: Geometry

    private static func area(_ r: CGRect) -> CGFloat { max(r.width, 0) * max(r.height, 0) }

    private static func overlapArea(_ a: CGRect, _ b: CGRect) -> CGFloat {
        let i = a.intersection(b)
        return i.isNull ? 0 : area(i)
    }

    private static func overlap(_ a: ClosedRange<CGFloat>, _ b: ClosedRange<CGFloat>) -> CGFloat {
        max(0, min(a.upperBound, b.upperBound) - max(a.lowerBound, b.lowerBound))
    }

    private static func verticalOverlap(_ a: CGRect, _ b: CGRect) -> CGFloat { overlap(a.minY...a.maxY, b.minY...b.maxY) }
}
