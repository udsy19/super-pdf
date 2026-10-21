import CoreGraphics
import Foundation
import ImageIO
import PDFModelKit
import RenderKit

// Make smaller's pictures (features #91): one image XObject at a time, downsampled to the target resolution and
// re-encoded, keeping its colour space, /Decode, soft mask and the rest of its dictionary. Grey and colour pictures
// become JPEG at the preset's quality; CMYK stays lossless (Flate), since CMYK JPEGs read inconsistently. A picture is
// only replaced when the new data is clearly smaller. Stencil masks, palette, spot-colour, 1/2/4/16-bit and JPEG 2000
// pictures are left alone.

/// What one preset asks of a picture.
struct ImageTarget: Sendable {
    /// Pictures drawn denser than 1.5 × this are downsampled to it.
    var dpi: Double
    /// JPEG quality 0…1.
    var quality: Double
    /// May turn lossless pictures into JPEG and re-encode JPEGs that aren't downsampled.
    var reencodeLossy: Bool
}

enum ImageRecompressor {
    /// New data must be at most this share of the old to replace it.
    static let keepRatio = 0.85

    /// Replaces `image` with a smaller encoding for `target` when one exists; returns the bytes saved (0 when kept).
    /// `resolution` is the picture's densest use in pixels per inch (nil when it isn't drawn on a page).
    @discardableResult
    static func recompress(_ image: PDFObject, in model: PDFModel, resolution: Double?, target: ImageTarget) -> Int {
        guard image.type == .stream, image["Subtype"]?.name == "Image", image["ImageMask"]?.bool != true,
              (image["BitsPerComponent"]?.int ?? 8) == 8,
              let width = image["Width"]?.int, let height = image["Height"]?.int, width >= 16, height >= 16,
              let components = components(of: image["ColorSpace"], in: model) else { return 0 }
        let filters = image.filters
        guard filters.allSatisfy({ ["FlateDecode", "DCTDecode", "LZWDecode", "ASCII85Decode", "ASCIIHexDecode", "RunLengthDecode"].contains($0) }),
              let old = try? image.streamData(decode: .none).count, old > 0 else { return 0 }
        let isJPEG = filters.last == "DCTDecode"
        if isJPEG && components == 4 { return 0 }
        // A colour-key /Mask array matches exact sample values, which JPEG doesn't keep.
        let colourKeyed = image["Mask"]?.type == .array

        var scale = 1.0
        if let resolution, resolution > target.dpi * 1.5 { scale = target.dpi / resolution }
        let newWidth = max(1, Int((Double(width) * scale).rounded())), newHeight = max(1, Int((Double(height) * scale).rounded()))
        let downsampled = newWidth < width || newHeight < height
        let lossy = components != 4 && !colourKeyed && (target.reencodeLossy || isJPEG)
        // Nothing to gain: same size and no new encoding to try.
        if !downsampled && !(lossy && target.reencodeLossy) { return 0 }

        guard let decoded = decode(image, isJPEG: isJPEG, components: components, width: width, height: height,
                                   maxPixelSize: downsampled ? max(newWidth, newHeight) : nil),
              let resampled = resample(decoded, components: components, width: newWidth, height: newHeight) else { return 0 }
        let replacement: PDFImageData
        let size: Int
        if lossy {
            guard let jpeg = try? ImageEncoder.encode(resampled.image, format: .jpeg, quality: target.quality) else { return 0 }
            let stripped = strippingMetadata(jpeg)
            replacement = .jpeg(stripped)
            size = stripped.count
        } else {
            replacement = .samples(resampled.samples)
            size = ((try? (resampled.samples as NSData).compressed(using: .zlib) as Data)?.count ?? resampled.samples.count) + 6
        }
        guard Double(size) < Double(old) * keepRatio else { return 0 }
        do {
            try model.replaceImage(image, with: replacement, width: newWidth, height: newHeight)
        } catch {
            return 0
        }
        return old - size
    }

    /// Colour components of an image colour space we can resample sample by sample: grey, RGB, CMYK (device, calibrated
    /// or ICC-based). Nil for palettes, spot colours, Lab and patterns.
    static func components(of colorSpace: PDFObject?, in model: PDFModel) -> Int? {
        guard let colorSpace else { return nil }
        if let name = colorSpace.name {
            switch name {
            case "DeviceGray", "G", "CalGray": return 1
            case "DeviceRGB", "RGB", "CalRGB": return 3
            case "DeviceCMYK", "CMYK": return 4
            default: return nil
            }
        }
        guard colorSpace.type == .array, let family = colorSpace[0]?.name else { return nil }
        switch family {
        case "CalGray": return 1
        case "CalRGB": return 3
        case "ICCBased":
            guard let n = colorSpace[1]?["N"]?.int, [1, 3, 4].contains(n) else { return nil }
            return n
        default: return nil
        }
    }

    // MARK: Decode

    /// The picture as a CGImage whose samples are the PDF's own (no colour conversion). JPEGs decode through ImageIO,
    /// which can shrink while decoding; everything else from QPDF's decoded samples.
    private static func decode(_ image: PDFObject, isJPEG: Bool, components: Int, width: Int, height: Int, maxPixelSize: Int?) -> CGImage? {
        if isJPEG {
            guard let jpeg = try? image.streamData(decode: .generalized),
                  let source = CGImageSourceCreateWithData(jpeg as CFData, nil) else { return nil }
            let model = (CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any])?[kCGImagePropertyColorModel] as? String
            guard model == (components == 1 ? (kCGImagePropertyColorModelGray as String) : (kCGImagePropertyColorModelRGB as String)) else { return nil }
            if let maxPixelSize {
                let options: [CFString: Any] = [kCGImageSourceCreateThumbnailFromImageAlways: true, kCGImageSourceThumbnailMaxPixelSize: maxPixelSize,
                                                kCGImageSourceCreateThumbnailWithTransform: false, kCGImageSourceShouldCacheImmediately: true]
                return CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary)
            }
            return CGImageSourceCreateImageAtIndex(source, 0, [kCGImageSourceShouldCacheImmediately: true] as CFDictionary)
        }
        guard let samples = try? image.streamData(decode: .all), samples.count >= width * height * components,
              let provider = CGDataProvider(data: samples as CFData) else { return nil }
        return CGImage(width: width, height: height, bitsPerComponent: 8, bitsPerPixel: 8 * components, bytesPerRow: width * components,
                       space: deviceSpace(components), bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.none.rawValue),
                       provider: provider, decode: nil, shouldInterpolate: false, intent: .defaultIntent)
    }

    private static func deviceSpace(_ components: Int) -> CGColorSpace {
        switch components {
        case 1: CGColorSpaceCreateDeviceGray()
        case 4: CGColorSpaceCreateDeviceCMYK()
        default: CGColorSpaceCreateDeviceRGB()
        }
    }

    // MARK: Resample

    /// The picture drawn at `width` × `height` into a context of the same colour model, and its packed samples.
    private static func resample(_ image: CGImage, components: Int, width: Int, height: Int) -> (image: CGImage, samples: Data)? {
        // Drawing into the image's own space changes no sample values; a space of another model falls back to device.
        let own = image.colorSpace.flatMap { space -> CGColorSpace? in
            switch (space.model, components) {
            case (.monochrome, 1), (.rgb, 3), (.cmyk, 4): space
            default: nil
            }
        }
        let space = own ?? deviceSpace(components)
        let alpha: CGImageAlphaInfo = components == 3 ? .noneSkipLast : .none
        let bytesPerPixel = components == 3 ? 4 : components
        guard let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width * bytesPerPixel,
                                      space: space, bitmapInfo: alpha.rawValue) else { return nil }
        context.interpolationQuality = .high
        context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
        guard let result = context.makeImage(), let raw = context.data else { return nil }
        let bytes = UnsafeRawBufferPointer(start: raw, count: width * height * bytesPerPixel)
        var samples = Data(count: width * height * components)
        samples.withUnsafeMutableBytes { out in
            if components == 3 {
                for pixel in 0..<(width * height) {
                    out[pixel * 3] = bytes[pixel * 4]; out[pixel * 3 + 1] = bytes[pixel * 4 + 1]; out[pixel * 3 + 2] = bytes[pixel * 4 + 2]
                }
            } else {
                out.copyMemory(from: bytes)
            }
        }
        return (result, samples)
    }

    // MARK: Encode

    /// The JPEG without APP1–APP15 segments other than Adobe's APP14 (Exif, ICC profiles, XMP: a PDF reader uses the
    /// image's /ColorSpace, and a profile is several kilobytes per picture).
    static func strippingMetadata(_ jpeg: Data) -> Data {
        let b = [UInt8](jpeg)
        guard b.count > 4, b[0] == 0xFF, b[1] == 0xD8 else { return jpeg }
        var out: [UInt8] = [0xFF, 0xD8]
        var i = 2
        while i + 4 <= b.count {
            guard b[i] == 0xFF else { return jpeg }
            let marker = b[i + 1]
            if marker == 0xDA { out.append(contentsOf: b[i...]); return Data(out) }
            let length = Int(b[i + 2]) << 8 | Int(b[i + 3])
            guard length >= 2, i + 2 + length <= b.count else { return jpeg }
            let isMetadata = (0xE1...0xEF).contains(marker) && marker != 0xEE
            if !isMetadata { out.append(contentsOf: b[i..<(i + 2 + length)]) }
            i += 2 + length
        }
        return jpeg
    }
}
