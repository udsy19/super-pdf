import Foundation
import SuperPDFCore

/// MarkupKit's own copy (sentence case, curly quotes, real ellipses; ux §1.1, §7). Preview's words where Preview has
/// them come from its tables (see MarkupModel.swift).
enum MarkupKitStrings {
    static func points(_ value: Double) -> String {
        (value == value.rounded() ? String(Int(value)) : String(value)) + " pt"
    }

    /// Tools › Annotate's shortcut for a tool (ux §6.4), read from the menu tree so they never disagree.
    static func shortcut(for command: MenuCommand) -> KeyCombo? {
        MenuTree.shortcuts.first { $0.command == command }?.shortcut
    }

    static func shortcut(for kind: ShapeKind) -> KeyCombo? {
        let command: MenuCommand? = switch kind {
        case .line: .line
        case .arrow: .arrow
        case .rectangle: .rectangle
        case .oval: .oval
        case .loupe: .loupe
        default: nil
        }
        return command.flatMap { shortcut(for: $0) }
    }

    enum Panel {
        static let highlightHint = "Choose a tool, then drag across the words. Your notes keep your name and the date."
        static let drawHint = "Choose a tool, then drag on the page. Click a drawing to move it; drag a corner to resize it."
        static let paletteFooter = "The markup bar under the toolbar has the same tools. Press Esc to stop."

        // Comments list
        static let all = "All"
        static let mine = "Mine"
        static let unresolved = "Unresolved"
        static let sort = "Sort"
        static let byPage = "Page"
        static let byDate = "Date"
        static let byAuthor = "Author"
        static let summarise = "Summarise comments to PDF…"
        static let importComments = "Import comments…"
        static let exportComments = "Export comments…"
        static let summaryLayout = "Summary"
        static let connectorLines = "Page and comments side by side"
        static let commentsOnly = "Comments only"
        static let numbered = "Pages with numbers, then comments"
        static let exportFormat = "Export as"
        static let reply = "Reply"
        static let resolve = "Resolve"
        static let replyPrompt = "Reply"
        static let replyPlaceholder = "Write a reply"
        static func summaryName(_ document: String) -> String { "\(document) (comments)" }

        // Attach a file
        static let file = "File"
        static let voiceNote = "Voice note"
        static let fileLabel = "File"
        static func attachedTo(page: Int) -> String { "Clips it to page \(page). Double-click the paper clip to open it again." }
        static let attachFile = "Attach file"
        static let attachVoiceNote = "Attach voice note"
        static let record = "Record"
        static let stop = "Stop"
        static let play = "Play"
        static let recordHint = "Click Record and speak. Click Stop when you’re done."
        static func recorded(_ seconds: Int) -> String { "Recorded \(seconds) s." }
        static let noMicrophone = "Super PDF can’t use the microphone. Allow it in System Settings › Privacy & Security › Microphone."

        // Measure
        static let thisLineIs = "This line is"
        static let unit = "Unit"
        static let otherUnit = "Other units"
        static let setScale = "Set scale from the last line"
        static let needLine = "Draw a line on the page first, then type how long it really is."
        static let needLength = "Type how long the line really is, for example 10."
        static func scale(_ ratio: String) -> String { "Scale: \(ratio)" }
        static let noMeasurements = "Drag on the page to measure. Perimeter and area: click each corner, double-click to finish."
    }
}
