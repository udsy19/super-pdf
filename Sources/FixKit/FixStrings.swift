import Foundation
import SuperPDFCore

// FixKit's panel copy (Core's `Strings` holds the shared banners and errors; the copy of one panel lives in its module).
// ux §1.1 tone: plain words, sentence case, curly quotes around file names, a real ellipsis on anything that asks.

enum FixStrings {
    private static func name(_ fileName: String?) -> String { fileName.map(Strings.quoted) ?? "this file" }

    // MARK: Make smaller (ux §5.3)

    enum MakeSmaller {
        static let hint = "Shrinks the file so it’s easier to send. The pages stay the same."
        static func title(_ preset: SizePreset) -> String {
            switch preset {
            case .good: "Good (recommended)"
            case .email: "Email (smallest)"
            case .best: "Best quality"
            }
        }
        static func estimate(_ bytes: Int64) -> String { "≈ " + Formatting.bytes(bytes) }
        static func now(_ bytes: Int64) -> String { "Now: " + Formatting.bytes(bytes) }
        static let imageQuality = "Image quality"
        static let sharpness = "Picture sharpness"
        static func dpi(_ value: Int) -> String { "\(value) dpi" }
        static let removeComments = "Remove comments and form entries"
        static let removeBookmarks = "Remove bookmarks and attachments"
        static let removeFonts = "Remove extra fonts"
        static let fastWebView = "Make pages load fast on the web"
        static let spaceHeading = "What takes up space"
        static let pictures = "Pictures"
        static let fonts = "Fonts"
        static let content = "Text and drawings"
        static let structure = "Structure"
        static let attachments = "Attachments"
        static let button = "Make smaller"
        static let alreadySmall = "This file is already as small as it gets."
    }

    // MARK: Recognise text (ux §5.3)

    enum Recognise {
        /// "14 of 20 pages have no text yet".
        static func withoutText(_ count: Int, of total: Int) -> String {
            "\(count) of \(Formatting.count(total, "page", "pages")) \(count == 1 ? "has" : "have") no text yet"
        }
        static let language = "Language"
        static let automatic = "Automatic"
        static let cleanUp = "Clean up the scan first (straighten, whiten)"
        static let editable = "Make text editable (replaces the picture with real text)"
        static let resolution = "Resolution"
        static let button = "Recognise text"
        static let nothingFound = "No text was found on these pages."
        /// The undo action ("Undo Recognise Text").
        static let actionName = "Recognise Text"
    }

    // MARK: Repair (ux §5.3, §7.4)

    enum Repair {
        static let indexDamaged = "The file’s index is damaged."
        static let contentDamaged = "Some page content is damaged."
        static let truncated = "The end of the file is missing."
        static let embedFonts = "Also embed missing fonts"
        static let button = "Repair and save copy"
        static func failed(_ fileName: String?) -> String {
            "We couldn’t repair \(name(fileName)). Too much of it is damaged to recover. Ask whoever sent it for a new copy."
        }
        static func needsPassword(_ fileName: String?) -> String {
            "\(name(fileName).prefix(1).uppercased() + name(fileName).dropFirst()) is damaged and needs a password, so it can’t be repaired."
        }
    }

    // MARK: Compare files (ux §5.3, §7.5)

    enum Compare {
        static let other = "Compare with"
        static let textOnly = "Text only"
        static let previous = "Previous change"
        static let next = "Next change"
        static let button = "Save comparison report…"
        static let reportName = "Comparison"
        static let comparing = "Comparing…"
        static let noChanges = "No changes found"
        /// "14 changes on 6 pages".
        static func summary(changes: Int, pages: Int) -> String {
            changes == 0 ? noChanges : "\(Formatting.count(changes, "change", "changes")) on \(Formatting.count(pages, "page", "pages"))"
        }
        static func page(_ number: Int) -> String { "Page \(number)" }
        static func changes(_ count: Int) -> String { Formatting.count(count, "change", "changes") }
        static func reportTitle(old: String, new: String) -> String { "Comparing \(Strings.quoted(old)) with \(Strings.quoted(new))" }
        static func added(_ text: String) -> String { "Added \(Strings.quoted(text))" }
        static func removed(_ text: String) -> String { "Removed \(Strings.quoted(text))" }
        static func changed(_ old: String, _ new: String) -> String { "Changed \(Strings.quoted(old)) to \(Strings.quoted(new))" }
        static let visual = "A picture or the layout changed"
    }

    // MARK: Checks (ux §5.3 Check accessibility / Check for printing)

    enum Check {
        static let checking = "Checking…"
        static let failed = "Failed"
        static let needsAttention = "Needs attention"
        static let passed = "Passed"
        static let button = "Save fixed copy"
        static func picture(page: Int) -> String { "Picture on page \(page)" }
        static let describe = "Describe this image"
        static let separations = "Separations"
        static let allInks = "All inks"
        static let cyan = "Cyan", magenta = "Magenta", yellow = "Yellow", black = "Black"
        static let printerMarks = "Add printer marks"
        static func pages(_ pages: [Int]) -> String {
            let shown = pages.prefix(4).map { "\($0 + 1)" }.joined(separator: ", ")
            return (pages.count == 1 ? "p. " : "pp. ") + shown + (pages.count > 4 ? "…" : "")
        }
        static func inkCoverage(_ percent: Int) -> String { "Ink coverage reaches \(percent)% on this page" }
    }

    enum Accessibility {
        static let hasTitle = "The document has a title", noTitle = "The document has no title", addTitle = "Add a title"
        static let hasLanguage = "The document’s language is set", noLanguage = "The document’s language isn’t set"
        static func setLanguage(_ language: String) -> String { "Set the language to \(language)" }
        static let tagged = "The document is tagged", untagged = "The document isn’t tagged", tag = "Tag the document"
        static let readingOrder = "The reading order is set", noReadingOrder = "There’s no reading order for screen readers"
        static let described = "Every picture has a description"
        static func undescribed(_ count: Int) -> String {
            "\(Formatting.count(count, "picture has", "pictures have")) no description"
        }
        static let tableHeaders = "Tables have header rows", noTableHeaders = "Some tables have no header row"
        static let headings = "Headings are in order", skippedHeadings = "Heading levels skip a level", noHeadings = "There are no headings"
        static let contrast = "Text has enough contrast", lowContrast = "Some text may be hard to read"
        static let labelled = "Form fields have labels"
        static func unlabelled(_ count: Int) -> String { "\(Formatting.count(count, "form field has", "form fields have")) no label" }
        static let bookmarks = "Long documents have bookmarks", noBookmarks = "This long document has no bookmarks"
        static let addBookmarks = "Add bookmarks from headings"
        static let tabOrder = "Tab order follows the structure", noTabOrder = "Tab order doesn’t follow the structure"
        static let setTabOrder = "Set the tab order"
    }

    enum Printing {
        static let fontsEmbedded = "All fonts are embedded"
        static func fontsMissing(_ names: [String]) -> String {
            "\(names.count == 1 ? "A font isn’t" : "\(names.count) fonts aren’t") embedded: " + names.prefix(3).joined(separator: ", ")
                + (names.count > 3 ? "…" : "")
        }
        static let embedFonts = "Embed fonts"
        static let resolution = "Pictures are sharp enough to print"
        static func lowResolution(_ count: Int) -> String { "\(Formatting.count(count, "picture is", "pictures are")) under 150 dpi" }
        static let noRGB = "Colours are ready for print", rgb = "Pages use RGB colours", convert = "Convert colours to CMYK"
        static let noTransparency = "No transparency", transparency = "Pages use transparency", flatten = "Flatten transparency"
        static func spotColours(_ names: [String]) -> String { "Spot colours: " + names.joined(separator: ", ") }
        static let boxes = "Pages have trim boxes", noTrimBox = "Pages have no trim box", mixedSizes = "Pages have different sizes"
        static let lines = "No lines are too thin to print", hairlines = "Some lines are too thin to print"
        static let thicken = "Thicken thin lines"
        static let overprint = "Some objects overprint"
        static let largeFile = "The file is very large"
    }

    enum PDFA {
        static func version(_ level: PDFALevel) -> String { "The PDF version is too new for \(level.title)" }
        static let encrypted = "The file is encrypted"
        static func notMarked(_ level: PDFALevel) -> String { "It isn’t marked as \(level.title)" }
        static let noOutputIntent = "It has no colour profile (output intent)"
        static let fonts = "Some fonts aren’t embedded"
        static let scripts = "It contains scripts or actions PDF/A doesn’t allow"
        static let transparency = "It uses transparency, which PDF/A-1 doesn’t allow"
        static let attachments = "It has attachments this level doesn’t allow"
        static let lzw = "It uses LZW compression"
        static let annotations = "Some notes have no appearance or don’t print"
        static let untagged = "It isn’t tagged, which this level needs"
        static let noID = "It has no file identifier"
        static func passes(_ level: PDFALevel) -> String { "It meets \(level.title)" }
    }
}
