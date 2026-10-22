import CoreGraphics
import Foundation

// Page operations (PagesKit: `Services.pages`; features §1.2). ViewerKit's thumbnails, context menu and workspace,
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

/// Margins as people see a page (after /Rotate), in points: what Crop takes off (features #28) and the white margins it
/// finds. ViewerKit's crop handles and PagesKit's crop panel speak in these.
public struct PageInsets: Codable, Hashable, Sendable {
    public var top: Double
    public var left: Double
    public var bottom: Double
    public var right: Double

    public init(top: Double, left: Double, bottom: Double, right: Double) {
        self.top = top; self.left = left; self.bottom = bottom; self.right = right
    }

    public static let zero = PageInsets(top: 0, left: 0, bottom: 0, right: 0)
    public var isZero: Bool { self == .zero }

    /// The rect left after taking these off `box` (page space) on a page turned `rotation` degrees clockwise; nil when
    /// less than a point would be left either way.
    public func kept(in box: CGRect, rotation: Int) -> CGRect? {
        // Which page-space side each seen side is: (minX, minY, maxX, maxY) insets.
        let (minX, minY, maxX, maxY) = pageSides(rotation: rotation)
        let width = box.width - minX - maxX, height = box.height - minY - maxY
        guard width >= 1, height >= 1 else { return nil }
        return CGRect(x: box.minX + minX, y: box.minY + minY, width: width, height: height)
    }

    /// The insets that leave `kept` (page space) of `box` on a page turned `rotation` degrees clockwise: the inverse of
    /// `kept(in:rotation:)`, for a crop rectangle dragged on the page.
    public init(box: CGRect, kept: CGRect, rotation: Int) {
        let minX = Double(kept.minX - box.minX), minY = Double(kept.minY - box.minY)
        let maxX = Double(box.maxX - kept.maxX), maxY = Double(box.maxY - kept.maxY)
        switch ((rotation % 360) + 360) % 360 {
        case 90: self.init(top: minX, left: minY, bottom: maxX, right: maxY)
        case 180: self.init(top: minY, left: maxX, bottom: maxY, right: minX)
        case 270: self.init(top: maxX, left: maxY, bottom: minX, right: minY)
        default: self.init(top: maxY, left: minX, bottom: minY, right: maxX)
        }
    }

    private func pageSides(rotation: Int) -> (Double, Double, Double, Double) {
        switch ((rotation % 360) + 360) % 360 {
        case 90: (top, left, bottom, right)
        case 180: (right, top, left, bottom)
        case 270: (bottom, right, top, left)
        default: (left, bottom, right, top)
        }
    }
}
