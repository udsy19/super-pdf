import AppKit
import SuperPDFCore
import UniformTypeIdentifiers

// The small dialogs behind SignKit's "…" buttons: Create my certificate, the password of a .p12, and the open and save
// panels. Each one only ever follows the person's click.

@MainActor
enum Prompts {
    /// "Create my certificate…": a name (the account's full name to start with) and an optional email.
    static func newCertificate(in parent: NSWindow?) async -> (name: String, email: String?)? {
        let name = NSTextField(string: NSFullUserName())
        let email = NSTextField(string: "")
        email.placeholderString = SignStrings.emailPlaceholder
        let grid = NSGridView(views: [[NSTextField(labelWithString: SignStrings.yourName), name],
                                      [NSTextField(labelWithString: SignStrings.email), email]])
        grid.column(at: 1).width = 220
        grid.rowSpacing = 8
        grid.frame = NSRect(x: 0, y: 0, width: 320, height: 56)
        let alert = NSAlert()
        alert.messageText = SignStrings.createCertificateTitle
        alert.informativeText = SignStrings.createCertificateHint
        alert.accessoryView = grid
        alert.addButton(withTitle: SignStrings.create)
        alert.addButton(withTitle: SignStrings.cancel)
        alert.window.initialFirstResponder = name
        guard await present(alert, in: parent) == .alertFirstButtonReturn else { return nil }
        let typed = name.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !typed.isEmpty else { return nil }
        let address = email.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        return (typed, address.isEmpty ? nil : address)
    }

    /// The password that opens a `.p12` file.
    static func p12Password(in parent: NSWindow?) async -> String? {
        let field = NSSecureTextField(frame: NSRect(x: 0, y: 0, width: 260, height: 24))
        let alert = NSAlert()
        alert.messageText = SignStrings.p12Password
        alert.accessoryView = field
        alert.addButton(withTitle: SignStrings.importAction)
        alert.addButton(withTitle: SignStrings.cancel)
        alert.window.initialFirstResponder = field
        return await present(alert, in: parent) == .alertFirstButtonReturn ? field.stringValue : nil
    }

    static func chooseFile(_ types: [UTType]) -> URL? {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = types
        panel.allowsMultipleSelection = false
        return panel.runModal() == .OK ? panel.url : nil
    }

    static func saveFile(named name: String, type: UTType, in folder: URL?) -> URL? {
        let panel = NSSavePanel()
        panel.nameFieldStringValue = name
        panel.allowedContentTypes = [type]
        if let folder { panel.directoryURL = folder }
        return panel.runModal() == .OK ? panel.url : nil
    }

    /// A message with OK (failures outside a panel: the requests window).
    static func show(_ error: Error, in parent: NSWindow?) {
        let alert = NSAlert()
        alert.messageText = (error as? ToolError)?.message.text ?? (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
        alert.addButton(withTitle: Strings.Errors.ok)
        if let parent { alert.beginSheetModal(for: parent) } else { alert.runModal() }
    }

    private static func present(_ alert: NSAlert, in parent: NSWindow?) async -> NSApplication.ModalResponse {
        guard let parent else { return alert.runModal() }
        return await withCheckedContinuation { continuation in
            alert.beginSheetModal(for: parent) { continuation.resume(returning: $0) }
        }
    }
}
