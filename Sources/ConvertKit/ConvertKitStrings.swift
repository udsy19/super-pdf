import Foundation
import SuperPDFCore

/// ConvertKit's own copy (ux §1.1 tone: sentence case, curly quotes around file names, a real ellipsis). Shared copy
/// (engine lines, banners, errors) lives in `Strings`.
enum ConvertStrings {
    static let nothingToConvert = "Add the files you want to turn into a PDF."
    static let readingPages = "Reading the pages…"
    /// "Converting “Budget.xlsx”…"
    static func converting(_ fileName: String) -> String { "Converting \(Strings.quoted(fileName))…" }
    static func nothingInArchive(_ fileName: String) -> String {
        "Nothing in \(Strings.quoted(fileName)) can be turned into a PDF."
    }
    /// ZIP members and other inputs that were left out (features #44: "unsupported files listed in the notice").
    static func leftOut(_ names: [String]) -> String {
        let listed = names.prefix(5).map(Strings.quoted).joined(separator: ", ")
        let more = names.count > 5 ? " and \(names.count - 5) more" : ""
        return names.count == 1 ? "\(listed) couldn’t be converted, so it was left out." : "\(listed)\(more) couldn’t be converted, so they were left out."
    }

    /// Any file → PDF through Quick Look (features #47).
    static let quickLookNotice = "Super PDF can’t read this kind of file, so the PDF shows a picture of its first page."
    /// An iWork file converted from the preview inside it (features #39).
    static func iWorkPreviewNotice(_ fileName: String) -> String {
        "Only the preview inside \(Strings.quoted(fileName)) could be used, which is usually the first page."
    }

    /// The plural noun of the "Needs LibreOffice" sentence (ux §7.4): "Spreadsheets saved as “.ods” need…".
    static func kind(ofExtension ext: String) -> String {
        switch ext.lowercased() {
        case "xls", "xlsx", "ods", "numbers", "csv", "tsv": "Spreadsheets"
        case "ppt", "pptx", "odp", "key": "Presentations"
        case "eps", "ps": "Drawings"
        default: "Documents"
        }
    }
}

/// The Convert panels' copy (ux §5.3): labels, choices, buttons and notes.
enum ConvertPanelStrings {
    static let format = "Format"
    static let layout = "Layout"
    static let keepTheLook = "Keep the look"
    static let flowingText = "Flowing text"
    static let saveAsWord = "Save as Word…"
    static let saveAsRichText = "Save as rich text…"
    static let oneSheetPerTable = "One sheet per table"
    static let saveAsExcel = "Save as Excel…"
    static let saveAsCSV = "Save as CSV…"
    static let editableTextOverPictures = "Editable text over page pictures"
    static let saveAsPowerPoint = "Save as PowerPoint…"
    static let text = "Text"
    static let html = "HTML"
    static let epub = "EPUB"
    static let saveAsText = "Save as text…"
    static let saveAsWebPage = "Save as web page…"
    static let saveAsEPUB = "Save as EPUB…"
    /// "3 pages are pictures — text will be recognised first" (ux §5.3).
    static func picturePages(_ count: Int) -> String {
        count == 1 ? "1 page is a picture — text will be recognised first" : "\(count) pages are pictures — text will be recognised first"
    }

    // To images
    static let qualityGood = "Good (150 dpi)"
    static let qualityGoodDetail = "Sharp on screen, small files"
    static let qualityPrint = "Print (300 dpi)"
    static let qualityPrintDetail = "For printing; bigger files"
    static let qualityScreen = "Screen (72 dpi)"
    static let qualityScreenDetail = "The smallest files"
    static let jpegQuality = "JPEG quality"
    static let oneTIFF = "One TIFF with every page"
    static let exportPicturesInstead = "Export the pictures inside instead"
    static let exportPagesInstead = "Export whole pages instead"
    static let picturesInsideNote = "Saves each picture on these pages at its own resolution."
    static let noPicturesInside = "These pages have no pictures inside to save."
    static let saveImages = "Save images…"

    // For archiving
    static let level2bDetail = "Opens the same way in any PDF app, now and later"
    static let level1bDetail = "For systems that only take the oldest kind"
    static let level3bDetail = "Also keeps the files attached to this PDF"
    static let level2uDetail = "Like PDF/A-2b, and its text can always be searched"
    static let forPrinters = "For sending to a printer"
    static let archiveCheckNote = "We’ll check the result and tell you if anything couldn’t be converted."
    static let otherStandard = "Other standard"
    static let otherStandardChosen = "Saves with the standard chosen under More options."
    static let none = "None"
    static let saveArchiveCopy = "Save archive copy"
    static let archiving = "Making the archive copy…"

    // Images → PDF, Any file → PDF
    static let pictures = "Pictures"
    static let files = "Files"
    static let paper = "Paper"
    static let fitEachPicture = "Fit each picture"
    static let margins = "Margins"
    static let marginNone = "None"
    static let marginSmall = "Small"
    static let marginNormal = "Normal"
    static let marginWide = "Wide"
    static let makePDF = "Make PDF"
    /// A new document made from several files (as Combine names it).
    static let combinedName = "Combined"
}
