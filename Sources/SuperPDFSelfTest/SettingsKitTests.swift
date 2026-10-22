import AppKit
import SuperPDFCore
@testable import SettingsKit

// SettingsKit's checks (WP16): the window and its six panes in ux §6.6's order, opening at the pane asked for or the last
// one, the sentences the panes build from live state (update status, LibreOffice, the network list) and the panes'
// views laid out offscreen. The window is made but never shown; nothing is opened.

func registerSettingsKitTests() {
    SelfTest.cases.append(("SettingsKit.window", { settingsWindow() }))
    SelfTest.cases.append(("SettingsKit.text", { settingsText() }))
}

@MainActor
private func settingsWindow() {
    installFakes()
    SettingsKitModule.install(showsWindow: false)
    guard let settings = Services.settings as? SettingsWindowController else { check(false, "Services.settings is SettingsKit's"); return }
    check(settings.paneTitles == ["General", "Tools", "Converters", "Signatures", "Scanning", "Privacy"], "ux §6.6's panes: \(settings.paneTitles)")
    settings.show(.privacy)
    check(settings.selectedPane == .privacy && settings.window?.title == "Privacy" && settings.window?.isVisible == false,
          "opens at the pane asked for (not shown here)")
    settings.show(nil)
    check(settings.selectedPane == .privacy, "and where it was last")
    settings.show(.converters)
    let again = SettingsWindowController(showsWindow: false)
    again.show(nil)
    check(again.selectedPane == .converters, "the last pane is remembered")
    // Every pane lays out at the window's width.
    for pane in SettingsPane.allCases {
        settings.show(pane)
        settings.window?.contentView?.layoutSubtreeIfNeeded()
        let size = settings.window?.contentViewController?.view.fittingSize ?? .zero
        check(size.height > 60 && size.height < 900, "\(pane.title) lays out: \(size)")
    }
    Defaults.reset(SettingsWindowController.lastPane)
    installFakes()
}

@MainActor
private func settingsText() {
    let now = Date(timeIntervalSince1970: 1_800_000_000)
    check(SettingsText.update(.upToDate(checkedAt: now), now: now).hasPrefix("Super PDF is up to date. Last checked today at"), "up to date today")
    check(SettingsText.update(.upToDate(checkedAt: now.addingTimeInterval(-86_400)), now: now).contains("yesterday at"), "checked yesterday")
    check(SettingsText.update(.downloading(version: "1.2", fraction: 0.456)) == "Downloading version 1.2… 46%", "download progress")
    check(SettingsText.update(.readyToInstall(version: "1.2")) == "Version 1.2 is ready. It installs when Super PDF quits." &&
          SettingsText.canInstall(.readyToInstall(version: "1.2")) && !SettingsText.canInstall(.idle), "ready, with Install and Relaunch")
    check(SettingsText.update(.disabled).contains("“Check Now” still looks"), "off, but the manual check still works")
    check(SettingsText.update(.failed("No connection.")) == "Couldn’t check for updates. No connection.", "a failed check says why")

    check(SettingsText.pdfApp(.other(name: "Adobe Acrobat")) == "Currently: Adobe Acrobat" && SettingsText.pdfApp(.thisApp) == "Currently: Super PDF"
          && SettingsText.pdfApp(.unknown) == "Currently: no app chosen", "the PDF app line names the current app")

    let soffice = URL(fileURLWithPath: "/Applications/LibreOffice.app/Contents/MacOS/soffice")
    check(SettingsText.libreOffice(.installed(at: soffice, version: "26.2")) == "Installed (version 26.2) at /Applications/LibreOffice.app.", "installed copy")
    check(SettingsText.libreOffice(.installed(at: URL(fileURLWithPath: "/opt/homebrew/bin/soffice"), version: nil)) == "Installed at /opt/homebrew/bin/soffice.",
          "a Homebrew wrapper")
    check(SettingsText.libreOffice(.notInstalled).hasPrefix("Not installed."), "not installed")
    check(SettingsText.getLibreOffice == "Get LibreOffice", "Get LibreOffice, never Install")

    // Privacy lists every use of the network the app makes (features §3.5): updates, timestamps, and the pages that open
    // in the browser; nothing else.
    check(SettingsText.networkUses.count == 3 && SettingsText.networkUses[0].contains("GitHub") && SettingsText.networkUses[1].contains("timestamp")
          && SettingsText.networkUses[2].contains("downloads nothing"), "the network list")
    check(SettingsText.officeApps([.word, .pages]) == "Microsoft Word, Pages", "apps found")
    check(SettingsPane.allCases.allSatisfy { NSImage(systemSymbolName: $0.symbol, accessibilityDescription: nil) != nil }, "every pane's symbol exists")
}
