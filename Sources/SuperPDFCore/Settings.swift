import Foundation

// Every user setting, one place, grouped by Settings pane (ux §6.6). Settings never leave the Mac. State private to one
// module (panel "More options" disclosure, frecency, window frames, sidebar width) is declared in that module with the
// module as prefix: `Key<Bool>("toolsKit.moreOptions.make-smaller", …)`.

/// General › Default save behaviour (ux §7.1): the first ⌘S on a file we did not create asks, unless "Always do this"
/// picked one of the others.
public enum SaveBehaviour: String, Codable, CaseIterable, Sendable {
    case ask, alwaysSaveCopy, replaceOriginal
}

/// General › Default zoom for newly opened documents.
public enum DefaultZoom: String, Codable, CaseIterable, Sendable {
    case scaleToFit, actualSize
}

/// General › Text size (ux §9): body text 13 → 15 → 17 pt, every other role scaled by the same factor.
public enum TextSize: String, Codable, CaseIterable, Sendable {
    case `default`, larger, largest

    /// The body size this setting gives; `SPFont` scales every role by `bodySize / 13`.
    public var bodySize: CGFloat {
        switch self {
        case .default: 13
        case .larger: 15
        case .largest: 17
        }
    }

    public var scale: CGFloat { bodySize / 13 }
}

/// Scanning › colour mode (features #102).
public enum ScanColorMode: String, Codable, CaseIterable, Sendable {
    case color, grayscale, blackAndWhite
}

public extension Defaults.Keys {
    // MARK: General (ux §6.6)

    /// Open documents as tabs of one window instead of separate windows.
    static let openFilesInTabs = Key<Bool>("openFilesInTabs", default: false)
    static let saveBehaviour = Key<SaveBehaviour>("saveBehaviour", default: .ask)
    /// The author written on notes and markup; empty means the Contacts "Me" card's name (features #76).
    static let authorName = Key<String>("authorName", default: "")
    static let defaultZoom = Key<DefaultZoom>("defaultZoom", default: .scaleToFit)
    static let textSize = Key<TextSize>("textSize", default: .default)

    // MARK: Tools (ux §6.6, §4)

    /// Tiles added to the toolbar with "Add to Toolbar", in order (one-click favourites).
    static let toolbarTools = Key<[ToolID]>("toolbarTools", default: [])
    /// Tiles added to the Dock menu with "Add to Dock Menu".
    static let dockMenuTools = Key<[ToolID]>("dockMenuTools", default: [])
    /// The Tools sheet's "Recently used" row.
    static let showRecentlyUsed = Key<Bool>("showRecentlyUsed", default: true)
    /// Experts: tile hints also name the Acrobat term ("Make smaller (Compress)").
    static let showJargonInHints = Key<Bool>("showJargonInHints", default: false)

    // MARK: Converters (ux §6.6, features §3.2)

    /// Where LibreOffice lives when the user pointed Settings at it; nil auto-detects.
    static let libreOfficePath = Key<URL?>("libreOfficePath", default: nil)

    // MARK: Signatures (ux §6.6, features §3.5 item 4, §3.6)

    /// "Add a trusted timestamp" to certificate signatures (RFC 3161); off by default because it needs the network.
    static let addTrustedTimestamp = Key<Bool>("addTrustedTimestamp", default: false)
    static let timestampServer = Key<URL?>("timestampServer", default: nil)
    /// The signing identity "Sign with a certificate" proposes first (its Keychain persistent reference, hex).
    static let defaultCertificateID = Key<String?>("defaultCertificateID", default: nil)

    // MARK: Scanning (ux §6.6, features #102)

    static let scanResolution = Key<Int>("scanResolution", default: 300)
    static let scanColorMode = Key<ScanColorMode>("scanColorMode", default: .color)
    /// "Clean up" after scanning (deskew, crop, whiten), on by default (ux §5.3 Scan step 3).
    static let cleanUpScans = Key<Bool>("cleanUpScans", default: true)

    // MARK: Privacy (ux §6.6, features §3.5 item 2)

    static let checkForUpdates = Key<Bool>("checkForUpdates", default: true)

    // MARK: Internal: one-time offers

    /// The PDF Services item ("Save to Super PDF") was offered once (ARCHITECTURE "Launch sequence" step 3).
    /// "Make Super PDF your PDF app" was offered once on the welcome window (answered or "Not now").
    static let defaultPDFAppOffered = Key<Bool>("defaultPDFAppOffered", default: false)
    static let pdfServicesOffered = Key<Bool>("pdfServicesOffered", default: false)
}
