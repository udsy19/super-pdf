import SuperPDFCore

/// FormsKit: fill (AF* emulation, AutoFill from the Contacts "Me" card), make a form (field finding through LayoutKit,
/// the palette, properties, tab order) and form data (docs/ARCHITECTURE.md, WP10). It registers `Services.forms`
/// (`FormServicing`), watches what people type into fields, and appends its `ToolProviding` for
/// `ToolCatalog.tiles(ownedBy: .formsKit)` to `Services.toolProviders`.
public enum FormsKitModule {
    /// Kept for the app's lifetime.
    @MainActor private static var watcher: FormWatcher?

    @MainActor public static func install() {
        let service = FormService()
        if let documents = Services.documents { service.watch(documents) }
        Services.forms = service
        watcher = FormWatcher(service: service)
        Services.toolProviders.append(FormsTools(service: service, contactCard: ContactsCard()))
    }
}
