import Foundation

// Content edits (EditKit: `Services.edit`; features §1.5). Decorations (headers and footers, page numbers, Bates,
// watermarks, backgrounds) are drawn into content streams as tagged XObjects so they can be found, updated and removed
// (features #64–#67). PagesKit's "Number pages" draws through `apply(.pageNumbers)`.

/// A spot on the page: a 3×3 grid read row by row from the top left (0 top-left … 8 bottom-right).
public enum PagePosition: Int, Codable, CaseIterable, Sendable {
    case topLeft, topCenter, topRight, middleLeft, center, middleRight, bottomLeft, bottomCenter, bottomRight
}

/// Text style of a decoration.
public struct DecorationStyle: Codable, Hashable, Sendable {
    public var fontName: String
    public var fontSize: Double
    /// "#RRGGBB".
    public var color: String

    public init(fontName: String = "Helvetica", fontSize: Double = 10, color: String = "#000000") {
        self.fontName = fontName; self.fontSize = fontSize; self.color = color
    }
}

/// A field of the headers and footers grid: literal text and tokens (ux §5.3 "+" menu).
public enum HeaderFooterPart: Codable, Hashable, Sendable {
    case text(String)
    case pageNumber, pageCount, date, title, fileName, author, batesNumber
}

public struct HeaderFooter: Codable, Hashable, Sendable {
    /// Six fields: top left/centre/right, bottom left/centre/right (`PagePosition` top and bottom rows).
    public var fields: [PagePosition: [HeaderFooterPart]]
    public var style: DecorationStyle
    /// Distance from the page edges, points.
    public var margins: Double
    /// Scale the page content down so the decoration doesn't overlap it.
    public var shrinkPage: Bool
    /// ICU date pattern for the date token.
    public var dateFormat: String
    /// The first page's number.
    public var startNumber: Int

    public init(fields: [PagePosition: [HeaderFooterPart]], style: DecorationStyle = DecorationStyle(), margins: Double = 36,
                shrinkPage: Bool = false, dateFormat: String = "d MMMM yyyy", startNumber: Int = 1) {
        self.fields = fields; self.style = style; self.margins = margins; self.shrinkPage = shrinkPage
        self.dateFormat = dateFormat; self.startNumber = startNumber
    }
}

/// Page number styles of ux §5.3 "Number pages".
public enum PageNumberStyle: String, Codable, CaseIterable, Sendable {
    /// "1"
    case plain
    /// "Page 1"
    case page
    /// "Page 1 of 12"
    case pageOfTotal
    /// "– 1 –"
    case dashed
    /// "i, ii"
    case roman
    /// "A-1"
    case prefixed

    /// The printed text for page `number` of `total` (`prefix` is the "A" of "A-1").
    public func text(_ number: Int, of total: Int, prefix: String = "A") -> String {
        switch self {
        case .plain: "\(number)"
        case .page: "Page \(number)"
        case .pageOfTotal: "Page \(number) of \(total)"
        case .dashed: "– \(number) –"
        case .roman: PageNumberStyle.roman(number)
        case .prefixed: "\(prefix)-\(number)"
        }
    }

    /// Lower-case roman numerals ("iv"); the decimal number beyond 3999.
    public static func roman(_ number: Int) -> String {
        guard (1...3999).contains(number) else { return "\(number)" }
        let table: [(Int, String)] = [(1000, "m"), (900, "cm"), (500, "d"), (400, "cd"), (100, "c"), (90, "xc"), (50, "l"),
                                      (40, "xl"), (10, "x"), (9, "ix"), (5, "v"), (4, "iv"), (1, "i")]
        var rest = number, out = ""
        for (value, numeral) in table { while rest >= value { out += numeral; rest -= value } }
        return out
    }
}

public struct PageNumbering: Codable, Hashable, Sendable {
    /// One of the six top/bottom spots.
    public var position: PagePosition
    public var style: PageNumberStyle
    public var startAt: Int
    /// Leave the first N pages unnumbered (a cover).
    public var skipFirst: Int
    public var text: DecorationStyle

    public init(position: PagePosition = .bottomCenter, style: PageNumberStyle = .plain, startAt: Int = 1, skipFirst: Int = 0,
                text: DecorationStyle = DecorationStyle()) {
        self.position = position; self.style = style; self.startAt = startAt; self.skipFirst = skipFirst; self.text = text
    }
}

public struct BatesNumbering: Codable, Hashable, Sendable {
    public var prefix: String
    public var suffix: String
    public var start: Int
    /// Zero-padded width (6 by default, features #65).
    public var digits: Int
    public var position: PagePosition
    public var style: DecorationStyle

    public init(prefix: String = "", suffix: String = "", start: Int = 1, digits: Int = 6, position: PagePosition = .bottomRight,
                style: DecorationStyle = DecorationStyle()) {
        self.prefix = prefix; self.suffix = suffix; self.start = start; self.digits = digits; self.position = position; self.style = style
    }

    /// "ABC000042XYZ".
    public func label(_ number: Int) -> String {
        let digits = String(number)
        return prefix + String(repeating: "0", count: max(0, self.digits - digits.count)) + digits + suffix
    }
}

/// What a watermark or background is made of.
public enum DecorationContent: Codable, Hashable, Sendable {
    case text(String, DecorationStyle)
    /// An image or the first page of a PDF.
    case file(URL)
    /// Backgrounds only.
    case color(String)
}

public struct Watermark: Codable, Hashable, Sendable {
    public enum Layer: String, Codable, Sendable { case behind, over }
    public enum Visibility: String, Codable, Sendable { case always, printOnly, screenOnly }

    public var content: DecorationContent
    /// 0…1.
    public var opacity: Double
    /// Degrees counter-clockwise; 45 is "Diagonal", 0 "Straight".
    public var rotation: Double
    public var position: PagePosition
    /// Relative to the page width (1 = full width).
    public var scale: Double
    public var layer: Layer
    public var visibility: Visibility

    public init(content: DecorationContent, opacity: Double = 0.3, rotation: Double = 45, position: PagePosition = .center,
                scale: Double = 0.5, layer: Layer = .over, visibility: Visibility = .always) {
        self.content = content; self.opacity = opacity; self.rotation = rotation; self.position = position; self.scale = scale
        self.layer = layer; self.visibility = visibility
    }
}

/// Everything EditKit stamps across pages.
public enum Decoration: Codable, Hashable, Sendable {
    case headerFooter(HeaderFooter)
    case pageNumbers(PageNumbering)
    case bates(BatesNumbering)
    case watermark(Watermark)
    /// Backgrounds are watermarks drawn behind the content (features #67).
    case background(Watermark)

    public var kind: DecorationKind {
        switch self {
        case .headerFooter: .headerFooter
        case .pageNumbers: .pageNumbers
        case .bates: .bates
        case .watermark: .watermark
        case .background: .background
        }
    }
}

public enum DecorationKind: String, Codable, CaseIterable, Sendable {
    case headerFooter, pageNumbers, bates, watermark, background
}

public struct FindReplaceOptions: Codable, Hashable, Sendable {
    public var matchCase: Bool
    public var wholeWords: Bool

    public init(matchCase: Bool = false, wholeWords: Bool = false) { self.matchCase = matchCase; self.wholeWords = wholeWords }
}

/// What a find-and-replace did; `notFitting` replacements were skipped with a warning (features #72).
public struct ReplaceReport: Hashable, Sendable {
    public var replaced: Int
    public var notFitting: Int
    /// Fonts not on this Mac and their stand-ins (ux §7.4 "Fonts missing").
    public var substitutedFonts: [String: String]

    public init(replaced: Int, notFitting: Int = 0, substitutedFonts: [String: String] = [:]) {
        self.replaced = replaced; self.notFitting = notFitting; self.substitutedFonts = substitutedFonts
    }
}

/// Content-stream editing and decorations (EditKit). The interactive text and image editing is EditKit's own mode
/// panel; these are what other modules and the assistant call.
@MainActor
public protocol ContentEditing: AnyObject {
    /// Stamps a decoration on `pages`; replaces our existing one of the same kind when `replacing`.
    func apply(_ decoration: Decoration, to pages: [Int], in document: DocumentHandle, replacing: Bool) async throws -> UndoGroup
    /// Our decorations already in the document ("Remove watermark" shows when one exists).
    func decorations(in document: DocumentHandle) -> [DecorationKind]
    func remove(_ kind: DecorationKind, from document: DocumentHandle) async throws -> UndoGroup
    /// Replaces text everywhere in `pages` with the same font (features #72).
    func replaceText(_ find: String, with replacement: String, options: FindReplaceOptions, pages: [Int],
                     in document: DocumentHandle) async throws -> (report: ReplaceReport, undo: UndoGroup)
    /// Document JavaScript and actions, listed so the user can remove them; never run (features #74).
    func scripts(in document: DocumentHandle) async throws -> [String]
    func removeScripts(from document: DocumentHandle) async throws -> UndoGroup
}
