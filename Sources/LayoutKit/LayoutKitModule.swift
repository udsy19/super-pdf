import SuperPDFCore

/// LayoutKit: text and layout analysis (shared analysis module, no app policy) (docs/ARCHITECTURE.md, WP2). It
/// registers `Services.layout` (`LayoutAnalyzing`).
///
/// Placeholder: `install()` registers nothing until WP2 replaces this file, keeping `install()` registering exactly
/// these services.
public enum LayoutKitModule {
    @MainActor public static func install() {}
}
