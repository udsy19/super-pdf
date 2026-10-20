import Foundation

/// One undoable step of an in-place edit (features §2.3: every change is on the undo stack, page operations and tool
/// runs included). Providers build it; DocumentKit registers it with the document's undo manager under `actionName`
/// ("Undo Rotate Pages").
@MainActor
public struct UndoGroup {
    public enum Change {
        /// The edit is already applied; these reverse and re-apply it (PDFKit page and annotation edits on the main actor).
        case actions(undo: @MainActor () -> Void, redo: @MainActor () -> Void)
        /// The document's bytes changed (an engine rewrote the file, e.g. the OCR text layer): DocumentKit swaps the
        /// PDFKit document between these and keeps the view state.
        case contents(before: Data, after: Data)
    }

    public var actionName: String
    public var change: Change

    public init(_ actionName: String, _ change: Change) { self.actionName = actionName; self.change = change }

    public init(_ actionName: String, undo: @escaping @MainActor () -> Void, redo: @escaping @MainActor () -> Void) {
        self.init(actionName, .actions(undo: undo, redo: redo))
    }

    /// Several steps as one ("Insert 3 pages" made of three insertions): undone last to first.
    public static func combined(_ actionName: String, _ groups: [UndoGroup]) -> UndoGroup {
        UndoGroup(actionName, undo: {
            for group in groups.reversed() { group.undo() }
        }, redo: {
            for group in groups { group.redo() }
        })
    }

    /// Reverses an `.actions` change; `.contents` changes are applied by DocumentKit, which owns the document swap.
    public func undo() {
        if case .actions(let undo, _) = change { undo() }
    }

    public func redo() {
        if case .actions(_, let redo) = change { redo() }
    }
}

public extension UndoManager {
    /// Registers an `.actions` group so that undo and redo alternate for as long as the stack lives. DocumentKit uses
    /// it for every in-place tool result (it handles `.contents` groups with its own swap).
    @MainActor
    func register(_ group: UndoGroup) {
        guard case .actions = group.change else { return }
        registerUndo(withTarget: UndoTarget.shared) { _ in
            MainActor.assumeIsolated {
                group.undo()
                self.register(UndoGroup(group.actionName, undo: group.redo, redo: group.undo))
            }
        }
        setActionName(group.actionName)
    }
}

/// The target undo registrations hang on: groups capture their own state, so one shared object is enough.
private final class UndoTarget: @unchecked Sendable {
    static let shared = UndoTarget()
}
