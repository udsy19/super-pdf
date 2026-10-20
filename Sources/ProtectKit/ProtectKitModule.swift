import SuperPDFCore

/// ProtectKit: passwords and permissions, redaction, hidden information, certificate encryption, security envelope and
/// flatten (docs/ARCHITECTURE.md, WP12). It registers `Services.protect` (`Protecting`), and appends its
/// `ToolProviding` for `ToolCatalog.tiles(ownedBy: .protectKit)` to `Services.toolProviders`.
///
/// Placeholder: `install()` registers nothing until WP12 replaces this file, keeping `install()` registering exactly
/// these services.
public enum ProtectKitModule {
    @MainActor public static func install() {}
}
