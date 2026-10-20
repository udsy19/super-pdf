import Foundation
import PDFKit
import SuperPDFCore
import UniformTypeIdentifiers

/// PagesKit's tiles (features #18–#33; ux §5.3): the panels, live previews and runs of the Pages section. Each tool's
/// panel and run live in an extension next to its kind: page lists (rotate, delete, extract, rearrange, insert), files
/// (combine, split, booklet) and page layout (crop, number pages, resize).
@MainActor
final class PagesTools: ToolProviding {
    let editor: PageEditing

    /// Plans of the split modes that need the pages looked at (size, blank pages), computed by `preview` and shown in
    /// the panel's button ("Split into 4 files").
    var splitPlans: [String: [[Int]]] = [:]

    init(editor: PageEditing) { self.editor = editor }

    var tools: [ToolID] { ToolCatalog.tiles(ownedBy: .pagesKit).map(\.id) }

    func panel(for tool: ToolID, context: ToolContext) -> ToolPanel {
        switch tool {
        case .combineFiles: combinePanel(context)
        case .rearrangePages: rearrangePanel(context)
        case .split: splitPanel(context)
        case .extractPages: extractPanel(context)
        case .rotatePages: rotatePanel(context)
        case .deletePages: deletePanel(context)
        case .crop: cropPanel(context)
        case .insertPages: insertPanel(context)
        case .numberPages: numberPanel(context)
        case .booklet: bookletPanel(context)
        case .resizePages: resizePanel(context)
        default: ToolPanel(.oneChoice, primary: ToolButton(Strings.Panel.done, isEnabled: false))
        }
    }

    func preview(for tool: ToolID, context: ToolContext) async -> ToolPreview {
        switch tool {
        case .split: await splitPreview(context)
        case .crop: cropPreview(context)
        case .numberPages: numberPreview(context)
        default: .none
        }
    }

    func handle(action: String, context: ToolContext) async throws -> ToolValues {
        do {
            switch (context.tool, action) {
            case (.rearrangePages, Action.organiser):
                if let document = context.document { Services.viewer?.showOrganiser(for: document, adding: context.inputs) }
            case (.insertPages, Action.reverse):
                try await applyInPlace(.reverse, context: context)
            case (.insertPages, Action.scan):
                let tool: ToolID = context.values.string(Key.source) == Source.iPhone ? .scanWithIPhone : .scanWithScanner
                Services.tools?.openPanel(tool, for: context.document, inputs: [])
            case (.crop, Action.whiteMargins):
                return try await removeWhiteMargins(context)
            default:
                break
            }
        } catch let error as PageEditError {
            throw ToolError(error.errorDescription ?? "")
        }
        return context.values
    }

    func run(_ request: ToolRequest, progress: ToolProgress) async throws -> ToolResult {
        do {
            switch request.tool {
            case .combineFiles: return try await runCombine(request, progress: progress)
            case .rearrangePages: return .none
            case .split: return try await runSplit(request, progress: progress)
            case .extractPages: return try await runExtract(request)
            case .rotatePages: return try await runRotate(request)
            case .deletePages: return try await runDelete(request)
            case .crop: return try runCrop(request)
            case .insertPages: return try await runInsert(request, progress: progress)
            case .numberPages: return try await runNumbers(request)
            case .booklet: return try await runBooklet(request)
            case .resizePages: return try await runResize(request)
            default: return .none
            }
        } catch let error as PageEditError {
            throw ToolError(error.errorDescription ?? "")
        }
    }

    // MARK: Shared

    /// Control and value ids.
    enum Key {
        static let files = "files", contents = "contents", size = "size"
        static let mode = "mode", every = "every", megabytes = "megabytes", ranges = "ranges"
        static let remove = "remove", each = "each"
        static let direction = "direction", sideways = "sideways"
        static let unit = "unit", box = "box"
        static let top = "top", left = "left", bottom = "bottom", right = "right"
        static let source = "source", after = "after", replace = "replace"
        static let position = "position", style = "style", start = "start", skip = "skip", fontSize = "fontSize", labels = "labels"
        static let layout = "layout", paper = "paper", fit = "fit", width = "width", height = "height"
    }

    enum Action {
        static let organiser = "organiser", reverse = "reverse", scan = "scan", whiteMargins = "whiteMargins"
    }

    enum Source {
        static let file = "file", blank = "blank", scanner = "scanner", iPhone = "iphone"
    }

    /// The pages the panel's scope covers in the open document.
    func scopePages(_ context: ToolContext) -> [Int] {
        guard let document = context.document else { return [] }
        return context.scope.pages(count: document.pageCount, current: context.currentPage)
    }

    /// Sorted pages as ranges ("3-5" for 2, 3, 4).
    static func ranges(_ pages: [Int]) -> PageRanges {
        var ranges: [ClosedRange<Int>] = []
        for page in pages.sorted() {
            if let last = ranges.last, last.upperBound + 1 == page { ranges[ranges.count - 1] = last.lowerBound...page } else { ranges.append(page...page) }
        }
        return PageRanges(ranges)
    }

    func document(_ request: ToolRequest) throws -> DocumentHandle {
        guard let document = request.document else { throw ToolError(PageEditError.pagesOutOfRange.errorDescription ?? "") }
        return document
    }

    /// An in-place page edit made from a panel button, registered by DocumentKit like a run's result.
    func applyInPlace(_ operation: PageOperation, context: ToolContext) async throws {
        guard let document = context.document else { return }
        let group = try await editor.perform(operation, in: document)
        let work = SuperPDFPaths.ensure(SuperPDFPaths.work.appendingPathComponent(UUID().uuidString, isDirectory: true))
        let request = ToolRequest(tool: context.tool, document: document, workFolder: work)
        try await Services.documents.apply(.inPlace(undoable: group, banner: nil), of: request)
    }

    /// A file as PDF bytes: PDFs as they are, anything else through the conversion registry into `folder`.
    func pdfSource(for url: URL, in folder: URL, progress: ToolProgress) async throws -> PDFSource {
        if UTType(filenameExtension: url.pathExtension)?.conforms(to: .pdf) == true { return .file(url) }
        progress.report(completed: 0, of: 1, label: PagesStrings.converting(url.lastPathComponent))
        let destination = folder.appendingPathComponent(UUID().uuidString + ".pdf")
        do {
            let result = try await Services.convert.convert(ConversionJob(inputs: [url], output: .pdf, destination: destination), progress: .ignored)
            return .file(result.outputs.first ?? destination)
        } catch let error as ToolError {
            throw error
        } catch {
            throw ToolError(Strings.Errors.conversionFailed(url.lastPathComponent), details: String(describing: error))
        }
    }

    /// The UTType identifiers the file drop zones take: PDFs and anything the registry might convert.
    static let droppableTypes = [UTType.pdf.identifier, UTType.image.identifier, UTType.content.identifier, UTType.data.identifier]
}
