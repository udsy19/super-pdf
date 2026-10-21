import SuperPDFCore

/// ScanKit: Continuity Camera, Image Capture scanners, document detection and scan clean-up (docs/ARCHITECTURE.md,
/// WP14). It registers `Services.scan` (`Scanning`), and appends its `ToolProviding` for `ToolCatalog.tiles(ownedBy:
/// .scanKit)` to `Services.toolProviders`.
public enum ScanKitModule {
    @MainActor public static func install() {
        let service = ScanService()
        Services.scan = service
        Services.toolProviders.append(ScanTools(service: service))
    }
}
