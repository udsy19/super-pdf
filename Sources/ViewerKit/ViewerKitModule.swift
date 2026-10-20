import SuperPDFCore

/// ViewerKit: the main window, toolbar, sidebar modes, PDFView host, reader, read aloud, find, page organiser, result
/// banner, welcome window and drag and drop (docs/ARCHITECTURE.md, WP4). It registers `Services.viewer`
/// (`ViewerPresenting`), and appends its `ToolProviding` for `ToolCatalog.tiles(ownedBy: .viewerKit)` to
/// `Services.toolProviders`.
///
/// Placeholder: `install()` registers nothing until WP4 replaces this file, keeping `install()` registering exactly
/// these services.
public enum ViewerKitModule {
    @MainActor public static func install() {}
}
