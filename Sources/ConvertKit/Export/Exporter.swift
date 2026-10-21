import Foundation
import SuperPDFCore

// Out of PDF (features §1.4 #50–#59): always native. The layout-reading writers (Word, Excel, PowerPoint, text, web
// page, EPUB) get the `LayoutDocument` LayoutKit made for the chosen pages; the others work on the bytes. Everything
// here runs off the main actor.

/// The choices of the To Word / To Excel / To PowerPoint / To images / To text / For archiving panels (ux §5.3).
struct ExportOptions: Sendable {
    var format: ConversionFormat
    /// 0-based pages; empty means every page.
    var pages: [Int] = []
    /// Word: "Keep the look" (text boxes where the text sat) instead of "Flowing text".
    var keepLayout = true
    /// Excel: one sheet per table instead of one per page.
    var oneSheetPerTable = true
    /// PowerPoint: "Editable text over page pictures"; off builds title and body text only.
    var picturesUnderText = true
    /// Images: resolution, JPEG/HEIC quality 0…1, one multi-page TIFF, or the pictures inside instead of the pages.
    var dpi: Double = 150
    var quality: Double = 0.85
    var multiPageTIFF = false
    var embeddedPictures = false
    /// For archiving.
    var pdfALevel: PDFALevel = .a2b
    var pdfXLevel: PDFXLevel = .x4

    /// Whether the format reads the page layout (LayoutKit) first.
    var needsLayout: Bool {
        switch format {
        case .docx, .rtf, .xlsx, .csv, .pptx, .text, .html, .epub: true
        default: false
        }
    }
}

/// What an export wrote.
struct ExportResult: Sendable {
    var outputs: [URL]
    var notices: [String] = []
    /// For archiving: what the PDF/A check still found in the result (empty: it passes).
    var problems: [PDFAProblem] = []
}

/// One finding of the PDF/A check (features #93): a stable rule id, the sentence people read, the pages it concerns.
struct PDFAProblem: Hashable, Sendable {
    var rule: String
    var message: String
    var pages: [Int] = []
}

enum Exporter {
    /// Writes `source` in `options.format`. Single-file formats write `destination`; images write one file per page
    /// into the folder `destination` (created), named "<baseName> – page N.<ext>".
    static func run(_ source: PDFSource, layout: LayoutDocument?, options: ExportOptions, destination: URL, baseName: String,
                    progress: ToolProgress) async throws -> ExportResult {
        let layout = layout ?? LayoutDocument(pages: [])
        return try await Task.detached(priority: .userInitiated) {
            switch options.format {
            case .docx:
                try WordWriter.writeDOCX(layout, source: source, keepLayout: options.keepLayout, to: destination)
            case .rtf:
                try WordWriter.writeRTF(layout, to: destination)
            case .xlsx:
                try SpreadsheetWriter.writeXLSX(layout, oneSheetPerTable: options.oneSheetPerTable, to: destination)
            case .csv:
                try SpreadsheetWriter.writeCSV(layout, to: destination)
            case .pptx:
                try PresentationWriter.write(layout, source: source, picturesUnderText: options.picturesUnderText, to: destination)
            case .text:
                try TextExport.text(layout).write(to: destination, atomically: true, encoding: .utf8)
            case .html:
                try TextExport.html(layout, source: source, title: baseName).write(to: destination, atomically: true, encoding: .utf8)
            case .epub:
                try TextExport.epub(layout, source: source, title: baseName, to: destination)
            case .png, .jpeg, .tiff, .heic, .webp:
                let files = try ImageExport.export(source, options: options, folder: destination, baseName: baseName, progress: progress)
                return ExportResult(outputs: files)
            case .pdfA:
                let problems = try ArchiveWriter.writePDFA(source, level: options.pdfALevel, to: destination)
                return ExportResult(outputs: [destination], problems: problems)
            case .pdfX:
                try ArchiveWriter.writePDFX(source, level: options.pdfXLevel, to: destination)
            case .fdf, .xfdf, .json:
                try DataExport.write(source, format: options.format, to: destination)
            case .pdf:
                throw ToolError(Strings.Errors.notConvertible("pdf"))
            }
            return ExportResult(outputs: [destination])
        }.value
    }
}
