import SuperPDFCore

/// DocumentKit: NSDocument, open/repair/password flows, the save policy, output naming, versions, page-operation undo,
/// recents and view state (docs/ARCHITECTURE.md, WP3). It registers `Services.documents` (`DocumentManaging`).
///
/// Placeholder: `install()` registers nothing until WP3 replaces this file, keeping `install()` registering exactly
/// these services.
public enum DocumentKitModule {
    @MainActor public static func install() {}
}
