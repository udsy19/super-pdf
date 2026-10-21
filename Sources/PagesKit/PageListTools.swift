import Foundation
import PDFKit
import SuperPDFCore

// Rotate, Delete, Extract, Rearrange and Insert (features #19–#22, #24–#27; ux §5.3, §6.2): edits of the page list.
extension PagesTools {
    // MARK: Rotate pages (A)

    /// The scope's pages, or every page seen sideways (wider than tall) when "All sideways pages" is on.
    func rotateTargets(_ context: ToolContext) -> [Int] {
        guard context.values.bool(Key.sideways), let pdf = context.document?.pdf else { return scopePages(context) }
        return (0..<pdf.pageCount).filter { index in
            guard let page = pdf.page(at: index) else { return false }
            let size = page.bounds(for: .cropBox).size
            return page.rotation % 180 == 0 ? size.width > size.height : size.height > size.width
        }
    }

    func rotatePanel(_ context: ToolContext) -> ToolPanel {
        let pages = rotateTargets(context)
        let sideways = context.values.bool(Key.sideways)
        return ToolPanel(.oneChoice, showsScope: !sideways, controls: [
            .segmented(id: Key.direction, options: [
                ToolOption("left", PagesStrings.rotateLeft, symbol: "rotate.left"),
                ToolOption("right", PagesStrings.rotateRight, symbol: "rotate.right"),
            ], selected: "right"),
            .scope,
            .toggle(id: Key.sideways, label: PagesStrings.allSideways, isOn: false),
        ], primary: ToolButton(PagesStrings.rotate(pages.count), isEnabled: !pages.isEmpty),
        message: sideways && pages.isEmpty ? ToolMessage(.info, PagesStrings.noSideways) : nil)
    }

    func runRotate(_ request: ToolRequest) async throws -> ToolResult {
        let document = try document(request)
        let context = ToolContext(tool: .rotatePages, document: document, scope: .selected(request.pages), values: request.values)
        let turns = request.values.string(Key.direction, default: "right") == "left" ? -1 : 1
        return .inPlace(undoable: try await editor.perform(.rotate(rotateTargets(context), quarterTurns: turns), in: document), banner: nil)
    }

    // MARK: Delete pages (A)

    func deletePanel(_ context: ToolContext) -> ToolPanel {
        let pages = scopePages(context)
        let everything = pages.count >= (context.document?.pageCount ?? 0)
        return ToolPanel(.oneChoice, showsScope: true, controls: [.scope],
                         primary: ToolButton(PagesStrings.delete(pages.count), isEnabled: !pages.isEmpty && !everything, isDestructive: true),
                         message: everything ? ToolMessage(.error, Strings.Errors.lastPage) : nil)
    }

    func runDelete(_ request: ToolRequest) async throws -> ToolResult {
        .inPlace(undoable: try await editor.perform(.delete(request.pages), in: try document(request)), banner: nil)
    }

    // MARK: Extract pages (A)

    func extractPanel(_ context: ToolContext) -> ToolPanel {
        let pages = scopePages(context)
        let each = context.values.bool(Key.each)
        let removesAll = context.values.bool(Key.remove) && pages.count >= (context.document?.pageCount ?? 0)
        let output: OutputPolicy = each ? .folder(.parts) : .sibling(.pages(Self.ranges(pages)), ext: "pdf")
        return ToolPanel(.oneChoice, showsScope: true, controls: [
            .scope,
            .toggle(id: Key.remove, label: PagesStrings.removeFromDocument, isOn: false),
            .toggle(id: Key.each, label: PagesStrings.eachPageOwnFile, isOn: false),
        ], primary: ToolButton(PagesStrings.savePagesAsPDF, isEnabled: !pages.isEmpty && !removesAll), output: output,
        message: removesAll ? ToolMessage(.error, Strings.Errors.lastPage) : nil)
    }

    func runExtract(_ request: ToolRequest) async throws -> ToolResult {
        let document = try document(request)
        let pages = request.pages
        guard !pages.isEmpty else { throw ToolError(PageEditError.pagesOutOfRange.errorDescription ?? "") }
        let remove = request.values.bool(Key.remove)
        if remove, pages.count >= document.pageCount { throw ToolError(Strings.Errors.lastPage) }
        let source = document.snapshot(), base = document.displayName, work = request.workFolder
        let result: ToolResult
        if request.values.bool(Key.each) {
            let files = try await Task.detached {
                try PageEngine.write(pages.map { [$0] }, of: source, to: work) {
                    OutputSuffix.pages(PageRanges([pages[$0 - 1]...pages[$0 - 1]])).fileName(base: base, ext: "pdf")
                }
            }.value
            let folder = request.destination?.lastPathComponent ?? OutputFolder.parts.folderName(base: base)
            result = .newFiles(files, banner: Strings.Banner.savedFiles(files.count, folder: folder))
        } else {
            let name = request.destination?.lastPathComponent
                ?? OutputSuffix.pages(Self.ranges(pages)).fileName(base: base, ext: "pdf")
            let file = work.appendingPathComponent(name)
            try await Task.detached { try PageEngine.pages(pages, of: source).write(to: file) }.value
            result = .newFile(file, banner: Strings.Banner.saved(name, openIn: nil))
        }
        if remove {
            // The new file is written; the pages leave this document as their own undo step.
            let group = try await editor.perform(.delete(pages), in: document)
            try await Services.documents.apply(.inPlace(undoable: group, banner: nil), of: request)
        }
        return result
    }

    // MARK: Rearrange pages (D)

    func rearrangePanel(_ context: ToolContext) -> ToolPanel {
        ToolPanel(.mode, controls: [
            .note(PagesStrings.organiserHint),
            .action(id: Action.organiser, title: PagesStrings.showOrganiser, isDestructive: false, symbol: "rectangle.grid.2x2"),
        ], primary: ToolButton(Strings.Panel.done), secondary: nil)
    }

    // MARK: Insert pages (A)

    func insertPanel(_ context: ToolContext) -> ToolPanel {
        let count = context.document?.pageCount ?? 0
        let source = context.values.string(Key.source, default: Source.file)
        let replace = source == Source.file && context.values.bool(Key.replace)
        let after = min(context.values.int(Key.after, default: context.currentPage + 1), count)
        var controls: [ToolControl] = [
            .segmented(id: Key.source, options: [
                ToolOption(Source.file, PagesStrings.fromFile, symbol: "doc"),
                ToolOption(Source.blank, PagesStrings.blankPage, symbol: "doc.badge.plus"),
                ToolOption(Source.scanner, PagesStrings.fromScanner, symbol: "scanner"),
                ToolOption(Source.iPhone, PagesStrings.fromIPhone, symbol: "iphone"),
            ], selected: Source.file),
        ]
        if source == Source.file {
            controls.append(.files(id: Key.files, label: PagesStrings.insertFrom, types: Self.droppableTypes, allowsMultiple: true))
        }
        if replace {
            controls.append(.scope)
        } else {
            controls.append(.stepper(id: Key.after, label: PagesStrings.afterPage, range: 0...max(count, 0), value: min(context.currentPage + 1, count)))
        }
        var primary = ToolButton(PagesStrings.insert)
        var message: ToolMessage?
        switch source {
        case Source.scanner, Source.iPhone:
            controls.append(.note(PagesStrings.scanNote(after: after)))
            controls.append(.action(id: Action.scan, title: PagesStrings.startScanning, isDestructive: false,
                                    symbol: source == Source.iPhone ? "iphone" : "scanner"))
            primary.isEnabled = false
        case Source.file:
            let files = context.values.queue(Key.files, inputs: context.inputs)
            if replace { primary = ToolButton(PagesStrings.replace(scopePages(context).count)) }
            primary.isEnabled = !files.isEmpty && (!replace || !scopePages(context).isEmpty)
            if files.isEmpty { message = ToolMessage(.info, PagesStrings.chooseFile) }
        default:
            break
        }
        return ToolPanel(.oneChoice, showsScope: replace, controls: controls, moreOptions: [
            .toggle(id: Key.replace, label: PagesStrings.replaceInstead, isOn: false),
            .action(id: Action.reverse, title: PagesStrings.reverseOrder, isDestructive: false, symbol: "arrow.up.arrow.down"),
        ], primary: primary, message: message)
    }

    func runInsert(_ request: ToolRequest, progress: ToolProgress) async throws -> ToolResult {
        let document = try document(request)
        let after = min(max(request.values.int(Key.after, default: 1), 0), document.pageCount)
        switch request.values.string(Key.source, default: Source.file) {
        case Source.blank:
            return .inPlace(undoable: try await editor.perform(.insertBlank(after: after - 1), in: document), banner: nil)
        case Source.file:
            let files = request.values.queue(Key.files, inputs: request.inputs)
            guard !files.isEmpty else { throw ToolError(PagesStrings.chooseFile) }
            var sources: [PDFSource] = []
            for file in files { sources.append(try await pdfSource(for: file, in: request.workFolder, progress: progress)) }
            if request.values.bool(Key.replace), let first = request.pages.first, let last = request.pages.last {
                return .inPlace(undoable: try await editor.perform(.replace(first...last, with: sources[0], pages: []), in: document), banner: nil)
            }
            var groups: [UndoGroup] = []
            var at = after
            for source in sources {
                let before = document.pageCount
                groups.append(try await editor.perform(.insertFile(source, pages: [], at: at), in: document))
                at += document.pageCount - before
            }
            return .inPlace(undoable: groups.count == 1 ? groups[0] : .combined(PagesStrings.Undo.insert, groups), banner: nil)
        default:
            return .none
        }
    }
}
