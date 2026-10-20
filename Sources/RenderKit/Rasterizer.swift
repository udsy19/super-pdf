import CoreGraphics
import Foundation
import ImageIO
import SuperPDFCore
import UniformTypeIdentifiers

/// Page → pixels through a bitmap context in the requested colour space (ColorSync converts), off the main actor.
public enum Rasterizer {
    /// Rasters above this many pixels are refused rather than swapped to disk (A3 at 600 dpi is 70 M).
    public static var maxPixels = 120_000_000

    /// The page at `dpi` (72 = 1 pt per pixel), white background.
    public static func render(_ page: CGPDFPage, dpi: Double, colorSpace: RenderColorSpace = .sRGB) throws -> CGImage {
        let size = PDFPages.displayedSize(page)
        let scale = dpi / 72
        return try render(page, pixelSize: CGSize(width: (size.width * scale).rounded(), height: (size.height * scale).rounded()), colorSpace: colorSpace)
    }

    /// The page fitted inside `maxPixelSize` (aspect kept), for thumbnails and view tiles.
    public static func render(_ page: CGPDFPage, fitting maxPixelSize: CGSize, colorSpace: RenderColorSpace = .sRGB) throws -> CGImage {
        let size = PDFPages.displayedSize(page)
        let scale = min(maxPixelSize.width / max(size.width, 1), maxPixelSize.height / max(size.height, 1))
        return try render(page, pixelSize: CGSize(width: max((size.width * scale).rounded(), 1), height: max((size.height * scale).rounded(), 1)), colorSpace: colorSpace)
    }

    public static func render(_ page: CGPDFPage, pixelSize: CGSize, colorSpace: RenderColorSpace = .sRGB) throws -> CGImage {
        let width = Int(pixelSize.width), height = Int(pixelSize.height)
        guard width > 0, height > 0 else { throw RenderError.cannotCreateContext }
        guard width * height <= maxPixels else { throw RenderError.tooLarge(width: width, height: height) }
        let context = try bitmapContext(width: width, height: height, colorSpace: colorSpace)
        context.interpolationQuality = CGInterpolationQuality.high
        PDFPages.draw(page, in: context, fitting: CGRect(x: 0, y: 0, width: width, height: height))
        guard let image = context.makeImage() else { throw RenderError.cannotCreateContext }
        return image
    }

    /// A white-filled bitmap context: 8-bit RGBA (sRGB), 8-bit grey, or 8-bit CMYK without alpha.
    public static func bitmapContext(width: Int, height: Int, colorSpace: RenderColorSpace, space: CGColorSpace? = nil) throws -> CGContext {
        let context: CGContext?
        switch colorSpace {
        case .sRGB:
            context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                                space: space ?? CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
        case .gray:
            context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                                space: space ?? CGColorSpace(name: CGColorSpace.genericGrayGamma2_2)!, bitmapInfo: CGImageAlphaInfo.none.rawValue)
        case .cmyk:
            context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                                space: space ?? CGColorSpace(name: CGColorSpace.genericCMYK)!, bitmapInfo: CGImageAlphaInfo.none.rawValue)
        }
        guard let context else { throw RenderError.cannotCreateContext }
        context.setFillColor(CGColor(gray: 1, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        return context
    }
}

/// Encodes rasters with ImageIO (features #53).
public enum ImageEncoder {
    /// Formats ImageIO can write here (WebP has no system encoder).
    public static let supportedFormats: [ImageFormat] = {
        let identifiers = Set((CGImageDestinationCopyTypeIdentifiers() as? [String]) ?? [])
        return ImageFormat.allCases.filter { identifiers.contains(utType(for: $0).identifier) }
    }()

    public static func utType(for format: ImageFormat) -> UTType {
        switch format {
        case .png: .png
        case .jpeg: .jpeg
        case .tiff: .tiff
        case .heic: .heic
        case .webp: .webP
        }
    }

    /// `quality` 0…1 applies to lossy formats; `dpi` is written as the image's resolution.
    public static func encode(_ image: CGImage, format: ImageFormat, quality: Double = 0.9, dpi: Double = 72) throws -> Data {
        try encode([image], format: format, quality: quality, dpi: dpi)
    }

    /// Several images in one file: a multi-page TIFF (features #53 "single multi-page TIFF"); other formats take one.
    public static func encode(_ images: [CGImage], format: ImageFormat, quality: Double = 0.9, dpi: Double = 72) throws -> Data {
        guard supportedFormats.contains(format) else { throw RenderError.unsupportedFormat(format) }
        let data = NSMutableData()
        let count = format == .tiff ? images.count : 1
        guard let destination = CGImageDestinationCreateWithData(data, utType(for: format).identifier as CFString, count, nil) else { throw RenderError.cannotCreateContext }
        let properties: [CFString: Any] = [kCGImageDestinationLossyCompressionQuality: quality, kCGImagePropertyDPIWidth: dpi, kCGImagePropertyDPIHeight: dpi,
                                           kCGImagePropertyTIFFDictionary: [kCGImagePropertyTIFFCompression: 5]]   // LZW
        for image in images.prefix(count) { CGImageDestinationAddImage(destination, image, properties as CFDictionary) }
        guard CGImageDestinationFinalize(destination) else { throw RenderError.cannotCreateContext }
        return data as Data
    }
}
