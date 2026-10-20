import AppKit

// The keyboard and menu contract (ux §8, §6.4, §1.2): Preview's menu tree and shortcuts where they overlap, plus Tools.
// Data, so the app's main menu, the Tools menu, tooltips and the self-test read the same table. The app target builds
// NSMenus from `MenuTree.main`; commands without a standard AppKit action go up the responder chain as
// `performMenuCommand(_:)` with the item's `identifier` set to the command (an unhandled command disables its item).
// AppKit adds the window-tab items (Show Tab Bar, Merge All Windows…) to the Window menu itself.

/// Modifier keys of a chord.
public struct KeyModifiers: OptionSet, Codable, Hashable, Sendable {
    public let rawValue: Int
    public init(rawValue: Int) { self.rawValue = rawValue }

    public static let control = KeyModifiers(rawValue: 1 << 0)
    public static let option = KeyModifiers(rawValue: 1 << 1)
    public static let shift = KeyModifiers(rawValue: 1 << 2)
    public static let command = KeyModifiers(rawValue: 1 << 3)

    /// "⌃⌥⇧⌘" in the macOS display order.
    public var symbols: String {
        (contains(.control) ? "⌃" : "") + (contains(.option) ? "⌥" : "") + (contains(.shift) ? "⇧" : "") + (contains(.command) ? "⌘" : "")
    }

    /// The menu item modifier mask.
    public var flags: NSEvent.ModifierFlags {
        var flags: NSEvent.ModifierFlags = []
        if contains(.control) { flags.insert(.control) }
        if contains(.option) { flags.insert(.option) }
        if contains(.shift) { flags.insert(.shift) }
        if contains(.command) { flags.insert(.command) }
        return flags
    }
}

/// One chord as a menu key equivalent: the character AppKit matches (letters lower-case) plus modifiers.
public struct KeyCombo: Codable, Hashable, Sendable, CustomStringConvertible {
    public var key: String
    public var modifiers: KeyModifiers

    public init(_ key: String, _ modifiers: KeyModifiers = .command) { self.key = key; self.modifiers = modifiers }

    public static let deleteKey = "\u{8}"
    public static let returnKey = "\r"
    public static let escapeKey = "\u{1b}"
    public static let upArrow = String(Character(UnicodeScalar(NSUpArrowFunctionKey)!))
    public static let downArrow = String(Character(UnicodeScalar(NSDownArrowFunctionKey)!))
    public static let leftArrow = String(Character(UnicodeScalar(NSLeftArrowFunctionKey)!))
    public static let rightArrow = String(Character(UnicodeScalar(NSRightArrowFunctionKey)!))

    /// "⌥⌘A", "⌘⌫", "⌥↑".
    public var description: String {
        let name: String = switch key {
        case Self.deleteKey: "⌫"
        case Self.returnKey: "↩"
        case Self.escapeKey: "Esc"
        case Self.upArrow: "↑"
        case Self.downArrow: "↓"
        case Self.leftArrow: "←"
        case Self.rightArrow: "→"
        case "-": "−"
        default: key.uppercased()
        }
        return modifiers.symbols + name
    }
}

/// What a menu item does: a stable identifier ("file.open", "tool.make-smaller").
public struct MenuCommand: RawRepresentable, Hashable, Sendable, ExpressibleByStringLiteral {
    public let rawValue: String
    public init(rawValue: String) { self.rawValue = rawValue }
    public init(stringLiteral value: String) { rawValue = value }

    /// Opens a tile's panel (the Tools menu's section submenus).
    public static func tool(_ id: ToolID) -> MenuCommand { MenuCommand(rawValue: "tool." + id.rawValue) }

    /// The tile a `tool(_:)` command opens.
    public var tool: ToolID? { rawValue.hasPrefix("tool.") ? ToolID(rawValue: String(rawValue.dropFirst(5))) : nil }

    // App
    public static let about: MenuCommand = "app.about"
    public static let settings: MenuCommand = "app.settings"
    public static let checkForUpdates: MenuCommand = "app.checkForUpdates"
    public static let hide: MenuCommand = "app.hide"
    public static let hideOthers: MenuCommand = "app.hideOthers"
    public static let showAll: MenuCommand = "app.showAll"
    public static let quit: MenuCommand = "app.quit"
    // File
    public static let newFromClipboard: MenuCommand = "file.newFromClipboard"
    public static let open: MenuCommand = "file.open"
    public static let clearRecents: MenuCommand = "file.clearRecents"
    public static let close: MenuCommand = "file.close"
    public static let save: MenuCommand = "file.save"
    public static let saveACopy: MenuCommand = "file.saveACopy"
    public static let duplicate: MenuCommand = "file.duplicate"
    public static let rename: MenuCommand = "file.rename"
    public static let moveTo: MenuCommand = "file.moveTo"
    public static let revertToSaved: MenuCommand = "file.revertToSaved"
    public static let browseVersions: MenuCommand = "file.browseVersions"
    public static let enterPassword: MenuCommand = "file.enterPassword"
    public static let editPermissions: MenuCommand = "file.editPermissions"
    public static let importFromIPhone: MenuCommand = "file.importFromIPhone"
    public static let importFromCamera: MenuCommand = "file.importFromCamera"
    public static let importFromScanner: MenuCommand = "file.importFromScanner"
    public static let exportAs: MenuCommand = "file.exportAs"
    public static let exportAsPDF: MenuCommand = "file.exportAsPDF"
    public static let print: MenuCommand = "file.print"
    // Edit
    public static let undo: MenuCommand = "edit.undo"
    public static let redo: MenuCommand = "edit.redo"
    public static let cut: MenuCommand = "edit.cut"
    public static let copy: MenuCommand = "edit.copy"
    public static let paste: MenuCommand = "edit.paste"
    public static let delete: MenuCommand = "edit.delete"
    public static let selectAll: MenuCommand = "edit.selectAll"
    public static let insertPageFromScanner: MenuCommand = "edit.insertPageFromScanner"
    public static let insertPageFromFile: MenuCommand = "edit.insertPageFromFile"
    public static let insertBlankPage: MenuCommand = "edit.insertBlankPage"
    public static let find: MenuCommand = "edit.find"
    public static let findNext: MenuCommand = "edit.findNext"
    public static let findPrevious: MenuCommand = "edit.findPrevious"
    public static let useSelectionForFind: MenuCommand = "edit.useSelectionForFind"
    public static let showSpelling: MenuCommand = "edit.showSpelling"
    public static let checkSpelling: MenuCommand = "edit.checkSpelling"
    public static let startSpeaking: MenuCommand = "edit.startSpeaking"
    public static let stopSpeaking: MenuCommand = "edit.stopSpeaking"
    // View
    public static let hideSidebar: MenuCommand = "view.hideSidebar"
    public static let thumbnails: MenuCommand = "view.thumbnails"
    public static let tableOfContents: MenuCommand = "view.tableOfContents"
    public static let highlightsAndNotes: MenuCommand = "view.highlightsAndNotes"
    public static let bookmarks: MenuCommand = "view.bookmarks"
    public static let attachments: MenuCommand = "view.attachments"
    public static let pageOrganiser: MenuCommand = "view.pageOrganiser"
    public static let contactSheet: MenuCommand = "view.contactSheet"
    public static let continuousScroll: MenuCommand = "view.continuousScroll"
    public static let singlePage: MenuCommand = "view.singlePage"
    public static let twoPages: MenuCommand = "view.twoPages"
    public static let darkAppearanceForPDF: MenuCommand = "view.darkAppearanceForPDF"
    public static let actualSize: MenuCommand = "view.actualSize"
    public static let zoomToFit: MenuCommand = "view.zoomToFit"
    public static let zoomIn: MenuCommand = "view.zoomIn"
    public static let zoomOut: MenuCommand = "view.zoomOut"
    public static let showMarkupToolbar: MenuCommand = "view.showMarkupToolbar"
    public static let customizeToolbar: MenuCommand = "view.customizeToolbar"
    public static let slideshow: MenuCommand = "view.slideshow"
    public static let enterFullScreen: MenuCommand = "view.enterFullScreen"
    // Go
    public static let up: MenuCommand = "go.up"
    public static let down: MenuCommand = "go.down"
    public static let previousItem: MenuCommand = "go.previousItem"
    public static let nextItem: MenuCommand = "go.nextItem"
    public static let goToPage: MenuCommand = "go.goToPage"
    public static let back: MenuCommand = "go.back"
    public static let forward: MenuCommand = "go.forward"
    // Tools
    public static let allTools: MenuCommand = "tools.allTools"
    public static let showInspector: MenuCommand = "tools.showInspector"
    public static let showMagnifier: MenuCommand = "tools.showMagnifier"
    public static let highlightText: MenuCommand = "tools.annotate.highlight"
    public static let underlineText: MenuCommand = "tools.annotate.underline"
    public static let strikeThroughText: MenuCommand = "tools.annotate.strikeThrough"
    public static let rectangle: MenuCommand = "tools.annotate.rectangle"
    public static let oval: MenuCommand = "tools.annotate.oval"
    public static let line: MenuCommand = "tools.annotate.line"
    public static let arrow: MenuCommand = "tools.annotate.arrow"
    public static let text: MenuCommand = "tools.annotate.text"
    public static let note: MenuCommand = "tools.annotate.note"
    public static let loupe: MenuCommand = "tools.annotate.loupe"
    public static let addBookmark: MenuCommand = "tools.addBookmark"
    public static let rotateLeft: MenuCommand = "tools.rotateLeft"
    public static let rotateRight: MenuCommand = "tools.rotateRight"
    public static let cropPage: MenuCommand = "tools.crop"
    // Window
    public static let minimize: MenuCommand = "window.minimize"
    public static let zoomWindow: MenuCommand = "window.zoom"
    public static let welcome: MenuCommand = "window.welcome"
    public static let signatureRequests: MenuCommand = "window.signatureRequests"
    public static let bringAllToFront: MenuCommand = "window.bringAllToFront"
    // Help
    public static let help: MenuCommand = "help.help"
}

/// One entry of a menu.
public indirect enum MenuEntry: Hashable, Sendable {
    case item(String, MenuCommand, KeyCombo? = nil)
    case submenu(String, [MenuEntry])
    case separator

    /// Every item under this entry, depth first.
    public var items: [(title: String, command: MenuCommand, shortcut: KeyCombo?)] {
        switch self {
        case .item(let title, let command, let shortcut): [(title, command, shortcut)]
        case .submenu(_, let entries): entries.flatMap(\.items)
        case .separator: []
        }
    }
}

/// A top-level menu.
public struct MenuSpec: Hashable, Sendable {
    public var title: String
    public var entries: [MenuEntry]

    public init(_ title: String, _ entries: [MenuEntry]) { self.title = title; self.entries = entries }
}

public enum MenuTree {
    private static let cmd: KeyModifiers = .command
    private static let shiftCmd: KeyModifiers = [.shift, .command]
    private static let optCmd: KeyModifiers = [.option, .command]
    private static let ctrlCmd: KeyModifiers = [.control, .command]

    /// The main menu, left to right (ux §8).
    public static let main: [MenuSpec] = [
        MenuSpec(Strings.appName, [
            .item("About Super PDF", .about),
            .separator,
            .item("Settings…", .settings, KeyCombo(",")),
            .item("Check for Updates…", .checkForUpdates),
            .separator,
            .submenu("Services", []),
            .separator,
            .item("Hide Super PDF", .hide, KeyCombo("h")),
            .item("Hide Others", .hideOthers, KeyCombo("h", optCmd)),
            .item("Show All", .showAll),
            .separator,
            .item("Quit Super PDF", .quit, KeyCombo("q")),
        ]),
        MenuSpec("File", [
            .item("New from Clipboard", .newFromClipboard, KeyCombo("n")),
            .item("Open…", .open, KeyCombo("o")),
            .submenu("Open Recent", [.item("Clear Menu", .clearRecents)]),
            .separator,
            .item("Close", .close, KeyCombo("w")),
            .item("Save", .save, KeyCombo("s")),
            .item("Save a Copy…", .saveACopy, KeyCombo("s", shiftCmd)),
            .item("Duplicate", .duplicate),
            .item("Rename…", .rename),
            .item("Move To…", .moveTo),
            .submenu("Revert To", [.item("Last Saved", .revertToSaved), .item("Browse All Versions…", .browseVersions)]),
            .separator,
            .item("Enter Password…", .enterPassword),
            .item("Edit Permissions…", .editPermissions),
            .separator,
            .item("Import from iPhone…", .importFromIPhone),
            .item("Import from Camera…", .importFromCamera),
            .item("Import from Scanner…", .importFromScanner),
            .separator,
            .item("Export As…", .exportAs),
            .item("Export as PDF…", .exportAsPDF),
            .separator,
            .item("Print…", .print, KeyCombo("p")),
        ]),
        MenuSpec("Edit", [
            .item("Undo", .undo, KeyCombo("z")),
            .item("Redo", .redo, KeyCombo("z", shiftCmd)),
            .separator,
            .item("Cut", .cut, KeyCombo("x")),
            .item("Copy", .copy, KeyCombo("c")),
            .item("Paste", .paste, KeyCombo("v")),
            .item("Delete", .delete),
            .item("Select All", .selectAll, KeyCombo("a")),
            .separator,
            .submenu("Insert", [
                .item("Page from Scanner…", .insertPageFromScanner),
                .item("Page from File…", .insertPageFromFile),
                .item("Blank Page", .insertBlankPage),
            ]),
            .separator,
            .submenu("Find", [
                .item("Find…", .find, KeyCombo("f")),
                .item("Find Next", .findNext, KeyCombo("g")),
                .item("Find Previous", .findPrevious, KeyCombo("g", shiftCmd)),
                .item("Use Selection for Find", .useSelectionForFind, KeyCombo("e")),
            ]),
            .submenu("Spelling and Grammar", [
                .item("Show Spelling and Grammar", .showSpelling, KeyCombo(":")),
                .item("Check Document Now", .checkSpelling, KeyCombo(";")),
            ]),
            .submenu("Speech", [.item("Start Speaking", .startSpeaking), .item("Stop Speaking", .stopSpeaking)]),
        ]),
        MenuSpec("View", [
            .item("Hide Sidebar", .hideSidebar, KeyCombo("1", optCmd)),
            .item("Thumbnails", .thumbnails, KeyCombo("2", optCmd)),
            .item("Table of Contents", .tableOfContents, KeyCombo("3", optCmd)),
            .item("Highlights and Notes", .highlightsAndNotes, KeyCombo("4", optCmd)),
            .item("Bookmarks", .bookmarks, KeyCombo("5", optCmd)),
            .item("Attachments", .attachments),
            .item("Page Organiser", .pageOrganiser, KeyCombo("6", optCmd)),
            .item("Contact Sheet", .contactSheet, KeyCombo("7", optCmd)),
            .separator,
            .item("Continuous Scroll", .continuousScroll, KeyCombo("1")),
            .item("Single Page", .singlePage, KeyCombo("2")),
            .item("Two Pages", .twoPages, KeyCombo("3")),
            .separator,
            .item("Use Dark Appearance for PDF", .darkAppearanceForPDF),
            .separator,
            .item("Actual Size", .actualSize, KeyCombo("0")),
            .item("Zoom to Fit", .zoomToFit, KeyCombo("9")),
            .item("Zoom In", .zoomIn, KeyCombo("+")),
            .item("Zoom Out", .zoomOut, KeyCombo("-")),
            .separator,
            .item("Show Markup Toolbar", .showMarkupToolbar, KeyCombo("a", shiftCmd)),
            .item("Customize Toolbar…", .customizeToolbar),
            .separator,
            .item("Slideshow", .slideshow, KeyCombo("f", shiftCmd)),
            .item("Enter Full Screen", .enterFullScreen, KeyCombo("f", ctrlCmd)),
        ]),
        MenuSpec("Go", [
            .item("Up", .up),
            .item("Down", .down),
            .item("Previous Item", .previousItem, KeyCombo(KeyCombo.upArrow, .option)),
            .item("Next Item", .nextItem, KeyCombo(KeyCombo.downArrow, .option)),
            .item("Go to Page…", .goToPage, KeyCombo("g", optCmd)),
            .separator,
            .item("Back", .back, KeyCombo("[")),
            .item("Forward", .forward, KeyCombo("]")),
        ]),
        MenuSpec("Tools", [
            .item(Strings.ToolsSheet.allTools, .allTools, KeyCombo("t")),
            .item("Show Inspector", .showInspector, KeyCombo("i")),
            .item("Show Magnifier", .showMagnifier, KeyCombo("`", [])),
            .submenu("Annotate", [
                .item("Highlight Text", .highlightText, KeyCombo("h", ctrlCmd)),
                .item("Underline Text", .underlineText, KeyCombo("u", ctrlCmd)),
                .item("Strike Through Text", .strikeThroughText, KeyCombo("s", ctrlCmd)),
                .item("Rectangle", .rectangle, KeyCombo("r", ctrlCmd)),
                .item("Oval", .oval, KeyCombo("o", ctrlCmd)),
                .item("Line", .line, KeyCombo("i", ctrlCmd)),
                .item("Arrow", .arrow, KeyCombo("a", ctrlCmd)),
                .item("Text", .text, KeyCombo("t", ctrlCmd)),
                .item("Note", .note, KeyCombo("n", ctrlCmd)),
                .item("Loupe", .loupe, KeyCombo("l", ctrlCmd)),
            ]),
            .item("Add Bookmark", .addBookmark, KeyCombo("d")),
            .separator,
            .item("Rotate Left", .rotateLeft, KeyCombo("l")),
            .item("Rotate Right", .rotateRight, KeyCombo("r")),
            .item("Crop", .cropPage, KeyCombo("k")),
            .separator,
        ] + toolSections),
        MenuSpec("Window", [
            .item("Minimize", .minimize, KeyCombo("m")),
            .item("Zoom", .zoomWindow),
            .separator,
            .item("Welcome", .welcome),
            .item("Signature Requests", .signatureRequests),
            .separator,
            .item("Bring All to Front", .bringAllToFront),
        ]),
        MenuSpec("Help", [
            .item("Super PDF Help", .help, KeyCombo("?")),
        ]),
    ]

    /// Tools › one submenu per section with every tile (ux §4, §8).
    public static let toolSections: [MenuEntry] = ToolSection.allCases.map { section in
        .submenu(Strings.menuTitle(section.title), ToolCatalog.tiles(in: section).map { tile in
            .item(tile.menuTitle, .tool(tile.id))
        })
    }

    /// Every menu item with a shortcut, for tooltips and the self-test.
    public static var shortcuts: [(title: String, command: MenuCommand, shortcut: KeyCombo)] {
        main.flatMap(\.entries).flatMap(\.items).compactMap { item in item.shortcut.map { (item.title, item.command, $0) } }
    }
}

/// Where a non-menu shortcut works.
public enum ShortcutContext: String, Codable, CaseIterable, Sendable {
    case toolsSheet, thumbnails, organiser, toolPanel
}

/// Keys that act inside one surface instead of through a menu (ux §1.2, §4, §5.1, §6.2, §6.3).
public struct ContextShortcut: Hashable, Sendable {
    public var context: ShortcutContext
    public var title: String
    public var combo: KeyCombo

    public init(_ context: ShortcutContext, _ title: String, _ combo: KeyCombo) { self.context = context; self.title = title; self.combo = combo }

    public static let all: [ContextShortcut] = ToolSection.allCases.enumerated().map { index, section in
        ContextShortcut(.toolsSheet, section.title, KeyCombo("\(index + 1)"))
    } + [
        ContextShortcut(.toolsSheet, "Open", KeyCombo(KeyCombo.returnKey, [])),
        ContextShortcut(.toolsSheet, "Close", KeyCombo(KeyCombo.escapeKey, [])),
        ContextShortcut(.thumbnails, "Delete Page", KeyCombo(KeyCombo.deleteKey, [])),
        ContextShortcut(.organiser, "Delete", KeyCombo(KeyCombo.deleteKey, [])),
        ContextShortcut(.organiser, "Done", KeyCombo(KeyCombo.escapeKey, [])),
        ContextShortcut(.toolPanel, "Close", KeyCombo(KeyCombo.escapeKey, [])),
    ]
}

/// Responders that handle menu commands without a standard AppKit action (ViewerKit's window, ToolsKit's panels, the
/// app delegate). Menu items carry their command as `identifier`.
@MainActor @objc public protocol MenuCommandResponding {
    func performMenuCommand(_ sender: NSMenuItem)
}

public extension NSMenuItem {
    /// The command a menu built from `MenuTree` carries.
    var menuCommand: MenuCommand? { identifier.map { MenuCommand(rawValue: $0.rawValue) } }
}
