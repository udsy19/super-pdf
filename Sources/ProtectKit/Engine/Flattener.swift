import CoreGraphics
import Foundation
import PDFModelKit
import RenderKit
import SuperPDFCore

// Lock in notes & fields (features #70). Each annotation's normal appearance stream is drawn into the page content
// where the annotation sits (ISO 32000-2 §12.5.5: the appearance's BBox through its Matrix is fitted to /Rect), then
// the annotation goes; flattened form fields leave the AcroForm. Text fields that rely on the viewer to draw their
// value (/NeedAppearances, no appearance stream) get a plain one first. "Make pages into pictures" then rasterizes
// every page with Quartz (features #58).
//
// ARCHITECTURE open question 2 (WP12's decision): PDFKit's `PDFDocumentBurnInAnnotationsOption` re-renders the whole
// document through Quartz and needs PDFKit on the main actor; this flattener works on the objects off the main actor,
// keeps everything else in the file as it is, and handles every widget kind that has an appearance stream.

enum Flattener {
    static func flatten(_ source: PDFSource, options: FlattenOptions) throws -> Data {
        let model = try PDFModel(source)
        try ProtectionRules.requireChanges(model)
        try flatten(model, annotations: options.annotations, formFields: options.formFields)
        let data = try model.data(options: PDFWriteOptions(encryption: .preserve))
        guard let dpi = options.rasterizeDPI else { return data }
        let scratch = FileManager.default.temporaryDirectory.appendingPathComponent("superpdf-flatten-\(UUID().uuidString).pdf")
        defer { try? FileManager.default.removeItem(at: scratch) }
        try PDFOutput.printAsImage(.data(data, password: source.password), dpi: dpi, to: scratch)
        return try Data(contentsOf: scratch)
    }

    /// Burns annotations (markup, not links) and/or form widgets into their pages; returns how many were drawn.
    @discardableResult
    static func flatten(_ model: PDFModel, annotations: Bool, formFields: Bool) throws -> Int {
        guard annotations || formFields else { return 0 }
        if formFields { generateMissingAppearances(model) }
        var drawn = 0
        for page in model.pages {
            guard let annots = page.object["Annots"] else { continue }
            var placements: [[PDFContentOperation]] = []
            var removed: Set<Int> = []
            for i in (0..<annots.count).reversed() {
                guard let annot = annots[i] else { continue }
                let subtype = annot["Subtype"]?.name ?? ""
                let isWidget = subtype == "Widget"
                guard subtype != "Link", isWidget ? formFields : annotations else { continue }
                if subtype != "Popup", let placement = place(annot, on: page) {
                    placements.append(placement)
                    drawn += 1
                }
                if let id = annot.objectID { removed.insert(id) }
                annots.removeItem(at: i)
            }
            // Pop-ups belong to the notes that went.
            for i in (0..<annots.count).reversed() {
                if let parent = annots[i]?["Parent"]?.objectID, removed.contains(parent) { annots.removeItem(at: i) }
            }
            if annots.count == 0 { page.object.remove("Annots") }
            if !placements.isEmpty {
                // Collected last to first; drawn in /Annots order, as viewers stack them.
                let ops = placements.reversed().flatMap { $0 }
                page.addContent(Data("q\n".utf8), prepend: true)
                page.addContent(Data("\nQ\n".utf8) + PDFContentStream(operations: ops).serialized())
            }
        }
        // Every widget is burnt in, so the fields have nothing left to show.
        if formFields { model.root.remove("AcroForm") }
        return drawn
    }

    /// The operations that draw an annotation's normal appearance where it sits; nil when it shows nothing.
    private static func place(_ annot: PDFObject, on page: PDFPage) -> [PDFContentOperation]? {
        let flags = annot["F"]?.int ?? 0
        guard flags & 2 == 0, flags & 32 == 0, let rect = annot["Rect"]?.rect, rect.width > 0, rect.height > 0 else { return nil }
        guard var appearance = annot["AP"]?["N"] else { return nil }
        if appearance.type == .dictionary {
            guard let state = annot["AS"]?.name, let chosen = appearance[state], chosen.type == .stream else { return nil }
            appearance = chosen
        }
        guard appearance.type == .stream else { return nil }
        if appearance["Subtype"]?.name != "Form" { appearance.set("Subtype", .name("Form")) }
        if appearance["Type"] == nil { appearance.set("Type", .name("XObject")) }
        let matrix = appearance["Matrix"]?.value.matrixValue ?? .identity
        let box = (appearance["BBox"]?.rect ?? .zero).applying(matrix)
        guard box.width > 0, box.height > 0 else { return nil }
        let fit = CGAffineTransform(a: rect.width / box.width, b: 0, c: 0, d: rect.height / box.height,
                                    tx: rect.minX - box.minX * rect.width / box.width, ty: rect.minY - box.minY * rect.height / box.height)
        let name = page.addResource(appearance, category: "XObject", prefix: "Fl")
        return [PDFContentOperation("q"), PDFContentOperation("cm", PDFValue.matrix(fit).arrayValue!),
                PDFContentOperation("Do", [.name(name)]), PDFContentOperation("Q")]
    }

    /// Plain appearances for text fields that have a value but no appearance stream (/NeedAppearances files).
    private static func generateMissingAppearances(_ model: PDFModel) {
        guard let form = model.acroForm else { return }
        let resources = form["DR"]?.value ?? .dictionary([:])
        for field in model.formFields() where field.type == "Tx" {
            guard let value = field.value?.textValue, !value.isEmpty else { continue }
            let (fontName, size) = defaultAppearance(field.defaultAppearance)
            for widget in field.widgets where widget.object["AP"]?["N"] == nil {
                let rect = widget.rect
                guard rect.width > 0, rect.height > 0 else { continue }
                let fontSize = size > 0 ? size : min(rect.height * 0.7, 12)
                let text = Data(value.map { String($0).data(using: .windowsCP1252)?.first ?? UInt8(ascii: "?") })
                var ops: [PDFContentOperation] = [PDFContentOperation("BMC", [.name("Tx")]), PDFContentOperation("q"), PDFContentOperation("BT")]
                if let fontName { ops.append(PDFContentOperation("Tf", [.name(fontName), .number(fontSize)])) }
                ops += [PDFContentOperation("g", [.integer(0)]),
                        PDFContentOperation("Td", [.integer(2), .number(max((rect.height - fontSize) / 2 + fontSize * 0.22, 1))]),
                        PDFContentOperation("Tj", [.string(text)]), PDFContentOperation("ET"), PDFContentOperation("Q"),
                        PDFContentOperation("EMC")]
                let stream = model.makeStream(["Type": .name("XObject"), "Subtype": .name("Form"),
                                               "BBox": .rect(CGRect(origin: .zero, size: rect.size)), "Resources": resources],
                                              data: PDFContentStream(operations: ops).serialized())
                widget.object.set("AP", .dictionary(["N": stream.reference!]))
            }
        }
    }

    /// The font resource name and size of a /DA string ("/Helv 0 Tf 0 g").
    private static func defaultAppearance(_ da: String?) -> (String?, Double) {
        guard let da else { return (nil, 0) }
        let ops = PDFContentStream(parsing: Data(da.utf8)).operations
        guard let tf = ops.last(where: { $0.operator == "Tf" }) else { return (nil, 0) }
        return (tf.operands.first?.nameValue, tf.operands.last?.numberValue ?? 0)
    }
}
