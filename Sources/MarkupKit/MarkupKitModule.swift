import SuperPDFCore

/// MarkupKit: Preview's markup bar, annotations with their own appearance streams, comments review, attachments,
/// measure and snapshot (docs/ARCHITECTURE.md, WP9). It registers `Services.markup` (`Annotating`) and appends its
/// `ToolProviding` for `ToolCatalog.tiles(ownedBy: .markupKit)` to `Services.toolProviders`.
public enum MarkupKitModule {
    @MainActor public static func install() {
        let service = MarkupService()
        Services.markup = service
        Services.toolProviders.append(MarkupToolProvider(service: service))
    }
}
