import CoreGraphics
import Foundation
import PDFModelKit

// Reads a page's content stream the way a viewer does (ISO 32000-2 §8.4 graphics state, §9.4 text objects) and
// hands back where every text run and every image lands on the page, with the operations that drew them, so they can
// be edited in place (features #60–#62, #72). Form XObjects are read too (their text is shown but not editable: the
// same form may be on many pages).

/// A text-showing operation (Tj, ', ", or one string of a TJ array) as it was drawn.
struct TextRun: Identifiable {
    var id: Int
    /// Index of the showing operation in the page's content (nil inside a form XObject).
    var opIndex: Int?
    /// For TJ: the index of this string in the array.
    var elementIndex: Int?
    var fontName: String
    var font: PDFFont
    /// Tfs.
    var fontSize: Double
    /// Text space → page space at the run's first glyph (Tm × CTM), without the font size.
    var matrix: CGAffineTransform
    var charSpacing: Double
    var wordSpacing: Double
    /// Th as a factor (1 = 100%).
    var horizontalScale: Double
    var rise: Double
    var renderMode: Int
    /// The fill colour operations in force (replayed for new text).
    var colorOps: [PDFContentOperation]
    /// Extra graphics state to replay (ExtGState name).
    var extGState: String?
    var units: [GlyphUnit]
    /// Each unit's start and advance along the baseline, in text space (Tm units).
    var offsets: [Double]
    var advances: [Double]
    var bounds: CGRect
    var inForm: Bool
    /// The clip in force (page space), when it is a plain rectangle.
    var clip: CGRect?

    var text: String { units.map(\.text).joined() }
    /// The total advance along the baseline in text space.
    var length: Double { (offsets.last ?? 0) + (advances.last ?? 0) }

    /// Page-space rectangle of the units in `range`.
    func bounds(of range: Range<Int>) -> CGRect {
        guard !range.isEmpty, range.upperBound <= units.count else { return .null }
        let x0 = offsets[range.lowerBound], x1 = offsets[range.upperBound - 1] + advances[range.upperBound - 1]
        return Self.box(x0: x0, x1: x1, fontSize: fontSize, rise: rise, ascent: font.ascent, descent: font.descent, matrix: matrix)
    }

    /// The box of a span along the baseline, through the run's matrix.
    static func box(x0: Double, x1: Double, fontSize: Double, rise: Double, ascent: Double, descent: Double, matrix: CGAffineTransform) -> CGRect {
        let top = ascent / 1000 * fontSize + rise, bottom = descent / 1000 * fontSize + rise
        let rect = CGRect(x: min(x0, x1), y: min(bottom, top), width: abs(x1 - x0), height: abs(top - bottom))
        return rect.applying(matrix)
    }

    /// The baseline point of text-space x, in page space.
    func baselinePoint(x: Double) -> CGPoint { CGPoint(x: x, y: rise).applying(matrix) }

    /// The page-space font size (Tfs through the matrix's scale).
    var pageFontSize: Double { fontSize * (matrix.b == 0 && matrix.c == 0 ? abs(matrix.d) : hypot(matrix.c, matrix.d)) }
}

/// An image XObject or inline image as it was drawn.
struct ImagePlacement: Identifiable {
    var id: Int
    var opIndex: Int?
    var resourceName: String?
    var isInline: Bool
    /// Unit square → page space.
    var transform: CGAffineTransform
    var bounds: CGRect
    var object: PDFObject?
    var inForm: Bool
    var clip: CGRect?
    /// The /OC of the XObject or the enclosing marked content, when hidden layers are flattened.
    var isHiddenLayer: Bool
}

/// What a page draws, in drawing order.
struct PageContent {
    var stream: PDFContentStream
    var runs: [TextRun]
    var images: [ImagePlacement]
    /// Fonts by resource name.
    var fonts: [String: PDFFont]

    /// Whether `opIndex` is a text-showing operation.
    static func isTextShowing(_ op: String) -> Bool { op == "Tj" || op == "TJ" || op == "'" || op == "\"" }
}

/// Runs the content and collects the runs and images.
struct ContentInterpreter {
    private struct GState {
        var ctm: CGAffineTransform = .identity
        var clip: CGRect?
        var colorOps: [PDFContentOperation] = []
        var fontName: String?
        var font: PDFFont?
        var fontSize: Double = 0
        var charSpacing: Double = 0
        var wordSpacing: Double = 0
        var horizontalScale: Double = 1
        var leading: Double = 0
        var rise: Double = 0
        var renderMode: Int = 0
        var extGState: String?
    }

    private var state = GState()
    private var stack: [GState] = []
    private var tm: CGAffineTransform = .identity
    private var tlm: CGAffineTransform = .identity
    private var runs: [TextRun] = []
    private var images: [ImagePlacement] = []
    private var fonts: [String: PDFFont] = [:]
    private var fontsByObject: [Int: PDFFont] = [:]
    private var pendingRect: CGRect?
    private var pathIsSingleRect = false
    private var pendingClip = false
    private var hiddenDepth = 0
    private var markedStack: [Bool] = []
    private var hiddenLayers: Set<Int>
    private var formDepth = 0
    private var seenForms: Set<Int> = []

    /// Reads `page`. `hiddenLayers` are the object numbers of OCGs that are off (their content is reported hidden).
    static func read(_ page: PDFPage, hiddenLayers: Set<Int> = []) throws -> PageContent {
        var interpreter = ContentInterpreter(hiddenLayers: hiddenLayers)
        let stream = try page.contentStream()
        interpreter.state.ctm = .identity
        interpreter.state.clip = nil
        interpreter.run(stream.operations, resources: page.resources, fallback: page.resources, inForm: false)
        return PageContent(stream: stream, runs: interpreter.runs, images: interpreter.images, fonts: interpreter.fonts)
    }

    private init(hiddenLayers: Set<Int>) { self.hiddenLayers = hiddenLayers }

    private mutating func run(_ ops: [PDFContentOperation], resources: PDFObject?, fallback: PDFObject?, inForm: Bool) {
        let base = stack.count
        for (index, op) in ops.enumerated() {
            let n = op.operands
            func num(_ i: Int) -> Double { i < n.count ? (n[i].numberValue ?? 0) : 0 }
            switch op.operator {
            case "q":
                stack.append(state)
            case "Q":
                if stack.count > base { state = stack.removeLast() }
            case "cm":
                guard n.count == 6 else { continue }
                let m = CGAffineTransform(a: num(0), b: num(1), c: num(2), d: num(3), tx: num(4), ty: num(5))
                state.ctm = m.concatenating(state.ctm)
            case "gs":
                if let name = n.first?.nameValue {
                    state.extGState = name
                    if let gs = resource("ExtGState", name, resources, fallback), let font = gs["Font"], let fontObject = font[0], let size = font[1]?.number {
                        state.font = loadFont(fontObject, name: "gs:" + name)
                        state.fontName = nil
                        state.fontSize = size
                    }
                }
            case "g", "rg", "k", "sc", "scn", "cs":
                if op.operator == "cs" { state.colorOps = [op] } else if op.operator == "sc" || op.operator == "scn" { state.colorOps = state.colorOps.filter { $0.operator == "cs" } + [op] } else { state.colorOps = [op] }
            case "re":
                guard n.count == 4 else { continue }
                let rect = CGRect(x: num(0), y: num(1), width: num(2), height: num(3)).standardized
                if pendingRect == nil { pendingRect = rect; pathIsSingleRect = true } else { pathIsSingleRect = false }
            case "m", "l", "c", "v", "y", "h":
                pathIsSingleRect = false
                if pendingRect == nil { pendingRect = .null }
            case "W", "W*":
                pendingClip = true
            case "n", "f", "F", "f*", "B", "B*", "b", "b*", "S", "s":
                if pendingClip {
                    if pathIsSingleRect, let rect = pendingRect, !rect.isNull {
                        let box = rect.applying(state.ctm)
                        state.clip = state.clip.map { $0.intersection(box) } ?? box
                    }
                    pendingClip = false
                }
                pendingRect = nil
                pathIsSingleRect = false
            case "BT":
                tm = .identity; tlm = .identity
            case "ET":
                break
            case "Tf":
                guard n.count >= 2, let name = n[0].nameValue else { continue }
                state.fontName = name
                state.fontSize = num(1)
                state.font = fontResource(name, resources, fallback)
            case "Td":
                tlm = CGAffineTransform(translationX: num(0), y: num(1)).concatenating(tlm); tm = tlm
            case "TD":
                state.leading = -num(1)
                tlm = CGAffineTransform(translationX: num(0), y: num(1)).concatenating(tlm); tm = tlm
            case "Tm":
                guard n.count == 6 else { continue }
                tlm = CGAffineTransform(a: num(0), b: num(1), c: num(2), d: num(3), tx: num(4), ty: num(5)); tm = tlm
            case "T*":
                nextLine()
            case "TL": state.leading = num(0)
            case "Tc": state.charSpacing = num(0)
            case "Tw": state.wordSpacing = num(0)
            case "Tz": state.horizontalScale = num(0) / 100
            case "Ts": state.rise = num(0)
            case "Tr": state.renderMode = Int(num(0))
            case "Tj":
                if let bytes = n.first?.stringValue { show(bytes, opIndex: inForm ? nil : index, element: nil, inForm: inForm) }
            case "'":
                nextLine()
                if let bytes = n.first?.stringValue { show(bytes, opIndex: inForm ? nil : index, element: nil, inForm: inForm) }
            case "\"":
                state.wordSpacing = num(0); state.charSpacing = num(1)
                nextLine()
                if n.count > 2, let bytes = n[2].stringValue { show(bytes, opIndex: inForm ? nil : index, element: nil, inForm: inForm) }
            case "TJ":
                guard let array = n.first?.arrayValue else { continue }
                for (i, item) in array.enumerated() {
                    switch item {
                    case .string(let bytes): show(bytes, opIndex: inForm ? nil : index, element: i, inForm: inForm)
                    default:
                        if let adj = item.numberValue {
                            let tx = -adj / 1000 * state.fontSize * state.horizontalScale
                            tm = CGAffineTransform(translationX: tx, y: 0).concatenating(tm)
                        }
                    }
                }
            case "Do":
                guard let name = n.first?.nameValue, let xobject = resource("XObject", name, resources, fallback) else { continue }
                if xobject["Subtype"]?.name == "Image" {
                    let hidden = hiddenDepth > 0 || isHidden(xobject["OC"])
                    images.append(ImagePlacement(id: images.count, opIndex: inForm ? nil : index, resourceName: name, isInline: false,
                                                 transform: state.ctm, bounds: CGRect(x: 0, y: 0, width: 1, height: 1).applying(state.ctm),
                                                 object: xobject, inForm: inForm, clip: state.clip, isHiddenLayer: hidden))
                } else if xobject["Subtype"]?.name == "Form", formDepth < 8 {
                    if let id = xobject.objectID { guard !seenForms.contains(id) else { continue }; seenForms.insert(id) }
                    let saved = state, savedStack = stack, savedTm = tm, savedTlm = tlm
                    if let matrix = xobject["Matrix"]?.value.matrixValue { state.ctm = matrix.concatenating(state.ctm) }
                    if let bbox = xobject["BBox"]?.rect {
                        let box = bbox.applying(state.ctm)
                        state.clip = state.clip.map { $0.intersection(box) } ?? box
                    }
                    if isHidden(xobject["OC"]) { hiddenDepth += 1 }
                    formDepth += 1
                    if let data = try? xobject.streamData(decode: .generalized) {
                        run(PDFContentStream(parsing: data).operations, resources: xobject["Resources"], fallback: resources ?? fallback, inForm: true)
                    }
                    formDepth -= 1
                    if isHidden(xobject["OC"]) { hiddenDepth -= 1 }
                    if let id = xobject.objectID { seenForms.remove(id) }
                    state = saved; stack = savedStack; tm = savedTm; tlm = savedTlm
                }
            case "BI":
                let bounds = CGRect(x: 0, y: 0, width: 1, height: 1).applying(state.ctm)
                images.append(ImagePlacement(id: images.count, opIndex: inForm ? nil : index, resourceName: nil, isInline: true, transform: state.ctm,
                                             bounds: bounds, object: nil, inForm: inForm, clip: state.clip, isHiddenLayer: hiddenDepth > 0))
            case "BDC":
                var hidden = false
                if n.first == .name("OC"), n.count > 1 {
                    if let name = n[1].nameValue, let ocg = resource("Properties", name, resources, fallback) { hidden = isHidden(ocg) }
                }
                markedStack.append(hidden)
                if hidden { hiddenDepth += 1 }
            case "BMC":
                markedStack.append(false)
            case "EMC":
                if let hidden = markedStack.popLast(), hidden { hiddenDepth -= 1 }
            default:
                break
            }
        }
        while stack.count > base { state = stack.removeLast() }
    }

    private mutating func nextLine() {
        tlm = CGAffineTransform(translationX: 0, y: -state.leading).concatenating(tlm)
        tm = tlm
    }

    private func isHidden(_ oc: PDFObject?) -> Bool {
        guard let oc else { return false }
        if let id = oc.objectID, hiddenLayers.contains(id) { return true }
        if oc["Type"]?.name == "OCMD" {
            if let ocgs = oc["OCGs"] {
                if let id = ocgs.objectID, hiddenLayers.contains(id) { return true }
                return ocgs.items.contains { $0.objectID.map(hiddenLayers.contains) ?? false }
            }
        }
        return false
    }

    private func resource(_ category: String, _ name: String, _ resources: PDFObject?, _ fallback: PDFObject?) -> PDFObject? {
        resources?[category]?[name] ?? fallback?[category]?[name]
    }

    private mutating func fontResource(_ name: String, _ resources: PDFObject?, _ fallback: PDFObject?) -> PDFFont? {
        guard let object = resource("Font", name, resources, fallback) else { return nil }
        return loadFont(object, name: name)
    }

    private mutating func loadFont(_ object: PDFObject, name: String) -> PDFFont {
        if let id = object.objectID, let cached = fontsByObject[id] {
            if formDepth == 0 { fonts[name] = cached }
            return cached
        }
        let font = PDFFont(object)
        if let id = object.objectID { fontsByObject[id] = font }
        if formDepth == 0 { fonts[name] = font }
        return font
    }

    private mutating func show(_ bytes: Data, opIndex: Int?, element: Int?, inForm: Bool) {
        guard let font = state.font else { return }
        let units = font.decode(bytes)
        font.noteUsed(units)
        var offsets: [Double] = [], advances: [Double] = []
        var x = 0.0
        let start = tm
        for unit in units {
            var w = unit.width / 1000 * state.fontSize
            if font.isType3 { w = unit.width / 1000 * state.fontSize }   // widths were scaled by the font matrix already
            var tx = (w + state.charSpacing + (unit.isWordSpace ? state.wordSpacing : 0)) * state.horizontalScale
            if tx.isNaN || tx.isInfinite { tx = 0 }
            offsets.append(x); advances.append(tx)
            x += tx
        }
        tm = CGAffineTransform(translationX: x, y: 0).concatenating(tm)
        guard !units.isEmpty else { return }
        let matrix = CGAffineTransform(a: state.horizontalScale, b: 0, c: 0, d: 1, tx: 0, ty: 0).concatenating(start).concatenating(state.ctm)
        // Offsets are in horizontally scaled space; divide them back so the matrix (which scales) places them.
        let scale = state.horizontalScale == 0 ? 1 : state.horizontalScale
        let unscaledOffsets = offsets.map { $0 / scale }, unscaledAdvances = advances.map { $0 / scale }
        let bounds = TextRun.box(x0: 0, x1: x / scale, fontSize: state.fontSize, rise: state.rise, ascent: font.ascent, descent: font.descent, matrix: matrix)
        let run = TextRun(id: runs.count, opIndex: opIndex, elementIndex: element, fontName: state.fontName ?? "", font: font, fontSize: state.fontSize,
                          matrix: matrix, charSpacing: state.charSpacing, wordSpacing: state.wordSpacing, horizontalScale: state.horizontalScale,
                          rise: state.rise, renderMode: state.renderMode, colorOps: state.colorOps, extGState: state.extGState, units: units,
                          offsets: unscaledOffsets, advances: unscaledAdvances, bounds: bounds, inForm: inForm || hiddenDepth > 0, clip: state.clip)
        runs.append(run)
    }
}
