import Foundation
import SuperPDFCore

// ProtectKit's panel copy (ux §5.3 "Add a password", "Remove password", "Black out", "Lock in notes & fields",
// "Remove hidden info"; features #69, #86–#88, #122). Shared banners and errors come from `Strings` (ux §7).

enum ProtectStrings {
    // MARK: Add a password

    static let password = "Password"
    static let passwordPlaceholder = "Password"
    static let verify = "Verify"
    static let verifyPlaceholder = "Type it again"
    static let forgetWarning = "If you forget this password, no one can open the file."
    static let mismatch = "The two passwords don’t match."
    /// macOS PDFKit (and other apps) can't open AES-256 files whose password has non-ASCII characters.
    static let nonASCIIWarning = "Some apps can’t open files with this password. Use only letters and numbers to be safe."
    static let needChangePassword = "Also need a password to change it"
    static let changePassword = "Password to change it"
    static let changePasswordPlaceholder = "Another password"
    static let allowPrinting = "Allow printing"
    static let printQuality = "Print quality"
    static let highResolution = "High resolution"
    static let lowResolution = "Low resolution"
    static let allowCopying = "Allow copying text"
    static let allowFormsAndComments = "Allow filling forms and commenting"
    static let allowPageChanges = "Allow page changes"
    static let encryption = "Encryption"
    static let aes256 = "AES-256 (recommended)"
    static let aes128 = "AES-128 (for old readers)"
    static let keepMetadata = "Encrypt everything except metadata"
    static let onlyAttachments = "Only attachments"
    static let saveProtected = "Save protected copy"
    static let strength = ["Weak", "Fair", "Good", "Strong"]

    // MARK: Remove password

    static let needsPasswordToOpen = "This file needs a password to open."
    static func limits(_ restrictions: [Strings.Restriction]) -> String {
        let words = restrictions.map(\.words)
        let list = words.count <= 1 ? words.joined() : words.dropLast().joined(separator: ", ") + " and " + words.last!
        return "This file limits \(list)."
    }
    static let noPassword = "This file doesn’t have a password."
    static let saveWithoutPassword = "Save copy without password"
    static let removePasswordOption = ToolOption("open-remove-password", Strings.Errors.removePasswordAction)

    // MARK: Black out

    static let markByHand = "Mark by hand"
    static let findAndMark = "Find and mark"
    static let handHint = "Drag across text or around an area to mark it. Click a mark to unmark it."
    static let findPlaceholder = "Words to find"
    static let patternTitles: [(RedactionPattern?, String)] = [
        (.phoneNumbers, "Phone numbers"), (.emails, "Emails"), (.cardNumbers, "Card numbers"), (.dates, "Dates"),
        (.contactNames, "Names from the address book"), (.socialSecurityNumbers, "Social security numbers"), (.iban, "IBANs"),
        (.ukNationalInsurance, "UK National Insurance numbers"), (.aadhaar, "Aadhaar numbers"), (nil, "Custom pattern…"),
    ]
    static let customPattern = "Pattern"
    static let customPatternPlaceholder = "A regular expression"
    static let badPattern = "That pattern isn’t a valid regular expression."
    static func found(_ count: Int, pages: Int) -> String {
        "\(count) found on \(Formatting.count(pages, "page", "pages"))"
    }
    static let alsoRemoveHidden = "Also remove hidden information (metadata, comments)"
    static let writeRedacted = "Write REDACTED over the boxes"
    static let overlayWords = "Words over the boxes"
    static let defaultOverlay = "REDACTED"
    static let boxColour = "Box colour"
    static let colours: [(id: String, title: String)] = [("#000000", "Black"), ("#FFFFFF", "White"), ("#808080", "Grey")]
    static func blackOut(_ count: Int) -> String { "Black out \(Formatting.count(count, "item", "items"))" }
    static let nothingMarked = "Mark something to black out first."
    static let notVerified = "Some marked content couldn’t be removed for certain, so nothing was saved."
    static func page(_ number: Int) -> String { "p. \(number)" }

    /// U.S. FOIA exemptions (b)(1)–(b)(9) with (b)(7)(A)–(F), and Privacy Act exemptions: Acrobat's code sets (features #69).
    static let foiaCodes = ["(b)(1)", "(b)(2)", "(b)(3)", "(b)(4)", "(b)(5)", "(b)(6)", "(b)(7)(A)", "(b)(7)(B)", "(b)(7)(C)",
                            "(b)(7)(D)", "(b)(7)(E)", "(b)(7)(F)", "(b)(8)", "(b)(9)"]
    static let privacyActCodes = ["(d)(5)", "(j)(1)", "(j)(2)", "(k)(1)", "(k)(2)", "(k)(3)", "(k)(4)", "(k)(5)", "(k)(6)", "(k)(7)"]

    // MARK: Lock in notes & fields

    static let notesAndMarkup = "Notes and markup"
    static let formEntries = "Form entries"
    static let makePictures = "Make pages into pictures (strongest)"
    static let saveLockedIn = "Save locked-in copy"

    // MARK: Remove hidden info

    static func title(_ kind: HiddenInfoKind) -> String {
        switch kind {
        case .metadata: "Metadata"
        case .comments: "Comments"
        case .formData: "Form entries"
        case .hiddenText: "Hidden text (OCR layer)"
        case .hiddenLayers: "Hidden layers"
        case .attachments: "Attachments"
        case .bookmarks: "Bookmarks"
        case .links: "Links"
        case .scripts: "Scripts"
        case .unreferencedObjects: "Deleted content still in the file"
        case .thumbnails: "Page thumbnails"
        case .overlappingObjects: "Things hidden under pictures"
        }
    }
    static let lookingForHidden = "Looking for hidden information…"
    static let nothingHidden = "Nothing hidden was found."
    static let saveClean = "Save clean copy"

    // MARK: Certificates and envelopes

    static let certificateUnusable = "This certificate can’t be used to lock a file. Ask for one with an RSA key."
    static func envelopeCover(files: [String]) -> [String] {
        ["Locked envelope", "", files.count == 1 ? "This PDF carries 1 attached file:" : "This PDF carries \(files.count) attached files:"]
            + files.map { "•  " + $0 } + ["", "Open the attachments to save them."]
    }
}
