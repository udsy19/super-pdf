import Foundation

// The Tools sheet as data (ux §4.1): every tile with its section, plain name, hint, search synonyms, SF Symbol, panel
// archetype (ux §5.2–§5.3), `features.md` numbers and the module that provides it (ARCHITECTURE "Work packages").
//
// Names, hints and synonyms are ux §4.1's words (curly quotes and apostrophes, real ellipsis): all 52 rows. Symbols: those ux §2.4 names are used as given; the rest are
// WP1's choice of the plainest SF Symbol for the verb, open to design review. Ownership where no work package names the
// feature: Contents and Read aloud → ViewerKit (they live in the sidebar and the viewer), Compare files → FixKit. Read
// aloud sits in Fix & check next to Check accessibility: the Understand section held the AI tools and went with them.

public enum ToolCatalog {
    public static let tiles: [ToolTile] = [
        // MARK: Pages
        ToolTile(.combineFiles, .pages, "Combine files", "Put several files into one PDF",
                 synonyms: ["merge", "join", "append", "concatenate"], symbol: "doc.on.doc", archetype: .convert, features: [18],
                 owner: .pagesKit, needsDocument: false),
        ToolTile(.rearrangePages, .pages, "Rearrange pages", "Drag pages into a new order",
                 synonyms: ["organise", "organize", "reorder", "move", "sort"], symbol: "rectangle.grid.2x2", archetype: .mode,
                 features: [19], owner: .pagesKit),
        ToolTile(.split, .pages, "Split", "Cut this PDF into several files",
                 synonyms: ["separate", "divide", "chapters"], symbol: "scissors", archetype: .presetAndMore, features: [23], owner: .pagesKit),
        ToolTile(.extractPages, .pages, "Extract pages", "Save some pages as their own PDF",
                 synonyms: ["pull out", "save pages", "range"], symbol: "arrow.up.doc", archetype: .oneChoice, features: [22], owner: .pagesKit),
        ToolTile(.rotatePages, .pages, "Rotate pages", "Turn pages the right way up",
                 synonyms: ["sideways", "upside down", "landscape"], symbol: "rotate.right", archetype: .oneChoice, features: [20],
                 owner: .pagesKit),
        ToolTile(.deletePages, .pages, "Delete pages", "Remove pages you don’t need",
                 synonyms: ["remove"], symbol: "trash", archetype: .oneChoice, features: [21], owner: .pagesKit),
        ToolTile(.crop, .pages, "Crop", "Trim the edges of pages",
                 synonyms: ["margins", "cut", "trim", "page boxes"], symbol: "crop", archetype: .livePreview, features: [28], owner: .pagesKit),
        ToolTile(.insertPages, .pages, "Insert pages", "Add a blank page or pages from another file",
                 synonyms: ["add page", "blank", "scanner"], symbol: "doc.badge.plus", archetype: .oneChoice, features: [24, 25, 27],
                 owner: .pagesKit),
        ToolTile(.numberPages, .pages, "Number pages", "Add page numbers",
                 synonyms: ["pagination", "folio", "page labels"], symbol: "number", archetype: .livePreview, features: [30, 31],
                 owner: .pagesKit),
        ToolTile(.booklet, .pages, "Booklet", "Lay pages out for printing and folding",
                 synonyms: ["imposition", "n-up", "2-up", "contact sheet"], symbol: "book", archetype: .presetAndMore, features: [32, 33],
                 owner: .pagesKit),
        ToolTile(.resizePages, .pages, "Resize pages", "Change the paper size",
                 synonyms: ["a4", "letter", "scale", "page boxes"], symbol: "aspectratio", archetype: .presetAndMore, features: [29],
                 owner: .pagesKit),

        // MARK: Convert
        ToolTile(.toWord, .convert, "To Word", "Make a Word document you can edit",
                 synonyms: ["docx", "doc", "export", "rtf"], symbol: "doc.richtext", archetype: .convert, features: [50], owner: .convertKit),
        ToolTile(.toExcel, .convert, "To Excel", "Pull tables into a spreadsheet",
                 synonyms: ["xlsx", "csv", "table", "numbers"], symbol: "tablecells", archetype: .convert, features: [51], owner: .convertKit),
        ToolTile(.toPowerPoint, .convert, "To PowerPoint", "Make slides from the pages",
                 synonyms: ["pptx", "keynote", "presentation"], symbol: "rectangle.on.rectangle", archetype: .convert, features: [52],
                 owner: .convertKit),
        ToolTile(.toImages, .convert, "To images", "Save pages as JPG or PNG",
                 synonyms: ["jpeg", "png", "tiff", "picture", "export images"], symbol: "photo", archetype: .presetAndMore, features: [53],
                 owner: .convertKit),
        ToolTile(.toTextOrWeb, .convert, "To text or web page", "Plain text, HTML or an EPUB book",
                 synonyms: ["txt", "html", "epub", "ebook", "reflow"], symbol: "doc.plaintext", archetype: .convert, features: [54, 55],
                 owner: .convertKit),
        ToolTile(.forArchiving, .convert, "For archiving (PDF/A)", "Save a copy that will open the same way in decades",
                 synonyms: ["pdfa", "archive", "iso 19005", "standards", "pdf/x"], symbol: "archivebox", archetype: .presetAndMore,
                 features: [56, 57], owner: .convertKit),
        ToolTile(.imagesToPDF, .convert, "Images → PDF", "Turn photos and scans into a PDF",
                 synonyms: ["jpg to pdf", "png", "heic", "picture"], symbol: "photo.on.rectangle", archetype: .convert, features: [34],
                 owner: .convertKit, needsDocument: false),
        ToolTile(.anyFileToPDF, .convert, "Any file → PDF", "Word, Excel, PowerPoint, Pages, web pages, text, EPUB, ZIP…",
                 synonyms: ["docx to pdf", "convert", "create pdf", "html", "csv", "hwp", "odt"], symbol: "arrow.left.arrow.right",
                 archetype: .convert, features: Array(35...49), owner: .convertKit, needsDocument: false),

        // MARK: Edit
        ToolTile(.editTextAndImages, .edit, "Edit text & images", "Change words and pictures on the page",
                 synonyms: ["edit pdf", "typo", "replace image"], symbol: "textformat", archetype: .mode, features: [60, 61, 62, 72],
                 owner: .editKit),
        ToolTile(.headersAndFooters, .edit, "Headers & footers", "Put a title, date or numbers at the top or bottom",
                 synonyms: ["running head"], symbol: "rectangle.topthird.inset.filled", archetype: .livePreview, features: [64],
                 owner: .editKit),
        ToolTile(.watermark, .edit, "Watermark", "Stamp “Draft” or a logo across every page",
                 synonyms: ["confidential", "background", "logo"], symbol: "drop", archetype: .livePreview, features: [66, 67],
                 owner: .editKit),
        ToolTile(.batesNumbering, .edit, "Bates numbering", "Number pages across many files for legal filing",
                 synonyms: ["legal", "exhibit", "stamp numbers"], symbol: "number.square", archetype: .livePreview, features: [65],
                 owner: .editKit),
        ToolTile(.stamps, .edit, "Stamps", "Add “Approved”, “Received”, a date or your own stamp",
                 synonyms: ["approved", "draft", "dynamic stamp"], symbol: "seal", archetype: .livePreview, features: [68], owner: .editKit),
        ToolTile(.links, .edit, "Links", "Make text or areas clickable",
                 synonyms: ["hyperlink", "url", "go to page"], symbol: "link", archetype: .livePreview, features: [63], owner: .editKit),
        ToolTile(.contents, .edit, "Contents", "Add a clickable table of contents",
                 synonyms: ["bookmarks", "outline", "chapters", "navigation"], symbol: "list.bullet.indent", archetype: .oneChoice,
                 features: [6], owner: .viewerKit),
        ToolTile(.manyFiles, .edit, "Do this to many files", "Run tools on a whole folder at once",
                 synonyms: ["batch", "action wizard", "routine", "automate"], symbol: "square.stack.3d.up", archetype: .convert,
                 features: [75], owner: .batchKit, needsDocument: false),

        // MARK: Mark up
        ToolTile(.highlightAndNotes, .markUp, "Highlight & notes", "Highlight, underline, add a note",
                 synonyms: ["comment", "annotate", "sticky"], symbol: "highlighter", archetype: .mode, features: [76], owner: .markupKit),
        ToolTile(.drawAndShapes, .markUp, "Draw & shapes", "Pen, arrows, boxes, callouts",
                 synonyms: ["sketch", "ink", "annotate", "cloud"], symbol: "scribble", archetype: .mode, features: [76], owner: .markupKit),
        ToolTile(.commentsList, .markUp, "Comments list", "See and answer every comment",
                 synonyms: ["review", "replies", "resolve", "summary"], symbol: "text.bubble", archetype: .mode, features: [77],
                 owner: .markupKit),
        ToolTile(.attachFile, .markUp, "Attach a file", "Clip a file or a voice note to a page",
                 synonyms: ["attachment", "audio"], symbol: "paperclip", archetype: .oneChoice, features: [79], owner: .markupKit),
        ToolTile(.measure, .markUp, "Measure", "Measure distances and areas on plans",
                 synonyms: ["ruler", "scale", "area", "distance"], symbol: "ruler", archetype: .mode, features: [15], owner: .markupKit),

        // MARK: Sign & fill
        ToolTile(.sign, .signAndFill, "Sign", "Put your signature on the page, or sign with a certificate",
                 synonyms: ["signature", "initials", "e-sign", "digital id"], symbol: "signature", archetype: .mode, features: [82],
                 owner: .signKit),
        ToolTile(.fillForm, .signAndFill, "Fill a form", "Type into the boxes and tick the ticks",
                 synonyms: ["form filler", "autofill"], symbol: "rectangle.and.pencil.and.ellipsis", archetype: .mode, features: [80],
                 owner: .formsKit),
        ToolTile(.makeForm, .signAndFill, "Make a form", "Turn this PDF into a form people can fill in",
                 synonyms: ["prepare form", "fields", "fillable"], symbol: "checklist", archetype: .mode, features: [81], owner: .formsKit),
        ToolTile(.requestSignatures, .signAndFill, "Request signatures", "Send this to people to sign, and track who’s done",
                 synonyms: ["e-signature", "send for signature", "docusign", "agreement"], symbol: "person.2.badge.key", archetype: .flow,
                 features: [84], owner: .signKit),
        ToolTile(.certificates, .signAndFill, "Certificates & signatures", "See who signed, trust people, manage your signing certificate",
                 synonyms: ["verify", "digital id", "trust"], symbol: "checkmark.shield", archetype: .flow, features: [83, 85],
                 owner: .signKit),

        // MARK: Protect
        ToolTile(.addPassword, .protect, "Add a password", "Lock the file so only people with the password can open it",
                 synonyms: ["encrypt", "protect", "permissions", "restrict"], symbol: "lock", archetype: .oneChoice, features: [86],
                 owner: .protectKit),
        ToolTile(.removePassword, .protect, "Remove password", "Save a copy that opens without a password",
                 synonyms: ["unlock", "decrypt", "remove security"], symbol: "lock.open", archetype: .oneChoice, features: [87],
                 owner: .protectKit),
        ToolTile(.blackOut, .protect, "Black out", "Permanently hide names, numbers or anything private",
                 synonyms: ["redact", "censor", "sanitize"], symbol: "text.redaction", archetype: .mode, features: [69], owner: .protectKit),
        ToolTile(.lockIn, .protect, "Lock in notes & fields", "Make notes and form entries part of the page",
                 synonyms: ["flatten", "burn in"], symbol: "square.3.layers.3d.down.right", archetype: .oneChoice, features: [70],
                 owner: .protectKit),
        ToolTile(.removeHiddenInfo, .protect, "Remove hidden info", "Strip metadata, comments and hidden things before sharing",
                 synonyms: ["sanitize", "metadata", "clean"], symbol: "eye.slash", archetype: .oneChoice, features: [88], owner: .protectKit),

        // MARK: Fix & check
        ToolTile(.makeSmaller, .fixAndCheck, "Make smaller", "Shrink the file so it’s easier to send",
                 synonyms: ["compress", "optimize", "reduce file size", "shrink", "email"], symbol: "arrow.down.right.and.arrow.up.left",
                 archetype: .presetAndMore, features: [91], owner: .fixKit),
        ToolTile(.recogniseText, .fixAndCheck, "Recognise text", "Make a scan searchable and copyable",
                 synonyms: ["ocr", "searchable", "scan to text"], symbol: "text.viewfinder", archetype: .presetAndMore, features: [92],
                 owner: .fixKit),
        ToolTile(.compareFiles, .fixAndCheck, "Compare files", "See what changed between two versions",
                 synonyms: ["diff", "differences", "versions"], symbol: "doc.text.magnifyingglass", archetype: .mode, features: [13],
                 owner: .fixKit),
        ToolTile(.checkAccessibility, .fixAndCheck, "Check accessibility", "Make the PDF work with screen readers",
                 synonyms: ["tags", "alt text", "reading order", "pdf/ua", "508"], symbol: "accessibility", archetype: .presetAndMore,
                 features: [97], owner: .fixKit),
        ToolTile(.readAloud, .fixAndCheck, "Read aloud", "Hear the document read to you",
                 synonyms: ["speak", "voice", "listen", "audio"], symbol: "speaker.wave.2", archetype: .oneChoice, features: [3],
                 owner: .viewerKit),
        ToolTile(.checkForPrinting, .fixAndCheck, "Check for printing", "Find problems before sending to a printer",
                 synonyms: ["preflight", "print production", "separations", "cmyk", "bleed"], symbol: "checkmark.seal",
                 archetype: .presetAndMore, features: [94, 95, 96], owner: .fixKit),
        ToolTile(.repair, .fixAndCheck, "Repair", "Fix a file that won’t open properly",
                 synonyms: ["damaged", "corrupt", "recover", "fonts", "fast web view"], symbol: "wrench.and.screwdriver",
                 archetype: .oneChoice, features: [98, 99, 100], owner: .fixKit),

        // MARK: Scan
        ToolTile(.scanWithIPhone, .scan, "Scan with iPhone", "Use your iPhone’s camera as a scanner",
                 synonyms: ["continuity camera", "phone", "document camera"], symbol: "iphone", archetype: .flow, features: [101],
                 owner: .scanKit, needsDocument: false),
        ToolTile(.scanWithScanner, .scan, "Scan with a scanner", "Use a flatbed or sheet-fed scanner",
                 synonyms: ["image capture", "twain", "flatbed"], symbol: "scanner", archetype: .flow, features: [102], owner: .scanKit,
                 needsDocument: false),
        ToolTile(.fromPhoto, .scan, "From a photo", "Straighten and clean up a photo of a page",
                 synonyms: ["perspective", "deskew", "picture"], symbol: "camera", archetype: .flow, features: [103, 104], owner: .scanKit,
                 needsDocument: false),
    ]

    private static let byID: [ToolID: ToolTile] = Dictionary(tiles.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })

    /// The tile for an id; every `ToolID` has one (checked by the self-test).
    public static func tile(_ id: ToolID) -> ToolTile { byID[id]! }

    /// A section's tiles in catalogue order.
    public static func tiles(in section: ToolSection) -> [ToolTile] { tiles.filter { $0.section == section } }

    /// The tiles a module provides.
    public static func tiles(ownedBy module: ModuleID) -> [ToolTile] { tiles.filter { $0.owner == module } }
}
