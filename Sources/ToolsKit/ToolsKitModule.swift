import SuperPDFCore

/// ToolsKit: the Tools sheet, the panel host and archetypes A–G, scope, live preview, progress, favourites, frecency
/// and search (docs/ARCHITECTURE.md, WP5). It registers `Services.tools` (`ToolRegistry`), after collecting
/// `Services.toolProviders` and checking that every catalog tile has exactly one provider.
///
/// Placeholder: `install()` registers nothing until WP5 replaces this file, keeping `install()` registering exactly
/// these services.
public enum ToolsKitModule {
    @MainActor public static func install() {}
}
