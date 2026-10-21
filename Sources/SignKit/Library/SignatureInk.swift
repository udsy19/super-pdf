import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers

// Turning what people make into a saved signature (features #82): strokes drawn on the trackpad become a smooth line,
// and a picture of a signature on paper (the camera, an iPhone sketch) keeps only the ink, on a transparent background,
// cropped to the ink. Core Graphics only, so the self-test runs it on generated input.

enum SignatureInk {
    /// Dark blue-black, like a ballpoint.
    static let color = CGColor(srgbRed: 0.07, green: 0.09, blue: 0.22, alpha: 1)

    /// Strokes (points in a canvas of `canvas` size, y up) as a transparent PNG cropped to the ink.
    static func png(strokes: [[CGPoint]], canvas: CGSize, lineWidth: CGFloat = 3) -> Data? {
        let usable = strokes.filter { !$0.isEmpty }
        guard !usable.isEmpty, canvas.width >= 1, canvas.height >= 1 else { return nil }
        let scale: CGFloat = 2
        guard let context = rgbaContext(width: Int(canvas.width * scale), height: Int(canvas.height * scale)) else { return nil }
        context.scaleBy(x: scale, y: scale)
        context.setStrokeColor(color)
        context.setFillColor(color)
        context.setLineWidth(lineWidth)
        context.setLineCap(.round)
        context.setLineJoin(.round)
        for stroke in usable {
            if stroke.count == 1 {
                context.fillEllipse(in: CGRect(x: stroke[0].x - lineWidth / 2, y: stroke[0].y - lineWidth / 2, width: lineWidth, height: lineWidth))
                continue
            }
            context.addPath(smoothPath(stroke))
            context.strokePath()
        }
        guard let image = context.makeImage(), let trimmed = trim(image, padding: Int(lineWidth * scale * 2)) else { return nil }
        return pngData(trimmed)
    }

    /// A Catmull–Rom curve through the points, so a trackpad's samples read as one flowing line.
    static func smoothPath(_ points: [CGPoint]) -> CGPath {
        let path = CGMutablePath()
        path.move(to: points[0])
        guard points.count > 2 else { points.dropFirst().forEach { path.addLine(to: $0) }; return path }
        for i in 0..<(points.count - 1) {
            let p0 = points[max(i - 1, 0)], p1 = points[i], p2 = points[i + 1], p3 = points[min(i + 2, points.count - 1)]
            let c1 = CGPoint(x: p1.x + (p2.x - p0.x) / 6, y: p1.y + (p2.y - p0.y) / 6)
            let c2 = CGPoint(x: p2.x - (p3.x - p1.x) / 6, y: p2.y - (p3.y - p1.y) / 6)
            path.addCurve(to: p2, control1: c1, control2: c2)
        }
        return path
    }

    /// The ink of a photographed or sketched signature: pixels clearly darker than the paper keep their darkness as
    /// opacity in the ink colour; the paper becomes transparent. Nil when there is no ink.
    static func extract(from image: CGImage) -> Data? {
        // Work at most 1600 px wide: plenty for a signature, quick for a camera frame.
        let scale = min(1, 1600 / CGFloat(max(image.width, 1)))
        let width = max(Int(CGFloat(image.width) * scale), 1), height = max(Int(CGFloat(image.height) * scale), 1)
        guard let gray = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width,
                                   space: CGColorSpaceCreateDeviceGray(), bitmapInfo: CGImageAlphaInfo.none.rawValue) else { return nil }
        gray.setFillColor(CGColor(gray: 1, alpha: 1))
        gray.fill(CGRect(x: 0, y: 0, width: width, height: height))
        gray.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
        guard let pixels = gray.data?.assumingMemoryBound(to: UInt8.self) else { return nil }
        let count = width * height

        // The paper is the bright majority: its level is a high percentile; ink is what sits well below it.
        var histogram = [Int](repeating: 0, count: 256)
        for i in 0..<count { histogram[Int(pixels[i])] += 1 }
        var seen = 0, paper = 255
        for level in stride(from: 255, through: 0, by: -1) {
            seen += histogram[level]
            if seen >= count / 4 { paper = level; break }
        }
        let threshold = Double(paper) * 0.62, soft = max(Double(paper) * 0.18, 8)

        guard let out = rgbaContext(width: width, height: height), let outPixels = out.data?.assumingMemoryBound(to: UInt8.self) else { return nil }
        let rowBytes = out.bytesPerRow, grayRow = gray.bytesPerRow
        var inked = 0
        let components = color.components ?? [0, 0, 0, 1]
        for y in 0..<height {
            for x in 0..<width {
                let level = Double(pixels[y * grayRow + x])
                let alpha = max(0, min(1, (threshold + soft - level) / (2 * soft)))
                guard alpha > 0.02 else { continue }
                inked += 1
                let p = y * rowBytes + x * 4
                // Premultiplied RGBA.
                outPixels[p] = UInt8(components[0] * alpha * 255)
                outPixels[p + 1] = UInt8(components[1] * alpha * 255)
                outPixels[p + 2] = UInt8(components[2] * alpha * 255)
                outPixels[p + 3] = UInt8(alpha * 255)
            }
        }
        // Mostly dark means the paper wasn't lit or nothing was held up.
        guard inked > 20, inked < count / 3, let result = out.makeImage(), let trimmed = trim(result, padding: 8) else { return nil }
        return pngData(trimmed)
    }

    /// `image` cropped to its non-transparent pixels plus `padding`; nil when it is empty.
    static func trim(_ image: CGImage, padding: Int) -> CGImage? {
        guard let context = rgbaContext(width: image.width, height: image.height) else { return nil }
        context.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
        guard let pixels = context.data?.assumingMemoryBound(to: UInt8.self) else { return nil }
        let row = context.bytesPerRow
        var minX = Int.max, minY = Int.max, maxX = -1, maxY = -1
        for y in 0..<image.height {
            for x in 0..<image.width where pixels[y * row + x * 4 + 3] > 8 {
                minX = min(minX, x); maxX = max(maxX, x); minY = min(minY, y); maxY = max(maxY, y)
            }
        }
        guard maxX >= minX, maxY >= minY else { return nil }
        // Bitmap rows run top-down in memory; cropping uses the same top-left origin.
        let crop = CGRect(x: max(minX - padding, 0), y: max(minY - padding, 0),
                          width: min(maxX + padding, image.width - 1) - max(minX - padding, 0) + 1,
                          height: min(maxY + padding, image.height - 1) - max(minY - padding, 0) + 1)
        return context.makeImage()?.cropping(to: crop)
    }

    static func pngData(_ image: CGImage) -> Data? {
        let data = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(data, UTType.png.identifier as CFString, 1, nil) else { return nil }
        CGImageDestinationAddImage(destination, image, nil)
        return CGImageDestinationFinalize(destination) ? data as Data : nil
    }

    static func rgbaContext(width: Int, height: Int) -> CGContext? {
        CGContext(data: nil, width: max(width, 1), height: max(height, 1), bitsPerComponent: 8, bytesPerRow: 0,
                  space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
    }
}
