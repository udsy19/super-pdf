import CoreGraphics
import CoreImage
import CoreImage.CIFilterBuiltins
import Foundation
import LayoutKit
import PDFModelKit
import SuperPDFCore

// Recognise text (features #92, §3.3): each page rendered as shown, cleaned up for the recogniser (straightened,
// whitened, despeckled; the page itself is not changed), read by Vision through LayoutKit's `TextRecognizer`, and
// written back as the invisible text layer, or with "Make text editable" as real text that replaces the scan.

enum Recognizer {
    struct Result {
        var data: Data
        var recognizedPages: Int
        var emptyPages: Int
    }

    /// Recognises `pages` (0-based) and returns the document with their text. `progress` gets (done, total, page).
    static func recognize(_ source: PDFSource, pages: [Int], options: OCROptions, progress: ((Int, Int, Int) -> Void)? = nil) throws -> Result {
        let data = try source.bytes()
        let model = try PDFModel(data: data, password: source.password)
        guard let provider = CGDataProvider(data: data as CFData), let document = CGPDFDocument(provider) else {
            throw PDFModelError.damaged("unreadable")
        }
        if document.isEncrypted, !document.isUnlocked { _ = document.unlockWithPassword(source.password ?? "") }
        var font: PDFObject?
        var recognized = 0, empty = 0
        for (done, index) in pages.enumerated() {
            try Task.checkCancellation()
            guard let cgPage = document.page(at: index + 1), let page = model.page(at: index) else { continue }
            let words = try words(on: cgPage, options: options)
            if words.isEmpty {
                empty += 1
            } else {
                recognized += 1
                if !(options.editableText && EditableText.replaceScan(on: page, with: words)) {
                    let layerFont = font ?? TextLayer.makeFont(in: model)
                    font = layerFont
                    TextLayer.add(words, to: page, font: layerFont)
                }
            }
            progress?(done + 1, pages.count, index)
        }
        return Result(data: try model.data(), recognizedPages: recognized, emptyPages: empty)
    }

    /// The words Vision reads on a page, in display space.
    static func words(on page: CGPDFPage, options: OCROptions) throws -> [PlacedWord] {
        guard let image = TextRecognizer.image(for: page, dpi: options.dpi) else { return [] }
        let crop = page.getBoxRect(.cropBox)
        let displayed = Int(page.rotationAngle) % 180 == 0 ? crop.size : CGSize(width: crop.height, height: crop.width)
        var input = image
        var skew = 0.0
        if options.cleanUp {
            skew = Deskew.angle(of: image)
            input = ScanCleanUp.enhance(image, rotation: -skew) ?? image
        }
        let lines = try TextRecognizer.recognize(input, pageSize: displayed, rotation: 0, languages: options.languages)
        let centre = CGPoint(x: displayed.width / 2, y: displayed.height / 2)
        return TextRecognizer.words(from: lines).compactMap { word in
            let text = word.text.trimmingCharacters(in: .whitespaces)
            guard !text.isEmpty else { return nil }
            guard skew != 0 else { return PlacedWord(text: text, bounds: word.bounds) }
            // Back from the straightened image to the page: turn the box's corner about the centre by the skew.
            let corner = CGPoint(x: word.bounds.minX - centre.x, y: word.bounds.minY - centre.y)
            let turned = CGPoint(x: corner.x * cos(skew) - corner.y * sin(skew) + centre.x, y: corner.x * sin(skew) + corner.y * cos(skew) + centre.y)
            return PlacedWord(text: text, bounds: CGRect(origin: turned, size: word.bounds.size), angle: skew)
        }
    }
}

// MARK: - Clean-up for the recogniser

/// The skew of a page's text lines by projection profiles: the angle at which dark pixels pile into the fewest,
/// fullest rows.
enum Deskew {
    /// Radians, counter-clockwise, within ±5°; 0 when the page is straight (under 0.15°) or has too little ink.
    static func angle(of image: CGImage) -> Double {
        let scale = min(1, 1000 / Double(max(image.width, 1)))
        let width = max(1, Int(Double(image.width) * scale)), height = max(1, Int(Double(image.height) * scale))
        guard let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width,
                                      space: CGColorSpaceCreateDeviceGray(), bitmapInfo: CGImageAlphaInfo.none.rawValue),
              let raw = context.data else { return 0 }
        context.interpolationQuality = .medium
        context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
        let pixels = raw.bindMemory(to: UInt8.self, capacity: width * height)
        let threshold = otsu(UnsafeBufferPointer(start: pixels, count: width * height))
        var xs: [Double] = [], ys: [Double] = []
        for row in 0..<height {
            let y = Double(height - 1 - row)
            for x in 0..<width where pixels[row * width + x] < threshold {
                xs.append(Double(x)); ys.append(y)
            }
        }
        guard xs.count >= 200, xs.count < width * height / 2 else { return 0 }
        if xs.count > 80_000 {
            let stride = xs.count / 80_000 + 1
            xs = Swift.stride(from: 0, to: xs.count, by: stride).map { xs[$0] }
            ys = Swift.stride(from: 0, to: ys.count, by: stride).map { ys[$0] }
        }
        let limit = 5.0 * .pi / 180
        let span = Int(Double(width) * tan(limit)) + 2
        var bins = [Double](repeating: 0, count: height + 2 * span + 2)
        func score(_ angle: Double) -> Double {
            let t = tan(angle)
            for i in bins.indices { bins[i] = 0 }
            for i in xs.indices {
                let key = Int((ys[i] - xs[i] * t).rounded()) + span
                if key >= 0 && key < bins.count { bins[key] += 1 }
            }
            return bins.reduce(0) { $0 + $1 * $1 }
        }
        var best = 0.0
        var step = 0.5 * .pi / 180
        var low = -limit, high = limit
        for _ in 0..<3 {
            var bestScore = -1.0
            var angle = low
            while angle <= high + 1e-9 {
                let s = score(angle)
                if s > bestScore { bestScore = s; best = angle }
                angle += step
            }
            low = best - step; high = best + step
            step /= 5
        }
        return abs(best) < 0.15 * .pi / 180 ? 0 : best
    }

    /// Otsu's threshold of a grey histogram.
    static func otsu(_ pixels: UnsafeBufferPointer<UInt8>) -> UInt8 {
        var histogram = [Double](repeating: 0, count: 256)
        for value in pixels { histogram[Int(value)] += 1 }
        let total = Double(pixels.count)
        let sum = histogram.enumerated().reduce(0) { $0 + Double($1.offset) * $1.element }
        var background = 0.0, backgroundSum = 0.0, best = 0.0, threshold = 128
        for level in 0..<256 {
            background += histogram[level]
            guard background > 0 else { continue }
            let foreground = total - background
            guard foreground > 0 else { break }
            backgroundSum += Double(level) * histogram[level]
            let meanBack = backgroundSum / background, meanFore = (sum - backgroundSum) / foreground
            let between = background * foreground * (meanBack - meanFore) * (meanBack - meanFore)
            if between > best { best = between; threshold = level }
        }
        return UInt8(min(255, threshold + 1))
    }
}

/// Core Image clean-up of a page image before recognition: straightened by `rotation`, shadows removed and the
/// background whitened (document enhancer), specks removed (median), grey out.
enum ScanCleanUp {
    private static let context = CIContext(options: [.cacheIntermediates: false])

    static func enhance(_ image: CGImage, rotation: Double) -> CGImage? {
        let extent = CGRect(x: 0, y: 0, width: image.width, height: image.height)
        var output = CIImage(cgImage: image)
        if rotation != 0 {
            let turn = CGAffineTransform(translationX: extent.midX, y: extent.midY).rotated(by: rotation).translatedBy(x: -extent.midX, y: -extent.midY)
            output = output.transformed(by: turn).composited(over: CIImage(color: .white).cropped(to: extent)).cropped(to: extent)
        }
        let enhancer = CIFilter.documentEnhancer()
        enhancer.inputImage = output
        enhancer.amount = 1
        output = enhancer.outputImage ?? output
        let median = CIFilter.median()
        median.inputImage = output
        output = (median.outputImage ?? output).cropped(to: extent)
        return context.createCGImage(output, from: extent, format: .L8, colorSpace: CGColorSpaceCreateDeviceGray())
    }
}
