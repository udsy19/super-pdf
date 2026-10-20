import SuperPDFCore

/// FormsKit: fill (AF* emulation, AutoFill), make a form, form data and templates (docs/ARCHITECTURE.md, WP10). It
/// registers `Services.forms` (`FormServicing`), and appends its `ToolProviding` for `ToolCatalog.tiles(ownedBy:
/// .formsKit)` to `Services.toolProviders`.
///
/// Placeholder: `install()` registers nothing until WP10 replaces this file, keeping `install()` registering exactly
/// these services.
public enum FormsKitModule {
    @MainActor public static func install() {}
}
