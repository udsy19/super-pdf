import AppKit
import PDFKit
import SuperPDFCore

// Boxes on the page while the Sign or Request signatures panel is open (ux §5.2 archetype D: the document becomes
// interactive): a click places, a drag moves, a corner handle resizes, Delete removes. Both panels keep their boxes in a
// `PageBoard`; one transparent view over the PDF view turns the mouse into those edits, and the panel's live preview
// draws the boxes themselves (so they scroll and zoom with the page).

/// A box on a page, in page space.
struct PageBox: Hashable {
    var id: UUID
    var page: Int
    var rect: CGRect
    /// Pictures keep their shape when resized.
    var keepsAspect: Bool
}

@MainActor
protocol PageBoard: AnyObject {
    var document: DocumentHandle { get }
    var boxes: [PageBox] { get }
    var selection: UUID? { get set }
    /// A click on the page away from every box; true when something was placed.
    func place(at point: CGPoint, page: Int, pdfPage: PDFPage) -> Bool
    func update(_ id: UUID, rect: CGRect)
    func remove(_ id: UUID)
}

/// The action a board's change sends to its panel's `handle(action:)`.
let boardChangedAction = "board-changed"

extension PageBoard {
    /// Tells the panel (`ToolPanel.performActionNotification`), so its preview and counts follow.
    func announce() {
        NotificationCenter.default.post(name: ToolPanel.performActionNotification, object: document,
                                        userInfo: [ToolPanel.actionKey: boardChangedAction])
    }
}

enum PageBoxDrawing {
    static let handle: CGFloat = 5

    /// The mockup's selection: a dashed accent outline with square handles at the corners.
    static func drawSelection(_ rect: CGRect, in context: CGContext) {
        let accent = NSColor.controlAccentColor.usingColorSpace(.sRGB)?.cgColor ?? CGColor(srgbRed: 0, green: 0.48, blue: 1, alpha: 1)
        context.saveGState()
        context.setStrokeColor(accent)
        context.setLineWidth(1)
        context.setLineDash(phase: 0, lengths: [3, 2])
        context.stroke(rect.insetBy(dx: -1, dy: -1))
        context.setLineDash(phase: 0, lengths: [])
        for corner in corners(of: rect.insetBy(dx: -1, dy: -1)) {
            let square = CGRect(x: corner.x - handle / 2, y: corner.y - handle / 2, width: handle, height: handle)
            context.setFillColor(CGColor(gray: 1, alpha: 1))
            context.fill(square)
            context.stroke(square)
        }
        context.restoreGState()
    }

    static func corners(of rect: CGRect) -> [CGPoint] {
        [CGPoint(x: rect.minX, y: rect.minY), CGPoint(x: rect.maxX, y: rect.minY), CGPoint(x: rect.minX, y: rect.maxY), CGPoint(x: rect.maxX, y: rect.maxY)]
    }
}

/// Installs the editing view over the document's PDF view while it is in a window (the panel's custom control hosts it).
@MainActor
final class BoardHost: NSView {
    private let board: PageBoard
    private weak var editor: PageBoardView?

    init(board: PageBoard, content: NSView? = nil) {
        self.board = board
        super.init(frame: content?.frame ?? .zero)
        if let content {
            content.translatesAutoresizingMaskIntoConstraints = false
            addSubview(content)
            NSLayoutConstraint.activate([
                content.leadingAnchor.constraint(equalTo: leadingAnchor), content.trailingAnchor.constraint(equalTo: trailingAnchor),
                content.topAnchor.constraint(equalTo: topAnchor), content.bottomAnchor.constraint(equalTo: bottomAnchor),
            ])
        }
    }

    @available(*, unavailable) required init?(coder: NSCoder) { fatalError() }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if window != nil {
            guard editor == nil, let pdfView = Services.viewer?.pdfView(for: board.document) else { return }
            let view = PageBoardView(pdfView: pdfView, board: board)
            view.frame = pdfView.bounds
            view.autoresizingMask = [.width, .height]
            pdfView.addSubview(view)
            editor = view
        } else {
            editor?.removeFromSuperview()
            editor = nil
        }
    }
}

/// Over the PDF view: clicks place, drags move and resize; scrolling and zooming pass through.
@MainActor
final class PageBoardView: NSView {
    private weak var pdfView: PDFView?
    private let board: PageBoard
    private enum Drag { case move, resize(corner: Int) }
    private var drag: (id: UUID, kind: Drag, start: CGPoint, original: CGRect, page: PDFPage)?
    private var ghost: CGRect?

    init(pdfView: PDFView, board: PageBoard) {
        self.pdfView = pdfView
        self.board = board
        super.init(frame: pdfView.bounds)
        setAccessibilityElement(false)
    }

    @available(*, unavailable) required init?(coder: NSCoder) { fatalError() }

    override var acceptsFirstResponder: Bool { true }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    override func resetCursorRects() { addCursorRect(bounds, cursor: .crosshair) }
    override func scrollWheel(with event: NSEvent) { pdfView?.documentView?.enclosingScrollView?.scrollWheel(with: event) }
    override func magnify(with event: NSEvent) { pdfView?.magnify(with: event) }

    private func location(_ event: NSEvent) -> (page: PDFPage, index: Int, point: CGPoint)? {
        guard let pdfView else { return nil }
        let inView = pdfView.convert(event.locationInWindow, from: nil)
        guard let page = pdfView.page(for: inView, nearest: true), let index = Optional(board.document.pdf.index(for: page)), index >= 0 else { return nil }
        return (page, index, pdfView.convert(inView, to: page))
    }

    override func mouseDown(with event: NSEvent) {
        window?.makeFirstResponder(self)
        guard let here = location(event) else { return }
        let slop = PageBoxDrawing.handle * 1.5 / max(pdfView?.scaleFactor ?? 1, 0.1)
        // Handles of the selected box first, then the boxes from the top down.
        if let selected = board.boxes.first(where: { $0.id == board.selection && $0.page == here.index }) {
            for (n, corner) in PageBoxDrawing.corners(of: selected.rect).enumerated() where hypot(corner.x - here.point.x, corner.y - here.point.y) <= slop {
                drag = (selected.id, .resize(corner: n), here.point, selected.rect, here.page)
                return
            }
        }
        if let hit = board.boxes.last(where: { $0.page == here.index && $0.rect.insetBy(dx: -2, dy: -2).contains(here.point) }) {
            board.selection = hit.id
            drag = (hit.id, .move, here.point, hit.rect, here.page)
            board.announce()
            return
        }
        board.selection = nil
        _ = board.place(at: here.point, page: here.index, pdfPage: here.page)
        board.announce()
    }

    override func mouseDragged(with event: NSEvent) {
        guard let drag, let pdfView else { return }
        let inView = pdfView.convert(event.locationInWindow, from: nil)
        let point = pdfView.convert(inView, to: drag.page)
        let rect = moved(drag.original, kind: drag.kind, by: CGSize(width: point.x - drag.start.x, height: point.y - drag.start.y),
                         keepsAspect: board.boxes.first { $0.id == drag.id }?.keepsAspect ?? false)
        ghost = convert(pdfView.convert(rect, from: drag.page), from: pdfView)
        needsDisplay = true
    }

    override func mouseUp(with event: NSEvent) {
        defer { drag = nil; ghost = nil; needsDisplay = true }
        guard let drag, let pdfView else { return }
        let inView = pdfView.convert(event.locationInWindow, from: nil)
        let point = pdfView.convert(inView, to: drag.page)
        let delta = CGSize(width: point.x - drag.start.x, height: point.y - drag.start.y)
        guard abs(delta.width) > 0.5 || abs(delta.height) > 0.5 else { return }
        let bounds = drag.page.bounds(for: .mediaBox)
        var rect = moved(drag.original, kind: drag.kind, by: delta, keepsAspect: board.boxes.first { $0.id == drag.id }?.keepsAspect ?? false)
        // Keep it on the page.
        rect.origin.x = min(max(rect.minX, bounds.minX), bounds.maxX - rect.width)
        rect.origin.y = min(max(rect.minY, bounds.minY), bounds.maxY - rect.height)
        board.update(drag.id, rect: rect)
        board.announce()
    }

    override func keyDown(with event: NSEvent) {
        switch event.keyCode {
        case 51, 117:
            // Delete removes the selected box.
            guard let selected = board.selection else { break }
            board.remove(selected)
            board.selection = nil
            board.announce()
            return
        case 36, 76:
            // Return places in the middle of the page in view, for people who don't use a pointer.
            guard let page = pdfView?.currentPage, let index = Optional(board.document.pdf.index(for: page)), index >= 0 else { break }
            let bounds = page.bounds(for: .mediaBox)
            _ = board.place(at: CGPoint(x: bounds.midX, y: bounds.midY), page: index, pdfPage: page)
            board.announce()
            return
        default:
            break
        }
        super.keyDown(with: event)
    }

    private func moved(_ rect: CGRect, kind: Drag, by delta: CGSize, keepsAspect: Bool) -> CGRect {
        switch kind {
        case .move:
            return rect.offsetBy(dx: delta.width, dy: delta.height)
        case .resize(let corner):
            // Corners: 0 bottom-left, 1 bottom-right, 2 top-left, 3 top-right; the opposite one stays put.
            let fixed = PageBoxDrawing.corners(of: rect)[3 - corner]
            let moving = PageBoxDrawing.corners(of: rect)[corner]
            var w = max(abs(moving.x + delta.width - fixed.x), 8), h = max(abs(moving.y + delta.height - fixed.y), 8)
            if keepsAspect, rect.width > 0, rect.height > 0 {
                let scale = max(w / rect.width, h / rect.height)
                w = rect.width * scale
                h = rect.height * scale
            }
            let x = moving.x > fixed.x ? fixed.x : fixed.x - w
            let y = moving.y > fixed.y ? fixed.y : fixed.y - h
            return CGRect(x: x, y: y, width: w, height: h)
        }
    }

    override func draw(_ dirtyRect: NSRect) {
        guard let ghost else { return }
        NSColor.controlAccentColor.withAlphaComponent(0.08).setFill()
        ghost.fill()
        let path = NSBezierPath(rect: ghost.insetBy(dx: 0.5, dy: 0.5))
        path.setLineDash([3, 2], count: 2, phase: 0)
        NSColor.controlAccentColor.setStroke()
        path.stroke()
    }
}
