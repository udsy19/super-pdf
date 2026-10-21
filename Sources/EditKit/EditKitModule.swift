import SuperPDFCore

/// EditKit: edit text and images, headers and footers, Bates, watermark, background, stamps, links, optional content,
/// scripts, document properties, page transitions and named destinations (docs/ARCHITECTURE.md, WP8). It registers
/// `Services.edit` (`ContentEditing`) and appends its `ToolProviding` for `ToolCatalog.tiles(ownedBy: .editKit)` to
/// `Services.toolProviders`.
public enum EditKitModule {
    @MainActor public static func install() {
        let service = EditService()
        Services.edit = service
        Services.toolProviders.append(EditToolProvider(service: service))
    }
}
