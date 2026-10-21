import SuperPDFCore

/// SettingsKit: the settings window and its panes (ux §6.6; docs/ARCHITECTURE.md, WP16). It registers
/// `Services.settings` (`SettingsPresenting`).
@MainActor
public enum SettingsKitModule {
    /// `showsWindow: false` makes the window without ever showing it (the self-test).
    public static func install(showsWindow: Bool = true) {
        Services.settings = SettingsWindowController(showsWindow: showsWindow)
    }
}
