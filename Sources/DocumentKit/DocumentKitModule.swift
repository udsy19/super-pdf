import AppKit
import SuperPDFCore

/// DocumentKit: NSDocument, open/repair/password flows, the save policy, output naming, versions, page-operation undo,
/// recents and view state (docs/ARCHITECTURE.md, WP3). It registers `Services.documents` (`DocumentManaging`).
///
/// Install it first (ARCHITECTURE "Launch sequence"): it creates the app's document controller, which must be the first
/// `NSDocumentController` made so that it becomes the shared one. The app's Info.plist names `SuperPDFDocument` as the
/// document class for PDFs.
public enum DocumentKitModule {
    @MainActor public static func install() {
        let controller = PDFDocumentController()
        if NSDocumentController.shared !== controller {
            Log.documents.error("DocumentKit installed after another document controller was created")
        }
        let autosave = (try? FileManager.default.url(for: .autosavedInformationDirectory, in: .userDomainMask, appropriateFor: nil, create: false))
            ?? SuperPDFPaths.support.appendingPathComponent("Autosave", isDirectory: true)
        let desktop = FileManager.default.urls(for: .desktopDirectory, in: .userDomainMask)[0]
        let manager = DocumentManager(controller: controller, prompter: AlertPrompter(), autosaveFolder: autosave, fallbackFolder: desktop)
        DocumentManager.current = manager
        Services.documents = manager
    }
}
