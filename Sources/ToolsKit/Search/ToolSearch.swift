import Foundation
import SuperPDFCore

/// Live search over the tiles (ux §4): plain names first, then the jargon synonyms, then the hints, with a little typo
/// tolerance. Pure and allocation-light so it runs on every keystroke; the first result is what Return opens.
public enum ToolSearch {
    /// The tiles matching `query`, best first; ties keep the higher `boost` (frecency), then catalogue order. An empty
    /// query gives `tiles` unchanged.
    public static func rank(_ query: String, in tiles: [ToolTile] = ToolCatalog.tiles,
                            boost: (ToolID) -> Double = { _ in 0 }) -> [ToolTile] {
        let q = Query(query)
        guard !q.tokens.isEmpty else { return tiles }
        let scored: [(tile: ToolTile, score: Double, boost: Double, order: Int)] = tiles.enumerated().compactMap { order, tile in
            let s = score(q, index[tile.id] ?? Entry(tile))
            return s > 0 ? (tile, s, boost(tile.id), order) : nil
        }
        return scored.sorted {
            if $0.score != $1.score { return $0.score > $1.score }
            if $0.boost != $1.boost { return $0.boost > $1.boost }
            return $0.order < $1.order
        }.map(\.tile)
    }

    /// Lower-case, accents and curly quotes folded, "→" read as "to" and "&" as "and", other punctuation (but "/" and
    /// "-") as spaces, whitespace collapsed: "Images → PDF" → "images to pdf".
    public static func normalize(_ text: String) -> String {
        let folded = text.folding(options: [.caseInsensitive, .diacriticInsensitive, .widthInsensitive], locale: nil)
        var out = ""
        out.reserveCapacity(folded.count)
        for ch in folded {
            switch ch {
            case "→": out += " to "
            case "&": out += " and "
            case "’", "‘", "'", "“", "”", "\"", "…": continue
            case "/", "-": out.append(ch)
            default: out.append(ch.isLetter || ch.isNumber ? ch : " ")
            }
        }
        return out.split(separator: " ").joined(separator: " ")
    }

    // MARK: - Scoring

    /// Words that need not match on their own: "pdf to word" finds To Word, "a form" finds Make a form.
    private static let optional: Set<String> = ["a", "an", "the", "to", "of", "in", "into", "my", "this", "pdf", "pdfs", "file", "files",
                                                "and", "for", "with", "from", "page", "pages"]

    private struct Query {
        let text: String
        let tokens: [String]
        let pairs: [String]

        init(_ raw: String) {
            text = ToolSearch.normalize(raw)
            tokens = text.split(separator: " ").map(String.init)
            pairs = zip(tokens, tokens.dropFirst()).map { "\($0) \($1)" }
        }
    }

    /// One tile's searchable text, normalised once.
    private struct Entry {
        let name: String
        let nameWords: [String]
        let synonyms: [String]
        let synonymWords: [String]
        let hint: String
        let hintWords: [String]
        /// Name and synonyms joined, for two-word phrases ("to pdf", "black out").
        let phrases: String

        init(_ tile: ToolTile) {
            name = ToolSearch.normalize(tile.name)
            nameWords = ToolSearch.words(name)
            synonyms = tile.synonyms.map(ToolSearch.normalize)
            synonymWords = synonyms.flatMap(ToolSearch.words)
            hint = ToolSearch.normalize(tile.hint)
            hintWords = ToolSearch.words(hint)
            phrases = ([name] + synonyms).joined(separator: " | ")
        }
    }

    /// Words, plus the parts of "pdf/a" and "e-sign".
    private static func words(_ text: String) -> [String] {
        let words = text.split(separator: " ").map(String.init)
        return words + words.filter { $0.contains("/") || $0.contains("-") }
            .flatMap { $0.split(whereSeparator: { $0 == "/" || $0 == "-" }).map(String.init) }
    }

    private static let index = Dictionary(ToolCatalog.tiles.map { ($0.id, Entry($0)) }, uniquingKeysWith: { first, _ in first })

    private static func score(_ q: Query, _ e: Entry) -> Double {
        // The whole query as one phrase.
        let whole = termScore(q.text, e)
        // Every word that matters must match somewhere.
        var total = 0.0, counted = 0
        for token in q.tokens {
            let s = termScore(token, e)
            if s == 0 && !optional.contains(token) { total = 0; counted = -1; break }
            if s > 0 || !optional.contains(token) { total += s; counted += 1 }
        }
        let byWords = counted > 0 ? total / Double(counted) : 0
        guard whole > 0 || byWords > 0 else { return 0 }
        // Word order counts: "word to pdf" is Any file → PDF, "pdf to word" is To Word.
        let phraseBonus = Double(q.pairs.filter { e.phrases.contains($0) }.count) * 500
        return max(whole, byWords) + phraseBonus
    }

    /// How well one term (a word or the whole query) matches a tile.
    private static func termScore(_ t: String, _ e: Entry) -> Double {
        if e.name == t { return 1000 }
        if e.name.hasPrefix(t) { return 900 }
        if e.synonyms.contains(t) { return 850 }
        if e.nameWords.contains(where: { $0.hasPrefix(t) }) { return 800 }
        if e.synonyms.contains(where: { $0.hasPrefix(t) }) { return 700 }
        if e.synonymWords.contains(where: { $0.hasPrefix(t) }) { return 650 }
        if t.count >= 3 && e.name.contains(t) { return 600 }
        if t.count >= 3 && e.synonyms.contains(where: { $0.contains(t) }) { return 500 }
        if t.count >= 2 && e.hintWords.contains(where: { $0.hasPrefix(t) }) { return 400 }
        if t.count >= 4 && e.hint.contains(t) { return 300 }
        if t.count >= 4 && !t.contains(" ") {
            let allowed = t.count >= 8 ? 2 : 1
            if (e.nameWords + e.synonymWords).contains(where: { abs($0.count - t.count) <= allowed && distance($0, t, limit: allowed) <= allowed }) {
                return 200
            }
        }
        return 0
    }

    /// Optimal string alignment distance (a swap counts as one edit), stopping once it passes `limit`.
    static func distance(_ a: String, _ b: String, limit: Int) -> Int {
        let a = Array(a), b = Array(b)
        if a.isEmpty || b.isEmpty { return max(a.count, b.count) }
        var previous2 = [Int](repeating: 0, count: b.count + 1)
        var previous = Array(0...b.count)
        var current = [Int](repeating: 0, count: b.count + 1)
        for i in 1...a.count {
            current[0] = i
            var rowMin = current[0]
            for j in 1...b.count {
                let cost = a[i - 1] == b[j - 1] ? 0 : 1
                var value = min(previous[j] + 1, current[j - 1] + 1, previous[j - 1] + cost)
                if i > 1, j > 1, a[i - 1] == b[j - 2], a[i - 2] == b[j - 1] { value = min(value, previous2[j - 2] + 1) }
                current[j] = value
                rowMin = min(rowMin, value)
            }
            if rowMin > limit { return limit + 1 }
            (previous2, previous, current) = (previous, current, previous2)
        }
        return previous[b.count]
    }
}
