import AppKit

// Colour tokens (ux §2.3). Semantic system colours only, so light and dark mode, the accent colour choice and Increase
// Contrast work for free: every token that has a system colour draws with it. The hex values are the reference
// appearance (default blue accent) for the self-test, the mockups and the few places that need fixed colours. Markup
// colours are Preview's, so files look the same in both apps.

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

    // MARK: Category colours: tile icon circles and panel header icons, nothing else (ux §2.3)

    public static let categoryBlue = SPColorToken("categoryBlue", light: "#007AFF", dark: "#0A84FF", system: .systemBlue)
    public static let categoryGreen = SPColorToken("categoryGreen", light: "#34C759", dark: "#30D158", system: .systemGreen)
    public static let categoryOrange = SPColorToken("categoryOrange", light: "#FF9500", dark: "#FF9F0A", system: .systemOrange)
    public static let categoryYellow = SPColorToken("categoryYellow", light: "#FFCC00", dark: "#FFD60A", system: .systemYellow)
    public static let categoryPurple = SPColorToken("categoryPurple", light: "#AF52DE", dark: "#BF5AF2", system: .systemPurple)
    public static let categoryRed = SPColorToken("categoryRed", light: "#FF3B30", dark: "#FF453A", system: .systemRed)
    public static let categoryTeal = SPColorToken("categoryTeal", light: "#30B0C7", dark: "#40C8E0", system: .systemTeal)
    public static let categoryIndigo = SPColorToken("categoryIndigo", light: "#5856D6", dark: "#5E5CE6", system: .systemIndigo)
    public static let categoryBrown = SPColorToken("categoryBrown", light: "#A2845E", dark: "#AC8E68", system: .systemBrown)

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
        categoryIndigo, categoryBrown, highlightYellow, highlightGreen, highlightBlue, highlightPink, highlightPurple, noteYellow,
        redactionApplied,
    ]
}
