import AppKit
import SuperPDFCore

/// Word, OpenDocument text, RTF, RTFD, plain text and WordML → PDF (features #35, #38, #40): macOS reads them into an
/// attributed string (the same importers `textutil` uses) and TextKit lays the text out on pages. Good for letters,
/// reports and theses; text boxes, floating pictures, footnote layout and tracked changes are lost (features §3.2).
enum AttributedTextImporter {
    static func convert(_ input: URL, to output: URL, options: ImportOptions) throws -> ImportReport {
        let text = try read(input)
        guard text.length > 0 else { throw ComposeError.nothingToConvert }
        try TextPaginator.write(text, to: output, paper: options.textPaper, margins: CGFloat(options.margins), title: String.baseName(input))
        return ImportReport()
    }

    static func read(_ url: URL) throws -> NSAttributedString {
        let ext = url.pathExtension.lowercased()
        if ext == "txt" { return plainText(try decodeText(at: url)) }
        let type: NSAttributedString.DocumentType? = switch ext {
        case "docx": .officeOpenXML
        case "doc": .docFormat
        case "odt": .openDocument
        case "rtf": .rtf
        case "rtfd": .rtfd
        case "wordml": .wordML
        default: nil
        }
        var options: [NSAttributedString.DocumentReadingOptionKey: Any] = [:]
        if let type { options[.documentType] = type }
        let text = try NSMutableAttributedString(url: url, options: options, documentAttributes: nil)
        return readable(text)
    }

    /// Plain text in a readable face: the system font at 11 pt, or monospaced when the text looks like code or a
    /// table aligned with spaces.
    static func plainText(_ string: String, monospaced: Bool? = nil) -> NSAttributedString {
        let mono = monospaced ?? looksMonospaced(string)
        let font = mono ? NSFont.monospacedSystemFont(ofSize: 9.5, weight: .regular) : NSFont.systemFont(ofSize: 11)
        let style = NSMutableParagraphStyle()
        style.lineHeightMultiple = mono ? 1.05 : 1.15
        style.paragraphSpacing = mono ? 0 : 4
        return NSAttributedString(string: string, attributes: [.font: font, .foregroundColor: NSColor.black, .paragraphStyle: style])
    }

    /// Text files decoded by their byte-order mark, as UTF-8, or as Windows Latin 1 (never fails).
    static func decodeText(at url: URL) throws -> String {
        let data = try Data(contentsOf: url)
        return decodeText(data)
    }

    static func decodeText(_ data: Data) -> String {
        if data.starts(with: [0xEF, 0xBB, 0xBF]) { return String(decoding: data.dropFirst(3), as: UTF8.self) }
        if data.starts(with: [0xFF, 0xFE]) || data.starts(with: [0xFE, 0xFF]), let text = String(data: data, encoding: .utf16) { return text }
        if let text = String(data: data, encoding: .utf8) { return text }
        return String(data: data, encoding: .windowsCP1252) ?? String(data: data, encoding: .macOSRoman) ?? String(decoding: data, as: UTF8.self)
    }

    /// Source code and space-aligned tables: many lines with runs of spaces or tabs inside, or braces and semicolons.
    private static func looksMonospaced(_ text: String) -> Bool {
        let lines = text.split(separator: "\n", omittingEmptySubsequences: true).prefix(200)
        guard !lines.isEmpty else { return false }
        let aligned = lines.filter { $0.contains("    ") || $0.contains("\t") || $0.hasSuffix(";") || $0.hasSuffix("{") || $0.hasSuffix("}") }
        return Double(aligned.count) / Double(lines.count) > 0.4
    }

    /// Imported text keeps its own look, except that colours meant for a dark screen and missing colours become ink on
    /// paper: text without a colour is black, and a white page background is dropped.
    private static func readable(_ text: NSMutableAttributedString) -> NSAttributedString {
        let whole = NSRange(location: 0, length: text.length)
        text.enumerateAttribute(.foregroundColor, in: whole) { value, range, _ in
            if value == nil { text.addAttribute(.foregroundColor, value: NSColor.black, range: range) }
        }
        text.enumerateAttribute(.backgroundColor, in: whole) { value, range, _ in
            if let color = (value as? NSColor)?.usingColorSpace(.sRGB), color.redComponent > 0.98, color.greenComponent > 0.98,
               color.blueComponent > 0.98 {
                text.removeAttribute(.backgroundColor, range: range)
            }
        }
        return text
    }
}
