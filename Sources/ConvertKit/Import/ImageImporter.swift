import CoreGraphics
import Foundation
import SuperPDFCore

/// Pictures → PDF (features #34): JPG, PNG, HEIC, TIFF (every page of a multi-page TIFF), GIF, BMP, WebP, PSD (flattened)
/// and camera RAW through ImageIO, one page per picture, upright.
enum ImageImporter {
    static func convert(_ input: URL, to output: URL, options: ImportOptions) throws -> ImportReport {
        try convert([input], to: output, options: options)
    }

    /// Several pictures into one PDF, in the order given (Images → PDF keeps the list's order).
    static func convert(_ inputs: [URL], to output: URL, options: ImportOptions) throws -> ImportReport {
        var pictures: [PagePicture] = []
        var report = ImportReport()
        for input in inputs {
            do { pictures += try PicturePages.pictures(from: input) } catch { report.skipped.append(input) }
        }
        guard !pictures.isEmpty else { throw ComposeError.nothingToConvert }
        try PicturePages.write(pictures, paper: options.paper, margins: CGFloat(options.paper == .fitContent ? 0 : options.margins), to: output,
                               title: inputs.count == 1 ? String.baseName(inputs[0]) : nil)
        if !report.skipped.isEmpty { report.notices.append(ConvertStrings.leftOut(report.skipped.map(\.lastPathComponent))) }
        return report
    }

    static let extensions: Set<String> = Set(ConverterTable.toPDF.first { $0.engines == [.builtIn(.images)] }?.inputs ?? [])
}
