import AppKit
import CoreGraphics
import Foundation
import ImageIO
import PDFModelKit
import UniformTypeIdentifiers

// Pictures on a page (features #61, #62): move, resize, rotate, flip, crop, replace, delete, and add. A placed image
// keeps its place in the drawing order: the `Do` that drew it is replaced by `q <adjustment> cm /Im Do Q`, where the
// adjustment turns the matrix that was in force into the one wanted.

enum ImageEditError: Error, Equatable {
    case notEditable
    case unreadableImage
}

enum ImageEditor {
    /// Moves and resizes: `rect` is the new page-space box (flips when its width or height is negative).
    static func place(_ image: ImagePlacement, in rect: CGRect, rotation: Double = 0, page: PDFPage, content: PageContent) throws {
        try transform(image, to: matrix(for: rect, rotation: rotation), crop: nil, page: page, content: content)
    }

    /// Unit square → `rect`, rotated by `rotation` degrees about the centre (negative sizes flip).
    static func matrix(for rect: CGRect, rotation: Double) -> CGAffineTransform {
        let center = CGPoint(x: rect.midX, y: rect.midY)
        var t = CGAffineTransform(a: rect.width, b: 0, c: 0, d: rect.height, tx: rect.minX, ty: rect.minY)
        if rect.width < 0 { t = CGAffineTransform(a: rect.width, b: 0, c: 0, d: rect.height, tx: rect.maxX, ty: rect.minY) }
        if rect.height < 0 { t.ty = rect.maxY }
        guard rotation != 0 else { return t }
        let about = CGAffineTransform(translationX: center.x, y: center.y).rotated(by: rotation * .pi / 180).translatedBy(x: -center.x, y: -center.y)
        return t.concatenating(about)
    }

    /// Flips horizontally or vertically in place.
    static func flip(_ image: ImagePlacement, horizontally: Bool, page: PDFPage, content: PageContent) throws {
        let flip = horizontally ? CGAffineTransform(a: -1, b: 0, c: 0, d: 1, tx: 1, ty: 0) : CGAffineTransform(a: 1, b: 0, c: 0, d: -1, tx: 0, ty: 1)
        try transform(image, to: flip.concatenating(image.transform), crop: nil, page: page, content: content)
    }

    /// Rotates by `degrees` about the centre.
    static func rotate(_ image: ImagePlacement, by degrees: Double, page: PDFPage, content: PageContent) throws {
        let center = CGPoint(x: 0.5, y: 0.5).applying(image.transform)
        let about = CGAffineTransform(translationX: center.x, y: center.y).rotated(by: degrees * .pi / 180).translatedBy(x: -center.x, y: -center.y)
        try transform(image, to: image.transform.concatenating(about), crop: nil, page: page, content: content)
    }

    /// Crops to `fraction` of the image (0…1 in image space, origin bottom-left): the visible part keeps its place.
    static func crop(_ image: ImagePlacement, to fraction: CGRect, page: PDFPage, content: PageContent) throws {
        try transform(image, to: image.transform, crop: fraction, page: page, content: content)
    }

    /// Removes the picture (the operation that drew it).
    static func delete(_ image: ImagePlacement, page: PDFPage, content: PageContent) throws {
        guard let opIndex = image.opIndex, !image.inForm else { throw ImageEditError.notEditable }
        page.setContentStream(ContentSurgery.rewrite(content.stream, replacing: [opIndex: []], appending: []))
    }

    /// Replaces the picture's pixels with an image file's (its box on the page stays; the aspect follows the new picture
    /// when `keepAspect`).
    static func replace(_ image: ImagePlacement, with file: URL, keepAspect: Bool, page: PDFPage, content: PageContent) throws {
        guard let object = image.object, !image.inForm else { throw ImageEditError.notEditable }
        guard let decoded = decode(file) else { throw ImageEditError.unreadableImage }
        try write(decoded, into: object, model: page.model)
        if keepAspect {
            let box = image.bounds
            let aspect = Double(decoded.image.width) / Double(max(decoded.image.height, 1))
            var rect = box
            if box.width / max(box.height, 0.001) > aspect { rect.size.width = box.height * aspect } else { rect.size.height = box.width / aspect }
            rect.origin = CGPoint(x: box.midX - rect.width / 2, y: box.midY - rect.height / 2)
            try place(image, in: rect, page: page, content: content)
        }
    }

    /// Adds an image file to the page at `rect` (its aspect kept inside it); returns the box it got.
    @discardableResult
    static func add(_ file: URL, in rect: CGRect, page: PDFPage) throws -> CGRect {
        guard let decoded = decode(file) else { throw ImageEditError.unreadableImage }
        let aspect = Double(decoded.image.width) / Double(max(decoded.image.height, 1))
        var box = rect
        if rect.width / max(rect.height, 0.001) > aspect { box.size.width = rect.height * aspect } else { box.size.height = rect.width / aspect }
        box.origin = CGPoint(x: rect.midX - box.width / 2, y: rect.midY - box.height / 2)
        let model = page.model
        let stream = model.makeStream(["Type": .name("XObject"), "Subtype": .name("Image")], data: Data())
        try write(decoded, into: stream, model: model)
        let name = page.addResource(stream, category: "XObject", prefix: "SPIm")
        let content = try page.contentStream()
        let ops = PDFContentStream.isolated([ContentSurgery.cm(matrix(for: box, rotation: 0)), PDFContentOperation("Do", [.name(name)])])
        page.setContentStream(ContentSurgery.rewrite(content, replacing: [:], appending: ops))
        return box
    }

    /// The picture's pixels as a PNG (with alpha) or JPEG (opaque), for "Edit in…" round trips and the replace sheet.
    static func export(_ image: ImagePlacement, page: PDFPage) throws -> (data: Data, type: UTType) {
        guard let object = image.object, let x = page.imageXObjects().first(where: { $0.object.isSameObject(as: object) }) else { throw ImageEditError.notEditable }
        if x.filters.contains("DCTDecode"), !x.hasMask { return (try x.encodedData(), .jpeg) }
        guard let cg = cgImage(of: x) else { throw ImageEditError.unreadableImage }
        let out = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(out, UTType.png.identifier as CFString, 1, nil) else { throw ImageEditError.unreadableImage }
        CGImageDestinationAddImage(destination, cg, nil)
        CGImageDestinationFinalize(destination)
        return (out as Data, .png)
    }

    // MARK: Internals

    private static func transform(_ image: ImagePlacement, to target: CGAffineTransform, crop: CGRect?, page: PDFPage, content: PageContent) throws {
        guard let opIndex = image.opIndex, !image.inForm else { throw ImageEditError.notEditable }
        let op = content.stream.operations[opIndex]
        // cm × CTM = target  ⇒  cm = target × CTM⁻¹
        let adjustment = target.concatenating(image.transform.inverted())
        var ops: [PDFContentOperation] = [PDFContentOperation("q"), ContentSurgery.cm(adjustment)]
        if let crop {
            // Clip to the kept part and stretch the whole image so that part fills the original box.
            let scale = CGAffineTransform(a: 1 / max(crop.width, 0.001), b: 0, c: 0, d: 1 / max(crop.height, 0.001), tx: 0, ty: 0)
            let shift = CGAffineTransform(translationX: -crop.minX, y: -crop.minY)
            ops.append(PDFContentOperation("re", [.integer(0), .integer(0), .integer(1), .integer(1)]))
            ops.append(PDFContentOperation("W"))
            ops.append(PDFContentOperation("n"))
            ops.append(ContentSurgery.cm(shift.concatenating(scale)))
        }
        ops.append(op)
        ops.append(PDFContentOperation("Q"))
        page.setContentStream(ContentSurgery.rewrite(content.stream, replacing: [opIndex: ops], appending: []))
    }

    struct Decoded {
        var image: CGImage
        var jpeg: Data?
    }

    /// Reads an image file; a JPEG file's bytes are kept to embed as they are.
    static func decode(_ file: URL) -> Decoded? {
        guard let source = CGImageSourceCreateWithURL(file as CFURL, nil), let image = CGImageSourceCreateImageAtIndex(source, 0, nil) else { return nil }
        let type = CGImageSourceGetType(source) as String?
        var jpeg: Data?
        if type == UTType.jpeg.identifier, let data = try? Data(contentsOf: file), image.alphaInfo == .none || image.alphaInfo == .noneSkipLast || image.alphaInfo == .noneSkipFirst {
            jpeg = data
        }
        return Decoded(image: image, jpeg: jpeg)
    }

    /// Writes pixels into an image XObject: JPEG as DCT, else RGB samples with an SMask for alpha.
    static func write(_ decoded: Decoded, into object: PDFObject, model: PDFModel) throws {
        let image = decoded.image
        if let jpeg = decoded.jpeg {
            object.remove("SMask"); object.remove("Mask")
            try model.replaceImage(object, with: .jpeg(jpeg), width: image.width, height: image.height, colorSpace: .name(image.colorSpace?.model == .monochrome ? "DeviceGray" : "DeviceRGB"))
            return
        }
        let width = image.width, height = image.height
        var rgba = [UInt8](repeating: 0, count: width * height * 4)
        let context = CGContext(data: &rgba, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width * 4,
                                space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
        var rgb = Data(capacity: width * height * 3)
        var alpha = Data(capacity: width * height)
        var hasAlpha = false
        for i in stride(from: 0, to: rgba.count, by: 4) {
            let a = rgba[i + 3]
            if a < 255 { hasAlpha = true }
            // Un-premultiply.
            if a > 0, a < 255 {
                rgb.append(UInt8(min(255, Int(rgba[i]) * 255 / Int(a)))); rgb.append(UInt8(min(255, Int(rgba[i + 1]) * 255 / Int(a)))); rgb.append(UInt8(min(255, Int(rgba[i + 2]) * 255 / Int(a))))
            } else {
                rgb.append(rgba[i]); rgb.append(rgba[i + 1]); rgb.append(rgba[i + 2])
            }
            alpha.append(a)
        }
        object.remove("Mask")
        try model.replaceImage(object, with: .samples(rgb), width: width, height: height, colorSpace: .name("DeviceRGB"))
        if hasAlpha {
            let smask = model.makeStream(["Type": .name("XObject"), "Subtype": .name("Image")], data: Data())
            try model.replaceImage(smask, with: .samples(alpha), width: width, height: height, colorSpace: .name("DeviceGray"))
            object.set("SMask", smask)
        } else {
            object.remove("SMask")
        }
    }

    /// Decodes an image XObject's samples into a CGImage (Gray/RGB/CMYK 8-bit, stencil masks, soft masks applied).
    static func cgImage(of image: PDFImageXObject) -> CGImage? {
        guard image.width > 0, image.height > 0, let samples = try? image.samples() else { return nil }
        let components: Int
        var space: CGColorSpace = CGColorSpaceCreateDeviceRGB()
        if image.isMask { components = 1; space = CGColorSpaceCreateDeviceGray() } else {
            switch image.colorSpace {
            case .name("DeviceGray"), .name("CalGray"), .name("G"): components = 1; space = CGColorSpaceCreateDeviceGray()
            case .name("DeviceCMYK"), .name("CMYK"): components = 4; space = CGColorSpaceCreateDeviceCMYK()
            case .array(let a) where a.first == .name("ICCBased"): components = samples.count / max(1, image.width * image.height * image.bitsPerComponent / 8); space = components == 1 ? CGColorSpaceCreateDeviceGray() : components == 4 ? CGColorSpaceCreateDeviceCMYK() : CGColorSpaceCreateDeviceRGB()
            case .array(let a) where a.first == .name("Indexed") || a.first == .name("I"): return indexed(image, samples: samples)
            default: components = 3
            }
        }
        let bpc = image.isMask ? 1 : image.bitsPerComponent
        let bytesPerRow = (image.width * components * bpc + 7) / 8
        guard samples.count >= bytesPerRow * image.height, let provider = CGDataProvider(data: samples as CFData) else { return nil }
        let info: CGBitmapInfo = image.isMask ? [] : CGBitmapInfo(rawValue: CGImageAlphaInfo.none.rawValue)
        if image.isMask {
            return CGImage(maskWidth: image.width, height: image.height, bitsPerComponent: 1, bitsPerPixel: 1, bytesPerRow: bytesPerRow, provider: provider, decode: nil, shouldInterpolate: false)
        }
        guard let base = CGImage(width: image.width, height: image.height, bitsPerComponent: bpc, bitsPerPixel: bpc * components, bytesPerRow: bytesPerRow, space: space,
                                 bitmapInfo: info, provider: provider, decode: nil, shouldInterpolate: true, intent: .defaultIntent) else { return nil }
        if let smask = image.object["SMask"], smask.type == .stream, let alpha = try? smask.streamData(decode: .all), let w = smask["Width"]?.int, let h = smask["Height"]?.int,
           alpha.count >= w * h, let maskProvider = CGDataProvider(data: alpha as CFData),
           let mask = CGImage(width: w, height: h, bitsPerComponent: 8, bitsPerPixel: 8, bytesPerRow: w, space: CGColorSpaceCreateDeviceGray(), bitmapInfo: [], provider: maskProvider, decode: nil, shouldInterpolate: true, intent: .defaultIntent) {
            // Combine through a bitmap: draw the colour image with the soft mask as a mask.
            let context = CGContext(data: nil, width: image.width, height: image.height, bitsPerComponent: 8, bytesPerRow: 0, space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
            let rect = CGRect(x: 0, y: 0, width: image.width, height: image.height)
            if let masked = base.masking(mask) { context.draw(masked, in: rect) } else { context.clip(to: rect, mask: mask); context.draw(base, in: rect) }
            return context.makeImage()
        }
        return base
    }

    private static func indexed(_ image: PDFImageXObject, samples: Data) -> CGImage? {
        guard case .array(let a)? = image.colorSpace, a.count >= 4, let hival = a[2].intValue else { return nil }
        let baseComponents: Int = a[1] == .name("DeviceGray") ? 1 : a[1] == .name("DeviceCMYK") ? 4 : 3
        var palette: Data
        switch a[3] {
        case .string(let d): palette = d
        case .reference: palette = (try? image.object.model.object(a[3])?.streamData(decode: .all)) ?? Data()
        default: return nil
        }
        guard !palette.isEmpty else { return nil }
        let bpc = image.bitsPerComponent
        var rgb = Data(capacity: image.width * image.height * 3)
        let bytesPerRow = (image.width * bpc + 7) / 8
        for y in 0..<image.height {
            for x in 0..<image.width {
                let bit = x * bpc
                let byte = samples[y * bytesPerRow + bit / 8]
                let index = bpc == 8 ? Int(byte) : Int((byte >> (8 - bpc - bit % 8)) & UInt8((1 << bpc) - 1))
                let i = min(index, hival) * baseComponents
                guard i + baseComponents <= palette.count else { rgb.append(contentsOf: [0, 0, 0]); continue }
                switch baseComponents {
                case 1: rgb.append(contentsOf: [palette[i], palette[i], palette[i]])
                case 4:
                    let k = Double(palette[i + 3]) / 255
                    rgb.append(UInt8((1 - Double(palette[i]) / 255) * (1 - k) * 255)); rgb.append(UInt8((1 - Double(palette[i + 1]) / 255) * (1 - k) * 255)); rgb.append(UInt8((1 - Double(palette[i + 2]) / 255) * (1 - k) * 255))
                default: rgb.append(contentsOf: [palette[i], palette[i + 1], palette[i + 2]])
                }
            }
        }
        guard let provider = CGDataProvider(data: rgb as CFData) else { return nil }
        return CGImage(width: image.width, height: image.height, bitsPerComponent: 8, bitsPerPixel: 24, bytesPerRow: image.width * 3, space: CGColorSpaceCreateDeviceRGB(),
                       bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.none.rawValue), provider: provider, decode: nil, shouldInterpolate: true, intent: .defaultIntent)
    }
}
