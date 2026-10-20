import CoreGraphics
import Foundation
import ImageIO
import SuperPDFCore

/// Re-rendered PDF output through Quartz contexts (features #56–58, #96).
///
/// PDF/A: Quartz's `kCGPDFContextCreatePDFA` writes a PDF/A-2B file (sRGB OutputIntent, fonts embedded, XMP with
/// `pdfaid:part 2 / conformance B`). The requested `PDFALevel` is kept by the caller through QPDF (features #56:
/// "QPDF for XMP/outline/attachments"): the re-render here is the same for every level, and the "a" levels' tags come
/// back from the structure tree the caller copies.
///
/// Colour conversion and transparency flattening are rasterizations: Quartz does not re-colour drawn content, so pages
/// become images in the target space at the given dpi (as Acrobat's flattener does for the affected regions).
public enum PDFOutput {
    // MARK: PDF/A

    public static func writePDFA(_ source: PDFSource, to destination: URL) throws {
        let document = try PDFPages.open(source)
        var info = PDFPages.metadata(document)
        info[kCGPDFContextCreatePDFA] = true
        info[kCGPDFContextOutputIntent] = outputIntent(subtype: "GTS_PDFA1", profile: CGColorSpace(name: CGColorSpace.sRGB)!.copyICCData()! as Data, identifier: "sRGB IEC61966-2.1")
        try PDFWriter.write(to: destination, info: info, pages: passThroughPages(document))
    }

    // MARK: PDF/X

    /// X-4 keeps the pages as drawn with a `GTS_PDFX` OutputIntent and the trim/bleed boxes; X-1a also rasterizes pages
    /// that use RGB into the output CMYK (`ColorUsage` decides), since X-1a allows no RGB. Quartz has no PDF/X flag
    /// (only `kCGPDFContextCreatePDFA`) and embeds the intent's ICC stream (`DestOutputProfile`) only in PDF/A
    /// contexts, so the `pdfxid` XMP and the profile stream are the caller's QPDF step, as the PDF/A levels are.
    public static func writePDFX(_ source: PDFSource, level: PDFXLevel, outputIntent profileURL: URL?, to destination: URL) throws {
        let document = try PDFPages.open(source)
        let profile: Data
        if let profileURL {
            profile = try Data(contentsOf: profileURL)
            guard CGColorSpace(iccData: profile as CFData) != nil else { throw RenderError.badProfile }
        } else {
            profile = CGColorSpace(name: CGColorSpace.genericCMYK)!.copyICCData()! as Data
        }
        let space = CGColorSpace(iccData: profile as CFData)
        var info = PDFPages.metadata(document)
        info[kCGPDFContextOutputIntent] = outputIntent(subtype: "GTS_PDFX", profile: profile, identifier: profileURL?.deletingPathExtension().lastPathComponent ?? "Generic CMYK")
        var pages: [PDFWriter.Page] = []
        for index in 0..<document.numberOfPages {
            let page = try PDFPages.page(document, at: index)
            let size = PDFPages.displayedSize(page)
            var pageInfo: [CFString: Any] = [:]
            if let trim = PDFPages.displayedBox(.trimBox, of: page) { pageInfo[kCGPDFContextTrimBox] = PDFWriter.boxData(trim) }
            if let bleed = PDFPages.displayedBox(.bleedBox, of: page) { pageInfo[kCGPDFContextBleedBox] = PDFWriter.boxData(bleed) }
            if level == .x1a, ColorUsage.scan(page).usesRGB {
                pages.append(PDFWriter.Page(size: size, info: pageInfo) { context in
                    let image = try Rasterizer.render(page, pixelSize: pixelSize(size, dpi: 300), colorSpace: .cmyk).converted(to: space)
                    context.draw(image, in: CGRect(origin: .zero, size: size))
                })
            } else {
                pages.append(PDFWriter.Page(size: size, info: pageInfo) { context in PDFPages.draw(page, in: context, fitting: CGRect(origin: .zero, size: size)) })
            }
        }
        try PDFWriter.write(to: destination, info: info, pages: pages)
    }

    // MARK: Print as image, convert colours

    /// Every page as a JPEG raster at `dpi` on a page of the original size (features #58).
    public static func printAsImage(_ source: PDFSource, dpi: Double, to destination: URL) throws {
        let document = try PDFPages.open(source)
        var pages: [PDFWriter.Page] = []
        for index in 0..<document.numberOfPages {
            let page = try PDFPages.page(document, at: index)
            let size = PDFPages.displayedSize(page)
            pages.append(PDFWriter.Page(size: size) { context in
                let raster = try Rasterizer.render(page, pixelSize: pixelSize(size, dpi: dpi), colorSpace: .sRGB)
                // JPEG bytes pass straight into the PDF (DCTDecode) instead of a Flate bitmap.
                let jpeg = try ImageEncoder.encode(raster, format: .jpeg, quality: 0.9, dpi: dpi)
                guard let provider = CGDataProvider(data: jpeg as CFData), let image = CGImage(jpegDataProviderSource: provider, decode: nil, shouldInterpolate: true, intent: .defaultIntent) else { throw RenderError.cannotCreateContext }
                context.draw(image, in: CGRect(origin: .zero, size: size))
            })
        }
        try PDFWriter.write(to: destination, info: PDFPages.metadata(document), pages: pages)
    }

    /// Pages rasterized in the target space (ColorSync) at `dpi` (300 when nil), with an OutputIntent for the profile.
    public static func convertColors(_ source: PDFSource, to colorSpace: RenderColorSpace, profile profileURL: URL?, flattenTransparencyAt dpi: Double?, to destination: URL) throws {
        let document = try PDFPages.open(source)
        let space: CGColorSpace
        if let profileURL {
            guard let iccSpace = CGColorSpace(iccData: try Data(contentsOf: profileURL) as CFData) else { throw RenderError.badProfile }
            space = iccSpace
        } else {
            switch colorSpace {
            case .sRGB: space = CGColorSpace(name: CGColorSpace.sRGB)!
            case .gray: space = CGColorSpace(name: CGColorSpace.genericGrayGamma2_2)!
            case .cmyk: space = CGColorSpace(name: CGColorSpace.genericCMYK)!
            }
        }
        var info = PDFPages.metadata(document)
        if let profile = space.copyICCData() as Data? {
            info[kCGPDFContextOutputIntent] = outputIntent(subtype: colorSpace == .cmyk ? "GTS_PDFX" : "GTS_PDFA1", profile: profile,
                                                           identifier: profileURL?.deletingPathExtension().lastPathComponent ?? colorSpace.rawValue)
        }
        let resolution = dpi ?? 300
        var pages: [PDFWriter.Page] = []
        for index in 0..<document.numberOfPages {
            let page = try PDFPages.page(document, at: index)
            let size = PDFPages.displayedSize(page)
            pages.append(PDFWriter.Page(size: size) { context in
                let pixels = pixelSize(size, dpi: resolution)
                let bitmap = try Rasterizer.bitmapContext(width: Int(pixels.width), height: Int(pixels.height), colorSpace: colorSpace, space: space)
                bitmap.interpolationQuality = CGInterpolationQuality.high
                PDFPages.draw(page, in: bitmap, fitting: CGRect(origin: .zero, size: pixels))
                guard let image = bitmap.makeImage() else { throw RenderError.cannotCreateContext }
                context.draw(image, in: CGRect(origin: .zero, size: size))
            })
        }
        try PDFWriter.write(to: destination, info: info, pages: pages)
    }

    // MARK: Helpers

    static func pixelSize(_ size: CGSize, dpi: Double) -> CGSize {
        CGSize(width: max((size.width * dpi / 72).rounded(), 1), height: max((size.height * dpi / 72).rounded(), 1))
    }

    static func passThroughPages(_ document: CGPDFDocument) throws -> [PDFWriter.Page] {
        try (0..<document.numberOfPages).map { index in
            let page = try PDFPages.page(document, at: index)
            let size = PDFPages.displayedSize(page)
            return PDFWriter.Page(size: size) { context in PDFPages.draw(page, in: context, fitting: CGRect(origin: .zero, size: size)) }
        }
    }

    static func outputIntent(subtype: String, profile: Data, identifier: String) -> [CFString: Any] {
        [kCGPDFXOutputIntentSubtype: subtype, kCGPDFXOutputConditionIdentifier: identifier, kCGPDFXRegistryName: "http://www.color.org",
         kCGPDFXInfo: identifier, kCGPDFXDestinationOutputProfile: profile as CFData]
    }
}

private extension CGImage {
    /// The same pixels tagged with `space` when it matches the image's model (an ICC CMYK profile for a CMYK raster).
    func converted(to space: CGColorSpace?) -> CGImage {
        guard let space, space.model == colorSpace?.model, let tagged = copy(colorSpace: space) else { return self }
        return tagged
    }
}
