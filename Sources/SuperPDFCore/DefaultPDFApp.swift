import AppKit
import UniformTypeIdentifiers

/// The two workspace calls behind "Open PDFs with Super PDF", so the self-test can use a fake and never change the real
/// default app.
@MainActor
public protocol DefaultAppControlling: AnyObject {
    /// The app that opens `type` now (what Finder's Open and Quick Look's "Open with …" use).
    func defaultApplication(toOpen type: UTType) -> URL?
    /// Makes `app` the default for `type`. macOS asks the person to confirm; throws when they decline or it fails.
    func setDefaultApplication(at app: URL, toOpen type: UTType) async throws
}

@MainActor
final class SystemDefaultApps: DefaultAppControlling {
    func defaultApplication(toOpen type: UTType) -> URL? { NSWorkspace.shared.urlForApplication(toOpen: type) }
    func setDefaultApplication(at app: URL, toOpen type: UTType) async throws {
        try await NSWorkspace.shared.setDefaultApplication(at: app, toOpen: type)
    }
}

/// Whether this app is the Mac's PDF app, and the one-time offer and Settings button that make it so (the app's
/// Info.plist ranks it "Default" for PDFs, which lets this choice stick; "Owner" is for types the app defines itself).
@MainActor
public final class DefaultPDFApp {
    public enum State: Equatable, Sendable {
        case thisApp
        case other(name: String)
        case unknown
    }

    public enum Outcome: Equatable, Sendable {
        case changed
        /// The person said no in macOS's prompt (or macOS kept the other app).
        case declined
        case failed(String)
    }

    public static let shared = DefaultPDFApp()

    private let workspace: DefaultAppControlling
    private let appURL: URL
    private let bundleIdentifier: String?

    public init(workspace: DefaultAppControlling? = nil, appURL: URL = Bundle.main.bundleURL, bundleIdentifier: String? = Bundle.main.bundleIdentifier) {
        self.workspace = workspace ?? SystemDefaultApps()
        self.appURL = appURL
        self.bundleIdentifier = bundleIdentifier
    }

    /// Only a real app bundle can be made the default (not `swift run`'s bare executable).
    public var canChange: Bool { appURL.pathExtension == "app" }

    public var state: State {
        guard let handler = workspace.defaultApplication(toOpen: .pdf) else { return .unknown }
        let sameApp = handler.standardizedFileURL == appURL.standardizedFileURL
            || (bundleIdentifier != nil && Bundle(url: handler)?.bundleIdentifier == bundleIdentifier)
        return sameApp ? .thisApp : .other(name: handler.deletingPathExtension().lastPathComponent)
    }

    /// Asks macOS to make this app the PDF app. The person confirms in the system's own prompt; declining comes back as
    /// `.declined`, and `state` says what is true afterwards either way.
    @discardableResult
    public func makeDefault() async -> Outcome {
        guard canChange else { return .failed("Super PDF has to be installed as an app first.") }
        do {
            try await workspace.setDefaultApplication(at: appURL, toOpen: .pdf)
            return state == .thisApp ? .changed : .declined
        } catch let error as NSError where error.domain == NSCocoaErrorDomain && error.code == NSUserCancelledError {
            return .declined
        } catch {
            return .failed(error.localizedDescription)
        }
    }

    /// Whether the welcome window should offer now: once ever, never when it already is the PDF app or can't be.
    public func shouldOffer() -> Bool {
        guard canChange, !Defaults[.defaultPDFAppOffered] else { return false }
        if state == .thisApp { Defaults[.defaultPDFAppOffered] = true; return false }
        return true
    }

    /// "Not now", or an answer: the offer is never made again (Settings › General keeps the button).
    public func rememberOffered() { Defaults[.defaultPDFAppOffered] = true }
}
