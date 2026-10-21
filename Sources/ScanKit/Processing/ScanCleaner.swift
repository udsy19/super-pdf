import CoreImage
import Foundation
import SuperPDFCore
import Vision

/// "Clean up a scan" (features #104) with Core Image and Vision, in this order: turn the page the right way up by its
/// text, cut off black borders, straighten a slightly crooked page, whiten the paper, remove specks. Every step leaves an
/// already-clean page as it is, so cleaning twice gives the same page.
enum ScanCleaner {
    static func clean(_ page: ScannedPage, options: CleanUpOptions) throws -> ScannedPage {
        var image = try ScanImage.decode(page.image)
        if options.autoRotate, let turns = try uprightQuarterTurns(image), turns != 0 {
            image = rotated(image, quarterTurns: turns)
        }
        if options.removeBorders, let crop = try borderCrop(image) {
            image = image.cropped(to: crop).transformed(by: CGAffineTransform(translationX: -crop.minX, y: -crop.minY))
        }
        if options.deskew {
            let angle = try skewAngle(image)
            if abs(angle) >= minimumSkew { image = straightened(image, by: angle) }
        }
        if options.whitenBackground { image = try whitened(image) }
        if options.despeckle {
            image = image.clampedToExtent().applyingFilter("CIMedianFilter").cropped(to: image.extent)
        }
        let cg = try ScanImage.render(image)
        return try ScanImage.page(cg, resolution: page.resolution, lossless: ScanImage.isPNG(page.image))
    }

    // MARK: Upright by text orientation

    /// Quarter turns (clockwise) that make the text read upright, or nil when there is too little text to tell. Vision's
    /// accurate recogniser reads text in any orientation; the direction its lines run (each line's top-left → top-right
    /// edge, weighted by letters) says how the page is turned.
    static func uprightQuarterTurns(_ image: CIImage) throws -> Int? {
        let small = try ScanImage.render(ScanImage.downscaled(image, longSide: 1200).image)
        let request = VNRecognizeTextRequest()
        request.recognitionLevel = .accurate
        request.usesLanguageCorrection = true
        try VNImageRequestHandler(cgImage: small, options: [:]).perform([request])
        var direction = CGVector(dx: 0, dy: 0)
        var letters = 0
        // Normalised coordinates stretch with the picture; directions are measured in pixels.
        let width = CGFloat(small.width), height = CGFloat(small.height)
        for observation in request.results ?? [] {
            guard let best = observation.topCandidates(1).first, best.confidence >= 0.3 else { continue }
            let count = best.string.filter(\.isLetter).count
            let dx = (observation.topRight.x - observation.topLeft.x) * width, dy = (observation.topRight.y - observation.topLeft.y) * height
            let length = hypot(dx, dy)
            guard count > 0, length > 0 else { continue }
            direction.dx += dx / length * CGFloat(count)
            direction.dy += dy / length * CGFloat(count)
            letters += count
        }
        guard letters >= 20, hypot(direction.dx, direction.dy) > CGFloat(letters) / 2 else { return nil }
        // Lines running right are upright; running down means the page was turned clockwise, and so on.
        if abs(direction.dx) >= abs(direction.dy) { return direction.dx > 0 ? 0 : 2 }
        return direction.dy < 0 ? 3 : 1
    }

    /// The picture turned `turns` quarter turns clockwise, origin back at zero.
    static func rotated(_ image: CIImage, quarterTurns turns: Int) -> CIImage {
        let turned = image.transformed(by: CGAffineTransform(rotationAngle: -CGFloat(turns) * .pi / 2))
        let extent = turned.extent
        return turned.transformed(by: CGAffineTransform(translationX: -extent.minX, y: -extent.minY))
            .cropped(to: CGRect(origin: .zero, size: extent.size).integral)
    }

    // MARK: Black borders

    /// Mean luminance below which an edge line counts as scanner border.
    static let borderLuminance = 70.0
    /// Borders never take more than this share of a side.
    static let maximumBorder = 0.2

    /// The page without the dark bands along its edges (in image coordinates), or nil when there are none.
    static func borderCrop(_ image: CIImage) throws -> CGRect? {
        let (small, scale) = ScanImage.downscaled(image, longSide: 1000)
        let grey = try ScanImage.grey(small)
        let w = grey.width, h = grey.height
        guard w > 10, h > 10 else { return nil }
        func rowMean(_ y: Int) -> Double { Double((0..<w).reduce(0) { $0 + Int(grey.at($1, y)) }) / Double(w) }
        func columnMean(_ x: Int) -> Double { Double((0..<h).reduce(0) { $0 + Int(grey.at(x, $1)) }) / Double(h) }
        var top = 0, bottom = 0, left = 0, right = 0
        let maxRows = Int(Double(h) * maximumBorder), maxColumns = Int(Double(w) * maximumBorder)
        while top < maxRows, rowMean(top) < borderLuminance { top += 1 }
        while bottom < maxRows, rowMean(h - 1 - bottom) < borderLuminance { bottom += 1 }
        while left < maxColumns, columnMean(left) < borderLuminance { left += 1 }
        while right < maxColumns, columnMean(w - 1 - right) < borderLuminance { right += 1 }
        guard top + bottom + left + right > 0 else { return nil }
        // One more line of margin past each band: its anti-aliased edge is grey, not paper.
        func grow(_ n: Int) -> Int { n > 0 ? n + 1 : 0 }
        let full = image.extent
        // Rows count from the top; image coordinates from the bottom.
        let rect = CGRect(x: CGFloat(grow(left)) / scale, y: CGFloat(grow(bottom)) / scale,
                          width: full.width - CGFloat(grow(left) + grow(right)) / scale,
                          height: full.height - CGFloat(grow(top) + grow(bottom)) / scale).integral
        return rect.width > 0 && rect.height > 0 ? rect.intersection(full) : nil
    }

    // MARK: Deskew

    /// Smaller angles (degrees) are left alone: straightening would only soften the picture.
    static let minimumSkew = 0.3
    static let maximumSkew = 8.0

    /// The page's tilt in degrees (counter-clockwise positive) by the projection-profile method: the angle at which rows
    /// of ink line up best with the pixel rows. Zero for a page with too little ink to tell.
    static func skewAngle(_ image: CIImage) throws -> Double {
        let grey = try ScanImage.grey(ScanImage.downscaled(image, longSide: 900).image)
        let threshold = min(Int(grey.percentile(0.5)) - 60, 160)
        var ink: [(x: Double, y: Double)] = []
        let cx = Double(grey.width) / 2, cy = Double(grey.height) / 2
        for y in 0..<grey.height {
            for x in 0..<grey.width where Int(grey.at(x, y)) < threshold {
                ink.append((Double(x) - cx, Double(y) - cy))
            }
        }
        guard ink.count > 50, ink.count < grey.pixels.count / 2 else { return 0 }
        func score(_ degrees: Double) -> Double {
            let r = degrees * .pi / 180
            let s = sin(r), c = cos(r)
            var rows = [Int](repeating: 0, count: grey.height * 2 + grey.width * 2)
            let offset = rows.count / 2
            for p in ink {
                // A line of ink tilted by `degrees` (counter-clockwise, rows counting down) falls on one row here.
                let row = Int((p.y * c + p.x * s).rounded()) + offset
                if row >= 0 && row < rows.count { rows[row] += 1 }
            }
            return rows.reduce(0) { $0 + Double($1 * $1) }
        }
        var best = (angle: 0.0, score: score(0))
        for step in stride(from: -maximumSkew, through: maximumSkew, by: 0.5) where step != 0 {
            let s = score(step)
            if s > best.score { best = (step, s) }
        }
        let coarse = best.angle
        for step in stride(from: coarse - 0.5, through: coarse + 0.5, by: 0.1) {
            let s = score(step)
            if s > best.score { best = (step, s) }
        }
        return best.angle
    }

    /// The page turned back by `degrees`, on white, at its original size.
    static func straightened(_ image: CIImage, by degrees: Double) -> CIImage {
        let extent = image.extent
        let center = CGPoint(x: extent.midX, y: extent.midY)
        let turn = CGAffineTransform(translationX: center.x, y: center.y)
            .rotated(by: -CGFloat(degrees) * .pi / 180)
            .translatedBy(x: -center.x, y: -center.y)
        let paper = CIImage(color: .white).cropped(to: extent)
        return image.transformed(by: turn).composited(over: paper).cropped(to: extent)
    }

    // MARK: Whiten

    /// The paper made white and the ink black by a linear stretch: the paper's tone (the 60th percentile of a page that
    /// is mostly paper) maps to white, the darkest ink to black.
    static func whitened(_ image: CIImage) throws -> CIImage {
        let grey = try ScanImage.grey(ScanImage.downscaled(image, longSide: 800).image)
        let white = Double(grey.percentile(0.6))
        let black = min(Double(grey.percentile(0.005)), max(white - 96, 0))
        guard white < 250 || black > 5, white - black > 32 else { return image }
        let gain = 255 / (white - black)
        let bias = -black / 255 * gain
        return image.applyingFilter("CIColorMatrix", parameters: [
            "inputRVector": CIVector(x: gain, y: 0, z: 0, w: 0),
            "inputGVector": CIVector(x: 0, y: gain, z: 0, w: 0),
            "inputBVector": CIVector(x: 0, y: 0, z: gain, w: 0),
            "inputBiasVector": CIVector(x: bias, y: bias, z: bias, w: 0),
        ]).applyingFilter("CIColorClamp")
    }
}
