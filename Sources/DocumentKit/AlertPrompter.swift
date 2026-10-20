import AppKit
import SuperPDFCore
import UniformTypeIdentifiers

/// The app's answers to `DocumentPrompting`: standard alerts with the copy of ux §7.1 and §7.4, as sheets on the
/// document's window when there is one, and the standard save panel. A locked PDF is asked for inside its window, as
/// Preview does (ViewerKit's `password(forLocked:retry:)`); the alert remains for when no viewer is installed.
@MainActor
final class AlertPrompter: DocumentPrompting {
    func password(for fileName: String, retry: Bool) async -> String? {
        if let viewer = Services.viewer { return await viewer.password(forLocked: fileName, retry: retry) }
        return await askPassword(window: nil, retry: retry)
    }

    func ownerPassword(for fileName: String, retry: Bool, window: NSWindow?) async -> String? {
        await askPassword(window: window, retry: retry)
    }

    private func askPassword(window: NSWindow?, retry: Bool) async -> String? {
        let alert = NSAlert()
        alert.messageText = retry ? Strings.Errors.invalidPassword : Strings.Errors.passwordPrompt
        let field = NSSecureTextField(frame: NSRect(x: 0, y: 0, width: 240, height: 24))
        alert.accessoryView = field
        alert.addButton(withTitle: Strings.Errors.unlock)
        alert.addButton(withTitle: Strings.Panel.cancel)
        alert.window.initialFirstResponder = field
        guard await run(alert, window) == .alertFirstButtonReturn else { return nil }
        return field.stringValue
    }

    func confirmRepair(of fileName: String, canRepair: Bool) async -> Bool {
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = Strings.Errors.damaged(fileName)
        if canRepair {
            alert.addButton(withTitle: Strings.Errors.repairAction)
            alert.addButton(withTitle: Strings.Panel.cancel)
        } else {
            alert.addButton(withTitle: Strings.Errors.ok)
        }
        return await run(alert, nil) == .alertFirstButtonReturn && canRepair
    }

    func firstSave(of fileName: String, window: NSWindow?) async -> (answer: FirstSaveAnswer, always: Bool)? {
        let alert = NSAlert()
        alert.messageText = Strings.Save.title(fileName)
        alert.addButton(withTitle: Strings.Save.saveCopy)
        alert.addButton(withTitle: Strings.Save.replaceOriginal)
        alert.addButton(withTitle: Strings.Panel.cancel)
        alert.showsSuppressionButton = true
        alert.suppressionButton?.title = Strings.Save.alwaysDoThis
        let response = await run(alert, window)
        let always = alert.suppressionButton?.state == .on
        switch response {
        case .alertFirstButtonReturn: return (.saveCopy, always)
        case .alertSecondButtonReturn: return (.replaceOriginal, always)
        default: return nil
        }
    }

    func closeWithUnsavedChanges(window: NSWindow?) async -> CloseAnswer {
        let alert = NSAlert()
        alert.messageText = Strings.Save.closeMessage
        alert.addButton(withTitle: Strings.Save.reviewChanges)
        alert.addButton(withTitle: Strings.Save.discardChanges)
        alert.addButton(withTitle: Strings.Panel.cancel)
        switch await run(alert, window) {
        case .alertFirstButtonReturn: return .review
        case .alertSecondButtonReturn: return .discard
        default: return .cancel
        }
    }

    func saveLocation(proposing proposal: URL, window: NSWindow?) async -> URL? {
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.pdf]
        panel.directoryURL = proposal.deletingLastPathComponent()
        panel.nameFieldStringValue = proposal.lastPathComponent
        panel.canCreateDirectories = true
        let response: NSApplication.ModalResponse
        if let window {
            response = await withCheckedContinuation { continuation in panel.beginSheetModal(for: window) { continuation.resume(returning: $0) } }
        } else {
            response = panel.runModal()
        }
        return response == .OK ? panel.url : nil
    }

    private func run(_ alert: NSAlert, _ window: NSWindow?) async -> NSApplication.ModalResponse {
        guard let window else { return alert.runModal() }
        return await withCheckedContinuation { continuation in alert.beginSheetModal(for: window) { continuation.resume(returning: $0) } }
    }
}
