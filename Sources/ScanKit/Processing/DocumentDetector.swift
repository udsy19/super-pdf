import CoreImage
import Foundation
import SuperPDFCore
import Vision

/// Finds the sheet of paper in a photo and straightens it (features #103): Vision's document segmentation, with its
/// rectangle detector as the fallback, then Core Image's perspective correction to the four corners.
enum DocumentDetector {
    /// Below this the corners are not trusted and the whole photo is used.
    static let minimumConfidence: Float = 0.5

    /// The sheet's corners (0…1, origin bottom-left), or nil when no sheet stands out.
    static func detect(in photo: Data) throws -> DetectedDocument? {
        let (image, _) = ScanImage.downscaled(try ScanImage.decode(photo), longSide: 1600)
        let cg = try ScanImage.render(image)
        let segmentation = VNDetectDocumentSegmentationRequest()
        let rectangles = VNDetectRectanglesRequest()
        rectangles.maximumObservations = 1
        rectangles.minimumSize = 0.2
        rectangles.minimumAspectRatio = 0.3
        rectangles.quadratureTolerance = 30
        rectangles.minimumConfidence = minimumConfidence
        let handler = VNImageRequestHandler(cgImage: cg, options: [:])
        try? handler.perform([segmentation])
        if let found = segmentation.results?.first, found.confidence >= minimumConfidence, Self.isPlausible(found) {
            return document(found)
        }
        try handler.perform([rectangles])
        if let found = rectangles.results?.first, Self.isPlausible(found) { return document(found) }
        return nil
    }

    /// A sheet covers a real part of the photo and is not a sliver.
    private static func isPlausible(_ observation: VNRectangleObservation) -> Bool {
        let box = observation.boundingBox
        return box.width * box.height > 0.05 && min(box.width, box.height) > 0.1
    }

    private static func document(_ o: VNRectangleObservation) -> DetectedDocument {
        DetectedDocument(topLeft: o.topLeft, topRight: o.topRight, bottomRight: o.bottomRight, bottomLeft: o.bottomLeft,
                         confidence: Double(o.confidence))
    }

    /// The sheet cut out and squared up. Its resolution assumes the long side is a Letter/A4 page's (11 inches), so the
    /// page lands at about its paper size in the PDF.
    static func straighten(_ photo: Data, to document: DetectedDocument) throws -> ScannedPage {
        let image = try ScanImage.decode(photo)
        let size = image.extent.size
        func point(_ p: CGPoint) -> CIVector { CIVector(x: p.x * size.width, y: p.y * size.height) }
        let corrected = image.applyingFilter("CIPerspectiveCorrection", parameters: [
            "inputTopLeft": point(document.topLeft), "inputTopRight": point(document.topRight),
            "inputBottomRight": point(document.bottomRight), "inputBottomLeft": point(document.bottomLeft),
        ])
        let extent = corrected.extent.integral
        let cg = try ScanImage.render(corrected.transformed(by: CGAffineTransform(translationX: -extent.minX, y: -extent.minY)))
        return try ScanImage.page(cg, resolution: Self.resolution(for: CGSize(width: cg.width, height: cg.height)))
    }

    /// A whole photo as a page (no sheet found), at the same notional resolution.
    static func wholePhoto(_ photo: Data) throws -> ScannedPage {
        let cg = try ScanImage.render(try ScanImage.decode(photo))
        return try ScanImage.page(cg, resolution: Self.resolution(for: CGSize(width: cg.width, height: cg.height)))
    }

    static func resolution(for pixels: CGSize) -> Double {
        max(Double(max(pixels.width, pixels.height)) / 11, 36)
    }
}
