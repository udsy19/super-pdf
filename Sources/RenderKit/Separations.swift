import CoreGraphics
import Foundation
import SuperPDFCore

/// Output preview plates (features #95): the page rendered through ColorSync into CMYK, one process channel shown in
/// its own ink on white, and the page's maximum total ink coverage. Spot plates cannot be isolated from a raster, so
/// they are refused (`ColorUsage.spotColors` still names them for the plate list).
public enum Separations {
    public static func plate(_ page: CGPDFPage, plate: Separation, dpi: Double) throws -> (image: CGImage, maxInk: Double) {
        let channel: Int
        switch plate {
        case .cyan: channel = 0
        case .magenta: channel = 1
        case .yellow: channel = 2
        case .black: channel = 3
        case .spot(let name): throw RenderError.unsupportedPlate(name)
        }
        let cmyk = try Rasterizer.render(page, dpi: dpi, colorSpace: .cmyk)
        guard let data = cmyk.dataProvider?.data as Data? else { throw RenderError.cannotCreateContext }
        let width = cmyk.width, height = cmyk.height, bytesPerRow = cmyk.bytesPerRow
        var maxInk = 0
        var pixels = [UInt8](repeating: 255, count: width * height * 4)
        data.withUnsafeBytes { (buffer: UnsafeRawBufferPointer) in
            for y in 0..<height {
                let row = y * bytesPerRow
                for x in 0..<width {
                    let offset = row + x * 4
                    let ink = Int(buffer[offset]) + Int(buffer[offset + 1]) + Int(buffer[offset + 2]) + Int(buffer[offset + 3])
                    if ink > maxInk { maxInk = ink }
                    let value = buffer[offset + channel]
                    let out = (y * width + x) * 4
                    let white = 255 - value
                    switch channel {
                    case 0: pixels[out] = white; pixels[out + 1] = 255; pixels[out + 2] = 255
                    case 1: pixels[out] = 255; pixels[out + 1] = white; pixels[out + 2] = 255
                    case 2: pixels[out] = 255; pixels[out + 1] = 255; pixels[out + 2] = white
                    default: pixels[out] = white; pixels[out + 1] = white; pixels[out + 2] = white
                    }
                    pixels[out + 3] = 255
                }
            }
        }
        guard let provider = CGDataProvider(data: Data(pixels) as CFData),
              let image = CGImage(width: width, height: height, bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: width * 4,
                                  space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue),
                                  provider: provider, decode: nil, shouldInterpolate: true, intent: .defaultIntent) else { throw RenderError.cannotCreateContext }
        return (image, Double(maxInk) * 100 / 255)
    }
}
