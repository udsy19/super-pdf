import AppKit
import PDFKit
import SuperPDFCore

// Clicks on the page for the forms panels (ux §5.3): while Make a form's panel shows, a transparent view over the
// document turns clicks into "pick this field" or "put a field here"; in Fill a form it takes only clicks that miss
// the fields (Fill anywhere), so typing into fields stays PDFKit's. The panel hears about each click through
// `ToolPanel.performActionNotification`, as ProtectKit's marking does.

/// The panel line (an optional hint) whose presence puts the document in placing mode.
@MainActor
final class FormsPlacement: NSView {
    private let document: DocumentHandle
    private weak var tools: FormsTools?
    private weak var catcher: FormsClickView?

    init(document: DocumentHandle, tools: FormsTools?, hint: String?) {
        self.document = document
        self.tools = tools
        super.init(frame: NSRect(x: 0, y: 0, width: 280, height: hint == nil ? 0 : 32))
        guard let hint else { return }
        let label = NSTextField(wrappingLabelWithString: hint)
        label.font = .systemFont(ofSize: 11)
        label.textColor = .secondaryLabelColor
        label.translatesAutoresizingMaskIntoConstraints = false
        addSubview(label)
        NSLayoutConstraint.activate([
            label.leadingAnchor.constraint(equalTo: leadingAnchor), label.trailingAnchor.constraint(equalTo: trailingAnchor),
            label.topAnchor.constraint(equalTo: topAnchor), label.bottomAnchor.constraint(equalTo: bottomAnchor),
        ])
    }

    @available(*, unavailable) required init?(coder: NSCoder) { fatalError() }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if window != nil {
            guard catcher == nil, let pdfView = Services.viewer?.pdfView(for: document) else { return }
            let view = FormsClickView(pdfView: pdfView, document: document, tools: tools)
            view.frame = pdfView.bounds
            view.autoresizingMask = [.width, .height]
            pdfView.addSubview(view)
            catcher = view
        } else {
            catcher?.removeFromSuperview()
            catcher = nil
        }
    }
}

/// Over the PDF view: single clicks become placement actions; scrolling and zooming pass through.
@MainActor
final class FormsClickView: NSView {
    private weak var pdfView: PDFView?
    private let document: DocumentHandle
    private weak var tools: FormsTools?

    init(pdfView: PDFView, document: DocumentHandle, tools: FormsTools?) {
        self.pdfView = pdfView
        self.document = document
        self.tools = tools
        super.init(frame: pdfView.bounds)
        setAccessibilityElement(false)
    }

    @available(*, unavailable) required init?(coder: NSCoder) { fatalError() }

    private var mode: (tool: ToolID, values: ToolValues)? { tools?.modes[document.id] }

    /// Fill a form takes clicks only in Fill anywhere, and only off the fields.
    override func hitTest(_ point: NSPoint) -> NSView? {
        guard let mode, let pdfView else { return nil }
        guard mode.tool == .fillForm else { return super.hitTest(point) }
        guard mode.values.bool(FormsTools.Key.anywhere) else { return nil }
        let inView = pdfView.convert(point, from: superview)
        guard let page = pdfView.page(for: inView, nearest: false) else { return nil }
        let onField = page.annotation(at: pdfView.convert(inView, to: page))?.type == "Widget"
        return onField ? nil : super.hitTest(point)
    }

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    override func scrollWheel(with event: NSEvent) { pdfView?.documentView?.enclosingScrollView?.scrollWheel(with: event) }
    override func magnify(with event: NSEvent) { pdfView?.magnify(with: event) }

    override func mouseDown(with event: NSEvent) {}

    override func mouseUp(with event: NSEvent) {
        guard let pdfView else { return }
        let inView = pdfView.convert(event.locationInWindow, from: nil)
        guard let page = pdfView.page(for: inView, nearest: false) else { return }
        let index = document.pdf.index(for: page)
        guard index >= 0 else { return }
        NotificationCenter.default.post(name: ToolPanel.performActionNotification, object: document,
                                        userInfo: [ToolPanel.actionKey: FormsTools.Action.click(page: index, at: pdfView.convert(inView, to: page))])
    }
}
