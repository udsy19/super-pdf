// The Finder Quick Actions (features §2.5: Combine in Super PDF, Make Smaller, Convert to PDF, Recognise Text). One
// executable serves four app extensions in Super PDF's Contents/PlugIns (scripts/build-app.sh), each with its own
// Info.plist naming its action (`QuickAction.infoKey`). Linked with `NSExtensionMain` as its entry point, it runs
// sandboxed in its own process: it reads nothing, it only hands the selected files' paths to the app as a `superpdf://`
// link (`AppRoute.tool`), and the app does the work in its own panels, where the result is shown.
import AppKit
import SuperPDFCore
import UniformTypeIdentifiers

@objc(QuickActionRequestHandler)
final class QuickActionRequestHandler: NSObject, NSExtensionRequestHandling {
    func beginRequest(with context: NSExtensionContext) {
        guard let action = QuickAction(bundleInfo: Bundle.main.infoDictionary) else {
            context.cancelRequest(withError: CocoaError(.featureUnsupported))
            return
        }
        let attachments = context.inputItems.compactMap { $0 as? NSExtensionItem }.flatMap { $0.attachments ?? [] }
        let collected = Collected()
        let group = DispatchGroup()
        for (index, attachment) in attachments.enumerated() where attachment.hasItemConformingToTypeIdentifier(UTType.fileURL.identifier) {
            group.enter()
            attachment.loadItem(forTypeIdentifier: UTType.fileURL.identifier, options: nil) { item, _ in
                let url = (item as? URL) ?? (item as? Data).flatMap { URL(dataRepresentation: $0, relativeTo: nil) }
                if let url, url.isFileURL { collected.add(url, at: index) }
                group.leave()
            }
        }
        group.notify(queue: .main) {
            let files = collected.files
            guard !files.isEmpty else {
                context.cancelRequest(withError: CocoaError(.fileReadNoSuchFile))
                return
            }
            NSWorkspace.shared.open(AppRoute.tool(action.tool, files: files).url)
            context.completeRequest(returningItems: nil)
        }
    }
}

/// The selected files, in Finder's order, gathered from callbacks on any queue.
private final class Collected: @unchecked Sendable {
    private let lock = NSLock()
    private var byIndex: [Int: URL] = [:]

    func add(_ url: URL, at index: Int) { lock.withLock { byIndex[index] = url } }
    var files: [URL] { lock.withLock { byIndex.keys.sorted().compactMap { byIndex[$0] } } }
}
