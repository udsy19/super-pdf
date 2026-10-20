import CoreGraphics
import Foundation
import LayoutKit
import PDFKit
import RenderKit
import SuperPDFCore

// Find and mark (features #69, ux §5.3 Black out): text, lists of words, Acrobat's patterns (phone numbers, card
// numbers, social security numbers, emails, dates) plus IBANs, UK National Insurance and Aadhaar numbers, names from
// the address book and custom regular expressions. Text pages are searched in PDFKit's text (main actor); pages
// without text are recognised with Vision first (LayoutKit's recogniser, off the main actor) and searched in its words.
// Matches become one mark per line they cover.

/// The text of one page and where its characters are, from PDFKit or from OCR.
struct PageText {
    var page: Int
    var text: String
    /// The page-space boxes of a range of `text` (UTF-16), one per line it covers.
    var lines: (NSRange) -> [CGRect]
}

enum RedactionFinder {
    // MARK: - Matching

    /// The ranges of `text` (UTF-16) a query matches.
    static func matches(_ query: RedactionQuery, in text: String, names: [String] = []) throws -> [NSRange] {
        let ns = text as NSString
        let full = NSRange(location: 0, length: ns.length)
        switch query {
        case .text(let needle, let wholeWords, let matchCase):
            let trimmed = needle.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else { return [] }
            let escaped = NSRegularExpression.escapedPattern(for: trimmed).replacingOccurrences(of: "\\ ", with: "\\s+")
                .replacingOccurrences(of: " ", with: "\\s+")
            let pattern = wholeWords ? "(?<![\\p{L}\\p{N}])" + escaped + "(?![\\p{L}\\p{N}])" : escaped
            let regex = try NSRegularExpression(pattern: pattern, options: matchCase ? [] : [.caseInsensitive])
            return regex.matches(in: text, range: full).map(\.range)
        case .words(let words):
            return try words.flatMap { try matches(.text($0, wholeWords: true, matchCase: false), in: text) }
                .sorted { $0.location < $1.location }
        case .regularExpression(let pattern):
            guard let regex = try? NSRegularExpression(pattern: pattern, options: []) else { throw ToolError(ProtectStrings.badPattern) }
            return regex.matches(in: text, range: full).map(\.range).filter { $0.length > 0 }
        case .pattern(.contactNames):
            return try matches(.words(names), in: text)
        case .pattern(let kind):
            let regex = try NSRegularExpression(pattern: Patterns.expression(kind), options: [])
            return regex.matches(in: text, range: full).map(\.range).filter { Patterns.isValid(kind, ns.substring(with: $0)) }
        }
    }

    /// Marks for the matches: one per line the match covers.
    static func marks(for ranges: [NSRange], in page: PageText) -> [RedactionMark] {
        let ns = page.text as NSString
        return ranges.flatMap { range in
            let matched = ns.substring(with: range)
            return page.lines(range).filter { $0.width > 0 && $0.height > 0 }.map {
                RedactionMark(page: page.page, rect: $0.insetBy(dx: -0.5, dy: -0.5).integralToTenths, text: matched)
            }
        }
    }

    // MARK: - Page text

    /// PDFKit's text of a page (main actor); nil when the page has no text. Boxes come from a selection of each range:
    /// `characterBounds(at:)` counts characters without the line breaks `string` has, so its indices drift.
    @MainActor
    static func pdfKitText(_ page: PDFPage, index: Int) -> PageText? {
        guard let text = page.string, !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }
        return PageText(page: index, text: text) { range in
            guard let selection = page.selection(for: range) else { return [] }
            return selection.selectionsByLine().map { $0.bounds(for: page) }
        }
    }

    /// The text Vision reads on a page without text (off the main actor), in page space.
    static func recognisedText(_ source: PDFSource, index: Int) throws -> PageText? {
        let document = try PDFPages.open(source)
        let page = try PDFPages.page(document, at: index)
        guard let image = TextRecognizer.image(for: page) else { return nil }
        let crop = page.getBoxRect(.cropBox)
        let lines = try TextRecognizer.recognize(image, pageSize: crop.size, rotation: Int(page.rotationAngle))
        var text = ""
        var boxes: [CGRect?] = []
        for line in lines {
            for word in line.words {
                let box = word.bounds.offsetBy(dx: crop.minX, dy: crop.minY)
                let units = (word.text as NSString).length
                let width = box.width / CGFloat(max(units, 1))
                for k in 0..<units {
                    boxes.append(CGRect(x: box.minX + CGFloat(k) * width, y: box.minY, width: width, height: box.height))
                }
                text += word.text + " "
                boxes.append(nil)
            }
            text += "\n"
            boxes.append(nil)
        }
        guard !text.isEmpty else { return nil }
        return PageText(page: index, text: text) { range in
            // Boxes of the range's characters, a new line where the next box starts back to the left or lower down.
            var result: [CGRect] = []
            var current: CGRect?
            for i in range.location..<min(range.location + range.length, boxes.count) {
                guard let box = boxes[i] else { continue }
                if let line = current, box.minX < line.maxX - 1 || abs(box.midY - line.midY) > line.height * 0.6 {
                    result.append(line); current = nil
                }
                current = current.map { $0.union(box) } ?? box
            }
            if let current { result.append(current) }
            return result
        }
    }
}

private extension CGRect {
    /// Rounded outwards to a tenth of a point, so marks compare and print cleanly.
    var integralToTenths: CGRect {
        let x0 = (minX * 10).rounded(.down) / 10, y0 = (minY * 10).rounded(.down) / 10
        let x1 = (maxX * 10).rounded(.up) / 10, y1 = (maxY * 10).rounded(.up) / 10
        return CGRect(x: x0, y: y0, width: x1 - x0, height: y1 - y0)
    }
}

/// The built-in patterns (features #69) and the checks that keep them from marking look-alikes.
enum Patterns {
    static func expression(_ kind: RedactionPattern) -> String {
        switch kind {
        case .phoneNumbers:
            // +1 (555) 123-4567, 020 7946 0958, 555.123.4567, +91 98765 43210
            return "(?<![\\w+])(?:\\+\\d{1,3}[\\s.-]?)?(?:\\(\\d{1,5}\\)[\\s.-]?)?\\d{2,5}(?:[\\s.-]\\d{2,5}){1,3}(?![\\w])"
        case .emails:
            return "[A-Za-z0-9._%+-]+@[A-Za-z0-9.-]+\\.[A-Za-z]{2,}"
        case .cardNumbers:
            return "(?<!\\d)(?:\\d[ -]?){12,18}\\d(?!\\d)"
        case .socialSecurityNumbers:
            return "(?<!\\d)(?!000|666|9\\d\\d)\\d{3}[- ](?!00)\\d{2}[- ](?!0000)\\d{4}(?!\\d)"
        case .dates:
            let months = "(?:Jan(?:uary)?|Feb(?:ruary)?|Mar(?:ch)?|Apr(?:il)?|May|June?|July?|Aug(?:ust)?|Sep(?:t(?:ember)?)?|Oct(?:ober)?|Nov(?:ember)?|Dec(?:ember)?)"
            return "(?<!\\d)(?:\\d{1,2}[/.-]\\d{1,2}[/.-](?:\\d{4}|\\d{2})|\\d{4}-\\d{2}-\\d{2}|\\d{1,2}(?:st|nd|rd|th)?\\s+\(months)\\.?,?\\s+\\d{4}|\(months)\\.?\\s+\\d{1,2}(?:st|nd|rd|th)?,?\\s+\\d{4})(?!\\d)"
        case .iban:
            return "(?<![A-Z0-9])[A-Z]{2}\\d{2}(?:[ ]?[A-Z0-9]){11,30}(?![A-Z0-9])"
        case .ukNationalInsurance:
            return "(?<![A-Z0-9])(?!BG|GB|NK|KN|TN|NT|ZZ)[A-CEGHJ-PR-TW-Z][A-CEGHJ-NPR-TW-Z] ?\\d{2} ?\\d{2} ?\\d{2} ?[A-D](?![A-Z0-9])"
        case .aadhaar:
            return "(?<!\\d)[2-9]\\d{3}[ -]?\\d{4}[ -]?\\d{4}(?!\\d)"
        case .contactNames:
            return "(?!)"
        }
    }

    static func isValid(_ kind: RedactionPattern, _ match: String) -> Bool {
        let digits = match.filter(\.isNumber)
        switch kind {
        case .phoneNumbers: return (7...15).contains(digits.count)
        case .cardNumbers: return (13...19).contains(digits.count) && luhn(digits)
        case .iban: return ibanChecksum(match.filter { !$0.isWhitespace })
        case .aadhaar: return verhoeff(digits)
        default: return true
        }
    }

    static func luhn(_ digits: String) -> Bool {
        var sum = 0
        for (i, c) in digits.reversed().enumerated() {
            guard var d = c.wholeNumberValue else { return false }
            if i % 2 == 1 { d *= 2; if d > 9 { d -= 9 } }
            sum += d
        }
        return sum % 10 == 0
    }

    static func ibanChecksum(_ iban: String) -> Bool {
        guard iban.count >= 15, iban.count <= 34 else { return false }
        let rearranged = iban.dropFirst(4) + iban.prefix(4)
        var remainder = 0
        for c in rearranged {
            let value: Int
            if let d = c.wholeNumberValue { value = d } else if let a = c.asciiValue, (65...90).contains(a) { value = Int(a) - 55 } else { return false }
            for digit in String(value) { remainder = (remainder * 10 + digit.wholeNumberValue!) % 97 }
        }
        return remainder == 1
    }

    /// Aadhaar's check digit (Verhoeff).
    static func verhoeff(_ digits: String) -> Bool {
        let d: [[Int]] = [[0,1,2,3,4,5,6,7,8,9],[1,2,3,4,0,6,7,8,9,5],[2,3,4,0,1,7,8,9,5,6],[3,4,0,1,2,8,9,5,6,7],[4,0,1,2,3,9,5,6,7,8],
                          [5,9,8,7,6,0,4,3,2,1],[6,5,9,8,7,1,0,4,3,2],[7,6,5,9,8,2,1,0,4,3],[8,7,6,5,9,3,2,1,0,4],[9,8,7,6,5,4,3,2,1,0]]
        let p: [[Int]] = [[0,1,2,3,4,5,6,7,8,9],[1,5,7,6,2,8,3,0,9,4],[5,8,0,3,7,9,6,1,4,2],[8,9,1,6,0,4,3,5,2,7],[9,4,5,3,1,2,6,8,7,0],
                          [4,2,8,6,5,7,3,9,0,1],[2,7,9,3,8,0,6,4,1,5],[7,0,4,6,9,1,3,2,5,8]]
        guard digits.count == 12 else { return false }
        var c = 0
        for (i, ch) in digits.reversed().enumerated() {
            guard let n = ch.wholeNumberValue else { return false }
            c = d[c][p[i % 8][n]]
        }
        return c == 0
    }
}
