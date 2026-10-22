import CoreGraphics
import Foundation
import SuperPDFCore
import UniformTypeIdentifiers

// What a drop does, decided in one place for every target of ux §3 (the window, the sidebar between thumbnails, the
// workspace, the welcome window). The views only describe what is being dragged and where; this table answers
// with the outcome and the two or three words the target shows ("Add 3 pages here").

/// A file being dragged in, with the facts the decision needs (read once per drag).
public struct DroppedFile: Hashable, Sendable {
    public var url: URL
    public var isDirectory: Bool
    public var isPDF: Bool
    /// Can become a PDF (ConvertKit's `canConvertToPDF`); PDFs always can.
    public var canConvert: Bool
    /// Pages in a PDF; nil for files that convert first (the count isn't known yet).
    public var pageCount: Int?

    public init(url: URL, isDirectory: Bool = false, isPDF: Bool, canConvert: Bool, pageCount: Int? = nil) {
        self.url = url; self.isDirectory = isDirectory; self.isPDF = isPDF; self.canConvert = canConvert || isPDF; self.pageCount = pageCount
    }

    /// Looks at a file on disk; `canConvert` asks ConvertKit about non-PDF files.
    public init(url: URL, canConvert: (URL) -> Bool) {
        let values = try? url.resourceValues(forKeys: [.isDirectoryKey, .contentTypeKey])
        let isDirectory = values?.isDirectory ?? false
        let type = values?.contentType ?? UTType(filenameExtension: url.pathExtension)
        let isPDF = !isDirectory && (type?.conforms(to: .pdf) ?? false)
        self.init(url: url, isDirectory: isDirectory, isPDF: isPDF, canConvert: !isDirectory && !isPDF && canConvert(url),
                  pageCount: isPDF ? CGPDFDocument(url as CFURL)?.numberOfPages : nil)
    }
}

/// Where the pointer is.
public enum DropZone: Hashable, Sendable {
    /// The document well of a window.
    case pageArea
    /// The thumbnail sidebar, in the gap before this page (`pageCount` is the end).
    case sidebarGap(Int)
    /// The workspace (ux §6.2), in the gap before this page (`pageCount` is the end and the add card).
    case workspaceGap(Int)
    /// Anywhere in the welcome window.
    case welcome
}

/// What is being dragged.
public enum DropPayload: Hashable, Sendable {
    case files([DroppedFile])
    /// Thumbnails from a document window (this one or another), 0-based.
    case pages(from: UUID, indices: [Int])
    case text(String)
}

public enum DropOutcome: Hashable, Sendable {
    /// Nothing happens and nothing lights up.
    case none
    /// The "not allowed" cursor, with the reason as a tooltip (ux §3 rules).
    case refuse(String)
    /// Open each file in its own window or tab (PDFs directly, others converted first).
    case open([URL])
    /// Several files dropped on the welcome window: the workspace with one card per file (ux §6.1, §6.2).
    case combine([URL])
    /// Insert the files' pages before this page (converting first when needed).
    case insertFiles([URL], atGap: Int)
    /// Reorder this document's pages.
    case movePages([Int], toGap: Int)
    /// Pages from another window: copied, or moved with ⌥ (ux §3).
    case copyPages(from: UUID, [Int], toGap: Int, removingFromSource: Bool)
    /// Text dropped on a page: a new text box.
    case addText(String)
}

public struct DropDecision: Hashable, Sendable {
    public var outcome: DropOutcome
    /// The target's two or three words; nil when only the insertion line or ring shows.
    public var label: String?

    public init(_ outcome: DropOutcome, label: String? = nil) { self.outcome = outcome; self.label = label }

    public var isAllowed: Bool {
        switch outcome {
        case .none, .refuse: false
        default: true
        }
    }

    /// The table of ux §3. `document` is the target window's document (nil for the welcome window); `isLocked` is an
    /// encrypted document that has not been unlocked; `optionKey` is ⌥ held (move instead of copy between windows).
    public static func decide(_ payload: DropPayload, onto zone: DropZone, of document: UUID? = nil, isLocked: Bool = false,
                              optionKey: Bool = false) -> DropDecision {
        switch payload {
        case .files(let files):
            return decideFiles(files, zone: zone, isLocked: isLocked)
        case .pages(let source, let indices):
            guard !indices.isEmpty else { return DropDecision(.none) }
            let gap: Int
            switch zone {
            case .sidebarGap(let g), .workspaceGap(let g): gap = g
            case .pageArea, .welcome: return DropDecision(.none)
            }
            if source == document {
                let pages = Array(Set(indices)).sorted()
                let to = PageGridModel.destination(of: pages, toGap: gap)
                let contiguous = pages.last! - pages.first! == pages.count - 1
                return contiguous && to == pages.first! ? DropDecision(.none) : DropDecision(.movePages(pages, toGap: gap))
            }
            if isLocked { return DropDecision(.refuse(Strings.Errors.passwordPrompt)) }
            return DropDecision(.copyPages(from: source, indices, toGap: gap, removingFromSource: optionKey),
                                label: Strings.Drop.addPages(indices.count))
        case .text(let text):
            guard zone == .pageArea, !text.isEmpty else { return DropDecision(.none) }
            if isLocked { return DropDecision(.refuse(Strings.Errors.passwordPrompt)) }
            return DropDecision(.addText(text), label: Strings.Drop.addText)
        }
    }

    private static func decideFiles(_ files: [DroppedFile], zone: DropZone, isLocked: Bool) -> DropDecision {
        guard !files.isEmpty else { return DropDecision(.none) }
        if files.contains(where: \.isDirectory) { return DropDecision(.refuse(Strings.Drop.cantAddFolder)) }
        if let stranger = files.first(where: { !$0.canConvert }) {
            return DropDecision(.refuse(Strings.Errors.notConvertible(stranger.url.pathExtension.lowercased())))
        }
        let urls = files.map(\.url)
        switch zone {
        case .pageArea:
            return DropDecision(.open(urls), label: Strings.Drop.open)
        case .welcome:
            return urls.count == 1 ? DropDecision(.open(urls), label: Strings.Drop.open)
                : DropDecision(.combine(urls), label: ViewerStrings.Welcome.combine)
        case .sidebarGap(let gap), .workspaceGap(let gap):
            if isLocked { return DropDecision(.refuse(Strings.Errors.passwordPrompt)) }
            let counts = files.map(\.pageCount)
            let label = counts.contains(nil) ? Strings.Drop.addHere : Strings.Drop.addPages(counts.compactMap { $0 }.reduce(0, +))
            return DropDecision(.insertFiles(urls, atGap: gap), label: label)
        }
    }
}
