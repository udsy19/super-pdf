import CoreGraphics
import CoreText
import Foundation
import RenderKit
import SuperPDFCore

// Compare files (features #13): the words of both versions in reading order, diffed line by line and then word by word
// inside changed lines (Myers), grouped into inserted / deleted / changed runs with their places on both versions;
// unless "Text only", pictures and drawing compared by rendering both at 36 dpi and comparing 12 pt tiles outside the
// text. A report PDF lists the changes and shows the newer pages with them marked.

/// A word of one version with its place (page space from the crop box, as LayoutKit gives it).
struct CompareWord: Hashable {
    var text: String
    var page: Int
    var bounds: CGRect
    var line: Int
}

/// A change with where it is on both versions (for the panel's marks and the report).
struct LocatedChange {
    var change: ComparisonChange
    /// Boxes on the older version (deleted and changed words).
    var oldBoxes: [CGRect] = []
    /// Boxes on the newer version (inserted and changed words, a visual change's area); for a deletion, the word it sits
    /// next to.
    var newBoxes: [CGRect] = []
}

enum Comparer {
    // MARK: Words

    /// Every word in reading order: blocks the reading order names, then table cells, then the rest (headers, footers).
    static func words(_ layout: LayoutDocument) -> [CompareWord] {
        var words: [CompareWord] = []
        var line = 0
        func add(_ lines: [LayoutLine], page: Int) {
            for l in lines {
                for word in l.words where !word.text.trimmingCharacters(in: .whitespaces).isEmpty {
                    words.append(CompareWord(text: word.text, page: page, bounds: word.bounds, line: line))
                }
                line += 1
            }
        }
        for page in layout.pages {
            var used: Set<Int> = []
            for element in page.readingOrder {
                switch element {
                case .block(let id):
                    guard let block = page.blocks.first(where: { $0.id == id }) else { continue }
                    used.insert(id)
                    add(block.lines, page: page.index)
                case .table(let id):
                    guard let table = page.tables.first(where: { $0.id == id }) else { continue }
                    for cell in table.cells.sorted(by: { ($0.row, $0.column) < ($1.row, $1.column) }) {
                        let tokens = cell.text.split(whereSeparator: \.isWhitespace).map(String.init)
                        for (i, token) in tokens.enumerated() {
                            let width = cell.bounds.width / CGFloat(max(tokens.count, 1))
                            words.append(CompareWord(text: token, page: page.index,
                                                     bounds: CGRect(x: cell.bounds.minX + CGFloat(i) * width, y: cell.bounds.minY, width: width, height: cell.bounds.height),
                                                     line: line))
                        }
                        line += 1
                    }
                case .figure: break
                }
            }
            for block in page.blocks where !used.contains(block.id) { add(block.lines, page: page.index) }
        }
        return words
    }

    // MARK: Text differences

    static func textChanges(old: [CompareWord], new: [CompareWord]) -> [LocatedChange] {
        let oldLines = lines(old), newLines = lines(new)
        var changes: [LocatedChange] = []
        for hunk in diff(oldLines.map(\.key), newLines.map(\.key)) {
            let oldWords = hunk.old.flatMap { oldLines[$0].words }, newWords = hunk.new.flatMap { newLines[$0].words }
            // Anchors for an empty side: the line before the hunk on that version.
            let oldAnchor = hunk.old.first.map { max($0 - 1, 0) } ?? hunk.oldPosition - 1
            let newAnchor = hunk.new.first.map { max($0 - 1, 0) } ?? hunk.newPosition - 1
            let oldBefore = oldLines.indices.contains(oldAnchor) ? oldLines[oldAnchor].words.last : nil
            let newBefore = newLines.indices.contains(newAnchor) ? newLines[newAnchor].words.last : nil
            for run in diff(oldWords.map(\.text), newWords.map(\.text)) {
                let removed = run.old.map { oldWords[$0] }, added = run.new.map { newWords[$0] }
                let oldPrevious = run.oldPosition > 0 ? oldWords[run.oldPosition - 1] : oldBefore
                let newPrevious = run.newPosition > 0 ? newWords[run.newPosition - 1] : newBefore
                let newNext = run.newPosition < newWords.count ? newWords[run.newPosition] : newBefore
                let kind: ComparisonChange.Kind = removed.isEmpty ? .inserted : added.isEmpty ? .deleted : .changed
                let change = ComparisonChange(kind: kind, oldPage: removed.first?.page ?? oldPrevious?.page ?? 0,
                                              newPage: added.first?.page ?? newNext?.page ?? newPrevious?.page ?? 0,
                                              oldText: removed.isEmpty ? nil : removed.map(\.text).joined(separator: " "),
                                              newText: added.isEmpty ? nil : added.map(\.text).joined(separator: " "))
                changes.append(LocatedChange(change: change, oldBoxes: removed.map(\.bounds),
                                             newBoxes: added.isEmpty ? (newNext ?? newPrevious).map { [$0.bounds] } ?? [] : added.map(\.bounds)))
            }
        }
        return changes
    }

    private struct Line {
        var key: String
        var words: [CompareWord]
    }

    private static func lines(_ words: [CompareWord]) -> [Line] {
        var result: [Line] = []
        for word in words {
            if let last = result.last, last.words.last?.line == word.line {
                result[result.count - 1].words.append(word)
                result[result.count - 1].key += " " + word.text
            } else {
                result.append(Line(key: word.text, words: [word]))
            }
        }
        return result
    }

    /// One run of differences: indices removed from `a`, inserted from `b`, and where the run starts in each.
    struct Hunk {
        var old: [Int]
        var new: [Int]
        var oldPosition: Int
        var newPosition: Int
    }

    /// Myers' O(ND) difference of two sequences as runs of edits (common prefix and suffix trimmed first). Past
    /// `limit` edits the middle is reported as one replacement.
    static func diff<T: Equatable>(_ a: [T], _ b: [T], limit: Int = 4000) -> [Hunk] {
        var prefix = 0
        while prefix < a.count, prefix < b.count, a[prefix] == b[prefix] { prefix += 1 }
        var suffix = 0
        while suffix < a.count - prefix, suffix < b.count - prefix, a[a.count - 1 - suffix] == b[b.count - 1 - suffix] { suffix += 1 }
        let n = a.count - prefix - suffix, m = b.count - prefix - suffix
        if n == 0 && m == 0 { return [] }
        if n == 0 || m == 0 {
            return [Hunk(old: Array(prefix..<(prefix + n)), new: Array(prefix..<(prefix + m)), oldPosition: prefix, newPosition: prefix)]
        }
        let maxD = min(n + m, limit)
        let offset = maxD + 1
        var v = [Int](repeating: 0, count: 2 * maxD + 3)
        var trace: [[Int]] = []
        var found = false
        search: for d in 0...maxD {
            trace.append(v)
            for k in stride(from: -d, through: d, by: 2) {
                var x = (k == -d || (k != d && v[offset + k - 1] < v[offset + k + 1])) ? v[offset + k + 1] : v[offset + k - 1] + 1
                var y = x - k
                while x < n, y < m, a[prefix + x] == b[prefix + y] { x += 1; y += 1 }
                v[offset + k] = x
                if x >= n && y >= m { found = true; break search }
            }
        }
        guard found else {
            return [Hunk(old: Array(prefix..<(prefix + n)), new: Array(prefix..<(prefix + m)), oldPosition: prefix, newPosition: prefix)]
        }
        // Walk back through the trace into single edits.
        var edits: [(isDelete: Bool, oldIndex: Int, newIndex: Int)] = []
        var x = n, y = m
        for d in stride(from: trace.count - 1, through: 1, by: -1) {
            let vd = trace[d]
            let k = x - y
            let previousK = (k == -d || (k != d && vd[offset + k - 1] < vd[offset + k + 1])) ? k + 1 : k - 1
            let previousX = vd[offset + previousK], previousY = previousX - previousK
            while x > previousX, y > previousY { x -= 1; y -= 1 }
            if previousK == k + 1 { edits.append((false, x, previousY)) } else { edits.append((true, previousX, y)) }
            x = previousX; y = previousY
        }
        edits.reverse()
        // Group edits that touch into runs.
        var hunks: [Hunk] = []
        for edit in edits {
            let oldAt = prefix + edit.oldIndex, newAt = prefix + edit.newIndex
            if var last = hunks.last, last.oldPosition + last.old.count == oldAt, last.newPosition + last.new.count == newAt {
                if edit.isDelete { last.old.append(oldAt) } else { last.new.append(newAt) }
                hunks[hunks.count - 1] = last
            } else {
                hunks.append(Hunk(old: edit.isDelete ? [oldAt] : [], new: edit.isDelete ? [] : [newAt], oldPosition: oldAt, newPosition: newAt))
            }
        }
        return hunks
    }

    // MARK: Visual differences

    /// Pages whose pictures or drawing differ outside the text, paired by index, with the area that changed.
    static func visualChanges(old: PDFSource, new: PDFSource, oldWords: [CompareWord], newWords: [CompareWord]) throws -> [LocatedChange] {
        let oldDocument = try PDFPages.open(old), newDocument = try PDFPages.open(new)
        let dpi = 36.0, tile = 6
        var changes: [LocatedChange] = []
        for index in 0..<min(oldDocument.numberOfPages, newDocument.numberOfPages) {
            try Task.checkCancellation()
            let oldPage = try PDFPages.page(oldDocument, at: index), newPage = try PDFPages.page(newDocument, at: index)
            let size = PDFPages.displayedSize(newPage)
            guard Int(newPage.rotationAngle) % 360 == 0, Int(oldPage.rotationAngle) % 360 == 0 else { continue }
            guard abs(PDFPages.displayedSize(oldPage).width - size.width) < 1, abs(PDFPages.displayedSize(oldPage).height - size.height) < 1 else {
                changes.append(LocatedChange(change: ComparisonChange(kind: .visual, oldPage: index, newPage: index),
                                             newBoxes: [CGRect(origin: .zero, size: size)]))
                continue
            }
            let a = try gray(Rasterizer.render(oldPage, dpi: dpi, colorSpace: .gray)), b = try gray(Rasterizer.render(newPage, dpi: dpi, colorSpace: .gray))
            guard a.width == b.width, a.height == b.height else { continue }
            let scale = CGFloat(dpi / 72)
            let text = (oldWords.filter { $0.page == index } + newWords.filter { $0.page == index }).map { $0.bounds.insetBy(dx: -3, dy: -3) }
            var changed = CGRect.null
            for ty in stride(from: 0, to: a.height, by: tile) {
                for tx in stride(from: 0, to: a.width, by: tile) {
                    let w = min(tile, a.width - tx), h = min(tile, a.height - ty)
                    var sum = 0
                    for y in ty..<(ty + h) { for x in tx..<(tx + w) { sum += abs(Int(a.pixels[y * a.width + x]) - Int(b.pixels[y * b.width + x])) } }
                    guard sum / max(w * h, 1) > 24 else { continue }
                    // Rows run top-down; page space runs up.
                    let rect = CGRect(x: CGFloat(tx) / scale, y: size.height - CGFloat(ty + h) / scale, width: CGFloat(w) / scale, height: CGFloat(h) / scale)
                    if !text.contains(where: { $0.intersects(rect) }) { changed = changed.union(rect) }
                }
            }
            if !changed.isNull {
                changes.append(LocatedChange(change: ComparisonChange(kind: .visual, oldPage: index, newPage: index), oldBoxes: [changed], newBoxes: [changed]))
            }
        }
        return changes
    }

    private static func gray(_ image: CGImage) throws -> (pixels: [UInt8], width: Int, height: Int) {
        let width = image.width, height = image.height
        var pixels = [UInt8](repeating: 255, count: width * height)
        guard let context = CGContext(data: &pixels, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width,
                                      space: CGColorSpaceCreateDeviceGray(), bitmapInfo: CGImageAlphaInfo.none.rawValue) else {
            throw RenderError.cannotCreateContext
        }
        context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
        return (pixels, width, height)
    }

    // MARK: Report

    /// A PDF: the list of changes, then the newer version's changed pages with the changes marked.
    static func report(_ changes: [LocatedChange], new: PDFSource, oldName: String, newName: String) throws -> Data {
        let document = try PDFPages.open(new)
        let data = NSMutableData()
        var letter = CGRect(x: 0, y: 0, width: 612, height: 792)
        guard let consumer = CGDataConsumer(data: data as CFMutableData), let context = CGContext(consumer: consumer, mediaBox: &letter, nil) else {
            throw RenderError.cannotCreateContext
        }
        let pages = Set(changes.compactMap(\.change.newPage))
        // The list.
        let margin: CGFloat = 54
        var y: CGFloat = 0
        func newPage() { context.beginPDFPage(nil); y = letter.height - margin }
        func write(_ text: String, size: CGFloat, emphasised: Bool = false, gap: CGFloat = 6) {
            let font = CTFontCreateUIFontForLanguage(emphasised ? .emphasizedSystem : .system, size, nil)
                ?? CTFontCreateWithName("Helvetica" as CFString, size, nil)
            let attributed = NSAttributedString(string: text, attributes: [NSAttributedString.Key(kCTFontAttributeName as String): font])
            let setter = CTFramesetterCreateWithAttributedString(attributed)
            let fit = CTFramesetterSuggestFrameSizeWithConstraints(setter, CFRange(), nil, CGSize(width: letter.width - 2 * margin, height: .greatestFiniteMagnitude), nil)
            if y - fit.height < margin { context.endPDFPage(); newPage() }
            let frame = CTFramesetterCreateFrame(setter, CFRange(), CGPath(rect: CGRect(x: margin, y: y - fit.height, width: letter.width - 2 * margin, height: fit.height), transform: nil), nil)
            CTFrameDraw(frame, context)
            y -= fit.height + gap
        }
        newPage()
        write(FixStrings.Compare.reportTitle(old: oldName, new: newName), size: 16, emphasised: true, gap: 4)
        write(FixStrings.Compare.summary(changes: changes.count, pages: pages.count), size: 11, gap: 14)
        for located in changes {
            let change = located.change
            let page = FixStrings.Compare.page((change.newPage ?? change.oldPage ?? 0) + 1)
            write(page + " · " + describe(change), size: 10, gap: 4)
        }
        context.endPDFPage()
        // The changed pages, marked.
        let added = SPColor.highlightGreen.light, removed = SPColor.highlightPink.light, visual = SPColor.highlightBlue.light
        for index in pages.sorted() {
            guard let page = document.page(at: index + 1) else { continue }
            var box = page.getBoxRect(.cropBox)
            context.beginPDFPage([kCGPDFContextMediaBox as String: Data(bytes: &box, count: MemoryLayout<CGRect>.size)] as CFDictionary)
            context.drawPDFPage(page)
            context.saveGState()
            context.translateBy(x: box.minX, y: box.minY)
            for located in changes where located.change.newPage == index {
                let hex = located.change.kind == .visual ? visual : located.change.kind == .deleted ? removed : added
                context.setFillColor(color(hex, alpha: 0.4))
                for rect in located.newBoxes {
                    if located.change.kind == .deleted {
                        context.fill(CGRect(x: rect.maxX + 1, y: rect.minY, width: 2.5, height: rect.height))
                    } else {
                        context.fill(rect.insetBy(dx: -1, dy: -1))
                    }
                }
            }
            context.restoreGState()
            context.endPDFPage()
        }
        context.closePDF()
        return data as Data
    }

    /// "#RRGGBB" as a CGColor (sRGB).
    static func color(_ hex: String, alpha: CGFloat) -> CGColor {
        let value = Int(hex.dropFirst().prefix(6), radix: 16) ?? 0
        return CGColor(srgbRed: CGFloat(value >> 16 & 0xFF) / 255, green: CGFloat(value >> 8 & 0xFF) / 255, blue: CGFloat(value & 0xFF) / 255, alpha: alpha)
    }

    /// One change in words: "Changed “cat” to “dog”".
    static func describe(_ change: ComparisonChange) -> String {
        func clip(_ text: String?) -> String {
            let text = text ?? ""
            return text.count > 80 ? String(text.prefix(79)) + "…" : text
        }
        switch change.kind {
        case .inserted: return FixStrings.Compare.added(clip(change.newText))
        case .deleted: return FixStrings.Compare.removed(clip(change.oldText))
        case .changed: return FixStrings.Compare.changed(clip(change.oldText), clip(change.newText))
        case .visual: return FixStrings.Compare.visual
        }
    }
}
