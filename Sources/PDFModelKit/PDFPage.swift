import CoreGraphics
import Foundation
internal import QPDF

/// The page boxes (ISO 32000-2 §14.11.2).
public enum PDFBox: String, CaseIterable, Sendable {
    case media = "MediaBox", crop = "CropBox", bleed = "BleedBox", trim = "TrimBox", art = "ArtBox"
}

/// A page of a `PDFModel`: its dictionary plus the page-level helpers. Indices are 0-based.
public struct PDFPage {
    public let object: PDFObject
    public var model: PDFModel { object.model }

    public init(_ object: PDFObject) { self.object = object }

    /// The page's index in its model (nil when it is not in the page tree).
    public var index: Int? {
        let i = qpdf_find_page_by_oh(model.q, object.oh)
        model.takeError()
        return i >= 0 ? Int(i) : nil
    }

    // MARK: Boxes and rotation

    /// A page box with inheritance and the defaults of §14.11.2 (crop → media, the others → crop), clipped to the
    /// media box. Letter size when the file gives no media box.
    public func box(_ kind: PDFBox) -> CGRect {
        let media = object.inherited(PDFBox.media.rawValue)?.rect ?? CGRect(x: 0, y: 0, width: 612, height: 792)
        switch kind {
        case .media: return media
        case .crop:
            guard let crop = object.inherited(PDFBox.crop.rawValue)?.rect else { return media }
            let clipped = crop.intersection(media)
            return clipped.isNull || clipped.isEmpty ? media : clipped
        default:
            let crop = box(.crop)
            guard let own = object[kind.rawValue]?.rect else { return crop }
            let clipped = own.intersection(media)
            return clipped.isNull || clipped.isEmpty ? crop : clipped
        }
    }

    /// Sets a page box on the page itself; nil removes it (it then inherits or falls back to its default).
    public func setBox(_ kind: PDFBox, _ rect: CGRect?) {
        if let rect { object.set(kind.rawValue, .rect(rect)) } else { object.remove(kind.rawValue) }
    }

    /// Clockwise rotation for display: 0, 90, 180 or 270 (inherited).
    public var rotation: Int {
        let raw = object.inherited("Rotate")?.int ?? 0
        let quarter = Int((Double(raw) / 90).rounded()) * 90
        return ((quarter % 360) + 360) % 360
    }

    /// Sets the rotation (normalised to 0/90/180/270), written on the page itself.
    public func setRotation(_ degrees: Int) {
        let quarter = Int((Double(degrees) / 90).rounded()) * 90
        let normalised = ((quarter % 360) + 360) % 360
        object.set("Rotate", .integer(normalised))
    }

    /// The crop box's size as shown (width and height swap at 90° and 270°).
    public var displaySize: CGSize {
        let crop = box(.crop)
        return rotation % 180 == 0 ? crop.size : CGSize(width: crop.height, height: crop.width)
    }

    /// Maps page space to the shown page (origin at its lower left, rotation applied): the inverse of what a viewer
    /// undoes when it draws the crop box upright.
    public var displayTransform: CGAffineTransform { Self.displayTransform(box: box(.crop), rotation: rotation) }

    static func displayTransform(box b: CGRect, rotation: Int) -> CGAffineTransform {
        switch rotation {
        case 90: CGAffineTransform(a: 0, b: -1, c: 1, d: 0, tx: -b.minY, ty: b.maxX)
        case 180: CGAffineTransform(a: -1, b: 0, c: 0, d: -1, tx: b.maxX, ty: b.maxY)
        case 270: CGAffineTransform(a: 0, b: 1, c: -1, d: 0, tx: b.maxY, ty: -b.minX)
        default: CGAffineTransform(translationX: -b.minX, y: -b.minY)
        }
    }

    // MARK: Resources

    /// The page's resource dictionary (inherited when the page has none of its own).
    public var resources: PDFObject? { object.inherited("Resources") }

    /// The page's own resource dictionary, made from the inherited one (or empty) when it has none.
    public func ownResources() -> PDFObject {
        if let own = object["Resources"], own.type == .dictionary { return own }
        object.set("Resources", resources?.value ?? .dictionary([:]))
        return object["Resources"]!
    }

    /// A resource name not yet used in `category` ("XObject", "Font", "ExtGState", "Properties"…): prefix + number.
    public func unusedResourceName(in category: String, prefix: String) -> String {
        let used = Set(resources?[category]?.keys ?? [])
        var n = 0
        while used.contains("\(prefix)\(n)") { n += 1 }
        return "\(prefix)\(n)"
    }

    /// Adds `object` under a fresh name in the page's own resources and returns the name.
    @discardableResult
    public func addResource(_ resource: PDFObject, category: String, prefix: String) -> String {
        let name = unusedResourceName(in: category, prefix: prefix)
        ownResources().dictionary(category).set(name, resource)
        return name
    }

    // MARK: Content

    /// The content streams (in order).
    public var contentStreams: [PDFObject] {
        guard let contents = object["Contents"] else { return [] }
        if contents.type == .stream { return [contents] }
        return contents.items.filter { $0.type == .stream }
    }

    /// The decoded content: all streams concatenated with a newline between them.
    public func contentData() throws -> Data {
        var buffer: UnsafeMutablePointer<UInt8>?
        var length = 0
        let rc = qpdf_oh_get_page_content_data(model.q, object.oh, &buffer, &length)
        defer { if buffer != nil { qpdf_oh_free_buffer(&buffer) } }
        if contentStreams.isEmpty { model.takeError(); return Data() }
        try model.check(rc)
        guard let buffer else { return Data() }
        return Data(bytes: buffer, count: length)
    }

    /// Replaces all content with one new stream.
    public func setContentData(_ data: Data) {
        object.set("Contents", model.makeStream(data: data))
    }

    /// Adds a content stream before or after the existing ones.
    public func addContent(_ data: Data, prepend: Bool = false) {
        let stream = model.makeStream(data: data)
        let existing = contentStreams
        let contents = model.make(.array([]))
        if prepend { contents.append(stream) }
        for s in existing { contents.append(s) }
        if !prepend { contents.append(stream) }
        object.set("Contents", contents)
    }

    /// The content parsed into operations.
    public func contentStream() throws -> PDFContentStream { PDFContentStream(parsing: try contentData()) }

    public func setContentStream(_ stream: PDFContentStream) { setContentData(stream.serialized()) }

    /// The /Annots entries.
    public var annotations: [PDFObject] { object["Annots"]?.items ?? [] }

    /// Adds an annotation dictionary (made indirect) to /Annots and points its /P here.
    @discardableResult
    public func addAnnotation(_ annotation: PDFObject) -> PDFObject {
        let annot = model.makeIndirect(annotation)
        if let ref = object.reference { annot.set("P", ref) }
        object.array("Annots").append(annot)
        return annot
    }
}

// MARK: - Page tree

extension PDFModel {
    public var pageCount: Int {
        let n = qpdf_get_num_pages(q)
        takeError()
        return max(Int(n), 0)
    }

    public func page(at index: Int) -> PDFPage? {
        guard index >= 0, index < pageCount else { return nil }
        return PDFPage(PDFObject(self, qpdf_get_page_n(q, index)))
    }

    public var pages: [PDFPage] { (0..<pageCount).map { PDFPage(PDFObject(self, qpdf_get_page_n(q, $0))) } }

    /// Inserts `page` (of this model or another) so it ends up at `index`. A page of another model is copied with
    /// everything it uses; a page already in this tree is shallow-copied (a duplicate).
    @discardableResult
    public func insertPage(_ page: PDFPage, at index: Int) throws -> PDFPage {
        let count = pageCount
        guard index >= 0, index <= count else { throw PDFModelError.invalidOperation("page index \(index) of \(count)") }
        let source = page.model
        if index == count {
            try check(qpdf_add_page(q, source.q, page.object.oh, QPDF_FALSE))
        } else {
            let reference = qpdf_get_page_n(q, index)
            defer { qpdf_oh_release(q, reference) }
            try check(qpdf_add_page_at(q, source.q, page.object.oh, QPDF_TRUE, reference))
        }
        return self.page(at: index)!
    }

    /// Copies pages of another model (or this one) to `index`, in order.
    public func insertPages(from source: PDFModel, pages indices: [Int], at index: Int) throws {
        let sourcePages = try indices.map { i -> PDFPage in
            guard let page = source.page(at: i) else { throw PDFModelError.invalidOperation("no page \(i)") }
            return page
        }
        for (offset, page) in sourcePages.enumerated() { try insertPage(page, at: index + offset) }
    }

    public func removePage(at index: Int) throws {
        guard let page = page(at: index) else { throw PDFModelError.invalidOperation("no page \(index)") }
        try check(qpdf_remove_page(q, page.object.oh))
    }

    /// Moves a page so it ends up at `destination` (an index in the final order).
    public func movePage(from index: Int, to destination: Int) throws {
        guard let page = page(at: index) else { throw PDFModelError.invalidOperation("no page \(index)") }
        guard destination >= 0, destination < pageCount else { throw PDFModelError.invalidOperation("page index \(destination)") }
        guard index != destination else { return }
        try check(qpdf_remove_page(q, page.object.oh))
        try insertPage(page, at: destination)
    }

    /// A new empty page of `size` (points) at `index` (the end by default).
    @discardableResult
    public func addBlankPage(size: CGSize, at index: Int? = nil) throws -> PDFPage {
        let page = makeIndirect(.dictionary([
            "Type": .name("Page"),
            "MediaBox": .rect(CGRect(origin: .zero, size: size)),
            "Resources": .dictionary([:]),
        ]))
        page.set("Contents", makeStream(data: Data()))
        return try insertPage(PDFPage(page), at: index ?? pageCount)
    }
}
