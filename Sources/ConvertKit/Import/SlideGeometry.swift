import CoreGraphics
import Foundation

// Shape outlines for the PowerPoint importer: the common preset geometries (`a:prstGeom`) with their adjust values, and
// custom paths (`a:custGeom`). Paths are built in page space (points, y down) inside the shape's frame; rotation and
// flips are the caller's transform.

/// A shape's position (`a:xfrm` / `p:xfrm`), in EMU of its parent's space.
struct SlideXfrm {
    var rect: CGRect
    /// Degrees clockwise.
    var rotation: Double
    var flipH: Bool
    var flipV: Bool
    /// A group's child space (`chOff`/`chExt`).
    var childRect: CGRect?

    init?(_ node: XMLNode?) {
        guard let node, let off = node.child("off"), let ext = node.child("ext") else { return nil }
        func number(_ text: String?) -> Double {
            guard let v = Double(text ?? ""), v.isFinite else { return 0 }
            return min(max(v, -2e10), 2e10)
        }
        rect = CGRect(x: number(off.attr("x")), y: number(off.attr("y")), width: max(number(ext.attr("cx")), 0), height: max(number(ext.attr("cy")), 0))
        rotation = number(node.attr("rot")) / 60_000
        flipH = ["1", "true"].contains(node.attr("flipH") ?? "")
        flipV = ["1", "true"].contains(node.attr("flipV") ?? "")
        if let chOff = node.child("chOff"), let chExt = node.child("chExt") {
            childRect = CGRect(x: number(chOff.attr("x")), y: number(chOff.attr("y")), width: number(chExt.attr("cx")), height: number(chExt.attr("cy")))
        }
    }

    /// Rotation and flips about the centre of `frame` (page space), for the shape's geometry.
    static func transform(for frame: CGRect, rotation: Double, flipH: Bool, flipV: Bool) -> CGAffineTransform {
        guard rotation != 0 || flipH || flipV else { return .identity }
        let center = CGPoint(x: frame.midX, y: frame.midY)
        return CGAffineTransform(translationX: -center.x, y: -center.y)
            .concatenating(CGAffineTransform(scaleX: flipH ? -1 : 1, y: flipV ? -1 : 1))
            .concatenating(CGAffineTransform(rotationAngle: rotation * .pi / 180))
            .concatenating(CGAffineTransform(translationX: center.x, y: center.y))
    }
}

enum SlideGeometry {
    /// The outline of the geometry in `container` (`spPr`) filling `rect`; a rectangle when it names none or one this
    /// reader doesn't know. `ends` are a line's first and last points (for arrowheads); `isOpen` paths aren't filled.
    static func path(in container: XMLNode?, rect: CGRect) -> (path: CGPath, ends: (CGPoint, CGPoint)?, isOpen: Bool) {
        if let custom = container?.child("custGeom"), let path = customPath(custom, rect: rect) { return (path, nil, false) }
        let preset = container?.child("prstGeom")
        let name = preset?.attr("prst") ?? "rect"
        var adjust: [String: Double] = [:]
        for guide in preset?.child("avLst")?.children("gd") ?? [] {
            let formula = (guide.attr("fmla") ?? "").split(separator: " ")
            if formula.count == 2, formula[0] == "val", let v = Double(formula[1]), v.isFinite { adjust[guide.attr("name") ?? ""] = v }
        }
        return presetPath(name, rect: rect, adjust: adjust)
    }

    static func presetPath(_ name: String, rect r: CGRect, adjust: [String: Double]) -> (path: CGPath, ends: (CGPoint, CGPoint)?, isOpen: Bool) {
        let path = CGMutablePath()
        let ss = min(r.width, r.height)
        func adj(_ key: String, _ fallback: Double) -> CGFloat { CGFloat(adjust[key] ?? adjust[key == "adj1" ? "adj" : key] ?? fallback) / 100_000 }
        func polygon(_ points: [CGPoint]) { path.addLines(between: points); path.closeSubpath() }
        switch name {
        case "line", "straightConnector1", "bentConnector2", "bentConnector3", "bentConnector4", "bentConnector5",
             "curvedConnector2", "curvedConnector3", "curvedConnector4", "curvedConnector5":
            let start = CGPoint(x: r.minX, y: r.minY), end = CGPoint(x: r.maxX, y: r.maxY)
            if name.hasPrefix("bentConnector3") {
                let mid = r.minX + r.width * adj("adj1", 50_000)
                path.addLines(between: [start, CGPoint(x: mid, y: r.minY), CGPoint(x: mid, y: r.maxY), end])
            } else if name == "bentConnector2" {
                path.addLines(between: [start, CGPoint(x: r.maxX, y: r.minY), end])
            } else {
                path.addLines(between: [start, end])
            }
            return (path, (start, end), true)
        case "ellipse", "flowChartConnector":
            path.addEllipse(in: r)
        case "roundRect", "flowChartAlternateProcess":
            let radius = min(ss * adj("adj", 16_667), r.width / 2, r.height / 2)
            path.addRoundedRect(in: r, cornerWidth: max(radius, 0), cornerHeight: max(radius, 0))
        case "triangle", "flowChartExtract", "flowChartMerge":
            let apex = r.minX + r.width * (name == "triangle" ? adj("adj", 50_000) : 0.5)
            if name == "flowChartMerge" {
                polygon([CGPoint(x: r.minX, y: r.minY), CGPoint(x: r.maxX, y: r.minY), CGPoint(x: r.midX, y: r.maxY)])
            } else {
                polygon([CGPoint(x: apex, y: r.minY), CGPoint(x: r.maxX, y: r.maxY), CGPoint(x: r.minX, y: r.maxY)])
            }
        case "rtTriangle":
            polygon([CGPoint(x: r.minX, y: r.minY), CGPoint(x: r.maxX, y: r.maxY), CGPoint(x: r.minX, y: r.maxY)])
        case "diamond", "flowChartDecision":
            polygon([CGPoint(x: r.midX, y: r.minY), CGPoint(x: r.maxX, y: r.midY), CGPoint(x: r.midX, y: r.maxY), CGPoint(x: r.minX, y: r.midY)])
        case "parallelogram", "flowChartInputOutput":
            let x = ss * (name == "parallelogram" ? adj("adj", 25_000) : 0.2)
            polygon([CGPoint(x: r.minX + x, y: r.minY), CGPoint(x: r.maxX, y: r.minY), CGPoint(x: r.maxX - x, y: r.maxY), CGPoint(x: r.minX, y: r.maxY)])
        case "trapezoid":
            let x = ss * adj("adj", 25_000)
            polygon([CGPoint(x: r.minX + x, y: r.minY), CGPoint(x: r.maxX - x, y: r.minY), CGPoint(x: r.maxX, y: r.maxY), CGPoint(x: r.minX, y: r.maxY)])
        case "pentagon", "homePlate":
            if name == "pentagon" {
                polygon([CGPoint(x: r.midX, y: r.minY), CGPoint(x: r.maxX, y: r.minY + r.height * 0.382), CGPoint(x: r.minX + r.width * 0.809, y: r.maxY),
                         CGPoint(x: r.minX + r.width * 0.191, y: r.maxY), CGPoint(x: r.minX, y: r.minY + r.height * 0.382)])
            } else {
                let head = min(ss * adj("adj", 50_000), r.width)
                polygon([CGPoint(x: r.minX, y: r.minY), CGPoint(x: r.maxX - head, y: r.minY), CGPoint(x: r.maxX, y: r.midY),
                         CGPoint(x: r.maxX - head, y: r.maxY), CGPoint(x: r.minX, y: r.maxY)])
            }
        case "chevron":
            let head = min(ss * adj("adj", 50_000), r.width)
            polygon([CGPoint(x: r.minX, y: r.minY), CGPoint(x: r.maxX - head, y: r.minY), CGPoint(x: r.maxX, y: r.midY),
                     CGPoint(x: r.maxX - head, y: r.maxY), CGPoint(x: r.minX, y: r.maxY), CGPoint(x: r.minX + head, y: r.midY)])
        case "hexagon":
            let x = ss * adj("adj", 25_000)
            polygon([CGPoint(x: r.minX + x, y: r.minY), CGPoint(x: r.maxX - x, y: r.minY), CGPoint(x: r.maxX, y: r.midY),
                     CGPoint(x: r.maxX - x, y: r.maxY), CGPoint(x: r.minX + x, y: r.maxY), CGPoint(x: r.minX, y: r.midY)])
        case "octagon":
            let x = ss * adj("adj", 29_289)
            polygon([CGPoint(x: r.minX + x, y: r.minY), CGPoint(x: r.maxX - x, y: r.minY), CGPoint(x: r.maxX, y: r.minY + x), CGPoint(x: r.maxX, y: r.maxY - x),
                     CGPoint(x: r.maxX - x, y: r.maxY), CGPoint(x: r.minX + x, y: r.maxY), CGPoint(x: r.minX, y: r.maxY - x), CGPoint(x: r.minX, y: r.minY + x)])
        case "rightArrow", "leftArrow", "upArrow", "downArrow":
            let shaft = adj("adj1", 50_000), headLength = adj("adj2", 50_000)
            let horizontal = name == "rightArrow" || name == "leftArrow"
            // Built pointing right in a unit frame, then mapped.
            let along = horizontal ? r.width : r.height, across = horizontal ? r.height : r.width
            let head = min(ss * headLength, along)
            let half = across * shaft / 2
            let points: [CGPoint] = [CGPoint(x: 0, y: across / 2 - half), CGPoint(x: along - head, y: across / 2 - half), CGPoint(x: along - head, y: 0),
                                     CGPoint(x: along, y: across / 2), CGPoint(x: along - head, y: across), CGPoint(x: along - head, y: across / 2 + half),
                                     CGPoint(x: 0, y: across / 2 + half)]
            let mapped = points.map { p -> CGPoint in
                switch name {
                case "rightArrow": CGPoint(x: r.minX + p.x, y: r.minY + p.y)
                case "leftArrow": CGPoint(x: r.maxX - p.x, y: r.minY + p.y)
                case "downArrow": CGPoint(x: r.minX + p.y, y: r.minY + p.x)
                default: CGPoint(x: r.minX + p.y, y: r.maxY - p.x)
                }
            }
            polygon(mapped)
        case "plus", "mathPlus":
            let x = ss * adj("adj", 25_000)
            polygon([CGPoint(x: r.minX + x, y: r.minY), CGPoint(x: r.maxX - x, y: r.minY), CGPoint(x: r.maxX - x, y: r.minY + x), CGPoint(x: r.maxX, y: r.minY + x),
                     CGPoint(x: r.maxX, y: r.maxY - x), CGPoint(x: r.maxX - x, y: r.maxY - x), CGPoint(x: r.maxX - x, y: r.maxY), CGPoint(x: r.minX + x, y: r.maxY),
                     CGPoint(x: r.minX + x, y: r.maxY - x), CGPoint(x: r.minX, y: r.maxY - x), CGPoint(x: r.minX, y: r.minY + x), CGPoint(x: r.minX + x, y: r.minY + x)])
        case "snip1Rect":
            let x = ss * adj("adj", 16_667)
            polygon([CGPoint(x: r.minX, y: r.minY), CGPoint(x: r.maxX - x, y: r.minY), CGPoint(x: r.maxX, y: r.minY + x), CGPoint(x: r.maxX, y: r.maxY), CGPoint(x: r.minX, y: r.maxY)])
        case "round1Rect", "round2SameRect":
            let radius = min(ss * adj("adj1", 16_667), r.width / 2, r.height / 2)
            path.move(to: CGPoint(x: r.minX, y: r.minY))
            if name == "round2SameRect" {
                path.move(to: CGPoint(x: r.minX + radius, y: r.minY))
            }
            path.addLine(to: CGPoint(x: r.maxX - radius, y: r.minY))
            path.addArc(tangent1End: CGPoint(x: r.maxX, y: r.minY), tangent2End: CGPoint(x: r.maxX, y: r.minY + radius), radius: max(radius, 0))
            path.addLine(to: CGPoint(x: r.maxX, y: r.maxY))
            path.addLine(to: CGPoint(x: r.minX, y: r.maxY))
            if name == "round2SameRect" {
                path.addLine(to: CGPoint(x: r.minX, y: r.minY + radius))
                path.addArc(tangent1End: CGPoint(x: r.minX, y: r.minY), tangent2End: CGPoint(x: r.minX + radius, y: r.minY), radius: max(radius, 0))
            }
            path.closeSubpath()
        case "donut":
            path.addEllipse(in: r)
            let inset = ss * adj("adj", 25_000)
            path.addEllipse(in: r.insetBy(dx: inset, dy: inset))
        default:
            path.addRect(r)
        }
        return (path, nil, false)
    }

    /// `a:custGeom`: each `a:path` scaled from its own w × h to the frame. Guide names in place of numbers aren't
    /// evaluated: such a path falls back to the frame rectangle.
    private static func customPath(_ geometry: XMLNode, rect r: CGRect) -> CGPath? {
        let path = CGMutablePath()
        var drewSomething = false
        for sub in geometry.child("pathLst")?.children("path") ?? [] {
            let w = Double(sub.attr("w") ?? "") ?? 0, h = Double(sub.attr("h") ?? "") ?? 0
            let sx = w > 0 ? r.width / w : 1 / slideEMU, sy = h > 0 ? r.height / h : 1 / slideEMU
            func point(_ node: XMLNode?) -> CGPoint? {
                guard let node, let x = Double(node.attr("x") ?? ""), let y = Double(node.attr("y") ?? ""), x.isFinite, y.isFinite else { return nil }
                return CGPoint(x: r.minX + x * sx, y: r.minY + y * sy)
            }
            var current = CGPoint(x: r.minX, y: r.minY)
            var started = false
            for command in sub.children {
                switch command.name {
                case "moveTo":
                    guard let p = point(command.child("pt")) else { return nil }
                    path.move(to: p); current = p; started = true
                case "lnTo":
                    guard let p = point(command.child("pt")) else { return nil }
                    if !started { path.move(to: current); started = true }
                    path.addLine(to: p); current = p
                case "cubicBezTo":
                    let points = command.children("pt").compactMap(point)
                    guard points.count == 3 else { return nil }
                    if !started { path.move(to: current); started = true }
                    path.addCurve(to: points[2], control1: points[0], control2: points[1]); current = points[2]
                case "quadBezTo":
                    let points = command.children("pt").compactMap(point)
                    guard points.count == 2 else { return nil }
                    if !started { path.move(to: current); started = true }
                    path.addQuadCurve(to: points[1], control: points[0]); current = points[1]
                case "arcTo":
                    guard let wr = Double(command.attr("wR") ?? ""), let hr = Double(command.attr("hR") ?? ""),
                          let start = Double(command.attr("stAng") ?? ""), let sweep = Double(command.attr("swAng") ?? "") else { return nil }
                    let rx = wr * sx, ry = hr * sy
                    let a0 = start / 60_000 * .pi / 180, a1 = (start + sweep) / 60_000 * .pi / 180
                    let center = CGPoint(x: current.x - rx * cos(a0), y: current.y - ry * sin(a0))
                    if !started { path.move(to: current); started = true }
                    let steps = max(Int(abs(sweep) / 60_000 / 10), 2)
                    for step in 1...steps {
                        let a = a0 + (a1 - a0) * Double(step) / Double(steps)
                        current = CGPoint(x: center.x + rx * cos(a), y: center.y + ry * sin(a))
                        path.addLine(to: current)
                    }
                case "close":
                    path.closeSubpath()
                default:
                    continue
                }
                drewSomething = true
            }
        }
        return drewSomething ? path : nil
    }
}
