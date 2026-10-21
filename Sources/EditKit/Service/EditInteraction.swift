import AppKit
import PDFKit
import SuperPDFCore

// The document's side of Edit text & images (ux §5.2 D: "the document becomes interactive"): while the panel is open a
// transparent view sits over the PDF view. A click on a paragraph opens it for typing right there, in its own font
// and size; a click on a picture selects it with handles to drag and resize; clicks elsewhere commit. The palette
// view in the panel installs and removes the overlay, so closing the panel ends the mode.

/// The panel's line for the mode; while it is in a window the document takes clicks.
@MainActor
final class EditModePalette: NSView {
    private let session: EditModeSession
    private weak var interaction: EditInteractionView?

    init(session: EditModeSession) {
        self.session = session
        super.init(frame: NSRect(x: 0, y: 0, width: 280, height: 30))
        let label = NSTextField(wrappingLabelWithString: EditKitStrings.Edit.shortcuts)
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
            guard interaction == nil, let pdfView = Services.viewer?.pdfView(for: session.document) else { return }
            let view = EditInteractionView(pdfView: pdfView, session: session)
            view.frame = pdfView.bounds
            view.autoresizingMask = [.width, .height]
            pdfView.addSubview(view)
            interaction = view
        } else {
            interaction?.finish()
            interaction?.removeFromSuperview()
            interaction = nil
        }
    }
}

/// Over the PDF view: clicks select, paragraphs are typed into in place, pictures drag and resize.
@MainActor
final class EditInteractionView: NSView, NSTextViewDelegate {
    private weak var pdfView: PDFView?
    private let session: EditModeSession
    private var editor: InlineTextView?
    private var editorPage: PDFPage?
    private var editorBlock: TextBlock?
    private var drag: (start: CGPoint, bounds: CGRect, handle: Int?)?
    private var dragRect: CGRect?
    private var observers: [Any] = []

    init(pdfView: PDFView, session: EditModeSession) {
        self.pdfView = pdfView
        self.session = session
        super.init(frame: pdfView.bounds)
        setAccessibilityElement(false)
        session.onChange = { [weak self] in self?.selectionChanged() }
        session.onStyleChange = { [weak self] in self?.applyPendingStyle() }
        let center = NotificationCenter.default
        observers.append(center.addObserver(forName: .PDFViewScaleChanged, object: pdfView, queue: .main) { [weak self] _ in MainActor.assumeIsolated { self?.reposition() } })
        if let clip = pdfView.documentView?.enclosingScrollView?.contentView {
            clip.postsBoundsChangedNotifications = true
            observers.append(center.addObserver(forName: NSView.boundsDidChangeNotification, object: clip, queue: .main) { [weak self] _ in MainActor.assumeIsolated { self?.reposition() } })
        }
    }

    @available(*, unavailable) required init?(coder: NSCoder) { fatalError() }

    deinit { observers.forEach(NotificationCenter.default.removeObserver) }

    /// Commits what is being typed and takes the overlay down.
    func finish() {
        commitEditor()
        session.onChange = nil
        session.onStyleChange = nil
    }

    override func resetCursorRects() {
        addCursorRect(bounds, cursor: session.tool == .select ? .iBeam : .crosshair)
    }

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    override var acceptsFirstResponder: Bool { true }
    override func scrollWheel(with event: NSEvent) { pdfView?.documentView?.enclosingScrollView?.scrollWheel(with: event) }
    override func magnify(with event: NSEvent) { pdfView?.magnify(with: event) }

    // MARK: Geometry

    private func location(_ event: NSEvent) -> (page: PDFPage, index: Int, point: CGPoint, inView: CGPoint)? {
        guard let pdfView else { return nil }
        let inView = pdfView.convert(event.locationInWindow, from: nil)
        guard let page = pdfView.page(for: inView, nearest: true) else { return nil }
        let index = session.document.pdf.index(for: page)
        guard index >= 0 else { return nil }
        return (page, index, pdfView.convert(inView, to: page), inView)
    }

    /// A page-space rectangle in this view's coordinates.
    private func viewRect(_ rect: CGRect, on page: PDFPage) -> CGRect {
        guard let pdfView else { return .zero }
        return convert(pdfView.convert(rect, from: page), from: pdfView)
    }

    private func page(at index: Int) -> PDFPage? { session.document.pdf.page(at: index) }

    // MARK: Mouse

    override func mouseDown(with event: NSEvent) {
        guard let here = location(event) else { return }
        if let editor, editorPage == here.page || true {
            if editor.frame.contains(convert(event.locationInWindow, from: nil)) {
                window?.makeFirstResponder(editor)
                editor.mouseDown(with: event)
                return
            }
            commitEditor()
        }
        if case .image(let index, _)? = session.selection, let image = session.image(), let page = page(at: index) {
            let box = viewRect(image.bounds, on: page)
            if let handle = handles(of: box).firstIndex(where: { $0.insetBy(dx: -3, dy: -3).contains(here.inView) }) {
                drag = (here.inView, image.bounds, handle)
                return
            }
            if box.contains(here.inView) {
                drag = (here.inView, image.bounds, nil)
                return
            }
        }
        Task { @MainActor in
            await session.click(page: here.index, at: here.point)
            if case .block? = session.selection { openEditor() }
        }
    }

    override func mouseDragged(with event: NSEvent) {
        guard let drag, let pdfView, let here = location(event), case .image(let index, _)? = session.selection, let page = page(at: index) else { return }
        let start = pdfView.convert(convert(drag.start, to: pdfView), to: page)
        let dx = here.point.x - start.x, dy = here.point.y - start.y
        var rect = drag.bounds
        if let handle = drag.handle {
            // Corners 0…3: bottom-left, bottom-right, top-right, top-left; the aspect is kept.
            let aspect = drag.bounds.width / max(drag.bounds.height, 0.001)
            switch handle {
            case 0: rect = CGRect(x: rect.minX + dx, y: rect.minY + dx / aspect, width: rect.width - dx, height: rect.height - dx / aspect)
            case 1: rect = CGRect(x: rect.minX, y: rect.minY - dx / aspect, width: rect.width + dx, height: rect.height + dx / aspect)
            case 2: rect = CGRect(x: rect.minX, y: rect.minY, width: rect.width + dx, height: rect.height + dx / aspect)
            default: rect = CGRect(x: rect.minX + dx, y: rect.minY, width: rect.width - dx, height: rect.height - dx / aspect)
            }
            if rect.width < 8 || rect.height < 8 { return }
        } else {
            rect = rect.offsetBy(dx: dx, dy: dy)
        }
        dragRect = rect
        needsDisplay = true
    }

    override func mouseUp(with event: NSEvent) {
        defer { drag = nil; dragRect = nil; needsDisplay = true }
        guard drag != nil, let rect = dragRect else { return }
        Task { @MainActor in try? await session.moveImage(to: rect) }
    }

    override func keyDown(with event: NSEvent) {
        if event.keyCode == 51 || event.keyCode == 117, case .image? = session.selection {   // ⌫, ⌦
            Task { @MainActor in try? await session.deleteSelection() }
        } else {
            super.keyDown(with: event)
        }
    }

    // MARK: The inline editor

    /// Opens the selected block for typing, in its font at the view's zoom.
    func openEditor() {
        guard case .block(let index, _)? = session.selection, let block = session.block(), let page = page(at: index), let pdfView else { return }
        guard block.isEditable else { return }
        commitEditor()
        let scale = pdfView.scaleFactor
        let editor = InlineTextView(frame: viewRect(block.bounds, on: page).insetBy(dx: -4, dy: -4))
        editor.font = Self.font(for: block, scale: scale, style: session.pendingStyle)
        editor.textColor = NSColor(hex: session.pendingStyle.color ?? block.style.colorHex ?? "#000000")
        editor.alignment = Self.alignment(session.pendingStyle.alignment ?? block.alignment)
        editor.string = block.text
        editor.delegate = self
        editor.onEscape = { [weak self] in self?.cancelEditor() }
        editor.onCommit = { [weak self] in self?.commitEditor() }
        addSubview(editor)
        self.editor = editor
        editorPage = page
        editorBlock = block
        window?.makeFirstResponder(editor)
        editor.selectAll(nil)
    }

    private static func font(for block: TextBlock, scale: CGFloat, style: EditModeSession.Style) -> NSFont {
        let size = CGFloat(style.size ?? block.style.pageFontSize) * scale
        let facts = block.style.font.facts
        if style.fontFamily != nil || style.bold != nil || style.italic != nil {
            let family = style.fontFamily ?? FontMatcher.match(facts, size: size).font.familyName ?? "Helvetica"
            return FontMatcher.installedFont(family: family, bold: style.bold ?? facts.isBold, italic: style.italic ?? facts.isItalic, size: size) ?? NSFont.systemFont(ofSize: size)
        }
        return FontMatcher.match(facts, size: size).font
    }

    private static func alignment(_ alignment: TextAlignment) -> NSTextAlignment {
        switch alignment {
        case .left: .left
        case .center: .center
        case .right: .right
        case .justified: .justified
        }
    }

    /// The panel changed the font, size, colour or alignment: the editor shows it at once.
    private func applyPendingStyle() {
        guard let editor, let block = editorBlock, let pdfView else { return }
        editor.font = Self.font(for: block, scale: pdfView.scaleFactor, style: session.pendingStyle)
        if let color = session.pendingStyle.color { editor.textColor = NSColor(hex: color) }
        if let alignment = session.pendingStyle.alignment { editor.alignment = Self.alignment(alignment) }
    }

    func commitEditor() {
        guard let editor else { return }
        let text = editor.string
        closeEditor()
        Task { @MainActor in try? await session.commitText(text) }
    }

    private func cancelEditor() {
        closeEditor()
        session.select(nil)
    }

    private func closeEditor() {
        editor?.removeFromSuperview()
        editor = nil
        editorPage = nil
        editorBlock = nil
        window?.makeFirstResponder(self)
    }

    private func reposition() {
        guard let editor, let page = editorPage, let block = editorBlock, let pdfView else { needsDisplay = true; return }
        editor.frame = viewRect(block.bounds, on: page).insetBy(dx: -4, dy: -4)
        editor.font = Self.font(for: block, scale: pdfView.scaleFactor, style: session.pendingStyle)
        needsDisplay = true
    }

    private func selectionChanged() {
        if case .block? = session.selection {} else if editor != nil { closeEditor() }
        window?.invalidateCursorRects(for: self)
        needsDisplay = true
    }

    // MARK: Drawing

    private func handles(of box: CGRect) -> [CGRect] {
        [CGPoint(x: box.minX, y: box.minY), CGPoint(x: box.maxX, y: box.minY), CGPoint(x: box.maxX, y: box.maxY), CGPoint(x: box.minX, y: box.maxY)]
            .map { CGRect(x: $0.x - 4, y: $0.y - 4, width: 8, height: 8) }
    }

    override func draw(_ dirtyRect: NSRect) {
        guard let pdfView else { return }
        let accent = NSColor.controlAccentColor
        if case .image(let index, _)? = session.selection, let image = session.image(), let page = page(at: index) {
            let box = dragRect.map { convert(pdfView.convert($0, from: page), from: pdfView) } ?? viewRect(image.bounds, on: page)
            accent.withAlphaComponent(0.08).setFill()
            box.fill()
            let path = NSBezierPath(rect: box)
            path.lineWidth = 1.5
            accent.setStroke()
            path.stroke()
            for handle in handles(of: box) {
                NSColor.white.setFill()
                NSBezierPath(ovalIn: handle).fill()
                accent.setStroke()
                NSBezierPath(ovalIn: handle.insetBy(dx: 0.5, dy: 0.5)).stroke()
            }
        }
        if editor == nil, case .block(let index, _)? = session.selection, let block = session.block(), let page = page(at: index) {
            let path = NSBezierPath(rect: viewRect(block.bounds, on: page).insetBy(dx: -3, dy: -3))
            path.lineWidth = 1
            accent.setStroke()
            path.stroke()
        }
    }
}

/// The text view a paragraph is typed into: its own font, a light card, Esc cancels, ⌘↩ commits.
@MainActor
final class InlineTextView: NSTextView {
    var onEscape: (() -> Void)?
    var onCommit: (() -> Void)?

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)   // builds the text storage, layout manager and container
        isRichText = false
        isEditable = true
        isSelectable = true
        allowsUndo = true
        drawsBackground = true
        backgroundColor = NSColor.textBackgroundColor.withAlphaComponent(0.92)
        textContainerInset = NSSize(width: 2, height: 2)
        wantsLayer = true
        layer?.borderWidth = 1.5
        layer?.borderColor = NSColor.controlAccentColor.cgColor
        layer?.cornerRadius = 3
        isAutomaticQuoteSubstitutionEnabled = false
        isAutomaticDashSubstitutionEnabled = false
        isContinuousSpellCheckingEnabled = true   // features #73: the system checker in edit-text blocks
    }

    override init(frame frameRect: NSRect, textContainer container: NSTextContainer?) { super.init(frame: frameRect, textContainer: container) }

    @available(*, unavailable) required init?(coder: NSCoder) { fatalError() }

    override func cancelOperation(_ sender: Any?) { onEscape?() }

    override func keyDown(with event: NSEvent) {
        if event.keyCode == 36, event.modifierFlags.contains(.command) { onCommit?(); return }
        super.keyDown(with: event)
    }
}
