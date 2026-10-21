import AppKit
import PDFKit
import SuperPDFCore

// Measure (features #15): distances, perimeters and areas on plans, saved as the standard measurement annotations
// (Line /IT /LineDimension, PolyLine /PolyLineDimension, Polygon /PolygonDimension) with a /Measure viewport scale
// ("1 in = 10 m"), so Acrobat reads the same values. The page's scale is the one its measurements carry.

enum Measure {
    static func value(_ kind: MeasureKind, points: [CGPoint], scale: MeasureScale) -> Double {
        switch kind {
        case .distance, .perimeter: scale.length(Geometry.length(of: points, closed: false))
        case .area: scale.area(Geometry.area(of: points))
        }
    }

    /// "12.5 m", "37.2 sq m".
    static func label(_ kind: MeasureKind, points: [CGPoint], scale: MeasureScale) -> String {
        format(value(kind, points: points, scale: scale), unit: scale.unit, area: kind == .area)
    }

    static func format(_ value: Double, unit: MeasureUnit, area: Bool) -> String {
        let formatter = NumberFormatter()
        formatter.numberStyle = .decimal
        formatter.maximumFractionDigits = value < 10 ? 2 : 1
        formatter.minimumFractionDigits = 0
        let number = formatter.string(from: NSNumber(value: value)) ?? String(value)
        return area ? "\(number) sq \(unit.rawValue)" : "\(number) \(unit.rawValue)"
    }

    /// "1 in = 10 m" (the /Measure /R text).
    static func ratio(_ scale: MeasureScale) -> String {
        let inches = scale.pageDistance / 72
        let real = scale.realDistance
        let pageText = format(inches, unit: .inch, area: false), realText = format(real, unit: scale.unit, area: false)
        return "\(pageText) = \(realText)"
    }

    /// The /Measure dictionary: X and D in `unit` per point, A in square units per square point.
    static func dictionary(_ scale: MeasureScale) -> NSDictionary {
        let perPoint = scale.pageDistance > 0 ? scale.realDistance / scale.pageDistance : 0
        func format(_ unit: String, _ factor: Double) -> NSArray {
            [["/Type": "/NumberFormat", "/U": unit, "/C": NSNumber(value: factor), "/D": NSNumber(value: 100)] as NSDictionary]
        }
        return ["/Type": "/Measure", "/Subtype": "/RL", "/R": ratio(scale), "/X": format(scale.unit.rawValue, perPoint),
                "/D": format(scale.unit.rawValue, 1), "/A": format("sq " + scale.unit.rawValue, 1)] as NSDictionary
    }

    /// The scale a measurement annotation carries (its /Measure X factor and unit).
    static func scale(of annotation: PDFAnnotation) -> MeasureScale? {
        guard let measure = annotation.value(forAnnotationKey: .measure) as? NSDictionary else { return nil }
        func entry(_ key: String) -> Any? { measure[key] ?? measure["/" + key] }
        guard let formats = entry("X") as? NSArray, let first = formats.firstObject as? NSDictionary else { return nil }
        let factor = ((first["C"] ?? first["/C"]) as? NSNumber)?.doubleValue ?? 0
        let unitName = ((first["U"] ?? first["/U"]) as? String) ?? ""
        guard factor > 0, let unit = MeasureUnit(rawValue: unitName) else { return nil }
        return MeasureScale(pageDistance: 72, realDistance: factor * 72, unit: unit)
    }

    static func kind(of annotation: PDFAnnotation) -> MeasureKind? {
        guard let intent = (annotation.value(forAnnotationKey: .intent) as? String)?.trimmingCharacters(in: CharacterSet(charactersIn: "/")) else { return nil }
        return switch intent {
        case "LineDimension": .distance
        case "PolyLineDimension": .perimeter
        case "PolygonDimension": .area
        default: nil
        }
    }

    /// The measured points of a measurement annotation, in page space.
    @MainActor
    static func points(of annotation: PDFAnnotation) -> [CGPoint] {
        if let drawn = annotation as? DrawnAnnotation {
            if case .measurement(let points, _, _) = drawn.drawing { return points }
            if case .vertices(let points, _) = drawn.drawing { return points }
        }
        if annotation.type == "Line" {
            let o = annotation.bounds.origin
            return [CGPoint(x: annotation.startPoint.x + o.x, y: annotation.startPoint.y + o.y),
                    CGPoint(x: annotation.endPoint.x + o.x, y: annotation.endPoint.y + o.y)]
        }
        let numbers = (annotation.value(forAnnotationKey: .vertices) as? [Any])?.compactMap { ($0 as? NSNumber)?.doubleValue } ?? []
        return stride(from: 0, to: numbers.count - 1, by: 2).map { CGPoint(x: numbers[$0], y: numbers[$0 + 1]) }
    }

    /// A measurement annotation through `points`.
    @MainActor
    static func annotation(_ kind: MeasureKind, points: [CGPoint], scale: MeasureScale, style: MarkupStyle, author: String) -> PDFAnnotation {
        let label = label(kind, points: points, scale: scale)
        let annotation: DrawnAnnotation
        switch kind {
        case .distance:
            let box = Geometry.bounds(of: points).insetBy(dx: -16, dy: -16)
            annotation = DrawnAnnotation(bounds: box, type: .line, drawing: .measurement(points, closed: false, label: label))
            annotation.startPoint = CGPoint(x: points[0].x - box.minX, y: points[0].y - box.minY)
            annotation.endPoint = CGPoint(x: points[points.count - 1].x - box.minX, y: points[points.count - 1].y - box.minY)
            annotation.setValue(true, forAnnotationKey: .caption)
        case .perimeter, .area:
            annotation = AnnotationFactory.polygon(points, closed: kind == .area, drawing: .measurement(points, closed: kind == .area, label: label))
            annotation.bounds = Geometry.bounds(of: points).insetBy(dx: -16, dy: -16)
        }
        annotation.setValue(kind == .distance ? "/LineDimension" : kind == .perimeter ? "/PolyLineDimension" : "/PolygonDimension",
                            forAnnotationKey: .intent)
        annotation.setValue(dictionary(scale), forAnnotationKey: .measure)
        annotation.contents = label
        AnnotationFactory.apply(style, toShape: annotation)
        if kind != .area { annotation.interiorColor = nil }
        return AnnotationFactory.finish(annotation, author: author)
    }
}
