import Foundation
import QuartzCore

// Motion (ux §2.5). Durations in seconds. With Reduce Motion on, only crossfades remain (no movement).

/// A spring in SwiftUI's response/damping parametrisation.
public struct SPSpring: Hashable, Sendable {
    public var response: Double
    public var dampingFraction: Double

    public init(response: Double, dampingFraction: Double) { self.response = response; self.dampingFraction = dampingFraction }

    /// The same spring for Core Animation (unit mass): stiffness (2π / response)², damping 4π · fraction / response.
    public func animation(_ keyPath: String, from: Any?, to: Any?) -> CASpringAnimation {
        let spring = CASpringAnimation(keyPath: keyPath)
        spring.mass = 1
        spring.stiffness = pow(2 * .pi / response, 2)
        spring.damping = 4 * .pi * dampingFraction / response
        spring.fromValue = from
        spring.toValue = to
        spring.duration = spring.settlingDuration
        return spring
    }
}

public enum SPMotion {
    /// The Tools sheet slides in as a system sheet.
    public static let sheet: TimeInterval = 0.25
    /// Tiles fade up in three staggered rows, this far apart.
    public static let tileStagger: TimeInterval = 0.04
    public static let tileStaggerRows = 3
    /// Tool panel width 0 → 320, ease-out; its content fades in from this point.
    public static let panelOpen: TimeInterval = 0.22
    public static let panelContentFadeIn: TimeInterval = 0.12
    /// Switching tools: crossfade, the header title slides 8 pt.
    public static let toolSwitch: TimeInterval = 0.15
    public static let toolSwitchTitleSlide: CGFloat = 8
    /// Tile hover: the border takes the section's colour (150 ms) while the tile lifts and grows on a lively spring.
    public static let hover: TimeInterval = 0.15
    public static let hoverSpring = SPSpring(response: 0.32, dampingFraction: 0.58)
    /// The result banner's check pops in; the confetti falls for this long (none with Reduce Motion).
    public static let pop = SPSpring(response: 0.42, dampingFraction: 0.5)
    public static let confetti: TimeInterval = 1.4
    /// A picked-up thumbnail scales up with an 8 pt shadow; the others (the workspace's cards) shift, make room and settle
    /// with this spring.
    public static let dragLiftScale: CGFloat = 1.05
    public static let dragShadow: CGFloat = 8
    public static let thumbnailShift = SPSpring(response: 0.3, dampingFraction: 0.8)
    public static let insertionLineFade: TimeInterval = 0.1
    /// Drop target ring and tint; the "Add here" label appears after hovering this long.
    public static let dropTarget: TimeInterval = 0.12
    public static let dropLabelDelay: TimeInterval = 0.3
    /// The result banner slides down 44 pt, ease-out.
    public static let banner: TimeInterval = 0.3
    /// Live preview edits re-render after this pause; no animation, the page just updates.
    public static let previewDebounce: TimeInterval = 0.08
    /// 90° rotation of the thumbnail and the page.
    public static let pageRotate: TimeInterval = 0.25
}
