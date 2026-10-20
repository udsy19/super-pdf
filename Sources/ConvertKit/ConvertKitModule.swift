import SuperPDFCore

/// ConvertKit: the conversion registry runtime, native importers, the LibreOffice helper, app automation and the
/// exporters (docs/ARCHITECTURE.md, WP7). It registers `Services.convert` (`Converting`), `Services.helpers`
/// (`HelperManaging`), and appends its `ToolProviding` for `ToolCatalog.tiles(ownedBy: .convertKit)` to
/// `Services.toolProviders`.
///
/// Placeholder: `install()` registers nothing until WP7 replaces this file, keeping `install()` registering exactly
/// these services.
public enum ConvertKitModule {
    @MainActor public static func install() {}
}
