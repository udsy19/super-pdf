import AppKit
import CoreGraphics
import Foundation
import PDFModelKit
import SuperPDFCore

// Writes decorations into pages as tagged form XObjects (features #64–#67: "ours are tagged so they can be replaced"):
// each item becomes a form drawn inside an Artifact span that names its kind, so the decoration can be listed,
// replaced and removed later by tag. Backgrounds go under the page's content, everything else over it.

enum DecorationWriter {
    /// The key in the artifact's property list that names the decoration kind.
    static let kindKey = "SPKind"
    /// A page key recording the content scale "shrink page to make room" applied.
    static let shrinkKey = "SPShrink"

    /// Stamps `decoration` on `pages` (0-based) of `model`.
    static func apply(_ decoration: Decoration, to pages: [Int], in model: PDFModel, context: DecorationContext) throws {
        var pictureForms: [URL: PDFObject] = [:]
        var layerGroup: PDFObject?
        for index in pages {
            guard let page = model.page(at: index) else { continue }
            if case .headerFooter(let header) = decoration, header.shrinkPage { shrink(page, margins: header.margins, fontSize: header.style.fontSize) }
            let items = DecorationLayout.items(for: decoration, pageIndex: index, pageSize: page.displaySize, context: context)
            var over: [PDFContentOperation] = [], under: [PDFContentOperation] = []
            for item in items {
                let form: PDFObject
                switch item.content {
                case .picture(let picture):
                    let key = pictureURL(picture)
                    if let existing = pictureForms[key] { form = existing } else {
                        form = try pictureForm(picture, in: model)
                        pictureForms[key] = form
                    }
                default:
                    form = try itemForm(for: item, in: model)
                }
                var layerName: String?
                if item.visibility != .always {
                    let group = try layerGroup ?? makeLayerGroup(item.visibility, in: model)
                    layerGroup = group
                    form.set("OC", group)
                    layerName = page.addResource(group, category: "Properties", prefix: "SPOc")
                }
                let name = page.addResource(form, category: "XObject", prefix: "SPDx")
                var ops: [PDFContentOperation] = [PDFContentOperation("q")]
                if item.opacity < 1 {
                    let state = model.makeIndirect(.dictionary(["Type": .name("ExtGState"), "ca": .number(item.opacity), "CA": .number(item.opacity)]))
                    ops.append(PDFContentOperation("gs", [.name(page.addResource(state, category: "ExtGState", prefix: "SPGs"))]))
                }
                // Frame space (the form's BBox) → shown page → page space.
                let bbox = form["BBox"]?.rect ?? item.frame
                let fit = CGAffineTransform(a: item.frame.width / max(bbox.width, 0.001), b: 0, c: 0, d: item.frame.height / max(bbox.height, 0.001), tx: 0, ty: 0)
                let toFrame = CGAffineTransform(translationX: -bbox.minX, y: -bbox.minY).concatenating(fit).concatenating(CGAffineTransform(translationX: item.frame.minX, y: item.frame.minY))
                let placement = toFrame.concatenating(DecorationLayout.placement(of: item)).concatenating(page.displayTransform.inverted())
                ops.append(ContentSurgery.cm(placement))
                ops.append(PDFContentOperation("Do", [.name(name)]))
                ops.append(PDFContentOperation("Q"))
                // Viewers apply a layer to marked content more reliably than to an XObject's /OC, so both are set.
                if let layerName { ops = PDFContentStream.markedContent(ops, tag: "OC", properties: .name(layerName)) }
                let tagged = PDFContentStream.markedContent(ops, tag: "Artifact", properties: .dictionary([
                    "Type": .name("Pagination"), "Subtype": .name(item.artifactSubtype), kindKey: .name(item.kind.rawValue),
                ]))
                if item.layer == .behind { under.append(contentsOf: tagged) } else { over.append(contentsOf: tagged) }
            }
            let stream = try page.contentStream()
            page.setContentStream(ContentSurgery.rewrite(stream, replacing: [:], prepending: under, appending: over))
        }
    }

    /// Removes every decoration of `kind` from the model; returns how many spans went.
    @discardableResult
    static func remove(_ kind: DecorationKind, from model: PDFModel) throws -> Int {
        var removed = 0
        for page in model.pages {
            var stream = try page.contentStream()
            let spans = stream.markedContent.filter { $0.tag == "Artifact" && $0.properties?[kindKey] == .name(kind.rawValue) }
            guard !spans.isEmpty else { continue }
            // Drop the forms the spans used from the page's resources.
            let names = spans.flatMap { span in stream.operations[span.range].filter { $0.operator == "Do" }.compactMap { $0.operands.first?.nameValue } }
            removed += stream.removeMarkedContent { $0.tag == "Artifact" && $0.properties?[kindKey] == .name(kind.rawValue) }
            page.setContentStream(stream)
            if let xobjects = page.object["Resources"]?["XObject"] { for name in names { xobjects.remove(name) } }
            if kind == .headerFooter { unshrink(page) }
        }
        return removed
    }

    /// The kinds of decoration the model carries (ours).
    static func kinds(in model: PDFModel) -> [DecorationKind] {
        var found: Set<DecorationKind> = []
        for page in model.pages {
            guard let stream = try? page.contentStream() else { continue }
            for span in stream.markedContent where span.tag == "Artifact" {
                if let name = span.properties?[kindKey]?.nameValue, let kind = DecorationKind(rawValue: name) { found.insert(kind) }
            }
            if found.count == DecorationKind.allCases.count { break }
        }
        return DecorationKind.allCases.filter(found.contains)
    }

    // MARK: Forms

    /// A form XObject drawing a text or fill item in its frame's space.
    static func itemForm(for item: DecorationItem, in model: PDFModel) throws -> PDFObject {
        let frame = CGRect(origin: .zero, size: item.frame.size)
        let form = model.makeStream(["Type": .name("XObject"), "Subtype": .name("Form"), "BBox": .rect(frame)], data: Data())
        var ops: [PDFContentOperation] = []
        switch item.content {
        case .text(let text, let fontName, let fontSize, let color):
            let nsFont = DecorationLayout.nsFont(fontName, size: fontSize)
            let (font, resource) = TextRewriter.writableFont(nsFont, on: FormResources(form: form))
            var shown = text
            if !font.canShow(text) {
                // Characters outside the font: fall back to a system font that has them.
                let fallback = NSFont.systemFont(ofSize: fontSize)
                let (f2, r2) = FontEmbedder.embeddedFont(fallback, on: FormResources(form: form))
                if f2.canShow(text) { return try textForm(frame: frame, font: f2, resource: r2, fontSize: fontSize, color: color, text: text, form: form) }
                shown = String(text.unicodeScalars.filter { font.canShow(String($0)) }.map(Character.init))
            }
            return try textForm(frame: frame, font: font, resource: resource, fontSize: fontSize, color: color, text: shown, form: form)
        case .fill(let hex):
            ops.append(contentsOf: BlockStyle.colorOps(for: hex))
            ops.append(PDFContentOperation("re", [.integer(0), .integer(0), .number(frame.width), .number(frame.height)]))
            ops.append(PDFContentOperation("f"))
        case .picture:
            break
        }
        form.setStreamData(PDFContentStream(operations: ops).serialized())
        return form
    }

    private static func textForm(frame: CGRect, font: WritableFont, resource: String, fontSize: Double, color: String, text: String, form: PDFObject) throws -> PDFObject {
        guard let bytes = font.encode(text) else { throw TextRewriteError.cannotShowText }
        font.finish()
        let descent = -font.descent / 1000 * fontSize
        var ops: [PDFContentOperation] = BlockStyle.colorOps(for: color)
        ops.append(PDFContentOperation("BT"))
        ops.append(PDFContentOperation("Tf", [.name(resource), .number(ContentSurgery.round(fontSize))]))
        ops.append(PDFContentOperation("Tm", [.integer(1), .integer(0), .integer(0), .integer(1), .integer(0), .number(ContentSurgery.round(descent))]))
        ops.append(PDFContentOperation("Tj", [.string(bytes)]))
        ops.append(PDFContentOperation("ET"))
        form.setStreamData(PDFContentStream(operations: ops).serialized())
        return form
    }

    /// A form drawing a picture: an image XObject in a unit box, or the imported PDF page.
    static func pictureForm(_ picture: DecorationPicture, in model: PDFModel) throws -> PDFObject {
        switch picture {
        case .pdfPage(let source, _, _):
            guard let page = source.page(at: 0) else { throw ImageEditError.unreadableImage }
            return try model.formXObject(from: page)
        case .image(let image, let file):
            let form = model.makeStream(["Type": .name("XObject"), "Subtype": .name("Form"), "BBox": .rect(CGRect(x: 0, y: 0, width: 1, height: 1))], data: Data())
            let stream = model.makeStream(["Type": .name("XObject"), "Subtype": .name("Image")], data: Data())
            let decoded = ImageEditor.decode(file) ?? ImageEditor.Decoded(image: image, jpeg: nil)
            try ImageEditor.write(decoded, into: stream, model: model)
            let name = FormResources(form: form).addResource(stream, category: "XObject", prefix: "Im")
            form.setStreamData(PDFContentStream(operations: [PDFContentOperation("Do", [.name(name)])]).serialized())
            return form
        }
    }

    private static func pictureURL(_ picture: DecorationPicture) -> URL {
        switch picture {
        case .image(_, let file), .pdfPage(_, _, let file): file
        }
    }

    // MARK: Print-only / screen-only (optional content, features #66, #71)

    /// An optional content group that shows only when printing or only on screen, registered in the catalog.
    static func makeLayerGroup(_ visibility: Watermark.Visibility, in model: PDFModel) throws -> PDFObject {
        let printOnly = visibility == .printOnly
        let group = model.makeIndirect(.dictionary([
            "Type": .name("OCG"),
            "Name": .text(printOnly ? "Watermark (print only)" : "Watermark (screen only)"),
            "Usage": .dictionary([
                "Print": .dictionary(["PrintState": .name(printOnly ? "ON" : "OFF")]),
                "View": .dictionary(["ViewState": .name(printOnly ? "OFF" : "ON")]),
            ]),
        ]))
        let properties = model.root["OCProperties"] ?? {
            model.root.set("OCProperties", model.makeIndirect(.dictionary(["OCGs": .array([]), "D": .dictionary(["Order": .array([])])])))
            return model.root["OCProperties"]!
        }()
        properties.array("OCGs").append(group)
        let defaults = properties.dictionary("D")
        defaults.array("Order").append(group)
        if printOnly { defaults.array("OFF").append(group) } else { defaults.array("ON").append(group) }
        // Usage application: viewers apply the Print/View usage when the event happens.
        let usage = defaults.array("AS")
        for event in ["View", "Print"] {
            let app = model.make(.dictionary(["Event": .name(event), "Category": .array([.name(event)])]))
            let groups = model.make(.array([]))
            groups.append(group)
            app.set("OCGs", groups)
            usage.append(app)
        }
        return group
    }

    // MARK: Shrink page to make room (features #64)

    /// Scales the page's content down so a header and a footer fit outside it; once per page.
    static func shrink(_ page: PDFPage, margins: Double, fontSize: Double) {
        guard page.object[shrinkKey] == nil else { return }
        let size = page.displaySize
        let band = margins + fontSize * 1.6
        let scale = max(0.5, (size.height - 2 * band) / size.height)
        guard scale < 0.999 else { return }
        let display = page.displayTransform
        let about = CGAffineTransform(translationX: size.width / 2, y: size.height / 2).scaledBy(x: scale, y: scale).translatedBy(x: -size.width / 2, y: -size.height / 2)
        let matrix = display.concatenating(about).concatenating(display.inverted())
        let stream = (try? page.contentStream()) ?? PDFContentStream()
        let wrapped = [PDFContentOperation("q"), ContentSurgery.cm(matrix)] + stream.operations + [PDFContentOperation("Q")]
        page.setContentStream(PDFContentStream(operations: wrapped))
        page.object.set(shrinkKey, .number(scale))
        // Annotations keep their place on the page (they sit in the margins or move with the viewer); only the drawn
        // content shrinks.
    }

    /// Undoes `shrink` when the content still starts with its wrapper.
    static func unshrink(_ page: PDFPage) {
        guard page.object[shrinkKey] != nil, var stream = try? page.contentStream() else { return }
        if stream.operations.count >= 3, stream.operations[0].operator == "q", stream.operations[1].operator == "cm", stream.operations.last?.operator == "Q" {
            stream.operations.removeLast()
            stream.operations.removeFirst(2)
            page.setContentStream(stream)
        }
        page.object.remove(shrinkKey)
    }
}
