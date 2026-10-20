import AppKit
import PDFKit
import SuperPDFCore

/// The live preview over the pages (ux §5.1): one `PDFPageOverlayViewProvider` per document view whose overlay views
/// call the open panel's `ToolPreview.overlay` drawing in page space. Nothing is committed; clicks pass through.
@MainActor
final class PreviewOverlay: NSObject, PDFPageOverlayViewProvider {
    typealias Draw = @MainActor (_ page: PDFPage, _ context: CGContext) -> Void

    /// The drawing of the open panel's preview; nil draws nothing.
    var draw: Draw? {
        didSet { for view in views.allObjects { view.needsDisplay = true } }
    }

    private let views = NSHashTable<PageOverlayView>.weakObjects()

    /// PDFView holds its overlay provider weakly; ToolsKit keeps one per view for as long as the view lives.
    private static let byView = NSMapTable<PDFView, PreviewOverlay>.weakToStrongObjects()

    /// The overlay of a PDF view, installed on first use. PDFKit asks for overlay views when it lays out pages, so the
    /// pages already on screen are laid out again (the view keeps its place).
    static func installed(on pdfView: PDFView) -> PreviewOverlay {
        if let existing = byView.object(forKey: pdfView), pdfView.pageOverlayViewProvider === existing { return existing }
        let overlay = PreviewOverlay()
        byView.setObject(overlay, forKey: pdfView)
        pdfView.pageOverlayViewProvider = overlay
        if let document = pdfView.document {
            let place = pdfView.currentDestination
            pdfView.document = nil
            pdfView.document = document
            if let place { pdfView.go(to: place) }
        }
        return overlay
    }

    var overlayViewCount: Int { views.count }

    nonisolated func pdfView(_ view: PDFView, overlayViewFor page: PDFPage) -> NSView? {
        MainActor.assumeIsolated {
            let overlay = PageOverlayView(page: page, owner: self, box: view.displayBox)
            views.add(overlay)
            return overlay
        }
    }
}

/// One page's overlay: maps page space (points from the box's lower-left) onto the view, rotation included.
@MainActor
final class PageOverlayView: NSView {
    private let page: PDFPage
    private weak var owner: PreviewOverlay?
    private let box: PDFDisplayBox

    init(page: PDFPage, owner: PreviewOverlay, box: PDFDisplayBox) {
        self.page = page
        self.owner = owner
        self.box = box
        super.init(frame: .zero)
        setAccessibilityElement(false)
    }

    @available(*, unavailable) required init?(coder: NSCoder) { fatalError() }

    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    override func draw(_ dirtyRect: NSRect) {
        guard let draw = owner?.draw, let context = NSGraphicsContext.current?.cgContext else { return }
        context.saveGState()
        context.concatenate(Self.pageTransform(pageBox: page.bounds(for: box), rotation: page.rotation, viewSize: bounds.size))
        draw(page, context)
        context.restoreGState()
    }

    /// Page space → view space for a page shown rotated by `rotation` (0, 90, 180, 270) and scaled into `viewSize`.
    static func pageTransform(pageBox: CGRect, rotation: Int, viewSize: CGSize) -> CGAffineTransform {
        let w = pageBox.width, h = pageBox.height
        let turns = ((rotation % 360) + 360) % 360 / 90
        let shown = turns % 2 == 0 ? CGSize(width: w, height: h) : CGSize(width: h, height: w)
        let scale = shown.width > 0 ? viewSize.width / shown.width : 1
        let rotate: CGAffineTransform = switch turns {
        case 1: CGAffineTransform(a: 0, b: -1, c: 1, d: 0, tx: 0, ty: w)
        case 2: CGAffineTransform(a: -1, b: 0, c: 0, d: -1, tx: w, ty: h)
        case 3: CGAffineTransform(a: 0, b: 1, c: -1, d: 0, tx: h, ty: 0)
        default: .identity
        }
        return CGAffineTransform(translationX: -pageBox.minX, y: -pageBox.minY)
            .concatenating(rotate)
            .concatenating(CGAffineTransform(scaleX: scale, y: scale))
    }
}
