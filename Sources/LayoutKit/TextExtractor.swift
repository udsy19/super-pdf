import AppKit
import PDFKit
import SuperPDFCore

/// Positioned words from PDFKit (features §2.4: "PDFKit provides characters with bounds"). PDFKit objects live on the
/// main actor (ARCHITECTURE "Rules"), so this is the one main-actor step of an analysis; it reads the page's string and
/// attributed string once and asks for one selection per word, which keeps a dense page to a few milliseconds.
@MainActor
enum TextExtractor {
    /// Words in page space (origin at the crop box's lower-left corner, unrotated).
    static func words(on page: PDFPage) -> [LayoutWord] {
        guard let string = page.string, !string.isEmpty else { return [] }
        let text = string as NSString
        let attributed = page.attributedString
        let crop = page.bounds(for: .cropBox)
        let whitespace = CharacterSet.whitespacesAndNewlines
        var words: [LayoutWord] = []
        var start: Int?
        func flush(_ end: Int) {
            guard let wordStart = start else { return }
            start = nil
            let range = NSRange(location: wordStart, length: end - wordStart)
            guard let selection = page.selection(for: range) else { return }
            var bounds = selection.bounds(for: page)
            guard bounds.width > 0, bounds.height > 0, bounds.width < 10_000 else { return }
            bounds.origin.x -= crop.minX; bounds.origin.y -= crop.minY
            var word = LayoutWord(text: text.substring(with: range), bounds: bounds)
            if let attributed, attributed.length >= range.location + 1 {
                let attributes = attributed.attributes(at: range.location, effectiveRange: nil)
                if let font = attributes[.font] as? NSFont {
                    word.fontName = font.fontName
                    word.fontSize = font.pointSize
                    let traits = font.fontDescriptor.symbolicTraits
                    let name = font.fontName.lowercased()
                    word.isBold = traits.contains(.bold) || name.contains("bold") || name.contains("black") || name.contains("heavy") || name.contains("semibold")
                    word.isItalic = traits.contains(.italic) || name.contains("italic") || name.contains("oblique")
                }
                if let color = (attributes[.foregroundColor] as? NSColor)?.usingColorSpace(.sRGB) {
                    word.color = String(format: "#%02X%02X%02X", Int(color.redComponent * 255 + 0.5), Int(color.greenComponent * 255 + 0.5), Int(color.blueComponent * 255 + 0.5))
                }
            }
            words.append(word)
        }
        var index = 0
        while index < text.length {
            let unit = text.character(at: index)
            let isSpace = UnicodeScalar(unit).map { whitespace.contains($0) } ?? false
            if isSpace { flush(index) } else if start == nil { start = index }
            index += 1
        }
        flush(text.length)
        return words
    }
}
