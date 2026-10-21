import CoreGraphics
import CoreImage
import Foundation
import ImageIO
import SuperPDFCore
import UniformTypeIdentifiers

/// Decoding, encoding and measuring scan pictures, off the main actor. Pictures cross actors as encoded bytes
/// (`ScannedPage.image`); inside a step they are `CIImage`s rendered through one shared context.
enum ScanImage {
    /// One context for every render: sRGB working space, no intermediate caching (pages are processed once).
    static let context = CIContext(options: [
        .workingColorSpace: CGColorSpace(name: CGColorSpace.sRGB)!,
        .cacheIntermediates: false,
    ])

    enum Failure: Error { case unreadable, unencodable }

    /// The picture with its EXIF orientation applied (phones save sideways pictures with an orientation flag).
    static func decode(_ data: Data) throws -> CIImage {
        guard let image = CIImage(data: data, options: [.applyOrientationProperty: true]) else { throw Failure.unreadable }
        return image.transformed(by: CGAffineTransform(translationX: -image.extent.minX, y: -image.extent.minY))
    }

    static func render(_ image: CIImage) throws -> CGImage {
        guard let cg = context.createCGImage(image, from: image.extent.integral, format: .RGBA8,
                                             colorSpace: CGColorSpace(name: CGColorSpace.sRGB)) else { throw Failure.unreadable }
        return cg
    }

    /// JPEG for colour and grey pages, PNG for black-and-white ones (sharp edges, small files).
    static func encode(_ image: CGImage, lossless: Bool = false) throws -> Data {
        let data = NSMutableData()
        let type = (lossless ? UTType.png : UTType.jpeg).identifier as CFString
        guard let destination = CGImageDestinationCreateWithData(data, type, 1, nil) else { throw Failure.unencodable }
        let options: [CFString: Any] = lossless ? [:] : [kCGImageDestinationLossyCompressionQuality: 0.85]
        CGImageDestinationAddImage(destination, image, options as CFDictionary)
        guard CGImageDestinationFinalize(destination) else { throw Failure.unencodable }
        return data as Data
    }

    /// Whether encoded bytes are a PNG (kept lossless through the clean-up).
    static func isPNG(_ data: Data) -> Bool { data.starts(with: [0x89, 0x50, 0x4E, 0x47]) }

    /// A page from a rendered picture, keeping the source's resolution.
    static func page(_ image: CGImage, resolution: Double, lossless: Bool = false) throws -> ScannedPage {
        ScannedPage(image: try encode(image, lossless: lossless), pixelSize: CGSize(width: image.width, height: image.height),
                    resolution: resolution)
    }

    /// The image scaled so its long side is at most `side` pixels (analysis works on small copies).
    static func downscaled(_ image: CIImage, longSide side: CGFloat) -> (image: CIImage, scale: CGFloat) {
        let long = max(image.extent.width, image.extent.height)
        guard long > side else { return (image, 1) }
        let scale = side / long
        let scaled = image.applyingFilter("CILanczosScaleTransform", parameters: [kCIInputScaleKey: scale, kCIInputAspectRatioKey: 1])
        return (scaled.cropped(to: CGRect(x: 0, y: 0, width: floor(image.extent.width * scale), height: floor(image.extent.height * scale))), scale)
    }

    /// Luminance (0–255) row by row from the top, for the measuring steps.
    struct Grey {
        var pixels: [UInt8]
        var width: Int
        var height: Int

        func at(_ x: Int, _ y: Int) -> UInt8 { pixels[y * width + x] }

        /// The luminance below which `share` of the pixels fall.
        func percentile(_ share: Double) -> UInt8 {
            var histogram = [Int](repeating: 0, count: 256)
            for p in pixels { histogram[Int(p)] += 1 }
            let target = Int(Double(pixels.count) * share)
            var seen = 0
            for (value, count) in histogram.enumerated() {
                seen += count
                if seen > target { return UInt8(value) }
            }
            return 255
        }
    }

    static func grey(_ image: CIImage) throws -> Grey {
        let cg = try render(image)
        let width = cg.width, height = cg.height
        var pixels = [UInt8](repeating: 255, count: width * height)
        let drawn: Bool = pixels.withUnsafeMutableBytes { buffer in
            guard let context = CGContext(data: buffer.baseAddress, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width,
                                          space: CGColorSpaceCreateDeviceGray(), bitmapInfo: CGImageAlphaInfo.none.rawValue) else { return false }
            context.setFillColor(gray: 1, alpha: 1)
            context.fill(CGRect(x: 0, y: 0, width: width, height: height))
            context.draw(cg, in: CGRect(x: 0, y: 0, width: width, height: height))
            return true
        }
        guard drawn else { throw Failure.unreadable }
        return Grey(pixels: pixels, width: width, height: height)
    }
}
