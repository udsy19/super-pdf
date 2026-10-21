import CoreGraphics
import Foundation

// DrawingML colours, fills and lines for the PowerPoint importer (features #37): theme colour schemes with the master's
// colour map, the colour modifiers (lumMod/lumOff, tint, shade, alpha, satMod), solid/gradient/picture/pattern fills,
// and outlines. Units: EMU in the file (12700 per point), 1/60000 degree for angles, 1/1000 percent for fractions.

/// Points per EMU.
let slideEMU: Double = 12_700

/// An sRGB colour with alpha, components 0…1.
struct SlideColor: Hashable {
    var r: Double
    var g: Double
    var b: Double
    var a: Double = 1

    static let black = SlideColor(r: 0, g: 0, b: 0)
    static let white = SlideColor(r: 1, g: 1, b: 1)

    init(r: Double, g: Double, b: Double, a: Double = 1) {
        self.r = Self.unit(r); self.g = Self.unit(g); self.b = Self.unit(b); self.a = Self.unit(a)
    }

    /// "4472C4" (case-insensitive, an optional "#").
    init?(hex: String) {
        let digits = hex.hasPrefix("#") ? String(hex.dropFirst()) : hex
        guard digits.count == 6, let value = UInt32(digits, radix: 16) else { return nil }
        self.init(r: Double((value >> 16) & 0xFF) / 255, g: Double((value >> 8) & 0xFF) / 255, b: Double(value & 0xFF) / 255)
    }

    var cgColor: CGColor {
        CGColor(colorSpace: CGColorSpace(name: CGColorSpace.sRGB)!, components: [r, g, b, a].map { CGFloat($0) })
            ?? CGColor(red: r, green: g, blue: b, alpha: a)
    }

    /// Mixed with `other`: 0 keeps self, 1 gives `other`.
    func mixed(with other: SlideColor, _ amount: Double) -> SlideColor {
        SlideColor(r: r + (other.r - r) * amount, g: g + (other.g - g) * amount, b: b + (other.b - b) * amount, a: a + (other.a - a) * amount)
    }

    private static func unit(_ v: Double) -> Double { v.isFinite ? min(max(v, 0), 1) : 0 }

    // HSL, for lumMod/lumOff/satMod.
    var hsl: (h: Double, s: Double, l: Double) {
        let maxC = max(r, g, b), minC = min(r, g, b)
        let l = (maxC + minC) / 2
        guard maxC != minC else { return (0, 0, l) }
        let d = maxC - minC
        let s = l > 0.5 ? d / (2 - maxC - minC) : d / (maxC + minC)
        var h: Double
        switch maxC {
        case r: h = (g - b) / d + (g < b ? 6 : 0)
        case g: h = (b - r) / d + 2
        default: h = (r - g) / d + 4
        }
        h /= 6
        return (h, s, l)
    }

    init(h: Double, s: Double, l: Double, a: Double) {
        let s = min(max(s, 0), 1), l = min(max(l, 0), 1)
        guard s > 0 else { self.init(r: l, g: l, b: l, a: a); return }
        func hue(_ p: Double, _ q: Double, _ t: Double) -> Double {
            var t = t
            if t < 0 { t += 1 }
            if t > 1 { t -= 1 }
            if t < 1.0 / 6 { return p + (q - p) * 6 * t }
            if t < 1.0 / 2 { return q }
            if t < 2.0 / 3 { return p + (q - p) * (2.0 / 3 - t) * 6 }
            return p
        }
        let q = l < 0.5 ? l * (1 + s) : l + s - l * s
        let p = 2 * l - q
        self.init(r: hue(p, q, h + 1.0 / 3), g: hue(p, q, h), b: hue(p, q, h - 1.0 / 3), a: a)
    }
}

/// A theme part (`ppt/theme/themeN.xml`): colour scheme, fonts and the style matrix.
struct SlideTheme {
    var colors: [String: SlideColor] = [:]
    var majorFont: String?
    var minorFont: String?
    var fillStyles: [XMLNode] = []
    var lineStyles: [XMLNode] = []
    var backgroundFillStyles: [XMLNode] = []

    init(_ root: XMLNode?) {
        guard let elements = root?.child("themeElements") else { return }
        for entry in elements.child("clrScheme")?.children ?? [] {
            if let color = entry.children.first.flatMap(Self.baseColor) { colors[entry.name] = color }
        }
        majorFont = elements.path("fontScheme/majorFont/latin")?.attr("typeface").flatMap { $0.isEmpty ? nil : $0 }
        minorFont = elements.path("fontScheme/minorFont/latin")?.attr("typeface").flatMap { $0.isEmpty ? nil : $0 }
        let matrix = elements.child("fmtScheme")
        fillStyles = matrix?.child("fillStyleLst")?.children ?? []
        lineStyles = matrix?.child("lnStyleLst")?.children ?? []
        backgroundFillStyles = matrix?.child("bgFillStyleLst")?.children ?? []
    }

    /// The colour an `srgbClr`/`sysClr` scheme entry names, before any modifier.
    static func baseColor(_ node: XMLNode) -> SlideColor? {
        switch node.name {
        case "srgbClr": node.attr("val").flatMap(SlideColor.init(hex:))
        case "sysClr": node.attr("lastClr").flatMap(SlideColor.init(hex:)) ?? (node.attr("val") == "window" ? .white : .black)
        default: nil
        }
    }

    /// "+mj-lt" and "+mn-lt" (and their East Asian and complex-script forms) name the theme's fonts.
    func typeface(_ name: String?) -> String? {
        guard let name, !name.isEmpty else { return nil }
        if name.hasPrefix("+mj") { return majorFont }
        if name.hasPrefix("+mn") { return minorFont }
        return name
    }
}

/// What colour references resolve against on one slide: the theme, the colour map (bg1 → lt1…) and, inside theme
/// styles, the placeholder colour (`phClr`).
struct SlideColorContext {
    var theme: SlideTheme
    var map: [String: String]
    var placeholder: SlideColor?

    static let colorElements: Set<String> = ["srgbClr", "schemeClr", "sysClr", "prstClr", "scrgbClr", "hslClr"]

    /// Standard colour map, used when a master has none.
    static let defaultMap = ["bg1": "lt1", "tx1": "dk1", "bg2": "lt2", "tx2": "dk2", "accent1": "accent1", "accent2": "accent2",
                             "accent3": "accent3", "accent4": "accent4", "accent5": "accent5", "accent6": "accent6",
                             "hlink": "hlink", "folHlink": "folHlink"]

    func with(placeholder color: SlideColor?) -> SlideColorContext {
        var copy = self
        copy.placeholder = color
        return copy
    }

    /// The colour of `node`, which is a colour element or holds one (`solidFill`, `buClr`, a `fillRef`…).
    func color(_ node: XMLNode?) -> SlideColor? {
        guard let node else { return nil }
        if Self.colorElements.contains(node.name) { return resolve(node) }
        return node.children.first { Self.colorElements.contains($0.name) }.flatMap(resolve)
    }

    private func resolve(_ node: XMLNode) -> SlideColor? {
        var base: SlideColor?
        switch node.name {
        case "srgbClr": base = node.attr("val").flatMap(SlideColor.init(hex:))
        case "sysClr": base = SlideTheme.baseColor(node)
        case "schemeClr": base = scheme(node.attr("val") ?? "")
        case "prstClr": base = Self.preset[node.attr("val") ?? ""]
        case "scrgbClr":
            func v(_ k: String) -> Double { (Double(node.attr(k) ?? "") ?? 0) / 100_000 }
            // scRGB is linear light; approximate the sRGB transfer curve.
            func gamma(_ c: Double) -> Double { c <= 0.0031308 ? 12.92 * c : 1.055 * pow(c, 1 / 2.4) - 0.055 }
            base = SlideColor(r: gamma(v("r")), g: gamma(v("g")), b: gamma(v("b")))
        case "hslClr":
            let h = (Double(node.attr("hue") ?? "") ?? 0) / 21_600_000
            base = SlideColor(h: h, s: (Double(node.attr("sat") ?? "") ?? 0) / 100_000, l: (Double(node.attr("lum") ?? "") ?? 0) / 100_000, a: 1)
        default: base = nil
        }
        guard var color = base else { return nil }
        for modifier in node.children {
            guard let value = Double(modifier.attr("val") ?? "").map({ $0 / 100_000 }), value.isFinite else { continue }
            switch modifier.name {
            case "lumMod":
                let hsl = color.hsl; color = SlideColor(h: hsl.h, s: hsl.s, l: hsl.l * value, a: color.a)
            case "lumOff":
                let hsl = color.hsl; color = SlideColor(h: hsl.h, s: hsl.s, l: hsl.l + value, a: color.a)
            case "satMod":
                let hsl = color.hsl; color = SlideColor(h: hsl.h, s: hsl.s * value, l: hsl.l, a: color.a)
            case "tint":
                // "A 10% tint is 10% of the input colour combined with 90% white."
                color = SlideColor.white.mixed(with: color, value).withAlpha(color.a)
            case "shade":
                color = SlideColor.black.mixed(with: color, value).withAlpha(color.a)
            case "alpha":
                color.a = min(max(value, 0), 1)
            case "alphaMod":
                color.a = min(max(color.a * value, 0), 1)
            default:
                continue
            }
        }
        return color
    }

    func scheme(_ name: String) -> SlideColor? {
        if name == "phClr" { return placeholder ?? theme.colors[map["tx1"] ?? "dk1"] }
        let mapped = map[name] ?? Self.defaultMap[name] ?? name
        return theme.colors[mapped] ?? theme.colors[name]
    }

    static let preset: [String: SlideColor] = [
        "black": .black, "white": .white, "red": SlideColor(r: 1, g: 0, b: 0), "green": SlideColor(r: 0, g: 0.5, b: 0),
        "blue": SlideColor(r: 0, g: 0, b: 1), "yellow": SlideColor(r: 1, g: 1, b: 0), "gray": SlideColor(r: 0.5, g: 0.5, b: 0.5),
        "grey": SlideColor(r: 0.5, g: 0.5, b: 0.5), "orange": SlideColor(r: 1, g: 0.65, b: 0), "purple": SlideColor(r: 0.5, g: 0, b: 0.5),
        "cyan": SlideColor(r: 0, g: 1, b: 1), "magenta": SlideColor(r: 1, g: 0, b: 1), "silver": SlideColor(r: 0.75, g: 0.75, b: 0.75),
        "navy": SlideColor(r: 0, g: 0, b: 0.5), "maroon": SlideColor(r: 0.5, g: 0, b: 0), "lime": SlideColor(r: 0, g: 1, b: 0),
        "teal": SlideColor(r: 0, g: 0.5, b: 0.5), "olive": SlideColor(r: 0.5, g: 0.5, b: 0), "darkGray": SlideColor(r: 0.66, g: 0.66, b: 0.66),
        "lightGray": SlideColor(r: 0.83, g: 0.83, b: 0.83),
    ]
}

extension SlideColor {
    func withAlpha(_ alpha: Double) -> SlideColor { var c = self; c.a = alpha; return c }
}

/// How an area is painted.
enum SlideFill {
    case none
    case solid(SlideColor)
    /// Stops at 0…1; `angle` in degrees clockwise from left → right; `radial` for path gradients.
    case gradient(stops: [(Double, SlideColor)], angle: Double, radial: Bool)
    case picture(CGImage)

    /// A representative colour (table cell text contrast, pattern fills).
    var averageColor: SlideColor? {
        switch self {
        case .solid(let c): c
        case .gradient(let stops, _, _): stops.first?.1
        default: nil
        }
    }
}

/// An outline: width in points, its paint, an optional dash pattern (in multiples of the width), arrowheads.
struct SlideLine {
    var width: Double
    var fill: SlideFill
    var dash: [Double]?
    var headArrow = false
    var tailArrow = false
}

/// Fills, lines and pictures of one part (pictures resolve through that part's relationships).
struct SlidePaint {
    let deck: SlideDeck
    let part: SlidePart
    let colors: SlideColorContext

    static let fillNames: Set<String> = ["noFill", "solidFill", "gradFill", "blipFill", "pattFill", "grpFill"]

    /// The fill named inside `container` (`spPr`, `bgPr`, `tcPr`, a style list entry); nil when it names none.
    func fill(in container: XMLNode?, group: SlideFill? = nil) -> SlideFill? {
        guard let node = container?.children.first(where: { Self.fillNames.contains($0.name) }) else { return nil }
        return fill(node, group: group)
    }

    func fill(_ node: XMLNode, group: SlideFill? = nil) -> SlideFill? {
        switch node.name {
        case "noFill":
            return SlideFill.none
        case "solidFill":
            return colors.color(node).map(SlideFill.solid)
        case "gradFill":
            let stops = (node.child("gsLst")?.children("gs") ?? []).compactMap { stop -> (Double, SlideColor)? in
                guard let color = colors.color(stop) else { return nil }
                return (min(max((Double(stop.attr("pos") ?? "") ?? 0) / 100_000, 0), 1), color)
            }.sorted { $0.0 < $1.0 }
            guard !stops.isEmpty else { return nil }
            if stops.count == 1 { return .solid(stops[0].1) }
            let angle = (Double(node.child("lin")?.attr("ang") ?? "") ?? 5_400_000) / 60_000
            return .gradient(stops: stops, angle: angle, radial: node.child("path") != nil)
        case "blipFill":
            guard let id = node.child("blip")?.attr("r:embed"), let image = deck.image(part, id) else { return nil }
            return .picture(image)
        case "pattFill":
            // Patterns are drawn as the blend of their two colours.
            let fg = colors.color(node.child("fgClr")) ?? .black, bg = colors.color(node.child("bgClr")) ?? .white
            return .solid(bg.mixed(with: fg, 0.5))
        case "grpFill":
            return group
        default:
            return nil
        }
    }

    /// An outline (`a:ln`); nil when there is none to draw.
    func line(_ ln: XMLNode?, fallback: SlideLine? = nil) -> SlideLine? {
        guard let ln else { return fallback }
        var line = fallback ?? SlideLine(width: 0.75, fill: .none)
        if let w = Double(ln.attr("w") ?? ""), w.isFinite { line.width = min(max(w / slideEMU, 0), 200) }
        if let fill = fill(in: ln) { line.fill = fill }
        if let dash = ln.child("prstDash")?.attr("val"), let pattern = Self.dashes[dash] { line.dash = pattern }
        if let head = ln.child("headEnd")?.attr("type") { line.headArrow = head != "none" }
        if let tail = ln.child("tailEnd")?.attr("type") { line.tailArrow = tail != "none" }
        if case .none = line.fill { return nil }
        return line.width > 0 ? line : nil
    }

    static let dashes: [String: [Double]?] = [
        "solid": nil, "dot": [1, 1], "dash": [4, 3], "lgDash": [8, 3], "dashDot": [4, 3, 1, 3], "lgDashDot": [8, 3, 1, 3],
        "lgDashDotDot": [8, 3, 1, 3, 1, 3], "sysDash": [3, 1], "sysDot": [1, 1], "sysDashDot": [3, 1, 1, 1], "sysDashDotDot": [3, 1, 1, 1, 1, 1],
    ]

    /// A theme style-matrix fill (`fillRef`/`bgRef` idx): 1… the fill list, 1001… the background list, painted with the
    /// reference's colour as `phClr`.
    func themeFill(_ reference: XMLNode?) -> SlideFill? {
        guard let reference, let idx = Int(reference.attr("idx") ?? ""), idx > 0 else { return nil }
        let list = idx >= 1001 ? colors.theme.backgroundFillStyles : colors.theme.fillStyles
        let index = idx >= 1001 ? idx - 1001 : idx - 1
        guard list.indices.contains(index) else { return colors.color(reference).map(SlideFill.solid) }
        let styled = SlidePaint(deck: deck, part: part, colors: colors.with(placeholder: colors.color(reference)))
        return styled.fill(list[index]) ?? colors.color(reference).map(SlideFill.solid)
    }

    /// A theme line style (`lnRef` idx 1…).
    func themeLine(_ reference: XMLNode?) -> SlideLine? {
        guard let reference, let idx = Int(reference.attr("idx") ?? ""), idx > 0 else { return nil }
        let styled = SlidePaint(deck: deck, part: part, colors: colors.with(placeholder: colors.color(reference)))
        let list = colors.theme.lineStyles
        guard list.indices.contains(idx - 1) else {
            return colors.color(reference).map { SlideLine(width: 0.75, fill: .solid($0)) }
        }
        return styled.line(list[idx - 1])
    }
}

// MARK: - Painting

enum SlideDraw {
    /// Fills `path` (page space, y down) with `fill`.
    static func fill(_ path: CGPath, with fill: SlideFill?, in context: CGContext, evenOdd: Bool = false) {
        guard let fill else { return }
        switch fill {
        case .none:
            return
        case .solid(let color):
            context.setFillColor(color.cgColor)
            context.addPath(path)
            context.fillPath(using: evenOdd ? .evenOdd : .winding)
        case .gradient(let stops, let angle, let radial):
            let colors = stops.map(\.1.cgColor) as CFArray
            let locations = stops.map { CGFloat($0.0) }
            guard let gradient = CGGradient(colorsSpace: CGColorSpace(name: CGColorSpace.sRGB), colors: colors, locations: locations) else { return }
            let box = path.boundingBoxOfPath
            context.saveGState()
            context.addPath(path)
            context.clip(using: evenOdd ? .evenOdd : .winding)
            if radial {
                let center = CGPoint(x: box.midX, y: box.midY)
                context.drawRadialGradient(gradient, startCenter: center, startRadius: 0, endCenter: center,
                                           endRadius: hypot(box.width, box.height) / 2, options: [.drawsBeforeStartLocation, .drawsAfterEndLocation])
            } else {
                let radians = angle * .pi / 180
                let dx = cos(radians), dy = sin(radians)
                let half = (abs(box.width * dx) + abs(box.height * dy)) / 2
                let center = CGPoint(x: box.midX, y: box.midY)
                context.drawLinearGradient(gradient, start: CGPoint(x: center.x - dx * half, y: center.y - dy * half),
                                           end: CGPoint(x: center.x + dx * half, y: center.y + dy * half),
                                           options: [.drawsBeforeStartLocation, .drawsAfterEndLocation])
            }
            context.restoreGState()
        case .picture(let image):
            context.saveGState()
            context.addPath(path)
            context.clip(using: evenOdd ? .evenOdd : .winding)
            drawImage(image, in: path.boundingBoxOfPath, context: context)
            context.restoreGState()
        }
    }

    /// Strokes `path` with `line`; `ends` gives the first and last points for arrowheads.
    static func stroke(_ path: CGPath, with line: SlideLine?, in context: CGContext, ends: (CGPoint, CGPoint)? = nil) {
        guard let line, line.width > 0 else { return }
        let color: SlideColor
        switch line.fill {
        case .solid(let c): color = c
        case .gradient(let stops, _, _): color = stops.first?.1 ?? .black
        default: return
        }
        context.saveGState()
        context.setStrokeColor(color.cgColor)
        context.setLineWidth(line.width)
        context.setLineJoin(.round)
        if let dash = line.dash { context.setLineDash(phase: 0, lengths: dash.map { CGFloat($0 * max(line.width, 0.5)) }) }
        context.addPath(path)
        context.strokePath()
        if let (start, end) = ends {
            context.setFillColor(color.cgColor)
            context.setLineDash(phase: 0, lengths: [])
            if line.headArrow { arrowhead(at: start, from: end, width: line.width, in: context) }
            if line.tailArrow { arrowhead(at: end, from: start, width: line.width, in: context) }
        }
        context.restoreGState()
    }

    private static func arrowhead(at tip: CGPoint, from tail: CGPoint, width: Double, in context: CGContext) {
        let angle = atan2(tip.y - tail.y, tip.x - tail.x)
        let size = max(width * 3, 4)
        let left = CGPoint(x: tip.x - size * cos(angle - .pi / 7), y: tip.y - size * sin(angle - .pi / 7))
        let right = CGPoint(x: tip.x - size * cos(angle + .pi / 7), y: tip.y - size * sin(angle + .pi / 7))
        context.move(to: tip); context.addLine(to: left); context.addLine(to: right); context.closePath()
        context.fillPath()
    }

    /// Draws an image upright into `rect` of a y-down context.
    static func drawImage(_ image: CGImage, in rect: CGRect, context: CGContext) {
        guard rect.width > 0, rect.height > 0 else { return }
        context.saveGState()
        context.translateBy(x: rect.minX, y: rect.maxY)
        context.scaleBy(x: 1, y: -1)
        context.interpolationQuality = .high
        context.draw(image, in: CGRect(origin: .zero, size: rect.size))
        context.restoreGState()
    }
}
