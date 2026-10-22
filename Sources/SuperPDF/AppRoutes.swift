import AppKit
import BatchKit
import SuperPDFCore

/// Where files and `superpdf://` links that reach the app go (features #1, #48, §2.5; ux §3): Finder's Open and Open
/// With, the Dock icon, the Print dialog's "Save to Super PDF", Quick Actions and links.
@MainActor
enum AppRoutes {
    /// Everything `application(_:open:)` receives: links are routed, files open.
    static func open(_ urls: [URL]) {
        let links = urls.filter { !$0.isFileURL }
        for link in links {
            if let route = AppRoute(link) { follow(route) } else { Log.app.error("Ignored a link it doesn't know: \(link.absoluteString, privacy: .private)") }
        }
        let files = urls.filter(\.isFileURL)
        if !files.isEmpty { openFiles(files) }
    }

    static func follow(_ route: AppRoute) {
        switch route {
        case .open(let files):
            openFiles(files)
        case .tool(let tool, let files):
            openTool(tool, files: files)
        }
    }

    /// A tile with files: tools that start from files get them in their list; a document tool opens its file first,
    /// and on several files runs as the step of "Do this to many files".
    static func openTool(_ tool: ToolID, files: [URL]) {
        let tile = ToolCatalog.tile(tool)
        guard let tools = Services.tools else { return }
        if !tile.needsDocument || files.isEmpty {
            tools.openPanel(tool, for: files.isEmpty ? Services.documents?.frontmost : nil, inputs: files)
        } else if files.count == 1 {
            Task {
                guard let document = await open(files[0]) else { return }
                tools.openPanel(tool, for: document, inputs: [])
            }
        } else {
            BatchKitModule.openManyFiles(steps: [tool], files: files)
        }
    }

    /// One file opens (converted first if need be); a PDF the Print dialog made becomes a new document; several ask
    /// whether to combine them, in the workspace (ux §3, §6.2).
    static func openFiles(_ files: [URL]) {
        let printed = files.filter(isPrintedPDF)
        for file in printed { openPrinted(file) }
        let others = files.filter { !isPrintedPDF($0) }
        guard !others.isEmpty else { return }
        if others.count == 1 || !askCombine(others.count) {
            Task { for file in others { await open(file) } }
        } else {
            Services.viewer?.combine(others)
        }
    }

    @discardableResult
    static func open(_ file: URL) async -> DocumentHandle? {
        do {
            return try await Services.documents?.open(file)
        } catch let error as CocoaError where error.code == .userCancelled {
            return nil
        } catch {
            NSApp.presentError(error)
            return nil
        }
    }

    /// "Combine these 3 files?" with Combine… (the workspace, to order and pick pages first) or Open Separately.
    private static func askCombine(_ count: Int) -> Bool {
        let alert = NSAlert()
        alert.messageText = AppStrings.combineFiles(count)
        alert.informativeText = AppStrings.combineInfo
        alert.addButton(withTitle: AppStrings.combine)
        alert.addButton(withTitle: AppStrings.openSeparately)
        return alert.runModal() == .alertFirstButtonReturn
    }

    // MARK: Print to Super PDF (features #48)

    /// The Print dialog hands a PDF it wrote in a temporary folder; it opens as a new document made here.
    static func isPrintedPDF(_ url: URL) -> Bool {
        guard url.pathExtension.lowercased() == "pdf" else { return false }
        let path = url.resolvingSymlinksInPath().path
        let temporary = URL(fileURLWithPath: NSTemporaryDirectory()).resolvingSymlinksInPath().path
        return path.hasPrefix(temporary + "/") || path.hasPrefix("/private/var/spool/")
    }

    private static func openPrinted(_ file: URL) {
        do {
            let data = try Data(contentsOf: file)
            try Services.documents?.openUntitled(data, name: file.deletingPathExtension().lastPathComponent)
        } catch {
            NSApp.presentError(error)
        }
    }
}
