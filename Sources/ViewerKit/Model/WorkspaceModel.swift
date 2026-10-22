import Foundation
import SuperPDFCore

// The workspace (ux §6.2) as values: Combine and Rearrange show the document's pages as cards, either one card per
// file (Files) or one per page (Pages). A page's file is the file it was mixed in from (its `PageOrigin`), or the
// document itself. Files converting to PDF wait as cards of their own. The views keep one of these and ask it what to
// show, which pages a gesture means and where they go; the edits run through `PageActions`.

public enum WorkspaceMode: String, CaseIterable, Sendable {
    case files, pages
}

public enum WorkspaceLayout: String, CaseIterable, Sendable {
    case grid, list
}

/// The Sort menu (ux §6.2): files by name either way, or everything back to front.
public enum WorkspaceSort: String, CaseIterable, Sendable {
    case nameAscending, nameDescending, reverse
}

/// A file being turned into a PDF before its pages go in (ux §6.2: "conversion progress on the card").
public struct PendingFile: Hashable, Sendable, Identifiable {
    public var id: UUID
    public var name: String
    public var colorIndex: Int
    /// The gap (0…page count) its pages will go into.
    public var gap: Int
    /// How far the conversion is, when the converter says; nil while it can't tell.
    public var fraction: Double?

    public init(id: UUID = UUID(), name: String, colorIndex: Int, gap: Int, fraction: Double? = nil) {
        self.id = id; self.name = name; self.colorIndex = colorIndex; self.gap = gap; self.fraction = fraction
    }
}

/// One card's identity, stable while cards move, so the views can animate them to their new places.
public enum WorkspaceItemID: Hashable, Sendable {
    case file(PageOrigin)
    case page(key: Int)
    case pending(UUID)
    /// The dashed "Add files" card at the end.
    case add
}

/// One card.
public enum WorkspaceItem: Hashable, Sendable {
    /// Every page of one file, in document order.
    case file(PageOrigin, pages: [Int])
    /// One page (0-based) and the file it came from.
    case page(Int, key: Int, file: PageOrigin)
    case pending(PendingFile)
    case add

    public var id: WorkspaceItemID {
        switch self {
        case .file(let origin, _): .file(origin)
        case .page(_, let key, _): .page(key: key)
        case .pending(let file): .pending(file.id)
        case .add: .add
        }
    }

    /// The document pages the card stands for (none for a converting file or the add card).
    public var pages: [Int] {
        switch self {
        case .file(_, let pages): pages
        case .page(let index, _, _): [index]
        case .pending, .add: []
        }
    }

    /// Cards that can be selected, dragged and edited.
    public var isContent: Bool { !pages.isEmpty }
}

public struct WorkspaceModel: Equatable, Sendable {
    public var entries: [PageGridModel.Entry]
    /// The name the document's own pages carry (its file name).
    public var documentName: String
    public var pending: [PendingFile]

    public init(entries: [PageGridModel.Entry], documentName: String, pending: [PendingFile] = []) {
        self.entries = entries; self.documentName = documentName; self.pending = pending
    }

    /// The file a page belongs to: where it was mixed in from, or the document itself (always the first colour).
    public func file(of index: Int) -> PageOrigin {
        entries[index].origin ?? PageOrigin(fileName: documentName, colorIndex: 0)
    }

    /// Files in the order of their first page, each with its pages.
    public var files: [(origin: PageOrigin, pages: [Int])] {
        var order: [PageOrigin] = []
        var pages: [PageOrigin: [Int]] = [:]
        for index in entries.indices {
            let origin = file(of: index)
            if pages[origin] == nil { order.append(origin) }
            pages[origin, default: []].append(index)
        }
        return order.map { ($0, pages[$0]!) }
    }

    /// The cards of a mode, converting files at their places, and the add card last.
    public func items(_ mode: WorkspaceMode) -> [WorkspaceItem] {
        var items: [WorkspaceItem]
        var starts: [Int]
        switch mode {
        case .files:
            let files = self.files
            items = files.map { .file($0.origin, pages: $0.pages) }
            starts = files.map { $0.pages.first ?? 0 }
        case .pages:
            items = entries.indices.map { .page($0, key: entries[$0].key, file: file(of: $0)) }
            starts = Array(entries.indices)
        }
        // A converting file sits before the first card that starts at or after its gap, in the order they were added.
        for file in pending.reversed() {
            let at = starts.firstIndex { $0 >= file.gap } ?? items.count
            items.insert(.pending(file), at: at)
            starts.insert(file.gap, at: at)
        }
        return items + [.add]
    }

    /// The document gap (0…page count) for a gap between cards (0…cards) once `excluded` cards are taken out: the first
    /// page of the card after the gap, or the end.
    public func pageGap(forCardGap gap: Int, in mode: WorkspaceMode, excluding excluded: Set<WorkspaceItemID> = []) -> Int {
        let cards = items(mode).filter { $0.isContent && !excluded.contains($0.id) }
        guard gap < cards.count else { return entries.count }
        return cards[max(gap, 0)].pages.min() ?? entries.count
    }

    /// Which pages a set of cards means, sorted and once each.
    public func pages(of ids: Set<WorkspaceItemID>, in mode: WorkspaceMode) -> [Int] {
        Array(Set(items(mode).filter { ids.contains($0.id) }.flatMap(\.pages))).sorted()
    }

    /// The new order of the pages, as runs of current indices, that a sort makes: files by name (each keeps its pages in
    /// order), or everything reversed. Nil when nothing would move.
    public func arrangement(_ sort: WorkspaceSort, in mode: WorkspaceMode) -> [[Int]]? {
        let files = self.files
        let blocks: [[Int]]
        switch sort {
        case .nameAscending, .nameDescending:
            let sorted = files.enumerated().sorted { a, b in
                let order = a.element.origin.fileName.localizedStandardCompare(b.element.origin.fileName)
                if order == .orderedSame { return a.offset < b.offset }
                return sort == .nameAscending ? order == .orderedAscending : order == .orderedDescending
            }
            blocks = sorted.map(\.element.pages)
        case .reverse:
            blocks = mode == .files ? files.reversed().map(\.pages) : entries.indices.reversed().map { [$0] }
        }
        return blocks.flatMap { $0 } == Array(entries.indices) ? nil : blocks
    }

    // MARK: Words

    /// "4 files · 17 pages · 1 selected" (Files) or "17 pages from 4 files · 2 selected" (Pages); a converting file
    /// counts as a file.
    public func statusLine(_ mode: WorkspaceMode, selectedCards: Int) -> String {
        let fileCount = files.count + pending.count
        var parts: [String]
        switch mode {
        case .files: parts = [Formatting.count(fileCount, "file", "files"), ViewerStrings.pages(entries.count)]
        case .pages: parts = [ViewerStrings.pages(entries.count) + (fileCount > 1 ? " from \(Formatting.count(fileCount, "file", "files"))" : "")]
        }
        if selectedCards > 0 { parts.append("\(selectedCards) selected") }
        return parts.joined(separator: " · ")
    }
}
