import AppKit
import SuperPDFCore
import DocumentKit
import LayoutKit
import RenderKit
import PagesKit
import ConvertKit
import EditKit
import MarkupKit
import FormsKit
import SignKit
import ProtectKit
import FixKit
import ScanKit
import BatchKit
import ToolsKit
import ViewerKit
import SettingsKit

/// The app shell (docs/ARCHITECTURE.md "Launch sequence"). Everything else lives in the modules, reached through
/// `Services`. Skeleton from WP1; WP16 completes step 3 (`Services.updates` over UpdateKit, the PDF Services offer,
/// Quick Actions), step 4 (open files or the welcome window, then start the updater), document types, `superpdf://`
/// routing and the Dock menu.
@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate, MenuCommandResponding, NSMenuItemValidation {
    /// Steps 1–2: Core bootstrap, then every module in dependency order (ToolsKit after every tool provider).
    func applicationWillFinishLaunching(_ notification: Notification) {
        SuperPDFPaths.ensure(SuperPDFPaths.support)
        DocumentKitModule.install()
        LayoutKitModule.install()
        RenderKitModule.install()
        PagesKitModule.install()
        ConvertKitModule.install()
        EditKitModule.install()
        MarkupKitModule.install()
        FormsKitModule.install()
        SignKitModule.install()
        ProtectKitModule.install()
        FixKitModule.install()
        ScanKitModule.install()
        BatchKitModule.install()
        ToolsKitModule.install()
        ViewerKitModule.install()
        SettingsKitModule.install()
        NSApp.mainMenu = MainMenu.make()
        NSApp.setActivationPolicy(.regular)
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        let version = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "dev"
        Log.app.info("Super PDF \(version, privacy: .public) launched")
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }

    // MARK: App-level menu commands (the end of the responder chain)

    func performMenuCommand(_ sender: NSMenuItem) {
        guard let command = sender.menuCommand else { return }
        let document = Services.documents?.frontmost
        if let tool = command.tool {
            Services.tools?.openPanel(tool, for: document, inputs: [])
            return
        }
        switch command {
        case .settings: Services.settings?.show(nil)
        case .checkForUpdates: Services.updates?.checkNow()
        case .allTools: Services.tools?.showToolsSheet(for: document)
        case .welcome: Services.viewer?.showWelcome()
        case .signatureRequests: Services.requests?.showRequestsWindow()
        default: break
        }
    }

    /// Commands are enabled once the module that answers them is installed.
    func validateMenuItem(_ menuItem: NSMenuItem) -> Bool {
        guard let command = menuItem.menuCommand else { return true }
        if command.tool != nil { return Services.tools != nil }
        switch command {
        case .settings: return Services.settings != nil
        case .checkForUpdates: return Services.updates != nil
        case .allTools: return Services.tools != nil
        case .welcome: return Services.viewer != nil
        case .signatureRequests: return Services.requests != nil
        default: return false
        }
    }
}

let app = NSApplication.shared
let delegate = MainActor.assumeIsolated { AppDelegate() }
app.delegate = delegate
app.run()
