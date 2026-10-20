import SuperPDFCore

/// BatchKit: "Do this to many files": pipelines, routines, Quick Actions and App Intents plumbing
/// (docs/ARCHITECTURE.md, WP16). It registers `Services.batch` (`BatchRunning`), and appends its `ToolProviding` for
/// `ToolCatalog.tiles(ownedBy: .batchKit)` to `Services.toolProviders`.
///
/// Placeholder: `install()` registers nothing until WP16 replaces this file, keeping `install()` registering exactly
/// these services.
public enum BatchKitModule {
    @MainActor public static func install() {}
}
