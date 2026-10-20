import CoreGraphics
import Foundation
import SuperPDFCore

/// `Services.render`: each call opens the source off the main actor, does its work there and returns values or writes
/// the destination file. Nothing is kept between calls (thumbnails and tiles use `PageImageCache`).
@MainActor
public final class RenderService: Rendering {
    public func rasterize(_ source: PDFSource, pages: [Int], dpi: Double, format: ImageFormat, quality: Double, colorSpace: RenderColorSpace) async throws -> [RasterPage] {
        try await Task.detached(priority: .userInitiated) {
            let document = try PDFPages.open(source)
            var result: [RasterPage] = []
            for index in pages {
                try Task.checkCancellation()
                let image = try Rasterizer.render(try PDFPages.page(document, at: index), dpi: dpi, colorSpace: colorSpace)
                let data = try ImageEncoder.encode(image, format: format, quality: quality, dpi: dpi)
                result.append(RasterPage(index: index, data: data, pixelSize: CGSize(width: image.width, height: image.height)))
            }
            return result
        }.value
    }

    public func writePDFA(_ source: PDFSource, level: PDFALevel, to destination: URL) async throws {
        try await Task.detached(priority: .userInitiated) { try PDFOutput.writePDFA(source, to: destination) }.value
    }

    public func writePDFX(_ source: PDFSource, level: PDFXLevel, outputIntent: URL?, to destination: URL) async throws {
        try await Task.detached(priority: .userInitiated) { try PDFOutput.writePDFX(source, level: level, outputIntent: outputIntent, to: destination) }.value
    }

    public func impose(_ source: PDFSource, layout: Imposition, paper: PaperSize, to destination: URL) async throws {
        try await Task.detached(priority: .userInitiated) { try Imposer.impose(source, layout: layout, paper: paper, to: destination) }.value
    }

    public func printAsImage(_ source: PDFSource, dpi: Double, to destination: URL) async throws {
        try await Task.detached(priority: .userInitiated) { try PDFOutput.printAsImage(source, dpi: dpi, to: destination) }.value
    }

    public func convertColors(_ source: PDFSource, to colorSpace: RenderColorSpace, profile: URL?, flattenTransparencyAt dpi: Double?, to destination: URL) async throws {
        try await Task.detached(priority: .userInitiated) {
            try PDFOutput.convertColors(source, to: colorSpace, profile: profile, flattenTransparencyAt: dpi, to: destination)
        }.value
    }

    public func separation(_ source: PDFSource, page: Int, plate: Separation, dpi: Double) async throws -> (image: RasterPage, maxInk: Double) {
        try await Task.detached(priority: .userInitiated) {
            let document = try PDFPages.open(source)
            let result = try Separations.plate(try PDFPages.page(document, at: page), plate: plate, dpi: dpi)
            let data = try ImageEncoder.encode(result.image, format: .png, dpi: dpi)
            return (RasterPage(index: page, data: data, pixelSize: CGSize(width: result.image.width, height: result.image.height)), result.maxInk)
        }.value
    }
}
