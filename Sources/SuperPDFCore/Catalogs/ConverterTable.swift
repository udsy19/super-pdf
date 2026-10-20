import Foundation

// The conversion registry as data (features §3.2 table; §1.3 #34–#49, §1.4 #50–#59, §5 PostScript). Each route lists
// its engines in ranking order; ConvertKit runs the first one available on this Mac and offers a better one when it can
// be installed. Inputs are lower-case file extensions.

public enum ConverterTable {
    /// Into PDF.
    public static let toPDF: [ConverterRoute] = [
        ConverterRoute(["docx", "doc"], [.builtIn(.attributedText), .libreOffice, .app(.word)],
                       note: "Built in: good for letters, reports and theses; loses text boxes, floating images, footnote layout and tracked changes."),
        ConverterRoute(["odt", "rtf", "rtfd", "txt", "wordml"], [.builtIn(.attributedText), .libreOffice]),
        ConverterRoute(["html", "htm", "webarchive"], [.builtIn(.webKit), .libreOffice], note: "HTML renders with WebKit, not TextKit (#41)."),
        ConverterRoute(["xlsx"], [.builtIn(.spreadsheet), .libreOffice, .app(.excel)], note: "Built in: no charts."),
        ConverterRoute(["xls"], [.libreOffice, .app(.excel)], note: "Binary BIFF is not worth a native reader."),
        ConverterRoute(["pptx"], [.builtIn(.presentation), .libreOffice, .app(.powerPoint), .app(.keynote)],
                       note: "Built in: text, images, basic shapes, backgrounds; no animations or SmartArt."),
        ConverterRoute(["ppt"], [.libreOffice, .app(.powerPoint)]),
        ConverterRoute(["ods", "odp"], [.libreOffice], note: "LibreOffice's own formats."),
        ConverterRoute(["pages"], [.app(.pages), .builtIn(.iWorkPreview)], note: "LibreOffice has no iWork import."),
        ConverterRoute(["numbers"], [.app(.numbers), .builtIn(.iWorkPreview)]),
        ConverterRoute(["key"], [.app(.keynote), .builtIn(.iWorkPreview)]),
        ConverterRoute(["hwp"], [.libreOffice], note: "LibreOffice's Hangul import filter (HWP 3 and 5)."),
        ConverterRoute(["hwpx"], [.libreOffice, .builtIn(.hwpx)]),
        ConverterRoute(["epub"], [.builtIn(.epub), .libreOffice]),
        ConverterRoute(["md", "markdown"], [.builtIn(.markdown)]),
        ConverterRoute(["csv", "tsv"], [.builtIn(.delimitedText)]),
        ConverterRoute(["json", "xml"], [.builtIn(.structuredText)]),
        ConverterRoute(["zip"], [.builtIn(.zip)]),
        ConverterRoute(["jpg", "jpeg", "png", "heic", "heif", "tif", "tiff", "gif", "bmp", "webp", "psd", "dng", "cr2", "cr3", "nef", "arw",
                        "raf", "orf", "rw2"], [.builtIn(.images)], note: "PSD flattened; multi-page TIFF expands."),
        ConverterRoute(["svg"], [.builtIn(.webKit)]),
        ConverterRoute(["eml"], [.builtIn(.mail), .app(.mail)]),
        ConverterRoute(["msg"], [.app(.mail)]),
        ConverterRoute(["ps", "eps"], [.builtIn(.postScript), .libreOffice], note: "Quartz when macOS can rasterize them; else LibreOffice Draw."),
    ]

    /// Anything else: Quick Look's page-one preview with a notice, or "Print to Super PDF" from the owning app.
    public static let fallback: [ConverterEngine] = [.builtIn(.quickLook), .printFromOwningApp]

    /// Out of PDF: always native (features §3.2 "PDF → Office is always native").
    public static let fromPDF: [ConverterRoute] = [
        ConverterRoute(["pdf"], to: .docx, [.builtIn(.wordWriter)]),
        ConverterRoute(["pdf"], to: .rtf, [.builtIn(.wordWriter)]),
        ConverterRoute(["pdf"], to: .xlsx, [.builtIn(.spreadsheetWriter)]),
        ConverterRoute(["pdf"], to: .csv, [.builtIn(.spreadsheetWriter)]),
        ConverterRoute(["pdf"], to: .pptx, [.builtIn(.presentationWriter)]),
        ConverterRoute(["pdf"], to: .png, [.builtIn(.imageExport)]),
        ConverterRoute(["pdf"], to: .jpeg, [.builtIn(.imageExport)]),
        ConverterRoute(["pdf"], to: .tiff, [.builtIn(.imageExport)]),
        ConverterRoute(["pdf"], to: .heic, [.builtIn(.imageExport)]),
        ConverterRoute(["pdf"], to: .webp, [.builtIn(.imageExport)]),
        ConverterRoute(["pdf"], to: .text, [.builtIn(.textExport)]),
        ConverterRoute(["pdf"], to: .html, [.builtIn(.htmlExport)]),
        ConverterRoute(["pdf"], to: .epub, [.builtIn(.epubExport)]),
        ConverterRoute(["pdf"], to: .pdfA, [.builtIn(.pdfAWriter)]),
        ConverterRoute(["pdf"], to: .pdfX, [.builtIn(.pdfXWriter)]),
        ConverterRoute(["pdf"], to: .fdf, [.builtIn(.dataExport)]),
        ConverterRoute(["pdf"], to: .xfdf, [.builtIn(.dataExport)]),
        ConverterRoute(["pdf"], to: .json, [.builtIn(.dataExport)]),
    ]

    /// The ranked engines for a file extension into a format; the fallback for unknown types into PDF.
    public static func engines(forExtension ext: String, to output: ConversionFormat = .pdf) -> [ConverterEngine] {
        let ext = ext.lowercased()
        let routes = output == .pdf ? toPDF : fromPDF.filter { $0.output == output }
        if let route = routes.first(where: { $0.inputs.contains(ext) }) { return route.engines }
        return output == .pdf ? fallback : []
    }
}
