import SuperPDFCore

/// SignKit: the signature library, certificate signing and verification, certificates, request signatures
/// (docs/ARCHITECTURE.md, WP11). It registers `Services.sign` (`Signing`), `Services.requests` (`SignatureRequesting`),
/// and appends its `ToolProviding` for `ToolCatalog.tiles(ownedBy: .signKit)` to `Services.toolProviders`.
///
/// Placeholder: `install()` registers nothing until WP11 replaces this file, keeping `install()` registering exactly
/// these services.
public enum SignKitModule {
    @MainActor public static func install() {}
}
