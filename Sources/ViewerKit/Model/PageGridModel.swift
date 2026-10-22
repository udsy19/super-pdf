import Foundation
import SuperPDFCore

/// A file whose pages were mixed into the document (a drop in the workspace, Combine from the welcome window). Until the
/// document is saved its pages keep the file's name and colour: its card and pill in the workspace (ux §6.2).
public struct PageOrigin: Hashable, Sendable {
    public var fileName: String
    /// Index into `PageOrigin.palette`.
    public var colorIndex: Int

    public init(fileName: String, colorIndex: Int) { self.fileName = fileName; self.colorIndex = colorIndex }

    /// The pill colours, in the order files arrive; the document's own pages take the first.
    public static var palette: [SPPill] { SPColor.pills }
    public var pill: SPPill { Self.palette[colorIndex % Self.palette.count] }
}

/// The page list the thumbnail sidebar and the workspace show, their selection, and the page edits their gestures
/// make (ux §3, §6.2, §6.3). Pure value: the views keep one, ask it for the `PageOperation` a gesture means, run it
/// through `Services.pages`, then apply the same change here so selection follows the pages.
public struct PageGridModel: Equatable, Sendable {
    public struct Entry: Hashable, Sendable {
        /// Stable identity of the page while it moves (the PDFPage's object identity in the app).
        public var key: Int
        public var origin: PageOrigin?

        public init(key: Int, origin: PageOrigin? = nil) { self.key = key; self.origin = origin }
    }

    public private(set) var entries: [Entry]
    public private(set) var selection: IndexSet

    public init(entries: [Entry], selection: IndexSet = []) {
        self.entries = entries
        self.selection = selection.filteredIndexSet { $0 < entries.count }
    }

    /// A document's pages with no mixed-in files.
    public init(pageCount: Int) { self.init(entries: (0..<pageCount).map { Entry(key: $0) }) }

    public var count: Int { entries.count }
    /// Selected pages, 0-based and sorted.
    public var selected: [Int] { Array(selection) }

    // MARK: Selection

    /// The selection the collection view reports (clicks with ⌘ and ⇧, rubber band) or a reload restores.
    public mutating func select(_ indices: IndexSet) {
        selection = indices.filteredIndexSet { $0 < entries.count }
    }

    // MARK: Moving

    /// Where the first of `pages` lands when they are dropped in the gap before `gap` (0…count): the `to` of
    /// `PageOperation.move`, which counts in the document after the pages are taken out.
    public static func destination(of pages: [Int], toGap gap: Int) -> Int {
        gap - pages.filter { $0 < gap }.count
    }

    /// The edit a drop of `pages` before `gap` makes; nil when nothing would move (dropped back where they are).
    public func move(_ pages: [Int], toGap gap: Int) -> PageOperation? {
        let pages = Array(Set(pages.filter { entries.indices.contains($0) })).sorted()
        guard !pages.isEmpty, (0...entries.count).contains(gap) else { return nil }
        let to = Self.destination(of: pages, toGap: gap)
        let contiguous = pages.last! - pages.first! == pages.count - 1
        if contiguous && to == pages.first! { return nil }
        return .move(pages, to: to)
    }

    /// Mirrors `move`: the pages leave their places and land together; they stay selected.
    public mutating func applyMove(_ pages: [Int], toGap gap: Int) {
        guard case .move(let sorted, let to)? = move(pages, toGap: gap) else { return }
        let moving = sorted.map { entries[$0] }
        for index in sorted.reversed() { entries.remove(at: index) }
        entries.insert(contentsOf: moving, at: to)
        select(IndexSet(integersIn: to..<to + moving.count))
    }

    // MARK: Inserting

    /// Pages of another file before `gap` (all of them when `pages` is empty).
    public func insertion(of source: PDFSource, pages: [Int] = [], atGap gap: Int) -> PageOperation {
        .insertFile(source, pages: pages, at: min(max(gap, 0), entries.count))
    }

    /// Mirrors an insertion of `keys.count` pages from `origin` (nil: pages of this document, such as a copy from another
    /// window, which carry no bar); the new pages become the selection.
    public mutating func applyInsert(keys: [Int], atGap gap: Int, origin: PageOrigin?) {
        let at = min(max(gap, 0), entries.count)
        entries.insert(contentsOf: keys.map { Entry(key: $0, origin: origin) }, at: at)
        select(IndexSet(integersIn: at..<at + keys.count))
    }

    /// The colour index the next mixed-in file gets: the first one no file uses yet (the document's own pages use the
    /// first colour).
    public var nextOriginColor: Int {
        var used = Set(entries.compactMap { $0.origin?.colorIndex })
        if entries.contains(where: { $0.origin == nil }) { used.insert(0) }
        return (0...).first { !used.contains($0) }! % PageOrigin.palette.count
    }

    // MARK: Deleting, rotating, duplicating

    /// Never the last page (ux §5.3).
    public func deletion(_ pages: [Int]) throws -> PageOperation {
        let pages = Array(Set(pages.filter { entries.indices.contains($0) })).sorted()
        guard !pages.isEmpty else { throw PageEditError.pagesOutOfRange }
        guard pages.count < entries.count else { throw PageEditError.lastPage }
        return .delete(pages)
    }

    public mutating func applyDelete(_ pages: [Int]) {
        guard (try? deletion(pages)) != nil else { return }
        let removed = Set(pages)
        let first = removed.min() ?? 0
        entries = entries.enumerated().filter { !removed.contains($0.offset) }.map(\.element)
        select(entries.isEmpty ? [] : [min(first, entries.count - 1)])
    }

    /// ⌘L is −1 (counter-clockwise), ⌘R +1 (Preview's keys).
    public func rotation(_ pages: [Int], quarterTurns: Int) -> PageOperation {
        .rotate(Array(Set(pages.filter { entries.indices.contains($0) })).sorted(), quarterTurns: quarterTurns)
    }
}
