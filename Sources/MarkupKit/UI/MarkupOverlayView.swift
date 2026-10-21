import AppKit
import AVFoundation
import PDFKit
import SuperPDFCore

/// The transparent layer MarkupKit lays over the document's PDFView (ARCHITECTURE: `ViewerPresenting.pdfView` is "for
/// overlays and selections"). In Text Selection mode it only takes clicks on markup, so PDFView keeps text selection,
/// links and form fields; in every other mode it turns drags into markup. Points are converted to page space at once;
/// what it draws (strokes in progress, handles, the snapshot area) is converted back on every draw, so scrolling and
/// zooming need nothing but a redraw.
@MainActor
final class MarkupOverlayView: NSView, NSTextViewDelegate {
    unowned let session: MarkupSession
    private weak var pdfView: PDFView?

    private enum Gesture {
        case stroke(PDFPage, [CGPoint])
        case shape(ShapeKind, PDFPage, CGPoint, CGPoint)
        case text(PDFPage, CGPoint, CGPoint)
        case snapshot(PDFPage, CGPoint, CGPoint)
        case distance(PDFPage, CGPoint, CGPoint)
        case outline(MeasureKind, PDFPage, [CGPoint], hover: CGPoint?)
        case move(PDFPage, start: CGPoint, last: CGPoint)
        case resize(PDFPage, Handle, CGRect)
        case lineEnd(PDFPage, end: Int, CGPoint, CGPoint)
    }

    /// A selection handle: a corner or edge of a box (dx, dy in -1…1), or an end of a line.
    private enum Handle: Equatable {
        case box(dx: Int, dy: Int)
        case lineEnd(Int)
    }

    private var gesture: Gesture?
    private var editor: NSTextView?
    private var editing: (annotation: PDFAnnotation, page: PDFPage)?
    private var player: AVAudioPlayer?
    private static let handleSize: CGFloat = 7

    init(session: MarkupSession, pdfView: PDFView) {
        self.session = session
        self.pdfView = pdfView
        super.init(frame: pdfView.bounds)
        autoresizingMask = [.width, .height]
        let center = NotificationCenter.default
        for name in [Notification.Name.PDFViewScaleChanged, .PDFViewPageChanged, .PDFViewDocumentChanged, .PDFViewDisplayModeChanged] {
            center.addObserver(self, selector: #selector(viewMoved), name: name, object: pdfView)
        }
        if let clip = pdfView.documentView?.enclosingScrollView?.contentView {
            clip.postsBoundsChangedNotifications = true
            center.addObserver(self, selector: #selector(viewMoved), name: NSView.boundsDidChangeNotification, object: clip)
        }
        addTrackingArea(NSTrackingArea(rect: .zero, options: [.mouseMoved, .activeInKeyWindow, .inVisibleRect, .cursorUpdate], owner: self))
    }

    @available(*, unavailable) required init?(coder: NSCoder) { fatalError() }

    @objc private func viewMoved() {
        needsDisplay = true
        if let editing, let editor { editor.frame = editorFrame(for: editing.annotation, on: editing.page) }
    }

    override var acceptsFirstResponder: Bool { true }

    func toolChanged() {
        gesture = nil
        window?.invalidateCursorRects(for: self)
        needsDisplay = true
    }

    // MARK: Coordinates

    private func viewPoint(_ point: CGPoint, on page: PDFPage) -> CGPoint {
        guard let pdfView else { return point }
        return convert(pdfView.convert(point, from: page), from: pdfView)
    }

    private func viewRect(_ rect: CGRect, on page: PDFPage) -> CGRect {
        guard let pdfView else { return rect }
        return convert(pdfView.convert(rect, from: page), from: pdfView)
    }

    /// The page under a point of this view and the point in its space.
    private func pagePoint(_ local: CGPoint, nearest: Bool = true) -> (PDFPage, CGPoint)? {
        guard let pdfView else { return nil }
        let inView = pdfView.convert(local, from: self)
        guard let page = pdfView.page(for: inView, nearest: nearest) else { return nil }
        return (page, pdfView.convert(inView, to: page))
    }

    private func point(_ local: CGPoint, on page: PDFPage) -> CGPoint {
        guard let pdfView else { return local }
        return pdfView.convert(pdfView.convert(local, from: self), to: page)
    }

    private func markup(at local: CGPoint) -> (PDFAnnotation, PDFPage)? {
        guard let (page, point) = pagePoint(local, nearest: false) else { return nil }
        let hit = page.annotations.reversed().first { annotation in
            AnnotationLedger.isMarkup(annotation) && annotation.shouldDisplay && annotation.bounds.insetBy(dx: -2, dy: -2).contains(point)
        }
        return hit.map { ($0, page) }
    }

    // MARK: Hit testing

    override func hitTest(_ point: NSPoint) -> NSView? {
        guard !isHidden, let superview else { return nil }
        let local = convert(point, from: superview)
        guard bounds.contains(local) else { return nil }
        if let editor, editor.frame.contains(local) { return editor }
        if session.tool != .textSelection { return self }
        if handle(at: local) != nil { return self }
        guard let (annotation, _) = markup(at: local) else { return nil }
        // Highlighted words stay selectable as text; a right-click on them still reaches the markup's menu.
        if AnnotationEditing.textMarkupTypes.contains(annotation.type ?? "") { return NSApp.currentEvent?.type == .rightMouseDown ? self : nil }
        return self
    }

    /// Right-click on markup: Preview's colours for highlights, and a way to remove it.
    override func menu(for event: NSEvent) -> NSMenu? {
        guard let (annotation, page) = markup(at: convert(event.locationInWindow, from: nil)) else { return nil }
        session.select(annotation, on: page)
        let menu = NSMenu()
        if annotation.type == "Highlight" {
            for color in HighlightColor.allCases {
                let handler = MenuHandler { [unowned self] in session.restyle("Highlight Style") { $0.textMarkup = .highlight(color) } }
                let item = NSMenuItem(title: color.title, action: #selector(MenuHandler.run), keyEquivalent: "")
                item.target = handler
                item.representedObject = handler
                item.image = MarkupBarView.swatch(MarkupColor(color.color), filled: true)
                menu.addItem(item)
            }
            menu.addItem(.separator())
        }
        let title = AnnotationEditing.textMarkupTypes.contains(annotation.type ?? "") ? "Remove " + CommentList.title(of: CommentList.kind(of: annotation) ?? .highlight)
            : "Delete"
        let handler = MenuHandler { [unowned self] in session.deleteSelection() }
        let remove = NSMenuItem(title: title, action: #selector(MenuHandler.run), keyEquivalent: "")
        remove.target = handler
        remove.representedObject = handler
        menu.addItem(remove)
        return menu
    }

    override func resetCursorRects() {
        let cursor: NSCursor = switch session.tool {
        case .textSelection: .arrow
        case .highlight, .correction, .text: .iBeam
        default: .crosshair
        }
        addCursorRect(bounds, cursor: cursor)
    }

    override func scrollWheel(with event: NSEvent) { pdfView?.documentView?.enclosingScrollView?.scrollWheel(with: event) }
    override func magnify(with event: NSEvent) { pdfView?.magnify(with: event) }

    // MARK: Handles

    private func handles() -> [(Handle, CGRect)] {
        guard let (annotation, page) = session.selection else { return [] }
        let size = Self.handleSize
        func square(_ p: CGPoint) -> CGRect { CGRect(x: p.x - size / 2, y: p.y - size / 2, width: size, height: size) }
        if annotation.type == "Line" {
            let ends = Measure.kind(of: annotation) != nil ? Measure.points(of: annotation) : [AnnotationEditing.lineEnds(of: annotation).0,
                                                                                             AnnotationEditing.lineEnds(of: annotation).1]
            guard ends.count == 2 else { return [] }
            return ends.enumerated().map { (.lineEnd($0.offset), square(viewPoint($0.element, on: page))) }
        }
        guard AnnotationEditing.canResize(annotation) else { return [] }
        let rect = viewRect(annotation.bounds, on: page)
        var result: [(Handle, CGRect)] = []
        for dx in -1...1 {
            for dy in -1...1 where dx != 0 || dy != 0 {
                let p = CGPoint(x: rect.midX + CGFloat(dx) * rect.width / 2, y: rect.midY + CGFloat(dy) * rect.height / 2)
                result.append((.box(dx: dx, dy: dy), square(p)))
            }
        }
        return result
    }

    private func handle(at local: CGPoint) -> Handle? {
        handles().first { $0.1.insetBy(dx: -3, dy: -3).contains(local) }?.0
    }

    // MARK: Mouse

    override func mouseDown(with event: NSEvent) {
        let local = convert(event.locationInWindow, from: nil)
        if editing != nil { endEditing() }
        window?.makeFirstResponder(self)
        switch session.tool {
        case .textSelection:
            if let handle = handle(at: local), let (annotation, page) = session.selection {
                if case .lineEnd(let end) = handle {
                    let ends = annotation.type == "Line" && Measure.kind(of: annotation) == nil
                        ? [AnnotationEditing.lineEnds(of: annotation).0, AnnotationEditing.lineEnds(of: annotation).1] : Measure.points(of: annotation)
                    gesture = .lineEnd(page, end: end, ends[0], ends[1])
                } else {
                    gesture = .resize(page, handle, annotation.bounds)
                }
                return
            }
            guard let (annotation, page) = markup(at: local) else { session.select(nil); return }
            session.select(annotation, on: page)
            if event.clickCount == 2 { open(annotation, on: page); return }
            guard AnnotationEditing.canMove(annotation), session.editableSelection() != nil else { return }
            let p = point(local, on: page)
            gesture = .move(page, start: p, last: p)
        case .rectangularSelection:
            guard let (page, p) = pagePoint(local) else { return }
            gesture = .snapshot(page, p, p)
        case .sketch, .draw:
            guard let (page, p) = pagePoint(local) else { return }
            gesture = .stroke(page, [p])
        case .shape(let kind):
            guard let (page, p) = pagePoint(local) else { return }
            gesture = .shape(kind, page, p, p)
        case .highlight, .correction(.deleteText), .correction(.replaceText):
            guard let (page, p) = pagePoint(local) else { return }
            gesture = .text(page, p, p)
        case .correction(.insertText):
            guard let (page, p) = pagePoint(local) else { return }
            if let caret = session.markCorrection(.insertText, selection: nil, insertionPoint: p, on: page, text: "").first {
                session.select(caret, on: page)
                beginEditing(caret, on: page, selectAll: false)
            }
        case .text:
            guard let (page, p) = pagePoint(local) else { return }
            session.placeText(at: p, on: page)
            session.choose(.textSelection)
            if let (box, page) = session.selection { beginEditing(box, on: page, selectAll: true) }
        case .note:
            guard let (page, p) = pagePoint(local) else { return }
            session.placeNote(at: p, on: page)
            session.choose(.textSelection)
            if let (note, page) = session.selection { beginEditing(note, on: page, selectAll: false) }
        case .stamp(let stamp):
            guard let (page, p) = pagePoint(local) else { return }
            let placed = session.placeStamp(stamp, at: p, on: page)
            session.choose(.textSelection)
            session.select(placed, on: page)
        case .measure(.distance):
            guard let (page, p) = pagePoint(local) else { return }
            gesture = .distance(page, p, p)
        case .measure(let kind):
            guard let (page, p) = pagePoint(local) else { return }
            if case .outline(let current, let outlinePage, let points, _) = gesture, current == kind, outlinePage == page {
                let closesShape = kind == .area && points.count >= 3 && hypot(viewPoint(points[0], on: page).x - local.x, viewPoint(points[0], on: page).y - local.y) < 8
                if event.clickCount == 2 || closesShape {
                    // A double-click's first click already placed its corner.
                    session.finishMeasurement(kind, points: points, on: page)
                    gesture = nil
                } else {
                    gesture = .outline(kind, page, points + [p], hover: p)
                }
            } else {
                gesture = .outline(kind, page, [p], hover: p)
            }
        }
        needsDisplay = true
    }

    override func mouseDragged(with event: NSEvent) {
        let local = convert(event.locationInWindow, from: nil)
        let constrain = event.modifierFlags.contains(.shift)
        switch gesture {
        case .stroke(let page, let points):
            gesture = .stroke(page, points + [point(local, on: page)])
        case .shape(let kind, let page, let start, _):
            var end = point(local, on: page)
            if constrain { end = kind.isLinear ? Self.snap45(start, end) : Self.square(start, end) }
            gesture = .shape(kind, page, start, end)
        case .text(let page, let start, _):
            let end = point(local, on: page)
            gesture = .text(page, start, end)
            if let selection = textSelection(page: page, from: start, to: local) { pdfView?.setCurrentSelection(selection, animate: false) }
        case .snapshot(let page, let start, _):
            gesture = .snapshot(page, start, point(local, on: page))
        case .distance(let page, let start, _):
            let end = point(local, on: page)
            gesture = .distance(page, start, constrain ? Self.snap45(start, end) : end)
        case .move(let page, let start, let last):
            let p = point(local, on: page)
            if let (annotation, _) = session.selection { AnnotationEditing.move(annotation, by: p.x - last.x, p.y - last.y) }
            gesture = .move(page, start: start, last: p)
        case .resize(let page, let handle, let original):
            gesture = .resize(page, handle, original)
            resizePreview = resized(original, handle: handle, to: point(local, on: page), square: constrain)
        case .lineEnd(let page, let end, let a, let b):
            var p = point(local, on: page)
            if constrain { p = Self.snap45(end == 0 ? b : a, p) }
            gesture = .lineEnd(page, end: end, end == 0 ? p : a, end == 1 ? p : b)
        default:
            break
        }
        needsDisplay = true
    }

    private var resizePreview: CGRect?

    override func mouseUp(with event: NSEvent) {
        let local = convert(event.locationInWindow, from: nil)
        mouseDragged(with: event)   // where the button came up counts
        switch gesture {
        case .stroke(let page, let points):
            session.finishStroke(points, on: page)
            gesture = nil
        case .shape(let kind, let page, let start, let end):
            let made = session.finishShape(kind, from: start, to: end, on: page)
            session.choose(.textSelection)
            session.select(made, on: page)
            gesture = nil
        case .text(let page, let start, _):
            gesture = nil
            guard let selection = textSelection(page: page, from: start, to: local), !(selection.string ?? "").trimmingCharacters(in: .whitespaces).isEmpty
            else { pdfView?.clearSelection(); break }
            pdfView?.clearSelection()
            switch session.tool {
            case .highlight: session.markText(selection)
            case .correction(let kind):
                let made = session.markCorrection(kind, selection: selection, insertionPoint: nil, on: page, text: "")
                if kind == .replaceText, let caret = made.first(where: { $0.type == "Caret" }) {
                    session.select(caret, on: page)
                    beginEditing(caret, on: page, selectAll: false)
                }
            default: break
            }
        case .snapshot(let page, let start, let end):
            session.snapshotArea = (page, Geometry.rect(start, end))
            gesture = nil
        case .distance(let page, let start, let end):
            if hypot(end.x - start.x, end.y - start.y) > 2 { session.finishMeasurement(.distance, points: [start, end], on: page) }
            gesture = nil
        case .move(_, let start, let last):
            gesture = nil
            if let (annotation, _) = session.selection, last != start {
                AnnotationEditing.move(annotation, by: start.x - last.x, start.y - last.y)   // back, then once with undo
                session.moveSelection(by: last.x - start.x, last.y - start.y)
            }
        case .resize:
            gesture = nil
            if let rect = resizePreview { session.resizeSelection(to: rect) }
            resizePreview = nil
        case .lineEnd(_, _, let a, let b):
            gesture = nil
            session.setLineEnds(a, b)
        default:
            break
        }
        needsDisplay = true
    }

    override func mouseMoved(with event: NSEvent) {
        guard case .outline(let kind, let page, let points, _) = gesture else { return }
        gesture = .outline(kind, page, points, hover: point(convert(event.locationInWindow, from: nil), on: page))
        needsDisplay = true
    }

    private func textSelection(page: PDFPage, from start: CGPoint, to local: CGPoint) -> PDFSelection? {
        guard let pdfView, let document = pdfView.document, let (endPage, end) = pagePoint(local) else { return nil }
        if endPage == page { return page.selection(from: start, to: end) }
        return document.selection(from: page, at: start, to: endPage, at: end)
    }

    private func resized(_ rect: CGRect, handle: Handle, to p: CGPoint, square: Bool) -> CGRect {
        guard case .box(let dx, let dy) = handle else { return rect }
        var minX = rect.minX, maxX = rect.maxX, minY = rect.minY, maxY = rect.maxY
        if dx < 0 { minX = min(p.x, maxX - 4) }
        if dx > 0 { maxX = max(p.x, minX + 4) }
        if dy < 0 { minY = min(p.y, maxY - 4) }
        if dy > 0 { maxY = max(p.y, minY + 4) }
        var result = CGRect(x: minX, y: minY, width: maxX - minX, height: maxY - minY)
        if square, dx != 0, dy != 0 {
            let side = max(result.width, result.height)
            result = CGRect(x: dx < 0 ? maxX - side : minX, y: dy < 0 ? maxY - side : minY, width: side, height: side)
        }
        return result
    }

    static func snap45(_ start: CGPoint, _ end: CGPoint) -> CGPoint {
        let angle = (atan2(end.y - start.y, end.x - start.x) / (.pi / 4)).rounded() * (.pi / 4)
        let length = hypot(end.x - start.x, end.y - start.y)
        return CGPoint(x: start.x + cos(angle) * length, y: start.y + sin(angle) * length)
    }

    static func square(_ start: CGPoint, _ end: CGPoint) -> CGPoint {
        let side = max(abs(end.x - start.x), abs(end.y - start.y))
        return CGPoint(x: start.x + (end.x < start.x ? -side : side), y: start.y + (end.y < start.y ? -side : side))
    }

    // MARK: Keys and menu actions

    override func keyDown(with event: NSEvent) {
        let step: CGFloat = event.modifierFlags.contains(.shift) ? 10 : 1
        switch event.keyCode {
        case 51, 117: session.deleteSelection()
        case 53:
            if gesture != nil { gesture = nil; needsDisplay = true } else if session.selection != nil { session.select(nil) } else { session.choose(.textSelection) }
        case 36, 76:
            if case .outline(let kind, let page, let points, _) = gesture { session.finishMeasurement(kind, points: points, on: page); gesture = nil; needsDisplay = true }
        case 123: session.moveSelection(by: -step, 0, named: "Nudge")
        case 124: session.moveSelection(by: step, 0, named: "Nudge")
        case 125: session.moveSelection(by: 0, -step, named: "Nudge")
        case 126: session.moveSelection(by: 0, step, named: "Nudge")
        default: super.keyDown(with: event)
        }
    }

    @objc func delete(_ sender: Any?) { session.deleteSelection() }

    @objc func copy(_ sender: Any?) { session.copySnapshot() }

    override func responds(to selector: Selector!) -> Bool {
        if selector == #selector(copy(_:)) { return session.snapshotArea != nil }
        if selector == #selector(delete(_:)) { return session.selection != nil }
        return super.responds(to: selector)
    }

    // MARK: Opening an annotation (double-click)

    private func open(_ annotation: PDFAnnotation, on page: PDFPage) {
        switch annotation.type {
        case "FreeText", "Text", "Caret": beginEditing(annotation, on: page, selectAll: false)
        case "FileAttachment":
            guard let file = session.service.attachment(of: annotation, in: session.document).file else { return }
            let folder = SuperPDFPaths.work.appendingPathComponent(UUID().uuidString, isDirectory: true)
            try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            let url = folder.appendingPathComponent(file.fileName)
            guard (try? file.data.write(to: url)) != nil else { return }
            NSWorkspace.shared.open(url)
        case "Sound":
            guard let clip = session.service.attachment(of: annotation, in: session.document).sound else { return }
            player = try? AVAudioPlayer(data: Self.wave(clip))
            player?.play()
        default: break
        }
    }

    /// A WAV file of a sound object's samples (PDF stores them big-endian; WAV wants little-endian).
    static func wave(_ clip: SoundClip) -> Data {
        var samples = clip.samples
        if clip.bits == 16 {
            samples.withUnsafeMutableBytes { bytes in
                for i in stride(from: 0, to: bytes.count - 1, by: 2) { bytes.swapAt(i, i + 1) }
            }
        }
        var data = Data("RIFF".utf8)
        func append<T: FixedWidthInteger>(_ value: T) { withUnsafeBytes(of: value.littleEndian) { data.append(contentsOf: $0) } }
        let blockAlign = clip.channels * clip.bits / 8
        append(UInt32(36 + samples.count))
        data.append(contentsOf: Array("WAVEfmt ".utf8))
        append(UInt32(16)); append(UInt16(1)); append(UInt16(clip.channels)); append(UInt32(clip.rate))
        append(UInt32(Int(clip.rate) * blockAlign)); append(UInt16(blockAlign)); append(UInt16(clip.bits))
        data.append(contentsOf: Array("data".utf8))
        append(UInt32(samples.count))
        data.append(samples)
        return data
    }

    // MARK: Typing into text boxes, notes and carets

    private func editorFrame(for annotation: PDFAnnotation, on page: PDFPage) -> CGRect {
        let rect = viewRect(annotation.bounds, on: page)
        if annotation.type == "FreeText" { return rect.insetBy(dx: -2, dy: -2) }
        // Notes and carets type into a small note card beside their icon.
        return CGRect(x: rect.maxX + 4, y: rect.maxY - 110, width: 220, height: 110)
    }

    func beginEditing(_ annotation: PDFAnnotation, on page: PDFPage, selectAll: Bool) {
        guard let pdfView, window != nil else { return }
        endEditing()
        let view = NSTextView(frame: editorFrame(for: annotation, on: page))
        view.string = annotation.contents ?? ""
        view.delegate = self
        view.isRichText = false
        view.allowsUndo = true
        view.textContainerInset = NSSize(width: 2, height: 2)
        if annotation.type == "FreeText" {
            let font = annotation.font ?? NSFont(name: "Helvetica", size: 12)!
            view.font = NSFont(descriptor: font.fontDescriptor, size: font.pointSize * pdfView.scaleFactor)
            view.textColor = annotation.fontColor ?? .black
            view.alignment = annotation.alignment
            view.drawsBackground = false
        } else {
            view.font = .systemFont(ofSize: 13)
            view.textColor = .black
            view.backgroundColor = annotation.type == "Text" ? annotation.color.withAlphaComponent(1) : NSColor(hex: SPColor.noteYellow.light)
            view.wantsLayer = true
            view.layer?.borderColor = NSColor.separatorColor.cgColor
            view.layer?.borderWidth = 1
            view.layer?.cornerRadius = 4
        }
        addSubview(view)
        editor = view
        editing = (annotation, page)
        window?.makeFirstResponder(view)
        if selectAll { view.selectAll(nil) }
    }

    func endEditing() {
        guard let editor, let editing else { return }
        self.editor = nil
        self.editing = nil
        session.setText(editor.string, of: editing.annotation)
        editor.removeFromSuperview()
        window?.makeFirstResponder(self)
    }

    func textDidEndEditing(_ notification: Notification) { endEditing() }

    func textView(_ textView: NSTextView, doCommandBy selector: Selector) -> Bool {
        if selector == #selector(cancelOperation(_:)) { endEditing(); return true }
        return false
    }

    // MARK: Drawing

    override func draw(_ dirtyRect: NSRect) {
        guard let context = NSGraphicsContext.current?.cgContext else { return }
        let accent = NSColor.controlAccentColor.cgColor
        let style = session.style
        context.setLineCap(.round)
        context.setLineJoin(.round)
        switch gesture {
        case .stroke(let page, let points):
            context.setStrokeColor(style.stroke.nsColor.cgColor)
            context.setLineWidth(CGFloat(style.lineWidth) * (pdfView?.scaleFactor ?? 1))
            context.addPath(Geometry.path(through: points.map { viewPoint($0, on: page) }, closed: false))
            context.strokePath()
        case .shape(let kind, let page, let start, let end):
            let a = viewPoint(start, on: page), b = viewPoint(end, on: page)
            context.setStrokeColor(style.stroke.nsColor.cgColor)
            context.setLineWidth(max(1, CGFloat(style.lineWidth) * (pdfView?.scaleFactor ?? 1)))
            switch kind {
            case .line, .arrow: context.move(to: a); context.addLine(to: b)
            case .oval, .loupe: context.addEllipse(in: Geometry.rect(a, b))
            case .star: context.addPath(Geometry.path(through: Geometry.star(in: Geometry.rect(a, b)), closed: true))
            case .polygon: context.addPath(Geometry.path(through: Geometry.hexagon(in: Geometry.rect(a, b)), closed: true))
            case .speechBubble: context.addPath(Geometry.path(through: Geometry.speechBubble(in: Geometry.rect(a, b)), closed: true))
            default: context.addRect(Geometry.rect(a, b))
            }
            context.strokePath()
        case .snapshot(let page, let start, let end):
            dashedRect(Geometry.rect(viewPoint(start, on: page), viewPoint(end, on: page)), in: context)
        case .distance(let page, let start, let end):
            drawMeasure(.distance, [start, end], on: page, in: context)
        case .outline(let kind, let page, let points, let hover):
            drawMeasure(kind, points + (hover.map { [$0] } ?? []), on: page, in: context)
        case .lineEnd(let page, _, let a, let b):
            context.setStrokeColor(accent)
            context.setLineWidth(1)
            context.move(to: viewPoint(a, on: page)); context.addLine(to: viewPoint(b, on: page))
            context.strokePath()
        default:
            break
        }
        if gesture == nil, let (page, rect) = session.snapshotArea { dashedRect(viewRect(rect, on: page), in: context) }
        if let (annotation, page) = session.selection {
            let rect = viewRect(resizePreview ?? annotation.bounds, on: page)
            context.setStrokeColor(accent)
            context.setLineWidth(1)
            if annotation.type != "Line" { context.stroke(rect.insetBy(dx: -1.5, dy: -1.5)) }
            for (_, square) in handles() {
                context.setFillColor(.white)
                context.fill(square)
                context.stroke(square)
            }
        }
    }

    private func dashedRect(_ rect: CGRect, in context: CGContext) {
        context.setStrokeColor(.black)
        context.setLineWidth(1)
        context.setLineDash(phase: 0, lengths: [4, 4])
        context.stroke(rect)
        context.setStrokeColor(.white)
        context.setLineDash(phase: 4, lengths: [4, 4])
        context.stroke(rect)
        context.setLineDash(phase: 0, lengths: [])
    }

    private func drawMeasure(_ kind: MeasureKind, _ points: [CGPoint], on page: PDFPage, in context: CGContext) {
        let view = points.map { viewPoint($0, on: page) }
        context.setStrokeColor(session.style.stroke.nsColor.cgColor)
        context.setLineWidth(1.5)
        context.addPath(Geometry.path(through: view, closed: kind == .area))
        context.strokePath()
        let index = session.document.pdf.index(for: page)
        let label = Measure.label(kind, points: points, scale: session.service.scale(in: session.document, page: index))
        DrawnAnnotation.drawLabel(label, near: view, closed: kind == .area, color: session.style.stroke.nsColor.cgColor, in: context)
    }
}
