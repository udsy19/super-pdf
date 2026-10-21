import Foundation
import PDFKit
import SuperPDFCore

/// `Services.batch` (features #75, "Do this to many files"): saved routines, and pipelines of file-level tools run over
/// files and folders. Each file is opened as a document no window shows, every step runs through its tile's own
/// provider exactly as its panel would run it (its panel's defaults, then the step's values), and each step's result
/// feeds the next: a new file, the bytes an in-place edit made, or a new document. The last result goes next to the
/// original (or into the chosen folder) under the name its tool gives ("Report (smaller).pdf"; "Report (edited).pdf"
/// when every step edits in place); the original is never touched (ux §1.1 "Nothing is lost").
@MainActor
public final class BatchRunner: BatchRunning {
    private let folder: URL
    public private(set) var routines: [Routine] = []

    /// `folder` holds the routines, one `<id>.json` each (`SuperPDFPaths.routines` in the app).
    public init(folder: URL) {
        self.folder = folder
        routines = Self.load(folder)
    }

    // MARK: Routines

    public func save(_ routine: Routine) throws {
        SuperPDFPaths.ensure(folder)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        try encoder.encode(routine).write(to: file(routine.id), options: .atomic)
        routines.removeAll { $0.id == routine.id }
        routines.append(routine)
        routines.sort { $0.created < $1.created }
    }

    public func delete(_ routineID: UUID) throws {
        let url = file(routineID)
        if FileManager.default.fileExists(atPath: url.path) { try FileManager.default.removeItem(at: url) }
        routines.removeAll { $0.id == routineID }
    }

    private func file(_ id: UUID) -> URL { folder.appendingPathComponent(id.uuidString.lowercased() + ".json") }

    private static func load(_ folder: URL) -> [Routine] {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let files = (try? FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil)) ?? []
        return files.filter { $0.pathExtension == "json" }
            .compactMap { (try? Data(contentsOf: $0)).flatMap { try? decoder.decode(Routine.self, from: $0) } }
            .sorted { $0.created < $1.created }
    }

    // MARK: Running

    /// Runs `pipeline` on every file (folders expanded, in name order); a file that fails is reported and the others
    /// go on. Cancelling the consuming task stops after the step under way.
    public func run(_ pipeline: BatchPipeline, on files: [URL]) -> AsyncThrowingStream<BatchEvent, Error> {
        AsyncThrowingStream { continuation in
            let task = Task { @MainActor in
                for file in Self.expand(files) {
                    if Task.isCancelled { break }
                    continuation.yield(.started(file))
                    do {
                        let outputs = try await self.run(pipeline, on: file) { tool, update in
                            continuation.yield(.step(file, tool: tool, update))
                        }
                        continuation.yield(.finished(file, outputs: outputs))
                    } catch is CancellationError {
                        break
                    } catch {
                        continuation.yield(.failed(file, message: Self.message(for: error)))
                    }
                }
                continuation.finish(throwing: Task.isCancelled ? CancellationError() : nil)
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    /// The files of `inputs` a pipeline runs on: files themselves, and the files inside folders (not hidden, not
    /// packages' insides), each once, in name order per folder.
    nonisolated static func expand(_ inputs: [URL]) -> [URL] {
        var seen: Set<URL> = [], found: [URL] = []
        let fm = FileManager.default
        for input in inputs {
            var isFolder: ObjCBool = false
            guard fm.fileExists(atPath: input.path, isDirectory: &isFolder) else { continue }
            let isPackage = (try? input.resourceValues(forKeys: [.isPackageKey]))?.isPackage ?? false
            if isFolder.boolValue && !isPackage {
                let enumerator = fm.enumerator(at: input, includingPropertiesForKeys: [.isRegularFileKey, .isPackageKey],
                                               options: [.skipsHiddenFiles, .skipsPackageDescendants])
                var inside: [URL] = []
                while let item = enumerator?.nextObject() as? URL {
                    let values = try? item.resourceValues(forKeys: [.isRegularFileKey, .isPackageKey])
                    if values?.isRegularFile == true || values?.isPackage == true { inside.append(item) }
                }
                for item in inside.sorted(by: { $0.path.localizedStandardCompare($1.path) == .orderedAscending })
                where seen.insert(item.standardizedFileURL).inserted {
                    found.append(item)
                }
            } else if seen.insert(input.standardizedFileURL).inserted {
                found.append(input)
            }
        }
        return found
    }

    /// One file through every step; the outputs where they were placed.
    private func run(_ pipeline: BatchPipeline, on file: URL,
                     progress: @escaping @Sendable (ToolID, ToolProgress.Update) -> Void) async throws -> [URL] {
        guard !pipeline.steps.isEmpty else { return [] }
        let work = SuperPDFPaths.ensure(SuperPDFPaths.work.appendingPathComponent("batch-" + UUID().uuidString, isDirectory: true))
        defer { try? FileManager.default.removeItem(at: work) }
        let base = file.deletingPathExtension().lastPathComponent
        var current = try await pdf(for: file, in: work)
        var naming: OutputPolicy = .sibling(.edited, ext: "pdf")
        var changed = false

        for (index, step) in pipeline.steps.enumerated() {
            try Task.checkCancellation()
            guard let provider = Services.tools?.provider(for: step.tool) else { throw BatchError.noTool(step.tool) }
            guard let pdf = PDFDocument(url: current) else { throw BatchError.unreadable(file.lastPathComponent) }
            guard !pdf.isLocked else { throw BatchError.locked(file.lastPathComponent) }
            let undo = UndoManager()
            undo.groupsByEvent = false
            let handle = DocumentHandle(url: current, displayName: base, pdf: pdf, undoManager: undo)
            let pages = Array(0..<handle.pageCount)
            var context = ToolContext(tool: step.tool, document: handle, selection: [], currentPage: 0, scope: .all, values: step.values)
            let panel = provider.panel(for: step.tool, context: context)
            var values = panel.initialValues
            for (key, value) in step.values.storage { values[key] = value }
            context.values = values
            let described = provider.panel(for: step.tool, context: context)
            guard described.primary.isEnabled else {
                throw BatchError.cantRun(step.tool, reason: described.message?.text)
            }
            let stepWork = SuperPDFPaths.ensure(work.appendingPathComponent("step-\(index)", isDirectory: true))
            let destination = Services.documents?.destination(for: described.output, of: nil,
                                                              source: stepWork.appendingPathComponent(base + ".pdf"))
            let request = ToolRequest(tool: step.tool, document: handle, source: handle.snapshot(), pages: pages, values: values, inputs: [],
                                      destination: destination, workFolder: stepWork)
            let tool = step.tool
            let result = try await provider.run(request, progress: ToolProgress { progress(tool, $0) })
            switch result {
            case .newFile(let url, _):
                current = url
                naming = described.output
                changed = true
            case .newFiles(let urls, _):
                // Pictures, parts: the end of the line for this file.
                return try place(urls, policy: described.output, original: file, into: pipeline.outputFolder)
            case .newDocument(let data, _, _):
                current = stepWork.appendingPathComponent(base + ".pdf")
                try data.write(to: current)
                changed = true
            case .inPlace(let group, _):
                current = stepWork.appendingPathComponent("edited.pdf")
                switch group.change {
                case .contents(_, let after):
                    try after.write(to: current)
                case .actions:
                    // The edit is already in the PDFKit document; its bytes as a save writes them.
                    handle.state.isEdited = true
                    try handle.snapshot().bytes().write(to: current)
                }
                changed = true
            case .none:
                break
            }
        }
        guard changed else { return [] }
        return [try place(current, policy: naming, original: file, into: pipeline.outputFolder)]
    }

    /// A file that isn't a PDF goes through the converter first (into `work`).
    private func pdf(for file: URL, in work: URL) async throws -> URL {
        if file.pathExtension.lowercased() == "pdf" { return file }
        guard let convert = Services.convert, convert.canConvertToPDF(file) else {
            throw BatchError.notConvertible(file.pathExtension.lowercased())
        }
        let destination = work.appendingPathComponent(file.deletingPathExtension().lastPathComponent + ".pdf")
        let result = try await convert.convert(ConversionJob(inputs: [file], output: .pdf, destination: destination), progress: .ignored)
        return result.outputs.first ?? destination
    }

    /// The last result next to the original (or in `folder`) under the name `policy` gives, never over an existing file.
    private func place(_ output: URL, policy: OutputPolicy, original: URL, into folder: URL?) throws -> URL {
        let named: OutputPolicy = switch policy {
        case .inPlace, .newDocument, .folder: .sibling(.edited, ext: output.pathExtension.isEmpty ? "pdf" : output.pathExtension)
        default: policy
        }
        let source = (folder ?? original.deletingLastPathComponent()).appendingPathComponent(original.lastPathComponent)
        guard let target = Services.documents?.destination(for: named, of: nil, source: source) else { throw BatchError.noPlace }
        try FileManager.default.moveItem(at: output, to: target)
        return target
    }

    /// Several results (pictures, parts) in a folder next to the original (or in `folder`): "Report images".
    private func place(_ outputs: [URL], policy: OutputPolicy, original: URL, into folder: URL?) throws -> [URL] {
        let source = (folder ?? original.deletingLastPathComponent()).appendingPathComponent(original.lastPathComponent)
        let kind: OutputPolicy = if case .folder = policy { policy } else { .folder(.parts) }
        guard let target = Services.documents?.destination(for: kind, of: nil, source: source) else { throw BatchError.noPlace }
        try FileManager.default.createDirectory(at: target, withIntermediateDirectories: true)
        return try outputs.map { output in
            let placed = target.appendingPathComponent(output.lastPathComponent)
            try FileManager.default.moveItem(at: output, to: placed)
            return placed
        }
    }

    /// What a failed file says in the list.
    static func message(for error: Error) -> String {
        if let error = error as? ToolError { return error.message.text }
        if let error = error as? BatchError { return error.message }
        return (error as? LocalizedError)?.errorDescription ?? BatchStrings.somethingWentWrong
    }
}

/// Why a file couldn't go through a pipeline.
enum BatchError: Error, Equatable {
    case noTool(ToolID)
    case cantRun(ToolID, reason: String?)
    case unreadable(String)
    case locked(String)
    case notConvertible(String)
    case noPlace

    var message: String {
        switch self {
        case .noTool(let tool): BatchStrings.cantRun(ToolCatalog.tile(tool).name, reason: nil)
        case .cantRun(let tool, let reason): BatchStrings.cantRun(ToolCatalog.tile(tool).name, reason: reason)
        case .unreadable(let name): Strings.Errors.damaged(name)
        case .locked(let name): BatchStrings.locked(name)
        case .notConvertible(let ext): Strings.Errors.notConvertible(ext)
        case .noPlace: BatchStrings.somethingWentWrong
        }
    }
}
