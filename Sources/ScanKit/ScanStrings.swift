import Foundation
import SuperPDFCore

// ScanKit's panel copy (ux §5.3 "Scan with iPhone / scanner / From a photo", §7.4; sentence case, curly quotes, a real
// ellipsis on what opens more UI). Shared copy (errors, the panel frame) comes from `Strings`.
enum ScanStrings {
    static func pages(_ n: Int) -> String { Formatting.count(n, "page", "pages") }

    // The three steps (ux §5.3: pick device, scan, pages come in).
    static let deviceSteps = ["Device", "Scan", "Pages"]
    static let photoSteps = ["Photos", "Straighten", "Pages"]

    // Step 1
    static let iPhoneNeeds = "Use an iPhone or iPad that’s unlocked, close by, and signed in to the same Apple Account."
    static let lookingForScanners = "Looking for scanners…"
    static let connecting = "Getting ready…"
    static let busy = "In use"
    static let unnamedScanner = "Scanner"
    static let photos = "Photos"
    static let choosePhotos = "Choose or drop photos of pages."

    // Step 2
    static let importFromIPhone = "Import from iPhone…"
    static let iPhoneHint = "Choose Scan Documents on your iPhone or iPad. The pages come back here."
    static let scan = "Scan"
    static let colour = "Colour"
    static let colourOption = "Colour", greyOption = "Grey", blackAndWhiteOption = "Black & white"
    static let resolution = "Resolution"
    static func dpi(_ value: Int) -> String { "\(value) dpi" }
    static let paperSize = "Size"
    static let a4 = "A4", letter = "US Letter", legal = "US Legal", wholeGlass = "Whole glass"
    static let bothSides = "Scan both sides"
    static let scanning = "Scanning…"
    static let waitingForIPhone = "Waiting for your iPhone or iPad…"
    static func scanned(_ n: Int) -> String { n == 0 ? "No pages yet." : "\(pages(n)) so far." }
    static let pageFound = "Page found"
    static let wholePhoto = "No edges found · whole photo used"
    static let finding = "Finding the page…"
    static func photo(_ n: Int) -> String { "Photo \(n)" }

    // Step 3
    static let cleanUp = "Clean up"
    static let recogniseText = "Recognise text so you can search and copy it"
    static let scanAnother = "Scan another"
    static let atTheEnd = "Insert position: At the end"
    static let newPDF = "The pages open as a new PDF."
    static let nothingYet = "Nothing scanned yet. Go back and scan a page."

    /// The new document's name when no PDF is open.
    static let newDocumentName = "Scan"
    /// Undo menu name ("Undo Insert Scanned Pages").
    static let undoName = "Insert Scanned Pages"

    // Errors (ux §7.4 has the copy for no device; the rest follow its rule: what happened, what to do).
    static let scannerBusy = "The scanner is busy. Wait until it’s done, then try again."
    static func scanFailed(_ reason: String) -> String { "The scan didn’t finish: \(reason)" }
    static let unreadablePhoto = "One of the photos couldn’t be read. Try another photo."
}

/// Why scanning stopped, in the panel's words (ux §7.4).
enum ScanFailure: LocalizedError, Equatable {
    case noIPhone
    case noScanner
    case scannerBusy
    case unreadable
    case failed(String)

    var errorDescription: String? {
        switch self {
        case .noIPhone: Strings.Errors.noIPhone
        case .noScanner: Strings.Errors.noScanner
        case .scannerBusy: ScanStrings.scannerBusy
        case .unreadable: ScanStrings.unreadablePhoto
        case .failed(let reason): ScanStrings.scanFailed(reason)
        }
    }

    /// The panel's message with its one action ("Try again" where trying again can help).
    var toolError: ToolError {
        switch self {
        case .noIPhone, .noScanner, .scannerBusy:
            ToolError(errorDescription ?? "", action: ToolOption(ScanTools.Action.tryAgain, Strings.Errors.tryAgain))
        case .unreadable, .failed:
            ToolError(errorDescription ?? "")
        }
    }
}
