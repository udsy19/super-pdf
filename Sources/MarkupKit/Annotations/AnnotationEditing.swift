import AppKit
import PDFKit

// Moving, resizing, restyling and deleting markup, each an undoable step named as Preview names it (its UndoStrings
// table: "Move", "Resize", "Nudge", "Color", "Fill Color", "Border Line Width", "Font", "Text", "Delete").
//
// PDFKit redraws the kinds it knows (rectangles, ovals, lines, ink, text markup, text boxes, notes) after any change.
// The others (polygons, clouds, carets, stamps, paper clips, measurements) only keep their look while their appearance
// stream is untouched, so before changing one that came from the file it becomes a `DrawnAnnotation` again.

@MainActor
enum AnnotationEditing {
    static let textMarkupTypes: Set<String> = ["Highlight", "Underline", "StrikeOut", "Squiggly"]

    /// Text markup stays with its text; everything else moves.
    static func canMove(_ annotation: PDFAnnotation) -> Bool {
        AnnotationLedger.isMarkup(annotation) && !textMarkupTypes.contains(annotation.type ?? "")
    }

    /// Boxes, stamps, drawings and outlines take new sizes; lines and measurements change by their ends instead.
    static func canResize(_ annotation: PDFAnnotation) -> Bool {
        guard Measure.kind(of: annotation) == nil else { return false }
        return ["Square", "Circle", "FreeText", "Stamp", "Ink", "Polygon", "PolyLine"].contains(annotation.type ?? "")
    }

    // MARK: Kinds PDFKit can't redraw

    private static let nativeTypes: Set<String> = ["Square", "Circle", "Line", "Ink", "Highlight", "Underline", "StrikeOut", "Squiggly",
                                                   "FreeText", "Text", "Popup", "Link", "Widget"]

    /// The annotation itself when PDFKit can redraw it after a change; else a `DrawnAnnotation` that draws the same,
    /// put in its place on `page`.
    static func editable(_ annotation: PDFAnnotation, on page: PDFPage) -> PDFAnnotation {
        if annotation is DrawnAnnotation { return annotation }
        let type = annotation.type ?? ""
        let cloud = annotation.value(forAnnotationKey: .borderEffect) != nil
        let loupe = (annotation.value(forAnnotationKey: .intent) as? String)?.hasSuffix("Loupe") == true
        guard !nativeTypes.contains(type) || Measure.kind(of: annotation) != nil || (type == "Square" && cloud) || loupe else { return annotation }
        let drawing: Drawing
        if let kind = Measure.kind(of: annotation) {
            drawing = .measurement(Measure.points(of: annotation), closed: kind == .area, label: annotation.contents ?? "")
        } else {
            switch type {
            case "Circle": drawing = .loupe(2)
            case "Polygon", "PolyLine": drawing = .vertices(Measure.points(of: annotation), closed: type == "Polygon")
            case "Square": drawing = .cloud
            case "Caret": drawing = .caret
            case "FileAttachment": drawing = .paperclip
            case "Sound": drawing = .speaker
            default: drawing = .appearance(appearanceSnapshot(annotation), originalBounds: annotation.bounds)
            }
        }
        let drawn = DrawnAnnotation(bounds: annotation.bounds, type: PDFAnnotationSubtype(rawValue: type), drawing: drawing)
        copyProperties(from: annotation, to: drawn)
        replace(annotation, with: drawn, on: page)
        return drawn
    }

    /// The annotation's current look as a one-page PDF the size of its bounds.
    static func appearanceSnapshot(_ annotation: PDFAnnotation) -> Data {
        let data = NSMutableData()
        var box = CGRect(origin: .zero, size: annotation.bounds.size)
        guard let consumer = CGDataConsumer(data: data as CFMutableData), let context = CGContext(consumer: consumer, mediaBox: &box, nil) else {
            return Data()
        }
        context.beginPDFPage(nil)
        context.translateBy(x: -annotation.bounds.minX, y: -annotation.bounds.minY)
        annotation.draw(with: .mediaBox, in: context)
        context.endPDFPage()
        context.closePDF()
        return data as Data
    }

    private static let copiedKeys: [PDFAnnotationKey] = [.superPDFID, .name, .creationDate, .intent, .measure, .vertices, .borderEffect,
                                                         .caption, .subject, .state, .stateModel, .iconName]

    static func copyProperties(from source: PDFAnnotation, to target: PDFAnnotation) {
        AnnotationFactory.setAuthor(source.userName, of: target)
        target.contents = source.contents
        target.color = source.color
        target.interiorColor = source.interiorColor
        target.border = source.border
        target.modificationDate = source.modificationDate
        target.shouldDisplay = source.shouldDisplay
        target.shouldPrint = source.shouldPrint
        if source.type == "Line" || target.type == "Line" {
            target.startPoint = source.startPoint
            target.endPoint = source.endPoint
        }
        for key in copiedKeys {
            if let value = source.value(forAnnotationKey: key) { target.setValue(value, forAnnotationKey: key) }
        }
        if let stamp = source.stampName { target.stampName = stamp }
    }

    /// Swaps an annotation on its page (the new one draws on top, as a moved one does in Preview).
    static func replace(_ old: PDFAnnotation, with new: PDFAnnotation, on page: PDFPage) {
        page.removeAnnotation(old)
        page.addAnnotation(new)
    }

    // MARK: Geometry

    static func move(_ annotation: PDFAnnotation, by dx: CGFloat, _ dy: CGFloat) {
        if let drawn = annotation as? DrawnAnnotation {
            drawn.translate(by: dx, dy)
            if annotation.value(forAnnotationKey: .vertices) != nil {
                AnnotationFactory.setVertices(Measure.points(of: drawn), of: drawn)
            }
        } else {
            annotation.bounds = annotation.bounds.offsetBy(dx: dx, dy: dy)
        }
        annotation.modificationDate = Date()
    }

    /// New bounds for a box-like annotation; drawings and outlines scale with it.
    static func resize(_ annotation: PDFAnnotation, to rect: CGRect) {
        let old = annotation.bounds
        guard old.width > 0, old.height > 0, rect.width >= 2, rect.height >= 2 else { return }
        let transform = CGAffineTransform(translationX: rect.minX, y: rect.minY)
            .scaledBy(x: rect.width / old.width, y: rect.height / old.height)
            .translatedBy(x: -old.minX, y: -old.minY)
        if let drawn = annotation as? DrawnAnnotation, case .vertices(let points, let closed) = drawn.drawing {
            let moved = points.map { $0.applying(transform) }
            drawn.drawing = .vertices(moved, closed: closed)
            AnnotationFactory.setVertices(moved, of: drawn)
        }
        if annotation.type == "Ink" {
            let scale = CGAffineTransform(scaleX: rect.width / old.width, y: rect.height / old.height)
            let paths = annotation.paths ?? []
            for path in paths {
                annotation.remove(path)
                let scaled = path.copy() as! NSBezierPath
                scaled.transform(using: AffineTransform(m11: scale.a, m12: scale.b, m21: scale.c, m22: scale.d, tX: 0, tY: 0))
                annotation.add(scaled)
            }
        }
        annotation.bounds = rect
        annotation.modificationDate = Date()
    }

    /// New ends for a line (page space), keeping its padding for arrowheads.
    static func setLine(_ annotation: PDFAnnotation, from start: CGPoint, to end: CGPoint) {
        let pad = max(annotation.border?.lineWidth ?? 1, 1) * 4 + 4
        let box = Geometry.rect(start, end).insetBy(dx: -pad, dy: -pad)
        annotation.bounds = box
        annotation.startPoint = CGPoint(x: start.x - box.minX, y: start.y - box.minY)
        annotation.endPoint = CGPoint(x: end.x - box.minX, y: end.y - box.minY)
        annotation.modificationDate = Date()
    }

    /// The ends of a line in page space.
    static func lineEnds(of annotation: PDFAnnotation) -> (CGPoint, CGPoint) {
        let o = annotation.bounds.origin
        return (CGPoint(x: annotation.startPoint.x + o.x, y: annotation.startPoint.y + o.y),
                CGPoint(x: annotation.endPoint.x + o.x, y: annotation.endPoint.y + o.y))
    }

    // MARK: Style

    /// What restyling can change, captured so undo can put it back.
    struct Look {
        var color: NSColor
        var interior: NSColor?
        var lineWidth: CGFloat
        var dashed: Bool
        var font: NSFont?
        var fontColor: NSColor?
        var alignment: NSTextAlignment
        var startStyle: PDFLineStyle
        var endStyle: PDFLineStyle

        @MainActor init(_ annotation: PDFAnnotation) {
            color = annotation.color
            interior = annotation.interiorColor
            lineWidth = annotation.border?.lineWidth ?? 1
            dashed = annotation.border?.style == .dashed
            font = annotation.type == "FreeText" ? annotation.font : nil
            fontColor = annotation.type == "FreeText" ? annotation.fontColor : nil
            alignment = annotation.alignment
            startStyle = annotation.startLineStyle
            endStyle = annotation.endLineStyle
        }

        @MainActor func apply(to annotation: PDFAnnotation) {
            annotation.color = color
            annotation.interiorColor = interior
            let border = PDFBorder()
            border.lineWidth = lineWidth
            border.style = dashed ? .dashed : .solid
            if dashed { border.dashPattern = [lineWidth * 3, lineWidth * 2] }
            annotation.border = border
            if annotation.type == "FreeText" {
                if let font { annotation.font = font }
                if let fontColor { annotation.fontColor = fontColor }
                annotation.alignment = alignment
                annotation.border = { let b = PDFBorder(); b.lineWidth = 0; return b }()
            }
            if annotation.type == "Line" {
                annotation.startLineStyle = startStyle
                annotation.endLineStyle = endStyle
            }
            annotation.modificationDate = Date()
        }
    }
}
