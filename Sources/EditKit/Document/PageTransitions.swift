import Foundation
import PDFModelKit

// Page transitions for slideshows (features #113; ISO 32000-2 §12.4.4): the /Trans dictionary of each page.

public struct PageTransition: Codable, Hashable, Sendable {
    public enum Style: String, Codable, CaseIterable, Sendable {
        case split = "Split", blinds = "Blinds", box = "Box", wipe = "Wipe", dissolve = "Dissolve", glitter = "Glitter", replace = "R"
        case fly = "Fly", push = "Push", cover = "Cover", uncover = "Uncover", fade = "Fade"

        public var title: String {
            switch self {
            case .split: "Split"
            case .blinds: "Blinds"
            case .box: "Box"
            case .wipe: "Wipe"
            case .dissolve: "Dissolve"
            case .glitter: "Glitter"
            case .replace: "None"
            case .fly: "Fly"
            case .push: "Push"
            case .cover: "Cover"
            case .uncover: "Uncover"
            case .fade: "Fade"
            }
        }
    }

    public var style: Style
    /// Seconds the transition takes.
    public var duration: Double
    /// Seconds the page shows before advancing in a slideshow (nil: wait for a click).
    public var advanceAfter: Double?

    public init(style: Style, duration: Double = 1, advanceAfter: Double? = nil) {
        self.style = style; self.duration = duration; self.advanceAfter = advanceAfter
    }

    /// The transition of a page, nil when it has none.
    public static func read(from page: PDFPage) -> PageTransition? {
        guard let trans = page.object["Trans"], let name = trans["S"]?.name, let style = Style(rawValue: name) else { return nil }
        return PageTransition(style: style, duration: trans["D"]?.number ?? 1, advanceAfter: page.object["Dur"]?.number)
    }

    /// Sets (or with nil removes) the transition of `pages`.
    public static func write(_ transition: PageTransition?, to pages: [Int], in model: PDFModel) {
        for index in pages {
            guard let page = model.page(at: index) else { continue }
            guard let transition else { page.object.remove("Trans"); page.object.remove("Dur"); continue }
            page.object.set("Trans", .dictionary(["Type": .name("Trans"), "S": .name(transition.style.rawValue), "D": .number(transition.duration)]))
            if let advance = transition.advanceAfter { page.object.set("Dur", .number(advance)) } else { page.object.remove("Dur") }
        }
    }
}
