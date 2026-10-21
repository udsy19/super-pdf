import CryptoKit
import Foundation
import PDFKit

// The open document and the pages a tool works on (ux §5.1 scope line, §7; features §2.1–§2.3). Page indices are
// 0-based everywhere in code; people see 1-based numbers.

/// The bytes an engine works on, off the main actor (ARCHITECTURE "Rules": PDFKit objects stay on the main actor; long
/// jobs open a private PDFModelKit handle of the same bytes).
public enum PDFSource: Hashable, Sendable {
    case file(URL, password: String? = nil)
    case data(Data, password: String? = nil)

    public var password: String? {
        switch self {
        case .file(_, let password), .data(_, let password): password
        }
    }

    /// The bytes, read from disk for `.file`.
    public func bytes() throws -> Data {
        switch self {
        case .file(let url, _): try Data(contentsOf: url, options: .mappedIfSafe)
        case .data(let data, _): data
        }
    }

    /// A string that changes whenever the bytes do: the engines' caches (page images, layout) key on it. A file is its
    /// path, size and modification date; data is its SHA-256. Hashing data is the only cost, so call it off the main
    /// actor for large documents.
    public func fingerprint() -> String {
        switch self {
        case .file(let url, _):
            let values = try? url.resourceValues(forKeys: [.fileSizeKey, .contentModificationDateKey])
            return "file:\(url.path):\(values?.fileSize ?? -1):\(values?.contentModificationDate?.timeIntervalSince1970 ?? 0)"
        case .data(let data, _):
            return "data:" + SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
        }
    }
}

/// Where the document came from: it decides the first-save question (ux §7.1).
public enum DocumentOrigin: String, Codable, Sendable {
    /// Opened from disk: the first ⌘S asks "Save a copy" or "Replace original".
    case opened
    /// Made here (Combined, converted, scanned, from clipboard): the first ⌘S shows the save panel.
    case createdHere
}

/// What the file allows, in plain words (features #86, #90). An owner password can limit these; we honour them and say
/// so ("This file doesn't allow printing").
public struct DocumentPermissions: Codable, Hashable, Sendable {
    public var printing: PrintingPermission
    public var copyingText: Bool
    public var fillingFormsAndSigning: Bool
    public var commenting: Bool
    /// Insert, delete, rotate pages.
    public var pageChanges: Bool
    /// Text extraction for screen readers ("Allow screen readers" is always on when we write).
    public var screenReaders: Bool

    public enum PrintingPermission: String, Codable, Sendable { case none, lowResolution, highResolution }

    public init(printing: PrintingPermission = .highResolution, copyingText: Bool = true, fillingFormsAndSigning: Bool = true,
                commenting: Bool = true, pageChanges: Bool = true, screenReaders: Bool = true) {
        self.printing = printing; self.copyingText = copyingText; self.fillingFormsAndSigning = fillingFormsAndSigning
        self.commenting = commenting; self.pageChanges = pageChanges; self.screenReaders = screenReaders
    }

    public static let all = DocumentPermissions()
    public var isRestricted: Bool { self != .all }
}

/// The document-level facts the window, the Tools sheet and the panels react to.
public struct DocumentState: Hashable, Sendable {
    public var origin: DocumentOrigin
    /// Unsaved changes ("— Edited" in the title).
    public var isEdited: Bool
    /// The choice made at the first save (ux §7.1); nil until then.
    public var saveChoice: SaveBehaviour?
    /// Opened through QPDF recovery (features #1): the "We repaired…" notice shows once.
    public var wasRepaired: Bool
    /// Needs a password to open; `isLocked` until it is entered.
    public var isEncrypted: Bool
    public var isLocked: Bool
    public var permissions: DocumentPermissions
    /// Shows the Form Filling toolbar item (ux §2.1).
    public var hasFormFields: Bool
    /// Shows the Signatures sidebar mode (ux §2.1).
    public var hasSignatures: Bool

    public init(origin: DocumentOrigin = .opened, isEdited: Bool = false, saveChoice: SaveBehaviour? = nil, wasRepaired: Bool = false,
                isEncrypted: Bool = false, isLocked: Bool = false, permissions: DocumentPermissions = .all,
                hasFormFields: Bool = false, hasSignatures: Bool = false) {
        self.origin = origin; self.isEdited = isEdited; self.saveChoice = saveChoice; self.wasRepaired = wasRepaired
        self.isEncrypted = isEncrypted; self.isLocked = isLocked; self.permissions = permissions
        self.hasFormFields = hasFormFields; self.hasSignatures = hasSignatures
    }
}

/// A document's authoritative bytes and how PDFKit-level changes go back into them (DocumentKit's structure-preserving
/// save, ARCHITECTURE "Contract notes"). PDFKit redraws every page and drops document structure when it writes, so a
/// document DocumentKit opened keeps the bytes it was read from (or the bytes an engine edit made) and writes only the
/// changes made through PDFKit into them.
@MainActor
public protocol DocumentContents: AnyObject {
    /// The current bytes of `document`: the authoritative bytes with what changed through PDFKit since applied.
    func snapshot(of document: DocumentHandle) -> PDFSource
}

/// One open PDF: its file, the PDFKit document the window shows, and its state. DocumentKit creates and owns these;
/// every other module receives them. Engines never see this object, only `snapshot()`.
@MainActor
public final class DocumentHandle: Identifiable {
    public nonisolated let id: UUID
    /// Nil until a document made here is saved.
    public var url: URL?
    /// The name in the title bar and in output names ("Report" for Report.pdf; "Combined" before saving).
    public var displayName: String
    public var pdf: PDFDocument
    public var state: DocumentState
    /// The password the user typed this session, so engines can open the same bytes.
    public var password: String?
    /// The document's undo manager (NSDocument's); in-place tool results register here.
    public weak var undoManager: UndoManager?
    /// The authoritative bytes (DocumentKit sets them whenever the window's document is read from new bytes); nil for
    /// handles made without DocumentKit.
    public var contents: DocumentContents?

    public init(id: UUID = UUID(), url: URL?, displayName: String? = nil, pdf: PDFDocument, state: DocumentState = DocumentState(),
                password: String? = nil, undoManager: UndoManager? = nil) {
        self.id = id; self.url = url
        self.displayName = displayName ?? url?.deletingPathExtension().lastPathComponent ?? "Untitled"
        self.pdf = pdf; self.state = state; self.password = password; self.undoManager = undoManager
    }

    public var pageCount: Int { pdf.pageCount }

    /// The current bytes for engine work: the file when nothing is edited, else the authoritative bytes with the
    /// changes made through PDFKit written into them, as a save writes them (`contents`); PDFKit's own serialisation
    /// only for a handle without contents.
    public func snapshot() -> PDFSource {
        if let url, !state.isEdited { return .file(url, password: password) }
        if let contents { return contents.snapshot(of: self) }
        return .data(pdf.dataRepresentation() ?? Data(), password: password)
    }
}

/// A page of an open document.
public struct PageRef: Codable, Hashable, Sendable {
    public var documentID: UUID
    /// 0-based.
    public var index: Int

    public init(documentID: UUID, index: Int) { self.documentID = documentID; self.index = index }

    /// The number people see (1-based).
    public var number: Int { index + 1 }
}

/// Page ranges as people type them ("1-3, 7, 9–12"), stored 0-based. Split's "Ranges" field and the scope popup's
/// range both use it.
public struct PageRanges: Codable, Hashable, Sendable {
    public var ranges: [ClosedRange<Int>]

    public init(_ ranges: [ClosedRange<Int>]) { self.ranges = ranges }

    /// Parses 1-based text: numbers and ranges separated by commas or spaces; "-", "–" and "—" between bounds; a
    /// reversed range ("5-3") is normalised. Nil when any part isn't a page in `1...pageCount`.
    public static func parse(_ text: String, pageCount: Int) -> PageRanges? {
        let parts = text.split(whereSeparator: { $0 == "," || $0 == ";" }).map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
        guard !parts.isEmpty else { return nil }
        var result: [ClosedRange<Int>] = []
        for part in parts {
            let bounds = part.split(whereSeparator: { "-–—".contains($0) }).map { $0.trimmingCharacters(in: .whitespaces) }
            guard (1...2).contains(bounds.count), let first = Int(bounds[0]), let last = Int(bounds[bounds.count - 1]),
                  (1...pageCount).contains(first), (1...pageCount).contains(last) else { return nil }
            result.append(min(first, last) - 1 ... max(first, last) - 1)
        }
        return PageRanges(result)
    }

    /// Every index once, in the order given.
    public var indices: [Int] {
        var seen: Set<Int> = []
        return ranges.flatMap { Array($0) }.filter { seen.insert($0).inserted }
    }

    /// "3–5", "1–3, 7" (1-based, en dash).
    public var display: String {
        ranges.map { $0.lowerBound == $0.upperBound ? "\($0.lowerBound + 1)" : "\($0.lowerBound + 1)–\($0.upperBound + 1)" }
            .joined(separator: ", ")
    }
}

/// Which pages a tool works on (ux §5.1): "Pages: All · This page · 3–5 · Selected (4)".
public enum Scope: Codable, Hashable, Sendable {
    case all
    case current
    case ranges(PageRanges)
    case selected([Int])

    /// The 0-based pages this scope covers in a document of `pageCount` pages showing `currentPage`, sorted, unique.
    public func pages(count pageCount: Int, current currentPage: Int) -> [Int] {
        let valid = 0..<pageCount
        let pages: [Int] = switch self {
        case .all: Array(valid)
        case .current: [currentPage]
        case .ranges(let ranges): ranges.indices
        case .selected(let selection): selection
        }
        return Array(Set(pages.filter { valid.contains($0) })).sorted()
    }
}

/// The views of the main window's PDFView (ux §8 View menu).
public enum DisplayMode: String, Codable, CaseIterable, Sendable {
    case continuousScroll, singlePage, twoPages
}

/// Sidebar modes (ux §2.1, §6.3). Search and Signatures appear only while searching / when the file is signed.
public enum SidebarMode: String, Codable, CaseIterable, Sendable {
    case thumbnails, tableOfContents, highlightsAndNotes, bookmarks, attachments, search, signatures
}

/// Per-document view state, kept in the file's extended attribute `SuperPDFPaths.viewStateAttribute` (never inside
/// the PDF) and restored on open (features §2.1).
public struct DocumentViewState: Codable, Hashable, Sendable {
    public var pageIndex: Int
    /// PDFView scale; nil means the default zoom setting.
    public var scale: Double?
    public var displayMode: DisplayMode
    public var sidebarMode: SidebarMode
    public var sidebarVisible: Bool
    public var sidebarWidth: Double

    public init(pageIndex: Int = 0, scale: Double? = nil, displayMode: DisplayMode = .continuousScroll,
                sidebarMode: SidebarMode = .thumbnails, sidebarVisible: Bool = true, sidebarWidth: Double = 197) {
        self.pageIndex = pageIndex; self.scale = scale; self.displayMode = displayMode; self.sidebarMode = sidebarMode
        self.sidebarVisible = sidebarVisible; self.sidebarWidth = sidebarWidth
    }
}

/// A row of the welcome window's Recent list (ux §6.1).
public struct RecentDocument: Codable, Hashable, Identifiable, Sendable {
    public var url: URL
    public var lastOpened: Date
    public var pageCount: Int
    public var fileSize: Int64

    public var id: URL { url }
    public var name: String { url.lastPathComponent }

    public init(url: URL, lastOpened: Date, pageCount: Int, fileSize: Int64) {
        self.url = url; self.lastOpened = lastOpened; self.pageCount = pageCount; self.fileSize = fileSize
    }
}

/// What DocumentKit announces about open documents.
public enum DocumentEvent: Equatable, Sendable {
    case opened(UUID)
    case closed(UUID)
    /// Pages, annotations or bytes changed (in-place tool results, undo, redo).
    case changed(UUID)
    case saved(UUID)
}
