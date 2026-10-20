import CoreGraphics
import Foundation
import SuperPDFCore
import Vision

/// OCR through Vision (features §3.3): accurate level, automatic language detection unless languages are given, custom
/// words from the document's own text. Results come back as `RecognizedLine`s in page space with per-word boxes, the
/// input `LayoutAnalyzer` takes for scanned pages and FixKit writes as the invisible text layer. Runs off the main actor.
public enum TextRecognizer {
    /// Recognises text in `image`, which shows the page as displayed (rotation applied) and maps the boxes back into
    /// the unrotated page space of `pageSize`.
    public static func recognize(_ image: CGImage, pageSize: CGSize, rotation: Int, languages: [String] = [], customWords: [String] = []) throws -> [RecognizedLine] {
        let request = VNRecognizeTextRequest()
        request.recognitionLevel = .accurate
        request.usesLanguageCorrection = true
        if languages.isEmpty { request.automaticallyDetectsLanguage = true } else { request.recognitionLanguages = languages }
        if !customWords.isEmpty { request.customWords = Array(customWords.prefix(2000)) }
        try VNImageRequestHandler(cgImage: image, options: [:]).perform([request])
        let displayed = pageSize.rotated(by: rotation)
        func pageRect(_ normalized: CGRect) -> CGRect {
            CGRect(x: normalized.minX * displayed.width, y: normalized.minY * displayed.height,
                   width: normalized.width * displayed.width, height: normalized.height * displayed.height)
                .rotated(by: rotation, pageSize: pageSize, inverse: true)
        }
        var lines: [RecognizedLine] = []
        for observation in request.results ?? [] {
            guard let candidate = observation.topCandidates(1).first else { continue }
            let text = candidate.string
            let bounds = pageRect(observation.boundingBox)
            var words: [LayoutWord] = []
            var searchStart = text.startIndex
            for token in text.split(separator: " ", omittingEmptySubsequences: true) {
                guard let range = text.range(of: token, range: searchStart..<text.endIndex) else { continue }
                searchStart = range.upperBound
                let box = (try? candidate.boundingBox(for: range))?.boundingBox ?? observation.boundingBox
                let wordBounds = pageRect(box)
                words.append(LayoutWord(text: String(token), bounds: wordBounds.rounded, fontSize: ((wordBounds.height * 0.8) * 2).rounded() / 2,
                                        confidence: Double(candidate.confidence)))
            }
            lines.append(RecognizedLine(text: text, bounds: bounds.rounded, confidence: Double(candidate.confidence), words: words))
        }
        return lines
    }

    /// Words for the analyser from OCR lines; lines without word boxes are split evenly across their box. Box heights
    /// jitter with ascenders and descenders, so sizes within a quarter of the page's median height all take the median
    /// (body text stays one size; headings, clearly larger, keep theirs).
    public static func words(from lines: [RecognizedLine]) -> [LayoutWord] {
        var words = rawWords(from: lines)
        let heights = words.map(\.bounds.height).sorted()
        guard !heights.isEmpty else { return words }
        let medianHeight = heights[heights.count / 2]
        let bodySize = ((medianHeight * 0.8) * 2).rounded() / 2
        for index in words.indices where words[index].bounds.height >= 0.75 * medianHeight && words[index].bounds.height <= 1.25 * medianHeight {
            words[index].fontSize = bodySize
        }
        return words
    }

    private static func rawWords(from lines: [RecognizedLine]) -> [LayoutWord] {
        lines.flatMap { line -> [LayoutWord] in
            if !line.words.isEmpty { return line.words }
            let tokens = line.text.split(separator: " ").map(String.init)
            guard !tokens.isEmpty else { return [] }
            let characters = max(tokens.reduce(0) { $0 + $1.count } + tokens.count - 1, 1)
            var x = line.bounds.minX
            return tokens.map { token in
                let width = line.bounds.width * CGFloat(token.count) / CGFloat(characters)
                defer { x += width + line.bounds.width / CGFloat(characters) }
                return LayoutWord(text: token, bounds: CGRect(x: x, y: line.bounds.minY, width: width, height: line.bounds.height),
                                  fontSize: ((line.bounds.height * 0.8) * 2).rounded() / 2, confidence: line.confidence)
            }
        }
    }

    /// Renders a page as displayed for OCR: grey, `dpi` resolution capped so the long side stays under 4500 pixels.
    /// (A deliberate twin of RenderKit's rasterizer in twenty lines: LayoutKit does not depend on RenderKit.)
    public static func image(for page: CGPDFPage, dpi: Double = 300) -> CGImage? {
        let crop = page.getBoxRect(.cropBox)
        let displayed = crop.size.rotated(by: Int(page.rotationAngle))
        let scale = min(dpi / 72, 4500 / max(displayed.width, displayed.height, 1))
        let width = Int((displayed.width * scale).rounded()), height = Int((displayed.height * scale).rounded())
        guard width > 0, height > 0,
              let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                                      space: CGColorSpaceCreateDeviceGray(), bitmapInfo: CGImageAlphaInfo.none.rawValue) else { return nil }
        context.setFillColor(gray: 1, alpha: 1)
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        context.interpolationQuality = CGInterpolationQuality.high
        // CGPDFPageGetDrawingTransform never scales up: rotate at the page's own size, then scale.
        context.scaleBy(x: scale, y: scale)
        context.concatenate(page.getDrawingTransform(.cropBox, rect: CGRect(origin: .zero, size: displayed), rotate: 0, preserveAspectRatio: true))
        context.drawPDFPage(page)
        return context.makeImage()
    }
}
