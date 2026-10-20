import CoreGraphics
import Foundation

// Markup and review (MarkupKit: `Services.markup`; features #8, #15, #76–#79, #116, #117; ux §6.4).

/// Review state of a comment (features #77).
public enum ReviewStatus: String, Codable, CaseIterable, Sendable {
    case none, accepted, rejected, completed, resolved
}

/// The kinds the Highlights and Notes sidebar filters by.
public enum MarkupKind: String, Codable, CaseIterable, Sendable {
    case highlight, underline, strikeOut, note, textBox, callout, ink, shape, stamp, attachment, sound, link, measurement, caret
}

/// One comment or annotation as the sidebar lists it.
public struct CommentItem: Codable, Hashable, Identifiable, Sendable {
    /// Stable within the open document (the annotation's /NM, or one MarkupKit assigns).
    public var id: String
    public var page: Int
    public var kind: MarkupKind
    public var author: String
    public var modified: Date?
    public var text: String
    /// The highlighted or struck text, for markup on text.
    public var quotedText: String?
    public var bounds: CGRect
    public var status: ReviewStatus
    public var replies: [CommentReply]

    public init(id: String, page: Int, kind: MarkupKind, author: String = "", modified: Date? = nil, text: String = "",
                quotedText: String? = nil, bounds: CGRect = .zero, status: ReviewStatus = .none, replies: [CommentReply] = []) {
        self.id = id; self.page = page; self.kind = kind; self.author = author; self.modified = modified; self.text = text
        self.quotedText = quotedText; self.bounds = bounds; self.status = status; self.replies = replies
    }
}

public struct CommentReply: Codable, Hashable, Identifiable, Sendable {
    public var id: String
    public var author: String
    public var modified: Date?
    public var text: String

    public init(id: String, author: String, modified: Date? = nil, text: String) {
        self.id = id; self.author = author; self.modified = modified; self.text = text
    }
}

/// Comment exchange formats (features #59, #77).
public enum CommentFormat: String, Codable, CaseIterable, Sendable {
    case xfdf, fdf, csv
}

/// "Summarise comments to PDF…" options (features #117, Acrobat's).
public struct CommentSummaryOptions: Codable, Hashable, Sendable {
    public enum Layout: String, Codable, Sendable {
        /// Document and comments side by side with connector lines.
        case connectorLines
        /// Comments only, numbered.
        case commentsOnly
        /// Document pages followed by the numbered comments.
        case sequenceNumbers
    }

    public var layout: Layout
    public var fontSize: Double

    public init(layout: Layout = .connectorLines, fontSize: Double = 10) { self.layout = layout; self.fontSize = fontSize }
}

/// Measurement units (features #15, Acrobat's list).
public enum MeasureUnit: String, Codable, CaseIterable, Sendable {
    case pt, inch = "in", mm, cm, pica, ft, yd, m, km, mi
}

/// "This line is 10 m": `pageDistance` points on the page stand for `realDistance` units.
public struct MeasureScale: Codable, Hashable, Sendable {
    public var pageDistance: Double
    public var realDistance: Double
    public var unit: MeasureUnit

    public init(pageDistance: Double = 72, realDistance: Double = 1, unit: MeasureUnit = .inch) {
        self.pageDistance = pageDistance; self.realDistance = realDistance; self.unit = unit
    }

    /// Real-world length of `points` on the page.
    public func length(_ points: Double) -> Double { pageDistance > 0 ? points / pageDistance * realDistance : 0 }
    /// Real-world area of `squarePoints` on the page.
    public func area(_ squarePoints: Double) -> Double {
        pageDistance > 0 ? squarePoints / (pageDistance * pageDistance) * realDistance * realDistance : 0
    }
}

/// Comments review (features #77).
@MainActor
public protocol CommentsReviewing: AnyObject {
    func comments(in document: DocumentHandle) -> [CommentItem]
    func reply(to comment: CommentItem, text: String, in document: DocumentHandle) -> UndoGroup
    func setStatus(_ status: ReviewStatus, of comment: CommentItem, in document: DocumentHandle) -> UndoGroup
    func exportComments(from document: DocumentHandle, as format: CommentFormat, to destination: URL) throws
    func importComments(from file: URL, into document: DocumentHandle) throws -> UndoGroup
    /// A new PDF summarising the comments.
    func summarizeComments(of document: DocumentHandle, options: CommentSummaryOptions) async throws -> Data
}

/// Measuring on plans (features #15); results are stored as measurement annotations.
@MainActor
public protocol Measuring: AnyObject {
    func scale(in document: DocumentHandle, page: Int) -> MeasureScale
    func setScale(_ scale: MeasureScale, in document: DocumentHandle, page: Int) -> UndoGroup
}

/// Annotations (MarkupKit). The markup bar and its tools are MarkupKit's own UI; these are the operations other
/// modules need.
@MainActor
public protocol Annotating: CommentsReviewing, Measuring {
    /// The author on new markup: Settings › General, else the Contacts "Me" card (features #76).
    var authorName: String { get }
    /// Shows or hides Preview's markup bar (⇧⌘A).
    func setMarkupBarVisible(_ visible: Bool, in document: DocumentHandle)
    /// Clips a file (or a recorded voice note) to a page as a paper-clip annotation (features #79).
    func attachFile(_ file: URL, to page: Int, at point: CGPoint, in document: DocumentHandle) throws -> UndoGroup
    /// A stamp annotation with an appearance stream (EditKit's stamps tool and image drops in Markup mode).
    func addStamp(_ image: Data, on page: Int, in rect: CGRect, in document: DocumentHandle) throws -> UndoGroup
}
