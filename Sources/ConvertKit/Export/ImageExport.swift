import CoreGraphics
import Foundation
import ImageIO
import PDFModelKit
import RenderKit
import SuperPDFCore

/// PDF → pictures (features #53): pages rendered at the chosen resolution as PNG, JPEG, TIFF or HEIC, one file per page
/// ("Report – page 3.png") or one multi-page TIFF; or "the pictures inside" pulled out at their own resolution (JPEG and
/// JPEG 2000 bytes as they are, the rest as PNG).
enum ImageExport {
    static func export(_ source: PDFSource, options: ExportOptions, folder: URL, baseName: String, progress: ToolProgress) throws -> [URL] {
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        return options.embeddedPictures
            ? try embedded(source, pages: options.pages, folder: folder, baseName: baseName, progress: progress)
            : try pages(source, options: options, folder: folder, baseName: baseName, progress: progress)
    }

    static func fileExtension(_ format: ImageFormat) -> String {
        switch format {
        case .jpeg: "jpg"
        case .tiff: "tiff"
        default: format.rawValue
        }
    }

    private static func pages(_ source: PDFSource, options: ExportOptions, folder: URL, baseName: String, progress: ToolProgress) throws -> [URL] {
        guard let format = ImageFormat(rawValue: options.format.rawValue) else { throw ConvertError.unsupported(options.format.rawValue) }
        guard ImageEncoder.supportedFormats.contains(format) else { throw RenderError.unsupportedFormat(format) }
        let document = try PDFPages.open(source)
        let indices = options.pages.isEmpty ? Array(0..<document.numberOfPages) : options.pages
        var files: [URL] = []
        var frames: [CGImage] = []
        for (done, index) in indices.enumerated() {
            try Task.checkCancellation()
            let image = try Rasterizer.render(try PDFPages.page(document, at: index), dpi: options.dpi)
            if format == .tiff && options.multiPageTIFF {
                frames.append(image)
            } else {
                let file = folder.appendingPathComponent("\(baseName) – \(ExportStrings.page) \(index + 1).\(fileExtension(format))")
                try ImageEncoder.encode(image, format: format, quality: options.quality, dpi: options.dpi).write(to: file)
                files.append(file)
            }
            progress.report(completed: done + 1, of: indices.count, page: index)
        }
        if !frames.isEmpty {
            let file = folder.appendingPathComponent("\(baseName).tiff")
            try ImageEncoder.encode(frames, format: .tiff, quality: options.quality, dpi: options.dpi).write(to: file)
            files.append(file)
        }
        return files
    }

    private static func embedded(_ source: PDFSource, pages: [Int], folder: URL, baseName: String, progress: ToolProgress) throws -> [URL] {
        let model = try PDFModel(source)
        let indices = pages.isEmpty ? Array(0..<model.pageCount) : pages
        var seen: Set<Int> = []
        var files: [URL] = []
        for (done, index) in indices.enumerated() {
            try Task.checkCancellation()
            guard let page = model.page(at: index) else { continue }
            var number = 0
            for image in page.imageXObjects() where !image.isMask && image.width >= 16 && image.height >= 16 {
                if let id = image.object.objectID { guard seen.insert(id).inserted else { continue } }
                guard let (data, ext) = encoded(image) else { continue }
                number += 1
                let file = folder.appendingPathComponent("\(baseName) – \(ExportStrings.page) \(index + 1) – \(ExportStrings.picture) \(number).\(ext)")
                try data.write(to: file)
                files.append(file)
            }
            progress.report(completed: done + 1, of: indices.count, page: index)
        }
        return files
    }

    /// The picture's bytes as a file: JPEG and JPEG 2000 unchanged, 8-bit grey/RGB/CMYK and palette pictures as PNG.
    private static func encoded(_ image: PDFImageXObject) -> (Data, String)? {
        if image.filters.last == "DCTDecode", let data = try? image.encodedData() { return (data, "jpg") }
        if image.filters.last == "JPXDecode", let data = try? image.encodedData() { return (data, "jp2") }
        guard image.bitsPerComponent == 8, let samples = try? image.samples(),
              let cgImage = picture(samples, width: image.width, height: image.height, colorSpace: image.colorSpace, model: image.object.model),
              let png = try? ImageEncoder.encode(cgImage, format: .png) else { return nil }
        return (png, "png")
    }

    private static func picture(_ samples: Data, width: Int, height: Int, colorSpace: PDFValue?, model: PDFModel) -> CGImage? {
        var space = colorSpace
        if let reference = space?.referenceValue { space = model.object(id: reference.id, generation: reference.generation).value }
        var components: Int
        var cgSpace: CGColorSpace
        var palette: Data?
        switch space?.nameValue ?? space?.arrayValue?.first?.nameValue {
        case "DeviceGray", "CalGray": components = 1; cgSpace = CGColorSpaceCreateDeviceGray()
        case "DeviceRGB", "CalRGB", "Lab": components = 3; cgSpace = CGColorSpace(name: CGColorSpace.sRGB)!
        case "DeviceCMYK": components = 4; cgSpace = CGColorSpaceCreateDeviceCMYK()
        case "ICCBased":
            let parts = space?.arrayValue ?? []
            let stream = (parts.count > 1 ? parts[1].referenceValue : nil).map { model.object(id: $0.id, generation: $0.generation) }
            let n = stream?.streamDictionary?["N"]?.int ?? 3
            components = n
            cgSpace = n == 1 ? CGColorSpaceCreateDeviceGray() : n == 4 ? CGColorSpaceCreateDeviceCMYK() : CGColorSpace(name: CGColorSpace.sRGB)!
        case "Indexed":
            // [/Indexed base hival lookup]: expand to RGB when the base is RGB.
            guard let array = space?.arrayValue, array.count == 4 else { return nil }
            var lookup = array[3].stringValue
            if lookup == nil, let reference = array[3].referenceValue {
                lookup = try? model.object(id: reference.id, generation: reference.generation).streamData(decode: .all)
            }
            guard let table = lookup, array[1].nameValue == "DeviceRGB" || array[1].arrayValue != nil else { return nil }
            palette = table
            components = 3; cgSpace = CGColorSpace(name: CGColorSpace.sRGB)!
        default:
            return nil
        }
        var bytes = samples
        if let palette {
            let table = [UInt8](palette)
            var rgb = Data(capacity: width * height * 3)
            for index in samples.prefix(width * height) {
                let at = Int(index) * 3
                rgb.append(contentsOf: at + 2 < table.count ? table[at...at + 2] : [0, 0, 0])
            }
            bytes = rgb
        }
        guard bytes.count >= width * height * components, let provider = CGDataProvider(data: bytes as CFData) else { return nil }
        return CGImage(width: width, height: height, bitsPerComponent: 8, bitsPerPixel: 8 * components, bytesPerRow: width * components,
                       space: cgSpace, bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.none.rawValue), provider: provider,
                       decode: nil, shouldInterpolate: false, intent: .defaultIntent)
    }
}

enum ExportStrings {
    /// File names: "Report – page 3.png", "Report – page 3 – picture 1.jpg".
    static let page = "page"
    static let picture = "picture"
}
