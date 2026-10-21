import CoreGraphics
import Foundation
import QuickLookThumbnailing
import SuperPDFCore

/// Anything else → PDF (features #47): Quick Look's preview of the file, page one only, as a picture, with a notice.
/// Quick Look's generic file icon doesn't count: when there is no real preview the file can't be converted.
enum QuickLookImporter {
    /// The preview's longest side in pixels: sharp on a printed page.
    static let pixels: CGFloat = 2400

    @MainActor
    static func convert(_ input: URL, to output: URL, options: ImportOptions) async throws -> ImportReport {
        let request = QLThumbnailGenerator.Request(fileAt: input, size: CGSize(width: pixels, height: pixels), scale: 1,
                                                   representationTypes: .thumbnail)
        let representation = try await QLThumbnailGenerator.shared.generateBestRepresentation(for: request)
        guard representation.type == .thumbnail else { throw ConvertError.unsupported("no preview") }
        let image = representation.cgImage
        // A preview has no resolution of its own: size the page like a printed page (the long side at A4/Letter height).
        let long = max(CGFloat(image.width), CGFloat(image.height))
        let scale = ImportOptions.localePaper.height / max(long, 1)
        let picture = PagePicture(image: image, naturalSize: CGSize(width: CGFloat(image.width) * scale, height: CGFloat(image.height) * scale))
        try PicturePages.write([picture], paper: options.paper, margins: CGFloat(options.margins), to: output, title: String.baseName(input))
        return ImportReport(notices: [ConvertStrings.quickLookNotice])
    }
}
