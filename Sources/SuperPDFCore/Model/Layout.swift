import CoreGraphics
import Foundation

// The text and layout model LayoutKit produces (features §2.4) and Edit text, PDF → Word/Excel/PowerPoint/HTML/EPUB,
// Reflow, Compare, auto-tagging and form-field detection consume. Codable so golden fixtures can be
// stored as JSON. Coordinates are page space: points, origin at the crop box's lower-left corner, y up, before the
// page's /Rotate is applied.

/// Where a page's text came from.
public enum TextOrigin: String, Codable, Sendable {
    /// The PDF's own text (PDFKit character positions).
    case embedded
    /// Vision OCR of the rendered page.
    case recognized
}

/// One word with its position and style.
public struct LayoutWord: Codable, Hashable, Sendable {
    public var text: String
    public var bounds: CGRect
    public var fontName: String?
    public var fontSize: Double
    public var isBold: Bool
    public var isItalic: Bool
    /// "#RRGGBB" fill colour, when known.
    public var color: String?
    /// OCR confidence 0…1; 1 for embedded text.
    public var confidence: Double

    public init(text: String, bounds: CGRect, fontName: String? = nil, fontSize: Double = 0, isBold: Bool = false, isItalic: Bool = false,
                color: String? = nil, confidence: Double = 1) {
        self.text = text; self.bounds = bounds; self.fontName = fontName; self.fontSize = fontSize; self.isBold = isBold
        self.isItalic = isItalic; self.color = color; self.confidence = confidence
    }
}

public struct LayoutLine: Codable, Hashable, Sendable {
    public var words: [LayoutWord]
    public var bounds: CGRect
    /// The baseline's y in page space.
    public var baseline: Double

    public init(words: [LayoutWord], bounds: CGRect, baseline: Double) {
        self.words = words; self.bounds = bounds; self.baseline = baseline
    }

    public var text: String { words.map(\.text).joined(separator: " ") }
}

/// What a block of lines is.
public enum LayoutBlockKind: Codable, Hashable, Sendable {
    case paragraph
    /// Level 1 is the largest heading on the document.
    case heading(level: Int)
    /// A list item at an indent level, with its bullet or number as printed ("•", "3.", "(b)").
    case listItem(level: Int, marker: String)
    case caption
    /// Running headers, footers and page numbers: excluded from the reading order.
    case header, footer, pageNumber
}

public struct LayoutBlock: Codable, Hashable, Identifiable, Sendable {
    public var id: Int
    public var kind: LayoutBlockKind
    public var bounds: CGRect
    public var lines: [LayoutLine]
    /// 0-based column on the page.
    public var column: Int

    public init(id: Int, kind: LayoutBlockKind, bounds: CGRect, lines: [LayoutLine], column: Int = 0) {
        self.id = id; self.kind = kind; self.bounds = bounds; self.lines = lines; self.column = column
    }

    public var text: String { lines.map(\.text).joined(separator: "\n") }
}

public struct LayoutTableCell: Codable, Hashable, Sendable {
    public var row: Int
    public var column: Int
    public var rowSpan: Int
    public var columnSpan: Int
    public var bounds: CGRect
    public var text: String

    public init(row: Int, column: Int, rowSpan: Int = 1, columnSpan: Int = 1, bounds: CGRect, text: String) {
        self.row = row; self.column = column; self.rowSpan = rowSpan; self.columnSpan = columnSpan; self.bounds = bounds; self.text = text
    }
}

/// A table found from ruling lines and alignment grids.
public struct LayoutTable: Codable, Hashable, Identifiable, Sendable {
    public var id: Int
    public var bounds: CGRect
    public var rowCount: Int
    public var columnCount: Int
    public var cells: [LayoutTableCell]
    /// The first row repeats as a header (and on later pages).
    public var hasHeaderRow: Bool

    public init(id: Int, bounds: CGRect, rowCount: Int, columnCount: Int, cells: [LayoutTableCell], hasHeaderRow: Bool = false) {
        self.id = id; self.bounds = bounds; self.rowCount = rowCount; self.columnCount = columnCount; self.cells = cells
        self.hasHeaderRow = hasHeaderRow
    }
}

/// An image XObject or a cluster of vector drawing.
public struct LayoutFigure: Codable, Hashable, Identifiable, Sendable {
    public enum Kind: String, Codable, Sendable { case image, vector }

    public var id: Int
    public var kind: Kind
    public var bounds: CGRect
    /// The caption block, when one sits next to it.
    public var captionBlockID: Int?

    public init(id: Int, kind: Kind, bounds: CGRect, captionBlockID: Int? = nil) {
        self.id = id; self.kind = kind; self.bounds = bounds; self.captionBlockID = captionBlockID
    }
}

/// One element in reading order.
public enum LayoutElement: Codable, Hashable, Sendable {
    case block(Int)
    case table(Int)
    case figure(Int)
}

public struct LayoutPage: Codable, Hashable, Sendable {
    /// 0-based page index.
    public var index: Int
    /// The crop box size.
    public var size: CGSize
    /// The page's /Rotate (0, 90, 180, 270).
    public var rotation: Int
    public var origin: TextOrigin
    public var blocks: [LayoutBlock]
    public var tables: [LayoutTable]
    public var figures: [LayoutFigure]
    /// Column-aware, top-left to bottom-right, headers and footers excluded.
    public var readingOrder: [LayoutElement]

    public init(index: Int, size: CGSize, rotation: Int = 0, origin: TextOrigin = .embedded, blocks: [LayoutBlock] = [],
                tables: [LayoutTable] = [], figures: [LayoutFigure] = [], readingOrder: [LayoutElement] = []) {
        self.index = index; self.size = size; self.rotation = rotation; self.origin = origin; self.blocks = blocks
        self.tables = tables; self.figures = figures; self.readingOrder = readingOrder
    }

    /// The page's text in reading order, blocks separated by blank lines (reflow, PDF → text, compare).
    public var text: String {
        readingOrder.compactMap { element -> String? in
            switch element {
            case .block(let id): blocks.first { $0.id == id }?.text
            case .table(let id): tables.first { $0.id == id }.map { table in
                (0..<table.rowCount).map { row in
                    table.cells.filter { $0.row == row }.sorted { $0.column < $1.column }.map(\.text).joined(separator: "\t")
                }.joined(separator: "\n")
            }
            case .figure: nil
            }
        }.joined(separator: "\n\n")
    }
}

public struct LayoutDocument: Codable, Hashable, Sendable {
    public var pages: [LayoutPage]

    public init(pages: [LayoutPage]) { self.pages = pages }
}

/// When LayoutKit runs Vision on a page before analysing it (features §2.4: scanned pages go through Vision first).
public enum RecognitionPolicy: String, Codable, Sendable {
    case never, whenPageHasNoText, always
}

public struct LayoutOptions: Codable, Hashable, Sendable {
    public var recognition: RecognitionPolicy
    /// BCP-47 codes for OCR; empty means automatic.
    public var languages: [String]
    public var detectTables: Bool
    public var excludeHeadersAndFooters: Bool

    public init(recognition: RecognitionPolicy = .whenPageHasNoText, languages: [String] = [], detectTables: Bool = true,
                excludeHeadersAndFooters: Bool = true) {
        self.recognition = recognition; self.languages = languages; self.detectTables = detectTables
        self.excludeHeadersAndFooters = excludeHeadersAndFooters
    }
}

/// A line of OCR output (Vision `VNRecognizedTextObservation`, already in page space), the input LayoutKit accepts
/// for scanned pages and FixKit writes as the invisible text layer.
public struct RecognizedLine: Codable, Hashable, Sendable {
    public var text: String
    public var bounds: CGRect
    public var confidence: Double
    /// Per-word boxes, so selection and search land on the right word.
    public var words: [LayoutWord]

    public init(text: String, bounds: CGRect, confidence: Double, words: [LayoutWord] = []) {
        self.text = text; self.bounds = bounds; self.confidence = confidence; self.words = words
    }
}
