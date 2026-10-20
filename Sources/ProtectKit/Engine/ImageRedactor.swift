import CoreGraphics
import Foundation
import PDFModelKit

// Pictures under a Black out box (features #69 "images re-encoded with the area filled"): the samples under each area
// are overwritten, so the pixels are gone from the file, not just covered. Samples come from QPDF when it can decode
// the filters (Flate, LZW, RunLength, DCT…); other pictures (JPEG 2000, JBIG2, CCITT) are drawn by Quartz at their own
// pixel size and stored as plain samples. Soft masks and stencil masks are cut the same way, so a picture's shape
// can't give the hidden part away either. The result is a new image stream; the original stays for other users.

enum ImageRedactor {
    /// A copy of `image` with the pixels under `areas` (page space) overwritten; nil when it can't be decoded at all
    /// (the caller then drops the picture). `imageToPage` maps the unit square the image fills to page space.
    static func redact(_ image: PDFObject, model: PDFModel, areas: [CGRect], imageToPage: CGAffineTransform) -> PDFObject? {
        guard let width = image["Width"]?.int, let height = image["Height"]?.int, width > 0, height > 0, width * height < 400_000_000 else { return nil }
        let isMask = image["ImageMask"]?.bool == true
        var dictionary = image.value.dictionaryValue ?? [:]
        for key in ["Length", "Filter", "DecodeParms", "SMaskInData"] { dictionary.removeValue(forKey: key) }

        var samples: [UInt8]
        var bitsPerComponent: Int
        var components: Int
        if let decoded = decodedSamples(image, model: model, width: width, height: height, isMask: isMask) {
            (samples, bitsPerComponent, components) = decoded
        } else if let drawn = drawnSamples(image, width: width, height: height, isMask: isMask) {
            (samples, bitsPerComponent, components) = drawn
            dictionary.removeValue(forKey: "Decode")
            if isMask {
                dictionary["BitsPerComponent"] = .integer(1)
            } else {
                dictionary["ColorSpace"] = .name(components == 1 ? "DeviceGray" : "DeviceRGB")
                dictionary["BitsPerComponent"] = .integer(8)
            }
        } else {
            return nil
        }

        let bitsPerPixel = bitsPerComponent * components
        let rowBytes = (width * bitsPerPixel + 7) / 8
        // A stencil mask's "not painted" value: 1, or 0 when /Decode is [1 0].
        let unpainted: Bool = isMask ? (dictionary["Decode"]?.arrayValue?.first?.numberValue ?? 0) == 0 : false
        let inverse = imageToPage.inverted()
        for area in areas {
            let corners = [CGPoint(x: area.minX, y: area.minY), CGPoint(x: area.maxX, y: area.minY),
                           CGPoint(x: area.minX, y: area.maxY), CGPoint(x: area.maxX, y: area.maxY)].map { $0.applying(inverse) }
            // Unit square (y up) → pixel grid (row 0 at the top), one pixel of margin for resampling at the edges.
            let xs = corners.map { $0.x * CGFloat(width) }, ys = corners.map { (1 - $0.y) * CGFloat(height) }
            let x0 = max(Int(floor(xs.min()!)) - 1, 0), x1 = min(Int(ceil(xs.max()!)) + 1, width)
            let y0 = max(Int(floor(ys.min()!)) - 1, 0), y1 = min(Int(ceil(ys.max()!)) + 1, height)
            guard x0 < x1, y0 < y1 else { continue }
            fill(&samples, rowBytes: rowBytes, bitsPerPixel: bitsPerPixel, columns: x0..<x1, rows: y0..<y1, ones: unpainted)
        }

        let copy = model.makeStream(dictionary, data: Data(samples))
        for key in ["SMask", "Mask"] {
            guard let mask = image[key], mask.type == .stream else { continue }
            if let redactedMask = redact(mask, model: model, areas: areas, imageToPage: imageToPage) {
                copy.set(key, redactedMask)
            } else {
                copy.remove(key)
            }
        }
        return copy
    }

    /// An inline image (`BI … ID … EI`) as a redacted image XObject; nil when it can't be decoded.
    static func redactInline(_ op: PDFContentOperation, model: PDFModel, areas: [CGRect], imageToPage: CGAffineTransform) -> PDFObject? {
        guard let inline = op.operands.first?.dictionaryValue else { return nil }
        let keys = ["W": "Width", "H": "Height", "BPC": "BitsPerComponent", "CS": "ColorSpace", "F": "Filter", "DP": "DecodeParms",
                    "IM": "ImageMask", "D": "Decode", "I": "Interpolate"]
        var dictionary: [String: PDFValue] = ["Type": .name("XObject"), "Subtype": .name("Image")]
        for (key, value) in inline { dictionary[keys[key] ?? key] = expand(value) }
        let filter = dictionary.removeValue(forKey: "Filter")
        let parms = dictionary.removeValue(forKey: "DecodeParms")
        let stream = model.makeStream(dictionary, data: op.inlineImageData ?? Data(), filter: filter, decodeParms: parms)
        return redact(stream, model: model, areas: areas, imageToPage: imageToPage)
    }

    /// Inline images' abbreviated names (ISO 32000-2 §8.9.7, tables 91–92).
    private static func expand(_ value: PDFValue) -> PDFValue {
        let names = ["G": "DeviceGray", "RGB": "DeviceRGB", "CMYK": "DeviceCMYK", "I": "Indexed", "AHx": "ASCIIHexDecode",
                     "A85": "ASCII85Decode", "LZW": "LZWDecode", "Fl": "FlateDecode", "RL": "RunLengthDecode",
                     "CCF": "CCITTFaxDecode", "DCT": "DCTDecode"]
        switch value {
        case .name(let n): return .name(names[n] ?? n)
        case .array(let items): return .array(items.map(expand))
        default: return value
        }
    }

    // MARK: - Samples

    /// QPDF's decoded samples, when it can decode every filter and the size adds up.
    private static func decodedSamples(_ image: PDFObject, model: PDFModel, width: Int, height: Int,
                                       isMask: Bool) -> (samples: [UInt8], bitsPerComponent: Int, components: Int)? {
        guard image.canDecode(to: .all), let data = try? image.streamData(decode: .all) else { return nil }
        let bpc = isMask ? 1 : (image["BitsPerComponent"]?.int ?? 8)
        guard [1, 2, 4, 8, 16].contains(bpc) else { return nil }
        let components = isMask ? 1 : (componentCount(image["ColorSpace"].map { $0.reference ?? $0.value }, model: model) ?? 0)
        guard components > 0 else { return nil }
        let rowBytes = (width * bpc * components + 7) / 8
        guard data.count >= rowBytes * height else { return nil }
        return ([UInt8](data.prefix(rowBytes * height)), bpc, components)
    }

    /// How many components a colour space has; nil when it can't be told.
    static func componentCount(_ space: PDFValue?, model: PDFModel) -> Int? {
        guard var space else { return nil }
        if let reference = space.referenceValue {
            let object = model.object(id: reference.id, generation: reference.generation)
            // A stream here is an ICC profile.
            if object.type == .stream { return object["N"]?.int }
            space = object.value
        }
        if let name = space.nameValue {
            switch name {
            case "DeviceGray", "CalGray", "G": return 1
            case "DeviceRGB", "CalRGB", "Lab", "RGB": return 3
            case "DeviceCMYK", "CMYK": return 4
            default: return nil
            }
        }
        guard let items = space.arrayValue, let family = items.first?.nameValue else { return nil }
        switch family {
        case "ICCBased":
            guard items.count > 1, let reference = items[1].referenceValue else { return nil }
            return model.object(id: reference.id, generation: reference.generation)["N"]?.int
        case "Indexed", "I", "Separation": return 1
        case "DeviceN": return items.count > 1 ? items[1].arrayValue?.count : nil
        case "CalGray": return 1
        case "CalRGB", "Lab": return 3
        default: return componentCount(.name(family), model: model)
        }
    }

    /// The picture drawn by Quartz at its pixel size: grey or RGB samples, or 1-bit samples for a stencil mask.
    private static func drawnSamples(_ image: PDFObject, width: Int, height: Int,
                                     isMask: Bool) -> (samples: [UInt8], bitsPerComponent: Int, components: Int)? {
        let scratch = PDFModel()
        guard let page = try? scratch.addBlankPage(size: CGSize(width: width, height: height)) else { return nil }
        let copy = scratch.importObject(image)
        copy.remove("SMask"); copy.remove("Mask")
        let name = page.addResource(copy, category: "XObject", prefix: "Im")
        page.setContentData(Data("q \(width) 0 0 \(height) 0 0 cm /\(name) Do Q".utf8))
        guard let data = try? scratch.data(), let provider = CGDataProvider(data: data as CFData),
              let document = CGPDFDocument(provider), let pdfPage = document.page(at: 1) else { return nil }
        let gray = isMask || (componentCount(image["ColorSpace"].map { $0.reference ?? $0.value }, model: image.model) ?? 3) == 1
        let space = gray ? CGColorSpaceCreateDeviceGray() : CGColorSpaceCreateDeviceRGB()
        let info = gray ? CGImageAlphaInfo.none.rawValue : CGImageAlphaInfo.noneSkipLast.rawValue
        guard let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0, space: space, bitmapInfo: info) else { return nil }
        context.setFillColor(gray: 1, alpha: 1)
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        context.drawPDFPage(pdfPage)
        guard let base = context.data else { return nil }
        let stride = context.bytesPerRow
        let pixels = base.assumingMemoryBound(to: UInt8.self)
        if isMask {
            let rowBytes = (width + 7) / 8
            var out = [UInt8](repeating: 0, count: rowBytes * height)
            for y in 0..<height {
                for x in 0..<width where pixels[y * stride + x] > 127 { out[y * rowBytes + x / 8] |= 0x80 >> UInt8(x % 8) }
            }
            return (out, 1, 1)
        }
        if gray {
            var out = [UInt8](repeating: 0, count: width * height)
            for y in 0..<height { for x in 0..<width { out[y * width + x] = pixels[y * stride + x] } }
            return (out, 8, 1)
        }
        var out = [UInt8](repeating: 0, count: width * height * 3)
        for y in 0..<height {
            for x in 0..<width {
                let p = y * stride + x * 4, q = (y * width + x) * 3
                out[q] = pixels[p]; out[q + 1] = pixels[p + 1]; out[q + 2] = pixels[p + 2]
            }
        }
        return (out, 8, 3)
    }

    /// Sets every bit of the pixels in `columns` × `rows` to 0 (or 1 for `ones`).
    static func fill(_ samples: inout [UInt8], rowBytes: Int, bitsPerPixel: Int, columns: Range<Int>, rows: Range<Int>, ones: Bool) {
        let value: UInt8 = ones ? 0xFF : 0
        for y in rows {
            let row = y * rowBytes
            if bitsPerPixel % 8 == 0 {
                let bytes = bitsPerPixel / 8
                let start = row + columns.lowerBound * bytes, end = min(row + columns.upperBound * bytes, row + rowBytes)
                guard start < end, end <= samples.count else { continue }
                for i in start..<end { samples[i] = value }
                continue
            }
            for bit in (columns.lowerBound * bitsPerPixel)..<(columns.upperBound * bitsPerPixel) {
                let index = row + bit / 8
                guard index < samples.count, index < row + rowBytes else { break }
                let mask = UInt8(0x80) >> UInt8(bit % 8)
                if ones { samples[index] |= mask } else { samples[index] &= ~mask }
            }
        }
    }
}
