import Foundation
import SuperPDFCore

// The built-in converters into PDF (features §3.2 "1st: built in"). Each reads one file and writes one PDF; the ones on
// WebKit run on the main actor (WKWebView), the rest off it. ZIP is the service's own: it recurses through the registry.

enum Importers {
    static func run(_ converter: BuiltInConverter, input: URL, output: URL, options: ImportOptions) async throws -> ImportReport {
        switch converter {
        case .webKit: return try await WebImporter.convert(input, to: output, options: options)
        case .markdown: return try await MarkdownImporter.convert(input, to: output, options: options)
        case .epub: return try await EPUBImporter.convert(input, to: output, options: options)
        case .mail: return try await MailImporter.convert(input, to: output, options: options)
        case .quickLook: return try await QuickLookImporter.convert(input, to: output, options: options)
        default: break
        }
        let work: @Sendable () throws -> ImportReport
        switch converter {
        case .attributedText: work = { try AttributedTextImporter.convert(input, to: output, options: options) }
        case .spreadsheet: work = { try XLSXImporter.convert(input, to: output, options: options) }
        case .presentation: work = { try PPTXImporter.convert(input, to: output, options: options) }
        case .iWorkPreview: work = { try IWorkPreviewImporter.convert(input, to: output, options: options) }
        case .hwpx: work = { try HWPXImporter.convert(input, to: output, options: options) }
        case .delimitedText: work = { try DelimitedTextImporter.convert(input, to: output, options: options) }
        case .structuredText: work = { try StructuredTextImporter.convert(input, to: output, options: options) }
        case .images: work = { try ImageImporter.convert(input, to: output, options: options) }
        case .postScript: work = { try PostScriptImporter.convert(input, to: output, options: options) }
        default: throw ConvertError.unsupported(converter.rawValue)
        }
        return try await Task.detached(priority: .userInitiated, operation: work).value
    }
}
