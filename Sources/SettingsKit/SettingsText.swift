import Foundation
import SuperPDFCore

// The settings window's copy (ux §6.6; ux §1.1 tone) and the sentences it builds from live state, kept apart from the
// views so the self-test reads them.
enum SettingsText {
    // MARK: General

    static let openInTabs = "Open documents in tabs"
    static let saveBehaviour = "When saving a file you opened"
    static func saveBehaviour(_ value: SaveBehaviour) -> String {
        switch value {
        case .ask: "Ask each time"
        case .alwaysSaveCopy: "Always save a copy"
        case .replaceOriginal: "Replace the original"
        }
    }
    static let authorName = "Author name"
    static let authorNamePlaceholder = "From your contact card"
    static let authorNameNote = "The name on your notes and markup."
    static let defaultZoom = "New documents open at"
    static func defaultZoom(_ value: DefaultZoom) -> String {
        switch value {
        case .scaleToFit: "Zoom to Fit"
        case .actualSize: "Actual Size"
        }
    }
    static let textSize = "Text size"
    static func textSize(_ value: TextSize) -> String {
        switch value {
        case .default: "Default"
        case .larger: "Larger"
        case .largest: "Largest"
        }
    }

    static let openPDFsWith = "Open PDFs with Super PDF"
    static func pdfApp(_ state: DefaultPDFApp.State) -> String {
        switch state {
        case .thisApp: "Currently: Super PDF"
        case .other(let name): "Currently: \(name)"
        case .unknown: "Currently: no app chosen"
        }
    }
    static let makeDefault = "Make Super PDF the PDF App…"
    static let pdfAppNote = "Finder, Quick Look and Mail then open PDFs here. macOS asks you to confirm."
    static func pdfAppFailed(_ reason: String) -> String { "Couldn’t change it. \(reason)" }

    // MARK: Tools

    static let showRecentlyUsed = "Show “Recently used” in the Tools sheet"
    static let showJargon = "Show the expert names in hints, like “Make smaller (Compress)”"
    static let toolbarTools = "In the toolbar"
    static let dockMenuTools = "In the Dock menu"
    static let noFavourites = "None yet. Right-click a tool in the Tools sheet to add it."
    static let remove = "Remove"

    // MARK: Converters

    static let libreOffice = "LibreOffice"
    static func libreOffice(_ status: HelperStatus) -> String {
        switch status {
        case .notInstalled:
            "Not installed. Spreadsheets and presentations saved by LibreOffice (.ods, .odp), older Office files (.xls, .ppt) and Hangul files (.hwp) need it."
        case .installed(let soffice, let version):
            "Installed\(version.map { " (version \($0))" } ?? "") at \(appPath(of: soffice))."
        }
    }
    static let getLibreOffice = Strings.Errors.getLibreOffice
    static let chooseLibreOffice = "Choose…"
    static let lookAgain = "Look Again"
    static let useFoundCopy = "Use the One Found Automatically"
    static let libreOfficeNotice = "LibreOffice is a separate free app by The Document Foundation, under the Mozilla Public License 2.0. Super PDF doesn’t include it or download it; it runs the copy on this Mac, offline."
    static let officeApps = "Apps that can export"
    static let noOfficeApps = "None found. Word, Excel, PowerPoint, Pages, Numbers and Keynote are used when they’re installed."
    static func officeApps(_ apps: [OfficeApp]) -> String { apps.map(\.name).joined(separator: ", ") }

    /// "/Applications/LibreOffice.app" for its soffice executable.
    static func appPath(of soffice: URL) -> String {
        var url = soffice
        while url.pathComponents.count > 1, url.pathExtension != "app" { url.deleteLastPathComponent() }
        return url.pathExtension == "app" ? url.path : soffice.path
    }

    // MARK: Signatures

    static let myCertificate = "My certificate"
    static let noCertificate = "None yet"
    static let certificatesNote = "Create, import and export certificates with Tools › Certificates & Signatures."
    static let trustedPeople = "People I trust"
    static let nobodyTrusted = "Nobody yet. When someone sends you their certificate, choose “Trust this person”."
    static let addTimestamp = "Add a trusted timestamp to certificate signatures"
    static let timestampServer = "Timestamp server"
    static let timestampPlaceholder = "https://timestamp.example.com"
    static let timestampNote = "Signing then sends a fingerprint of the signed file (never the file) to this server."

    // MARK: Scanning

    static let resolution = "Resolution"
    static func resolution(_ dpi: Int) -> String { "\(dpi) dpi" }
    static let resolutions = [150, 300, 600]
    static let colorMode = "Colour"
    static func colorMode(_ mode: ScanColorMode) -> String {
        switch mode {
        case .color: "Colour"
        case .grayscale: "Greyscale"
        case .blackAndWhite: "Black and white"
        }
    }
    static let cleanUp = "Clean up scans (straighten, crop and whiten)"

    // MARK: Privacy (features §3.5, exhaustively)

    static let privacyIntro = "Super PDF works on this Mac. Your files never leave it. These are the only times it uses the internet:"
    static let networkUses = [
        "Checking GitHub for a new version of Super PDF, and downloading it (automatic checks can be turned off below).",
        "Getting a trusted timestamp for a certificate signature, only if you turned that on in Signatures and named a server.",
        "“Get LibreOffice” and “Get Pages” open their download pages in your browser or the App Store; Super PDF itself downloads nothing.",
    ]
    static let privacyOutro = "Nothing else: no accounts, no analytics, no remote settings. Everything else works with Wi-Fi off."
    static let checkAutomatically = "Check for updates automatically"
    static let checkNow = "Check Now"
    static let installNow = "Install and Relaunch"

    /// The update status under the switch.
    static func update(_ status: UpdateStatus, now: Date = Date()) -> String {
        switch status {
        case .idle: "Super PDF checks for a new version every few hours."
        case .checking: "Checking for a new version…"
        case .upToDate(let checked): "Super PDF is up to date. Last checked \(checkedTime(checked, now: now))."
        case .downloading(let version, let fraction): "Downloading version \(version)… \(Int((fraction * 100).rounded()))%"
        case .readyToInstall(let version): "Version \(version) is ready. It installs when Super PDF quits."
        case .failed(let reason): "Couldn’t check for updates. \(reason)"
        case .disabled: "Automatic checks are off. “Check Now” still looks for a new version."
        }
    }

    /// "today at 10:42", "yesterday at 09:15", or the date.
    static func checkedTime(_ date: Date, now: Date) -> String {
        let calendar = Calendar.current
        let time = date.formatted(date: .omitted, time: .shortened)
        if calendar.isDate(date, inSameDayAs: now) { return "today at \(time)" }
        if let yesterday = calendar.date(byAdding: .day, value: -1, to: now), calendar.isDate(date, inSameDayAs: yesterday) { return "yesterday at \(time)" }
        return date.formatted(date: .abbreviated, time: .shortened)
    }

    static func canInstall(_ status: UpdateStatus) -> Bool {
        if case .readyToInstall = status { return true }
        return false
    }
}

extension SettingsPane {
    /// The pane's toolbar symbol.
    var symbol: String {
        switch self {
        case .general: "gearshape"
        case .tools: "square.grid.2x2"
        case .converters: "arrow.triangle.2.circlepath"
        case .signatures: "signature"
        case .scanning: "scanner"
        case .privacy: "hand.raised"
        }
    }
}
