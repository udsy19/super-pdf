import Foundation

// Fix, check and optimise (FixKit: `Services.fix`; features #91–#100, #13, #120, #123).

/// The three sizes of "Make smaller" (ux §5.3), Acrobat's large/medium/small.
public enum SizePreset: String, Codable, CaseIterable, Sendable {
    /// "Good (recommended)"
    case good
    /// "Email (smallest)"
    case email
    /// "Best quality"
    case best
}

/// The optimiser settings behind "More options" (features #91, Acrobat's Optimizer panels).
public struct OptimizeOptions: Codable, Hashable, Sendable {
    public var preset: SizePreset
    /// "Picture sharpness": target resolution for colour and grey images (72/150/300).
    public var imageDPI: Double
    /// JPEG quality 0…1.
    public var imageQuality: Double
    public var removeCommentsAndForms: Bool
    public var removeBookmarksAndAttachments: Bool
    /// "Remove extra fonts": unembed the standard 14.
    public var removeExtraFonts: Bool
    /// "Make pages load fast on the web" (linearize).
    public var linearize: Bool
    public var removeMetadata: Bool
    public var removeThumbnails: Bool
    public var removeScripts: Bool
    public var flattenLayers: Bool
    public var compressObjectStreams: Bool

    public init(preset: SizePreset = .good, imageDPI: Double = 150, imageQuality: Double = 0.75, removeCommentsAndForms: Bool = false,
                removeBookmarksAndAttachments: Bool = false, removeExtraFonts: Bool = false, linearize: Bool = false,
                removeMetadata: Bool = false, removeThumbnails: Bool = true, removeScripts: Bool = false, flattenLayers: Bool = false,
                compressObjectStreams: Bool = true) {
        self.preset = preset; self.imageDPI = imageDPI; self.imageQuality = imageQuality
        self.removeCommentsAndForms = removeCommentsAndForms; self.removeBookmarksAndAttachments = removeBookmarksAndAttachments
        self.removeExtraFonts = removeExtraFonts; self.linearize = linearize; self.removeMetadata = removeMetadata
        self.removeThumbnails = removeThumbnails; self.removeScripts = removeScripts; self.flattenLayers = flattenLayers
        self.compressObjectStreams = compressObjectStreams
    }
}

/// Where a file's bytes go ("Audit space usage", features #91).
public struct SpaceAudit: Hashable, Sendable {
    public var images: Int64
    public var fonts: Int64
    public var content: Int64
    public var structure: Int64
    public var attachments: Int64

    public init(images: Int64, fonts: Int64, content: Int64, structure: Int64, attachments: Int64) {
        self.images = images; self.fonts = fonts; self.content = content; self.structure = structure; self.attachments = attachments
    }
}

/// OCR settings (features #92; ux §5.3 Recognise text).
public struct OCROptions: Codable, Hashable, Sendable {
    /// BCP-47 codes; empty means automatic.
    public var languages: [String]
    /// "Clean up the scan first (straighten, whiten)".
    public var cleanUp: Bool
    /// "Make text editable (replaces the picture with real text)".
    public var editableText: Bool
    public var dpi: Double

    public init(languages: [String] = [], cleanUp: Bool = true, editableText: Bool = false, dpi: Double = 300) {
        self.languages = languages; self.cleanUp = cleanUp; self.editableText = editableText; self.dpi = dpi
    }
}

public struct OCRReport: Hashable, Sendable {
    /// The document with its invisible text layer.
    public var data: Data
    public var recognizedPages: Int
    /// Pages where nothing was found ("2 pages had no text").
    public var emptyPages: Int

    public init(data: Data, recognizedPages: Int, emptyPages: Int) {
        self.data = data; self.recognizedPages = recognizedPages; self.emptyPages = emptyPages
    }
}

/// The checks of "Check accessibility", "Check for printing" and "Check PDF/A" (features #93, #94, #97).
public enum CheckProfile: Codable, Hashable, Sendable {
    case accessibility
    case printing
    case pdfA(PDFALevel)
}

/// One finding of a check, grouped Pass / Needs attention / Failed (ux §5.3).
public struct CheckIssue: Codable, Hashable, Identifiable, Sendable {
    public enum Severity: String, Codable, Sendable { case passed, needsAttention, failed }

    /// Stable rule id ("title", "language", "alt-text", "fonts-embedded").
    public var id: String
    public var severity: Severity
    public var title: String
    /// Pages it concerns (0-based).
    public var pages: [Int]
    /// The automatic fix's button title ("Set the language to English"); nil when there is none.
    public var fixTitle: String?

    public init(id: String, severity: Severity, title: String, pages: [Int] = [], fixTitle: String? = nil) {
        self.id = id; self.severity = severity; self.title = title; self.pages = pages; self.fixTitle = fixTitle
    }
}

/// What "Repair" can say before it runs (ux §5.3: "The file's index is damaged").
public struct RepairDiagnosis: Hashable, Sendable {
    public var problems: [String]
    public var missingFonts: [String]

    public init(problems: [String], missingFonts: [String] = []) { self.problems = problems; self.missingFonts = missingFonts }
}

/// One difference of "Compare files" (features #13).
public struct ComparisonChange: Codable, Hashable, Sendable {
    public enum Kind: String, Codable, Sendable { case inserted, deleted, changed, visual }

    public var kind: Kind
    /// Pages in the older and the newer file (0-based).
    public var oldPage: Int?
    public var newPage: Int?
    public var oldText: String?
    public var newText: String?

    public init(kind: Kind, oldPage: Int?, newPage: Int?, oldText: String? = nil, newText: String? = nil) {
        self.kind = kind; self.oldPage = oldPage; self.newPage = newPage; self.oldText = oldText; self.newText = newText
    }
}

@MainActor
public protocol Optimizing: AnyObject {
    /// Estimated output size for a preset, from a page sample, within a second (ux §5.3).
    func estimate(_ source: PDFSource, options: OptimizeOptions) async throws -> Int64
    func optimize(_ source: PDFSource, options: OptimizeOptions, to destination: URL, progress: ToolProgress) async throws
    func audit(_ source: PDFSource) async throws -> SpaceAudit
}

@MainActor
public protocol OCRing: AnyObject {
    /// Pages without a text layer (0-based), for "14 of 20 pages have no text yet".
    func pagesWithoutText(in document: DocumentHandle) -> [Int]
    func recognize(_ source: PDFSource, pages: [Int], options: OCROptions, progress: ToolProgress) async throws -> OCRReport
}

@MainActor
public protocol Checking: AnyObject {
    func check(_ source: PDFSource, profile: CheckProfile, progress: ToolProgress) async throws -> [CheckIssue]
    /// Applies the automatic fixes for `issueIDs` into a new file.
    func fix(_ issueIDs: [String], in source: PDFSource, profile: CheckProfile, to destination: URL) async throws
}

@MainActor
public protocol Repairing: AnyObject {
    func diagnose(_ url: URL) async -> RepairDiagnosis?
    /// QPDF recovery, optionally embedding missing fonts available on this Mac (features #98, #100).
    func repair(_ source: PDFSource, embedFonts: Bool, to destination: URL) async throws -> RepairDiagnosis
    /// "Fast web view" (features #99).
    func linearize(_ source: PDFSource, to destination: URL) async throws
}

/// Fix and check (FixKit), plus Compare files.
@MainActor
public protocol Fixing: Optimizing, OCRing, Checking, Repairing {
    func compare(_ old: PDFSource, with new: PDFSource, textOnly: Bool, progress: ToolProgress) async throws -> [ComparisonChange]
}
