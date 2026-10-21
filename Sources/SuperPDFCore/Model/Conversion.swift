import CoreGraphics
import Foundation

// Conversions in and out of PDF (features §1.3, §1.4, §3.2): the ranked engines per route, jobs and the helper.

/// What a conversion produces.
public enum ConversionFormat: String, Codable, CaseIterable, Sendable {
    case pdf, pdfA = "pdf-a", pdfX = "pdf-x"
    case docx, rtf, xlsx, csv, pptx
    case png, jpeg, tiff, heic, webp
    case text, html, epub
    /// Comments and form data (features #59).
    case fdf, xfdf, json
}

/// Apps on this Mac that can export a file as PDF through Apple Events (features §3.2 "App automation").
public enum OfficeApp: String, Codable, CaseIterable, Sendable {
    case word, excel, powerPoint, pages, numbers, keynote, mail

    /// The name people see ("Pages will open to export this file").
    public var name: String {
        switch self {
        case .word: "Microsoft Word"
        case .excel: "Microsoft Excel"
        case .powerPoint: "Microsoft PowerPoint"
        case .pages: "Pages"
        case .numbers: "Numbers"
        case .keynote: "Keynote"
        case .mail: "Mail"
        }
    }

    public var bundleIdentifier: String {
        switch self {
        case .word: "com.microsoft.Word"
        case .excel: "com.microsoft.Excel"
        case .powerPoint: "com.microsoft.Powerpoint"
        case .pages: "com.apple.iWork.Pages"
        case .numbers: "com.apple.iWork.Numbers"
        case .keynote: "com.apple.iWork.Keynote"
        case .mail: "com.apple.mail"
        }
    }
}

/// The converters written in this repository or provided by macOS (features §3.2 "1st: built in", §1.4).
public enum BuiltInConverter: String, Codable, CaseIterable, Sendable {
    // Into PDF
    /// NSAttributedString import + TextKit pagination (docx, doc, odt, rtf, rtfd, txt, wordml).
    case attributedText
    /// WebKit rendering (html, webarchive, svg, mail bodies).
    case webKit
    /// Own OOXML spreadsheet reader rendered as tables.
    case spreadsheet
    /// Own OOXML presentation reader.
    case presentation
    /// The preview inside an iWork package (often the first page only).
    case iWorkPreview
    /// Own basic `.hwpx` reader.
    case hwpx
    /// Own EPUB reader, chapters rendered with WebKit, outline per chapter.
    case epub
    /// Markdown → HTML → WebKit.
    case markdown
    /// CSV/TSV with delimiter and encoding detection, header row repeated per page.
    case delimitedText
    /// JSON and XML pretty-printed.
    case structuredText
    /// Unzip and convert each supported file, combined in name order with a bookmark per file.
    case zip
    /// ImageIO, one page per image (multi-page TIFF expands).
    case images
    /// Headers, body and attachments of `.eml`.
    case mail
    /// PostScript and EPS through Quartz, when macOS can rasterize them.
    case postScript
    /// Quick Look's preview image, page one only, with a notice.
    case quickLook
    // Out of PDF (features §1.4), always native
    case wordWriter, spreadsheetWriter, presentationWriter, imageExport, textExport, htmlExport, epubExport
    case pdfAWriter, pdfXWriter, dataExport
}

/// One way to convert, in ranking order (features §3.2).
public enum ConverterEngine: Codable, Hashable, Sendable {
    case builtIn(BuiltInConverter)
    /// The LibreOffice helper, when the person has installed it; never bundled.
    case libreOffice
    /// The owning app on this Mac, driven with Apple Events (it opens briefly).
    case app(OfficeApp)
    /// No converter: "Print to Super PDF" from the owning app (features #48).
    case printFromOwningApp
}

/// A row of the registry: inputs (lower-case file extensions), the output, and the engines in order of preference.
public struct ConverterRoute: Hashable, Sendable {
    public var inputs: [String]
    public var output: ConversionFormat
    public var engines: [ConverterEngine]
    /// The table's note column.
    public var note: String?

    public init(_ inputs: [String], to output: ConversionFormat = .pdf, _ engines: [ConverterEngine], note: String? = nil) {
        self.inputs = inputs; self.output = output; self.engines = engines; self.note = note
    }
}

/// Whether an engine can run on this Mac right now (ConvertKit decides; the panel's engine line says it).
public enum ConverterAvailability: Hashable, Sendable {
    case available
    /// LibreOffice isn't installed: the panel explains and offers "Get LibreOffice".
    case needsLibreOffice
    /// The app isn't installed ("Pages is free on the Mac App Store").
    case needsApp(OfficeApp)
    case unavailable
}

/// A ranked engine with its availability, as `Converting.converters(for:to:)` answers.
public struct ConverterOffer: Hashable, Sendable {
    public var engine: ConverterEngine
    public var availability: ConverterAvailability

    public init(engine: ConverterEngine, availability: ConverterAvailability) { self.engine = engine; self.availability = availability }
}

/// Paper choices of Images → PDF / Any file → PDF / text pagination (ux §5.3).
public enum PaperSize: Codable, Hashable, Sendable {
    /// Each page takes the size of its picture.
    case fitContent
    case a4, letter, legal, a3
    case custom(width: Double, height: Double)

    /// Points; nil for `fitContent`.
    public var size: CGSize? {
        switch self {
        case .fitContent: nil
        case .a4: CGSize(width: 595.28, height: 841.89)
        case .letter: CGSize(width: 612, height: 792)
        case .legal: CGSize(width: 612, height: 1008)
        case .a3: CGSize(width: 841.89, height: 1190.55)
        case .custom(let width, let height): CGSize(width: width, height: height)
        }
    }
}

/// One conversion: files in, one format out (features §1.3, §1.4).
public struct ConversionJob: Codable, Hashable, Sendable {
    public var inputs: [URL]
    public var output: ConversionFormat
    /// Force an engine (the panel's "Use LibreOffice" / "Use the built-in converter"); nil takes the best available.
    public var engine: ConverterEngine?
    public var paper: PaperSize
    /// Margins in points for paginated text and images on a fixed paper size.
    public var margins: Double
    /// PDF → Office: keep the page look (positioned text boxes) instead of flowing text (ux §5.3 To Word).
    public var keepLayout: Bool
    /// Pages to convert out of a PDF (0-based); empty means all.
    public var pages: [Int]
    /// Raster outputs: dots per inch and JPEG/HEIC quality 0…1.
    public var dpi: Double
    public var quality: Double
    /// Where the result goes (a file, or a folder for one-file-per-page outputs).
    public var destination: URL

    public init(inputs: [URL], output: ConversionFormat, engine: ConverterEngine? = nil, paper: PaperSize = .fitContent, margins: Double = 36,
                keepLayout: Bool = true, pages: [Int] = [], dpi: Double = 150, quality: Double = 0.85, destination: URL) {
        self.inputs = inputs; self.output = output; self.engine = engine; self.paper = paper; self.margins = margins
        self.keepLayout = keepLayout; self.pages = pages; self.dpi = dpi; self.quality = quality; self.destination = destination
    }
}

/// What a conversion did.
public struct ConversionResult: Hashable, Sendable {
    public var outputs: [URL]
    public var engine: ConverterEngine
    /// Inputs skipped (ZIP members, unknown types), listed in the notice.
    public var skipped: [URL]
    /// Notices the panel or banner shows ("Only the first page could be used").
    public var notices: [String]

    public init(outputs: [URL], engine: ConverterEngine, skipped: [URL] = [], notices: [String] = []) {
        self.outputs = outputs; self.engine = engine; self.skipped = skipped; self.notices = notices
    }
}

/// The LibreOffice helper (features §3.2): an installed copy, detected; never bundled or installed by Super PDF.
public enum HelperStatus: Hashable, Sendable {
    case notInstalled
    /// `at` is the `soffice` executable that runs headless.
    case installed(at: URL, version: String?)
}
