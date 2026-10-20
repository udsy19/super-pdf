import Foundation
import SuperPDFCore

/// Where each part of a `ToolPanel` goes (ux §5.1–§5.2), worked out once per panel so the view only draws: the mode
/// switch or the G steps under the hint, the body in order with the scope row and the More options disclosure in
/// place, and no more than three visible choices (the rest move to the top of More options).
public struct PanelLayout {
    public enum Item {
        case control(ToolControl)
        /// The "Pages" scope row.
        case scope
        /// The disclosure; its controls are `moreOptions`.
        case moreOptions
    }

    /// A mode panel's (D) leading unlabelled segmented control, drawn under the hint.
    public var headerSwitch: ToolControl?
    /// Archetype G's steps, drawn under the hint.
    public var steps: [String]
    public var currentStep: Int
    public var body: [Item]
    /// The controls behind the disclosure: choices over the limit first, then the panel's own.
    public var moreOptions: [ToolControl]

    public init(_ panel: ToolPanel) {
        var controls = panel.controls
        headerSwitch = nil
        if panel.archetype == .mode, case .segmented(_, nil, _, _)? = controls.first {
            headerSwitch = controls.removeFirst()
        }
        steps = panel.archetype == .flow ? panel.steps : []
        currentStep = min(max(panel.currentStep, 0), max(steps.count - 1, 0))

        var visible: [ToolControl] = []
        var overflow: [ToolControl] = []
        var choices = 0
        for control in controls {
            if control.isChoice {
                choices += 1
                if choices > SPMetrics.ToolPanel.maximumVisibleControls { overflow.append(control); continue }
            }
            visible.append(control)
        }
        moreOptions = overflow + panel.moreOptions

        var body: [Item] = []
        for control in visible {
            switch control {
            case .scope: if panel.showsScope { body.append(.scope) }
            case .moreOptions: if !moreOptions.isEmpty { body.append(.moreOptions) }
            default: body.append(.control(control))
            }
        }
        if panel.showsScope && !body.contains(where: { if case .scope = $0 { true } else { false } }) {
            // After the last choice (or segmented switch); at the top when there is none.
            let last = body.lastIndex { item in
                guard case .control(let control) = item else { return false }
                if case .segmented = control { return true }
                return control.isChoice
            }
            body.insert(.scope, at: last.map { $0 + 1 } ?? 0)
        }
        if !moreOptions.isEmpty && !body.contains(where: { if case .moreOptions = $0 { true } else { false } }) {
            body.append(.moreOptions)
        }
        self.body = body
    }

    /// The visible choices (for the three-choice rule).
    public var visibleChoices: Int {
        body.reduce(0) { count, item in
            if case .control(let control) = item, control.isChoice { return count + 1 }
            return count
        }
    }
}
