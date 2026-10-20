import AppKit
import PDFKit
import SuperPDFCore

// Black out's "Mark by hand" (ux §5.3, Preview's Redact tool): while the mode is on, a transparent view over the
// document turns drags into marks. A drag that starts on text selects text, and each selected line becomes a mark; a
// drag that starts anywhere else draws a box. A click on a mark unmarks it. The panel hears about each change through
// `ToolPanel.performActionNotification`; the marks themselves are drawn by the panel's live preview.

/// The hand marks of one document while its Black out panel is open.
@MainActor
final class HandMarks {
    var marks: [RedactionMark]
    let document: DocumentHandle

    init(document: DocumentHandle, marks: [RedactionMark]) {
        self.document = document
        self.marks = marks
    }

    /// Tells the panel the marks changed (it reads them back through `handle(action:)`).
    func announce() {
        NotificationCenter.default.post(name: ToolPanel.performActionNotification, object: document,
                                        userInfo: [ToolPanel.actionKey: ProtectToolProvider.marksChangedAction])
    }
}

/// The hand mode's line in the panel; while it is shown, the document takes drags as marks.
@MainActor
final class MarkingPalette: NSView {
    private let store: HandMarks
    private weak var marking: MarkingView?

    init(store: HandMarks) {
        self.store = store
        super.init(frame: NSRect(x: 0, y: 0, width: 280, height: 32))
        let label = NSTextField(wrappingLabelWithString: ProtectStrings.handHint)
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
            guard marking == nil, let pdfView = Services.viewer?.pdfView(for: store.document) else { return }
            let view = MarkingView(pdfView: pdfView, store: store)
            view.frame = pdfView.bounds
            view.autoresizingMask = [.width, .height]
            pdfView.addSubview(view)
            marking = view
        } else {
            marking?.removeFromSuperview()
            marking = nil
        }
    }
}

/// Over the PDF view: drags become marks; scrolling and zooming pass through.
@MainActor
final class MarkingView: NSView {
    private weak var pdfView: PDFView?
    private let store: HandMarks
    private var start: (page: PDFPage, point: CGPoint, onText: Bool, inView: CGPoint)?
    private var band: NSRect?
    private var moved = false

    init(pdfView: PDFView, store: HandMarks) {
        self.pdfView = pdfView
        self.store = store
        super.init(frame: pdfView.bounds)
        setAccessibilityElement(false)
    }

    @available(*, unavailable) required init?(coder: NSCoder) { fatalError() }

    override func resetCursorRects() { addCursorRect(bounds, cursor: .crosshair) }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func scrollWheel(with event: NSEvent) { pdfView?.documentView?.enclosingScrollView?.scrollWheel(with: event) }
    override func magnify(with event: NSEvent) { pdfView?.magnify(with: event) }

    private func location(_ event: NSEvent) -> (page: PDFPage, point: CGPoint, inView: CGPoint)? {
        guard let pdfView else { return nil }
        let inView = pdfView.convert(event.locationInWindow, from: nil)
        guard let page = pdfView.page(for: inView, nearest: true) else { return nil }
        return (page, pdfView.convert(inView, to: page), inView)
    }

    override func mouseDown(with event: NSEvent) {
        guard let here = location(event) else { return }
        start = (here.page, here.point, here.page.characterIndex(at: here.point) >= 0, here.inView)
        moved = false
        band = nil
    }

    override func mouseDragged(with event: NSEvent) {
        guard let start, let here = location(event), let pdfView else { return }
        if hypot(here.inView.x - start.inView.x, here.inView.y - start.inView.y) > 3 { moved = true }
        guard moved else { return }
        if start.onText, here.page == start.page {
            pdfView.setCurrentSelection(start.page.selection(from: start.point, to: here.point), animate: false)
        } else {
            let a = convert(start.inView, from: pdfView), b = convert(here.inView, from: pdfView)
            band = NSRect(x: min(a.x, b.x), y: min(a.y, b.y), width: abs(a.x - b.x), height: abs(a.y - b.y))
            needsDisplay = true
        }
    }

    override func mouseUp(with event: NSEvent) {
        defer { start = nil; band = nil; needsDisplay = true }
        guard let start, let here = location(event), let pdfView, let index = Optional(store.document.pdf.index(for: start.page)), index >= 0 else { return }
        if !moved {
            // A click on a mark unmarks it.
            let before = store.marks.count
            store.marks.removeAll { $0.page == index && $0.rect.contains(start.point) }
            if store.marks.count != before { store.announce() }
            return
        }
        var added: [RedactionMark] = []
        if start.onText, here.page == start.page, let selection = start.page.selection(from: start.point, to: here.point) {
            for line in selection.selectionsByLine() {
                let rect = line.bounds(for: start.page)
                guard rect.width > 0.5, rect.height > 0.5 else { continue }
                added.append(RedactionMark(page: index, rect: rect.insetBy(dx: -0.5, dy: -0.5), text: line.string))
            }
            pdfView.clearSelection()
        } else {
            let end = here.page == start.page ? here.point : pdfView.convert(here.inView, to: start.page)
            let rect = CGRect(x: min(start.point.x, end.x), y: min(start.point.y, end.y), width: abs(start.point.x - end.x),
                              height: abs(start.point.y - end.y)).intersection(start.page.bounds(for: .mediaBox))
            if !rect.isNull, rect.width >= 2, rect.height >= 2 { added.append(RedactionMark(page: index, rect: rect)) }
        }
        guard !added.isEmpty else { return }
        store.marks += added
        store.announce()
    }

    override func draw(_ dirtyRect: NSRect) {
        guard let band else { return }
        NSColor.systemRed.withAlphaComponent(0.1).setFill()
        band.fill()
        let path = NSBezierPath(rect: band.insetBy(dx: 0.75, dy: 0.75))
        path.lineWidth = 1.5
        NSColor.systemRed.setStroke()
        path.stroke()
    }
}
