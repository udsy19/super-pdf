import AppKit
import SuperPDFCore
import SwiftUI
import UniformTypeIdentifiers

/// Hosts a `ToolPanelView` in the document's panel slot (ViewerKit) or its own small window, and answers the session's
/// questions with the system's sheets: where to save (NSSavePanel) and "are you sure" (NSAlert).
@MainActor
final class ToolPanelController: NSViewController {
    let session: ToolSession
    private let onBack: () -> Void
    private let onClose: () -> Void

    init(session: ToolSession, onBack: @escaping () -> Void, onClose: @escaping () -> Void) {
        self.session = session
        self.onBack = onBack
        self.onClose = onClose
        super.init(nibName: nil, bundle: nil)
        session.chooseDestination = { [weak self] proposed, policy, prompt in await self?.askWhere(proposed, policy: policy, prompt: prompt) }
        session.confirm = { [weak self] confirmation in await self?.confirm(confirmation) ?? false }
    }

    @available(*, unavailable) required init?(coder: NSCoder) { fatalError() }

    override func loadView() {
        let host = NSHostingView(rootView: ToolPanelView(session: session, onBack: onBack, onClose: onClose))
        // The panel fills the slot it is given (ViewerKit's 320 pt column); it never sizes the window.
        host.sizingOptions = []
        host.frame = NSRect(x: 0, y: 0, width: SPMetrics.ToolPanel.width, height: 600)
        host.setAccessibilityLabel(session.tile.name)
        view = host
    }

    private func askWhere(_ proposed: URL, policy: OutputPolicy, prompt: String) async -> URL? {
        let panel = NSSavePanel()
        panel.directoryURL = proposed.deletingLastPathComponent()
        panel.nameFieldStringValue = proposed.lastPathComponent
        panel.prompt = prompt
        panel.canCreateDirectories = true
        if case .folder = policy { panel.allowsOtherFileTypes = true } else if !proposed.pathExtension.isEmpty {
            panel.allowedContentTypes = [UTType(filenameExtension: proposed.pathExtension)].compactMap { $0 }
        }
        let response: NSApplication.ModalResponse
        if let window = view.window {
            response = await withCheckedContinuation { continuation in
                panel.beginSheetModal(for: window) { continuation.resume(returning: $0) }
            }
        } else {
            response = panel.runModal()
        }
        return response == .OK ? panel.url : nil
    }

    private func confirm(_ confirmation: ToolConfirmation) async -> Bool {
        let alert = NSAlert()
        alert.messageText = confirmation.message
        let confirm = alert.addButton(withTitle: confirmation.confirm.title)
        confirm.hasDestructiveAction = confirmation.confirm.isDestructive
        alert.addButton(withTitle: Strings.Panel.cancel)
        guard let window = view.window else { return alert.runModal() == .alertFirstButtonReturn }
        let response = await withCheckedContinuation { continuation in
            alert.beginSheetModal(for: window) { continuation.resume(returning: $0) }
        }
        return response == .alertFirstButtonReturn
    }
}
