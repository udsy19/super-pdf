import AppKit
import PDFKit
import PDFModelKit
import SuperPDFCore

// Links (features #63): a box drawn on the page becomes a Link annotation that goes to a page, a named place, a web
// address or a file; "Make links from the web addresses in the text" finds addresses with the data detector and links
// each line they sit on. PDFKit writes the annotations on the main actor, so these are `.actions` undo steps.

enum LinkTarget: Equatable {
    case page(Int)
    case destination(String)
    case url(URL)
    case file(URL)
}

enum LinkTools {
    /// Adds one link over `rect` of page `index`.
    @MainActor
    static func addLink(over rect: CGRect, page index: Int, to target: LinkTarget, in document: DocumentHandle) -> UndoGroup? {
        guard let page = document.pdf.page(at: index), let annotation = makeAnnotation(rect, to: target, in: document) else { return nil }
        page.addAnnotation(annotation)
        return UndoGroup(EditKitStrings.Undo.link, undo: { page.removeAnnotation(annotation) }, redo: { page.addAnnotation(annotation) })
    }

    @MainActor
    static func makeAnnotation(_ rect: CGRect, to target: LinkTarget, in document: DocumentHandle) -> PDFAnnotation? {
        let annotation = PDFAnnotation(bounds: rect, forType: .link, withProperties: nil)
        switch target {
        case .page(let index):
            guard let page = document.pdf.page(at: index) else { return nil }
            annotation.action = PDFActionGoTo(destination: PDFDestination(page: page, at: CGPoint(x: kPDFDestinationUnspecifiedValue, y: kPDFDestinationUnspecifiedValue)))
        case .destination(let name):
            guard let model = try? PDFModel(EditSource.source(for: document)), let item = NamedDestinations.read(from: model).first(where: { $0.name == name }),
                  let page = document.pdf.page(at: item.destination.page) else { return nil }
            annotation.action = PDFActionGoTo(destination: PDFDestination(page: page, at: CGPoint(x: kPDFDestinationUnspecifiedValue, y: kPDFDestinationUnspecifiedValue)))
        case .url(let url):
            annotation.action = PDFActionURL(url: url)
        case .file(let url):
            annotation.action = PDFActionRemoteGoTo(pageIndex: 0, at: CGPoint(x: kPDFDestinationUnspecifiedValue, y: kPDFDestinationUnspecifiedValue), fileURL: url)
        }
        return annotation
    }

    /// Links every web address found in the text of `pages` (one annotation per line it spans); returns how many.
    @MainActor
    static func detectLinks(in document: DocumentHandle, pages: [Int]) -> (count: Int, undo: UndoGroup) {
        guard let detector = try? NSDataDetector(types: NSTextCheckingResult.CheckingType.link.rawValue) else { return (0, UndoGroup(EditKitStrings.Undo.links, undo: {}, redo: {})) }
        var added: [(PDFKit.PDFPage, PDFAnnotation)] = []
        for index in pages {
            guard let page = document.pdf.page(at: index), let text = page.string, !text.isEmpty else { continue }
            let existing = page.annotations.filter { $0.type == "Link" }.map(\.bounds)
            for match in detector.matches(in: text, range: NSRange(location: 0, length: (text as NSString).length)) {
                guard let url = match.url, let selection = page.selection(for: match.range) else { continue }
                for line in selection.selectionsByLine() {
                    let bounds = line.bounds(for: page)
                    guard bounds.width > 1, bounds.height > 1, !existing.contains(where: { $0.intersects(bounds) }) else { continue }
                    let annotation = PDFAnnotation(bounds: bounds.insetBy(dx: -1, dy: -1), forType: .link, withProperties: nil)
                    annotation.action = PDFActionURL(url: url)
                    page.addAnnotation(annotation)
                    added.append((page, annotation))
                }
            }
        }
        let group = UndoGroup(EditKitStrings.Undo.links, undo: { for (page, annotation) in added { page.removeAnnotation(annotation) } },
                              redo: { for (page, annotation) in added { page.addAnnotation(annotation) } })
        return (added.count, group)
    }

    /// A typed address, with "https://" added when it has no scheme.
    static func url(from text: String) -> URL? {
        var trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, !trimmed.contains(" ") else { return nil }
        if !trimmed.contains("://"), !trimmed.hasPrefix("mailto:") { trimmed = trimmed.contains("@") && !trimmed.contains("/") ? "mailto:" + trimmed : "https://" + trimmed }
        guard let url = URL(string: trimmed), let scheme = url.scheme, ["http", "https", "mailto", "ftp"].contains(scheme.lowercased()) else { return nil }
        if scheme.hasPrefix("http") { guard let host = url.host, host.contains(".") else { return nil } }
        return url
    }
}

/// The box drawn for a link on one document while its panel is open.
@MainActor
final class LinkArea {
    let document: DocumentHandle
    var page: Int?
    var rect: CGRect?

    init(document: DocumentHandle) { self.document = document }

    static let changedAction = "areaChanged"

    func announce() {
        NotificationCenter.default.post(name: ToolPanel.performActionNotification, object: document, userInfo: [ToolPanel.actionKey: Self.changedAction])
    }
}

/// The panel's line for drawing the link's box; while it is in a window the document takes drags.
@MainActor
final class LinkDrawingPalette: NSView {
    private let area: LinkArea
    private weak var drawing: LinkDrawingView?

    init(area: LinkArea) {
        self.area = area
        super.init(frame: NSRect(x: 0, y: 0, width: 280, height: 30))
        let label = NSTextField(wrappingLabelWithString: EditKitStrings.Links.drawNote)
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
            guard drawing == nil, let pdfView = Services.viewer?.pdfView(for: area.document) else { return }
            let view = LinkDrawingView(pdfView: pdfView, area: area)
            view.frame = pdfView.bounds
            view.autoresizingMask = [.width, .height]
            pdfView.addSubview(view)
            drawing = view
        } else {
            drawing?.removeFromSuperview()
            drawing = nil
        }
    }
}

/// Over the PDF view: a drag draws the link's box (the panel's preview shows it afterwards).
@MainActor
final class LinkDrawingView: NSView {
    private weak var pdfView: PDFView?
    private let area: LinkArea
    private var start: (page: PDFKit.PDFPage, point: CGPoint, inView: CGPoint)?
    private var band: NSRect?

    init(pdfView: PDFView, area: LinkArea) {
        self.pdfView = pdfView
        self.area = area
        super.init(frame: pdfView.bounds)
        setAccessibilityElement(false)
    }

    @available(*, unavailable) required init?(coder: NSCoder) { fatalError() }

    override func resetCursorRects() { addCursorRect(bounds, cursor: .crosshair) }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    override func scrollWheel(with event: NSEvent) { pdfView?.documentView?.enclosingScrollView?.scrollWheel(with: event) }
    override func magnify(with event: NSEvent) { pdfView?.magnify(with: event) }

    private func location(_ event: NSEvent) -> (page: PDFKit.PDFPage, point: CGPoint, inView: CGPoint)? {
        guard let pdfView else { return nil }
        let inView = pdfView.convert(event.locationInWindow, from: nil)
        guard let page = pdfView.page(for: inView, nearest: true) else { return nil }
        return (page, pdfView.convert(inView, to: page), inView)
    }

    override func mouseDown(with event: NSEvent) {
        start = location(event)
        band = nil
    }

    override func mouseDragged(with event: NSEvent) {
        guard let start, let here = location(event), let pdfView else { return }
        let a = convert(start.inView, from: pdfView), b = convert(here.inView, from: pdfView)
        band = NSRect(x: min(a.x, b.x), y: min(a.y, b.y), width: abs(a.x - b.x), height: abs(a.y - b.y))
        needsDisplay = true
    }

    override func mouseUp(with event: NSEvent) {
        defer { start = nil; band = nil; needsDisplay = true }
        guard let start, let here = location(event), let pdfView else { return }
        let end = here.page == start.page ? here.point : pdfView.convert(here.inView, to: start.page)
        let rect = CGRect(x: min(start.point.x, end.x), y: min(start.point.y, end.y), width: abs(start.point.x - end.x), height: abs(start.point.y - end.y))
            .intersection(start.page.bounds(for: .cropBox))
        guard !rect.isNull, rect.width >= 4, rect.height >= 4 else { return }
        area.page = area.document.pdf.index(for: start.page)
        area.rect = rect
        area.announce()
    }

    override func draw(_ dirtyRect: NSRect) {
        guard let band else { return }
        NSColor.controlAccentColor.withAlphaComponent(0.1).setFill()
        band.fill()
        let path = NSBezierPath(rect: band.insetBy(dx: 0.75, dy: 0.75))
        path.lineWidth = 1.5
        NSColor.controlAccentColor.setStroke()
        path.stroke()
    }
}
