import SuperPDFCore

// The app shell's own copy (ux §1.1 tone).
enum AppStrings {
    /// ux §3: several files dropped on the Dock icon or opened together.
    static func combineFiles(_ count: Int) -> String { Strings.Drop.combineFiles(count) }
    static let combineInfo = "They go into one new PDF, in this order. You can change the order and the pages first."
    static let combine = "Combine…"
    static let openSeparately = "Open Separately"

    /// The one-time PDF Services offer (features #48, ARCHITECTURE "Launch sequence" step 3).
    static let pdfServicesTitle = "Add “Save to Super PDF” to the Print dialog?"
    static let pdfServicesInfo = "Then any app can print straight into Super PDF: click PDF in the Print dialog and choose Save to Super PDF."
    static let pdfServicesItem = "Save to Super PDF"
    static let add = "Add"
    static let notNow = "Not Now"

    /// The Services menu item and File › New from Clipboard (features #49, §2.5).
    static let untitled = "Untitled"
    static let nothingToMake = "There’s no text, picture or PDF on the clipboard to make a PDF from."
}
