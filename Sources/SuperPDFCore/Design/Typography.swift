import AppKit

// Type (ux §2.2): the system font (SF Pro) only, as Preview. Every role scales with Settings › General › Text size
// (ux §9: Default / Larger / Largest makes body 13 → 15 → 17). Monospace never appears in the UI.

/// A role's size at the default text size, and its weight.
public struct SPTextStyle: Hashable, Sendable {
    public var size: CGFloat
    public var weight: NSFont.Weight

    public init(_ size: CGFloat, _ weight: NSFont.Weight = .regular) { self.size = size; self.weight = weight }

    /// The system font for this role at a text-size setting.
    public func font(_ textSize: TextSize = .default) -> NSFont {
        .systemFont(ofSize: (size * textSize.scale).rounded(), weight: weight)
    }
}

public enum SPFont {
    /// Body, controls, menus, thumbnail labels in lists, text fields.
    public static let body = SPTextStyle(13)
    /// Hints, metadata, page numbers under thumbnails (with `secondaryLabelColor`).
    public static let secondary = SPTextStyle(11)
    /// Panel and sheet section titles.
    public static let panelTitle = SPTextStyle(15, .semibold)
    /// "What do you want to do?"
    public static let sheetTitle = SPTextStyle(20, .semibold)
    /// Tools sheet section headers.
    public static let sectionHeader = SPTextStyle(13, .semibold)
    public static let welcomeTitle = SPTextStyle(28, .bold)
    public static let welcomeSubtitle = SPTextStyle(15)
    /// Welcome window target labels.
    public static let welcomeTarget = SPTextStyle(15, .semibold)
    public static let tileName = SPTextStyle(13, .semibold)
    public static let tileHint = SPTextStyle(11)
    /// Result banner text; its numbers use `bannerEmphasis`.
    public static let banner = SPTextStyle(13)
    public static let bannerEmphasis = SPTextStyle(13, .semibold)
    public static let primaryButton = SPTextStyle(13, .semibold)
    /// The text button under the primary button ("Cancel").
    public static let secondaryButton = SPTextStyle(11)
    /// Highlights and Notes: page number (Preview's).
    public static let notesPageNumber = SPTextStyle(11, .bold)

    /// Every role, for the self-test.
    public static let all: [SPTextStyle] = [
        body, secondary, panelTitle, sheetTitle, sectionHeader, welcomeTitle, welcomeSubtitle, welcomeTarget, tileName, tileHint,
        banner, bannerEmphasis, primaryButton, secondaryButton, notesPageNumber,
    ]
}
