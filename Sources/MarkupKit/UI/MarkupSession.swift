import AppKit
import PDFKit
import SuperPDFCore

/// One document's markup: the bar under the toolbar, the layer over its PDFView that turns drags into markup, the
/// chosen tool and the selected annotation. Everything that changes the document goes through here as one undo step.
/// The gesture methods take page-space input, so the self-test drives them without a window.
@MainActor
final class MarkupSession: NSObject {
    let document: DocumentHandle
    unowned let service: MarkupService
    private(set) var tool: MarkupTool = .textSelection
    private(set) var isBarVisible = false
    /// The annotation with handles (Text Selection mode), and its page.
    private(set) var selection: (annotation: PDFAnnotation, page: PDFPage)?
    /// The last distance drawn, for the Measure panel's "Set scale" (page index, length in points).
    private(set) var lastDistance: (page: Int, points: Double)?
    /// Rectangular Selection's area, for Copy.
    var snapshotArea: (page: PDFPage, rect: CGRect)? { didSet { overlay?.needsDisplay = true } }

    private var accessory: NSTitlebarAccessoryViewController?
    private(set) var bar: MarkupBarView?
    private(set) var overlay: MarkupOverlayView?
    private var observers: [UUID: @MainActor () -> Void] = [:]

    init(document: DocumentHandle, service: MarkupService) {
        self.document = document
        self.service = service
    }

    var pdfView: PDFView? { Services.viewer?.pdfView(for: document) }
    var author: String { service.authorName }
    var ledger: AnnotationLedger { service.ledger(for: document) }

    var style: MarkupStyle {
        get { Defaults[.markupStyle] }
        set { Defaults[.markupStyle] = newValue; refresh() }
    }

    // MARK: Showing

    func setBarVisible(_ visible: Bool) {
        isBarVisible = visible
        if visible {
            attach()
        } else {
            choose(.textSelection)
            if let accessory, let window = accessory.view.window,
               let index = window.titlebarAccessoryViewControllers.firstIndex(of: accessory) {
                window.removeTitlebarAccessoryViewController(at: index)
            }
            accessory = nil
            bar = nil
        }
        refresh()
    }

    /// Puts the layer over the document's PDFView (and the bar under the toolbar when it shows).
    func attach() {
        guard let pdfView else { return }
        if overlay?.superview !== pdfView {
            overlay?.removeFromSuperview()
            let layer = MarkupOverlayView(session: self, pdfView: pdfView)
            pdfView.addSubview(layer)
            overlay = layer
        }
        if isBarVisible, accessory == nil, let window = pdfView.window {
            let bar = MarkupBarView(session: self)
            let controller = NSTitlebarAccessoryViewController()
            controller.view = bar
            controller.layoutAttribute = .bottom
            window.addTitlebarAccessoryViewController(controller)
            accessory = controller
            self.bar = bar
        }
        overlay?.toolChanged()
        pagesShown()
    }

    /// Reads the file data of the pages the window shows (only those: a long file opens without reading the rest).
    func pagesShown() {
        guard let pdfView else { return }
        var pages = pdfView.visiblePages
        if let current = pdfView.currentPage, !pages.contains(current) { pages.append(current) }
        service.pagesShown(pages, in: document)
    }

    func detach() {
        setBarVisible(false)
        overlay?.removeFromSuperview()
        overlay = nil
    }

    /// The document's contents were swapped (undo of an engine edit, Revert): the old annotations are gone.
    func documentChanged() {
        if let selection, !selection.page.annotations.contains(where: { $0 === selection.annotation }) { self.selection = nil }
        if overlay?.superview == nil { overlay = nil }
        attach()
        refresh()
    }

    /// Redraws the layer and the bar and tells open panels.
    func refresh() {
        overlay?.needsDisplay = true
        bar?.refresh()
        observers.values.forEach { $0() }
    }

    func observe(_ key: UUID, _ change: @escaping @MainActor () -> Void) { observers[key] = change }
    func stopObserving(_ key: UUID) { observers[key] = nil }

    // MARK: Tools

    func choose(_ tool: MarkupTool) {
        overlay?.endEditing()
        self.tool = tool
        if tool != .textSelection { select(nil) }
        if tool != .rectangularSelection { snapshotArea = nil }
        attach()
        if tool == .highlight, let current = pdfView?.currentSelection, !(current.string ?? "").isEmpty {
            markText(current)
            pdfView?.clearSelection()
        }
        refresh()
    }

    func select(_ annotation: PDFAnnotation?, on page: PDFPage? = nil) {
        if let annotation, let page {
            ledger.prepare(page)
            selection = (annotation, page)
        } else {
            selection = nil
        }
        refresh()
    }

    // MARK: Undo

    func register(_ group: UndoGroup) {
        guard let undoManager = document.undoManager else { return }
        undoManager.beginUndoGrouping()
        undoManager.register(group)
        undoManager.endUndoGrouping()
    }

    /// Adds markup to a page as one undo step ("Add Rectangle").
    @discardableResult
    func commit(_ annotations: [PDFAnnotation], on page: PDFPage, named name: String, records: [String: LedgerRecord] = [:]) -> [PDFAnnotation] {
        guard !annotations.isEmpty else { return [] }
        register(service.add(annotations.map { ($0, page) }, records: records, named: name, in: document))
        refresh()
        return annotations
    }

    // MARK: Gestures (page space)

    /// Sketch and Draw.
    @discardableResult
    func finishStroke(_ points: [CGPoint], on page: PDFPage) -> PDFAnnotation? {
        let annotation = tool == .sketch ? AnnotationFactory.sketch(points, style: style, author: author)
            : AnnotationFactory.ink([points], style: style, author: author)
        guard let annotation else { return nil }
        let name = switch annotation.type {
        case "Square": "Add Rectangle"
        case "Circle": "Add Oval"
        case "Line": "Add Line"
        default: "Add Sketch"
        }
        return commit([annotation], on: page, named: name).first
    }

    @discardableResult
    func finishShape(_ kind: ShapeKind, from start: CGPoint, to end: CGPoint, on page: PDFPage) -> PDFAnnotation {
        let annotation = AnnotationFactory.shape(kind, from: start, to: end, style: style, author: author)
        commit([annotation], on: page, named: "Add " + kind.title)
        return annotation
    }

    /// A text box with Preview's "Text", selected (the layer opens it for typing).
    @discardableResult
    func placeText(at point: CGPoint, on page: PDFPage) -> PDFAnnotation {
        let box = AnnotationFactory.textBox(at: point, style: style, author: author)
        commit([box], on: page, named: "Add Text")
        select(box, on: page)
        return box
    }

    @discardableResult
    func placeNote(at point: CGPoint, on page: PDFPage) -> PDFAnnotation {
        let note = AnnotationFactory.note(at: point, text: "", color: style.noteColor, author: author)
        commit([note], on: page, named: "Add Note")
        select(note, on: page)
        return note
    }

    @discardableResult
    func placeStamp(_ stamp: StandardStamp, at point: CGPoint, on page: PDFPage) -> PDFAnnotation {
        let annotation = AnnotationFactory.standardStamp(stamp, centeredAt: point, author: author)
        commit([annotation], on: page, named: "Add Stamp")
        return annotation
    }

    /// Highlight, underline or strike through a text selection (one annotation per page).
    @discardableResult
    func markText(_ selection: PDFSelection) -> [PDFAnnotation] {
        let markup = style.textMarkup
        var made: [PDFAnnotation] = []
        for page in selection.pages {
            guard let annotation = AnnotationFactory.textMarkup(markup, lines: AnnotationFactory.lineRects(of: selection, on: page), author: author)
            else { continue }
            made += commit([annotation], on: page, named: "Add " + markup.title)
        }
        return made
    }

    /// Proofreading marks (features #78): insert at a point; delete or replace a selection.
    @discardableResult
    func markCorrection(_ kind: CorrectionKind, selection: PDFSelection?, insertionPoint: CGPoint?, on page: PDFPage, text: String) -> [PDFAnnotation] {
        switch kind {
        case .insertText:
            guard let point = insertionPoint else { return [] }
            let index = page.characterIndex(at: point)
            let anchor = index >= 0 ? page.characterBounds(at: index) : CGRect(origin: point, size: CGSize(width: 0, height: 12))
            return commit([AnnotationFactory.caret(after: anchor, text: text, author: author)], on: page, named: "Add " + kind.title)
        case .deleteText, .replaceText:
            guard let selection, let strike = AnnotationFactory.correctionStrike(lines: AnnotationFactory.lineRects(of: selection, on: page), author: author)
            else { return [] }
            guard kind == .replaceText, let last = AnnotationFactory.lineRects(of: selection, on: page).last else {
                return commit([strike], on: page, named: "Add " + kind.title)
            }
            // Acrobat's replace: a caret with the new words, and the strike grouped under it.
            let caret = AnnotationFactory.caret(after: last, text: text, author: author)
            let strikeID = AnnotationLedger.id(of: strike), caretID = AnnotationLedger.id(of: caret)
            return commit([caret, strike], on: page, named: "Add " + kind.title,
                          records: [strikeID: LedgerRecord(parent: caretID, replyType: "Group")])
        }
    }

    /// A finished measurement; a distance also becomes the line "Set scale" uses.
    @discardableResult
    func finishMeasurement(_ kind: MeasureKind, points: [CGPoint], on page: PDFPage) -> PDFAnnotation? {
        guard points.count >= (kind == .area ? 3 : 2) else { return nil }
        let index = document.pdf.index(for: page)
        var measureStyle = style
        measureStyle.dashed = false
        let annotation = Measure.annotation(kind, points: points, scale: service.scale(in: document, page: index), style: measureStyle, author: author)
        if kind == .distance { lastDistance = (index, Geometry.length(of: points, closed: false)) }
        commit([annotation], on: page, named: "Add " + kind.title)
        return annotation
    }

    // MARK: Editing the selection

    func deleteSelection() {
        guard let (annotation, page) = selection else { return }
        let id = AnnotationLedger.id(of: annotation)
        let ledger = ledger
        // A comment's replies and states go with it.
        let children = ledger.children(of: id).compactMap { child in page.annotations.first { AnnotationLedger.existingID(of: $0) == child } }
        let removed = [annotation] + children
        let records = Dictionary(uniqueKeysWithValues: removed.map { a -> (String, LedgerRecord) in let i = AnnotationLedger.id(of: a); return (i, ledger[i]) })
        let take = { for a in removed { page.removeAnnotation(a) }; records.keys.forEach(ledger.remove) }
        let put = { for a in removed { page.addAnnotation(a) }; for (i, r) in records { ledger[i] = r } }
        take()
        selection = nil
        register(UndoGroup("Delete", undo: { put(); self.refresh() }, redo: { take(); self.refresh() }))
        refresh()
    }

    /// The selected annotation, made redrawable by PDFKit before it changes (see `AnnotationEditing.editable`).
    @discardableResult
    func editableSelection() -> PDFAnnotation? {
        guard let (original, page) = selection else { return nil }
        let annotation = AnnotationEditing.editable(original, on: page)
        selection = (annotation, page)
        return annotation
    }

    /// Moves the selection (a drag is "Move", arrow keys "Nudge").
    func moveSelection(by dx: CGFloat, _ dy: CGFloat, named name: String = "Move") {
        guard let (original, page) = selection, AnnotationEditing.canMove(original), dx != 0 || dy != 0 else { return }
        let annotation = AnnotationEditing.editable(original, on: page)
        selection = (annotation, page)
        AnnotationEditing.move(annotation, by: dx, dy)
        register(UndoGroup(name, undo: { AnnotationEditing.move(annotation, by: -dx, -dy); self.refresh() },
                           redo: { AnnotationEditing.move(annotation, by: dx, dy); self.refresh() }))
        refresh()
    }

    func resizeSelection(to rect: CGRect) {
        guard let (original, page) = selection, AnnotationEditing.canResize(original) else { return }
        let annotation = AnnotationEditing.editable(original, on: page)
        selection = (annotation, page)
        let before = annotation.bounds
        guard before != rect else { return }
        AnnotationEditing.resize(annotation, to: rect)
        register(UndoGroup("Resize", undo: { AnnotationEditing.resize(annotation, to: before); self.refresh() },
                           redo: { AnnotationEditing.resize(annotation, to: rect); self.refresh() }))
        refresh()
    }

    /// New ends for a selected line or distance.
    func setLineEnds(_ start: CGPoint, _ end: CGPoint) {
        guard let (original, page) = selection, original.type == "Line" else { return }
        if let kind = Measure.kind(of: original) {
            // A measurement is remade so its value follows.
            let index = document.pdf.index(for: page)
            let remade = Measure.annotation(kind, points: [start, end], scale: service.scale(in: document, page: index), style: style, author: author)
            AnnotationEditing.copyProperties(from: original, to: remade)
            remade.contents = Measure.label(kind, points: [start, end], scale: service.scale(in: document, page: index))
            swap(original, for: remade, on: page, named: "Resize")
            return
        }
        let (oldStart, oldEnd) = AnnotationEditing.lineEnds(of: original)
        AnnotationEditing.setLine(original, from: start, to: end)
        register(UndoGroup("Resize", undo: { AnnotationEditing.setLine(original, from: oldStart, to: oldEnd); self.refresh() },
                           redo: { AnnotationEditing.setLine(original, from: start, to: end); self.refresh() }))
        refresh()
    }

    private func swap(_ old: PDFAnnotation, for new: PDFAnnotation, on page: PDFPage, named name: String) {
        AnnotationEditing.replace(old, with: new, on: page)
        selection = (new, page)
        register(UndoGroup(name, undo: { AnnotationEditing.replace(new, with: old, on: page); self.refresh() },
                           redo: { AnnotationEditing.replace(old, with: new, on: page); self.refresh() }))
        refresh()
    }

    /// Restyles the selection (and remembers the style for new markup).
    func restyle(_ name: String, _ change: (inout MarkupStyle) -> Void) {
        var newStyle = style
        change(&newStyle)
        style = newStyle
        guard let (original, page) = selection, AnnotationLedger.isMarkup(original) else { return }
        let annotation = AnnotationEditing.editable(original, on: page)
        selection = (annotation, page)
        let before = AnnotationEditing.Look(annotation)
        var after = before
        switch annotation.type {
        case "FreeText":
            after.font = newStyle.font
            after.fontColor = newStyle.textColor.nsColor
            after.alignment = newStyle.alignment.nsAlignment
        case "Text":
            after.color = newStyle.noteColor.nsColor
        case "Highlight", "Underline", "StrikeOut":
            if case .highlight(let color) = newStyle.textMarkup, annotation.type == "Highlight" { after.color = color.color }
        default:
            after.color = newStyle.stroke.nsColor
            after.interior = newStyle.fill.isClear ? nil : newStyle.fill.nsColor
            after.lineWidth = CGFloat(newStyle.lineWidth)
            after.dashed = newStyle.dashed
            if annotation.type == "Line", Measure.kind(of: annotation) == nil, annotation.startLineStyle != .none || annotation.endLineStyle != .none {
                after.startStyle = newStyle.arrowAtStart ? .openArrow : .none
                after.endStyle = newStyle.arrowAtEnd ? .openArrow : .none
            }
        }
        after.apply(to: annotation)
        register(UndoGroup(name, undo: { before.apply(to: annotation); self.refresh() }, redo: { after.apply(to: annotation); self.refresh() }))
        refresh()
    }

    /// New words in a text box or note ("Text"); a text box grows to fit them.
    func setText(_ text: String, of annotation: PDFAnnotation) {
        let oldText = annotation.contents ?? "", oldBounds = annotation.bounds
        guard oldText != text else { return }
        var newBounds = oldBounds
        if annotation.type == "FreeText", let font = annotation.font {
            let size = AnnotationFactory.textBoxSize(text, font: font)
            newBounds = CGRect(x: oldBounds.minX, y: oldBounds.maxY - size.height, width: max(oldBounds.width, size.width), height: size.height)
        }
        let apply = { (text: String, bounds: CGRect) in
            annotation.contents = text
            annotation.bounds = bounds
            annotation.modificationDate = Date()
        }
        apply(text, newBounds)
        register(UndoGroup("Text", undo: { apply(oldText, oldBounds); self.refresh() }, redo: { apply(text, newBounds); self.refresh() }))
        refresh()
    }

    // MARK: Rectangular Selection (features #116)

    /// Copies the area as a picture at twice screen resolution (PNG and TIFF), as Preview's Copy does.
    @discardableResult
    func copySnapshot(to pasteboard: NSPasteboard = .general) -> Bool {
        guard let (page, rect) = snapshotArea, let image = Snapshot.image(of: rect, on: page, scale: 2) else { return false }
        pasteboard.clearContents()
        return pasteboard.writeObjects([image])
    }

    // MARK: The bar's other buttons

    /// Black out, Sign, Crop and Form Fill open their tools' panels; Rotate turns the selected pages (or this one) left.
    func open(_ tool: ToolID) { Services.tools?.openPanel(tool, for: document, inputs: []) }

    func rotateLeft() {
        let selected = Services.viewer?.selectedPages(in: document) ?? []
        let pages = selected.isEmpty ? [Services.viewer?.currentPage(in: document) ?? 0] : selected
        let document = document
        Task { @MainActor in
            guard let pagesService = Services.pages, let group = try? await pagesService.perform(.rotate(pages, quarterTurns: -1), in: document) else { return }
            try? await Services.documents?.apply(.inPlace(undoable: group, banner: nil),
                                                 of: ToolRequest(tool: .rotatePages, document: document, workFolder: SuperPDFPaths.work))
        }
    }
}

/// Copy an area of a page as a picture (features #116).
@MainActor
enum Snapshot {
    static func image(of rect: CGRect, on page: PDFPage, scale: CGFloat) -> NSImage? {
        let area = rect.standardized.intersection(page.bounds(for: .cropBox))
        guard area.width >= 1, area.height >= 1 else { return nil }
        let width = Int(area.width * scale), height = Int(area.height * scale)
        guard let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                                      space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
        context.setFillColor(.white)
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        context.scaleBy(x: scale, y: scale)
        context.translateBy(x: -area.minX, y: -area.minY)
        // `draw(with:to:)` draws in the box's display space (rotated, from its corner); undo that to stay in page space.
        context.concatenate(page.transform(for: .mediaBox).inverted())
        page.draw(with: .mediaBox, to: context)
        guard let image = context.makeImage() else { return nil }
        return NSImage(cgImage: image, size: area.size)
    }
}
