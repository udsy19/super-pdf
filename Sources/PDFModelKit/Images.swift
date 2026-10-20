import Foundation

// Image XObjects (features §3.1): find the images a page draws, read their data, replace it (Make smaller's
// downsampling, Edit image's replace, redaction's re-encoded images) keeping masks and the rest of the dictionary.

/// An image XObject a page uses.
public struct PDFImageXObject {
    /// The resource name it is drawn with (in the page's resources or a form's).
    public var name: String
    /// The image stream.
    public var object: PDFObject
    public var width: Int
    public var height: Int
    public var bitsPerComponent: Int
    /// /ColorSpace as written (a name, an array, or a reference); nil for stencil masks.
    public var colorSpace: PDFValue?
    public var filters: [String]
    /// A stencil mask (/ImageMask true).
    public var isMask: Bool
    /// /SMask (soft mask) or /Mask present.
    public var hasMask: Bool

    /// The data as stored: a JPEG file for DCTDecode, a JPEG 2000 file for JPXDecode.
    public func encodedData() throws -> Data { try object.streamData(decode: .generalized) }
    /// Decoded samples (lossy filters decoded too), row by row.
    public func samples() throws -> Data { try object.streamData(decode: .all) }
}

/// New image data for `replaceImage`.
public enum PDFImageData: Sendable {
    /// A baseline JPEG file (DCTDecode).
    case jpeg(Data)
    /// Raw samples, row by row; stored Flate-compressed.
    case samples(Data)
}

extension PDFPage {
    /// The image XObjects the page uses, each stream once (in resource order), including those inside its form
    /// XObjects when `includingForms`.
    public func imageXObjects(includingForms: Bool = true) -> [PDFImageXObject] {
        var result: [PDFImageXObject] = []
        var seen: Set<Int> = []
        func scan(_ resources: PDFObject?, depth: Int) {
            guard let xobjects = resources?["XObject"], depth < 12 else { return }
            for name in xobjects.keys {
                guard let x = xobjects[name], x.type == .stream else { continue }
                if let id = x.objectID { guard seen.insert(id).inserted else { continue } }
                switch x["Subtype"]?.name {
                case "Image":
                    result.append(PDFImageXObject(
                        name: name, object: x,
                        width: x["Width"]?.int ?? 0, height: x["Height"]?.int ?? 0,
                        bitsPerComponent: x["BitsPerComponent"]?.int ?? (x["ImageMask"]?.bool == true ? 1 : 8),
                        colorSpace: x["ColorSpace"].map { $0.reference ?? $0.value },
                        filters: x.filters,
                        isMask: x["ImageMask"]?.bool == true,
                        hasMask: x.has("SMask") || x.has("Mask")))
                case "Form" where includingForms:
                    scan(x["Resources"], depth: depth + 1)
                default:
                    break
                }
            }
        }
        scan(resources, depth: 0)
        return result
    }
}

extension PDFModel {
    /// Replaces an image's data and geometry; /SMask, /Mask, /Intent, /Interpolate and the rest stay. `colorSpace`
    /// replaces /ColorSpace (and drops /Decode, which belonged to the old samples); nil keeps both.
    public func replaceImage(_ image: PDFObject, with data: PDFImageData, width: Int, height: Int, bitsPerComponent: Int = 8,
                             colorSpace: PDFValue? = nil) throws {
        guard image.type == .stream, image["Subtype"]?.name == "Image" else { throw PDFModelError.invalidOperation("not an image XObject") }
        switch data {
        case .jpeg(let jpeg):
            image.setStreamData(jpeg, filter: .name("DCTDecode"))
        case .samples(let samples):
            if let compressed = Flate.compress(samples) {
                image.setStreamData(compressed, filter: .name("FlateDecode"))
            } else {
                image.setStreamData(samples)
            }
        }
        image.set("Width", .integer(width))
        image.set("Height", .integer(height))
        if image["ImageMask"]?.bool != true { image.set("BitsPerComponent", .integer(bitsPerComponent)) }
        if let colorSpace {
            image.set("ColorSpace", colorSpace)
            image.remove("Decode")
        }
    }
}
