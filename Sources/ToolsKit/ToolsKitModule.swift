import Foundation
import SuperPDFCore

/// ToolsKit: the Tools sheet, the panel host and archetypes A–E and G, scope, live preview, progress, favourites,
/// frecency and search (docs/ARCHITECTURE.md, WP5). It registers `Services.tools` (`ToolRegistry`); providers are read
/// from `Services.toolProviders` when first needed, and once every module has installed the coverage (exactly one
/// provider per catalog tile) is checked and any gap logged.
public enum ToolsKitModule {
    @MainActor public static func install() {
        let controller = ToolsController()
        Services.tools = controller
        // ViewerKit and SettingsKit install after ToolsKit; check when the launch sequence is done.
        DispatchQueue.main.async { controller.reportCoverage() }
    }
}
