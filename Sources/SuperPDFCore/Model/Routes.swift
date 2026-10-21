import Foundation

// How files reach the app from outside a window (features #1, §2.5): `superpdf://` links, which the app opens and
// Finder's Quick Actions use to hand over their files, and the Quick Actions themselves. The app target routes them;
// the Quick Actions extension (a separate process) only builds the links, so both read them from here.

/// A `superpdf://` link.
///
///     superpdf://open?file=/Users/me/Report.pdf                      open (several files: the Combine queue)
///     superpdf://tool/make-smaller?file=/a.pdf&file=/b.pdf           a tile with these files
public enum AppRoute: Equatable, Sendable {
    /// Open files as a drop on the Dock icon does: one opens (converted first if need be), several go to Combine.
    case open([URL])
    /// A tile with these files: tools that start from files get them in their list; a document tool opens the file
    /// first (several files: "Do this to many files" with that tool as its step).
    case tool(ToolID, files: [URL])

    public init?(_ url: URL) {
        guard url.scheme?.lowercased() == SuperPDFPaths.urlScheme,
              let components = URLComponents(url: url, resolvingAgainstBaseURL: false) else { return nil }
        let files = (components.queryItems ?? []).filter { $0.name == "file" }.compactMap(\.value).filter { $0.hasPrefix("/") }
            .map { URL(fileURLWithPath: $0) }
        let path = components.path.split(separator: "/").map(String.init)
        switch components.host?.lowercased() {
        case "open":
            self = .open(files)
        case "tool":
            guard path.count == 1, let tool = ToolID(rawValue: path[0]) else { return nil }
            self = .tool(tool, files: files)
        default:
            return nil
        }
    }

    public var url: URL {
        var components = URLComponents()
        components.scheme = SuperPDFPaths.urlScheme
        let files: [URL]
        switch self {
        case .open(let urls):
            components.host = "open"
            files = urls
        case .tool(let tool, let urls):
            components.host = "tool"
            components.path = "/" + tool.rawValue
            files = urls
        }
        components.queryItems = files.isEmpty ? nil : files.map { URLQueryItem(name: "file", value: $0.standardizedFileURL.path) }
        return components.url!
    }
}

/// The Finder Quick Actions (features §2.5), one app extension each in the app's PlugIns folder. Each hands the
/// selected files to the app as `AppRoute.tool(tool, files:)`.
public enum QuickAction: String, CaseIterable, Sendable {
    case combine, makeSmaller = "make-smaller", convertToPDF = "convert-to-pdf", recogniseText = "recognise-text"

    /// The name Finder shows (menu items are title case, ux §4).
    public var title: String {
        switch self {
        case .combine: "Combine in Super PDF"
        case .makeSmaller: Strings.menuTitle("Make smaller")
        case .convertToPDF: Strings.menuTitle("Convert to PDF")
        case .recogniseText: Strings.menuTitle("Recognise text")
        }
    }

    public var tool: ToolID {
        switch self {
        case .combine: .combineFiles
        case .makeSmaller: .makeSmaller
        case .convertToPDF: .anyFileToPDF
        case .recogniseText: .recogniseText
        }
    }

    /// The extension's bundle name in Contents/PlugIns ("MakeSmaller.appex") and its bundle id's last part.
    public var bundleName: String {
        switch self {
        case .combine: "CombineInSuperPDF"
        case .makeSmaller: "MakeSmaller"
        case .convertToPDF: "ConvertToPDF"
        case .recogniseText: "RecogniseText"
        }
    }

    public var bundleID: String { SuperPDFPaths.bundleID + ".quickactions." + bundleName }

    /// Make smaller and Recognise text work on PDFs; Combine and Convert take anything that can become a PDF.
    public var acceptsPDFsOnly: Bool { self == .makeSmaller || self == .recogniseText }

    /// The action an extension performs, from the `SuperPDFQuickAction` key of its Info.plist.
    public init?(bundleInfo: [String: Any]?) {
        guard let raw = bundleInfo?[Self.infoKey] as? String else { return nil }
        self.init(rawValue: raw)
    }

    public static let infoKey = "SuperPDFQuickAction"
}
