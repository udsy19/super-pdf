import AppKit
import PDFKit

// Tools are data plus a service (ARCHITECTURE "Rules"). The catalog (Catalogs/ToolCatalog.swift) lists every tile; a
// module implements `ToolProviding` for its tool ids, describing its panel declaratively (`ToolPanel`) and running a
// `ToolRequest` into a `ToolResult`. ToolsKit hosts the panels; DocumentKit applies the results (ux §5, §7).

/// Every tile of the Tools sheet (ux §4.1), in catalogue order. Raw values are stable: they are stored in settings
/// (toolbar, Dock menu), frecency, routines and App Intents.
public enum ToolID: String, Codable, CaseIterable, Sendable {
    // Pages
    case combineFiles = "combine-files", rearrangePages = "rearrange-pages", split, extractPages = "extract-pages"
    case rotatePages = "rotate-pages", deletePages = "delete-pages", crop, insertPages = "insert-pages"
    case numberPages = "number-pages", booklet, resizePages = "resize-pages"
    // Convert
    case toWord = "to-word", toExcel = "to-excel", toPowerPoint = "to-powerpoint", toImages = "to-images"
    case toTextOrWeb = "to-text-or-web", forArchiving = "for-archiving", imagesToPDF = "images-to-pdf"
    case anyFileToPDF = "any-file-to-pdf"
    // Edit
    case editTextAndImages = "edit-text-and-images", headersAndFooters = "headers-and-footers", watermark
    case batesNumbering = "bates-numbering", stamps, links, contents, manyFiles = "many-files"
    // Mark up
    case highlightAndNotes = "highlight-and-notes", drawAndShapes = "draw-and-shapes", commentsList = "comments-list"
    case attachFile = "attach-file", measure
    // Sign & fill
    case sign, fillForm = "fill-form", makeForm = "make-form", requestSignatures = "request-signatures"
    case certificates
    // Protect
    case addPassword = "add-password", removePassword = "remove-password", blackOut = "black-out"
    case lockIn = "lock-in", removeHiddenInfo = "remove-hidden-info"
    // Fix & check
    case makeSmaller = "make-smaller", recogniseText = "recognise-text", compareFiles = "compare-files"
    case checkAccessibility = "check-accessibility", readAloud = "read-aloud", checkForPrinting = "check-for-printing", repair
    // Scan
    case scanWithIPhone = "scan-with-iphone", scanWithScanner = "scan-with-scanner", fromPhoto = "from-photo"
}

/// The Tools sheet's sections in the order of a document's life (ux §4); ⌘1–8 jump to them in this order.
public enum ToolSection: String, Codable, CaseIterable, Sendable {
    case pages, convert, edit, markUp, signAndFill, protect, fixAndCheck, scan

    /// The section header, sentence case (ux §4).
    public var title: String {
        switch self {
        case .pages: "Pages"
        case .convert: "Convert"
        case .edit: "Edit"
        case .markUp: "Mark up"
        case .signAndFill: "Sign & fill"
        case .protect: "Protect"
        case .fixAndCheck: "Fix & check"
        case .scan: "Scan"
        }
    }

    /// The category colour of its tiles' icon circles and panel header icons (ux §2.3).
    public var color: SPColorToken {
        switch self {
        case .pages: SPColor.categoryBlue
        case .convert: SPColor.categoryGreen
        case .edit: SPColor.categoryOrange
        case .markUp: SPColor.categoryYellow
        case .signAndFill: SPColor.categoryPurple
        case .protect: SPColor.categoryRed
        case .fixAndCheck: SPColor.categoryTeal
        case .scan: SPColor.categoryBrown
        }
    }
}

/// The panel shapes of ux §5.2.
public enum ToolArchetype: String, Codable, CaseIterable, Sendable {
    /// A. Scope + one control (or none) + button.
    case oneChoice
    /// B. Three radio presets with a consequence line each, More options for the full set.
    case presetAndMore
    /// C. Controls in the panel, the effect drawn on the page immediately, handles where position matters.
    case livePreview
    /// D. A thin palette; the document becomes interactive; the footer button is "Done".
    case mode
    /// E. Input list or drop zone, output format and location, the engine line, "Save as …".
    case convert
    /// G. Up to three numbered steps in one panel, back/next in the footer. (ux §5.2 has no F: that shape served AI tools,
    /// which Super PDF does not have.)
    case flow

    public var letter: String {
        switch self {
        case .oneChoice: "A"
        case .presetAndMore: "B"
        case .livePreview: "C"
        case .mode: "D"
        case .convert: "E"
        case .flow: "G"
        }
    }
}

/// The modules of ARCHITECTURE "Modules" that own something in a catalog (the tool tiles' providers).
public enum ModuleID: String, Codable, CaseIterable, Sendable {
    case documentKit = "DocumentKit", viewerKit = "ViewerKit", toolsKit = "ToolsKit", pagesKit = "PagesKit"
    case convertKit = "ConvertKit", editKit = "EditKit", markupKit = "MarkupKit", formsKit = "FormsKit"
    case signKit = "SignKit", protectKit = "ProtectKit", fixKit = "FixKit", scanKit = "ScanKit"
    case batchKit = "BatchKit", settingsKit = "SettingsKit"
}

/// One tile of the Tools sheet (ux §4.1): what it is called, what it says, how people search for it, how its panel is
/// shaped, which features it covers and which module provides it.
public struct ToolTile: Hashable, Identifiable, Sendable {
    public var id: ToolID
    public var section: ToolSection
    /// Plain name, sentence case: "Make smaller".
    public var name: String
    /// The second line: "Shrink the file so it’s easier to send".
    public var hint: String
    /// Jargon and other words that find it, lower-cased: "compress", "optimize".
    public var synonyms: [String]
    /// SF Symbol shown in the category-coloured circle.
    public var symbol: String
    public var archetype: ToolArchetype
    /// `features.md` numbers this tile covers.
    public var features: [Int]
    /// The module whose `ToolProviding` serves it.
    public var owner: ModuleID
    /// False for tools that start from files instead of an open document (Combine, conversions into PDF, scanning,
    /// "Do this to many files"): the welcome window and the Dock menu can open them.
    public var needsDocument: Bool

    public init(_ id: ToolID, _ section: ToolSection, _ name: String, _ hint: String, synonyms: [String], symbol: String,
                archetype: ToolArchetype, features: [Int], owner: ModuleID, needsDocument: Bool = true) {
        self.id = id; self.section = section; self.name = name; self.hint = hint; self.synonyms = synonyms; self.symbol = symbol
        self.archetype = archetype; self.features = features; self.owner = owner; self.needsDocument = needsDocument
    }

    /// The Tools menu item (ux §4, §8): title case with an ellipsis, "Rotate Pages…".
    public var menuTitle: String { Strings.menuTitle(name) + "…" }
}

/// Whether a tile can run right now (ux §4): unavailable tiles stay visible with a grey badge, and clicking explains in
/// the panel.
public enum ToolAvailability: Hashable, Sendable {
    case ready
    /// Continuity Camera needs an iPhone or iPad nearby.
    case needsDevice
    /// The input needs the LibreOffice helper.
    case needsConverter
    /// Anything else, with the sentence the panel shows.
    case unavailable(String)

    /// The badge text (ux §4); nil when ready, and for `.unavailable`, whose sentence the panel shows instead.
    public var badge: String? {
        switch self {
        case .ready, .unavailable: nil
        case .needsDevice: Strings.ToolsSheet.badgeNeedsDevice
        case .needsConverter: Strings.ToolsSheet.badgeInstallConverter
        }
    }
}

// MARK: - Panel values

/// One value of a panel control, as a run receives it and a routine stores it.
public enum ToolValue: Codable, Hashable, Sendable {
    case bool(Bool)
    case int(Int)
    case double(Double)
    case string(String)
    case strings([String])
    case files([URL])
}

/// The values of a panel's controls by control id. Routines save these with the tool id (features #75).
public struct ToolValues: Codable, Hashable, Sendable {
    public var storage: [String: ToolValue]

    public init(_ storage: [String: ToolValue] = [:]) { self.storage = storage }

    public subscript(_ id: String) -> ToolValue? {
        get { storage[id] }
        set { storage[id] = newValue }
    }

    public func bool(_ id: String, default fallback: Bool = false) -> Bool {
        if case .bool(let v) = storage[id] { return v }
        return fallback
    }

    public func int(_ id: String, default fallback: Int = 0) -> Int {
        if case .int(let v) = storage[id] { return v }
        return fallback
    }

    public func double(_ id: String, default fallback: Double = 0) -> Double {
        switch storage[id] {
        case .double(let v): v
        case .int(let v): Double(v)
        default: fallback
        }
    }

    public func string(_ id: String, default fallback: String = "") -> String {
        if case .string(let v) = storage[id] { return v }
        return fallback
    }

    public func strings(_ id: String) -> [String] {
        if case .strings(let v) = storage[id] { return v }
        return []
    }

    public func files(_ id: String) -> [URL] {
        if case .files(let v) = storage[id] { return v }
        return []
    }
}

// MARK: - Panel description

/// A choice in a segmented control, radio group or popup.
public struct ToolOption: Hashable, Sendable {
    public var id: String
    public var title: String
    /// The consequence line of a preset ("≈ 1.7 MB"), or a popup item's secondary text.
    public var detail: String?
    public var symbol: String?

    public init(_ id: String, _ title: String, detail: String? = nil, symbol: String? = nil) {
        self.id = id; self.title = title; self.detail = detail; self.symbol = symbol
    }
}

/// How a slider shows its value on the right (ux §5.1: "30%").
public enum ToolValueFormat: String, Sendable {
    case plain, percent, points, dpi, degrees
}

/// One control of a panel, in the order shown (ux §5.1). Each `id` keys its value in `ToolValues`; the value given
/// here is the default ToolsKit starts from (or the remembered one).
public enum ToolControl {
    case segmented(id: String, options: [ToolOption], selected: String)
    case radio(id: String, options: [ToolOption], selected: String)
    /// At most seven items (ux §5.1).
    case popup(id: String, label: String, options: [ToolOption], selected: String)
    case slider(id: String, label: String, range: ClosedRange<Double>, step: Double, value: Double, format: ToolValueFormat)
    case stepper(id: String, label: String, range: ClosedRange<Int>, value: Int)
    /// The label says what it does ("Also remove hidden information").
    case toggle(id: String, label: String, isOn: Bool)
    case text(id: String, label: String?, placeholder: String, value: String, isSecure: Bool)
    /// A drop zone with a list (Combine queue, Compare's "Compare with", Images → PDF); `types` are UTType identifiers.
    case files(id: String, label: String, types: [String], allowsMultiple: Bool)
    /// A 3×3 or 3×2 dot grid (watermark position, page-number position); `selected` counts row by row from the top left.
    case positionGrid(id: String, columns: Int, rows: Int, selected: Int)
    /// A button inside the panel ("Remove white margins", "Find fields for me"); runs `ToolProviding.handle(action:)`.
    case action(id: String, title: String, isDestructive: Bool)
    /// A line of text ("Now: 6.1 MB", "14 of 20 pages have no text yet").
    case note(String)
    /// The provider's own view: palettes of mode tools, flow steps.
    case custom(id: String, make: @MainActor () -> NSView)

    /// The value key; nil for notes.
    public var id: String? {
        switch self {
        case .segmented(let id, _, _), .radio(let id, _, _), .popup(let id, _, _, _), .slider(let id, _, _, _, _, _),
             .stepper(let id, _, _, _), .toggle(let id, _, _), .text(let id, _, _, _, _), .files(let id, _, _, _),
             .positionGrid(let id, _, _, _), .action(let id, _, _), .custom(let id, _):
            id
        case .note:
            nil
        }
    }

    /// The value this control starts with; nil for controls that hold none (notes, actions, custom views).
    public var initialValue: ToolValue? {
        switch self {
        case .segmented(_, _, let selected), .radio(_, _, let selected), .popup(_, _, _, let selected): .string(selected)
        case .slider(_, _, _, _, let value, _): .double(value)
        case .stepper(_, _, _, let value): .int(value)
        case .toggle(_, _, let isOn): .bool(isOn)
        case .text(_, _, _, let value, _): .string(value)
        case .files: .files([])
        case .positionGrid(_, _, _, let selected): .int(selected)
        case .action, .note, .custom: nil
        }
    }
}

/// The panel's primary or secondary button: one verb (ux §1.1), the count when destructive ("Delete 3 pages").
public struct ToolButton: Hashable, Sendable {
    public var title: String
    public var isEnabled: Bool
    /// Red (Black out, "Remove watermark").
    public var isDestructive: Bool

    public init(_ title: String, isEnabled: Bool = true, isDestructive: Bool = false) {
        self.title = title; self.isEnabled = isEnabled; self.isDestructive = isDestructive
    }
}

/// A message inside the panel above the footer (ux §5.1 Errors, §7.4): what happened and one action that fixes it.
public struct ToolMessage: Hashable, Sendable {
    public enum Kind: String, Sendable { case info, warning, error }

    public var kind: Kind
    public var text: String
    /// The fixing action's title and the id passed to `ToolProviding.handle(action:)`.
    public var action: ToolOption?
    /// Revealed by "Show details" (never on the surface).
    public var details: String?

    public init(_ kind: Kind, _ text: String, action: ToolOption? = nil, details: String? = nil) {
        self.kind = kind; self.text = text; self.action = action; self.details = details
    }
}

/// A confirmation sheet before the run (Black out: "This permanently removes 12 items…").
public struct ToolConfirmation: Hashable, Sendable {
    public var message: String
    public var confirm: ToolButton

    public init(message: String, confirm: ToolButton) { self.message = message; self.confirm = confirm }
}

/// A panel, as a provider describes it for the current values; ToolsKit renders it in the shape of its archetype
/// (ux §5.1–§5.2) and asks again whenever a value changes (debounced, ux §2.5).
public struct ToolPanel {
    public var archetype: ToolArchetype
    /// A line under the hint (Crop's "Cropping hides content without removing it…").
    public var notice: String?
    /// Shows the "Pages:" scope popup under the hint.
    public var showsScope: Bool
    /// Archetype G's numbered steps ("Who", "Where", "Send"); `currentStep` is 0-based.
    public var steps: [String]
    public var currentStep: Int
    /// At most three visible controls (ux §5.1).
    public var controls: [ToolControl]
    /// Behind the "More options" disclosure, closed by default.
    public var moreOptions: [ToolControl]
    public var primary: ToolButton
    /// Cancel by default; a red text button when relevant ("Remove watermark").
    public var secondary: ToolButton?
    /// Drives the "Saves “Report (smaller).pdf” next to the original · Change…" line.
    public var output: OutputPolicy
    public var message: ToolMessage?
    public var confirmation: ToolConfirmation?

    public init(_ archetype: ToolArchetype, notice: String? = nil, showsScope: Bool = false, steps: [String] = [], currentStep: Int = 0,
                controls: [ToolControl] = [], moreOptions: [ToolControl] = [], primary: ToolButton,
                secondary: ToolButton? = ToolButton(Strings.Panel.cancel), output: OutputPolicy = .inPlace,
                message: ToolMessage? = nil, confirmation: ToolConfirmation? = nil) {
        self.archetype = archetype; self.notice = notice; self.showsScope = showsScope; self.steps = steps
        self.currentStep = currentStep; self.controls = controls; self.moreOptions = moreOptions; self.primary = primary
        self.secondary = secondary; self.output = output; self.message = message; self.confirmation = confirmation
    }

    /// The values every control starts with.
    public var initialValues: ToolValues {
        var values = ToolValues()
        for control in controls + moreOptions {
            if let id = control.id, let value = control.initialValue { values[id] = value }
        }
        return values
    }
}

/// What a provider knows while its panel is open.
@MainActor
public struct ToolContext {
    public var tool: ToolID
    /// Nil when the tool started without a document (`ToolTile.needsDocument == false`).
    public var document: DocumentHandle?
    /// Selected thumbnails (0-based).
    public var selection: [Int]
    public var currentPage: Int
    public var scope: Scope
    public var values: ToolValues
    /// Files dropped on the tile or the panel.
    public var inputs: [URL]

    public init(tool: ToolID, document: DocumentHandle? = nil, selection: [Int] = [], currentPage: Int = 0, scope: Scope = .all,
                values: ToolValues = ToolValues(), inputs: [URL] = []) {
        self.tool = tool; self.document = document; self.selection = selection; self.currentPage = currentPage
        self.scope = scope; self.values = values; self.inputs = inputs
    }
}

/// One run of a tool: on an open document, or on files (batch, Quick Actions, App Intents).
@MainActor
public struct ToolRequest {
    public var tool: ToolID
    public var document: DocumentHandle?
    /// The bytes to work on off the main actor (`document.snapshot()` or a file).
    public var source: PDFSource?
    /// The scope's pages, resolved (0-based, sorted).
    public var pages: [Int]
    public var values: ToolValues
    public var inputs: [URL]
    /// Where the output goes, resolved by DocumentKit from the panel's `OutputPolicy` (the name shown in the panel);
    /// nil for in-place tools.
    public var destination: URL?
    /// A fresh scratch folder for this run: write outputs here; DocumentKit moves them to `destination`.
    public var workFolder: URL

    public init(tool: ToolID, document: DocumentHandle? = nil, source: PDFSource? = nil, pages: [Int] = [], values: ToolValues = ToolValues(),
                inputs: [URL] = [], destination: URL? = nil, workFolder: URL) {
        self.tool = tool; self.document = document; self.source = source; self.pages = pages; self.values = values
        self.inputs = inputs; self.destination = destination; self.workFolder = workFolder
    }
}

/// Progress of a run (ux §5.1: "Page 14 of 120 · Stop"; thumbnails tick as pages complete). Safe to call from any
/// thread; cancellation is the run's task being cancelled ("Stop").
public struct ToolProgress: Sendable {
    public struct Update: Hashable, Sendable {
        public var completed: Int
        public var total: Int
        /// The page just finished, so its thumbnail can tick.
        public var page: Int?
        /// Replaces "Page 14 of 120" when the work isn't per page ("Converting “Budget.xlsx”…").
        public var label: String?

        public init(completed: Int, total: Int, page: Int? = nil, label: String? = nil) {
            self.completed = completed; self.total = total; self.page = page; self.label = label
        }

        public var fraction: Double { total > 0 ? Double(completed) / Double(total) : 0 }
    }

    private let handler: @Sendable (Update) -> Void

    public init(_ handler: @escaping @Sendable (Update) -> Void) { self.handler = handler }

    public func report(_ update: Update) { handler(update) }

    public func report(completed: Int, of total: Int, page: Int? = nil, label: String? = nil) {
        handler(Update(completed: completed, total: total, page: page, label: label))
    }

    /// Discards updates (tests, batch steps that report elsewhere).
    public static let ignored = ToolProgress { _ in }
}

/// The live effect while a panel is open (ux §5.1 "Live preview"): drawn over the pages, not committed; or, for
/// file-level tools without a visual effect, a before → after summary.
public enum ToolPreview {
    case none
    /// Drawn over each visible page in page space (points, origin at the crop box's lower-left); ToolsKit hosts it in a
    /// `PDFPageOverlayViewProvider`.
    case overlay(@MainActor (_ page: PDFPage, _ context: CGContext) -> Void)
    /// Lines like "Now: 6.1 MB", "Pages: 12", "Converted by: LibreOffice".
    case summary([String])
}

// MARK: - Results

/// What happened, as DocumentKit applies it (ux §7). No module writes to the open file's URL itself.
public enum ToolResult {
    /// The open document was edited; DocumentKit registers the undo under its action name. No banner for page edits
    /// (ux §7.3: "the sidebar shows it and ⌘Z works").
    case inPlace(undoable: UndoGroup, banner: ResultBanner?)
    /// One file written in the run's work folder; DocumentKit moves it to the request's destination and, for PDFs,
    /// opens it in a new tab.
    case newFile(URL, banner: ResultBanner)
    /// Several files (Split, To images); DocumentKit moves them into the destination folder.
    case newFiles([URL], banner: ResultBanner)
    /// A new unsaved document (Combine: "Combined.pdf"; Images → PDF; Any file → PDF); the first ⌘S shows the save panel.
    case newDocument(Data, name: String, banner: ResultBanner?)
    /// Nothing to apply (a mode closed with Done, a check whose report stays in the panel).
    case none
}

/// The result banner under the toolbar (ux §7.3): one sentence with the numbers, then up to three actions.
public struct ResultBanner: Hashable, Sendable {
    public enum Action: Hashable, Sendable {
        case showInFinder
        case share
        case undo
        /// "Save…" (Combine's unsaved result).
        case save
        /// "Open in Word" — the app that owns the output.
        case openIn(appName: String)
        /// "Show requests" (Window › Signature Requests).
        case showRequests
        /// "Show" (the PDF/A problems).
        case showDetails

        public var title: String {
            switch self {
            case .showInFinder: Strings.Banner.showInFinder
            case .share: Strings.Banner.share
            case .undo: Strings.Banner.undo
            case .save: Strings.Banner.save
            case .openIn(let app): Strings.Banner.openIn(app)
            case .showRequests: Strings.Banner.showRequests
            case .showDetails: Strings.Banner.show
            }
        }
    }

    public var text: String
    /// Substrings set in semibold (the numbers, ux §2.2).
    public var emphasis: [String]
    public var actions: [Action]
    /// The file the actions act on, once DocumentKit knows its final place.
    public var file: URL?

    public init(_ text: String, emphasis: [String] = [], actions: [Action] = [], file: URL? = nil) {
        self.text = text; self.emphasis = emphasis; self.actions = actions; self.file = file
    }
}

/// Where a tool's output goes (ux §7.2). DocumentKit turns it into a URL (`DocumentManaging.destination`), adding " 2"
/// on collisions; the panel shows the name with "Change…".
public enum OutputPolicy: Codable, Hashable, Sendable {
    /// An undoable edit of the open document.
    case inPlace
    /// "<name> (<suffix>).<ext>" next to the original.
    case sibling(OutputSuffix, ext: String)
    /// The same name in another format next to the original ("Report.docx"), through a save panel.
    case sameName(ext: String)
    /// A folder next to the original ("Report parts", "Report images") holding several files.
    case folder(OutputFolder)
    /// A new unsaved document with this name ("Combined").
    case newDocument(name: String)
}

/// The suffixes of ux §7.2 (and §7.1's "edited"), in the words people see.
public enum OutputSuffix: Codable, Hashable, Sendable {
    case edited, smaller, blackedOut, protected, noPassword, lockedIn, signed, archive, clean, repaired
    /// "part 1"
    case part(Int)
    /// "pages 3-5"
    case pages(PageRanges)

    public var word: String {
        switch self {
        case .edited: "edited"
        case .smaller: "smaller"
        case .blackedOut: "blacked out"
        case .protected: "protected"
        case .noPassword: "no password"
        case .lockedIn: "locked in"
        case .signed: "signed"
        case .archive: "archive"
        case .clean: "clean"
        case .repaired: "repaired"
        case .part(let n): "part \(n)"
        case .pages(let ranges): "pages " + ranges.ranges.map {
            $0.lowerBound == $0.upperBound ? "\($0.lowerBound + 1)" : "\($0.lowerBound + 1)-\($0.upperBound + 1)"
        }.joined(separator: ",")
        }
    }

    /// The file name for a document called `base`: "Report (smaller).pdf"; parts and page extracts use the en-dash form
    /// the Split panel and page drags show (ux §5.3, §3): "Report – part 1.pdf", "Report – pages 3-5.pdf".
    public func fileName(base: String, ext: String) -> String {
        switch self {
        case .part, .pages: "\(base) – \(word).\(ext)"
        default: "\(base) (\(word)).\(ext)"
        }
    }
}

/// The folders of multi-file outputs (ux §5.3, §7.3): "Report parts", "Report images".
public enum OutputFolder: String, Codable, Hashable, Sendable {
    case parts, images

    public func folderName(base: String) -> String { "\(base) \(rawValue)" }
}
