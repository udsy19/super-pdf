import AppKit

// The tool host contract (ARCHITECTURE "Rules", ux §4–§5). Modules implement `ToolProviding` for the catalog tiles they
// own and append it to `Services.toolProviders` in `install()`; ToolsKit (`Services.tools`) collects them, renders the
// Tools sheet and the panels, and runs the requests.
//
// How ToolsKit hosts a provider (WP5):
// - Opening a tile builds a `ToolContext` (document, selected thumbnails, page in view, scope, values, dropped files)
//   and asks `panel(for:context:)`. Values start from each control's value, or the remembered choice for that tool.
// - Every change (a value, the scope, the selection, a step) asks `panel(for:)` again at once and `preview(for:)` after
//   80 ms of quiet; the panel is asked again when a preview arrives, so figures a preview computed (estimates) can show.
//   Keep `panel(for:)` cheap and synchronous; do slow work in `preview(for:)` and cache it.
// - `.action` buttons, a message's action and a non-Cancel secondary button call `handle(action:context:)`; its values
//   replace the panel's. A `ToolError` thrown there or from `run` shows above the footer.
// - The primary button builds a `ToolRequest` (scope resolved to pages, `source` = `document.snapshot()`, destination
//   from `DocumentManaging.destination(for:of:source:)` or the place chosen with Change… / the "…" save panel, a fresh
//   `workFolder`), shows the confirmation if any, calls `run` off the panel with progress ("Page 14 of 120 · Stop";
//   Stop cancels the task), then hands the result to `DocumentManaging.apply(_:of:)`, records the use for "Recently
//   used" and closes the panel. Mode panels (D) whose run returns `.none` just close.
// - The live preview: `.overlay` is drawn over every visible page through a `PDFPageOverlayViewProvider` on the
//   document's PDFView (not committed); `.summary` lines show at the top of the panel.
// - Module self-tests drive a provider exactly like this with ToolsKit's `ToolSession` (headless, no window).

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

    /// The result banner (ux §7.3) that ViewerKit's `showBanner` puts in the 44 pt slot under the toolbar and animates
    /// in. ToolsKit draws it and runs its actions (Show in Finder, Share, Undo, Save…, Open in…, Show requests, Show);
    /// it calls `dismiss` after 8 s without the pointer inside, on an action that ends it, or when clicked.
    func makeBannerView(_ banner: ResultBanner, in document: DocumentHandle, dismiss: @escaping @MainActor () -> Void) -> NSView
    /// A toolbar item for a tile (View › Customize Toolbar…, "Add to Toolbar" favourites; ux §2.1, §4); its identifier
    /// is `tool.toolbarItemIdentifier`. ViewerKit lists every tile's identifier as allowed and adds
    /// `Defaults[.toolbarTools]` to the default set, watching that key for new favourites.
    func makeToolbarItem(_ tool: ToolID) -> NSToolbarItem
    /// The Dock menu (ux §4): All Tools… and the tiles added with "Add to Dock Menu" (`Defaults[.dockMenuTools]`).
    func makeDockMenu() -> NSMenu
}

public extension ToolID {
    /// The toolbar item of a tile: "tool.make-smaller".
    var toolbarItemIdentifier: NSToolbarItem.Identifier { NSToolbarItem.Identifier("tool." + rawValue) }

    /// The tile a toolbar item identifier names, if it is a tile's.
    init?(toolbarItemIdentifier identifier: NSToolbarItem.Identifier) {
        guard identifier.rawValue.hasPrefix("tool.") else { return nil }
        self.init(rawValue: String(identifier.rawValue.dropFirst(5)))
    }
}
