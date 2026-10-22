import Foundation
import SuperPDFCore

/// ToolsKit's own copy (shared copy lives in `Strings`): the scope row's range item, the fallback error and the open
/// prompt for document tools started without a document.
enum ToolsKitStrings {
    /// The scope popup item that asks for page numbers.
    static let rangeItem = "Some pages…"
    static let rangePlaceholder = "1–3, 7"
    /// The "Pages" choice under a file in a queue (ux §5.3 Combine: "Pages: all ▾").
    static let allPages = "All"
    /// What a screen reader calls the dot grid of Watermark and Page numbers.
    static let position = "Position"
    static func pagesOf(_ fileName: String) -> String { "Pages of \(Strings.quoted(fileName))" }
    /// A failure that isn't a `ToolError` (the code goes behind Show details).
    static let somethingWentWrong = "Something went wrong. Nothing was changed."
    /// The open panel's message when a tile needs a document and none is open.
    static func choosePDF(for tool: String) -> String { "Choose a PDF to use \(Strings.quoted(tool)) on." }
    /// The save panel's prompt is the primary button's verb without the ellipsis.
    static func savePrompt(_ title: String) -> String { title.hasSuffix("…") ? String(title.dropLast()) : title }
    static let progressSeparator = " · "
}
