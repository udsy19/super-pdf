import AppKit

// Colour tokens (ux §2.3). Chrome and text use semantic system colours, so light and dark mode, the accent colour choice
// and Increase Contrast work for free: every token that has a system colour draws with it. The brand palette (one
// cheerful colour per Tools section, the app's indigo, the success green, the workspace canvas and the pastel file
// pills) is fixed, with its own dark values, so the app has one recognisable look. Markup colours are Preview's, so
// files look the same in both apps. The hex values are also the mockups' (docs/mockups/src/shared.css).

/// A light/dark pair of "#RRGGBB" / "#RRGGBBAA" reference values, and the system colour that renders it.
public struct SPColorToken: Hashable, @unchecked Sendable {
    public var name: String
    public var light: String
    public var dark: String
    /// The semantic system colour; nil for fixed colours (markup) and materials (the sidebar).
    public var system: NSColor?

    public init(_ name: String, light: String, dark: String, system: NSColor? = nil) {
        self.name = name; self.light = light; self.dark = dark; self.system = system
    }

    public init(_ name: String, _ both: String) { self.init(name, light: both, dark: both) }

    /// The colour to draw with: the system colour, else a dynamic colour resolved by the drawing appearance.
    public var color: NSColor {
        if let system { return system }
        let light = NSColor(hex: light), dark = NSColor(hex: dark)
        return NSColor(name: NSColor.Name("superpdf." + name)) { appearance in
            appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua ? dark : light
        }
    }

    public func hex(dark isDark: Bool) -> String { isDark ? dark : light }
}

public enum SPColor {
    // MARK: Chrome and text (ux §2.3)

    public static let windowBackground = SPColorToken("windowBackground", light: "#ECECEC", dark: "#323232", system: .windowBackgroundColor)
    /// The vibrant `sidebar` material (also the Tools sheet background); the hex values are its approximate look.
    public static let sidebar = SPColorToken("sidebar", light: "#F2F2F2", dark: "#2A2A2A")
    /// The document well.
    public static let underPageBackground = SPColorToken("underPageBackground", light: "#E6E6E6", dark: "#1E1E1E",
                                                         system: .underPageBackgroundColor)
    /// Tiles, panel cards, the result banner.
    public static let controlBackground = SPColorToken("controlBackground", light: "#FFFFFF", dark: "#1E1E1E",
                                                       system: .controlBackgroundColor)
    public static let separator = SPColorToken("separator", light: "#0000001A", dark: "#FFFFFF1A", system: .separatorColor)
    public static let label = SPColorToken("label", light: "#000000D9", dark: "#FFFFFFD9", system: .labelColor)
    public static let secondaryLabel = SPColorToken("secondaryLabel", light: "#00000080", dark: "#FFFFFF8C", system: .secondaryLabelColor)
    public static let tertiaryLabel = SPColorToken("tertiaryLabel", light: "#00000040", dark: "#FFFFFF40", system: .tertiaryLabelColor)
    /// The Tools button, primary buttons, selection rings, drop highlights, the insertion line.
    public static let accent = SPColorToken("accent", light: "#007AFF", dark: "#0A84FF", system: .controlAccentColor)
    /// Black out marks and destructive confirm buttons only.
    public static let destructive = SPColorToken("destructive", light: "#FF3B30", dark: "#FF453A", system: .systemRed)

    // MARK: Brand palette (ux §2.3): one colour per Tools section, for tile icons, panel headers and section chips

    public static let categoryBlue = SPColorToken("categoryBlue", light: "#2F80ED", dark: "#4C8DF6")
    public static let categoryGreen = SPColorToken("categoryGreen", light: "#1FAF68", dark: "#2DC27A")
    public static let categoryOrange = SPColorToken("categoryOrange", light: "#FF8A1F", dark: "#FF9A3C")
    public static let categoryYellow = SPColorToken("categoryYellow", light: "#F5B000", dark: "#FFC21A")
    public static let categoryPurple = SPColorToken("categoryPurple", light: "#8B5CF6", dark: "#9D74FF")
    public static let categoryRed = SPColorToken("categoryRed", light: "#EF4444", dark: "#F65A5A")
    public static let categoryTeal = SPColorToken("categoryTeal", light: "#0EB2C2", dark: "#22C3D2")
    public static let categoryPink = SPColorToken("categoryPink", light: "#EC4899", dark: "#F45FAA")
    /// The app's own colour: its mark and "Open a PDF".
    public static let brand = SPColorToken("brand", light: "#5B5BF6", dark: "#7272FF")
    /// "Done": the result banner's check and its wash, a finished conversion.
    public static let success = SPColorToken("success", light: "#22B35E", dark: "#30C46C")
    /// The workspace's soft blue canvas (ux §6.2) and the cards on it.
    public static let canvas = SPColorToken("canvas", light: "#EDF3FE", dark: "#171B23")
    public static let card = SPColorToken("card", light: "#FFFFFF", dark: "#252B36")

    /// The section colours in the sheet's order.
    public static let categories: [SPColorToken] = [categoryBlue, categoryGreen, categoryOrange, categoryYellow, categoryPurple, categoryRed,
                                                    categoryTeal, categoryPink]

    // MARK: File pills (ux §6.2): a pastel fill with a deep ink of the same hue, one pair per file in the workspace

    public static let pills: [SPPill] = [
        SPPill("sky", fill: ("#DCEBFF", "#1E3A66"), ink: ("#1F5FBF", "#A9CBFF")),
        SPPill("pink", fill: ("#FFDDEB", "#5A2440"), ink: ("#B4245F", "#FFB3D2")),
        SPPill("mint", fill: ("#D3F5E3", "#1C4A35"), ink: ("#127346", "#A6EBC7")),
        SPPill("peach", fill: ("#FFE4CF", "#5A3519"), ink: ("#A8500F", "#FFC9A1")),
        SPPill("lavender", fill: ("#E9E0FF", "#3A2D66"), ink: ("#5B3CC4", "#CDBDFF")),
        SPPill("lemon", fill: ("#FFF2B8", "#4D4214"), ink: ("#7D5E00", "#FFE58A")),
        SPPill("aqua", fill: ("#CFF4F6", "#164A50"), ink: ("#0B6E78", "#9FE8EE")),
        SPPill("coral", fill: ("#FFE0DC", "#5A2622"), ink: ("#B3322A", "#FFB8AF")),
    ]

    // MARK: Markup: Preview's highlight colours, light written into the file, dark for display (ux §2.3)

    public static let highlightYellow = SPColorToken("highlightYellow", light: "#FACD5A", dark: "#5E4613")
    public static let highlightGreen = SPColorToken("highlightGreen", light: "#7CC868", dark: "#294714")
    public static let highlightBlue = SPColorToken("highlightBlue", light: "#69B0F1", dark: "#1F3466")
    public static let highlightPink = SPColorToken("highlightPink", light: "#FB5C89", dark: "#5E2D42")
    public static let highlightPurple = SPColorToken("highlightPurple", light: "#C885DA", dark: "#422D61")
    /// Sticky-note fill.
    public static let noteYellow = SPColorToken("noteYellow", "#FFEB6B")

    /// Preview's highlight palette in its menu order.
    public static let highlights: [SPColorToken] = [highlightYellow, highlightGreen, highlightBlue, highlightPink, highlightPurple]

    // MARK: Redaction (ux §2.3): a red outline with a 10 % fill while marked; solid black (or the chosen colour) after.

    public static let redactionMarkFillOpacity: CGFloat = 0.10
    public static let redactionApplied = SPColorToken("redactionApplied", "#000000")

    /// Every token, for the self-test and a debug palette.
    public static let all: [SPColorToken] = [
        windowBackground, sidebar, underPageBackground, controlBackground, separator, label, secondaryLabel, tertiaryLabel, accent,
        destructive, categoryBlue, categoryGreen, categoryOrange, categoryYellow, categoryPurple, categoryRed, categoryTeal,
        categoryPink, brand, success, canvas, card, highlightYellow, highlightGreen, highlightBlue, highlightPink, highlightPurple,
        noteYellow, redactionApplied,
    ] + pills.flatMap { [$0.fill, $0.ink] }
}

/// A file's pill colours (ux §6.2): the pastel `fill` behind its name and the `ink` the name is written in, which is
/// also the file's colour wherever a stronger mark is needed (the bar on its pages in the sidebar).
public struct SPPill: Hashable, Sendable {
    public var name: String
    public var fill: SPColorToken
    public var ink: SPColorToken

    public init(_ name: String, fill: (light: String, dark: String), ink: (light: String, dark: String)) {
        self.name = name
        self.fill = SPColorToken("pill." + name, light: fill.light, dark: fill.dark)
        self.ink = SPColorToken("pillInk." + name, light: ink.light, dark: ink.dark)
    }
}
