import CoreGraphics
import Foundation
import ImageIO
import SuperPDFCore

/// Pages in and out of PDF: scanned pictures become a PDF with one page per picture at its paper size, and the PDF an
/// iPhone's "Scan Documents" returns becomes pictures so every page goes through the same clean-up.
enum ScanPDF {
    /// Resolution the iPhone's PDF pages are read at (its document camera delivers about this much detail).
    static let deviceResolution = 200.0

    /// One page per picture, each the size the picture covers at its resolution.
    static func make(_ pages: [ScannedPage]) throws -> Data {
        let data = NSMutableData()
        guard let consumer = CGDataConsumer(data: data as CFMutableData),
              let context = CGContext(consumer: consumer, mediaBox: nil, nil) else { throw ScanImage.Failure.unencodable }
        for page in pages {
            guard let source = CGImageSourceCreateWithData(page.image as CFData, nil),
                  let image = Self.uprightImage(source) else { throw ScanImage.Failure.unreadable }
            let dpi = page.resolution > 0 ? page.resolution : 300
            var box = CGRect(x: 0, y: 0, width: Double(image.width) * 72 / dpi, height: Double(image.height) * 72 / dpi)
            let info = [kCGPDFContextMediaBox as String: NSData(bytes: &box, length: MemoryLayout<CGRect>.size)] as CFDictionary
            context.beginPDFPage(info)
            context.interpolationQuality = .high
            context.draw(image, in: box)
            context.endPDFPage()
        }
        context.closePDF()
        return data as Data
    }

    /// The picture with its EXIF orientation applied; untouched pictures pass straight through (JPEG stays JPEG).
    private static func uprightImage(_ source: CGImageSource) -> CGImage? {
        let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any]
        let orientation = (properties?[kCGImagePropertyOrientation] as? UInt32) ?? 1
        guard orientation != 1 else { return CGImageSourceCreateImageAtIndex(source, 0, nil) }
        let long = max((properties?[kCGImagePropertyPixelWidth] as? Int) ?? 0, (properties?[kCGImagePropertyPixelHeight] as? Int) ?? 0)
        return CGImageSourceCreateThumbnailAtIndex(source, 0, [
            kCGImageSourceCreateThumbnailFromImageAlways: true, kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: max(long, 1),
        ] as CFDictionary)
    }

    /// Each page of a PDF drawn on white at `resolution`.
    static func rasterize(_ pdf: Data, resolution: Double = deviceResolution) throws -> [ScannedPage] {
        guard let provider = CGDataProvider(data: pdf as CFData), let document = CGPDFDocument(provider), document.numberOfPages > 0 else {
            throw ScanImage.Failure.unreadable
        }
        return try (1...document.numberOfPages).compactMap { number in
            guard let page = document.page(at: number) else { return nil }
            let box = page.getBoxRect(.cropBox)
            let turns = ((page.rotationAngle % 360) + 360) % 360 / 90
            let size = turns % 2 == 1 ? CGSize(width: box.height, height: box.width) : box.size
            let scale = resolution / 72
            let width = max(Int((size.width * scale).rounded()), 1), height = max(Int((size.height * scale).rounded()), 1)
            guard let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                                          space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                          bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue) else { throw ScanImage.Failure.unreadable }
            context.setFillColor(CGColor(gray: 1, alpha: 1))
            context.fill(CGRect(x: 0, y: 0, width: width, height: height))
            context.interpolationQuality = .high
            context.scaleBy(x: scale, y: scale)
            context.concatenate(page.getDrawingTransform(.cropBox, rect: CGRect(origin: .zero, size: size), rotate: 0, preserveAspectRatio: true))
            context.drawPDFPage(page)
            guard let image = context.makeImage() else { throw ScanImage.Failure.unreadable }
            return try ScanImage.page(image, resolution: resolution)
        }
    }
}
