import AppKit
import SuperPDFCore
import SwiftUI

// The look shared by the Tools sheet, the panels and the banner: Core's tokens (ux §2) plus the few measurements the
// mockups (docs/mockups/src/shared.css) add where the spec gives none.

enum Style {
    // MARK: Colours (system colours through the Core tokens, so dark mode, accent colour and Increase Contrast follow)

    static var accent: NSColor { SPColor.accent.color }
    static var label: NSColor { SPColor.label.color }
    static var secondary: NSColor { SPColor.secondaryLabel.color }
    static var tertiary: NSColor { SPColor.tertiaryLabel.color }
    static var separator: NSColor { SPColor.separator.color }
    static var control: NSColor { SPColor.controlBackground.color }
    static var surface: NSColor { SPColor.sidebar.color }
    static var destructive: NSColor { SPColor.destructive.color }
    /// Field and popup borders: a little stronger than the separator (mockup `--sep-strong`, 16 % / 18 %).
    static let strongSeparator = NSColor(name: "toolsKit.strongSeparator") { appearance in
        appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua ? NSColor(white: 1, alpha: 0.18) : NSColor(white: 0, alpha: 0.16)
    }
    /// Segmented tracks, the sheet's close button: a faint fill of the label colour.
    static let faintFill = NSColor(name: "toolsKit.faintFill") { appearance in
        appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua ? NSColor(white: 1, alpha: 0.08) : NSColor(white: 0, alpha: 0.06)
    }
    /// The accent at 12 %: selected preset cards, chips, focus rings.
    static var accentSoft: NSColor { accent.withAlphaComponent(0.12) }

    static func category(_ section: ToolSection) -> NSColor { section.color.color }

    // MARK: Type (ux §2.2, scaled by Settings › General › Text size)

    static func font(_ style: SPTextStyle) -> NSFont { style.font(Defaults[.textSize]) }
    static func font(size: CGFloat, weight: NSFont.Weight = .regular) -> NSFont {
        SPTextStyle(size, weight).font(Defaults[.textSize])
    }

    // MARK: Materials

    /// The Tools sheet and the panels sit on the vibrant sidebar material (ux §2.3). Offscreen renders (the self-test)
    /// can't capture vibrancy, so they draw its solid look instead.
    static var opaqueBackgrounds = false

    // MARK: Motion

    static var reduceMotion: Bool { NSWorkspace.shared.accessibilityDisplayShouldReduceMotion }

    // MARK: Mockup measurements the spec leaves open

    enum Sheet {
        static let titleTop: CGFloat = 22
        static let titleGap: CGFloat = 12
        static let searchRadius: CGFloat = 9
        static let closeSize: CGFloat = 24
        static let closeInset: CGFloat = 14
        static let bodyTop: CGFloat = 8
        static let headerTop: CGFloat = 16
        static let headerGap: CGFloat = 8
        /// A section header's line: its 20 pt icon.
        static let headerLine: CGFloat = 20
        static let bottom: CGFloat = 24
        /// The section chips: 12 pt under the search field, 28 pt capsules 6 pt apart.
        static let chipsGap: CGFloat = 12
        static let chipHeight: CGFloat = 28
        static let chipGap: CGFloat = 6
        /// The colour wash behind the title.
        static let washHeight: CGFloat = 150
        /// Search focus ring (3 pt of the soft accent).
        static let focusRing: CGFloat = 3
    }

    enum TileInside {
        static let padding = NSEdgeInsets(top: 12, left: 12, bottom: 10, right: 12)
        static let gap: CGFloat = 6
    }

    enum Panel {
        static let headerTop: CGFloat = 12
        static let headerLeading: CGFloat = 12
        static let headerTrailing: CGFloat = 14
        static let hintIndent: CGFloat = 32
        static let contentTop: CGFloat = 16
        static let gap: CGFloat = 14
        static let labelWidth: CGFloat = 70
        static let footerTop: CGFloat = 12
        static let footerBottom: CGFloat = 14
        static let footerGap: CGFloat = 8
        /// The section-coloured wash under the header.
        static let washHeight: CGFloat = 64
    }
}

extension Color {
    init(_ ns: NSColor) { self.init(nsColor: ns) }
}

extension SwiftUI.Font {
    static func sp(_ style: SPTextStyle) -> SwiftUI.Font { SwiftUI.Font(Style.font(style)) }
    static func sp(size: CGFloat, weight: NSFont.Weight = .regular) -> SwiftUI.Font { SwiftUI.Font(Style.font(size: size, weight: weight)) }
}

/// A symbol image at a point size and weight, or an empty image when the name is unknown (never crashes on a bad name).
func symbol(_ name: String, size: CGFloat, weight: NSFont.Weight = .regular) -> NSImage {
    let image = NSImage(systemSymbolName: name, accessibilityDescription: nil) ?? NSImage(size: NSSize(width: size, height: size))
    return image.withSymbolConfiguration(NSImage.SymbolConfiguration(pointSize: size, weight: weight)) ?? image
}

/// "Label: value" summary lines (ToolPreview.summary): the label, the emphasised first figure and the rest.
struct SummaryLine: Equatable {
    var label: String?
    var emphasis: String
    var rest: String

    init(_ line: String) {
        guard let colon = line.range(of: ": ") else { label = nil; emphasis = ""; rest = line; return }
        label = String(line[..<colon.lowerBound])
        let value = String(line[colon.upperBound...])
        if let dot = value.range(of: " · ") {
            emphasis = String(value[..<dot.lowerBound]); rest = String(value[dot.lowerBound...])
        } else {
            emphasis = value; rest = ""
        }
    }
}

/// Text with the given substrings set in semibold (banner numbers, ux §2.2).
func emphasised(_ text: String, _ parts: [String], font: NSFont, bold: NSFont, color: NSColor) -> NSAttributedString {
    let result = NSMutableAttributedString(string: text, attributes: [.font: font, .foregroundColor: color])
    let ns = text as NSString
    for part in parts where !part.isEmpty {
        var range = ns.range(of: part)
        while range.location != NSNotFound {
            result.addAttribute(.font, value: bold, range: range)
            let next = range.location + range.length
            range = ns.range(of: part, range: NSRange(location: next, length: ns.length - next))
        }
    }
    return result
}
