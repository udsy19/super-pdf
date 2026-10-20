import SuperPDFCore

/// ViewerKit: the main window, toolbar, sidebar modes, PDFView host, reader, read aloud, find, page organiser, result
/// banner slot, welcome window, the locked-PDF prompt and drag and drop (docs/ARCHITECTURE.md, WP4). It registers
/// `Services.viewer` (`ViewerPresenting`) and appends its `ToolProviding` for `ToolCatalog.tiles(ownedBy: .viewerKit)`
/// (Contents, Read aloud) to `Services.toolProviders`.
public enum ViewerKitModule {
    @MainActor public static func install() {
        Services.viewer = Viewer.shared
        Services.toolProviders.append(ViewerTools())
    }
}
