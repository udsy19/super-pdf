import AppKit
import PDFKit
import SuperPDFCore

// Crop's handles on the page (ux §5.2 archetype C, "drag handles on the page where position matters"; §5.3 Crop;
// features #28). While the Crop panel is open, every page in its scope shows the part it keeps with the rest dimmed, an
// accent outline and eight handles. Dragging a side or a corner on any of those pages moves it on all of them as the
// drag goes; when the drag ends the panel gets the new margins (`CropHandles.changed`) and shows them as numbers. The
// view sits over the PDF view and only takes the mouse on a handle or an edge, so scrolling, zooming and clicks
// elsewhere reach the document.

/// The drag maths, in the overlay's own (unflipped) coordinates, kept apart so the self-test checks it.
enum CropFrame {
    /// A handle: which way it moves the rect's sides (−1 the low side, +1 the high side, 0 neither), so (−1, 1) is the
    /// top-left corner and (0, −1) the bottom edge.
    struct Handle: Hashable {
        var dx: Int
        var dy: Int

        static let all: [Handle] = [(-1, 1), (0, 1), (1, 1), (-1, 0), (1, 0), (-1, -1), (0, -1), (1, -1)].map { Handle(dx: $0.0, dy: $0.1) }

        /// Where the handle sits on `rect`.
        func point(on rect: CGRect) -> CGPoint {
            CGPoint(x: dx < 0 ? rect.minX : dx > 0 ? rect.maxX : rect.midX, y: dy < 0 ? rect.minY : dy > 0 ? rect.maxY : rect.midY)
        }

        var cursor: NSCursor {
            switch (dx, dy) {
            case (0, _): .resizeUpDown
            case (_, 0): .resizeLeftRight
            default: .crosshair
            }
        }
    }

    /// `rect` with the sides `handle` moves pushed by `delta`, kept inside `bounds` and at least `minimum` wide and tall.
    static func dragged(_ rect: CGRect, handle: Handle, by delta: CGSize, within bounds: CGRect, minimum: CGFloat) -> CGRect {
        var minX = rect.minX, maxX = rect.maxX, minY = rect.minY, maxY = rect.maxY
        if handle.dx < 0 { minX = min(max(minX + delta.width, bounds.minX), maxX - minimum) }
        if handle.dx > 0 { maxX = max(min(maxX + delta.width, bounds.maxX), minX + minimum) }
        if handle.dy < 0 { minY = min(max(minY + delta.height, bounds.minY), maxY - minimum) }
        if handle.dy > 0 { maxY = max(min(maxY + delta.height, bounds.maxY), minY + minimum) }
        return CGRect(x: minX, y: minY, width: maxX - minX, height: maxY - minY)
    }

    /// The handle under `point` on `rect`, corners first, then the edges anywhere along them; nil away from all of them.
    static func handle(at point: CGPoint, on rect: CGRect, slop: CGFloat) -> Handle? {
        for handle in Handle.all where handle.dx != 0 && handle.dy != 0 {
            let p = handle.point(on: rect)
            if abs(p.x - point.x) <= slop, abs(p.y - point.y) <= slop { return handle }
        }
        let insideX = point.x >= rect.minX - slop && point.x <= rect.maxX + slop
        let insideY = point.y >= rect.minY - slop && point.y <= rect.maxY + slop
        if insideY, abs(point.x - rect.minX) <= slop { return Handle(dx: -1, dy: 0) }
        if insideY, abs(point.x - rect.maxX) <= slop { return Handle(dx: 1, dy: 0) }
        if insideX, abs(point.y - rect.minY) <= slop { return Handle(dx: 0, dy: -1) }
        if insideX, abs(point.y - rect.maxY) <= slop { return Handle(dx: 0, dy: 1) }
        return nil
    }
}

@MainActor
final class CropHandlesView: NSView {
    private weak var pdfView: PDFView?
    private let document: DocumentHandle
    var handles: CropHandles { didSet { needsDisplay = true; window?.invalidateCursorRects(for: self) } }
    /// The margins while a drag is under way (drawn on every page in scope); nil otherwise.
    private var live: PageInsets?
    private var drag: (page: PDFPage, handle: CropFrame.Handle, start: CGPoint, original: CGRect)?

    static let handleSize: CGFloat = 7
    /// Nothing is cropped smaller than this (points on the page).
    static let minimumSide: CGFloat = 18

    init(pdfView: PDFView, document: DocumentHandle, handles: CropHandles) {
        self.pdfView = pdfView
        self.document = document
        self.handles = handles
        super.init(frame: pdfView.bounds)
        autoresizingMask = [.width, .height]
        setAccessibilityElement(false)
        let center = NotificationCenter.default
        for name in [Notification.Name.PDFViewScaleChanged, .PDFViewPageChanged, .PDFViewDocumentChanged, .PDFViewDisplayModeChanged] {
            center.addObserver(self, selector: #selector(viewMoved), name: name, object: pdfView)
        }
        if let clip = pdfView.documentView?.enclosingScrollView?.contentView {
            clip.postsBoundsChangedNotifications = true
            center.addObserver(self, selector: #selector(viewMoved), name: NSView.boundsDidChangeNotification, object: clip)
        }
    }

    @available(*, unavailable) required init?(coder: NSCoder) { fatalError() }

    @objc private func viewMoved() {
        needsDisplay = true
        window?.invalidateCursorRects(for: self)
    }

    // MARK: Geometry

    private var insets: PageInsets { live ?? handles.insets }

    /// The pages in scope that are on screen, each with its whole box and the part kept, in this view's coordinates.
    private func visibleFrames() -> [(page: PDFPage, whole: CGRect, kept: CGRect)] {
        guard let pdfView else { return [] }
        let visible = pdfView.visiblePages
        return visible.compactMap { page in
            let index = document.pdf.index(for: page)
            guard index >= 0, handles.pages.contains(index) else { return nil }
            let box = page.bounds(for: .cropBox)
            guard let kept = insets.kept(in: box, rotation: page.rotation) else { return nil }
            return (page, convert(pdfView.convert(box, from: page), from: pdfView), convert(pdfView.convert(kept, from: page), from: pdfView))
        }
    }

    private var slop: CGFloat { Self.handleSize }

    // MARK: Drawing

    override func draw(_ dirtyRect: NSRect) {
        guard let context = NSGraphicsContext.current?.cgContext else { return }
        let accent = NSColor.controlAccentColor.cgColor
        for frame in visibleFrames() {
            context.saveGState()
            context.addRect(frame.whole)
            context.addRect(frame.kept)
            context.setFillColor(CGColor(gray: 0, alpha: 0.35))
            context.fillPath(using: .evenOdd)
            context.setStrokeColor(accent)
            context.setLineWidth(1.5)
            context.stroke(frame.kept)
            for handle in CropFrame.Handle.all {
                let p = handle.point(on: frame.kept)
                let square = CGRect(x: p.x - Self.handleSize / 2, y: p.y - Self.handleSize / 2, width: Self.handleSize, height: Self.handleSize)
                context.setFillColor(CGColor(gray: 1, alpha: 1))
                context.fill(square)
                context.setLineWidth(1)
                context.stroke(square)
            }
            context.restoreGState()
        }
    }

    // MARK: Mouse

    /// Only handles and edges take the mouse; everything else goes to the document.
    override func hitTest(_ point: NSPoint) -> NSView? {
        let local = convert(point, from: superview)
        return visibleFrames().contains { CropFrame.handle(at: local, on: $0.kept, slop: slop) != nil } ? self : nil
    }

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func resetCursorRects() {
        for frame in visibleFrames() {
            for handle in CropFrame.Handle.all {
                let p = handle.point(on: frame.kept)
                let rect: CGRect = switch (handle.dx, handle.dy) {
                case (0, _): CGRect(x: frame.kept.minX + slop, y: p.y - slop, width: max(frame.kept.width - 2 * slop, 0), height: 2 * slop)
                case (_, 0): CGRect(x: p.x - slop, y: frame.kept.minY + slop, width: 2 * slop, height: max(frame.kept.height - 2 * slop, 0))
                default: CGRect(x: p.x - slop, y: p.y - slop, width: 2 * slop, height: 2 * slop)
                }
                addCursorRect(rect, cursor: handle.cursor)
            }
        }
    }

    override func mouseDown(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        for frame in visibleFrames() {
            if let handle = CropFrame.handle(at: point, on: frame.kept, slop: slop) {
                drag = (frame.page, handle, point, frame.kept)
                return
            }
        }
    }

    override func mouseDragged(with event: NSEvent) {
        guard let next = draggedInsets(event) else { return }
        live = next
        needsDisplay = true
    }

    override func mouseUp(with event: NSEvent) {
        let next = draggedInsets(event)
        drag = nil
        live = nil
        guard let next, next != handles.insets else { needsDisplay = true; return }
        handles.insets = next
        handles.changed(next)
    }

    /// The margins the drag so far gives, worked out on the page it started on.
    private func draggedInsets(_ event: NSEvent) -> PageInsets? {
        guard let drag, let pdfView else { return nil }
        let point = convert(event.locationInWindow, from: nil)
        let box = drag.page.bounds(for: .cropBox)
        let whole = convert(pdfView.convert(box, from: drag.page), from: pdfView)
        let minimum = Self.minimumSide * max(pdfView.scaleFactor, 0.01)
        let rect = CropFrame.dragged(drag.original, handle: drag.handle, by: CGSize(width: point.x - drag.start.x, height: point.y - drag.start.y),
                                     within: whole, minimum: minimum)
        let kept = pdfView.convert(convert(rect, to: pdfView), to: drag.page).intersection(box)
        guard !kept.isNull else { return nil }
        let insets = PageInsets(box: box, kept: kept, rotation: drag.page.rotation)
        func clean(_ value: Double) -> Double { max(0, (value * 10).rounded() / 10) }
        return PageInsets(top: clean(insets.top), left: clean(insets.left), bottom: clean(insets.bottom), right: clean(insets.right))
    }
}
