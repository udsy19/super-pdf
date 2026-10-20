import SuperPDFCore

/// RenderKit: Quartz rendering and writing (shared analysis module, no app policy) (docs/ARCHITECTURE.md, WP2). It
/// registers `Services.render` (`Rendering`).
///
/// Placeholder: `install()` registers nothing until WP2 replaces this file, keeping `install()` registering exactly
/// these services.
public enum RenderKitModule {
    @MainActor public static func install() {}
}
