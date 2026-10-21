import SuperPDFCore

/// ConvertKit: the conversion registry runtime, native importers, the LibreOffice helper, app automation and the
/// exporters (docs/ARCHITECTURE.md, WP7). It registers `Services.convert` (`Converting`) and `Services.helpers`
/// (`HelperManaging`), and appends its `ToolProviding` for `ToolCatalog.tiles(ownedBy: .convertKit)` to
/// `Services.toolProviders`.
public enum ConvertKitModule {
    @MainActor public static func install() {
        let helpers = HelperService()
        let service = ConvertService(helpers: helpers)
        Services.helpers = helpers
        Services.convert = service
        Services.toolProviders.append(ConvertToolProvider(service: service))
    }
}
