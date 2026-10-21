import AppKit
import SuperPDFCore

/// The main menu built from `MenuTree.main` (ux §8). Commands with a standard AppKit action use it; every other item
/// sends `performMenuCommand(_:)` up the responder chain with its command as the item's identifier.
@MainActor
enum MainMenu {
    static func make() -> NSMenu {
        let menu = NSMenu()
        for spec in MenuTree.main {
            let submenu = build(spec.title, spec.entries)
            let item = NSMenuItem(title: spec.title, action: nil, keyEquivalent: "")
            item.submenu = submenu
            menu.addItem(item)
            switch spec.title {
            case "Window": NSApp.windowsMenu = submenu
            case "Help": NSApp.helpMenu = submenu
            default: break
            }
        }
        return menu
    }

    private static func build(_ title: String, _ entries: [MenuEntry]) -> NSMenu {
        let menu = NSMenu(title: title)
        for entry in entries {
            switch entry {
            case .separator:
                menu.addItem(.separator())
            case .submenu(let title, let children):
                let item = NSMenuItem(title: title, action: nil, keyEquivalent: "")
                let submenu = build(title, children)
                item.submenu = submenu
                if title == "Services" { NSApp.servicesMenu = submenu }
                menu.addItem(item)
            case .item(let title, let command, let shortcut):
                let item = NSMenuItem(title: title, action: standardActions[command] ?? #selector(MenuCommandResponding.performMenuCommand(_:)),
                                      keyEquivalent: shortcut?.key ?? "")
                item.keyEquivalentModifierMask = shortcut?.modifiers.flags ?? []
                item.identifier = NSUserInterfaceItemIdentifier(command.rawValue)
                menu.addItem(item)
            }
        }
        return menu
    }

    /// Commands AppKit already implements, by their standard action.
    private static let standardActions: [MenuCommand: Selector] = [
        .about: #selector(NSApplication.orderFrontStandardAboutPanel(_:)),
        .hide: #selector(NSApplication.hide(_:)),
        .hideOthers: #selector(NSApplication.hideOtherApplications(_:)),
        .showAll: #selector(NSApplication.unhideAllApplications(_:)),
        .quit: #selector(NSApplication.terminate(_:)),
        .open: #selector(NSDocumentController.openDocument(_:)),
        .clearRecents: #selector(NSDocumentController.clearRecentDocuments(_:)),
        .close: #selector(NSWindow.performClose(_:)),
        .save: #selector(NSDocument.save(_:)),
        .duplicate: #selector(NSDocument.duplicate(_:)),
        .rename: #selector(NSDocument.rename(_:)),
        .moveTo: #selector(NSDocument.move(_:)),
        .revertToSaved: #selector(NSDocument.revertToSaved(_:)),
        .browseVersions: #selector(NSDocument.browseVersions(_:)),
        .print: #selector(NSDocument.printDocument(_:)),
        .undo: Selector(("undo:")),
        .redo: Selector(("redo:")),
        .cut: #selector(NSText.cut(_:)),
        .copy: #selector(NSText.copy(_:)),
        .paste: #selector(NSText.paste(_:)),
        .delete: #selector(NSText.delete(_:)),
        .selectAll: #selector(NSText.selectAll(_:)),
        .showSpelling: #selector(NSText.showGuessPanel(_:)),
        .checkSpelling: #selector(NSText.checkSpelling(_:)),
        .startSpeaking: #selector(NSTextView.startSpeaking(_:)),
        .stopSpeaking: #selector(NSTextView.stopSpeaking(_:)),
        .customizeToolbar: #selector(NSWindow.runToolbarCustomizationPalette(_:)),
        .enterFullScreen: #selector(NSWindow.toggleFullScreen(_:)),
        .minimize: #selector(NSWindow.performMiniaturize(_:)),
        .zoomWindow: #selector(NSWindow.performZoom(_:)),
        .bringAllToFront: #selector(NSApplication.arrangeInFront(_:)),
    ]
}
