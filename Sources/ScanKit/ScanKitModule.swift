import SuperPDFCore

/// ScanKit: Continuity Camera, Image Capture scanners, document detection and scan clean-up (docs/ARCHITECTURE.md,
/// WP14). It registers `Services.scan` (`Scanning`), and appends its `ToolProviding` for `ToolCatalog.tiles(ownedBy:
/// .scanKit)` to `Services.toolProviders`.
///
/// Placeholder: `install()` registers nothing until WP14 replaces this file, keeping `install()` registering exactly
/// these services.
public enum ScanKitModule {
    @MainActor public static func install() {}
}
