import CoreGraphics
import Foundation

/// Reads a page's drawing with Quartz's content-stream scanner: ruling lines (thin rectangles and axis-aligned
/// strokes), placed images (image XObjects and inline images) and the bounding boxes of other painted paths. Form
/// XObjects are followed with their matrix; text is left to `TextExtractor`. Runs off the main actor.
public enum PageGraphicsScanner {
    /// The page's graphics in page space (origin at the crop box's lower-left corner, unrotated).
    public static func scan(_ page: CGPDFPage) -> PageGraphics {
        let crop = page.getBoxRect(.cropBox)
        let state = ScanState(ctm: CGAffineTransform(translationX: -crop.minX, y: -crop.minY))
        if let pageDictionary = page.dictionary {
            var resources: CGPDFDictionaryRef?
            if CGPDFDictionaryGetDictionary(pageDictionary, "Resources", &resources) { state.pageResources = resources }
        }
        guard let table = CGPDFOperatorTableCreate() else { return .empty }
        installCallbacks(table)
        let content = CGPDFContentStreamCreateWithPage(page)
        run(content, table: table, state: state)
        return PageGraphics(rulings: state.rulings, images: state.images, vectors: state.vectors)
    }

    // MARK: State

    final class ScanState {
        var ctm: CGAffineTransform
        var stack: [CGAffineTransform] = []
        var lineWidth: CGFloat = 1
        var subpaths: [Subpath] = []
        var current: Subpath?
        var rulings: [Ruling] = []
        var images: [CGRect] = []
        var vectors: [CGRect] = []
        var inlineImagePending = false
        var depth = 0
        var drawCount = 0
        var tables: [CGPDFOperatorTableRef] = []
        var pageResources: CGPDFDictionaryRef?

        init(ctm: CGAffineTransform) { self.ctm = ctm }

        struct Subpath {
            var points: [CGPoint]
            var isRectangle: Bool
            var bounds: CGRect { CGRect.union(points.map { CGRect(origin: $0, size: .zero) }) }
        }
    }

    private static func state(_ info: UnsafeMutableRawPointer?) -> ScanState {
        Unmanaged<ScanState>.fromOpaque(info!).takeUnretainedValue()
    }

    private static func numbers(_ scanner: CGPDFScannerRef, _ count: Int) -> [CGFloat] {
        var values = [CGPDFReal](repeating: 0, count: count)
        for index in stride(from: count - 1, through: 0, by: -1) { CGPDFScannerPopNumber(scanner, &values[index]) }
        return values.map { CGFloat($0) }
    }

    // MARK: Operators

    private static func installCallbacks(_ table: CGPDFOperatorTableRef) {
        CGPDFOperatorTableSetCallback(table, "q") { _, info in let s = PageGraphicsScanner.state(info); s.stack.append(s.ctm) }
        CGPDFOperatorTableSetCallback(table, "Q") { _, info in let s = PageGraphicsScanner.state(info); if let top = s.stack.popLast() { s.ctm = top } }
        CGPDFOperatorTableSetCallback(table, "cm") { scanner, info in
            let s = PageGraphicsScanner.state(info), v = PageGraphicsScanner.numbers(scanner, 6)
            s.ctm = CGAffineTransform(a: v[0], b: v[1], c: v[2], d: v[3], tx: v[4], ty: v[5]).concatenating(s.ctm)
        }
        CGPDFOperatorTableSetCallback(table, "w") { scanner, info in let s = PageGraphicsScanner.state(info); s.lineWidth = PageGraphicsScanner.numbers(scanner, 1)[0] }
        CGPDFOperatorTableSetCallback(table, "m") { scanner, info in
            let s = PageGraphicsScanner.state(info), v = PageGraphicsScanner.numbers(scanner, 2)
            s.closeSubpath()
            s.current = ScanState.Subpath(points: [CGPoint(x: v[0], y: v[1]).applying(s.ctm)], isRectangle: false)
        }
        CGPDFOperatorTableSetCallback(table, "l") { scanner, info in let s = PageGraphicsScanner.state(info), v = PageGraphicsScanner.numbers(scanner, 2); s.add(CGPoint(x: v[0], y: v[1])) }
        CGPDFOperatorTableSetCallback(table, "c") { scanner, info in
            let s = PageGraphicsScanner.state(info), v = PageGraphicsScanner.numbers(scanner, 6)
            s.add(CGPoint(x: v[0], y: v[1])); s.add(CGPoint(x: v[2], y: v[3])); s.add(CGPoint(x: v[4], y: v[5]))
        }
        CGPDFOperatorTableSetCallback(table, "v") { scanner, info in let s = PageGraphicsScanner.state(info), v = PageGraphicsScanner.numbers(scanner, 4); s.add(CGPoint(x: v[0], y: v[1])); s.add(CGPoint(x: v[2], y: v[3])) }
        CGPDFOperatorTableSetCallback(table, "y") { scanner, info in let s = PageGraphicsScanner.state(info), v = PageGraphicsScanner.numbers(scanner, 4); s.add(CGPoint(x: v[0], y: v[1])); s.add(CGPoint(x: v[2], y: v[3])) }
        CGPDFOperatorTableSetCallback(table, "h") { _, info in PageGraphicsScanner.state(info).closeSubpath() }
        CGPDFOperatorTableSetCallback(table, "re") { scanner, info in
            let s = PageGraphicsScanner.state(info), v = PageGraphicsScanner.numbers(scanner, 4)
            s.closeSubpath()
            let corners = [CGPoint(x: v[0], y: v[1]), CGPoint(x: v[0] + v[2], y: v[1]), CGPoint(x: v[0] + v[2], y: v[1] + v[3]), CGPoint(x: v[0], y: v[1] + v[3])]
            s.subpaths.append(ScanState.Subpath(points: corners.map { $0.applying(s.ctm) }, isRectangle: true))
        }
        for op in ["S", "s", "B", "B*", "b", "b*"] { CGPDFOperatorTableSetCallback(table, op) { _, info in PageGraphicsScanner.state(info).paint(stroked: true) } }
        for op in ["f", "F", "f*"] { CGPDFOperatorTableSetCallback(table, op) { _, info in PageGraphicsScanner.state(info).paint(stroked: false) } }
        CGPDFOperatorTableSetCallback(table, "n") { _, info in PageGraphicsScanner.state(info).discardPath() }
        CGPDFOperatorTableSetCallback(table, "BI") { _, info in PageGraphicsScanner.state(info).inlineImage(.begin) }
        CGPDFOperatorTableSetCallback(table, "ID") { _, info in PageGraphicsScanner.state(info).inlineImage(.data) }
        CGPDFOperatorTableSetCallback(table, "EI") { _, info in PageGraphicsScanner.state(info).inlineImage(.end) }
        CGPDFOperatorTableSetCallback(table, "Do") { scanner, info in
            let s = PageGraphicsScanner.state(info)
            var name: UnsafePointer<CChar>?
            guard CGPDFScannerPopName(scanner, &name), let name, s.drawCount < 4000 else { return }
            s.drawCount += 1
            let content = CGPDFScannerGetContentStream(scanner)
            guard let object = CGPDFContentStreamGetResource(content, "XObject", name) else { return }
            var stream: CGPDFStreamRef?
            guard CGPDFObjectGetValue(object, .stream, &stream), let stream, let dictionary = CGPDFStreamGetDictionary(stream) else { return }
            var subtype: UnsafePointer<CChar>?
            CGPDFDictionaryGetName(dictionary, "Subtype", &subtype)
            switch subtype.map({ String(cString: $0) }) {
            case "Image":
                s.images.append(CGRect(x: 0, y: 0, width: 1, height: 1).applying(s.ctm).standardized)
            case "Form":
                guard s.depth < 6 else { return }
                var matrix: CGPDFArrayRef?
                var transform = CGAffineTransform.identity
                if CGPDFDictionaryGetArray(dictionary, "Matrix", &matrix), let matrix, CGPDFArrayGetCount(matrix) == 6 {
                    var values = [CGPDFReal](repeating: 0, count: 6)
                    for index in 0..<6 { CGPDFArrayGetNumber(matrix, index, &values[index]) }
                    transform = CGAffineTransform(a: CGFloat(values[0]), b: CGFloat(values[1]), c: CGFloat(values[2]), d: CGFloat(values[3]), tx: CGFloat(values[4]), ty: CGFloat(values[5]))
                }
                var resources: CGPDFDictionaryRef?
                CGPDFDictionaryGetDictionary(dictionary, "Resources", &resources)
                // A form without its own resources inherits the page's.
                guard let formResources = resources ?? s.pageResources else { return }
                let saved = (s.ctm, s.stack, s.current, s.subpaths, s.lineWidth)
                s.ctm = transform.concatenating(s.ctm); s.stack = []; s.current = nil; s.subpaths = []
                s.depth += 1
                let formContent = CGPDFContentStreamCreateWithStream(stream, formResources, content)
                if let table = s.tables.first { PageGraphicsScanner.run(formContent, table: table, state: s) }
                s.depth -= 1
                (s.ctm, s.stack, s.current, s.subpaths, s.lineWidth) = saved
            default: break
            }
        }
    }

    private static func run(_ content: CGPDFContentStreamRef, table: CGPDFOperatorTableRef, state: ScanState) {
        if state.tables.isEmpty { state.tables.append(table) }
        let info = Unmanaged.passUnretained(state).toOpaque()
        let scanner = CGPDFScannerCreate(content, table, info)
        CGPDFScannerScan(scanner)
        CGPDFScannerRelease(scanner)
        CGPDFContentStreamRelease(content)
    }
}

extension PageGraphicsScanner.ScanState {
    enum InlineImageStep { case begin, data, end }

    func add(_ point: CGPoint) {
        let transformed = point.applying(ctm)
        if current == nil { current = Subpath(points: [transformed], isRectangle: false) } else { current!.points.append(transformed) }
    }

    func closeSubpath() {
        if let current { subpaths.append(current) }
        current = nil
    }

    func discardPath() { current = nil; subpaths = [] }

    func inlineImage(_ step: InlineImageStep) {
        switch step {
        case .begin, .data:
            if !inlineImagePending { images.append(CGRect(x: 0, y: 0, width: 1, height: 1).applying(ctm).standardized); inlineImagePending = true }
        case .end:
            if !inlineImagePending { images.append(CGRect(x: 0, y: 0, width: 1, height: 1).applying(ctm).standardized) }
            inlineImagePending = false
        }
    }

    /// Classifies the current path: thin rectangles and axis-aligned two-point strokes are rulings, the rest vectors.
    func paint(stroked: Bool) {
        closeSubpath()
        let width = max(lineWidth * (ctm.a.magnitude + ctm.d.magnitude) / 2, 0.5)
        var others: [CGRect] = []
        for subpath in subpaths {
            var bounds = subpath.bounds
            if stroked { bounds = bounds.insetBy(dx: -width / 2, dy: -width / 2) }
            guard bounds.width.isFinite, bounds.height.isFinite else { continue }
            let thin = min(bounds.width, bounds.height), long = max(bounds.width, bounds.height)
            let isLine = subpath.points.count == 2 && (abs(subpath.points[0].x - subpath.points[1].x) < 1 || abs(subpath.points[0].y - subpath.points[1].y) < 1)
            if (subpath.isRectangle || isLine) && thin <= 2.5 && long >= 6 {
                rulings.append(Ruling(bounds: bounds, isHorizontal: bounds.width >= bounds.height))
            } else if long >= 1 {
                others.append(bounds)
            }
        }
        if !others.isEmpty { vectors.append(CGRect.union(others)) }
        subpaths = []
    }
}
