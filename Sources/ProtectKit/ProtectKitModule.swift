import SuperPDFCore

/// ProtectKit: passwords and permissions, redaction, hidden information, certificate encryption, security envelope and
/// flatten (docs/ARCHITECTURE.md, WP12). It registers `Services.protect` (`Protecting`), and appends its
/// `ToolProviding` for `ToolCatalog.tiles(ownedBy: .protectKit)` to `Services.toolProviders`.
public enum ProtectKitModule {
    @MainActor public static func install() {
        let service = ProtectService()
        Services.protect = service
        Services.toolProviders.append(ProtectToolProvider(service: service))
    }
}
