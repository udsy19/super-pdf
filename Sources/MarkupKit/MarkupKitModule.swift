import SuperPDFCore

/// MarkupKit: Preview's markup bar, appearance streams, comments review, attachments, measure and snapshot
/// (docs/ARCHITECTURE.md, WP9). It registers `Services.markup` (`Annotating`), and appends its `ToolProviding` for
/// `ToolCatalog.tiles(ownedBy: .markupKit)` to `Services.toolProviders`.
///
/// Placeholder: `install()` registers nothing until WP9 replaces this file, keeping `install()` registering exactly
/// these services.
public enum MarkupKitModule {
    @MainActor public static func install() {}
}
