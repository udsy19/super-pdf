import Foundation

// The tool host contract (ARCHITECTURE "Rules", ux §4–§5). Modules implement `ToolProviding` for the catalog tiles they
// own and append it to `Services.toolProviders` in `install()`; ToolsKit (`Services.tools`) collects them, renders the
// Tools sheet and the panels, and runs the requests. WP5 announces the host details for wave C.

/// One module's tools: their panels, live previews and runs.
@MainActor
public protocol ToolProviding: AnyObject {
    /// The catalog tiles this provider serves (`ToolTile.owner` is this module).
    var tools: [ToolID] { get }
    /// Whether a tile can run now; unavailable tiles still open and explain (ux §4).
    func availability(of tool: ToolID) -> ToolAvailability
    /// The panel for the current context; asked again whenever a value, the scope or the selection changes.
    func panel(for tool: ToolID, context: ToolContext) -> ToolPanel
    /// The live effect for the current values (ux §5.1), recomputed at most every 80 ms (ux §2.5).
    func preview(for tool: ToolID, context: ToolContext) async -> ToolPreview
    /// A panel button (`ToolControl.action`) or a message's action was pressed; returns the values to continue with.
    func handle(action: String, context: ToolContext) async throws -> ToolValues
    /// Does the work. Engine work runs off the main actor on `request.source`; PDFKit edits stay on the main actor.
    /// Throw `ToolError` for the panel's error copy; cancellation (Stop) cancels the task.
    func run(_ request: ToolRequest, progress: ToolProgress) async throws -> ToolResult
}

public extension ToolProviding {
    func availability(of tool: ToolID) -> ToolAvailability { .ready }
    func preview(for tool: ToolID, context: ToolContext) async -> ToolPreview { .none }
    func handle(action: String, context: ToolContext) async throws -> ToolValues { context.values }
}

/// A failure a panel shows above its footer (ux §5.1, §7.4): the copy, and the action that fixes it when there is one.
public struct ToolError: LocalizedError, Hashable {
    public var message: ToolMessage

    public init(_ message: ToolMessage) { self.message = message }
    public init(_ text: String, action: ToolOption? = nil, details: String? = nil) {
        message = ToolMessage(.error, text, action: action, details: details)
    }

    public var errorDescription: String? { message.text }
}

/// The Tools sheet, the panel host and the provider registry (ToolsKit; ux §4, §5).
@MainActor
public protocol ToolRegistry: AnyObject {
    /// The provider serving a tile; every catalog tile has exactly one after ToolsKit's install.
    func provider(for tool: ToolID) -> (any ToolProviding)?
    /// Live search over names, hints and synonyms (ux §4); the first result is what Return runs.
    func search(_ query: String) -> [ToolTile]
    /// Up to five tiles by frecency; empty on first launch (ux §4).
    var recentlyUsed: [ToolTile] { get }
    func recordUse(_ tool: ToolID)
    /// ⌘T, the toolbar's Tools button, Tools › All Tools…, the Dock menu.
    func showToolsSheet(for document: DocumentHandle?)
    /// Opens a tile's panel directly (toolbar favourites, menus, thumbnail context menu, a drop on a tile).
    func openPanel(_ tool: ToolID, for document: DocumentHandle?, inputs: [URL])
    func closePanel(for document: DocumentHandle)
}
