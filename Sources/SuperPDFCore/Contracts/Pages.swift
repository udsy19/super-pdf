import Foundation

// Page operations (PagesKit: `Services.pages`; features §1.2). ViewerKit's thumbnails, context menu and organiser,
// PagesKit's own panels and batch steps all edit pages through these, so every edit is one undo step.

/// One edit of a document's page list (0-based indices).
public enum PageOperation: Hashable, Sendable {
    /// Quarter turns; positive is clockwise (⌘R), negative counter-clockwise (⌘L). Saved as /Rotate.
    case rotate([Int], quarterTurns: Int)
    /// Never the last page (ux §5.3: "A PDF needs at least one page.").
    case delete([Int])
    /// Moves the pages, in their current order, so the first lands at `to` in the resulting document.
    case move([Int], to: Int)
    case duplicate([Int])
    /// A blank page the size of its neighbour, after `after` (-1 for the front).
    case insertBlank(after: Int)
    /// Pages of another PDF (all when `pages` is empty) at `at`.
    case insertFile(PDFSource, pages: [Int], at: Int)
    /// Replaces `range` with pages of another file, keeping comments where positions match (features #25).
    case replace(ClosedRange<Int>, with: PDFSource, pages: [Int])
    case reverse
}

public enum PageEditError: LocalizedError, Equatable {
    case lastPage
    case pagesOutOfRange
    case notAllowed

    public var errorDescription: String? {
        switch self {
        case .lastPage: Strings.Errors.lastPage
        case .pagesOutOfRange: "Those pages aren’t in this document."
        case .notAllowed: Strings.Errors.ownerRestricted(.pageChanges)
        }
    }
}

@MainActor
public protocol PageEditing: AnyObject {
    /// Applies an edit to the open document and returns its undo step (DocumentKit registers it).
    func perform(_ operation: PageOperation, in document: DocumentHandle) async throws -> UndoGroup
    /// The pages as a new PDF (extract, drag to Finder as a file promise, features #22).
    func extract(_ pages: [Int], from document: DocumentHandle) throws -> Data
    /// Copies pages between open documents (thumbnail drag to another window; ⌥ moves).
    func copy(_ pages: [Int], from source: DocumentHandle, to target: DocumentHandle, at index: Int) throws -> UndoGroup
}
