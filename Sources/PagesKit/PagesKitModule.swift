import SuperPDFCore

/// PagesKit: page tools (docs/ARCHITECTURE.md, WP6). It registers `Services.pages` (`PageEditing`), and appends its
/// `ToolProviding` for `ToolCatalog.tiles(ownedBy: .pagesKit)` to `Services.toolProviders`.
///
/// Placeholder: `install()` registers nothing until WP6 replaces this file, keeping `install()` registering exactly
/// these services.
public enum PagesKitModule {
    @MainActor public static func install() {}
}
