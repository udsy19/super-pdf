import Foundation
import SuperPDFCore

// PagesKit's panel copy (ux §5.3, §6.2, §7; sentence case, curly quotes, a real ellipsis on what asks where to save).
// Shared copy (banners, errors, the panel frame) comes from `Strings`.
enum PagesStrings {
    static func pages(_ n: Int) -> String { Formatting.count(n, "page", "pages") }
    static func files(_ n: Int) -> String { Formatting.count(n, "file", "files") }

    /// Undo menu names ("Undo Rotate Pages").
    enum Undo {
        static let rotate = "Rotate Pages"
        static let delete = "Delete Pages"
        static let move = "Move Pages"
        static let duplicate = "Duplicate Pages"
        static let insertBlank = "Insert Blank Page"
        static let insert = "Insert Pages"
        static let replace = "Replace Pages"
        static let reverse = "Reverse Pages"
        static let crop = "Crop Pages"
        static let number = "Number Pages"
        static let resize = "Resize Pages"
    }

    // Combine files
    static let combineFilesLabel = "Files"
    static let combineContents = "Add a contents entry for each file"
    static let fileSize = "File size"
    static let sizeNormal = "Normal"
    static let sizeSmaller = "Smaller"
    static func combine(_ n: Int) -> String { "Combine \(files(n))" }
    static let combineNeedsTwo = "Add at least two files to combine."
    static func noChosenPages(_ file: String) -> String { "\(Strings.quoted(file)) doesn’t have the pages chosen for it. Choose other pages." }
    static let combinedName = "Combined"
    static func converting(_ name: String) -> String { "Converting \(Strings.quoted(name))…" }
    static func adding(_ name: String) -> String { "Adding \(Strings.quoted(name))…" }
    static func needsPassword(_ name: String) -> String {
        "\(Strings.quoted(name)) is password protected. Open it, enter the password, then try again."
    }

    // Rearrange
    static let organiserHint = "Drag pages to rearrange. Drop files here to add them."
    static let showOrganiser = "Show Page Organiser"

    // Split
    static let splitEvery = "Every N pages"
    static let splitBySize = "By size"
    static let splitByContents = "By contents entries"
    static let splitByBlanks = "Blank pages between documents"
    static let splitRanges = "Ranges"
    static let pagesPerFile = "Pages in each file"
    static let largestFile = "Largest file (MB)"
    static let rangesPlaceholder = "1-3, 4-9"
    static func splitInto(_ n: Int) -> String { "Split into \(files(n))" }
    static let split = "Split"
    static let splitOneFile = "This would make just one file. Choose fewer pages per file."
    static let noContents = "This PDF has no table of contents to split by."
    static let noBlanks = "No blank pages found between documents."
    static let badRanges = "Type pages like “1-3, 4-9”."
    static func blanksFound(_ n: Int) -> String { "\(Formatting.count(n, "blank page", "blank pages")) found. They are left out." }

    // Extract
    static let removeFromDocument = "Remove them from this document"
    static let eachPageOwnFile = "Each page as its own file"
    static let savePagesAsPDF = "Save pages as PDF…"

    // Rotate / Delete
    static let rotateLeft = "Rotate Left"
    static let rotateRight = "Rotate Right"
    static let allSideways = "All sideways pages"
    static func rotate(_ n: Int) -> String { "Rotate \(pages(n))" }
    static let noSideways = "No pages are sideways."
    static func delete(_ n: Int) -> String { "Delete \(pages(n))" }

    // Crop
    static let cropNotice = "Cropping hides content without removing it. Use Black out to remove it."
    static let removeWhiteMargins = "Remove white margins"
    static let units = "Units"
    static let points = "Points"
    static let millimetres = "Millimetres"
    static let top = "Top", left = "Left", bottom = "Bottom", right = "Right"
    static let box = "Box"
    static let cropBox = "What shows (crop box)"
    static let trimBox = "Finished size (trim box)"
    static let bleedBox = "With bleed (bleed box)"
    static let artBox = "Content (art box)"
    static let crop = "Crop"
    static let noWhiteMargins = "These pages have no white margins to remove."
    static let cropsEverything = "That leaves nothing of the page. Make the margins smaller."

    // Insert
    static let fromFile = "From file"
    static let blankPage = "Blank page"
    static let fromScanner = "From scanner"
    static let fromIPhone = "From iPhone"
    static let insertFrom = "Pages from"
    static let afterPage = "After page"
    static let insert = "Insert"
    static let startScanning = "Start scanning…"
    static func scanNote(after page: Int) -> String {
        page == 0 ? "Scanned pages go at the front." : "Scanned pages go after page \(page)."
    }
    static let replaceInstead = "Replace the chosen pages instead"
    static func replace(_ n: Int) -> String { "Replace \(pages(n))" }
    static let reverseOrder = "Reverse page order"
    static let chooseFile = "Choose a file to insert."

    // Number pages
    static let style = "Style"
    static let startAt = "Start at"
    static let skipFirst = "Skip first"
    static let size = "Size"
    static let pageLabels = "Show these numbers in the sidebar too (page labels)"
    static let addNumbers = "Add numbers"

    // Booklet
    static let bookletFold = "Booklet (fold in half)"
    static let bookletFoldDetail = "Two pages on each side, in folding order"
    static let twoPerSheet = "2 per sheet"
    static let fourPerSheet = "4 per sheet"
    static let contactSheet = "Contact sheet"
    static let contactSheetDetail = "Every page small, to see the whole file at once"
    static let paper = "Paper"
    static let sameAsPages = "Same as the pages"
    static let makeBooklet = "Make booklet PDF"
    static let makeSheets = "Make PDF"
    static let makeContactSheet = "Make contact sheet"
    static func bookletName(_ base: String) -> String { "\(base) (booklet)" }

    // Resize
    static let customSize = "Custom size"
    static let a4Detail = "210 × 297 mm"
    static let letterDetail = "8.5 × 11 in"
    static let customDetail = "Set the width and height under More options"
    static let fit = "Fit"
    static let scaleToFit = "Scale to fit"
    static let addSpace = "Add space around"
    static let width = "Width (mm)"
    static let height = "Height (mm)"
    static func resize(_ n: Int) -> String { "Resize \(pages(n))" }
}
