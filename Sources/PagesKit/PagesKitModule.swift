import SuperPDFCore

/// PagesKit: page tools (docs/ARCHITECTURE.md, WP6; features §1.2). It registers `Services.pages` (`PageEditing`), and
/// appends its `ToolProviding` for `ToolCatalog.tiles(ownedBy: .pagesKit)` to `Services.toolProviders`.
public enum PagesKitModule {
    @MainActor public static func install() {
        let editor = PageEditor()
        Services.pages = editor
        Services.toolProviders.append(PagesTools(editor: editor))
    }
}
