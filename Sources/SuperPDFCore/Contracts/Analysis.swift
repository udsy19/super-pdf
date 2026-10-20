import CoreGraphics
import Foundation

// The shared analysis modules: LayoutKit (`Services.layout`, features §2.4) and RenderKit (`Services.render`, features
// §1.4, §1.9). Both work off the main actor on `PDFSource` bytes and hand back values. Feature modules may also import
// them directly to use their engines off the main actor.

/// Text and layout analysis (LayoutKit).
@MainActor
public protocol LayoutAnalyzing: AnyObject {
    /// Analyses `pages` (0-based; nil for all), running Vision first on pages the options say need it.
    func analyze(_ source: PDFSource, pages: [Int]?, options: LayoutOptions) async throws -> LayoutDocument
    /// Analyses OCR output for one page (the scan and OCR paths that already ran Vision).
    func analyze(recognized lines: [RecognizedLine], pageIndex: Int, pageSize: CGSize, options: LayoutOptions) async -> LayoutPage
}

/// Raster formats for page images (features #53).
public enum ImageFormat: String, Codable, CaseIterable, Sendable {
    case png, jpeg, tiff, heic, webp
}

/// Colour of a rendering or a conversion target (features #96).
public enum RenderColorSpace: String, Codable, Sendable {
    case sRGB, gray, cmyk
}

/// A rendered page.
public struct RasterPage: Sendable {
    public var index: Int
    /// Encoded in the requested format.
    public var data: Data
    public var pixelSize: CGSize

    public init(index: Int, data: Data, pixelSize: CGSize) { self.index = index; self.data = data; self.pixelSize = pixelSize }
}

/// PDF/A conformance levels (features #56). The "a" levels need a tagged file.
public enum PDFALevel: String, Codable, CaseIterable, Sendable {
    case a1b = "1b", a2b = "2b", a2u = "2u", a3b = "3b", a1a = "1a", a2a = "2a", a3a = "3a"

    public var title: String { "PDF/A-\(rawValue)" }
    public var requiresTags: Bool { rawValue.hasSuffix("a") }
}

/// PDF/X basics (features #57).
public enum PDFXLevel: String, Codable, CaseIterable, Sendable {
    case x1a = "1a", x4 = "4"

    public var title: String { "PDF/X-\(rawValue)" }
}

/// Imposition layouts (features #32, #33; ux §5.3 Booklet).
public enum Imposition: Codable, Hashable, Sendable {
    /// Saddle-stitch order, two pages per side, fold in half.
    case booklet
    /// N pages per sheet (2 or 4 in the panel).
    case nUp(Int)
    /// A grid of every page as thumbnails.
    case contactSheet(columns: Int)
}

/// A colour plate of the output preview (features #95).
public enum Separation: Codable, Hashable, Sendable {
    case cyan, magenta, yellow, black
    case spot(String)
}

/// Rendering and writing through Quartz (RenderKit).
@MainActor
public protocol Rendering: AnyObject {
    /// Page images at `dpi` (72/150/300/600 or custom).
    func rasterize(_ source: PDFSource, pages: [Int], dpi: Double, format: ImageFormat, quality: Double,
                   colorSpace: RenderColorSpace) async throws -> [RasterPage]
    /// Re-renders into a PDF/A context (`kCGPDFContextCreatePDFA`) at `destination`.
    func writePDFA(_ source: PDFSource, level: PDFALevel, to destination: URL) async throws
    /// Writes with an OutputIntent and trim/bleed boxes; X-1a converts RGB to CMYK.
    func writePDFX(_ source: PDFSource, level: PDFXLevel, outputIntent: URL?, to destination: URL) async throws
    /// Booklet, N-up and contact sheets on `paper` (features #32, #33).
    func impose(_ source: PDFSource, layout: Imposition, paper: PaperSize, to destination: URL) async throws
    /// "Print as image": every page rasterized at `dpi` into a new PDF (features #58).
    func printAsImage(_ source: PDFSource, dpi: Double, to destination: URL) async throws
    /// Converts document colours (ColorSync) with an OutputIntent; transparency flattened at `dpi` (features #96).
    func convertColors(_ source: PDFSource, to colorSpace: RenderColorSpace, profile: URL?, flattenTransparencyAt dpi: Double?,
                       to destination: URL) async throws
    /// One plate of a page for the output preview, and the page's maximum total ink coverage in percent (features #95).
    func separation(_ source: PDFSource, page: Int, plate: Separation, dpi: Double) async throws -> (image: RasterPage, maxInk: Double)
}
