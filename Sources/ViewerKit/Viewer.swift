import AppKit
import Combine
import PDFKit
import SuperPDFCore
import UniformTypeIdentifiers

/// What ViewerKit asks of the system, swappable in the self-test: no case opens Finder, another app, a panel or a URL,
/// and nothing is written to the user's defaults.
@MainActor
public struct ViewerEnvironment {
    /// Toolbar configuration, window frames and the sidebar width are remembered in the user's defaults.
    public var persistsWindowState = true
    /// Movement follows the system's Reduce Motion; the self-test turns animation off so frames settle at once.
    public var animates = true
    /// Windows the viewer makes on its own (the welcome window, a locked PDF's window) are shown; the self-test keeps them
    /// off screen.
    public var showsWindows = true
    /// A message with OK, as a sheet on the window ("A PDF needs at least one page.").
    public var alert: @MainActor (_ message: String, _ window: NSWindow?) -> Void = { message, window in
        let alert = NSAlert()
        alert.messageText = message
        alert.addButton(withTitle: Strings.Errors.ok)
        if let window { alert.beginSheetModal(for: window) } else { alert.runModal() }
    }
    /// The open panel: files of `types` (empty means any), one or several. Empty when cancelled.
    public var chooseFiles: @MainActor (_ types: [UTType], _ multiple: Bool, _ window: NSWindow?) async -> [URL] = { types, multiple, window in
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = multiple
        panel.canChooseDirectories = false
        if !types.isEmpty { panel.allowedContentTypes = types }
        let response: NSApplication.ModalResponse
        if let window {
            response = await withCheckedContinuation { continuation in panel.beginSheetModal(for: window) { continuation.resume(returning: $0) } }
        } else {
            response = panel.runModal()
        }
        return response == .OK ? panel.urls : []
    }
    /// The share sheet for pages, next to the view that asked.
    public var share: @MainActor (_ items: [Any], _ view: NSView) -> Void = { items, view in
        NSSharingServicePicker(items: items).show(relativeTo: view.bounds, of: view, preferredEdge: .maxY)
    }
    /// Show in Finder (the welcome window's recents).
    public var revealInFinder: @MainActor ([URL]) -> Void = { NSWorkspace.shared.activateFileViewerSelecting($0) }
    /// File › Open… (the welcome window's Open a PDF target).
    public var openDocumentPanel: @MainActor () -> Void = { NSDocumentController.shared.openDocument(nil) }

    public init() {}

    /// Movement is on unless the self-test or Reduce Motion turned it off (ux §2.5).
    var moves: Bool { animates && !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion }
}

/// `Services.viewer` (ARCHITECTURE "Core contracts"): the document windows, the welcome window, banners, the panel slot
/// and the workspace (ux §2, §3, §6).
@MainActor
public final class Viewer: ViewerPresenting {
    public static let shared = Viewer()

    public var environment = ViewerEnvironment()
    /// Open windows by document; NSDocument owns them too, this is the lookup.
    private var controllers: [UUID: DocumentWindowController] = [:]
    /// Windows asking for a locked PDF's password, by file name, waiting to become that document's window.
    private var lockedPrompts: [String: LockedPromptWindowController] = [:]
    private var welcome: WelcomeWindowController?
    private var events: AnyCancellable?
    /// The document manager `events` listens to (the self-test installs new ones).
    private weak var observed: DocumentManaging?

    init() {}

    // MARK: ViewerPresenting

    public func makeWindowController(for document: DocumentHandle) -> NSWindowController {
        observeDocuments()
        let name = document.url?.lastPathComponent ?? document.displayName
        let adopted = lockedPrompts.removeValue(forKey: name)?.handOverWindow()
        let controller = DocumentWindowController(document: document, viewer: self, adopting: adopted)
        controllers[document.id] = controller
        return controller
    }

    /// The window controller of an open document, if it has one.
    public func controller(for document: DocumentHandle) -> DocumentWindowController? { controllers[document.id] }

    public func pdfView(for document: DocumentHandle) -> PDFView? { controllers[document.id]?.pdfView }

    public func selectedPages(in document: DocumentHandle) -> [Int] { controllers[document.id]?.selectedPages ?? [] }

    public func currentPage(in document: DocumentHandle) -> Int { controllers[document.id]?.currentPageIndex ?? 0 }

    public func showToolPanel(_ panel: NSViewController?, in document: DocumentHandle) {
        controllers[document.id]?.setToolPanel(panel)
    }

    public func showBanner(_ banner: ResultBanner, in document: DocumentHandle) {
        controllers[document.id]?.showBanner(banner)
    }

    public func showSidebar(_ mode: SidebarMode, in document: DocumentHandle) {
        controllers[document.id]?.showSidebar(mode)
    }

    public func showCropHandles(_ handles: CropHandles?, in document: DocumentHandle) {
        controllers[document.id]?.showCropHandles(handles)
    }

    public func showOrganiser(for document: DocumentHandle, adding files: [URL]) {
        controllers[document.id]?.showWorkspace(adding: files)
    }

    public func combine(_ files: [URL]) {
        Task { await combine(files, from: welcome?.window) { [weak self] working in self?.welcome?.welcomeView.isWorking = working } }
    }

    /// Several files become one new unsaved document in the workspace, a card per file (ux §6.1, §6.2). The first PDF
    /// among them opens at once as the document; the files before and after it go in around it, each on its own card while
    /// it converts. With no PDF at all, the first file converts first (`working` says so meanwhile).
    func combine(_ urls: [URL], from window: NSWindow?, working: (Bool) -> Void) async {
        guard let documents = Services.documents, !urls.isEmpty else { return }
        let palette = PageOrigin.palette.count
        var start: (index: Int, data: Data)?
        if let index = urls.firstIndex(where: Self.isReadablePDF), let data = try? Data(contentsOf: urls[index]) {
            start = (index, data)
        } else {
            working(true)
            if let url = await Self.convertedPDF(for: urls[0]), let data = try? Data(contentsOf: url) { start = (0, data) }
            working(false)
        }
        guard let start else {
            environment.alert(Strings.Errors.conversionFailed(urls[0].lastPathComponent), window)
            return
        }
        do {
            let handle = try documents.openUntitled(start.data, name: ViewerStrings.Welcome.combinedName)
            guard let controller = controller(for: handle) else { return }
            controller.pageActions.tag(0..<handle.pageCount, as: PageOrigin(fileName: urls[start.index].lastPathComponent, colorIndex: start.index % palette))
            // The other files wait on their cards first, so the workspace opens on Files.
            controller.pageActions.insertFiles(Array(urls[..<start.index]), atGap: 0, tagged: true, firstColor: 0)
            controller.pageActions.insertFiles(Array(urls[(start.index + 1)...]), atGap: handle.pageCount, tagged: true,
                                               firstColor: (start.index + 1) % palette)
            controller.showWorkspace(adding: [])
        } catch {
            environment.alert(error.localizedDescription, window)
        }
    }

    /// A PDF that opens without a password.
    private static func isReadablePDF(_ url: URL) -> Bool {
        guard UTType(filenameExtension: url.pathExtension)?.conforms(to: .pdf) == true, let pdf = PDFDocument(url: url) else { return false }
        return !pdf.isLocked && pdf.pageCount > 0
    }

    /// A file that isn't a PDF, through ConvertKit, into the work folder.
    private static func convertedPDF(for url: URL) async -> URL? {
        guard let convert = Services.convert, convert.canConvertToPDF(url) else { return nil }
        let folder = SuperPDFPaths.ensure(SuperPDFPaths.work.appendingPathComponent(UUID().uuidString, isDirectory: true))
        let job = ConversionJob(inputs: [url], output: .pdf, destination: folder.appendingPathComponent(url.deletingPathExtension().lastPathComponent + ".pdf"))
        return try? await convert.convert(job, progress: .ignored).outputs.first
    }

    public func showWelcome() {
        let controller = welcome ?? WelcomeWindowController(viewer: self)
        welcome = controller
        controller.showWindow(nil)
        controller.window?.makeKeyAndOrderFront(nil)
    }

    public func password(forLocked fileName: String, retry: Bool) async -> String? {
        let prompt: LockedPromptWindowController
        if let waiting = lockedPrompts[fileName] {
            prompt = waiting
        } else {
            prompt = LockedPromptWindowController(fileName: fileName, environment: environment)
            lockedPrompts[fileName] = prompt
        }
        let answer = await prompt.ask(retry: retry)
        guard answer != nil else { lockedPrompts[fileName] = nil; return nil }
        // A right password makes DocumentKit open the document at once and adopt this window; if that never comes (the
        // open failed afterwards) and no retry asks again, the window goes.
        DispatchQueue.main.asyncAfter(deadline: .now() + 3) { [weak self, weak prompt] in
            MainActor.assumeIsolated {
                guard let self, let prompt, self.lockedPrompts[fileName] === prompt, !prompt.isAsking else { return }
                self.lockedPrompts[fileName] = nil
                prompt.close()
            }
        }
        return answer
    }

    /// The window asking for `fileName`'s password, while it asks.
    func lockedPrompt(named fileName: String) -> LockedPromptWindowController? { lockedPrompts[fileName] }

    // MARK: Documents

    /// Follows DocumentKit's events: changed pages reload the window, a save ends the file-colour bars, an opened
    /// document closes the welcome window.
    private func observeDocuments() {
        guard let documents = Services.documents, events == nil || observed !== documents else { return }
        observed = documents
        events = documents.events.sink { [weak self] event in
            MainActor.assumeIsolated {
                guard let self else { return }
                switch event {
                case .opened:
                    self.welcome?.close()
                case .changed(let id):
                    self.controllers[id]?.documentChanged()
                case .saved(let id):
                    self.controllers[id]?.documentSaved()
                case .closed(let id):
                    self.controllers[id] = nil
                }
            }
        }
    }

    func windowClosed(_ controller: DocumentWindowController) {
        if controllers[controller.handle.id] === controller { controllers[controller.handle.id] = nil }
    }

    /// Opens files the way a drop on the window does (ux §3): each in its own window or tab; other types convert first.
    func open(_ urls: [URL], from window: NSWindow?) {
        guard let documents = Services.documents else { return }
        Task {
            for url in urls {
                do { try await documents.open(url) } catch let error as CocoaError where error.code == .userCancelled {
                } catch { environment.alert(error.localizedDescription, window) }
            }
        }
    }
}
