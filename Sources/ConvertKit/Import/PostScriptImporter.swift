import CoreGraphics
import Foundation
import SuperPDFCore

/// PostScript and EPS → PDF through Quartz's PostScript converter, when this macOS still has a working one (features §5:
/// "convert through Quartz only when macOS can rasterize them; otherwise LibreOffice"). Recent macOS versions keep
/// the API but produce nothing, so availability is probed once with a one-line document.
enum PostScriptImporter {
    static let isAvailable: Bool = {
        let probe = "%!PS-Adobe-3.0\n%%BoundingBox: 0 0 72 72\nnewpath 0 0 moveto 72 72 lineto stroke showpage\n"
        return (try? convert(Data(probe.utf8)).isEmpty == false) ?? false
    }()

    static func convert(_ input: URL, to output: URL, options: ImportOptions) throws -> ImportReport {
        let pdf = try convert(try Data(contentsOf: input))
        guard !pdf.isEmpty else { throw ConvertError.unsupported("PostScript") }
        try pdf.write(to: output)
        return ImportReport()
    }

    private static func convert(_ postScript: Data) throws -> Data {
        var callbacks = CGPSConverterCallbacks(version: 0, beginDocument: nil, endDocument: nil, beginPage: nil, endPage: nil,
                                               noteProgress: nil, noteMessage: nil, releaseInfo: nil)
        guard let converter = CGPSConverter(info: nil, callbacks: &callbacks, options: nil),
              let provider = CGDataProvider(data: postScript as CFData) else { throw ConvertError.unsupported("PostScript") }
        let out = NSMutableData()
        guard let consumer = CGDataConsumer(data: out as CFMutableData), converter.convert(provider, consumer: consumer, options: nil) else {
            throw ConvertError.unsupported("PostScript")
        }
        return out as Data
    }
}
