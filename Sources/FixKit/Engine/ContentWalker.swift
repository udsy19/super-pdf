import CoreGraphics
import Foundation
import PDFModelKit

// Geometry of page content (ISO 32000-2 §8.4, §9.4): walks content-stream operations keeping the current transformation
// matrix, the line width and the text matrix, and hands each operation to a visitor with that state. Make smaller uses
// it for each image's effective resolution, Check for printing for picture resolution and hairlines, the auto-tagger
// for where each text object, image and form starts. `walk(_:visit:)` on a page also enters the form XObjects it draws;
// on a list of operations it stays in that list.

/// The graphics state the walker keeps per operation.
struct ContentState {
    /// User space → page space (the page's default user space).
    var ctm: CGAffineTransform
    /// `w`, in user space.
    var lineWidth: Double = 1
    /// Text space → user space inside BT … ET (Tm × the line matrix moves).
    var textMatrix: CGAffineTransform = .identity
    var lineMatrix: CGAffineTransform = .identity
    var leading: Double = 0

    /// The text line's start in page space (glyph advances are not followed: the first show of a text object starts here).
    var textOrigin: CGPoint { CGPoint.zero.applying(textMatrix.concatenating(ctm)) }

    /// The line width as drawn, in points (the thinner axis, as a printer sees a stroke).
    var drawnLineWidth: Double {
        Double(min(hypot(ctm.a, ctm.b), hypot(ctm.c, ctm.d))) * lineWidth
    }
}

enum ContentWalker {
    /// Calls `visit` for every operation in order with the state *before* the operation takes effect (for `Do` and text
    /// showing that is the state it draws with).
    static func walk(_ operations: [PDFContentOperation], ctm: CGAffineTransform,
                     visit: (_ index: Int, _ operation: PDFContentOperation, _ state: ContentState) -> Void) {
        var state = ContentState(ctm: ctm)
        var stack: [ContentState] = []
        for (index, op) in operations.enumerated() {
            visit(index, op, state)
            let n = op.operands.compactMap(\.numberValue)
            switch op.operator {
            case "q": stack.append(state)
            case "Q": if let last = stack.popLast() { state = last }
            case "cm" where n.count == 6:
                state.ctm = CGAffineTransform(a: n[0], b: n[1], c: n[2], d: n[3], tx: n[4], ty: n[5]).concatenating(state.ctm)
            case "w" where n.count == 1: state.lineWidth = n[0]
            case "BT":
                state.textMatrix = .identity
                state.lineMatrix = .identity
            case "TL" where n.count == 1: state.leading = n[0]
            case "Tm" where n.count == 6:
                state.lineMatrix = CGAffineTransform(a: n[0], b: n[1], c: n[2], d: n[3], tx: n[4], ty: n[5])
                state.textMatrix = state.lineMatrix
            case "Td" where n.count == 2:
                state.lineMatrix = CGAffineTransform(translationX: n[0], y: n[1]).concatenating(state.lineMatrix)
                state.textMatrix = state.lineMatrix
            case "TD" where n.count == 2:
                state.leading = -n[1]
                state.lineMatrix = CGAffineTransform(translationX: n[0], y: n[1]).concatenating(state.lineMatrix)
                state.textMatrix = state.lineMatrix
            case "T*", "'", "\"":
                state.lineMatrix = CGAffineTransform(translationX: 0, y: -state.leading).concatenating(state.lineMatrix)
                state.textMatrix = state.lineMatrix
            default: break
            }
        }
    }

    /// The page-space rectangle the unit square fills under `ctm` (images and the bounding box of forms).
    static func unitSquare(_ ctm: CGAffineTransform) -> CGRect {
        CGRect(x: 0, y: 0, width: 1, height: 1).applying(ctm)
    }

    /// The operations of a page, or nil when its content can't be read.
    static func operations(of page: PDFPage) -> [PDFContentOperation]? {
        guard let stream = try? page.contentStream() else { return nil }
        return stream.operations
    }

    /// The operations of a form XObject (decoded), or nil when it isn't one or can't be read.
    static func operations(ofForm form: PDFObject) -> [PDFContentOperation]? {
        guard form.type == .stream, form["Subtype"]?.name == "Form", let data = try? form.streamData() else { return nil }
        return PDFContentStream(parsing: data).operations
    }

    /// A form's /Matrix (identity when absent).
    static func matrix(ofForm form: PDFObject) -> CGAffineTransform {
        form["Matrix"]?.value.matrixValue ?? .identity
    }
}

// MARK: - Through form XObjects

/// Where an operation runs: the page itself or a form XObject drawn on it.
struct ContentScope {
    /// The resources names resolve in.
    var resources: PDFObject?
    /// The form XObject whose stream holds the operation; nil for the page's own content.
    var form: PDFObject?
}

extension ContentWalker {
    /// Walks a page's content and, depth first at each `Do`, the form XObjects it draws (8 levels, each form once per
    /// path), with page-space state throughout.
    static func walk(_ page: PDFPage, visit: (_ operation: PDFContentOperation, _ state: ContentState, _ scope: ContentScope) -> Void) {
        guard let operations = operations(of: page) else { return }
        var visiting: Set<Int> = []
        walk(operations, scope: ContentScope(resources: page.resources), ctm: .identity, depth: 0, visiting: &visiting, visit: visit)
    }

    private static func walk(_ list: [PDFContentOperation], scope: ContentScope, ctm: CGAffineTransform, depth: Int,
                             visiting: inout Set<Int>, visit: (PDFContentOperation, ContentState, ContentScope) -> Void) {
        var forms: [(PDFObject, CGAffineTransform)] = []
        walk(list, ctm: ctm) { _, op, state in
            visit(op, state, scope)
            if op.operator == "Do", let name = op.operands.first?.nameValue, let x = scope.resources?["XObject"]?[name],
               x.type == .stream, x["Subtype"]?.name == "Form" {
                forms.append((x, matrix(ofForm: x).concatenating(state.ctm)))
            }
        }
        guard depth < 8 else { return }
        for (form, formCTM) in forms {
            if let id = form.objectID { guard visiting.insert(id).inserted else { continue } }
            if let inner = ContentWalker.operations(ofForm: form) {
                walk(inner, scope: ContentScope(resources: form["Resources"] ?? scope.resources, form: form), ctm: formCTM, depth: depth + 1,
                     visiting: &visiting, visit: visit)
            }
            if let id = form.objectID { visiting.remove(id) }
        }
    }
}

// MARK: - Images as drawn

/// Where an image XObject is drawn on a page.
struct ImageUse {
    var object: PDFObject
    var objectID: Int?
    /// The drawn rectangle in page space.
    var rect: CGRect
    /// Pixels per inch along the image's denser axis.
    var resolution: Double
}

enum ImageUses {
    /// Every draw of an image XObject on the page, through its form XObjects, in content order.
    static func on(_ page: PDFPage) -> [ImageUse] {
        var uses: [ImageUse] = []
        ContentWalker.walk(page) { op, state, scope in
            guard op.operator == "Do", let name = op.operands.first?.nameValue, let x = scope.resources?["XObject"]?[name],
                  x.type == .stream, x["Subtype"]?.name == "Image" else { return }
            let width = Double(x["Width"]?.int ?? 0), height = Double(x["Height"]?.int ?? 0)
            let drawnWidth = Double(hypot(state.ctm.a, state.ctm.b)), drawnHeight = Double(hypot(state.ctm.c, state.ctm.d))
            guard drawnWidth > 0.01, drawnHeight > 0.01 else { return }
            let resolution = max(width / (drawnWidth / 72), height / (drawnHeight / 72))
            uses.append(ImageUse(object: x, objectID: x.objectID, rect: ContentWalker.unitSquare(state.ctm), resolution: resolution))
        }
        return uses
    }
}
