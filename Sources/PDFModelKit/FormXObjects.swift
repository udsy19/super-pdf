import CoreGraphics
import Foundation

// Overlay and underlay (features §3.1): a page of any PDF becomes a form XObject that is drawn over or under another
// page's content, optionally inside a marked-content span so it can be found again (watermarks, backgrounds, stamps,
// headers and footers are tagged this way and removed or updated by tag).

/// Over or under the page's existing content.
public enum PDFPlacementLayer: Sendable { case over, under }

/// The marked-content wrapper of a placement: BDC with `properties` (an inline dictionary), else BMC.
public struct PDFMarkedContentTag: Hashable, Sendable {
    public var tag: String
    public var properties: PDFValue?

    public init(_ tag: String, properties: PDFValue? = nil) { self.tag = tag; self.properties = properties }

    /// A pagination artifact (ISO 32000-2 §14.8.2.2.2), e.g. subtype "Watermark", "Header", "Footer", "Background".
    public static func artifact(subtype: String) -> PDFMarkedContentTag {
        PDFMarkedContentTag("Artifact", properties: .dictionary(["Type": .name("Pagination"), "Subtype": .name(subtype)]))
    }
}

extension PDFModel {
    /// A form XObject in this model that draws `page` (of this or another model) as it is shown: its crop box,
    /// upright after /Rotate. A page of another model is built there and imported with what it uses.
    public func formXObject(from page: PDFPage) throws -> PDFObject {
        let source = page.model
        let crop = page.box(.crop)
        var dict: [String: PDFValue] = [
            "Type": .name("XObject"),
            "Subtype": .name("Form"),
            "BBox": .rect(crop),
            "Matrix": .matrix(page.displayTransform),
        ]
        if let group = page.object["Group"] { dict["Group"] = group.reference ?? group.value }
        let xobject = source.makeStream(dict, data: try page.contentData())
        // A direct resource dictionary is copied, so later edits to either side stay apart.
        if let resources = page.resources, resources.isIndirect { xobject.set("Resources", resources) } else {
            xobject.set("Resources", page.resources?.value ?? .dictionary([:]))
        }
        return importObject(xobject)
    }

    /// The form's drawn bounds: its BBox through its Matrix.
    public func formBounds(_ xobject: PDFObject) -> CGRect {
        let bbox = xobject["BBox"]?.rect ?? .zero
        let matrix = xobject["Matrix"]?.value.matrixValue ?? .identity
        return bbox.applying(matrix)
    }

    /// Draws a form XObject on `page` so its bounds fill `rect` (page space), keeping its aspect ratio (centred) unless
    /// `keepAspectRatio` is off. Returns the XObject's resource name.
    @discardableResult
    public func place(_ xobject: PDFObject, on page: PDFPage, in rect: CGRect, keepAspectRatio: Bool = true,
                      layer: PDFPlacementLayer = .over, tag: PDFMarkedContentTag? = nil) throws -> String {
        let bounds = formBounds(xobject)
        guard bounds.width > 0, bounds.height > 0 else { throw PDFModelError.invalidOperation("empty form XObject") }
        var sx = rect.width / bounds.width, sy = rect.height / bounds.height
        if keepAspectRatio { sx = min(sx, sy); sy = sx }
        let tx = rect.midX - (bounds.midX * sx), ty = rect.midY - (bounds.midY * sy)
        return try place(xobject, on: page, transform: CGAffineTransform(a: sx, b: 0, c: 0, d: sy, tx: tx, ty: ty), layer: layer, tag: tag)
    }

    /// Draws a form XObject on `page` with `transform` (form space after its Matrix → page space). Returns its
    /// resource name.
    @discardableResult
    public func place(_ xobject: PDFObject, on page: PDFPage, transform: CGAffineTransform, layer: PDFPlacementLayer = .over,
                      tag: PDFMarkedContentTag? = nil) throws -> String {
        guard page.model === self else { throw PDFModelError.invalidOperation("page of another model") }
        let form = makeIndirect(xobject)
        let name = page.addResource(form, category: "XObject", prefix: "Fx")
        var ops = PDFContentStream.isolated([
            PDFContentOperation("cm", PDFValue.matrix(transform).arrayValue!),
            PDFContentOperation("Do", [.name(name)]),
        ])
        if let tag { ops = PDFContentStream.markedContent(ops, tag: tag.tag, properties: tag.properties) }
        let content = PDFContentStream(operations: ops).serialized()
        switch layer {
        case .under:
            page.addContent(content, prepend: true)
        case .over:
            // Wrap what is there in q … Q so its graphics state cannot leak into the overlay.
            page.addContent(Data("q\n".utf8), prepend: true)
            page.addContent(Data("\nQ\n".utf8) + content)
        }
        return name
    }

    /// Draws `source` (a page of any model) over or under `page`, filling the page's crop box.
    @discardableResult
    public func overlay(_ source: PDFPage, on page: PDFPage, layer: PDFPlacementLayer = .over, tag: PDFMarkedContentTag? = nil) throws -> String {
        let form = try formXObject(from: source)
        return try place(form, on: page, in: page.box(.crop), keepAspectRatio: true, layer: layer, tag: tag)
    }

    /// Removes the marked-content spans `shouldRemove` picks from `page` and returns how many went (the page keeps
    /// one content stream). The resources they used stay: other pages may share them.
    @discardableResult
    public func removeMarkedContent(on page: PDFPage, where shouldRemove: (PDFMarkedContent) -> Bool) throws -> Int {
        var content = try page.contentStream()
        let removed = content.removeMarkedContent(where: shouldRemove)
        if removed > 0 { page.setContentStream(content) }
        return removed
    }
}
