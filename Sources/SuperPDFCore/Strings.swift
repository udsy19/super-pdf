import Foundation

// Copy shared across modules (ux §1.1 tone: sentence case, curly quotes around file names, a real ellipsis on anything
// that opens a dialog, no exclamation marks): the Tools sheet (§4), the panel frame (§5.1), drop labels (§3), saving
// (§7.1), result banners (§7.3), errors (§7.4) and empty states (§7.5). Tile names and hints live in the catalog;
// copy of one panel lives in its module.

public enum Strings {
    public static let appName = "Super PDF"

    /// “Report.pdf” — curly quotes around a file name.
    public static func quoted(_ name: String) -> String { "“\(name)”" }

    /// Menu titles are title case (ux §4: Tools › Pages › Rotate Pages…; Apple's style): every word capitalised except
    /// articles, coordinating conjunctions and short prepositions in the middle; a particle right after the first word
    /// is capitalised ("Black Out", "Lock In"); words that already hold a capital ("iPhone", "PDF/A") are kept.
    public static func menuTitle(_ sentence: String) -> String {
        let minor: Set<String> = ["a", "an", "the", "and", "but", "or", "nor", "for", "so", "yet", "as", "at", "by", "from", "in",
                                  "into", "of", "off", "on", "onto", "out", "over", "to", "up", "with", "via"]
        let particles: Set<String> = ["in", "out", "up", "off", "down", "over"]
        let words = sentence.split(separator: " ", omittingEmptySubsequences: false).map(String.init)
        return words.enumerated().map { index, word in
            guard let first = word.first, first.isLetter, first.isLowercase, !word.contains(where: \.isUppercase) else { return word }
            let isEdge = index == 0 || index == words.count - 1
            let isParticle = index == 1 && particles.contains(word)
            guard isEdge || isParticle || !minor.contains(word) else { return word }
            return first.uppercased() + word.dropFirst()
        }.joined(separator: " ")
    }

    /// Restrictions an owner password can set, in the words of the "doesn’t allow" sentence (ux §7.4).
    public enum Restriction: String, Sendable {
        case printing, copying, pageChanges, commenting, formFilling

        public var words: String {
            switch self {
            case .printing: "printing"
            case .copying: "copying"
            case .pageChanges: "page changes"
            case .commenting: "comments"
            case .formFilling: "filling in forms"
            }
        }
    }

    // MARK: - Tools sheet (ux §4)

    public enum ToolsSheet {
        public static let title = "What do you want to do?"
        public static let searchPlaceholder = "Search tools — try “smaller”, “sign”, “Word”, “black out”"
        public static let recentlyUsed = "Recently used"
        public static func noResults(_ query: String) -> String { "Nothing called \(quoted(query)). Try “smaller”, “sign” or “Word”." }
        public static let badgeNeedsDevice = "Needs iPhone nearby"
        public static let badgeInstallConverter = "Install converter"
        public static let addToToolbar = "Add to Toolbar"
        public static let addToDockMenu = "Add to Dock Menu"
        /// Tools › All Tools… (ux §8).
        public static let allTools = "All Tools…"
    }

    // MARK: - Panel frame (ux §5.1)

    public enum Panel {
        public static let moreOptions = "More options"
        public static let cancel = "Cancel"
        public static let done = "Done"
        public static let change = "Change…"
        public static let stop = "Stop"
        public static let showDetails = "Show details"
        public static let back = "Back"
        public static let next = "Next"
        /// The scope popup: "Pages: All · This page · 3–5 · Selected (4)".
        public static let scopeLabel = "Pages"
        public static func scope(_ scope: Scope) -> String {
            switch scope {
            case .all: "All"
            case .current: "This page"
            case .ranges(let ranges): ranges.display
            case .selected(let pages): "Selected (\(pages.count))"
            }
        }
        /// "Page 14 of 120" while a run works through pages.
        public static func progress(page: Int, of total: Int) -> String { "Page \(page) of \(total)" }
        /// The output line above the button: "Saves “Report (smaller).pdf” next to the original".
        public static func savesNextToOriginal(_ fileName: String) -> String { "Saves \(quoted(fileName)) next to the original" }
        /// The convert archetype's engine line (ux §5.3 Images → PDF / Any file → PDF).
        public static func engineLine(_ engine: ConverterEngine) -> String {
            switch engine {
            case .builtIn: "Converted by: the built-in converter"
            case .libreOffice: "Converted by: LibreOffice"
            case .app(let app): "\(app.name) will open to export this file"
            case .printFromOwningApp: "Open the file in its app and use Print › Save as PDF"
            }
        }
    }

    // MARK: - Drag and drop (ux §3)

    public enum Drop {
        public static let open = "Open"
        public static func addPages(_ count: Int) -> String { count == 1 ? "Add 1 page here" : "Add \(count) pages here" }
        public static let addHere = "Add here"
        public static let placeImage = "Place image"
        public static let addText = "Add text"
        public static let cantAddFolder = "Can’t add a folder. Drop the files inside it."
        public static func combineFiles(_ count: Int) -> String { "Combine these \(count) files?" }
    }

    // MARK: - Saving and closing (ux §7.1)

    public enum Save {
        public static func title(_ fileName: String) -> String { "Save changes to \(quoted(fileName))?" }
        public static let saveCopy = "Save a copy…"
        public static let replaceOriginal = "Replace original"
        public static let alwaysDoThis = "Always do this"
        public static let closeMessage =
            "You have a Super PDF document with unsaved changes. Do you want to review these changes before closing?"
        public static let reviewChanges = "Review Changes…"
        public static let discardChanges = "Discard Changes"
    }

    // MARK: - Result banners (ux §7.3)

    public enum Banner {
        public static let showInFinder = "Show in Finder"
        public static let share = "Share"
        public static let undo = "Undo"
        public static let save = "Save…"
        public static let showRequests = "Show requests"
        public static let show = "Show"
        public static func openIn(_ app: String) -> String { "Open in \(app)" }

        /// "Done. The file is 72% smaller (6.1 MB → 1.7 MB)."
        public static func madeSmaller(before: Int64, after: Int64) -> ResultBanner {
            let percent = "\(Formatting.percentSaved(before: before, after: after))%"
            let from = Formatting.bytes(before), to = Formatting.bytes(after)
            return ResultBanner("Done. The file is \(percent) smaller (\(from) → \(to)).", emphasis: [percent, from, to],
                                actions: [.showInFinder, .share, .undo])
        }

        /// "Recognised 14 pages. You can now search and copy the text."
        public static func recognised(pages: Int) -> ResultBanner {
            let count = Formatting.count(pages, "page", "pages")
            return ResultBanner("Recognised \(count). You can now search and copy the text.", emphasis: [count], actions: [.undo])
        }

        /// "Blacked out 12 items on 5 pages and saved “Report (blacked out).pdf”."
        public static func blackedOut(items: Int, pages: Int, fileName: String) -> ResultBanner {
            let itemCount = Formatting.count(items, "item", "items"), pageCount = Formatting.count(pages, "page", "pages")
            return ResultBanner("Blacked out \(itemCount) on \(pageCount) and saved \(quoted(fileName)).", emphasis: [itemCount, pageCount],
                                actions: [.showInFinder])
        }

        /// "Combined 3 files into 41 pages."
        public static func combined(files: Int, pages: Int) -> ResultBanner {
            let fileCount = Formatting.count(files, "file", "files"), pageCount = Formatting.count(pages, "page", "pages")
            return ResultBanner("Combined \(fileCount) into \(pageCount).", emphasis: [fileCount, pageCount], actions: [.save])
        }

        /// "Saved “Report.docx”." with Open in <app> (Word, Excel, PowerPoint…) and Show in Finder.
        public static func saved(_ fileName: String, openIn app: String?) -> ResultBanner {
            ResultBanner("Saved \(quoted(fileName)).", actions: (app.map { [.openIn(appName: $0)] } ?? []) + [.showInFinder])
        }

        /// "Saved 12 images in “Report images”."
        public static func savedImages(_ count: Int, folder: String) -> ResultBanner {
            let images = Formatting.count(count, "image", "images")
            return ResultBanner("Saved \(images) in \(quoted(folder)).", emphasis: [images], actions: [.showInFinder])
        }

        /// "Saved 4 files in “Report parts”." (Split)
        public static func savedFiles(_ count: Int, folder: String) -> ResultBanner {
            let files = Formatting.count(count, "file", "files")
            return ResultBanner("Saved \(files) in \(quoted(folder)).", emphasis: [files], actions: [.showInFinder])
        }

        /// "Saved “Report (archive).pdf”. It passes the PDF/A-2b check." or "… 2 things couldn’t be fixed." with Show.
        public static func archived(_ fileName: String, level: PDFALevel, unfixed: Int) -> ResultBanner {
            if unfixed == 0 {
                return ResultBanner("Saved \(quoted(fileName)). It passes the \(level.title) check.", emphasis: [level.title])
            }
            let things = Formatting.count(unfixed, "thing", "things")
            return ResultBanner("Saved \(quoted(fileName)). \(things) couldn’t be fixed.", emphasis: [things], actions: [.showDetails])
        }

        /// "Saved “Report (protected).pdf”. Keep the password somewhere safe."
        public static func protected(_ fileName: String) -> ResultBanner {
            ResultBanner("Saved \(quoted(fileName)). Keep the password somewhere safe.")
        }

        /// "Signed and saved “Contract (signed).pdf”."
        public static func signed(_ fileName: String) -> ResultBanner {
            ResultBanner("Signed and saved \(quoted(fileName)).", actions: [.share])
        }

        /// "Sent to 2 people. We’ll match their files when they come back."
        public static func requestSent(people: Int) -> ResultBanner {
            let count = Formatting.count(people, "person", "people")
            return ResultBanner("Sent to \(count). We’ll match their files when they come back.", emphasis: [count], actions: [.showRequests])
        }
    }

    // MARK: - Errors (ux §7.4): what happened, what it means, what to do; codes only behind "Show details"

    public enum Errors {
        public static let ok = "OK"
        public static let tryAgain = "Try again"
        public static let notNow = "Not now"

        /// Preview's words.
        public static let passwordPrompt = "This document is password protected. Please enter the password below."
        public static let unlock = "Unlock"
        public static let invalidPassword = "Invalid password. Please try again."

        public static func ownerRestricted(_ restriction: Restriction) -> String {
            "This file doesn’t allow \(restriction.words). If you know the owner password you can remove the limit."
        }
        public static let removePasswordAction = "Remove password…"

        public static func damaged(_ fileName: String) -> String {
            "\(quoted(fileName)) couldn’t be opened. It may be damaged. We can try to repair it."
        }
        public static let repairAction = "Repair"
        public static func repaired(_ fileName: String) -> String {
            "We repaired \(quoted(fileName)). Check that everything looks right, then save a copy."
        }

        /// `fileExtension` without the dot: "Super PDF can’t turn “.sketch” files into a PDF. …"
        public static func notConvertible(_ fileExtension: String) -> String {
            "Super PDF can’t turn \(quoted("." + fileExtension)) files into a PDF. Try opening the file in its app and using Print › Save as PDF."
        }

        /// `kind` is the plural noun for the file type ("Spreadsheets", "Presentations", "Documents").
        public static func needsLibreOffice(kind: String, fileExtension: String) -> String {
            "\(kind) saved as \(quoted("." + fileExtension)) need the free Office converter (LibreOffice, about 800 MB)."
        }
        public static let installAction = "Install…"

        public static func needsOfficeApp(_ app: OfficeApp) -> String {
            "To convert this with full fidelity, \(app.shortName) needs to open it briefly."
        }
        public static func useApp(_ app: OfficeApp) -> String { "Use \(app.shortName)" }
        public static let useBuiltInConverter = "Use the built-in converter (simpler result)"

        public static func iWorkMissing(_ app: OfficeApp) -> String {
            "\(app.name) isn’t installed, so only the preview inside the file can be used (usually the first page). "
                + "\(app.name) is free on the Mac App Store."
        }
        public static let continueAction = "Continue"
        public static func getApp(_ app: OfficeApp) -> String { "Get \(app.name)" }

        public static let noIPhone = "No iPhone or iPad nearby. Make sure it’s unlocked, close by, and signed in to the same Apple Account."
        public static let noScanner = "No scanner found. Check that it’s on and connected."

        public static func fontMissing(_ font: String, substitute: String) -> String {
            "The font \(quoted(font)) isn’t on this Mac, so new text uses \(quoted(substitute)) instead."
        }

        public static let lastPage = "A PDF needs at least one page."

        public static func redactConfirm(items: Int) -> String {
            "This permanently removes \(Formatting.count(items, "item", "items")) from the new file. Your original stays as it is."
        }
        public static let blackOutAction = "Black out"

        public static func conversionFailed(_ fileName: String) -> String {
            "Something went wrong converting \(quoted(fileName)). The file may be damaged or use features we don’t support yet."
        }
        public static let tryWithLibreOffice = "Try with LibreOffice"

        public static let signatureInvalid = "This signature doesn’t match the document: it was changed after signing."
        public static let showWhatChanged = "Show what changed"

        public static let formHasScripts = "This form uses scripts we don’t run. Calculations may not update."
        public static let xfaForm = "This form was made with an Adobe-only format. You can view it but not fill it here."
    }

    // MARK: - Empty states (ux §7.5)

    public enum Empty {
        public static let welcomeRecents = "Files you open will show up here."
        public static let tableOfContents = "No table of contents yet."
        public static let findHeadings = "Find headings"
        public static let highlightsAndNotes = "No highlights or notes."
        public static let attachments = "No attachments. Drop a file here to attach it."
        /// Preview's word when a search finds nothing in the document.
        public static let searchNotFound = "Not found"
        public static func searchNoResults(_ query: String) -> String { "No results for \(quoted(query))." }
        public static let commentsUnresolved = "Nothing unresolved."
        public static let signatureRequests = "No requests yet. Use Tools › Request signatures to send a document for signing."
        public static let compare = "Drop the other version here, or choose it."
    }
}

public extension OfficeApp {
    /// The name in running text ("Excel needs to open it briefly").
    var shortName: String {
        switch self {
        case .word: "Word"
        case .excel: "Excel"
        case .powerPoint: "PowerPoint"
        default: name
        }
    }
}
