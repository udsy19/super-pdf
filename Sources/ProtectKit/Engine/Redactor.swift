import CoreGraphics
import Foundation
import PDFModelKit
import SuperPDFCore

// Black out, applied (features #69): on every page with marks the content under them leaves the file (glyphs, picture
// pixels, path pieces: `ContentRewriter`), annotations and form fields over them go, strings elsewhere in the file
// that repeat the blacked-out words (bookmark titles, tags' alternate text, field values, metadata) are overwritten,
// the boxes are drawn in their colour with the optional words over them, and the file is rewritten whole so nothing
// unreferenced or from an earlier revision survives. Runs off the main actor on a private model.

enum Redactor {
    /// The new file's bytes. `phrases` are the words being blacked out (found matches), scrubbed from strings outside
    /// the page content too.
    static func apply(_ marks: [RedactionMark], to source: PDFSource, options: RedactionOptions, phrases: [String],
                      progress: ToolProgress) throws -> Data {
        let model = try PDFModel(source)
        try ProtectionRules.requireChanges(model)
        let byPage = Dictionary(grouping: marks, by: \.page)
        let pages = byPage.keys.sorted()
        let fill = RGB(hex: options.fillColor)
        for (done, index) in pages.enumerated() {
            try Task.checkCancellation()
            guard let page = model.page(at: index) else { continue }
            let areas = byPage[index]!.map(\.rect.standardized).filter { $0.width > 0 && $0.height > 0 }
            guard !areas.isEmpty else { continue }
            let boxes = try boxOperations(areas, fill: fill, words: options.overlayText, page: page)
            let rewriter = ContentRewriter(model: model, rules: ContentRules(areas: { _ in areas }, cutsPartially: true))
            try rewriter.rewrite(page: page, appending: boxes)
            removeAnnotations(on: page, over: areas, in: model)
            progress.report(completed: done + 1, of: pages.count, page: index)
        }
        StringScrubber.scrub(phrases, in: model)
        if options.removeHiddenInformation {
            try Sanitizer.remove(Sanitizer.defaultKinds, from: model)
        }
        return try model.data(options: PDFWriteOptions(encryption: .preserve))
    }

    // MARK: - Boxes

    /// The boxes in their colour, with the words centred in each when given (Helvetica, white on dark fills).
    private static func boxOperations(_ areas: [CGRect], fill: RGB, words: String?, page: PDFPage) throws -> [PDFContentOperation] {
        var ops: [PDFContentOperation] = [PDFContentOperation("rg", [.number(fill.r), .number(fill.g), .number(fill.b)])]
        for area in areas {
            ops.append(PDFContentOperation("re", [.number(area.minX), .number(area.minY), .number(area.width), .number(area.height)]))
        }
        ops.append(PDFContentOperation("f"))
        guard let words = words?.trimmingCharacters(in: .whitespaces), !words.isEmpty else { return ops }
        let font = page.model.makeIndirect(.dictionary(["Type": .name("Font"), "Subtype": .name("Type1"), "BaseFont": .name("Helvetica"),
                                                         "Encoding": .name("WinAnsiEncoding")]))
        let name = page.addResource(font, category: "Font", prefix: "FR")
        let bytes = Data(words.map { String($0).data(using: .windowsCP1252)?.first ?? UInt8(ascii: "?") })
        let widths = StandardFonts.widths(for: "Helvetica")
        let unitWidth = bytes.reduce(0.0) { $0 + (widths[UInt32($1)] ?? 0.5) }
        let ink = fill.luminance < 0.5 ? 1.0 : 0.0
        for area in areas {
            let size = min(area.height * 0.6, (area.width - 4) / max(unitWidth, 0.1), 14)
            guard size >= 3 else { continue }
            let x = area.midX - unitWidth * size / 2, y = area.midY - size * 0.35
            ops += [PDFContentOperation("BT"), PDFContentOperation("Tf", [.name(name), .number(size)]),
                    PDFContentOperation("g", [.number(ink)]), PDFContentOperation("Td", [.number(x), .number(y)]),
                    PDFContentOperation("Tj", [.string(bytes)]), PDFContentOperation("ET")]
        }
        return ops
    }

    // MARK: - Annotations

    /// Annotations over a mark go (their appearance could show what is under it); a widget takes its field along.
    private static func removeAnnotations(on page: PDFPage, over areas: [CGRect], in model: PDFModel) {
        guard let annots = page.object["Annots"] else { return }
        var removedIDs: Set<Int> = []
        var fieldNames: Set<String> = []
        let fields = model.formFields()
        for i in (0..<annots.count).reversed() {
            guard let annot = annots[i], let rect = annot["Rect"]?.rect else { continue }
            let overlap = areas.contains { !$0.intersection(rect).isNull && !$0.intersection(rect).isEmpty }
            guard overlap else { continue }
            if let id = annot.objectID { removedIDs.insert(id) }
            if annot["Subtype"]?.name == "Widget",
               let field = fields.first(where: { $0.widgets.contains { $0.object.objectID != nil && $0.object.objectID == annot.objectID } }) {
                fieldNames.insert(field.name)
            }
            annots.removeItem(at: i)
        }
        // Pop-ups of removed annotations go with them.
        for i in (0..<annots.count).reversed() {
            guard let parent = annots[i]?["Parent"]?.objectID, removedIDs.contains(parent) else { continue }
            annots.removeItem(at: i)
        }
        for name in fieldNames { model.removeField(named: name) }
    }
}

/// A "#RRGGBB" colour as PDF components.
struct RGB {
    var r: Double, g: Double, b: Double

    init(hex: String) {
        let digits = hex.trimmingCharacters(in: CharacterSet(charactersIn: "# "))
        let value = UInt32(digits, radix: 16) ?? 0
        r = Double((value >> 16) & 0xFF) / 255; g = Double((value >> 8) & 0xFF) / 255; b = Double(value & 0xFF) / 255
    }

    var luminance: Double { 0.2126 * r + 0.7152 * g + 0.0722 * b }
}

/// Overwrites blacked-out words wherever the file repeats them in strings (bookmark titles, field values, alternate
/// text, document info) and in the XMP metadata.
enum StringScrubber {
    static func scrub(_ phrases: [String], in model: PDFModel) {
        let needles = Set(phrases.map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { $0.count >= 3 })
        guard !needles.isEmpty else { return }
        let encryptID = model.trailer["Encrypt"]?.objectID
        for object in ObjectWalk.objects(of: model) where encryptID == nil || object.objectID != encryptID {
            switch object.type {
            case .dictionary, .stream:
                for key in object.keys {
                    guard let value = object[key]?.value, !(object[key]?.isIndirect ?? false) else { continue }
                    if let scrubbed = scrub(value, needles) { object.set(key, scrubbed) }
                }
            case .array:
                for (i, item) in object.items.enumerated() where !item.isIndirect {
                    if let scrubbed = scrub(item.value, needles) { object.replaceItem(at: i, with: scrubbed) }
                }
            default:
                break
            }
        }
        if let metadata = model.root["Metadata"], metadata.type == .stream, let data = try? metadata.streamData(),
           var text = String(data: data, encoding: .utf8) {
            var changed = false
            for needle in needles where text.range(of: needle, options: .caseInsensitive) != nil {
                text = text.replacingOccurrences(of: needle, with: String(repeating: "X", count: needle.count), options: .caseInsensitive)
                changed = true
            }
            if changed { metadata.setStreamData(Data(text.utf8)) }
        }
    }

    /// The value with every string containing a needle overwritten; nil when nothing changed.
    private static func scrub(_ value: PDFValue, _ needles: Set<String>) -> PDFValue? {
        switch value {
        case .string(let bytes):
            var text = PDFText.decode(bytes)
            var changed = false
            for needle in needles where text.range(of: needle, options: .caseInsensitive) != nil {
                text = text.replacingOccurrences(of: needle, with: String(repeating: "X", count: needle.count), options: .caseInsensitive)
                changed = true
            }
            return changed ? .text(text) : nil
        case .array(let items):
            var changed = false
            let next = items.map { item -> PDFValue in
                if let s = scrub(item, needles) { changed = true; return s }
                return item
            }
            return changed ? .array(next) : nil
        case .dictionary(let dict):
            var changed = false
            var next = dict
            for (key, item) in dict { if let s = scrub(item, needles) { next[key] = s; changed = true } }
            return changed ? .dictionary(next) : nil
        default:
            return nil
        }
    }
}

/// Every indirect object of a model, by number (object and cross-reference streams excluded).
enum ObjectWalk {
    static func objects(of model: PDFModel) -> [PDFObject] {
        let size = model.trailer["Size"]?.int ?? 0
        var result: [PDFObject] = []
        for id in 1..<max(size, 1) {
            let object = model.object(id: id)
            guard !object.isNull else { continue }
            if object.type == .stream, ["ObjStm", "XRef"].contains(object["Type"]?.name ?? "") { continue }
            result.append(object)
        }
        return result
    }

    /// Object numbers reachable from the trailer.
    static func reachable(in model: PDFModel) -> Set<Int> {
        var seen: Set<Int> = []
        var queue: [PDFValue] = [model.trailer.value]
        while let value = queue.popLast() {
            switch value {
            case .reference(let id, let generation):
                guard seen.insert(id).inserted else { continue }
                queue.append(model.object(id: id, generation: generation).value)
            case .array(let items): queue += items
            case .dictionary(let dict): queue += dict.values
            default: break
            }
        }
        return seen
    }
}

/// Permission checks shared by the tools that rewrite a file (features #87, #90: we honour owner restrictions and
/// never crack passwords).
enum ProtectionRules {
    /// Changing the content needs the owner password when the file forbids changes.
    static func requireChanges(_ model: PDFModel) throws {
        guard !model.hasOwnerAccess else { return }
        let p = model.permissions
        if !p.pageChanges || !p.commenting || !p.fillingFormsAndSigning {
            throw ToolError(Strings.Errors.ownerRestricted(.pageChanges), action: ProtectStrings.removePasswordOption)
        }
    }
}
