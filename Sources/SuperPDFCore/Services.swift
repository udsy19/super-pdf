import Foundation
import os

/// Late-bound registry: each module's `install()` assigns its implementations at launch, in the order the app target
/// calls them (docs/ARCHITECTURE.md "Launch sequence"). Modules reach each other only through these. Every slot has one
/// owner; the comment names it.
@MainActor
public enum Services {
    // DocumentKit
    public static var documents: DocumentManaging!

    // LayoutKit, RenderKit (shared analysis modules)
    public static var layout: LayoutAnalyzing!
    public static var render: Rendering!

    // PagesKit
    public static var pages: PageEditing!

    // ConvertKit
    public static var convert: Converting!
    public static var helpers: HelperManaging!

    // EditKit
    public static var edit: ContentEditing!

    // MarkupKit
    public static var markup: Annotating!

    // FormsKit
    public static var forms: FormServicing!

    // SignKit
    public static var sign: Signing!
    public static var requests: SignatureRequesting!

    // ProtectKit
    public static var protect: Protecting!

    // FixKit
    public static var fix: Fixing!

    // ScanKit
    public static var scan: Scanning!

    // BatchKit
    public static var batch: BatchRunning!

    // ToolsKit: collects `toolProviders` at install and verifies every catalog tile has exactly one provider.
    public static var tools: ToolRegistry!

    // ViewerKit
    public static var viewer: ViewerPresenting!

    // SettingsKit
    public static var settings: SettingsPresenting!

    // The app target (the UpdateKit engine)
    public static var updates: UpdateChecking!

    /// Every module that ships tools appends its provider here in `install()`; ToolsKit installs after them and reads
    /// the list (ARCHITECTURE "Launch sequence" step 2).
    public static var toolProviders: [any ToolProviding] = []
}

/// Where Super PDF keeps its files (ARCHITECTURE "Data"): ~/Library/Application Support/Super PDF/.
public enum SuperPDFPaths {
    public static let bundleID = "com.udsy.superpdf"
    public static let supportFolderName = "Super PDF"
    /// Keychain service of the signature images key and other app secrets.
    public static let keychainService = "com.udsy.superpdf"
    /// Per-document view state lives in this extended attribute of the PDF, never inside it.
    public static let viewStateAttribute = "com.udsy.superpdf.viewstate"
    /// The `superpdf://` URL scheme (features #1).
    public static let urlScheme = "superpdf"
    public static let repository = URL(string: "https://github.com/udsy19/super-pdf")!

    /// The folder `support` lives in (Application Support). The self-test points it at a temporary folder.
    nonisolated(unsafe) public static var base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]

    public static var support: URL { ensure(base.appendingPathComponent(supportFolderName, isDirectory: true)) }
    /// Helper state: LibreOffice's private profile (features §3.2; LibreOffice itself is the person's own install).
    public static var helpers: URL { ensure(support.appendingPathComponent("Helpers", isDirectory: true)) }
    /// LibreOffice's private profile (`-env:UserInstallation=`), so runs never touch the user's own profile.
    public static var libreOfficeProfile: URL { ensure(helpers.appendingPathComponent("lo-profile", isDirectory: true)) }
    /// Signing packages, returned copies and audit data, one folder per request (features #84).
    public static var requests: URL { ensure(support.appendingPathComponent("Requests", isDirectory: true)) }
    public static func request(_ id: UUID) -> URL {
        ensure(requests.appendingPathComponent(id.uuidString.lowercased(), isDirectory: true))
    }
    /// Signature images (encrypted with the Keychain-held key).
    public static var signatures: URL { ensure(support.appendingPathComponent("Signatures", isDirectory: true)) }
    /// Folder search indexes, `Index/<folder-hash>.sqlite` (features #115).
    public static var index: URL { ensure(support.appendingPathComponent("Index", isDirectory: true)) }
    /// Saved routines, `Routines/<id>.json` (features #75).
    public static var routines: URL { ensure(support.appendingPathComponent("Routines", isDirectory: true)) }
    /// Custom stamps (features #68).
    public static var stamps: URL { ensure(support.appendingPathComponent("Stamps", isDirectory: true)) }
    /// Scratch space for tool runs: outputs are written here, then moved into place by DocumentKit.
    public static var work: URL { ensure(FileManager.default.temporaryDirectory.appendingPathComponent("Super PDF", isDirectory: true)) }

    /// Free bytes for important use on the volume that holds `url`; `Int64.max` when the system can't say.
    public static func freeSpace(at url: URL) -> Int64 {
        (try? url.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey]))?.volumeAvailableCapacityForImportantUsage ?? .max
    }

    @discardableResult public static func ensure(_ url: URL) -> URL {
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }
}

/// Unified-log categories, one per module (local only; no telemetry, ARCHITECTURE "Rules").
public enum Log {
    private static let subsystem = Bundle.main.bundleIdentifier ?? SuperPDFPaths.bundleID
    public static let app = Logger(subsystem: subsystem, category: "app")
    public static let documents = Logger(subsystem: subsystem, category: "documents")
    public static let viewer = Logger(subsystem: subsystem, category: "viewer")
    public static let tools = Logger(subsystem: subsystem, category: "tools")
    public static let pages = Logger(subsystem: subsystem, category: "pages")
    public static let convert = Logger(subsystem: subsystem, category: "convert")
    public static let edit = Logger(subsystem: subsystem, category: "edit")
    public static let markup = Logger(subsystem: subsystem, category: "markup")
    public static let forms = Logger(subsystem: subsystem, category: "forms")
    public static let sign = Logger(subsystem: subsystem, category: "sign")
    public static let protect = Logger(subsystem: subsystem, category: "protect")
    public static let fix = Logger(subsystem: subsystem, category: "fix")
    public static let scan = Logger(subsystem: subsystem, category: "scan")
    public static let batch = Logger(subsystem: subsystem, category: "batch")
    public static let settings = Logger(subsystem: subsystem, category: "settings")
    public static let layout = Logger(subsystem: subsystem, category: "layout")
    public static let render = Logger(subsystem: subsystem, category: "render")
    public static let pdfModel = Logger(subsystem: subsystem, category: "pdf-model")
    public static let updates = Logger(subsystem: subsystem, category: "updates")
}
