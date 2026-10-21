import CoreGraphics
import CoreText
import Foundation

// Text of the PowerPoint importer: paragraph and run properties resolved through the inheritance chain (the run, the
// shape's list style, the placeholder on the layout and the master, the master's title/body/other style, the
// presentation's default), bullets and numbering, and Core Text layout drawn as real text.

enum SlideSpacing {
    case percent(Double)
    case points(Double)

    init?(_ node: XMLNode?) {
        guard let node else { return nil }
        if let pct = node.child("spcPct")?.attr("val").flatMap(Double.init), pct.isFinite {
            self = .percent(min(max(pct / 100_000, 0), 10))
        } else if let pts = node.child("spcPts")?.attr("val").flatMap(Double.init), pts.isFinite {
            self = .points(min(max(pts / 100, 0), 1_000))
        } else {
            return nil
        }
    }

    func points(fontSize: Double) -> Double {
        switch self {
        case .percent(let p): p * fontSize * 1.2
        case .points(let p): p
        }
    }
}

enum SlideBullet {
    case none
    case character(String)
    /// `scheme` is the `buAutoNum` type ("arabicPeriod"), numbering from `start`.
    case number(scheme: String, start: Int)
}

/// Run properties (`a:rPr`, `a:defRPr`), each nil when this layer doesn't say.
struct SlideRunProps {
    var size: Double?
    var bold: Bool?
    var italic: Bool?
    var underline: Bool?
    var color: SlideColor?
    var typeface: String?
    /// Superscript (> 0) or subscript (< 0).
    var baseline: Double?
    var allCaps: Bool?

    init() {}

    init(_ node: XMLNode?, colors: SlideColorContext) {
        guard let node else { return }
        if let sz = node.attr("sz").flatMap(Double.init), sz.isFinite { size = min(max(sz / 100, 1), 4_000) }
        bold = SlideRunProps.flag(node.attr("b"))
        italic = SlideRunProps.flag(node.attr("i"))
        if let u = node.attr("u") { underline = u != "none" }
        if let fill = node.child("solidFill") { color = colors.color(fill) }
        else if let gradient = node.child("gradFill")?.child("gsLst")?.children("gs").first { color = colors.color(gradient) }
        if let face = node.child("latin")?.attr("typeface"), !face.isEmpty { typeface = face }
        if let b = node.attr("baseline").flatMap(Double.init), b.isFinite { baseline = b / 100_000 }
        if let cap = node.attr("cap") { allCaps = cap == "all" }
    }

    static func flag(_ text: String?) -> Bool? {
        switch text {
        case "1", "true", "on": true
        case "0", "false", "off": false
        default: nil
        }
    }

    /// This layer over `base`: what this one says wins.
    func merged(over base: SlideRunProps) -> SlideRunProps {
        var out = self
        out.size = size ?? base.size
        out.bold = bold ?? base.bold
        out.italic = italic ?? base.italic
        out.underline = underline ?? base.underline
        out.color = color ?? base.color
        out.typeface = typeface ?? base.typeface
        out.baseline = baseline ?? base.baseline
        out.allCaps = allCaps ?? base.allCaps
        return out
    }
}

/// Paragraph properties (`a:pPr`, `a:lvlNpPr`).
struct SlideParagraphProps {
    var align: String?
    /// Points.
    var marginLeft: Double?
    var indent: Double?
    var lineSpacing: SlideSpacing?
    var spaceBefore: SlideSpacing?
    var spaceAfter: SlideSpacing?
    var bullet: SlideBullet?
    var bulletColor: SlideColor?
    var bulletSizePercent: Double?
    var bulletFont: String?
    var run = SlideRunProps()

    init() {}

    init(_ node: XMLNode?, colors: SlideColorContext) {
        guard let node else { return }
        align = node.attr("algn")
        func points(_ key: String) -> Double? {
            guard let v = node.attr(key).flatMap(Double.init), v.isFinite else { return nil }
            return min(max(v / slideEMU, -2_000), 2_000)
        }
        marginLeft = points("marL")
        indent = points("indent")
        lineSpacing = SlideSpacing(node.child("lnSpc"))
        spaceBefore = SlideSpacing(node.child("spcBef"))
        spaceAfter = SlideSpacing(node.child("spcAft"))
        if node.child("buNone") != nil {
            bullet = SlideBullet.none
        } else if let char = node.child("buChar")?.attr("char"), !char.isEmpty {
            bullet = .character(char)
        } else if let number = node.child("buAutoNum") {
            bullet = .number(scheme: number.attr("type") ?? "arabicPeriod", start: max(Int(number.attr("startAt") ?? "") ?? 1, 0))
        }
        if let clr = node.child("buClr") { bulletColor = colors.color(clr) }
        if let pct = node.child("buSzPct")?.attr("val").flatMap(Double.init), pct.isFinite { bulletSizePercent = min(max(pct / 100_000, 0.1), 4) }
        if let face = node.child("buFont")?.attr("typeface"), !face.isEmpty { bulletFont = face }
        run = SlideRunProps(node.child("defRPr"), colors: colors)
    }

    func merged(over base: SlideParagraphProps) -> SlideParagraphProps {
        var out = self
        out.align = align ?? base.align
        out.marginLeft = marginLeft ?? base.marginLeft
        out.indent = indent ?? base.indent
        out.lineSpacing = lineSpacing ?? base.lineSpacing
        out.spaceBefore = spaceBefore ?? base.spaceBefore
        out.spaceAfter = spaceAfter ?? base.spaceAfter
        out.bullet = bullet ?? base.bullet
        out.bulletColor = bulletColor ?? base.bulletColor
        out.bulletSizePercent = bulletSizePercent ?? base.bulletSizePercent
        out.bulletFont = bulletFont ?? base.bulletFont
        out.run = run.merged(over: base.run)
        return out
    }
}

/// Body properties (`a:bodyPr`) resolved through the placeholder chain.
struct SlideBodyProps {
    var insets = (left: 7.2, top: 3.6, right: 7.2, bottom: 3.6)
    var anchor = "t"
    var wraps = true
    var fontScale = 1.0
    var spacingReduction = 0.0
    var vertical = false

    init(_ chain: [XMLNode]) {
        func first(_ key: String) -> String? { chain.lazy.compactMap { $0.attr(key) }.first }
        func inset(_ key: String, _ fallback: Double) -> Double {
            guard let v = first(key).flatMap(Double.init), v.isFinite else { return fallback }
            return min(max(v / slideEMU, 0), 1_000)
        }
        insets = (inset("lIns", 7.2), inset("tIns", 3.6), inset("rIns", 7.2), inset("bIns", 3.6))
        anchor = first("anchor") ?? "t"
        wraps = first("wrap") != "none"
        vertical = ["vert", "eaVert", "wordArtVert", "vert270", "mongolianVert"].contains(first("vert") ?? "horz")
        if let autofit = chain.lazy.compactMap({ $0.child("normAutofit") }).first {
            if let scale = autofit.attr("fontScale").flatMap(Double.init), scale.isFinite { fontScale = min(max(scale / 100_000, 0.05), 1) }
            if let reduction = autofit.attr("lnSpcReduction").flatMap(Double.init), reduction.isFinite {
                spacingReduction = min(max(reduction / 100_000, 0), 0.9)
            }
        }
    }
}

/// One layer of inherited text style below a shape's own list style.
enum SlideStyleLayer {
    /// A list style (`a:lstStyle`, `p:titleStyle`, `p:defaultTextStyle`…) with `lvl1pPr`…`lvl9pPr`.
    case list(XMLNode)
    /// Run defaults only (a shape style's font reference, a table style's cell text).
    case run(SlideRunProps)
}

/// Where a text body's inherited properties come from.
struct SlideTextContext {
    /// Most specific first: the layout's and master's placeholder list styles, the master text style, the
    /// presentation default, with run layers where they apply.
    var layers: [SlideStyleLayer]
    /// `bodyPr` of the placeholder chain, most specific first.
    var bodies: [XMLNode]
    var colors: SlideColorContext
    var slideNumber: Int
    /// The theme font used when nothing names one ("+mn-lt" for bodies, "+mj-lt" for titles).
    var defaultTypeface: String?
}

enum SlideText {
    /// Lays out and draws `txBody` inside `frame` (page space, y down). Returns the text it drew (empty when none).
    @discardableResult
    static func draw(_ body: XMLNode, in frame: CGRect, context textContext: SlideTextContext, cg: CGContext) -> String {
        let props = SlideBodyProps([body.child("bodyPr")].compactMap { $0 } + textContext.bodies)
        guard let built = attributedString(body, context: textContext, body: props), built.string.contains(where: { !$0.isWhitespace }) else {
            return ""
        }
        var area = CGRect(x: frame.minX + props.insets.left, y: frame.minY + props.insets.top,
                          width: frame.width - props.insets.left - props.insets.right,
                          height: frame.height - props.insets.top - props.insets.bottom)
        if props.vertical { area = CGRect(x: area.midX - area.height / 2, y: area.midY - area.width / 2, width: area.height, height: area.width) }
        cg.saveGState()
        if props.vertical {
            cg.translateBy(x: frame.midX, y: frame.midY)
            cg.rotate(by: .pi / 2)
            cg.translateBy(x: -frame.midX, y: -frame.midY)
        }
        layout(built.text, in: area, anchor: props.anchor, wraps: props.wraps, alignment: built.firstAlignment, cg: cg)
        cg.restoreGState()
        return built.string
    }

    /// The height `txBody` needs inside `width` including its insets (table rows grow to fit their text).
    static func height(_ body: XMLNode, width: CGFloat, context textContext: SlideTextContext) -> CGFloat {
        let props = SlideBodyProps([body.child("bodyPr")].compactMap { $0 } + textContext.bodies)
        guard let built = attributedString(body, context: textContext, body: props), built.string.contains(where: { !$0.isWhitespace }) else { return 0 }
        let framesetter = CTFramesetterCreateWithAttributedString(built.text)
        let inner = max(width - props.insets.left - props.insets.right, 1)
        let size = CTFramesetterSuggestFrameSizeWithConstraints(framesetter, CFRange(), nil, CGSize(width: inner, height: .greatestFiniteMagnitude), nil)
        return ceil(size.height) + props.insets.top + props.insets.bottom
    }

    /// Draws laid-out text in `area` anchored top/centre/bottom; text taller than the area overflows as it does in
    /// PowerPoint.
    static func layout(_ text: NSAttributedString, in area: CGRect, anchor: String, wraps: Bool, alignment: CTTextAlignment, cg: CGContext) {
        let framesetter = CTFramesetterCreateWithAttributedString(text)
        let width = wraps ? max(area.width, 1) : 100_000
        let size = CTFramesetterSuggestFrameSizeWithConstraints(framesetter, CFRange(), nil, CGSize(width: width, height: .greatestFiniteMagnitude), nil)
        let height = ceil(size.height)
        var box = CGRect(x: area.minX, y: area.minY, width: wraps ? max(area.width, 1) : ceil(size.width) + 1, height: height)
        if !wraps {
            switch alignment {
            case .center: box.origin.x = area.midX - box.width / 2
            case .right: box.origin.x = area.maxX - box.width
            default: break
            }
        }
        switch anchor {
        case "ctr": box.origin.y = area.midY - height / 2
        case "b": box.origin.y = area.maxY - height
        default: break
        }
        // A little room below so rounding never drops the last line; the top stays where it was placed.
        let slack: CGFloat = 4
        cg.saveGState()
        cg.translateBy(x: box.minX, y: box.minY + height + slack)
        cg.scaleBy(x: 1, y: -1)
        cg.textMatrix = .identity
        let frame = CTFramesetterCreateFrame(framesetter, CFRange(), CGPath(rect: CGRect(x: 0, y: 0, width: box.width, height: height + slack), transform: nil), nil)
        CTFrameDraw(frame, cg)
        cg.restoreGState()
    }

    struct Built {
        var text: NSAttributedString
        var string: String
        var firstAlignment: CTTextAlignment
    }

    /// The paragraph's properties: its own, the shape's list style, then the inherited layers.
    static func paragraphProps(_ pPr: XMLNode?, level: Int, own: XMLNode?, context: SlideTextContext) -> SlideParagraphProps {
        let key = "lvl\(level + 1)pPr"
        var props = SlideParagraphProps(pPr, colors: context.colors).merged(over: SlideParagraphProps(own?.child(key), colors: context.colors))
        for layer in context.layers {
            switch layer {
            case .list(let node): props = props.merged(over: SlideParagraphProps(node.child(key), colors: context.colors))
            case .run(let run): props.run = props.run.merged(over: run)
            }
        }
        return props
    }

    static func attributedString(_ body: XMLNode, context: SlideTextContext, body bodyProps: SlideBodyProps) -> Built? {
        let colors = context.colors
        let own = body.child("lstStyle")
        let out = NSMutableAttributedString()
        var counters: [Int: Int] = [:]
        var numbered: [Int: Bool] = [:]
        var firstAlignment: CTTextAlignment?
        let paragraphs = body.children("p")
        for (index, paragraph) in paragraphs.enumerated() {
            guard out.length < SlideLimits.textCharacters else { break }
            let pPr = paragraph.child("pPr")
            let level = min(max(Int(pPr?.attr("lvl") ?? "") ?? 0, 0), 8)
            let props = paragraphProps(pPr, level: level, own: own, context: context)

            var runs: [(String, SlideRunProps)] = []
            for item in paragraph.children {
                switch item.name {
                case "r":
                    runs.append((item.child("t")?.text ?? "", SlideRunProps(item.child("rPr"), colors: colors).merged(over: props.run)))
                case "br":
                    runs.append(("\u{2028}", SlideRunProps(item.child("rPr"), colors: colors).merged(over: props.run)))
                case "fld":
                    let text = item.attr("type") == "slidenum" ? String(context.slideNumber) : (item.child("t")?.text ?? "")
                    runs.append((text, SlideRunProps(item.child("rPr"), colors: colors).merged(over: props.run)))
                default:
                    continue
                }
            }
            let hasText = runs.contains { !$0.0.isEmpty }
            let endProps = SlideRunProps(paragraph.child("endParaRPr"), colors: colors).merged(over: props.run)
            let firstRun = runs.first { !$0.0.isEmpty }?.1 ?? endProps
            let paragraphStart = out.length

            var hasBullet = false
            if hasText, let bullet = props.bullet {
                var marker: String?
                switch bullet {
                case .none:
                    numbered[level] = false
                case .character(let char):
                    marker = SlideBullets.character(char, font: props.bulletFont)
                    numbered[level] = false
                case .number(let scheme, let start):
                    let next = numbered[level] == true ? (counters[level] ?? start - 1) + 1 : start
                    counters[level] = next
                    numbered[level] = true
                    marker = SlideBullets.number(next, scheme: scheme)
                }
                for deeper in (level + 1)..<9 { numbered[deeper] = false }
                if let marker {
                    var bulletRun = firstRun
                    bulletRun.size = (firstRun.size ?? 18) * (props.bulletSizePercent ?? 1)
                    bulletRun.color = props.bulletColor ?? firstRun.color
                    bulletRun.underline = false
                    bulletRun.baseline = nil
                    bulletRun.allCaps = false
                    if let face = props.bulletFont.flatMap(colors.theme.typeface), !SlideBullets.isSymbolFont(face) { bulletRun.typeface = face }
                    out.append(NSAttributedString(string: marker + "\t", attributes: attributes(bulletRun, context: context, body: bodyProps)))
                    hasBullet = true
                }
            }
            if hasText {
                for (text, run) in runs where !text.isEmpty {
                    let shown = run.allCaps == true ? text.uppercased() : text
                    out.append(NSAttributedString(string: shown, attributes: attributes(run, context: context, body: bodyProps)))
                }
            }
            let isLast = index == paragraphs.count - 1
            if !isLast || !hasText {
                // An empty paragraph still takes a line at its end-of-paragraph size.
                out.append(NSAttributedString(string: isLast ? "\u{200B}" : "\n", attributes: attributes(hasText ? firstRun : endProps, context: context, body: bodyProps)))
            }
            let range = NSRange(location: paragraphStart, length: out.length - paragraphStart)
            guard range.length > 0 else { continue }
            let size = (firstRun.size ?? 18) * bodyProps.fontScale
            let style = paragraphStyle(props, fontSize: size, isFirst: index == 0, hasBullet: hasBullet, body: bodyProps)
            out.addAttribute(NSAttributedString.Key(kCTParagraphStyleAttributeName as String), value: style.style, range: range)
            if firstAlignment == nil { firstAlignment = style.alignment }
        }
        guard out.length > 0 else { return nil }
        return Built(text: out, string: out.string.replacingOccurrences(of: "\u{200B}", with: ""), firstAlignment: firstAlignment ?? .left)
    }

    /// Core Text attributes for a run.
    static func attributes(_ run: SlideRunProps, context: SlideTextContext, body: SlideBodyProps) -> [NSAttributedString.Key: Any] {
        var size = (run.size ?? 18) * body.fontScale
        if let baseline = run.baseline, baseline != 0 { size *= 0.66 }
        let theme = context.colors.theme
        let face = theme.typeface(run.typeface) ?? theme.typeface(context.defaultTypeface) ?? theme.minorFont ?? "Helvetica Neue"
        let font = SlideFonts.font(face, size: size, bold: run.bold ?? false, italic: run.italic ?? false)
        let color = run.color ?? context.colors.scheme("tx1") ?? .black
        var attributes: [NSAttributedString.Key: Any] = [
            NSAttributedString.Key(kCTFontAttributeName as String): font,
            NSAttributedString.Key(kCTForegroundColorAttributeName as String): color.cgColor,
        ]
        if run.underline == true { attributes[NSAttributedString.Key(kCTUnderlineStyleAttributeName as String)] = CTUnderlineStyle.single.rawValue }
        if let baseline = run.baseline, baseline != 0 { attributes[NSAttributedString.Key(kCTSuperscriptAttributeName as String)] = baseline > 0 ? 1 : -1 }
        return attributes
    }

    static func paragraphStyle(_ props: SlideParagraphProps, fontSize: Double, isFirst: Bool, hasBullet: Bool,
                               body: SlideBodyProps) -> (style: CTParagraphStyle, alignment: CTTextAlignment) {
        let alignment: CTTextAlignment = switch props.align {
        case "ctr": .center
        case "r": .right
        case "just", "dist", "justLow", "thaiDist": .justified
        default: .left
        }
        let margin = CGFloat(max(props.marginLeft ?? 0, 0))
        let first = CGFloat(max((props.marginLeft ?? 0) + (props.indent ?? 0), 0))
        var tabs: [CTTextTab] = []
        if hasBullet, margin > first + 1 { tabs.append(CTTextTabCreate(.left, Double(margin), nil)) }
        var lineMultiple: CGFloat = 0, lineExact: CGFloat = 0
        switch props.lineSpacing {
        case .percent(let p)?: lineMultiple = CGFloat(max(p * (1 - body.spacingReduction), 0.1))
        case .points(let p)?: lineExact = CGFloat(p)
        case nil: if body.spacingReduction > 0 { lineMultiple = CGFloat(1 - body.spacingReduction) }
        }
        let before = isFirst ? 0 : CGFloat(props.spaceBefore?.points(fontSize: fontSize) ?? 0)
        let after = CGFloat(props.spaceAfter?.points(fontSize: fontSize) ?? 0)
        let settings = SlideParagraphSettings()
        settings.add(.alignment, alignment)
        settings.add(.headIndent, margin)
        settings.add(.firstLineHeadIndent, first)
        settings.add(.defaultTabInterval, CGFloat(72))
        settings.add(.tabStops, tabs as CFArray)
        if lineMultiple > 0 { settings.add(.lineHeightMultiple, lineMultiple) }
        if lineExact > 0 { settings.add(.minimumLineHeight, lineExact); settings.add(.maximumLineHeight, lineExact) }
        settings.add(.paragraphSpacingBefore, before)
        settings.add(.paragraphSpacing, after)
        return (settings.make(), alignment)
    }
}

/// Owns the values a `CTParagraphStyle` is made from until it is made.
final class SlideParagraphSettings {
    private var settings: [CTParagraphStyleSetting] = []
    private var buffers: [UnsafeMutableRawPointer] = []

    func add<T>(_ specifier: CTParagraphStyleSpecifier, _ value: T) {
        let buffer = UnsafeMutableRawPointer.allocate(byteCount: MemoryLayout<T>.size, alignment: MemoryLayout<T>.alignment)
        buffer.initializeMemory(as: T.self, repeating: value, count: 1)
        buffers.append(buffer)
        settings.append(CTParagraphStyleSetting(spec: specifier, valueSize: MemoryLayout<T>.size, value: buffer))
    }

    func make() -> CTParagraphStyle { CTParagraphStyleCreate(settings, settings.count) }

    deinit {
        // CFArray values were retained by the style; the raw buffers are ours.
        for buffer in buffers { buffer.deallocate() }
    }
}

/// Fonts by name with substitutes for the Office fonts macOS doesn't have.
enum SlideFonts {
    private static let lock = NSLock()
    nonisolated(unsafe) private static var cache: [String: CTFont] = [:]

    static func font(_ name: String, size: Double, bold: Bool, italic: Bool) -> CTFont {
        let size = CGFloat(min(max(size, 1), 4_000))
        let key = "\(name)|\(size)|\(bold)|\(italic)"
        lock.lock(); defer { lock.unlock() }
        if let cached = cache[key] { return cached }
        var base = CTFontCreateWithName(name as CFString, size, nil)
        if !matches(base, name) { base = CTFontCreateWithName(substitute(for: name) as CFString, size, nil) }
        var traits: CTFontSymbolicTraits = []
        if bold { traits.insert(.traitBold) }
        if italic { traits.insert(.traitItalic) }
        let font = traits.isEmpty ? base : (CTFontCreateCopyWithSymbolicTraits(base, size, nil, traits, traits) ?? base)
        if cache.count > 2_000 { cache.removeAll() }
        cache[key] = font
        return font
    }

    private static func matches(_ font: CTFont, _ name: String) -> Bool {
        let wanted = name.lowercased()
        let names = [CTFontCopyFamilyName(font), CTFontCopyPostScriptName(font), CTFontCopyFullName(font)].map { ($0 as String).lowercased() }
        return names.contains(wanted) || names.contains(wanted.replacingOccurrences(of: " ", with: ""))
    }

    static func substitute(for name: String) -> String {
        let lower = name.lowercased()
        if ["mono", "courier", "consolas", "code"].contains(where: lower.contains) { return "Menlo" }
        if ["times", "cambria", "georgia", "garamond", "serif", "book", "palatino", "minion", "constantia"].contains(where: lower.contains)
            && !lower.contains("sans") { return "Times New Roman" }
        return "Helvetica Neue"
    }
}

/// Bullet characters and numbering schemes.
enum SlideBullets {
    static func isSymbolFont(_ name: String) -> Bool {
        let lower = name.lowercased()
        return lower.hasPrefix("wingdings") || lower == "symbol" || lower.hasPrefix("webdings")
    }

    /// The character to show: symbol-font code points mapped to their Unicode look-alikes.
    static func character(_ char: String, font: String?) -> String {
        guard let font, isSymbolFont(font) else { return char }
        let map: [String: String] = ["\u{A7}": "\u{25AA}", "\u{D8}": "\u{27A2}", "\u{FC}": "\u{2713}", "q": "\u{2751}", "v": "\u{2756}",
                                     "n": "\u{25A0}", "l": "\u{25CF}", "o": "\u{25CB}", "w": "\u{25C6}", "\u{DC}": "\u{27A4}", "\u{E8}": "\u{2794}",
                                     "\u{E0}": "\u{2794}", "\u{F0A7}": "\u{25AA}", "\u{F0B7}": "\u{2022}", "\u{F06C}": "\u{25CF}", "\u{B7}": "\u{2022}"]
        return map[char] ?? "•"
    }

    static func number(_ n: Int, scheme: String) -> String {
        let lower = scheme.lowercased()
        let body: String
        if lower.hasPrefix("alphalc") { body = letters(n).lowercased() }
        else if lower.hasPrefix("alphauc") { body = letters(n) }
        else if lower.hasPrefix("romanlc") { body = roman(n).lowercased() }
        else if lower.hasPrefix("romanuc") { body = roman(n) }
        else { body = String(n) }
        if lower.hasSuffix("parenboth") { return "(\(body))" }
        if lower.hasSuffix("parenr") { return "\(body))" }
        if lower.hasSuffix("plain") { return body }
        return "\(body)."
    }

    private static func letters(_ n: Int) -> String {
        var n = max(n, 1), out = ""
        while n > 0 { n -= 1; out = String(UnicodeScalar(UInt8(65 + n % 26))) + out; n /= 26 }
        return out
    }

    private static func roman(_ n: Int) -> String {
        guard n > 0, n < 4_000 else { return String(n) }
        let table: [(Int, String)] = [(1000, "M"), (900, "CM"), (500, "D"), (400, "CD"), (100, "C"), (90, "XC"), (50, "L"), (40, "XL"), (10, "X"),
                                      (9, "IX"), (5, "V"), (4, "IV"), (1, "I")]
        var n = n, out = ""
        for (value, symbol) in table { while n >= value { out += symbol; n -= value } }
        return out
    }
}
