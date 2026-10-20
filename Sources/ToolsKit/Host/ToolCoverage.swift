import Foundation
import SuperPDFCore

/// Every catalog tile has exactly one provider (ARCHITECTURE "Launch sequence"): which providers serve which tiles, and
/// what is wrong with the set.
public enum ToolCoverage {
    public enum Issue: Hashable, CustomStringConvertible {
        /// No provider serves this tile.
        case missing(ToolID)
        /// More than one provider claims this tile.
        case duplicate(ToolID)
        /// A provider serves some of a module's tiles but not these.
        case incomplete(ModuleID, missing: [ToolID])
        /// One provider claims tiles that different modules own.
        case mixedOwners([ModuleID])

        public var description: String {
            switch self {
            case .missing(let tool): "no provider for \(tool.rawValue)"
            case .duplicate(let tool): "several providers for \(tool.rawValue)"
            case .incomplete(let module, let missing): "\(module.rawValue) leaves out \(missing.map(\.rawValue).joined(separator: ", "))"
            case .mixedOwners(let modules): "one provider spans \(modules.map(\.rawValue).joined(separator: ", "))"
            }
        }
    }

    /// The provider of each tile; the first registered wins a duplicate.
    @MainActor
    public static func map(_ providers: [any ToolProviding]) -> [ToolID: any ToolProviding] {
        var map: [ToolID: any ToolProviding] = [:]
        for provider in providers { for tool in provider.tools where map[tool] == nil { map[tool] = provider } }
        return map
    }

    /// What is wrong. `requireAll` adds a `.missing` issue per unserved tile; without it only the modules that
    /// registered a provider are held to covering all their tiles (while other modules are still placeholders).
    @MainActor
    public static func issues(_ providers: [any ToolProviding], requireAll: Bool) -> [Issue] {
        var issues: [Issue] = []
        var claims: [ToolID: Int] = [:]
        var owners: Set<ModuleID> = []
        for provider in providers {
            let modules = Set(provider.tools.map { ToolCatalog.tile($0).owner })
            if modules.count > 1 { issues.append(.mixedOwners(modules.sorted { $0.rawValue < $1.rawValue })) }
            owners.formUnion(modules)
            for tool in Set(provider.tools) { claims[tool, default: 0] += 1 }
        }
        for tile in ToolCatalog.tiles {
            let count = claims[tile.id] ?? 0
            if count > 1 { issues.append(.duplicate(tile.id)) }
            if count == 0 && requireAll { issues.append(.missing(tile.id)) }
        }
        if !requireAll {
            for module in owners.sorted(by: { $0.rawValue < $1.rawValue }) {
                let missing = ToolCatalog.tiles(ownedBy: module).map(\.id).filter { claims[$0] == nil }
                if !missing.isEmpty { issues.append(.incomplete(module, missing: missing)) }
            }
        }
        return issues
    }
}
