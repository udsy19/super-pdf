import CoreGraphics
import Foundation
import PDFModelKit

// Takes content out of a page for real (features #69 "text objects clipped/removed by glyph bounds, images re-encoded
// with the area filled, paths clipped"; #88 hidden text and objects under pictures). It walks a content stream with
// the graphics and text state (ISO 32000-2 §8.4, §9.3–§9.4), places every glyph, path and picture on the page, and
// writes the stream again without what the rules take out: glyphs leave their string (a kerning number keeps the
// rest in place), subpaths inside an area go and those crossing it are cut geometrically, pictures are re-encoded
// with the area's pixels overwritten (`ImageRedactor`), and forms are rewritten as copies so other users of a shared
// form keep theirs. Marked-content spans that lost content drop their /ActualText, /Alt and /E, which could repeat it.

/// What a rewrite takes out.
struct ContentRules {
    /// Page-space areas content must leave, for the page-level operation at an index (forms' operations ask with the
    /// index of their `Do`).
    var areas: (Int) -> [CGRect]
    /// True cuts what is partly inside an area (redaction); false removes only what lies wholly inside one.
    var cutsPartially: Bool
    /// Also removes text drawn invisibly (render mode 3: OCR layers, hidden text), wherever it is.
    var removesInvisibleText = false
    /// Told about every picture drawn at page level: operation index, page-space box, whether it is opaque.
    var onPicture: ((Int, CGRect, Bool) -> Void)? = nil
}

/// What a rewrite took out.
struct RewriteStats {
    var glyphs = 0
    var invisibleGlyphs = 0
    var paths = 0
    var pictures = 0

    var total: Int { glyphs + paths + pictures }
    static func + (a: RewriteStats, b: RewriteStats) -> RewriteStats {
        RewriteStats(glyphs: a.glyphs + b.glyphs, invisibleGlyphs: a.invisibleGlyphs + b.invisibleGlyphs, paths: a.paths + b.paths,
                     pictures: a.pictures + b.pictures)
    }
}

final class ContentRewriter {
    private let model: PDFModel
    private let rules: ContentRules
    private var fonts: [Int: FontMetrics] = [:]
    private(set) var stats = RewriteStats()

    init(model: PDFModel, rules: ContentRules) {
        self.model = model
        self.rules = rules
    }

    /// Rewrites a page's content in place; true when anything changed. The new stream is the old one wrapped in q … Q
    /// followed by `appending` (the boxes Black out draws).
    @discardableResult
    func rewrite(page: PDFPage, appending extra: [PDFContentOperation] = []) throws -> Bool {
        let operations = try page.contentStream().operations
        let resources = page.resources
        var ownResources: PDFObject?
        let result = rewrite(operations, resources: resources, ctm: .identity, depth: 0, outerIndex: nil) { object in
            let own = ownResources ?? page.ownResources()
            ownResources = own
            return Self.add(object, to: own)
        }
        guard result.changed || !extra.isEmpty else { return false }
        var ops = result.operations
        if !extra.isEmpty { ops = PDFContentStream.isolated(ops) + extra }
        page.setContentStream(PDFContentStream(operations: ops))
        if let pruned = Self.pruned(page.resources, keeping: ops) { page.object.set("Resources", pruned) }
        return true
    }

    /// A copy of a resource dictionary without the XObjects the content no longer draws (the originals of rewritten
    /// pictures and forms would otherwise stay in the file); nil when nothing goes. A copy, because resource
    /// dictionaries are often shared with other pages.
    static func pruned(_ resources: PDFObject?, keeping operations: [PDFContentOperation]) -> PDFValue? {
        guard let resources, let xobjects = resources["XObject"], var dictionary = resources.value.dictionaryValue,
              var entries = xobjects.value.dictionaryValue else { return nil }
        let used = Set(operations.filter { $0.operator == "Do" }.compactMap { $0.operands.first?.nameValue })
        let unused = entries.keys.filter { !used.contains($0) }
        guard !unused.isEmpty else { return nil }
        for name in unused { entries.removeValue(forKey: name) }
        dictionary["XObject"] = .dictionary(entries)
        return .dictionary(dictionary)
    }

    /// Adds an XObject under a fresh name to a resource dictionary.
    static func add(_ object: PDFObject, to resources: PDFObject) -> String {
        let xobjects = resources.dictionary("XObject")
        let used = Set(xobjects.keys)
        var n = 0
        while used.contains("Rx\(n)") { n += 1 }
        xobjects.set("Rx\(n)", object)
        return "Rx\(n)"
    }

    // MARK: - The walk

    private struct GraphicsState {
        var ctm = CGAffineTransform.identity
        var font: FontMetrics?
        var fontSize = 0.0
        var charSpacing = 0.0
        var wordSpacing = 0.0
        var horizontalScale = 1.0
        var leading = 0.0
        var rise = 0.0
        var renderMode = 0
    }

    private enum Segment {
        case move(CGPoint), line(CGPoint), curve(CGPoint, CGPoint, CGPoint), close
    }

    private struct MarkedSpan { var outputIndex: Int; var touched: Bool }

    private func rewrite(_ operations: [PDFContentOperation], resources: PDFObject?, ctm: CGAffineTransform, depth: Int,
                         outerIndex: Int?, addXObject: @escaping (PDFObject) -> String) -> (operations: [PDFContentOperation], changed: Bool) {
        var out: [PDFContentOperation] = []
        out.reserveCapacity(operations.count)
        var changed = false
        var state = GraphicsState()
        state.ctm = ctm
        var stack: [GraphicsState] = []
        var tm = CGAffineTransform.identity, tlm = CGAffineTransform.identity
        var path: [Segment] = []
        var pathOps: [PDFContentOperation] = []
        var clipOp: PDFContentOperation?
        var current = CGPoint.zero, subpathStart = CGPoint.zero
        var spans: [MarkedSpan] = []

        func touch() {
            changed = true
            for i in spans.indices { spans[i].touched = true }
        }

        for (index, op) in operations.enumerated() {
            let level = outerIndex ?? index
            let n = op.operands.compactMap(\.numberValue)
            switch op.operator {
            // Graphics state
            case "q":
                stack.append(state); out.append(op)
            case "Q":
                if let last = stack.popLast() { state = last }
                out.append(op)
            case "cm":
                if n.count == 6 { state.ctm = CGAffineTransform(a: n[0], b: n[1], c: n[2], d: n[3], tx: n[4], ty: n[5]).concatenating(state.ctm) }
                out.append(op)

            // Text state
            case "BT":
                tm = .identity; tlm = .identity; out.append(op)
            case "Tc": state.charSpacing = n.first ?? 0; out.append(op)
            case "Tw": state.wordSpacing = n.first ?? 0; out.append(op)
            case "Tz": state.horizontalScale = (n.first ?? 100) / 100; out.append(op)
            case "TL": state.leading = n.first ?? 0; out.append(op)
            case "Ts": state.rise = n.first ?? 0; out.append(op)
            case "Tr": state.renderMode = Int(n.first ?? 0); out.append(op)
            case "Tf":
                if let name = op.operands.first?.nameValue { state.font = font(named: name, in: resources) }
                state.fontSize = n.last ?? state.fontSize
                out.append(op)
            case "Td", "TD":
                if n.count == 2 {
                    tlm = CGAffineTransform(translationX: n[0], y: n[1]).concatenating(tlm); tm = tlm
                    if op.operator == "TD" { state.leading = -n[1] }
                }
                out.append(op)
            case "Tm":
                if n.count == 6 { tlm = CGAffineTransform(a: n[0], b: n[1], c: n[2], d: n[3], tx: n[4], ty: n[5]); tm = tlm }
                out.append(op)
            case "T*":
                tlm = CGAffineTransform(translationX: 0, y: -state.leading).concatenating(tlm); tm = tlm
                out.append(op)

            // Text showing
            case "Tj", "TJ", "'", "\"":
                var prefix: [PDFContentOperation] = []
                var elements: [PDFValue] = []
                switch op.operator {
                case "'":
                    tlm = CGAffineTransform(translationX: 0, y: -state.leading).concatenating(tlm); tm = tlm
                    prefix = [PDFContentOperation("T*")]
                    elements = op.operands.last.map { [$0] } ?? []
                case "\"":
                    guard op.operands.count >= 3 else { out.append(op); continue }
                    if n.count >= 2 { state.wordSpacing = n[0]; state.charSpacing = n[1] }
                    tlm = CGAffineTransform(translationX: 0, y: -state.leading).concatenating(tlm); tm = tlm
                    prefix = [PDFContentOperation("Tw", [op.operands[0]]), PDFContentOperation("Tc", [op.operands[1]]), PDFContentOperation("T*")]
                    elements = op.operands.last.map { [$0] } ?? []
                case "TJ":
                    elements = op.operands.first?.arrayValue ?? []
                default:
                    elements = op.operands.last.map { [$0] } ?? []
                }
                let shown = show(elements, state: state, tm: &tm, level: level)
                if let rewritten = shown {
                    touch()
                    out.append(contentsOf: prefix)
                    out.append(PDFContentOperation("TJ", [.array(rewritten)]))
                } else {
                    out.append(op)
                }

            // Paths
            case "m":
                if n.count == 2 { current = CGPoint(x: n[0], y: n[1]); subpathStart = current; path.append(.move(current)) }
                pathOps.append(op)
            case "l":
                if n.count == 2 { current = CGPoint(x: n[0], y: n[1]); path.append(.line(current)) }
                pathOps.append(op)
            case "c":
                if n.count == 6 {
                    let end = CGPoint(x: n[4], y: n[5])
                    path.append(.curve(CGPoint(x: n[0], y: n[1]), CGPoint(x: n[2], y: n[3]), end)); current = end
                }
                pathOps.append(op)
            case "v":
                if n.count == 4 {
                    let end = CGPoint(x: n[2], y: n[3])
                    path.append(.curve(current, CGPoint(x: n[0], y: n[1]), end)); current = end
                }
                pathOps.append(op)
            case "y":
                if n.count == 4 {
                    let end = CGPoint(x: n[2], y: n[3])
                    path.append(.curve(CGPoint(x: n[0], y: n[1]), end, end)); current = end
                }
                pathOps.append(op)
            case "h":
                path.append(.close); current = subpathStart; pathOps.append(op)
            case "re":
                if n.count == 4 {
                    let o = CGPoint(x: n[0], y: n[1])
                    path += [.move(o), .line(CGPoint(x: n[0] + n[2], y: n[1])), .line(CGPoint(x: n[0] + n[2], y: n[1] + n[3])),
                             .line(CGPoint(x: n[0], y: n[1] + n[3])), .close]
                    current = o; subpathStart = o
                }
                pathOps.append(op)
            case "W", "W*":
                clipOp = op
            case "S", "s", "f", "F", "f*", "B", "B*", "b", "b*", "n":
                if let rewritten = paint(path, ops: pathOps, clip: clipOp, painting: op, ctm: state.ctm, level: level) {
                    touch()
                    out.append(contentsOf: rewritten)
                } else {
                    out.append(contentsOf: pathOps)
                    if let clipOp { out.append(clipOp) }
                    out.append(op)
                }
                path = []; pathOps = []; clipOp = nil

            // Pictures and forms
            case "Do":
                guard let name = op.operands.first?.nameValue, let object = resources?["XObject"]?[name], object.type == .stream else {
                    out.append(op); continue
                }
                switch object["Subtype"]?.name {
                case "Image":
                    let box = CGRect(x: 0, y: 0, width: 1, height: 1).applying(state.ctm)
                    if depth == 0, outerIndex == nil {
                        let opaque = object["SMask"] == nil && object["Mask"] == nil && object["ImageMask"]?.bool != true
                        rules.onPicture?(index, box, opaque)
                    }
                    switch picture(box: box, level: level) {
                    case .keep:
                        out.append(op)
                    case .remove:
                        stats.pictures += 1; touch()
                    case .cut(let areas):
                        if let copy = ImageRedactor.redact(object, model: model, areas: areas, imageToPage: state.ctm) {
                            stats.pictures += 1; touch()
                            out.append(PDFContentOperation("Do", [.name(addXObject(copy))]))
                        } else {
                            // Could not re-encode: the picture goes rather than keep what is under the area.
                            stats.pictures += 1; touch()
                        }
                    }
                case "Form" where depth < 12:
                    let matrix = object["Matrix"]?.value.matrixValue ?? .identity
                    let formCTM = matrix.concatenating(state.ctm)
                    let bounds = (object["BBox"]?.rect ?? .zero).applying(formCTM)
                    let areas = rules.areas(level).filter { $0.intersects(bounds) }
                    guard !areas.isEmpty || rules.removesInvisibleText, let data = try? object.streamData() else {
                        out.append(op); continue
                    }
                    let formResources = object["Resources"] ?? resources
                    var copyResources: PDFObject?
                    var copy: PDFObject?
                    let inner = rewrite(PDFContentStream(parsing: data).operations, resources: formResources, ctm: formCTM, depth: depth + 1,
                                        outerIndex: level) { [model] added in
                        // The copy's own resource dictionary, so names added for re-encoded pictures stay with it.
                        if copyResources == nil {
                            copy = copy ?? model.makeStream([:], data: Data())
                            copy!.set("Resources", formResources?.value ?? .dictionary([:]))
                            copyResources = copy!["Resources"]
                        }
                        return Self.add(added, to: copyResources!)
                    }
                    guard inner.changed else { out.append(op); continue }
                    var dictionary = object.value.dictionaryValue ?? [:]
                    for key in ["Length", "Filter", "DecodeParms"] { dictionary.removeValue(forKey: key) }
                    let form = copy ?? model.makeStream([:], data: Data())
                    let keptResources = form["Resources"]?.value
                    for (key, value) in dictionary where key != "Resources" || keptResources == nil { form.set(key, value) }
                    form.setStreamData(PDFContentStream(operations: inner.operations).serialized())
                    if let pruned = Self.pruned(form["Resources"], keeping: inner.operations) { form.set("Resources", pruned) }
                    touch()
                    out.append(PDFContentOperation("Do", [.name(addXObject(form))]))
                default:
                    out.append(op)
                }
            case "BI":
                let box = CGRect(x: 0, y: 0, width: 1, height: 1).applying(state.ctm)
                if depth == 0, outerIndex == nil {
                    let dict = op.operands.first?.dictionaryValue ?? [:]
                    let mask = dict["IM"]?.boolValue == true || dict["ImageMask"]?.boolValue == true
                    rules.onPicture?(index, box, !mask)
                }
                switch picture(box: box, level: level) {
                case .keep:
                    out.append(op)
                case .remove:
                    stats.pictures += 1; touch()
                case .cut(let areas):
                    // Re-encoded as an image XObject (inline image data can't safely hold arbitrary samples); one
                    // that can't be decoded goes.
                    stats.pictures += 1; touch()
                    if let redacted = ImageRedactor.redactInline(op, model: model, areas: areas, imageToPage: state.ctm) {
                        out.append(PDFContentOperation("Do", [.name(addXObject(redacted))]))
                    }
                }

            // Marked content
            case "BMC", "BDC":
                spans.append(MarkedSpan(outputIndex: out.count, touched: false))
                out.append(op)
            case "EMC":
                if let span = spans.popLast(), span.touched {
                    var opening = out[span.outputIndex]
                    if opening.operator == "BDC", opening.operands.count == 2, var properties = opening.operands[1].dictionaryValue {
                        let before = properties.count
                        for key in ["ActualText", "Alt", "E"] { properties.removeValue(forKey: key) }
                        if properties.count != before { opening.operands[1] = .dictionary(properties); out[span.outputIndex] = opening }
                    }
                }
                out.append(op)

            default:
                out.append(op)
            }
        }
        return (out, changed)
    }

    private func font(named name: String, in resources: PDFObject?) -> FontMetrics {
        guard let object = resources?["Font"]?[name] else { return FontMetrics(nil) }
        if let id = object.objectID, let cached = fonts[id] { return cached }
        let metrics = FontMetrics(object)
        if let id = object.objectID { fonts[id] = metrics }
        return metrics
    }

    // MARK: - Glyphs

    /// Places a show's glyphs; returns the TJ array without the removed ones (nil when nothing goes).
    private func show(_ elements: [PDFValue], state: GraphicsState, tm: inout CGAffineTransform, level: Int) -> [PDFValue]? {
        let font = state.font ?? FontMetrics(nil)
        let size = state.fontSize, h = state.horizontalScale
        let base = CGAffineTransform(a: size * h, b: 0, c: 0, d: size, tx: 0, ty: state.rise)
        let areas = rules.areas(level)
        let invisible = rules.removesInvisibleText && state.renderMode == 3
        guard invisible || !areas.isEmpty else {
            // Nothing can go: just advance the text position.
            for element in elements {
                if let number = element.numberValue { tm = CGAffineTransform(translationX: -number / 1000 * size * h, y: 0).concatenating(tm) }
                else if let string = element.stringValue {
                    for code in font.codes(string) {
                        let advance = (font.width(of: code.code) * size + state.charSpacing + (code.isSingleByteSpace ? state.wordSpacing : 0)) * h
                        tm = CGAffineTransform(translationX: advance, y: 0).concatenating(tm)
                    }
                }
            }
            return nil
        }
        var result: [PDFValue] = []
        var pending = Data()
        var removedAny = false
        func flush() { if !pending.isEmpty { result.append(.string(pending)); pending = Data() } }
        func shift(_ thousandths: Double) {
            guard thousandths != 0 else { return }
            if case .some(.real(let last)) = result.last { result[result.count - 1] = .real(last + thousandths) }
            else if case .some(.integer(let last)) = result.last { result[result.count - 1] = .real(Double(last) + thousandths) }
            else { result.append(.real(thousandths)) }
        }
        for element in elements {
            if let number = element.numberValue {
                flush()
                shift(number)
                tm = CGAffineTransform(translationX: -number / 1000 * size * h, y: 0).concatenating(tm)
                continue
            }
            guard let string = element.stringValue else { continue }
            for code in font.codes(string) {
                let w0 = font.width(of: code.code)
                let advance = (w0 * size + state.charSpacing + (code.isSingleByteSpace ? state.wordSpacing : 0)) * h
                let glyph = CGRect(x: 0, y: font.descent, width: max(w0, 0.05), height: font.ascent - font.descent)
                let box = glyph.applying(base.concatenating(tm).concatenating(state.ctm))
                if invisible || Self.removes(box, areas: areas, partially: rules.cutsPartially) {
                    removedAny = true
                    stats.glyphs += 1
                    if invisible { stats.invisibleGlyphs += 1 }
                    flush()
                    // A kerning number keeps the glyphs after it where they were.
                    if size * h != 0 { shift(-advance * 1000 / (size * h)) }
                } else {
                    pending.append(code.bytes)
                }
                tm = CGAffineTransform(translationX: advance, y: 0).concatenating(tm)
            }
        }
        flush()
        return removedAny ? result : nil
    }

    /// A glyph goes when its centre is inside an area, or a real part of it is (not a sliver of a neighbour's line).
    private static func removes(_ box: CGRect, areas: [CGRect], partially: Bool) -> Bool {
        for area in areas {
            if partially {
                if area.contains(CGPoint(x: box.midX, y: box.midY)) { return true }
                let overlap = area.intersection(box)
                if !overlap.isNull, overlap.width > 0.3 * box.width, overlap.height > 0.3 * box.height { return true }
            } else if area.insetBy(dx: -0.5, dy: -0.5).contains(box) {
                return true
            }
        }
        return false
    }

    // MARK: - Pictures

    private enum PictureAction { case keep, remove, cut([CGRect]) }

    private func picture(box: CGRect, level: Int) -> PictureAction {
        let areas = rules.areas(level).filter { $0.intersects(box) && !$0.intersection(box).isEmpty }
        guard !areas.isEmpty else { return .keep }
        if areas.contains(where: { $0.insetBy(dx: -0.5, dy: -0.5).contains(box) }) { return .remove }
        return rules.cutsPartially ? .cut(areas) : .keep
    }

    // MARK: - Paths

    /// The path and its painting rewritten without what lies in the areas; nil when nothing changes.
    private func paint(_ path: [Segment], ops: [PDFContentOperation], clip: PDFContentOperation?, painting: PDFContentOperation,
                       ctm: CGAffineTransform, level: Int) -> [PDFContentOperation]? {
        guard painting.operator != "n", !path.isEmpty else { return nil }
        let areas = rules.areas(level)
        guard !areas.isEmpty else { return nil }
        let subpaths = Self.split(path)
        let boxes = subpaths.map { Self.bounds($0, ctm: ctm) }
        guard boxes.contains(where: { box in areas.contains { $0.intersects(box) } }) else { return nil }

        let fills = ["f", "F", "f*", "B", "B*", "b", "b*"].contains(painting.operator)
        let strokes = ["S", "s", "B", "B*", "b", "b*"].contains(painting.operator)
        let closesForStroke = ["s", "b", "b*"].contains(painting.operator)
        let evenOdd = painting.operator.hasSuffix("*")
        var kept: [[Segment]] = []
        var fillPolygons: [[CGPoint]] = []
        var strokePieces: [[CGPoint]] = []
        var removed = 0
        for (subpath, box) in zip(subpaths, boxes) {
            let touching = areas.filter { $0.intersects(box) }
            if touching.isEmpty { kept.append(subpath); continue }
            removed += 1
            if touching.contains(where: { $0.insetBy(dx: -0.5, dy: -0.5).contains(box) }) { continue }
            guard rules.cutsPartially else { kept.append(subpath); removed -= 1; continue }
            let points = Self.flatten(subpath, ctm: ctm)
            guard !points.isEmpty else { continue }
            if fills { fillPolygons += Geometry.subtract(touching, from: [points]) }
            if strokes {
                let closed = closesForStroke || subpath.contains { if case .close = $0 { true } else { false } }
                strokePieces += Geometry.cutPolyline(closed ? points + [points[0]] : points, outside: touching)
            }
        }
        guard removed > 0 else { return nil }
        stats.paths += removed

        var out: [PDFContentOperation] = []
        let inverse = ctm.inverted()
        func emit(_ segments: [[Segment]], close: Bool) {
            for subpath in segments {
                for segment in subpath {
                    switch segment {
                    case .move(let p): out.append(PDFContentOperation("m", [.number(p.x), .number(p.y)]))
                    case .line(let p): out.append(PDFContentOperation("l", [.number(p.x), .number(p.y)]))
                    case .curve(let a, let b, let c):
                        out.append(PDFContentOperation("c", [a, b, c].flatMap { [PDFValue.number($0.x), .number($0.y)] }))
                    case .close: out.append(PDFContentOperation("h"))
                    }
                }
                if close, !subpath.contains(where: { if case .close = $0 { true } else { false } }) { out.append(PDFContentOperation("h")) }
            }
        }
        func emit(points: [[CGPoint]], close: Bool) {
            for polyline in points where polyline.count >= 2 {
                let user = polyline.map { $0.applying(inverse) }
                out.append(PDFContentOperation("m", [.number(user[0].x), .number(user[0].y)]))
                for p in user.dropFirst() { out.append(PDFContentOperation("l", [.number(p.x), .number(p.y)])) }
                if close { out.append(PDFContentOperation("h")) }
            }
        }
        if fills, !(kept.isEmpty && fillPolygons.isEmpty) {
            emit(kept, close: false)
            emit(points: fillPolygons, close: true)
            out.append(PDFContentOperation(evenOdd ? "f*" : "f"))
        }
        if strokes, !(kept.isEmpty && strokePieces.isEmpty) {
            emit(kept, close: closesForStroke)
            emit(points: strokePieces, close: false)
            out.append(PDFContentOperation("S"))
        }
        // A clip set by this path still applies after the painting, as it did before.
        if let clip { out += ops + [clip, PDFContentOperation("n")] }
        return out
    }

    private static func split(_ path: [Segment]) -> [[Segment]] {
        var result: [[Segment]] = []
        var current: [Segment] = []
        for segment in path {
            if case .move = segment, !current.isEmpty { result.append(current); current = [] }
            current.append(segment)
        }
        if !current.isEmpty { result.append(current) }
        return result
    }

    /// Page-space bounds of a subpath (control points included, so curves are inside).
    private static func bounds(_ subpath: [Segment], ctm: CGAffineTransform) -> CGRect {
        var points: [CGPoint] = []
        for segment in subpath {
            switch segment {
            case .move(let p), .line(let p): points.append(p)
            case .curve(let a, let b, let c): points += [a, b, c]
            case .close: break
            }
        }
        return Geometry.bounds(points.map { $0.applying(ctm) })
    }

    /// The subpath as a page-space polyline, curves in 16 steps.
    private static func flatten(_ subpath: [Segment], ctm: CGAffineTransform) -> [CGPoint] {
        var points: [CGPoint] = []
        var current = CGPoint.zero
        for segment in subpath {
            switch segment {
            case .move(let p), .line(let p):
                points.append(p); current = p
            case .curve(let a, let b, let c):
                for step in 1...16 {
                    let t = CGFloat(step) / 16, u = 1 - t
                    let x = u * u * u * current.x + 3 * u * u * t * a.x + 3 * u * t * t * b.x + t * t * t * c.x
                    let y = u * u * u * current.y + 3 * u * u * t * a.y + 3 * u * t * t * b.y + t * t * t * c.y
                    points.append(CGPoint(x: x, y: y))
                }
                current = c
            case .close:
                break
            }
        }
        return points.map { $0.applying(ctm) }
    }
}

/// Plane geometry for cutting paths out of rectangles.
enum Geometry {
    static func bounds(_ points: [CGPoint]) -> CGRect {
        guard let first = points.first else { return .null }
        var minX = first.x, maxX = first.x, minY = first.y, maxY = first.y
        for p in points.dropFirst() { minX = min(minX, p.x); maxX = max(maxX, p.x); minY = min(minY, p.y); maxY = max(maxY, p.y) }
        return CGRect(x: minX, y: minY, width: maxX - minX, height: maxY - minY)
    }

    /// Polygons minus rectangles: each polygon is clipped (Sutherland–Hodgman) to the four convex regions around each
    /// rectangle, which keeps the winding of every point outside it, so fill rules still hold.
    static func subtract(_ rects: [CGRect], from polygons: [[CGPoint]]) -> [[CGPoint]] {
        var result = polygons
        for rect in rects {
            var next: [[CGPoint]] = []
            for polygon in result {
                guard Geometry.bounds(polygon).intersects(rect) else { next.append(polygon); continue }
                for region in regions(around: rect) {
                    var clipped = polygon
                    for edge in region { clipped = clip(clipped, edge) ; if clipped.isEmpty { break } }
                    if clipped.count >= 3 { next.append(clipped) }
                }
            }
            result = next
        }
        return result
    }

    /// A half-plane: points with `inside(p)` true; `cross` finds where a segment crosses its border.
    private struct HalfPlane { var axisIsX: Bool; var value: CGFloat; var keepsGreater: Bool }

    private static func regions(around r: CGRect) -> [[HalfPlane]] {
        [[HalfPlane(axisIsX: true, value: r.minX, keepsGreater: false)],
         [HalfPlane(axisIsX: true, value: r.maxX, keepsGreater: true)],
         [HalfPlane(axisIsX: true, value: r.minX, keepsGreater: true), HalfPlane(axisIsX: true, value: r.maxX, keepsGreater: false),
          HalfPlane(axisIsX: false, value: r.maxY, keepsGreater: true)],
         [HalfPlane(axisIsX: true, value: r.minX, keepsGreater: true), HalfPlane(axisIsX: true, value: r.maxX, keepsGreater: false),
          HalfPlane(axisIsX: false, value: r.minY, keepsGreater: false)]]
    }

    private static func clip(_ polygon: [CGPoint], _ plane: HalfPlane) -> [CGPoint] {
        func inside(_ p: CGPoint) -> Bool {
            let v = plane.axisIsX ? p.x : p.y
            return plane.keepsGreater ? v >= plane.value : v <= plane.value
        }
        func crossing(_ a: CGPoint, _ b: CGPoint) -> CGPoint {
            if plane.axisIsX {
                let t = (plane.value - a.x) / (b.x - a.x)
                return CGPoint(x: plane.value, y: a.y + t * (b.y - a.y))
            }
            let t = (plane.value - a.y) / (b.y - a.y)
            return CGPoint(x: a.x + t * (b.x - a.x), y: plane.value)
        }
        guard !polygon.isEmpty else { return [] }
        var out: [CGPoint] = []
        var previous = polygon[polygon.count - 1]
        for point in polygon {
            switch (inside(previous), inside(point)) {
            case (true, true): out.append(point)
            case (true, false): out.append(crossing(previous, point))
            case (false, true): out.append(crossing(previous, point)); out.append(point)
            case (false, false): break
            }
            previous = point
        }
        return out
    }

    /// The parts of a polyline outside every rectangle (Liang–Barsky per segment).
    static func cutPolyline(_ points: [CGPoint], outside rects: [CGRect]) -> [[CGPoint]] {
        var pieces: [[CGPoint]] = []
        for (a, b) in zip(points, points.dropFirst()) {
            var parts: [(CGPoint, CGPoint)] = [(a, b)]
            for rect in rects {
                parts = parts.flatMap { outsideParts($0.0, $0.1, rect) }
            }
            for (p, q) in parts {
                if let last = pieces.last?.last, abs(last.x - p.x) < 0.001, abs(last.y - p.y) < 0.001 {
                    pieces[pieces.count - 1].append(q)
                } else {
                    pieces.append([p, q])
                }
            }
        }
        return pieces
    }

    /// A segment minus a rectangle: zero, one or two segments.
    private static func outsideParts(_ a: CGPoint, _ b: CGPoint, _ r: CGRect) -> [(CGPoint, CGPoint)] {
        let dx = b.x - a.x, dy = b.y - a.y
        var t0: CGFloat = 0, t1: CGFloat = 1
        let checks: [(CGFloat, CGFloat)] = [(-dx, a.x - r.minX), (dx, r.maxX - a.x), (-dy, a.y - r.minY), (dy, r.maxY - a.y)]
        for (p, q) in checks {
            if p == 0 {
                if q < 0 { return [(a, b)] }
            } else {
                let t = q / p
                if p < 0 { if t > t1 { return [(a, b)] }; t0 = max(t0, t) } else { if t < t0 { return [(a, b)] }; t1 = min(t1, t) }
            }
        }
        guard t0 < t1 else { return [(a, b)] }
        func at(_ t: CGFloat) -> CGPoint { CGPoint(x: a.x + t * dx, y: a.y + t * dy) }
        var result: [(CGPoint, CGPoint)] = []
        if t0 > 0.0001 { result.append((a, at(t0))) }
        if t1 < 0.9999 { result.append((at(t1), b)) }
        return result
    }
}
