import Foundation
import PDFKit
import PDFModelKit
import SuperPDFCore

// Combine files, Split and Booklet (features #18, #23, #32, #33; ux §5.3): tools whose result is other files.
extension PagesTools {
    // MARK: Combine files (E)

    /// The files of the queue after the open document (which goes first when there is one): dropped, then added.
    func combineFiles(_ values: ToolValues, inputs: [URL]) -> [URL] { inputs + values.files(Key.files) }

    func combinePanel(_ context: ToolContext) -> ToolPanel {
        let count = (context.document == nil ? 0 : 1) + combineFiles(context.values, inputs: context.inputs).count
        return ToolPanel(.convert, controls: [
            .files(id: Key.files, label: PagesStrings.combineFilesLabel, types: Self.droppableTypes, allowsMultiple: true),
            .toggle(id: Key.contents, label: PagesStrings.combineContents, isOn: true),
            .popup(id: Key.size, label: PagesStrings.fileSize, options: [
                ToolOption("normal", PagesStrings.sizeNormal), ToolOption("smaller", PagesStrings.sizeSmaller),
            ], selected: "normal"),
        ], primary: ToolButton(PagesStrings.combine(count), isEnabled: count >= 2),
        output: .newDocument(name: PagesStrings.combinedName),
        message: count < 2 ? ToolMessage(.info, PagesStrings.combineNeedsTwo) : nil)
    }

    func runCombine(_ request: ToolRequest, progress: ToolProgress) async throws -> ToolResult {
        let urls = combineFiles(request.values, inputs: request.inputs)
        var inputs: [PageEngine.CombineInput] = []
        if let document = request.document { inputs.append(.init(source: document.snapshot(), title: document.displayName)) }
        for (n, url) in urls.enumerated() {
            try Task.checkCancellation()
            progress.report(completed: n, of: urls.count, label: PagesStrings.adding(url.lastPathComponent))
            let source = try await pdfSource(for: url, in: request.workFolder, progress: progress)
            inputs.append(.init(source: source, title: url.deletingPathExtension().lastPathComponent))
        }
        guard inputs.count >= 2 else { throw ToolError(PagesStrings.combineNeedsTwo) }
        let contents = request.values.bool(Key.contents, default: true)
        let titles = inputs.map(\.title)
        var (data, pages) = try await Task.detached { () throws -> (Data, Int) in
            do {
                return try PageEngine.combine(inputs, contents: contents)
            } catch PDFModelError.passwordRequired, PDFModelError.wrongPassword {
                // Which file: the first that does not open without one.
                let locked = zip(inputs, titles).first { (try? PDFModel($0.0.source)) == nil }?.1 ?? ""
                throw ToolError(PagesStrings.needsPassword(locked))
            }
        }.value
        if request.values.string(Key.size) == "smaller", let fix = Services.fix {
            let combined = request.workFolder.appendingPathComponent("combined.pdf"), smaller = request.workFolder.appendingPathComponent("smaller.pdf")
            try data.write(to: combined)
            try await fix.optimize(.file(combined), options: OptimizeOptions(preset: .good), to: smaller, progress: .ignored)
            if let optimised = try? Data(contentsOf: smaller), optimised.count < data.count { data = optimised }
        }
        return .newDocument(data, name: PagesStrings.combinedName, banner: Strings.Banner.combined(files: inputs.count, pages: pages))
    }

    // MARK: Split (B)

    enum SplitMode {
        static let every = "every", size = "size", contents = "contents", blanks = "blanks", ranges = "ranges"
    }

    /// The parts as page groups, when they can be known without looking at the pages (sizes and blank pages are found by
    /// `splitPreview` and kept in `splitPlans`).
    func splitGroups(_ context: ToolContext) -> [[Int]]? {
        guard let document = context.document else { return nil }
        let count = document.pageCount
        switch context.values.string(Key.mode, default: SplitMode.every) {
        case SplitMode.every:
            return PageEngine.groups(every: context.values.int(Key.every, default: 1), count: count)
        case SplitMode.ranges:
            return PageRanges.parse(context.values.string(Key.ranges), pageCount: count)?.ranges.map { Array($0) }
        case SplitMode.contents:
            let starts = (document.pdf.outlineRoot.map { root in (0..<root.numberOfChildren).compactMap { root.child(at: $0) } } ?? [])
                .compactMap { $0.destination?.page.map { document.pdf.index(for: $0) } }
            return starts.isEmpty ? [] : PageEngine.groups(startingAt: starts, count: count)
        default:
            return splitPlans[splitKey(context)]
        }
    }

    func splitKey(_ context: ToolContext) -> String {
        let mode = context.values.string(Key.mode, default: SplitMode.every)
        let parameter = mode == SplitMode.size ? "\(context.values.int(Key.megabytes, default: 10))" : ""
        return "\(context.document?.id.uuidString ?? "")|\(context.document?.pageCount ?? 0)|\(mode)|\(parameter)"
    }

    func splitPanel(_ context: ToolContext) -> ToolPanel {
        let mode = context.values.string(Key.mode, default: SplitMode.every)
        let count = context.document?.pageCount ?? 0
        var controls: [ToolControl] = [
            .radio(id: Key.mode, options: [
                ToolOption(SplitMode.every, PagesStrings.splitEvery), ToolOption(SplitMode.size, PagesStrings.splitBySize),
                ToolOption(SplitMode.contents, PagesStrings.splitByContents), ToolOption(SplitMode.blanks, PagesStrings.splitByBlanks),
                ToolOption(SplitMode.ranges, PagesStrings.splitRanges),
            ], selected: SplitMode.every),
        ]
        switch mode {
        case SplitMode.every:
            controls.append(.stepper(id: Key.every, label: PagesStrings.pagesPerFile, range: 1...max(count - 1, 1), value: 1))
        case SplitMode.size:
            controls.append(.stepper(id: Key.megabytes, label: PagesStrings.largestFile, range: 1...2000, value: 10))
        case SplitMode.ranges:
            controls.append(.text(id: Key.ranges, label: PagesStrings.splitRanges, placeholder: PagesStrings.rangesPlaceholder, value: "", isSecure: false))
        default:
            break
        }
        let groups = splitGroups(context)
        var message: ToolMessage?
        if let groups, groups.count < 2 {
            message = switch mode {
            case SplitMode.contents: ToolMessage(.info, PagesStrings.noContents)
            case SplitMode.blanks: ToolMessage(.info, PagesStrings.noBlanks)
            case SplitMode.ranges: nil
            default: ToolMessage(.info, PagesStrings.splitOneFile)
            }
        }
        if mode == SplitMode.ranges, groups == nil, !context.values.string(Key.ranges).isEmpty {
            message = ToolMessage(.error, PagesStrings.badRanges)
        }
        let enabled = mode == SplitMode.ranges ? (groups?.isEmpty == false) : (groups.map { $0.count >= 2 } ?? true)
        let title = groups.map { $0.count >= 2 ? PagesStrings.splitInto($0.count) : PagesStrings.split } ?? PagesStrings.split
        return ToolPanel(.presetAndMore, controls: controls, primary: ToolButton(title, isEnabled: enabled), output: .folder(.parts),
                         message: message)
    }

    func splitPreview(_ context: ToolContext) async -> ToolPreview {
        let mode = context.values.string(Key.mode, default: SplitMode.every)
        guard let document = context.document, mode == SplitMode.size || mode == SplitMode.blanks else { return .none }
        let key = splitKey(context)
        if splitPlans[key] == nil {
            let source = document.snapshot(), count = document.pageCount
            let limit = context.values.int(Key.megabytes, default: 10) * 1_000_000
            splitPlans[key] = try? await Task.detached { try Self.plan(mode: mode, source: source, count: count, limit: limit) }.value
        }
        if mode == SplitMode.blanks, let groups = splitPlans[key] {
            let blanks = document.pageCount - groups.reduce(0) { $0 + $1.count }
            return blanks > 0 ? .summary([PagesStrings.blanksFound(blanks)]) : .none
        }
        return .none
    }

    /// The parts of the modes that look at the pages, off the main actor.
    nonisolated static func plan(mode: String, source: PDFSource, count: Int, limit: Int) throws -> [[Int]] {
        mode == SplitMode.size
            ? PageEngine.groups(sizes: try PageEngine.pageSizes(source), limit: limit)
            : PageEngine.groups(separatedBy: try PageEngine.blankPages(source), count: count)
    }

    func runSplit(_ request: ToolRequest, progress: ToolProgress) async throws -> ToolResult {
        let document = try document(request)
        let mode = request.values.string(Key.mode, default: SplitMode.every)
        let source = document.snapshot(), count = document.pageCount, base = document.displayName, work = request.workFolder
        let groups: [[Int]]
        if mode == SplitMode.size || mode == SplitMode.blanks {
            let limit = request.values.int(Key.megabytes, default: 10) * 1_000_000
            groups = try await Task.detached { try Self.plan(mode: mode, source: source, count: count, limit: limit) }.value
        } else {
            groups = splitGroups(ToolContext(tool: .split, document: document, values: request.values)) ?? []
        }
        guard groups.count >= 2 || (mode == SplitMode.ranges && !groups.isEmpty) else {
            throw ToolError(mode == SplitMode.contents ? PagesStrings.noContents : mode == SplitMode.blanks ? PagesStrings.noBlanks : PagesStrings.splitOneFile)
        }
        let files = try await Task.detached {
            try PageEngine.write(groups, of: source, to: work, progress: progress) { OutputSuffix.part($0).fileName(base: base, ext: "pdf") }
        }.value
        let folder = request.destination?.lastPathComponent ?? OutputFolder.parts.folderName(base: base)
        return .newFiles(files, banner: Strings.Banner.savedFiles(files.count, folder: folder))
    }

    // MARK: Booklet (B)

    enum BookletLayout {
        static let booklet = "booklet", twoUp = "2up", fourUp = "4up", contactSheet = "contact"
    }

    static let papers: [(id: String, title: String, paper: PaperSize)] = [
        ("same", PagesStrings.sameAsPages, .fitContent), ("a4", "A4", .a4), ("letter", "Letter", .letter),
        ("legal", "Legal", .legal), ("a3", "A3", .a3),
    ]

    /// A4, or Letter where the Mac measures in inches.
    static var localPaper: String { Locale.current.measurementSystem == .us ? "letter" : "a4" }

    func bookletPanel(_ context: ToolContext) -> ToolPanel {
        let layout = context.values.string(Key.layout, default: BookletLayout.booklet)
        let title = switch layout {
        case BookletLayout.booklet: PagesStrings.makeBooklet
        case BookletLayout.contactSheet: PagesStrings.makeContactSheet
        default: PagesStrings.makeSheets
        }
        return ToolPanel(.presetAndMore, controls: [
            .radio(id: Key.layout, options: [
                ToolOption(BookletLayout.booklet, PagesStrings.bookletFold, detail: PagesStrings.bookletFoldDetail),
                ToolOption(BookletLayout.twoUp, PagesStrings.twoPerSheet),
                ToolOption(BookletLayout.fourUp, PagesStrings.fourPerSheet),
                ToolOption(BookletLayout.contactSheet, PagesStrings.contactSheet, detail: PagesStrings.contactSheetDetail),
            ], selected: BookletLayout.booklet),
            .popup(id: Key.paper, label: PagesStrings.paper, options: Self.papers.map { ToolOption($0.id, $0.title) }, selected: Self.localPaper),
        ], primary: ToolButton(title, isEnabled: context.document != nil),
        output: .newDocument(name: PagesStrings.bookletName(context.document?.displayName ?? PagesStrings.combinedName)))
    }

    func runBooklet(_ request: ToolRequest) async throws -> ToolResult {
        let document = try document(request)
        let layout: Imposition = switch request.values.string(Key.layout, default: BookletLayout.booklet) {
        case BookletLayout.twoUp: .nUp(2)
        case BookletLayout.fourUp: .nUp(4)
        case BookletLayout.contactSheet: .contactSheet(columns: 4)
        default: .booklet
        }
        let paperID = request.values.string(Key.paper, default: Self.localPaper)
        let paper = Self.papers.first { $0.id == paperID }?.paper ?? .a4
        let file = request.workFolder.appendingPathComponent("booklet.pdf")
        try await Services.render.impose(document.snapshot(), layout: layout, paper: paper, to: file)
        return .newDocument(try Data(contentsOf: file), name: PagesStrings.bookletName(document.displayName), banner: nil)
    }
}
