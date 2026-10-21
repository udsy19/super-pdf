import AppKit
import PDFKit
import PDFModelKit
import SuperPDFCore

// Builds every kind of markup as a standard PDF annotation (features #15, #76, #78, #79): the PDFKit subtype other
// readers know, the author (/T), dates (/M, /CreationDate), an id, the style keys, and for kinds PDFKit can't draw a
// `DrawnAnnotation` whose drawing becomes the appearance stream. Coordinates are page space.

@MainActor
enum AnnotationFactory {
    /// The default size of a shape made with a click instead of a drag.
    static let defaultShapeSize: CGFloat = 72
    /// Preview's text box words before you type ("FreeTextAnnotationDefaultContents").
    nonisolated static let defaultText = "Text"

    /// Author, dates and id on a new annotation.
    @discardableResult
    static func finish(_ annotation: PDFAnnotation, author: String, date: Date = Date()) -> PDFAnnotation {
        setAuthor(author, of: annotation)
        annotation.modificationDate = date
        annotation.setValue(PDFDate.string(date), forAnnotationKey: .creationDate)
        AnnotationLedger.id(of: annotation)
        return annotation
    }

    /// /T. PDFKit's `userName` only takes on subtypes it knows (not Polygon, Caret, FileAttachment, Sound); the key works
    /// on all.
    static func setAuthor(_ author: String?, of annotation: PDFAnnotation) {
        guard let author else { return }
        annotation.userName = author
        annotation.setValue(author, forAnnotationKey: .textLabel)
    }

    static func apply(_ style: MarkupStyle, toShape annotation: PDFAnnotation) {
        annotation.color = style.stroke.nsColor
        annotation.interiorColor = style.fill.isClear ? nil : style.fill.nsColor
        let border = PDFBorder()
        border.lineWidth = CGFloat(style.lineWidth)
        border.style = style.dashed ? .dashed : .solid
        if style.dashed { border.dashPattern = [style.lineWidth * 3, style.lineWidth * 2] }
        annotation.border = border
    }

    // MARK: Text markup (Highlight ▾)

    /// One annotation over the lines of a selection on one page (Preview's highlight spans lines the same way).
    static func textMarkup(_ style: TextMarkupStyle, lines: [CGRect], author: String) -> PDFAnnotation? {
        let lines = lines.filter { $0.width > 0.5 && $0.height > 0.5 }
        guard let first = lines.first else { return nil }
        let bounds = lines.dropFirst().reduce(first) { $0.union($1) }
        let subtype: PDFAnnotationSubtype, color: NSColor
        switch style {
        case .highlight(let highlight): subtype = .highlight; color = highlight.color
        case .underline: subtype = .underline; color = MarkupColor.red.nsColor
        case .strikethrough: subtype = .strikeOut; color = MarkupColor.red.nsColor
        }
        let annotation = PDFAnnotation(bounds: bounds, forType: subtype, withProperties: nil)
        annotation.color = color
        annotation.quadrilateralPoints = lines.flatMap { line -> [NSValue] in
            [CGPoint(x: line.minX, y: line.maxY), CGPoint(x: line.maxX, y: line.maxY), CGPoint(x: line.minX, y: line.minY),
             CGPoint(x: line.maxX, y: line.minY)].map { NSValue(point: CGPoint(x: $0.x - bounds.minX, y: $0.y - bounds.minY)) }
        }
        return finish(annotation, author: author)
    }

    /// The lines of a selection on `page`, in page space.
    static func lineRects(of selection: PDFSelection, on page: PDFKit.PDFPage) -> [CGRect] {
        selection.selectionsByLine().compactMap { line -> CGRect? in
            guard line.pages.contains(page) else { return nil }
            let rect = line.bounds(for: page)
            return rect.isEmpty ? nil : rect
        }
    }

    // MARK: Shapes (Shapes ▾, Sketch, Draw)

    static func shape(_ kind: ShapeKind, from start: CGPoint, to end: CGPoint, style: MarkupStyle, author: String) -> PDFAnnotation {
        var a = start, b = end
        if hypot(b.x - a.x, b.y - a.y) < 4 {   // a click: Preview's default size around the point
            let half = defaultShapeSize / 2
            if kind.isLinear { a = CGPoint(x: start.x - half, y: start.y); b = CGPoint(x: start.x + half, y: start.y) } else {
                a = CGPoint(x: start.x - half, y: start.y - half); b = CGPoint(x: start.x + half, y: start.y + half)
            }
        }
        let rect = Geometry.rect(a, b)
        let annotation: PDFAnnotation
        switch kind {
        case .line, .arrow:
            let pad = CGFloat(style.lineWidth) * 4 + 4
            let box = rect.insetBy(dx: -pad, dy: -pad)
            annotation = PDFAnnotation(bounds: box, forType: .line, withProperties: nil)
            annotation.startPoint = CGPoint(x: a.x - box.minX, y: a.y - box.minY)
            annotation.endPoint = CGPoint(x: b.x - box.minX, y: b.y - box.minY)
            annotation.startLineStyle = kind == .arrow && style.arrowAtStart ? .openArrow : .none
            annotation.endLineStyle = kind == .arrow && style.arrowAtEnd ? .openArrow : .none
        case .rectangle:
            annotation = PDFAnnotation(bounds: rect, forType: .square, withProperties: nil)
        case .oval:
            annotation = PDFAnnotation(bounds: rect, forType: .circle, withProperties: nil)
        case .loupe:
            let side = max(rect.width, rect.height)
            let square = CGRect(x: rect.midX - side / 2, y: rect.midY - side / 2, width: side, height: side)
            annotation = DrawnAnnotation(bounds: square, type: .circle, drawing: .loupe(2))
            annotation.setValue("/Loupe", forAnnotationKey: .intent)
        case .roundedRectangle:
            annotation = DrawnAnnotation(bounds: rect, type: .square, drawing: .roundedRect(radius: min(rect.width, rect.height) * 0.18))
        case .cloud:
            annotation = DrawnAnnotation(bounds: rect, type: .square, drawing: .cloud)
            annotation.setValue(["/S": "/C", "/I": 1] as NSDictionary, forAnnotationKey: .borderEffect)
        case .speechBubble, .star, .polygon:
            let points = switch kind {
            case .star: Geometry.star(in: rect)
            case .polygon: Geometry.hexagon(in: rect)
            default: Geometry.speechBubble(in: rect)
            }
            annotation = polygon(points, closed: true)
        }
        apply(style, toShape: annotation)
        return finish(annotation, author: author)
    }

    /// A Polygon or PolyLine annotation through `points` with the standard /Vertices.
    static func polygon(_ points: [CGPoint], closed: Bool, drawing: Drawing? = nil) -> DrawnAnnotation {
        let annotation = DrawnAnnotation(bounds: Geometry.bounds(of: points).insetBy(dx: -6, dy: -6), type: closed ? .polygon : .polyLine,
                                         drawing: drawing ?? .vertices(points, closed: closed))
        setVertices(points, of: annotation)
        return annotation
    }

    static func setVertices(_ points: [CGPoint], of annotation: PDFAnnotation) {
        annotation.setValue(points.flatMap { [NSNumber(value: Double($0.x)), NSNumber(value: Double($0.y))] } as NSArray, forAnnotationKey: .vertices)
    }

    /// Freehand strokes as one ink annotation.
    static func ink(_ strokes: [[CGPoint]], style: MarkupStyle, author: String) -> PDFAnnotation? {
        let strokes = strokes.map { Geometry.simplify($0, tolerance: 0.6) }.filter { !$0.isEmpty }
        guard !strokes.isEmpty else { return nil }
        let pad = CGFloat(style.lineWidth) + 2
        let box = Geometry.bounds(of: strokes.flatMap { $0 }).insetBy(dx: -pad, dy: -pad)
        let annotation = PDFAnnotation(bounds: box, forType: .ink, withProperties: nil)
        for stroke in strokes {
            let path = NSBezierPath()
            path.move(to: CGPoint(x: stroke[0].x - box.minX, y: stroke[0].y - box.minY))
            for p in stroke.dropFirst() { path.line(to: CGPoint(x: p.x - box.minX, y: p.y - box.minY)) }
            if stroke.count == 1 { path.line(to: CGPoint(x: stroke[0].x - box.minX + 0.1, y: stroke[0].y - box.minY)) }
            annotation.add(path)
        }
        apply(style, toShape: annotation)
        annotation.interiorColor = nil
        return finish(annotation, author: author)
    }

    /// Sketch: the shape a stroke looks like, else the stroke itself.
    static func sketch(_ points: [CGPoint], style: MarkupStyle, author: String) -> PDFAnnotation? {
        switch SketchShape.recognise(points) {
        case .line(let a, let b): shape(.line, from: a, to: b, style: style, author: author)
        case .rectangle(let rect): shape(.rectangle, from: rect.origin, to: CGPoint(x: rect.maxX, y: rect.maxY), style: style, author: author)
        case .oval(let rect): shape(.oval, from: rect.origin, to: CGPoint(x: rect.maxX, y: rect.maxY), style: style, author: author)
        case .freehand: ink([points], style: style, author: author)
        }
    }

    // MARK: Text, notes, stamps

    /// A text box whose top-left corner is at `point`, sized to its words.
    static func textBox(at point: CGPoint, text: String = defaultText, style: MarkupStyle, author: String) -> PDFAnnotation {
        let size = textBoxSize(text, font: style.font)
        let annotation = PDFAnnotation(bounds: CGRect(x: point.x, y: point.y - size.height, width: size.width, height: size.height),
                                       forType: .freeText, withProperties: nil)
        annotation.contents = text
        annotation.font = style.font
        annotation.fontColor = style.textColor.nsColor
        annotation.alignment = style.alignment.nsAlignment
        annotation.color = MarkupColor.clear.nsColor
        let border = PDFBorder()
        border.lineWidth = 0
        annotation.border = border
        return finish(annotation, author: author)
    }

    /// The box that shows `text` in `font` on one line per paragraph, with PDFKit's 2 pt inset.
    static func textBoxSize(_ text: String, font: NSFont) -> CGSize {
        let measured = NSAttributedString(string: text.isEmpty ? " " : text, attributes: [.font: font])
            .boundingRect(with: CGSize(width: 2000, height: 2000), options: [.usesLineFragmentOrigin, .usesFontLeading])
        return CGSize(width: ceil(measured.width) + 8, height: ceil(measured.height) + 6)
    }

    /// A sticky note at `point` (its icon's top-left corner).
    static func note(at point: CGPoint, text: String, color: MarkupColor, author: String) -> PDFAnnotation {
        let annotation = PDFAnnotation(bounds: CGRect(x: point.x, y: point.y - 24, width: 24, height: 24), forType: .text, withProperties: nil)
        annotation.contents = text
        annotation.color = color.nsColor
        annotation.iconType = .note
        return finish(annotation, author: author)
    }

    /// The default stamp size: 3 : 1, Acrobat's proportion.
    static let stampSize = CGSize(width: 150, height: 50)

    static func standardStamp(_ stamp: StandardStamp, centeredAt point: CGPoint, author: String, date: Date = Date()) -> PDFAnnotation {
        let rect = CGRect(x: point.x - stampSize.width / 2, y: point.y - stampSize.height / 2, width: stampSize.width, height: stampSize.height)
        let detail = [author, date.formatted(date: .abbreviated, time: .shortened)].filter { !$0.isEmpty }.joined(separator: " · ")
        let annotation = DrawnAnnotation(bounds: rect, type: .stamp, drawing: .stamp(stamp, detail: detail))
        annotation.stampName = stamp.rawValue
        annotation.color = stamp.color
        annotation.contents = stamp.title
        return finish(annotation, author: author, date: date)
    }

    static func imageStamp(_ data: Data, in rect: CGRect, author: String) -> PDFAnnotation {
        finish(DrawnAnnotation(bounds: rect, type: .stamp, drawing: .image(data)), author: author)
    }

    // MARK: Proofreading marks (features #78)

    static let correctionColor = MarkupColor(hex: "#1F5FBF")

    /// A caret just after `rect` (the character before the insertion point), with the words to insert.
    static func caret(after rect: CGRect, text: String, author: String) -> PDFAnnotation {
        let size = max(8, rect.height * 0.6)
        let annotation = DrawnAnnotation(bounds: CGRect(x: rect.maxX - size / 2, y: rect.minY - size * 0.35, width: size, height: size),
                                         type: .caret, drawing: .caret)
        annotation.color = correctionColor.nsColor
        annotation.contents = text
        return finish(annotation, author: author)
    }

    /// Text struck out for deletion or replacement (Acrobat's /IT /StrikeOutTextEdit).
    static func correctionStrike(lines: [CGRect], author: String) -> PDFAnnotation? {
        guard let strike = textMarkup(.strikethrough, lines: lines, author: author) else { return nil }
        strike.color = correctionColor.nsColor
        strike.setValue("/StrikeOutTextEdit", forAnnotationKey: .intent)
        return strike
    }

    // MARK: Attachments (features #79)

    static func paperclip(at point: CGPoint, fileName: String, author: String) -> DrawnAnnotation {
        let annotation = DrawnAnnotation(bounds: CGRect(x: point.x, y: point.y - 20, width: 14, height: 20), type: .fileAttachment, drawing: .paperclip)
        annotation.color = NSColor(hex: "#3C3C43")
        annotation.contents = fileName
        finish(annotation, author: author)
        return annotation
    }

    static func speaker(at point: CGPoint, title: String, author: String) -> DrawnAnnotation {
        let annotation = DrawnAnnotation(bounds: CGRect(x: point.x, y: point.y - 20, width: 20, height: 20), type: .sound, drawing: .speaker)
        annotation.color = NSColor(hex: "#3C3C43")
        annotation.contents = title
        finish(annotation, author: author)
        return annotation
    }
}
