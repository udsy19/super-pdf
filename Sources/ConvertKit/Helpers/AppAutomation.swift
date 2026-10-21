import Foundation
import SuperPDFCore

// App automation (features §3.2): Word, Excel, PowerPoint, Pages, Numbers and Keynote export a file as PDF through Apple
// Events. The panel says "Pages will open to export this file" before it happens; the app is told to quit afterwards
// only if it wasn't running before. Scripts run in `osascript` as a child process with a time limit, so the
// Automation prompt names Super PDF and a stuck app never blocks the main thread.

/// Runs an AppleScript to completion. Tests inject a fake: no self-test ever opens an app.
typealias ScriptRunner = @Sendable (_ script: String) async throws -> Void

enum AppAutomation {
    static let timeout: TimeInterval = 180

    /// The apps that can export through a script (Mail has no PDF export).
    static func supports(_ app: OfficeApp) -> Bool { app != .mail }

    /// The real runner: `/usr/bin/osascript -e script`.
    static let osascript: ScriptRunner = { script in
        try await ProcessRunner.run(URL(fileURLWithPath: "/usr/bin/osascript"), arguments: ["-e", script], timeout: timeout)
    }

    /// The export script for `app`; nil for apps that can't export.
    static func exportScript(_ app: OfficeApp, input: URL, output: URL, quitAfterwards: Bool) -> String? {
        let source = quote(input.path), target = quote(output.path), id = quote(app.bundleIdentifier)
        let quit = quitAfterwards ? "\n    quit" : ""
        switch app {
        case .pages, .numbers, .keynote:
            return """
            set inFile to POSIX file \(source)
            set outFile to POSIX file \(target)
            tell application id \(id)
                set theDocument to open inFile
                export theDocument to outFile as PDF
                close theDocument saving no\(quit)
            end tell
            """
        case .word:
            return """
            set inFile to POSIX file \(source)
            tell application id \(id)
                open inFile
                set theDocument to active document
                save as theDocument file name \(target) file format format PDF
                close theDocument saving no\(quit)
            end tell
            """
        case .excel:
            return """
            set inFile to POSIX file \(source)
            tell application id \(id)
                set theBook to open workbook workbook file name (inFile as text)
                save workbook as theBook filename \(target) file format PDF file format
                close theBook saving no\(quit)
            end tell
            """
        case .powerPoint:
            return """
            set inFile to POSIX file \(source)
            set outFile to POSIX file \(target)
            tell application id \(id)
                open inFile
                set thePresentation to active presentation
                save thePresentation in outFile as save as PDF
                close thePresentation\(quit)
            end tell
            """
        case .mail:
            return nil
        }
    }

    /// An AppleScript string literal.
    static func quote(_ text: String) -> String {
        "\"" + text.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"") + "\""
    }

    /// The App Store page of a free Apple app ("Get Pages", ux §7.4); nil for the others.
    static func appStorePage(_ app: OfficeApp) -> URL? {
        switch app {
        case .pages: URL(string: "https://apps.apple.com/app/id409201541")
        case .numbers: URL(string: "https://apps.apple.com/app/id409203825")
        case .keynote: URL(string: "https://apps.apple.com/app/id409183694")
        default: nil
        }
    }
}
