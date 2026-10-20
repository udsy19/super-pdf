import Foundation
import SuperPDFCore

/// What the Tools sheet shows (ux §4): Recently used (when there are any, the setting is on and nothing is typed), then
/// the sections in order, filtered live by the search; and where the keyboard is (arrows move, Return opens).
@MainActor
final class ToolsSheetModel {
    struct Group: Equatable {
        /// Nil for "Recently used".
        var section: ToolSection?
        var tiles: [ToolTile]

        var title: String { section?.title ?? Strings.ToolsSheet.recentlyUsed }
    }

    /// A tile's place: which group, which tile in it.
    struct Position: Equatable {
        var group: Int
        var index: Int
    }

    enum Move { case left, right, up, down }

    private(set) var query = ""
    private(set) var groups: [Group] = []
    /// The search's ranking (best first); empty while nothing is typed.
    private(set) var ranked: [ToolTile] = []
    /// The keyboard's tile; while searching it starts on the best match, which Return opens.
    private(set) var selection: Position?

    private let recents: () -> [ToolTile]
    private let boost: (ToolID) -> Double

    init(recents: @escaping () -> [ToolTile], boost: @escaping (ToolID) -> Double = { _ in 0 }) {
        self.recents = recents
        self.boost = boost
        rebuild()
    }

    /// Typing filters every section live; the best match gets the keyboard.
    func search(_ text: String) {
        query = text
        rebuild()
    }

    /// Re-reads Recently used (after a run) keeping the query.
    func reload() { rebuild() }

    private func rebuild() {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty {
            ranked = []
            let recent = Defaults[.showRecentlyUsed] ? Array(recents().prefix(SPMetrics.ToolsSheet.recentTiles)) : []
            groups = (recent.isEmpty ? [] : [Group(section: nil, tiles: recent)])
                + ToolSection.allCases.map { Group(section: $0, tiles: ToolCatalog.tiles(in: $0)) }
            selection = nil
        } else {
            ranked = ToolSearch.rank(trimmed, boost: boost)
            let found = Set(ranked.map(\.id))
            groups = ToolSection.allCases.compactMap { section in
                let tiles = ToolCatalog.tiles(in: section).filter { found.contains($0.id) }
                return tiles.isEmpty ? nil : Group(section: section, tiles: tiles)
            }
            selection = ranked.first.flatMap(position(of:))
        }
    }

    var isEmpty: Bool { groups.isEmpty }

    /// The tile Return opens: the keyboard's, else the best match.
    var returnTarget: ToolTile? {
        if let selection { return tile(at: selection) }
        return ranked.first
    }

    func tile(at position: Position) -> ToolTile? {
        guard groups.indices.contains(position.group), groups[position.group].tiles.indices.contains(position.index) else { return nil }
        return groups[position.group].tiles[position.index]
    }

    func position(of tile: ToolTile) -> Position? {
        for (g, group) in groups.enumerated() where group.section != nil {
            if let i = group.tiles.firstIndex(where: { $0.id == tile.id }) { return Position(group: g, index: i) }
        }
        return nil
    }

    /// Arrow keys across the grid of `columns` tiles per row: left/right step through tiles (wrapping into the next or
    /// previous group), up/down keep the column, crossing into the neighbouring group.
    func move(_ move: Move, columns: Int) {
        guard !groups.isEmpty else { return }
        guard let current = selection else { selection = Position(group: 0, index: 0); return }
        let columns = max(columns, 1)
        let count = groups[current.group].tiles.count
        switch move {
        case .right:
            if current.index + 1 < count { selection = Position(group: current.group, index: current.index + 1) }
            else if current.group + 1 < groups.count { selection = Position(group: current.group + 1, index: 0) }
        case .left:
            if current.index > 0 { selection = Position(group: current.group, index: current.index - 1) }
            else if current.group > 0 { selection = Position(group: current.group - 1, index: groups[current.group - 1].tiles.count - 1) }
        case .down:
            let column = current.index % columns
            if current.index + columns < count { selection = Position(group: current.group, index: current.index + columns) }
            else if (current.index / columns) < (count - 1) / columns { selection = Position(group: current.group, index: count - 1) }
            else if current.group + 1 < groups.count {
                selection = Position(group: current.group + 1, index: min(column, groups[current.group + 1].tiles.count - 1))
            }
        case .up:
            let column = current.index % columns
            if current.index - columns >= 0 { selection = Position(group: current.group, index: current.index - columns) }
            else if current.group > 0 {
                let previous = groups[current.group - 1].tiles.count
                let lastRowStart = ((previous - 1) / columns) * columns
                selection = Position(group: current.group - 1, index: min(lastRowStart + column, previous - 1))
            }
        }
    }

    /// ⌘1–8: the group of a section (Recently used doesn't count).
    func group(of section: ToolSection) -> Int? { groups.firstIndex { $0.section == section } }
}
