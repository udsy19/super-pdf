import Foundation

// Page labels (ISO 32000-2 §12.4.2): the catalog's /PageLabels number tree as ranges, and the label each page shows.

/// A run of pages labelled the same way, from `startPage` (0-based) to the next range.
public struct PDFPageLabelRange: Hashable, Sendable {
    public enum Style: String, CaseIterable, Sendable {
        /// "1, 2, 3"
        case decimal = "D"
        /// "I, II, III"
        case upperRoman = "R"
        /// "i, ii, iii"
        case lowerRoman = "r"
        /// "A … Z, AA … ZZ"
        case upperLetters = "A"
        /// "a … z, aa … zz"
        case lowerLetters = "a"
    }

    public var startPage: Int
    /// Nil: the prefix alone.
    public var style: Style?
    public var prefix: String
    /// The number of the range's first page (≥ 1).
    public var firstNumber: Int

    public init(startPage: Int, style: Style? = .decimal, prefix: String = "", firstNumber: Int = 1) {
        self.startPage = startPage; self.style = style; self.prefix = prefix; self.firstNumber = firstNumber
    }

    /// The label of page `index` (which must be in this range).
    public func label(forPage index: Int) -> String {
        let n = firstNumber + (index - startPage)
        guard let style else { return prefix }
        switch style {
        case .decimal: return prefix + String(n)
        case .upperRoman: return prefix + Self.roman(n)
        case .lowerRoman: return prefix + Self.roman(n).lowercased()
        case .upperLetters: return prefix + Self.letters(n)
        case .lowerLetters: return prefix + Self.letters(n).lowercased()
        }
    }

    static func roman(_ number: Int) -> String {
        guard number > 0 else { return String(number) }
        let table: [(Int, String)] = [(1000, "M"), (900, "CM"), (500, "D"), (400, "CD"), (100, "C"), (90, "XC"), (50, "L"),
                                      (40, "XL"), (10, "X"), (9, "IX"), (5, "V"), (4, "IV"), (1, "I")]
        var n = number, out = ""
        for (value, symbol) in table { while n >= value { out += symbol; n -= value } }
        return out
    }

    /// A…Z, then AA…ZZ, AAA… (the letter repeats, §12.4.2).
    static func letters(_ number: Int) -> String {
        guard number > 0 else { return String(number) }
        let letter = Character(Unicode.Scalar(UInt8(65 + (number - 1) % 26)))
        return String(repeating: letter, count: (number - 1) / 26 + 1)
    }
}

extension PDFModel {
    /// The label ranges, sorted by start page (empty when the file has none).
    public func pageLabels() -> [PDFPageLabelRange] {
        guard let tree = root["PageLabels"] else { return [] }
        return PDFNumberTree.entries(of: tree).map { entry in
            let d = entry.value
            return PDFPageLabelRange(startPage: entry.key,
                                     style: d["S"]?.name.flatMap(PDFPageLabelRange.Style.init(rawValue:)),
                                     prefix: d["P"]?.text ?? "",
                                     firstNumber: max(d["St"]?.int ?? 1, 1))
        }.sorted { $0.startPage < $1.startPage }
    }

    /// Replaces the label ranges (an empty list removes them). A first range that does not start at page 0 gets a
    /// decimal range before it, as the number tree must cover page 0.
    public func setPageLabels(_ ranges: [PDFPageLabelRange]) {
        guard !ranges.isEmpty else { root.remove("PageLabels"); return }
        var sorted = ranges.sorted { $0.startPage < $1.startPage }
        if sorted[0].startPage > 0 { sorted.insert(PDFPageLabelRange(startPage: 0), at: 0) }
        let entries = sorted.map { range -> (key: Int, value: PDFObject) in
            var d: [String: PDFValue] = ["Type": .name("PageLabel")]
            if let style = range.style { d["S"] = .name(style.rawValue) }
            if !range.prefix.isEmpty { d["P"] = .text(range.prefix) }
            if range.firstNumber != 1 { d["St"] = .integer(range.firstNumber) }
            return (range.startPage, make(.dictionary(d)))
        }
        root.set("PageLabels", PDFNumberTree.make(in: self, entries: entries))
    }

    /// The label page `index` shows; nil when the file has no labels.
    public func pageLabel(at index: Int) -> String? {
        pageLabels().last { $0.startPage <= index }?.label(forPage: index)
    }
}
