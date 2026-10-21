import AppKit
import PDFKit
import SuperPDFCore

/// Notices when the person fills a field right on the page (PDFKit's own widget editing): when a text entry ends, and
/// after a click or a Tab/Return/Space that may have ticked a box or picked a choice. FormsKit then checks and formats
/// the entry and runs the calculations (`FormService.reconcile`), with or without a panel open, and puts the change on
/// the undo stack. A refused entry beeps, goes back, and the Fill a form panel says why.
@MainActor
final class FormWatcher {
    private let service: FormService
    private var observers: [Any] = []
    private var monitor: Any?
    private var scheduled: Set<UUID> = []

    init(service: FormService) {
        self.service = service
        for name in [NSText.didEndEditingNotification, NSControl.textDidEndEditingNotification] {
            observers.append(NotificationCenter.default.addObserver(forName: name, object: nil, queue: .main) { [weak self] note in
                MainActor.assumeIsolated { self?.changed(near: note.object as? NSView) }
            })
        }
        monitor = NSEvent.addLocalMonitorForEvents(matching: [.leftMouseUp, .keyUp]) { [weak self] event in
            MainActor.assumeIsolated { self?.handle(event) }
            return event
        }
    }

    private func handle(_ event: NSEvent) {
        guard let window = event.window else { return }
        // While a text entry is being typed its value isn't committed; its end is noticed above.
        if window.firstResponder is NSText { return }
        if event.type == .keyUp, ![48, 36, 76, 49].contains(event.keyCode) { return }   // Tab, Return, Enter, Space
        for document in Services.documents?.openDocuments ?? [] where Services.viewer?.pdfView(for: document)?.window === window {
            schedule(document)
        }
    }

    private func changed(near view: NSView?) {
        var current = view
        while let candidate = current, !(candidate is PDFView) { current = candidate.superview }
        guard let pdfView = current as? PDFView,
              let document = Services.documents?.openDocuments.first(where: { Services.viewer?.pdfView(for: $0) === pdfView }) else { return }
        schedule(document)
    }

    /// Looks once the event is over, so PDFKit has committed the value.
    private func schedule(_ document: DocumentHandle) {
        guard document.state.hasFormFields, scheduled.insert(document.id).inserted else { return }
        DispatchQueue.main.async { [weak self, weak document] in
            MainActor.assumeIsolated {
                guard let self, let document else { return }
                self.scheduled.remove(document.id)
                self.reconcile(document)
            }
        }
    }

    func reconcile(_ document: DocumentHandle) {
        let (undo, rejected) = service.reconcile(document)
        if rejected != nil { NSSound.beep() }
        guard undo != nil || rejected != nil else { return }
        if let group = undo {
            Task {
                let work = SuperPDFPaths.ensure(SuperPDFPaths.work.appendingPathComponent(UUID().uuidString, isDirectory: true))
                try? await Services.documents.apply(.inPlace(undoable: group, banner: nil),
                                                    of: ToolRequest(tool: .fillForm, document: document, workFolder: work))
            }
        }
        NotificationCenter.default.post(name: ToolPanel.performActionNotification, object: document,
                                        userInfo: [ToolPanel.actionKey: FormsTools.Action.refresh])
    }
}
