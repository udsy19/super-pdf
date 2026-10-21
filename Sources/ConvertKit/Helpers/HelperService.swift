import AppKit
import Combine
import SuperPDFCore

/// `Services.helpers`: the LibreOffice copy and the Office/iWork apps on this Mac (features §3.2; Settings ›
/// Converters). Detection only looks at the file system and LaunchServices; nothing is launched. Pages to get
/// LibreOffice or an iWork app open in the browser or the App Store through `open` (a fake in the self-test).
@MainActor
public final class HelperService: HelperManaging {
    public private(set) var libreOffice: HelperStatus = .notInstalled
    public private(set) var officeApps: [OfficeApp: URL] = [:]
    public var changes: AnyPublisher<Void, Never> { subject.eraseToAnyPublisher() }

    /// The installation conversions use; nil when LibreOffice isn't on this Mac.
    private(set) var installation: LibreOffice.Installation?

    private let subject = PassthroughSubject<Void, Never>()
    private let open: @MainActor (URL) -> Void
    private let findApp: @MainActor (String) -> URL?
    private let candidates: [URL]

    /// - Parameters:
    ///   - open: opens a web or App Store page (NSWorkspace in the app).
    ///   - findApp: an app's location by bundle identifier (LaunchServices in the app).
    ///   - candidates: where to look for LibreOffice after the Settings override.
    public convenience init() {
        self.init(open: { NSWorkspace.shared.open($0) },
                  findApp: { NSWorkspace.shared.urlForApplication(withBundleIdentifier: $0) },
                  candidates: LibreOffice.candidates())
    }

    init(open: @escaping @MainActor (URL) -> Void, findApp: @escaping @MainActor (String) -> URL?, candidates: [URL]) {
        self.open = open
        self.findApp = findApp
        self.candidates = candidates
        detect()
    }

    public func detect() {
        let found = LibreOffice.detect(override: Defaults[.libreOfficePath], candidates: candidates)
        let status: HelperStatus = found.map { .installed(at: $0.soffice, version: $0.version) } ?? .notInstalled
        var apps: [OfficeApp: URL] = [:]
        for app in OfficeApp.allCases where AppAutomation.supports(app) {
            if let url = findApp(app.bundleIdentifier) { apps[app] = url }
        }
        let changed = status != libreOffice || apps != officeApps
        installation = found
        libreOffice = status
        officeApps = apps
        if changed { subject.send() }
    }

    public func getLibreOffice() { open(LibreOffice.downloadPage) }

    /// "Get Pages" (ux §7.4 "iWork app missing").
    func getApp(_ app: OfficeApp) {
        if let page = AppAutomation.appStorePage(app) { open(page) }
    }
}
