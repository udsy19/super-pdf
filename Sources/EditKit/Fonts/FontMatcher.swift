import AppKit
import CoreText
import Foundation

// Which font on this Mac stands in for a PDF font (features #60: "missing fonts substituted with a notice";
// ux §7.4: "The font “Garamond Premier” isn’t on this Mac, so new text uses “Georgia” instead.").

/// What a PDF font dictionary says about its face, for matching.
struct FontFacts: Hashable {
    /// /BaseFont without the subset tag ("ABCDEF+").
    var baseFont: String
    var isSerif: Bool
    var isFixedPitch: Bool
    var isBold: Bool
    var isItalic: Bool
    var isSymbolic: Bool

    /// The family part of a PostScript-style name: "TimesNewRomanPS-BoldMT" → "Times New Roman".
    var familyName: String { FontMatcher.familyName(of: baseFont) }
}

enum FontMatcher {
    /// The system font that matches the PDF font: the same family when installed (traits applied), else a standard face
    /// by its flags. `substituted` is true when the family differs from the PDF's.
    static func match(_ facts: FontFacts, size: CGFloat) -> (font: NSFont, substituted: Bool) {
        let family = facts.familyName
        if let font = installedFont(family: family, bold: facts.isBold, italic: facts.isItalic, size: size) { return (font, false) }
        for (aliases, replacement) in aliasFamilies where aliases.contains(where: { family.lowercased() == $0 }) {
            if let font = installedFont(family: replacement, bold: facts.isBold, italic: facts.isItalic, size: size) { return (font, false) }
        }
        let fallback = facts.isFixedPitch ? "Courier New" : facts.isSerif ? "Georgia" : "Helvetica"
        let font = installedFont(family: fallback, bold: facts.isBold, italic: facts.isItalic, size: size)
            ?? NSFont.systemFont(ofSize: size, weight: facts.isBold ? .bold : .regular)
        return (font, true)
    }

    /// The standard 14 names and their common clones map to the same installed families.
    private static let aliasFamilies: [([String], String)] = [
        (["helvetica", "arial", "arialmt", "helveticaneue", "arial narrow"], "Helvetica"),
        (["times", "times-roman", "timesnewroman", "times new roman", "timesnewromanpsmt", "times roman"], "Times New Roman"),
        (["courier", "couriernew", "courier new", "couriernewpsmt"], "Courier New"),
        (["symbol"], "Symbol"),
        (["zapfdingbats", "dingbats"], "Zapf Dingbats"),
        (["calibri", "segoe ui", "verdana", "tahoma"], "Helvetica"),
        (["cambria", "garamond", "book antiqua", "palatino", "palatino linotype", "georgia"], "Georgia"),
    ]

    /// A font of the family on this Mac with the traits, nil when the family isn't installed.
    static func installedFont(family: String, bold: Bool, italic: Bool, size: CGFloat) -> NSFont? {
        let manager = NSFontManager.shared
        guard manager.availableFontFamilies.contains(where: { $0.caseInsensitiveCompare(family) == .orderedSame })
                || NSFont(name: family, size: size) != nil else { return nil }
        var traits: NSFontTraitMask = []
        if bold { traits.insert(.boldFontMask) }
        if italic { traits.insert(.italicFontMask) }
        if let font = manager.font(withFamily: family, traits: traits, weight: bold ? 9 : 5, size: size) { return font }
        return NSFont(name: family, size: size)
    }

    /// "ABCDEF+TimesNewRomanPS-BoldItalicMT" → "Times New Roman".
    static func familyName(of baseFont: String) -> String {
        var name = baseFont
        if name.count > 7, name[name.index(name.startIndex, offsetBy: 6)] == "+" { name = String(name.dropFirst(7)) }
        if let dash = name.firstIndex(of: "-") { name = String(name[..<dash]) }
        if let comma = name.firstIndex(of: ",") { name = String(name[..<comma]) }
        // Style words glued to the family ("ArialBold", "HelveticaBoldOblique"), then foundry suffixes ("PSMT", "MT").
        for style in ["BoldOblique", "BoldItalic", "Oblique", "Italic", "Bold", "Regular"] where name.hasSuffix(style) && name.count > style.count + 2 {
            name = String(name.dropLast(style.count))
        }
        for suffix in ["PSMT", "MT", "PS", "Std", "Pro", "LT"] where name.hasSuffix(suffix) && name.count > suffix.count + 2 {
            name = String(name.dropLast(suffix.count))
            break
        }
        // Split camel case into words: "TimesNewRoman" → "Times New Roman"; keep "SF" style abbreviations together.
        var words = ""
        var previous: Character?
        for ch in name {
            if ch.isUppercase, let p = previous, p.isLowercase || p.isNumber { words.append(" ") }
            words.append(ch)
            previous = ch
        }
        return words.replacingOccurrences(of: "  ", with: " ").trimmingCharacters(in: .whitespaces)
    }

    /// Traits read from a PostScript name: "-Bold", "BoldItalic", ",Bold", "Oblique".
    static func traits(in baseFont: String) -> (bold: Bool, italic: Bool) {
        let lower = baseFont.lowercased()
        let style = lower.split(whereSeparator: { $0 == "-" || $0 == "," }).dropFirst().joined()
        let bold = style.contains("bold") || style.contains("black") || style.contains("heavy") || style.contains("semibold") || lower.hasSuffix("bd") || lower.hasSuffix("bi")
        let italic = style.contains("italic") || style.contains("oblique") || lower.hasSuffix("it") || lower.hasSuffix("bi")
        return (bold, italic)
    }

    /// The name people see for a font ("Times New Roman Bold").
    static func displayName(_ font: NSFont) -> String { font.displayName ?? font.fontName }
}
