import SuperPDFCore

/// FixKit: make smaller, OCR, repair, fast web view, fonts, PDF/A and print checks, output preview, accessibility,
/// compare (docs/ARCHITECTURE.md, WP13). It registers `Services.fix` (`Fixing`), and appends its `ToolProviding` for
/// `ToolCatalog.tiles(ownedBy: .fixKit)` to `Services.toolProviders`.
public enum FixKitModule {
    @MainActor public static func install() {
        let service = FixService()
        Services.fix = service
        Services.toolProviders.append(FixTools(service: service))
    }
}
