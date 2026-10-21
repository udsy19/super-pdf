import CoreGraphics
import Foundation

// Shape outlines in page space (points, y up) and the Sketch tool's recogniser. The shapes PDFKit can't draw are
// stored as standard /Vertices polygons (features #76), so every reader can redraw them; these build those vertices.

enum Geometry {
    /// The five-pointed star that fills `rect`, starting at the top point.
    static func star(in rect: CGRect) -> [CGPoint] {
        let center = CGPoint(x: rect.midX, y: rect.midY)
        return (0..<10).map { i in
            let radius = i.isMultiple(of: 2) ? 1.0 : 0.382
            let angle = Double.pi / 2 + Double(i) * Double.pi / 5
            return CGPoint(x: center.x + rect.width / 2 * radius * cos(angle), y: center.y + rect.height / 2 * radius * sin(angle))
        }
    }

    /// Preview's polygon: a hexagon with flat top and bottom that fills `rect`.
    static func hexagon(in rect: CGRect) -> [CGPoint] {
        (0..<6).map { i in
            let angle = Double(i) * Double.pi / 3
            return CGPoint(x: rect.midX + rect.width / 2 * cos(angle), y: rect.midY + rect.height / 2 * sin(angle))
        }
    }

    /// A speech bubble: a rounded body over the top four fifths with a tail down to the bottom left, as vertices
    /// (corners sampled so the outline stays round in readers that redraw from /Vertices).
    static func speechBubble(in rect: CGRect) -> [CGPoint] {
        let tail = rect.height * 0.2
        let body = CGRect(x: rect.minX, y: rect.minY + tail, width: rect.width, height: rect.height - tail)
        let r = min(body.width, body.height) * 0.22
        func corner(_ cx: CGFloat, _ cy: CGFloat, from start: Double) -> [CGPoint] {
            (0...6).map { step in
                let a = start + Double(step) * Double.pi / 12
                return CGPoint(x: cx + r * cos(a), y: cy + r * sin(a))
            }
        }
        var points: [CGPoint] = []
        points += corner(body.maxX - r, body.minY + r, from: -Double.pi / 2)        // bottom right
        points += corner(body.maxX - r, body.maxY - r, from: 0)                      // top right
        points += corner(body.minX + r, body.maxY - r, from: Double.pi / 2)          // top left
        points += corner(body.minX + r, body.minY + r, from: Double.pi)              // bottom left
        // The tail leaves the bottom edge a quarter of the way along and points down-left.
        let baseLeft = CGPoint(x: body.minX + body.width * 0.22, y: body.minY)
        let baseRight = CGPoint(x: body.minX + body.width * 0.38, y: body.minY)
        points += [baseLeft, CGPoint(x: rect.minX + body.width * 0.12, y: rect.minY), baseRight]
        return points
    }

    /// Acrobat's cloudy border (/BE /S /C) around `rect`: bulges of about `radius` along each edge.
    static func cloud(in rect: CGRect, radius: CGFloat) -> CGPath {
        let path = CGMutablePath()
        let corners = [CGPoint(x: rect.minX, y: rect.minY), CGPoint(x: rect.maxX, y: rect.minY),
                       CGPoint(x: rect.maxX, y: rect.maxY), CGPoint(x: rect.minX, y: rect.maxY)]
        var points: [CGPoint] = []
        for i in 0..<4 {
            let a = corners[i], b = corners[(i + 1) % 4]
            let length = hypot(b.x - a.x, b.y - a.y)
            let count = max(1, Int((length / (radius * 1.6)).rounded()))
            for step in 0..<count {
                let t = CGFloat(step) / CGFloat(count)
                points.append(CGPoint(x: a.x + (b.x - a.x) * t, y: a.y + (b.y - a.y) * t))
            }
        }
        guard let first = points.first else { return path }
        path.move(to: first)
        for (i, p0) in points.enumerated() {
            let p1 = points[(i + 1) % points.count]
            let center = CGPoint(x: (p0.x + p1.x) / 2, y: (p0.y + p1.y) / 2)
            let half = hypot(p1.x - p0.x, p1.y - p0.y) / 2
            let angle = atan2(p1.y - p0.y, p1.x - p0.x)
            // Counter-clockwise around the box: the outward side is to the right, so sweep from behind p0 forwards
            // through the outward normal.
            path.addArc(center: center, radius: half, startAngle: angle + .pi, endAngle: angle + 2 * .pi, clockwise: false)
        }
        path.closeSubpath()
        return path
    }

    /// A closed or open path through `points`.
    static func path(through points: [CGPoint], closed: Bool) -> CGPath {
        let path = CGMutablePath()
        guard let first = points.first else { return path }
        path.move(to: first)
        for p in points.dropFirst() { path.addLine(to: p) }
        if closed { path.closeSubpath() }
        return path
    }

    /// The box around points, never thinner than `minimum`.
    static func bounds(of points: [CGPoint], minimum: CGFloat = 1) -> CGRect {
        guard let first = points.first else { return .zero }
        var rect = CGRect(origin: first, size: .zero)
        for p in points.dropFirst() { rect = rect.union(CGRect(origin: p, size: .zero)) }
        if rect.width < minimum { rect = rect.insetBy(dx: (rect.width - minimum) / 2, dy: 0) }
        if rect.height < minimum { rect = rect.insetBy(dx: 0, dy: (rect.height - minimum) / 2) }
        return rect
    }

    /// A rectangle from two corners.
    static func rect(_ a: CGPoint, _ b: CGPoint) -> CGRect {
        CGRect(x: min(a.x, b.x), y: min(a.y, b.y), width: abs(a.x - b.x), height: abs(a.y - b.y))
    }

    // MARK: Measuring (features #15)

    static func length(of points: [CGPoint], closed: Bool) -> Double {
        guard points.count > 1 else { return 0 }
        var total = 0.0
        for i in 1..<points.count { total += Double(hypot(points[i].x - points[i - 1].x, points[i].y - points[i - 1].y)) }
        if closed, let first = points.first, let last = points.last { total += Double(hypot(first.x - last.x, first.y - last.y)) }
        return total
    }

    /// The shoelace area of a simple polygon.
    static func area(of points: [CGPoint]) -> Double {
        guard points.count > 2 else { return 0 }
        var sum = 0.0
        for i in 0..<points.count {
            let a = points[i], b = points[(i + 1) % points.count]
            sum += Double(a.x * b.y - b.x * a.y)
        }
        return abs(sum) / 2
    }

    // MARK: Freehand

    /// Douglas–Peucker: fewer points, same line within `tolerance`.
    static func simplify(_ points: [CGPoint], tolerance: CGFloat) -> [CGPoint] {
        guard points.count > 2 else { return points }
        var keep = [Bool](repeating: false, count: points.count)
        keep[0] = true; keep[points.count - 1] = true
        var stack = [(0, points.count - 1)]
        while let (start, end) = stack.popLast() {
            var farthest = 0 as CGFloat, index = start
            for i in (start + 1)..<end {
                let d = distance(points[i], toSegment: points[start], points[end])
                if d > farthest { farthest = d; index = i }
            }
            if farthest > tolerance, index > start {
                keep[index] = true
                stack.append((start, index)); stack.append((index, end))
            }
        }
        return points.enumerated().filter { keep[$0.offset] }.map(\.element)
    }

    static func distance(_ p: CGPoint, toSegment a: CGPoint, _ b: CGPoint) -> CGFloat {
        let dx = b.x - a.x, dy = b.y - a.y
        let lengthSquared = dx * dx + dy * dy
        guard lengthSquared > 0 else { return hypot(p.x - a.x, p.y - a.y) }
        let t = max(0, min(1, ((p.x - a.x) * dx + (p.y - a.y) * dy) / lengthSquared))
        return hypot(p.x - (a.x + t * dx), p.y - (a.y + t * dy))
    }
}

/// What a Sketch stroke looks like (Preview turns a rough box into a rectangle, a rough ring into an oval).
enum SketchShape: Equatable {
    case line(CGPoint, CGPoint)
    case rectangle(CGRect)
    case oval(CGRect)
    case freehand

    static func recognise(_ points: [CGPoint]) -> SketchShape {
        guard points.count >= 2, let first = points.first, let last = points.last else { return .freehand }
        let travel = Geometry.length(of: points, closed: false)
        guard travel > 12 else { return .freehand }
        let chord = Double(hypot(last.x - first.x, last.y - first.y))
        // Nearly straight: no point strays far from the line between the ends.
        let straying = points.map { Double(Geometry.distance($0, toSegment: first, last)) }.max() ?? 0
        if chord > travel * 0.9, straying < max(4, chord * 0.06) { return .line(first, last) }
        // Closed: the stroke ends near where it began.
        guard chord < max(16, travel * 0.18) else { return .freehand }
        let box = Geometry.bounds(of: points)
        guard box.width > 12, box.height > 12 else { return .freehand }
        let scale = Double(min(box.width, box.height))
        let toRect = points.map { p -> Double in
            Double(min(abs(p.x - box.minX), abs(p.x - box.maxX), abs(p.y - box.minY), abs(p.y - box.maxY)))
        }.reduce(0, +) / Double(points.count) / scale
        let toOval = points.map { p -> Double in
            let nx = Double((p.x - box.midX) / (box.width / 2)), ny = Double((p.y - box.midY) / (box.height / 2))
            return abs(sqrt(nx * nx + ny * ny) - 1) * scale / 2
        }.reduce(0, +) / Double(points.count) / scale
        if min(toRect, toOval) > 0.09 { return .freehand }
        return toRect < toOval ? .rectangle(box) : .oval(box)
    }
}
