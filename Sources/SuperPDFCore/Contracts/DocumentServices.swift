import AppKit
import Combine
import PDFKit

// Documents and the windows around them: DocumentKit (`Services.documents`), ViewerKit (`Services.viewer`) and
// SettingsKit (`Services.settings`).

/// Open documents, the save and output policy, recents and view state (DocumentKit; ux §7, features §2.1–§2.3).
@MainActor
public protocol DocumentManaging: AnyObject {
    var openDocuments: [DocumentHandle] { get }
    /// The document of the key window, if any.
    var frontmost: DocumentHandle? { get }
    var events: AnyPublisher<DocumentEvent, Never> { get }

    /// Opens a PDF (password and repair flows included, ux §7.4) and shows it; other file types go through ConvertKit
    /// first. An open document is brought forward instead of opened twice.
    @discardableResult func open(_ url: URL) async throws -> DocumentHandle
    /// A new unsaved document made here ("Combined", a conversion, a scan, the clipboard); `origin` is `.createdHere`.
    @discardableResult func openUntitled(_ data: Data, name: String) throws -> DocumentHandle

    /// The URL a policy gives for a document (ux §7.2): next to `document.url` (or the Desktop for unsaved ones), with
    /// " 2", " 3"… on collisions. Nil for `.inPlace`.
    func destination(for policy: OutputPolicy, of document: DocumentHandle?, source: URL?) -> URL?
    /// Applies a run's result (ARCHITECTURE "End-to-end tool flow"): registers undo, moves new files into place and
    /// opens PDFs in a new tab, then asks the viewer to show the banner.
    func apply(_ result: ToolResult, of request: ToolRequest) async throws

    /// Recent files for the welcome window (ux §6.1), newest first.
    var recentDocuments: [RecentDocument] { get }
    func removeRecent(_ url: URL)

    /// The view state stored in the file's extended attribute; nil when there is none.
    func viewState(for url: URL) -> DocumentViewState?
    func saveViewState(_ state: DocumentViewState, for url: URL)
}

/// The main window, the welcome window, banners and the live-preview host (ViewerKit; ux §2, §6).
@MainActor
public protocol ViewerPresenting: AnyObject {
    /// The window controller NSDocument shows for a document.
    func makeWindowController(for document: DocumentHandle) -> NSWindowController
    /// The PDFView showing a document, for overlays and selections.
    func pdfView(for document: DocumentHandle) -> PDFView?
    /// Selected thumbnails (0-based) and the page in view.
    func selectedPages(in document: DocumentHandle) -> [Int]
    func currentPage(in document: DocumentHandle) -> Int
    /// Shows a tool panel (or removes it with nil) in the document's 320 pt inline panel slot (ux §2.1).
    func showToolPanel(_ panel: NSViewController?, in document: DocumentHandle)
    /// The result banner under the toolbar (ux §7.3).
    func showBanner(_ banner: ResultBanner, in document: DocumentHandle)
    func showSidebar(_ mode: SidebarMode, in document: DocumentHandle)
    /// The full-window page organiser (ux §6.2), optionally with files to mix in.
    func showOrganiser(for document: DocumentHandle, adding files: [URL])
    /// Shown when the app opens with no document, and from Window › Welcome (ux §6.1).
    func showWelcome()
}

/// The settings window's panes (ux §6.6).
public enum SettingsPane: String, Codable, CaseIterable, Sendable {
    case general, tools, converters, signatures, scanning, privacy

    public var title: String {
        switch self {
        case .general: "General"
        case .tools: "Tools"
        case .converters: "Converters"
        case .signatures: "Signatures"
        case .scanning: "Scanning"
        case .privacy: "Privacy"
        }
    }
}

/// The settings window (SettingsKit).
@MainActor
public protocol SettingsPresenting: AnyObject {
    /// Opens Settings (⌘,) at a pane, or where it was last.
    func show(_ pane: SettingsPane?)
}
