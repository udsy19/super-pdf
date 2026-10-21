import AppKit
import SuperPDFCore

// What the markup bar can do (ux §6.4, features #15, #76, #78) and the style new markup gets. Names, colours and the
// menu order are Preview's where Preview has them (its Localizable and UndoStrings tables): the colour menu is Black,
// Gray, Red, Orange, Yellow, Green, Blue, Purple, Pink; text boxes start as "Text"; undo says "Add Rectangle".

/// The Shapes ▾ menu, in Preview's order (its Loupe last), plus the cloud of features #76.
public enum ShapeKind: String, CaseIterable, Codable, Sendable {
    case line, arrow, rectangle, roundedRectangle, oval, speechBubble, star, polygon, cloud, loupe

    public var title: String {
        switch self {
        case .line: "Line"
        case .arrow: "Arrow"
        case .rectangle: "Rectangle"
        case .roundedRectangle: "Rounded Rectangle"
        case .oval: "Oval"
        case .speechBubble: "Speech Bubble"
        case .star: "Star"
        case .polygon: "Polygon"
        case .cloud: "Cloud"
        case .loupe: "Loupe"
        }
    }

    public var symbol: String {
        switch self {
        case .line: "line.diagonal"
        case .arrow: "arrow.up.right"
        case .rectangle: "rectangle"
        case .roundedRectangle: "app"
        case .oval: "oval"
        case .speechBubble: "bubble.left"
        case .star: "star"
        case .polygon: "hexagon"
        case .cloud: "cloud"
        case .loupe: "magnifyingglass.circle"
        }
    }

    /// Lines draw from point to point; the others fill the dragged box.
    var isLinear: Bool { self == .line || self == .arrow }
}

/// Preview's five highlight colours (ux §2.3), in its menu order.
public enum HighlightColor: Int, CaseIterable, Codable, Sendable {
    case yellow, green, blue, pink, purple

    public var token: SPColorToken { SPColor.highlights[rawValue] }
    /// The colour written into the file (the light value, so files look the same in Preview).
    public var color: NSColor { NSColor(hex: token.light) }
    public var title: String { ["Yellow", "Green", "Blue", "Pink", "Purple"][rawValue] }
}

/// What the Highlight button does to selected text.
public enum TextMarkupStyle: Hashable, Codable, Sendable {
    case highlight(HighlightColor)
    case underline
    case strikethrough

    var title: String {
        switch self {
        case .highlight: "Highlight"
        case .underline: "Underline"
        case .strikethrough: "Strikethrough"
        }
    }
}

/// Proofreading marks (features #78).
public enum CorrectionKind: String, CaseIterable, Codable, Sendable {
    case insertText, replaceText, deleteText

    public var title: String {
        switch self {
        case .insertText: "Insert Text"
        case .replaceText: "Replace Text"
        case .deleteText: "Delete Text"
        }
    }
}

/// Stamps of the Stamp ▾ menu: the PDF standard names where there is one, so other readers know them.
public enum StandardStamp: String, CaseIterable, Codable, Sendable {
    case approved = "Approved", notApproved = "NotApproved", draft = "Draft", final = "Final", confidential = "Confidential"
    case forComment = "ForComment", received = "Received", signHere = "SignHere"

    public var title: String {
        switch self {
        case .approved: "Approved"
        case .notApproved: "Not Approved"
        case .draft: "Draft"
        case .final: "Final"
        case .confidential: "Confidential"
        case .forComment: "For Comment"
        case .received: "Received"
        case .signHere: "Sign Here"
        }
    }

    /// The colour of the stamp's frame and words (Acrobat's convention: green yes, red no, blue for information).
    var color: NSColor {
        switch self {
        case .approved, .final, .received: NSColor(hex: "#1E8C3A")
        case .notApproved, .confidential: NSColor(hex: "#C8261E")
        case .draft, .forComment: NSColor(hex: "#1F5FBF")
        case .signHere: NSColor(hex: "#D9822B")
        }
    }
}

/// Measure ▾ (features #15).
public enum MeasureKind: String, CaseIterable, Codable, Sendable {
    case distance, perimeter, area

    public var title: String {
        switch self {
        case .distance: "Distance"
        case .perimeter: "Perimeter"
        case .area: "Area"
        }
    }
}

/// The markup bar's modes. Text selection is PDFView's own behaviour; every other mode makes the page draw markup.
public enum MarkupTool: Hashable, Sendable {
    case textSelection
    /// Preview's Rectangular Selection: drag an area, ⌘C copies it as a picture (features #116).
    case rectangularSelection
    /// Freehand drawing that turns into the shape it looks like.
    case sketch
    /// Freehand drawing kept as drawn.
    case draw
    case shape(ShapeKind)
    case text
    /// Highlight, underline or strike through text, in the bar's text-markup style.
    case highlight
    case note
    case correction(CorrectionKind)
    case stamp(StandardStamp)
    case measure(MeasureKind)
}

/// An sRGB colour as markup stores it.
public struct MarkupColor: Codable, Hashable, Sendable {
    public var red, green, blue, alpha: Double

    public init(red: Double, green: Double, blue: Double, alpha: Double = 1) {
        self.red = red; self.green = green; self.blue = blue; self.alpha = alpha
    }

    public init(_ color: NSColor) {
        let c = color.usingColorSpace(.sRGB) ?? NSColor(srgbRed: 0, green: 0, blue: 0, alpha: 1)
        self.init(red: Double(c.redComponent), green: Double(c.greenComponent), blue: Double(c.blueComponent), alpha: Double(c.alphaComponent))
    }

    public init(hex: String) { self.init(NSColor(hex: hex)) }

    public var nsColor: NSColor { NSColor(srgbRed: red, green: green, blue: blue, alpha: alpha) }
    public var isClear: Bool { alpha < 0.01 }
    /// "#RRGGBB" (XFDF's form).
    public var hexRGB: String { String(nsColor.hexRGBA.prefix(7)) }

    public static let clear = MarkupColor(red: 0, green: 0, blue: 0, alpha: 0)
    public static let black = MarkupColor(hex: "#000000")
    public static let red = MarkupColor(hex: "#FF3B30")
    public static let noteYellow = MarkupColor(hex: SPColor.noteYellow.light)
}

/// Preview's colour menu (TB_Black … TB_Pink), the values Apple's system palette draws in light mode.
public enum MarkupPalette {
    public static let colors: [(name: String, color: MarkupColor)] = [
        ("Black", .black), ("Gray", MarkupColor(hex: "#8E8E93")), ("Red", .red), ("Orange", MarkupColor(hex: "#FF9500")),
        ("Yellow", MarkupColor(hex: "#FFCC00")), ("Green", MarkupColor(hex: "#34C759")), ("Blue", MarkupColor(hex: "#007AFF")),
        ("Purple", MarkupColor(hex: "#AF52DE")), ("Pink", MarkupColor(hex: "#FF2D55")),
    ]
    /// Shape Style's line widths, in points.
    public static let lineWidths: [Double] = [0.5, 1, 2, 3, 4, 6, 8, 12]
    /// Text Style's sizes.
    public static let fontSizes: [Double] = [9, 10, 12, 14, 18, 24, 36, 48, 72]
    /// Text Style's fonts: standard faces every PDF reader has.
    public static let fonts: [String] = ["Helvetica", "Helvetica-Bold", "Times-Roman", "Courier", "Georgia", "Arial", "Verdana"]
}

public enum MarkupTextAlignment: String, Codable, CaseIterable, Sendable {
    case left, center, right

    var nsAlignment: NSTextAlignment {
        switch self {
        case .left: .left
        case .center: .center
        case .right: .right
        }
    }
}

/// The look of new markup and of the selection's restyling: Shape Style, Border Colour, Fill Colour, Text Style.
public struct MarkupStyle: Codable, Hashable, Sendable {
    public var stroke: MarkupColor = .red
    public var fill: MarkupColor = .clear
    public var lineWidth: Double = 2
    public var dashed = false
    public var arrowAtStart = false
    public var arrowAtEnd = true
    public var fontName = "Helvetica"
    public var fontSize: Double = 12
    public var textColor: MarkupColor = .black
    public var alignment: MarkupTextAlignment = .left
    public var textMarkup: TextMarkupStyle = .highlight(.yellow)
    public var noteColor: MarkupColor = .noteYellow

    public init() {}

    var font: NSFont { NSFont(name: fontName, size: fontSize) ?? NSFont(name: "Helvetica", size: fontSize) ?? .systemFont(ofSize: fontSize) }
}

extension Defaults.Keys {
    /// The bar's style, remembered across documents like Preview's.
    static let markupStyle = Key<MarkupStyle>("markupKit.style", default: MarkupStyle())
    /// The last measure scale chosen ("this line is 10 m"), offered on pages that have none yet.
    static let measureUnit = Key<MeasureUnit>("markupKit.measureUnit", default: .m)
}
