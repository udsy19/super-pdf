import SuperPDFCore

/// EditKit: edit text and images, headers and footers, Bates, watermark, background, stamps, links, optional content
/// and scripts (docs/ARCHITECTURE.md, WP8). It registers `Services.edit` (`ContentEditing`), and appends its
/// `ToolProviding` for `ToolCatalog.tiles(ownedBy: .editKit)` to `Services.toolProviders`.
///
/// Placeholder: `install()` registers nothing until WP8 replaces this file, keeping `install()` registering exactly
/// these services.
public enum EditKitModule {
    @MainActor public static func install() {}
}
