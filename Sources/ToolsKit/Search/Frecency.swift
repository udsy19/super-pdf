import Foundation
import SuperPDFCore

/// "Recently used" by frecency (ux §4): each tool keeps its last ten uses, each worth less as it ages, so a tool used
/// daily this week beats one used once yesterday, and old habits fade. Stored in this Mac's defaults only.
public struct Frecency: Codable, Hashable, Sendable {
    /// Use times per tool id (raw value), oldest first.
    public private(set) var uses: [String: [Date]]

    public static let usesKept = 10

    public init(uses: [String: [Date]] = [:]) { self.uses = uses }

    public mutating func record(_ tool: ToolID, at date: Date = Date()) {
        var times = uses[tool.rawValue] ?? []
        times.append(date)
        uses[tool.rawValue] = Array(times.suffix(Self.usesKept))
    }

    /// The sum of each use's weight by age: under 4 days 100, 2 weeks 70, a month 50, 3 months 30, older 10.
    public func score(_ tool: ToolID, now: Date = Date()) -> Double {
        (uses[tool.rawValue] ?? []).reduce(0) { total, date in
            let days = now.timeIntervalSince(date) / 86_400
            return total + (days < 4 ? 100 : days < 14 ? 70 : days < 31 ? 50 : days < 90 ? 30 : 10)
        }
    }

    /// The best `count` tools, ties broken by the latest use.
    public func top(_ count: Int, now: Date = Date()) -> [ToolID] {
        uses.compactMap { key, times -> (ToolID, Double, Date)? in
            guard let tool = ToolID(rawValue: key), let last = times.last else { return nil }
            return (tool, score(tool, now: now), last)
        }
        .sorted { $0.1 != $1.1 ? $0.1 > $1.1 : $0.2 > $1.2 }
        .prefix(count).map(\.0)
    }
}

extension Defaults.Keys {
    /// ToolsKit's frecency table (module-private, ARCHITECTURE "Rules").
    static let frecency = Key<Frecency>("toolsKit.frecency", default: Frecency())
}
