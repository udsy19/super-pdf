import AppKit
import Combine
import SwiftUI
import SuperPDFCore

/// `Services.settings` (ux §6.6): the settings window, one toolbar tab per pane (General, Tools, Converters,
/// Signatures, Scanning, Privacy), opening where it was last unless a pane is asked for.
@MainActor
public final class SettingsWindowController: NSWindowController, SettingsPresenting, NSWindowDelegate {
    private let tabs = NSTabViewController()
    /// The self-test makes the window without showing it.
    private let showsWindow: Bool

    static let lastPane = Defaults.Key<SettingsPane>("settingsKit.pane", default: .general)
    static let width: CGFloat = 560

    public init(showsWindow: Bool = true) {
        self.showsWindow = showsWindow
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: Self.width, height: 420),
                              styleMask: [.titled, .closable, .miniaturizable], backing: .buffered, defer: true)
        window.isReleasedWhenClosed = false
        super.init(window: window)
        window.delegate = self
        tabs.tabStyle = .toolbar
        for pane in SettingsPane.allCases {
            let host = NSHostingController(rootView: SettingsPaneView(pane: pane))
            host.sizingOptions = [.preferredContentSize]
            let item = NSTabViewItem(viewController: host)
            item.label = pane.title
            item.image = NSImage(systemSymbolName: pane.symbol, accessibilityDescription: pane.title)
            item.identifier = pane.rawValue
            tabs.addTabViewItem(item)
        }
        window.contentViewController = tabs
        window.toolbarStyle = .preference
    }

    @available(*, unavailable) required init?(coder: NSCoder) { fatalError() }

    public func show(_ pane: SettingsPane?) {
        let pane = pane ?? Defaults[Self.lastPane]
        select(pane)
        guard showsWindow, let window else { return }
        if !window.isVisible { window.center() }
        window.makeKeyAndOrderFront(nil)
        NSApp.activate()
    }

    /// The pane in front.
    var selectedPane: SettingsPane? {
        tabs.tabViewItems[safe: tabs.selectedTabViewItemIndex].flatMap { ($0.identifier as? String).flatMap(SettingsPane.init(rawValue:)) }
    }

    /// The toolbar's pane titles, in order.
    var paneTitles: [String] { tabs.tabViewItems.map(\.label) }

    private func select(_ pane: SettingsPane) {
        guard let index = tabs.tabViewItems.firstIndex(where: { $0.identifier as? String == pane.rawValue }) else { return }
        tabs.selectedTabViewItemIndex = index
        window?.title = pane.title
        Defaults[Self.lastPane] = pane
    }

    public func windowDidUpdate(_ notification: Notification) {
        // The toolbar switches tabs itself; remember where the person went.
        if let pane = selectedPane, pane != Defaults[Self.lastPane] { Defaults[Self.lastPane] = pane }
    }
}

private extension Array {
    subscript(safe index: Int) -> Element? { indices.contains(index) ? self[index] : nil }
}

/// The live state the panes show and change: the update status, LibreOffice and the Office apps, certificates.
@MainActor
final class SettingsState: ObservableObject {
    @Published var update: UpdateStatus = Services.updates?.status ?? .idle
    @Published var libreOffice: HelperStatus = Services.helpers?.libreOffice ?? .notInstalled
    @Published var officeApps: [OfficeApp] = []
    @Published var identities: [SigningIdentity] = []
    @Published var trusted: [TrustedCertificate] = []
    private var cancellables: Set<AnyCancellable> = []

    init() {
        reload()
        Services.updates?.statusChanges.receive(on: DispatchQueue.main).sink { [weak self] status in
            MainActor.assumeIsolated { self?.update = status }
        }.store(in: &cancellables)
        Services.helpers?.changes.receive(on: DispatchQueue.main).sink { [weak self] _ in
            MainActor.assumeIsolated { self?.reload() }
        }.store(in: &cancellables)
    }

    func reload() {
        update = Services.updates?.status ?? .idle
        libreOffice = Services.helpers?.libreOffice ?? .notInstalled
        officeApps = OfficeApp.allCases.filter { Services.helpers?.officeApps[$0] != nil }
        identities = Services.sign?.identities ?? []
        trusted = Services.sign?.trustedCertificates ?? []
    }
}
