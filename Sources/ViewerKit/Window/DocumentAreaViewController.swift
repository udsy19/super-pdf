import AppKit
import PDFKit
import SuperPDFCore

/// The document well (ux §2.1): PDFKit's view with Preview's defaults — under-page grey, page shadows, 4/4.75 pt page
/// breaks, continuous scroll, scale 0.1–20 — taking drops for the whole page area (ux §3), and the floating panel card
/// when the window is too narrow for the inline slot.
@MainActor
final class DocumentAreaViewController: NSViewController {
    weak var owner: DocumentWindowController?
    let pdfView = DocumentPDFView()
    private(set) var overlayPanel: NSViewController?
    private let overlayCard = NSView()

    override func loadView() {
        let root = NSView(frame: NSRect(x: 0, y: 0, width: 700, height: 700))
        pdfView.displayMode = .singlePageContinuous
        pdfView.displaysPageBreaks = true
        pdfView.pageBreakMargins = SPMetrics.Document.pageBreakMargins
        pdfView.backgroundColor = .underPageBackgroundColor
        pdfView.pageShadowsEnabled = true
        pdfView.minScaleFactor = SPMetrics.Document.scaleRange.lowerBound
        pdfView.maxScaleFactor = SPMetrics.Document.scaleRange.upperBound
        pdfView.frame = root.bounds
        pdfView.autoresizingMask = [.width, .height]
        pdfView.area = self
        root.addSubview(pdfView)

        overlayCard.wantsLayer = true
        overlayCard.layer?.cornerRadius = 12
        overlayCard.layer?.masksToBounds = false
        overlayCard.shadow = {
            let shadow = NSShadow()
            shadow.shadowBlurRadius = 20
            shadow.shadowColor = NSColor.black.withAlphaComponent(0.25)
            shadow.shadowOffset = NSSize(width: 0, height: -6)
            return shadow
        }()
        overlayCard.isHidden = true
        overlayCard.translatesAutoresizingMaskIntoConstraints = false
        root.addSubview(overlayCard)
        NSLayoutConstraint.activate([
            overlayCard.topAnchor.constraint(equalTo: root.topAnchor, constant: 12),
            overlayCard.bottomAnchor.constraint(equalTo: root.bottomAnchor, constant: -12),
            overlayCard.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -12),
            overlayCard.widthAnchor.constraint(equalToConstant: SPMetrics.ToolPanel.width),
        ])
        view = root
    }

    /// A panel floating over the document as a card (window narrower than 1000 pt, ux §2.1).
    func setOverlayPanel(_ panel: NSViewController?) {
        _ = view
        if let overlayPanel { overlayPanel.view.removeFromSuperview(); overlayPanel.removeFromParent() }
        overlayPanel = panel
        overlayCard.isHidden = panel == nil
        guard let panel else { return }
        addChild(panel)
        panel.view.frame = overlayCard.bounds
        panel.view.autoresizingMask = [.width, .height]
        panel.view.wantsLayer = true
        panel.view.layer?.cornerRadius = 12
        panel.view.layer?.masksToBounds = true
        overlayCard.addSubview(panel.view)
    }

    // MARK: Drops on the page area (ux §3): files open, text becomes a text box

    func decision(for info: NSDraggingInfo) -> DropDecision {
        guard let owner else { return DropDecision(.none) }
        let pasteboard = info.draggingPasteboard
        let payload: DropPayload
        if let pages = PagesPromiseProvider.read(pasteboard) {
            payload = .pages(from: pages.document, indices: pages.pages)
        } else if let urls = pasteboard.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as? [URL], !urls.isEmpty {
            payload = .files(urls.map { DroppedFile(url: $0, canConvert: { Services.convert?.canConvertToPDF($0) ?? false }) })
        } else if let text = pasteboard.string(forType: .string) {
            payload = .text(text)
        } else {
            return DropDecision(.none)
        }
        return DropDecision.decide(payload, onto: .pageArea, of: owner.handle.id, isLocked: owner.handle.state.isLocked)
    }

    func perform(_ decision: DropDecision, at windowPoint: NSPoint) -> Bool {
        guard let owner else { return false }
        switch decision.outcome {
        case .open(let urls):
            owner.viewer.open(urls, from: owner.window)
        case .addText(let text):
            let point = pdfView.convert(windowPoint, from: nil)
            guard let page = pdfView.page(for: point, nearest: true) else { return false }
            owner.pageActions.addText(text, on: page, at: pdfView.convert(point, to: page))
        default:
            return false
        }
        return true
    }
}

/// The PDFView of a document window, taking drops for the page area with the window-wide accent ring and label.
final class DocumentPDFView: PDFView {
    weak var area: DocumentAreaViewController?
    private let highlight = DropHighlightView()
    private var current: DropDecision?

    override init(frame: NSRect) {
        super.init(frame: frame)
        registerForDraggedTypes([.fileURL, .string, .superPDFPages])
        highlight.isHidden = true
        highlight.frame = bounds
        highlight.autoresizingMask = [.width, .height]
        addSubview(highlight)
    }

    required init?(coder: NSCoder) { fatalError("not used") }

    /// Zoom to Fit follows the window's size.
    override func setFrameSize(_ newSize: NSSize) {
        super.setFrameSize(newSize)
        area?.owner?.fitPage()
    }

    override func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation { update(sender) }
    override func draggingUpdated(_ sender: NSDraggingInfo) -> NSDragOperation { update(sender) }

    override func draggingExited(_ sender: NSDraggingInfo?) {
        current = nil
        highlight.isHidden = true
    }

    override func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
        highlight.isHidden = true
        guard let decision = current ?? area?.decision(for: sender), decision.isAllowed else { return false }
        current = nil
        return area?.perform(decision, at: sender.draggingLocation) ?? false
    }

    private func update(_ info: NSDraggingInfo) -> NSDragOperation {
        let decision = area?.decision(for: info) ?? DropDecision(.none)
        current = decision
        switch decision.outcome {
        case .open, .addText:
            highlight.label = decision.label
            highlight.isRefusal = false
            highlight.isHidden = false
            addSubview(highlight, positioned: .above, relativeTo: nil)
            return .copy
        case .refuse(let reason):
            highlight.label = reason
            highlight.isRefusal = true
            highlight.isHidden = false
            return []
        default:
            highlight.isHidden = true
            return []
        }
    }
}

/// The window-wide drop target: a 2 pt accent ring, 8 % accent tint and the label in a pill (ux §2.5, §3).
final class DropHighlightView: NSView {
    var label: String? { didSet { needsDisplay = true } }
    var isRefusal = false { didSet { needsDisplay = true } }

    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    override func draw(_ dirtyRect: NSRect) {
        let accent = SPColor.accent.color
        if !isRefusal {
            let ring = NSBezierPath(roundedRect: bounds.insetBy(dx: 1, dy: 1), xRadius: 10, yRadius: 10)
            accent.withAlphaComponent(SPMetrics.DropTarget.tintOpacity).setFill()
            ring.fill()
            ring.lineWidth = SPMetrics.DropTarget.ring
            accent.setStroke()
            ring.stroke()
        }
        guard let label else { return }
        let text = NSAttributedString(string: label, attributes: [.font: SPFont.bannerEmphasis.font(),
                                                                  .foregroundColor: isRefusal ? SPColor.label.color : NSColor.white])
        let size = text.size()
        let pill = NSRect(x: bounds.midX - size.width / 2 - 14, y: bounds.midY - 16, width: size.width + 28, height: 32)
        let path = NSBezierPath(roundedRect: pill, xRadius: 10, yRadius: 10)
        (isRefusal ? SPColor.controlBackground.color : accent).setFill()
        path.fill()
        text.draw(at: NSPoint(x: pill.minX + 14, y: pill.midY - size.height / 2))
    }
}
