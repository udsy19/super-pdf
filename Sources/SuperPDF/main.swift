import AppKit
import Combine
import CoreServices
import SuperPDFCore
import UpdateKit
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
/// `Services`; this target installs them in order, owns `Services.updates`, the menus, the Dock menu, the Services
/// menu item, `superpdf://` links, files opened from outside and the one-time PDF Services offer.
@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate, MenuCommandResponding, NSMenuItemValidation {
    /// Links and files that arrive before launch finishes wait here.
    private var pending: [URL] = []
    private var isLaunched = false
    /// A throwaway data folder (`SUPERPDF_DATA_DIR`, scripts/e2e.sh): no updates, no offers, nothing restored.
    private let isThrowaway = AppDelegate.configureThrowawayData()

    // MARK: Launch

    /// Steps 1–3: Core bootstrap, every module in dependency order (ToolsKit after every tool provider), the updater and
    /// the main menu.
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
        Services.updates = Self.makeUpdater()
        NSApp.mainMenu = MainMenu.make()
        NSApp.servicesProvider = self
        NSApp.setActivationPolicy(.regular)
    }

    /// Step 3 continued and step 4: the Services menu and Quick Actions registered, the files passed in (or the welcome
    /// window), the PDF Services offer once, then the updater.
    func applicationDidFinishLaunching(_ notification: Notification) {
        let version = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "dev"
        Log.app.info("Super PDF \(version, privacy: .public) launched")
        NSUpdateDynamicServices()
        if !isThrowaway, Bundle.main.bundleURL.pathExtension == "app" {
            // The Quick Actions are app extensions in Contents/PlugIns; registering the bundle lets Finder find them.
            LSRegisterURL(Bundle.main.bundleURL as CFURL, true)
        }
        isLaunched = true
        let waiting = pending
        pending = []
        if !waiting.isEmpty { AppRoutes.open(waiting) }
        // Restored documents open asynchronously; the welcome window shows when nothing else did.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
            MainActor.assumeIsolated { self.showWelcomeIfNothingIsOpen() }
        }
        if !isThrowaway {
            PDFServicesItem.offerOnce()
            Services.updates.start()
        }
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }
    func applicationShouldOpenUntitledFile(_ sender: NSApplication) -> Bool { false }

    /// A Dock click with no window open shows the welcome window (ux §6.1).
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        if !flag { Services.viewer?.showWelcome() }
        return true
    }

    func applicationSupportsSecureRestorableState(_ app: NSApplication) -> Bool { true }

    private func showWelcomeIfNothingIsOpen() {
        guard Services.documents.openDocuments.isEmpty, !NSApp.windows.contains(where: { $0.isVisible && $0.level == .normal }) else { return }
        Services.viewer?.showWelcome()
    }

    // MARK: Files and links

    func application(_ application: NSApplication, open urls: [URL]) {
        guard isLaunched else { pending += urls; return }
        AppRoutes.open(urls)
    }

    // MARK: Dock menu (ux §4): All Tools… and the tools added with "Add to Dock Menu"

    func applicationDockMenu(_ sender: NSApplication) -> NSMenu? { Services.tools?.makeDockMenu() }

    // MARK: Services menu (features §2.5: "Open selection as PDF")

    @objc func openSelectionAsPDF(_ pasteboard: NSPasteboard, userData: String?, error: AutoreleasingUnsafeMutablePointer<NSString?>) {
        NSApp.activate()
        Task { await PasteboardPDF.open(from: pasteboard) }
    }

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
        case .checkForUpdates:
            // The status shows in Settings › Privacy, next to the switch for automatic checks.
            Services.updates?.checkNow()
            Services.settings?.show(.privacy)
        case .allTools: Services.tools?.showToolsSheet(for: document)
        case .welcome: Services.viewer?.showWelcome()
        case .signatureRequests: Services.requests?.showRequestsWindow()
        case .newFromClipboard: Task { await PasteboardPDF.open(from: .general) }
        case .importFromIPhone: Services.tools?.openPanel(.scanWithIPhone, for: document, inputs: [])
        case .importFromCamera: Services.tools?.openPanel(.fromPhoto, for: document, inputs: [])
        case .importFromScanner: Services.tools?.openPanel(.scanWithScanner, for: document, inputs: [])
        case .exportAs: Services.tools?.openPanel(.toImages, for: document, inputs: [])
        case .editPermissions: Services.tools?.openPanel(.addPassword, for: document, inputs: [])
        case .exportAsPDF:
            // Preview's Export as PDF… is a copy of the document: the document's own Save a Copy….
            let copy = NSMenuItem()
            copy.identifier = NSUserInterfaceItemIdentifier(MenuCommand.saveACopy.rawValue)
            (NSDocumentController.shared.currentDocument as? MenuCommandResponding)?.performMenuCommand(copy)
        case .help: NSWorkspace.shared.open(SuperPDFPaths.repository.appendingPathComponent("blob/main/README.md"))
        default:
            // Tools › Annotate: the window forwards what it doesn't own; markup acts on the frontmost document.
            if let document { _ = Services.markup?.perform(command, in: document) }
        }
    }

    /// Commands are enabled once the module that answers them is installed (and, for document commands, a document is
    /// open).
    func validateMenuItem(_ menuItem: NSMenuItem) -> Bool {
        guard let command = menuItem.menuCommand else { return true }
        if command.tool != nil { return Services.tools != nil }
        let document = Services.documents?.frontmost
        switch command {
        case .settings: return Services.settings != nil
        case .checkForUpdates: return Services.updates != nil
        case .allTools: return Services.tools != nil
        case .welcome: return Services.viewer != nil
        case .signatureRequests: return Services.requests != nil
        case .newFromClipboard: return PasteboardPDF.canMake(from: .general)
        case .importFromIPhone, .importFromCamera, .importFromScanner: return Services.tools != nil
        case .exportAs, .editPermissions: return document != nil && Services.tools != nil
        case .exportAsPDF: return NSDocumentController.shared.currentDocument != nil
        case .help: return true
        default:
            guard let document else { return false }
            return Services.markup?.validate(command, in: document) ?? false
        }
    }

    // MARK: Engines the app target owns

    /// UpdateKit on this repository's releases. Automatic checks follow Settings › Privacy; "Check for Updates…"
    /// always checks. A staged update goes in when the app quits, or sooner when it is idle: in the background with no
    /// unsaved changes and nothing asking a question.
    private static func makeUpdater() -> Updater {
        Updater(app: UpdateIdentity(bundleID: SuperPDFPaths.bundleID, appName: "Super PDF.app", displayName: "Super PDF",
                                    repository: "udsy19/super-pdf", assetBase: "SuperPDF", feedOverride: "SUPERPDF_UPDATE_FEED"),
                stateFile: SuperPDFPaths.support.appendingPathComponent("update.json"),
                enabled: { Defaults[.checkForUpdates] },
                enabledChanges: Defaults.publisher(.checkForUpdates).dropFirst().map { _ in () }.eraseToAnyPublisher(),
                canInstallNow: {
                    !NSApp.isActive && NSApp.modalWindow == nil
                        && !(Services.documents?.openDocuments.contains { $0.state.isEdited } ?? false)
                })
    }

    /// `SUPERPDF_DATA_DIR` points Application Support at a throwaway folder and `SUPERPDF_DEFAULTS_SUITE` the settings at
    /// a throwaway suite (scripts/e2e.sh); without them nothing changes.
    private static func configureThrowawayData() -> Bool {
        let environment = ProcessInfo.processInfo.environment
        guard let folder = environment["SUPERPDF_DATA_DIR"], !folder.isEmpty else { return false }
        SuperPDFPaths.base = URL(fileURLWithPath: folder, isDirectory: true).appendingPathComponent("Application Support", isDirectory: true)
        if let suite = environment["SUPERPDF_DEFAULTS_SUITE"], let store = UserDefaults(suiteName: suite) { Defaults.store = store }
        return true
    }
}

let app = NSApplication.shared
let delegate = MainActor.assumeIsolated { AppDelegate() }
app.delegate = delegate
app.run()
