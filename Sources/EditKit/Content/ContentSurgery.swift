import CoreGraphics
import Foundation
import PDFModelKit

// Rewriting a page's operations: the original content is kept inside one marked wrapper (`/SPOriginal BMC q … Q EMC`)
// so edits appended after it start from the page's base graphics state, operations are replaced by index, and new
// blocks are added after everything else (each inside its own q … Q).

enum ContentSurgery {
    static let originalTag = "SPOriginal"

    /// Replaces operations by index (an empty replacement removes one), puts `prepended` before everything (drawn
    /// under the page) and `appended` after the wrapper (drawn over it), wrapping the original content first when it
    /// isn't yet.
    static func rewrite(_ stream: PDFContentStream, replacing replacements: [Int: [PDFContentOperation]], prepending prepended: [PDFContentOperation] = [],
                        appending appended: [PDFContentOperation]) -> PDFContentStream {
        var ops: [PDFContentOperation] = []
        ops.reserveCapacity(stream.operations.count + appended.count + prepended.count + 4)
        for (index, op) in stream.operations.enumerated() {
            if let replacement = replacements[index] { ops.append(contentsOf: replacement) } else { ops.append(op) }
        }
        if let wrapper = wrapperRange(ops) {
            ops.insert(contentsOf: prepended, at: wrapper.lowerBound)
        } else {
            ops = prepended + [PDFContentOperation("BMC", [.name(originalTag)]), PDFContentOperation("q")] + ops
                + [PDFContentOperation("Q"), PDFContentOperation("EMC")]
        }
        ops.append(contentsOf: appended)
        return PDFContentStream(operations: ops)
    }

    /// The wrapper's operations (BMC … EMC) when the content has one; things before it are underlays.
    static func wrapperRange(_ ops: [PDFContentOperation]) -> ClosedRange<Int>? {
        guard let start = ops.firstIndex(where: { $0.operator == "BMC" && $0.operands.first == .name(originalTag) }) else { return nil }
        var depth = 0
        for i in start..<ops.count {
            switch ops[i].operator {
            case "BMC", "BDC": depth += 1
            case "EMC":
                depth -= 1
                if depth == 0 { return start...i }
            default: break
            }
        }
        return start...(ops.count - 1)
    }


    /// `cm` for a matrix.
    static func cm(_ t: CGAffineTransform) -> PDFContentOperation {
        PDFContentOperation("cm", [.number(round(t.a)), .number(round(t.b)), .number(round(t.c)), .number(round(t.d)), .number(round(t.tx)), .number(round(t.ty))])
    }

    static func round(_ v: Double) -> Double { (v * 10_000).rounded() / 10_000 }

    /// The ops of a `TJ` built from kept glyph stretches and the advances of removed ones (so later text stays put).
    /// `pieces` alternate: `.keep(bytes)` writes the bytes, `.skip(textSpaceAdvance)` moves by the removed glyphs' advance.
    enum Piece { case keep(Data); case skip(Double) }

    static func tj(_ pieces: [Piece], fontSize: Double) -> PDFContentOperation {
        var array: [PDFValue] = []
        for piece in pieces {
            switch piece {
            case .keep(let bytes): if !bytes.isEmpty { array.append(.string(bytes)) }
            case .skip(let advance):
                guard fontSize != 0, advance != 0 else { continue }
                let n = -advance * 1000 / fontSize
                if let last = array.last, let previous = last.numberValue { array[array.count - 1] = .number(round(previous + n)) } else { array.append(.number(round(n))) }
            }
        }
        return PDFContentOperation("TJ", [.array(array)])
    }
}
