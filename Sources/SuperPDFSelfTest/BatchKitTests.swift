import AppKit
@testable import BatchKit
import PDFKit
import SuperPDFCore
@testable import ToolsKit

// BatchKit's checks (WP16): routines on disk, folders expanded, the "Do this to many files" panel driven headlessly
// (its menus, prompts and Finder replaced), and pipelines run through fake providers: results named and placed next to
// the originals or in a folder, in-place steps chained, failures reported per file. The real tools in a pipeline are
// AppTests' end-to-end cases.

func registerBatchKitTests() {
    SelfTest.cases.append(("BatchKit.routines", { batchRoutines() }))
    SelfTest.cases.append(("BatchKit.expand", { batchExpand() }))
    SelfTest.cases.append(("BatchKit.panel", { batchPanel() }))
    SelfTest.cases.append(("BatchKit.pipeline", { batchPipeline() }))
}

private func batchFolder(_ name: String) -> URL {
    SuperPDFPaths.ensure(scratch.appendingPathComponent("BatchKit-\(name)-\(UUID().uuidString)", isDirectory: true))
}

/// The panel's system parts, scripted.
@MainActor
private final class BatchScript {
    var tools: [ToolID] = []
    var routineName: String?
    var routine: Routine?
    var folder: URL?
    var revealed: [[URL]] = []
    var offered: [[ToolID]] = []

    var environment: BatchEnvironment {
        var environment = BatchEnvironment()
        environment.chooseTool = { [unowned self] tiles in offered.append(tiles.map(\.id)); return tools.isEmpty ? nil : tools.removeFirst() }
        environment.chooseRoutine = { [unowned self] _ in routine }
        environment.askRoutineName = { [unowned self] in routineName }
        environment.chooseFolder = { [unowned self] in folder }
        environment.reveal = { [unowned self] in revealed.append($0) }
        return environment
    }
}

@MainActor
private func installBatch(_ script: BatchScript) -> BatchTools {
    installFakes()
    Services.documents = FakeDocuments()
    BatchKitModule.install(environment: script.environment)
    return Services.toolProviders.compactMap { $0 as? BatchTools }.first!
}

@MainActor
private func batchRoutines() {
    let folder = batchFolder("routines")
    let runner = BatchRunner(folder: folder)
    check(runner.routines.isEmpty, "no routines at first")
    let archive = Routine(name: "Archive scans", pipeline: BatchPipeline(steps: [BatchStep(tool: .recogniseText), BatchStep(tool: .makeSmaller),
                                                                                  BatchStep(tool: .forArchiving, values: ToolValues(["level": .string("1b")]))]),
                          created: Date(timeIntervalSince1970: 1_000))
    let words = Routine(name: "Word copies", pipeline: BatchPipeline(steps: [BatchStep(tool: .toWord)], outputFolder: folder),
                        created: Date(timeIntervalSince1970: 2_000))
    do {
        try runner.save(words)
        try runner.save(archive)
    } catch { check(false, "saving routines: \(error)"); return }
    check(runner.routines.map(\.name) == ["Archive scans", "Word copies"], "oldest first")
    let again = BatchRunner(folder: folder)
    check(again.routines == runner.routines, "read back from Routines/*.json")
    check(again.routines.first?.pipeline.steps.last?.values.string("level") == "1b", "step values kept")
    var renamed = archive
    renamed.name = "Scans for the archive"
    try? again.save(renamed)
    check(again.routines.count == 2 && again.routines.first?.name == "Scans for the archive", "saving again replaces it")
    try? again.delete(words.id)
    check(BatchRunner(folder: folder).routines.map(\.id) == [archive.id], "deleted from disk")
}

@MainActor
private func batchExpand() {
    let folder = batchFolder("expand")
    let inside = SuperPDFPaths.ensure(folder.appendingPathComponent("Scans", isDirectory: true))
    let nested = SuperPDFPaths.ensure(inside.appendingPathComponent("2026", isDirectory: true))
    for url in [inside.appendingPathComponent("b.pdf"), inside.appendingPathComponent("a 10.pdf"), inside.appendingPathComponent("a 9.pdf"),
                nested.appendingPathComponent("c.docx"), inside.appendingPathComponent(".DS_Store")] {
        try? Data("x".utf8).write(to: url)
    }
    let loose = folder.appendingPathComponent("Loose.pdf")
    try? Data("x".utf8).write(to: loose)
    let files = BatchRunner.expand([inside, loose, inside.appendingPathComponent("b.pdf"), folder.appendingPathComponent("missing.pdf")])
    check(files.map(\.lastPathComponent) == ["c.docx", "a 9.pdf", "a 10.pdf", "b.pdf", "Loose.pdf"],
          "folders in name order (numbers as numbers), hidden files skipped, each file once: \(files.map(\.lastPathComponent))")
}

@MainActor
private func batchPanel() {
    let script = BatchScript()
    let tools = installBatch(script)
    check(Services.batch is BatchRunner && Set(tools.tools) == Set(ToolCatalog.tiles(ownedBy: .batchKit).map(\.id)), "installs Services.batch and its tile")
    check(BatchTools.runnable.allSatisfy { ToolCatalog.tile($0).needsDocument }, "pipelines run document tools")
    let folder = batchFolder("panel")
    for name in ["One.pdf", "Two.pdf", "Three.pdf"] { try? makePDF(pages: 1).write(to: folder.appendingPathComponent(name)) }

    // Opened with a folder (a drop on the tile): the folder shows in the list, three files to run on, no step yet.
    let session = ToolSession(tool: .manyFiles, provider: tools, document: nil, inputs: [folder])
    check(session.values.files(BatchTools.Key.files) == [folder], "the dropped folder is in the list")
    check(session.panel.archetype == .convert && !session.canRun && session.message?.text == "Add a tool to run.", "a step is needed")
    check(session.panel.primary.title == "Run on 3 files", "the button counts the files inside: \(session.panel.primary.title)")

    // Add a tool…: Make smaller, then To Word.
    script.tools = [.makeSmaller, .toWord]
    _ = complete { await session.perform(BatchTools.Action.add) }
    _ = complete { await session.perform(BatchTools.Action.add) }
    check(script.offered.first == BatchTools.runnable, "the menu offers the tools a pipeline can run")
    if case .checklist(_, let items, _)? = session.panel.controls.first {
        check(items.map(\.title) == ["1. Make smaller", "2. To Word"], "the steps in order: \(items.map(\.title))")
    } else { check(false, "the steps are listed") }
    check(session.canRun, "two steps, three files: ready")
    // To Word first can't work: something else would have to follow a Word file.
    script.tools = [.recogniseText]
    _ = complete { await session.perform(BatchTools.Action.add) }
    check(!session.canRun && session.message?.text == "“To Word” makes other kinds of files, so it has to be the last step.",
          "a Word file can't go on: \(session.message?.text ?? "-")")
    // Unticking the third step makes To Word last again.
    session.set(BatchTools.Key.steps, .strings(["0", "1"]))
    check(session.canRun && tools.activeSteps(session.values, inputs: session.inputs) == [.makeSmaller, .toWord], "unticked steps don't run")

    // Save as routine… and Use a routine….
    script.routineName = "Smaller Word copies"
    _ = complete { await session.perform(BatchTools.Action.saveRoutine) }
    let saved = Services.batch.routines.last
    check(saved?.name == "Smaller Word copies" && saved?.pipeline.steps.map(\.tool) == [.makeSmaller, .toWord], "saved the ticked steps")
    let fresh = ToolSession(tool: .manyFiles, provider: tools, document: nil, inputs: [folder])
    script.routine = saved
    _ = complete { await fresh.perform(BatchTools.Action.useRoutine) }
    check(tools.activeSteps(fresh.values, inputs: fresh.inputs) == [.makeSmaller, .toWord], "a routine fills the steps")
    check(fresh.panel.moreOptions.contains { $0.id == BatchTools.Action.useRoutine }, "routines are offered once there are some")

    // Results in a folder, and back next to the originals.
    let results = batchFolder("results")
    script.folder = results
    _ = complete { await fresh.perform(BatchTools.Action.chooseFolder) }
    check(tools.folder(fresh.values) == results && fresh.panel.controls.contains { if case .note(let text) = $0 { text.contains(results.lastPathComponent) } else { false } },
          "the results folder is said")
    _ = complete { await fresh.perform(BatchTools.Action.nextToOriginals) }
    check(tools.folder(fresh.values) == nil, "next to each file again")

    // A Quick Action for a document tool on several files opens the panel with that step.
    let pdfs = ["One.pdf", "Two.pdf"].map { folder.appendingPathComponent($0) }
    tools.open(steps: [.makeSmaller, .sign], files: pdfs)
    check((Services.tools as? FakeTools)?.openedPanels.last == .manyFiles, "the panel opens")
    let fromAction = ToolSession(tool: .manyFiles, provider: tools, document: nil, inputs: pdfs)
    check(tools.activeSteps(fromAction.values, inputs: fromAction.inputs) == [.makeSmaller] && fromAction.panel.primary.title == "Run on 2 files",
          "with its step (tools a pipeline can't run are left out)")
    installFakes()
}

/// A provider standing in for real tools: "make smaller" writes a new file with " small" appended to the text,
/// "recognise text" edits in place (new bytes), "to word" writes a .docx; a file named "Broken" fails.
@MainActor
private final class PipelineProvider: ToolProviding {
    let tools: [ToolID] = [.makeSmaller, .recogniseText, .toWord, .toImages]
    var runs: [(ToolID, URL?)] = []

    func panel(for tool: ToolID, context: ToolContext) -> ToolPanel {
        let output: OutputPolicy = switch tool {
        case .makeSmaller: .sibling(.smaller, ext: "pdf")
        case .toWord: .sameName(ext: "docx")
        case .toImages: .folder(.images)
        default: .inPlace
        }
        return ToolPanel(.presetAndMore, controls: [.toggle(id: "flag", label: "Flag", isOn: true)], primary: ToolButton("Run"), output: output)
    }

    func run(_ request: ToolRequest, progress: ToolProgress) async throws -> ToolResult {
        guard let document = request.document else { throw ToolError("no document") }
        runs.append((request.tool, document.url))
        progress.report(completed: 1, of: 1)
        if document.displayName == "Broken" { throw ToolError("This one is broken.") }
        let text = (document.pdf.string ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        func pdf(_ text: String) -> Data { batchPDF(text) }
        switch request.tool {
        case .makeSmaller:
            let out = request.workFolder.appendingPathComponent("out.pdf")
            try pdf(text + " small").write(to: out)
            return .newFile(out, banner: ResultBanner("Done"))
        case .recogniseText:
            return .inPlace(undoable: UndoGroup("Recognise Text", .contents(before: Data(), after: pdf(text + " ocr"))), banner: nil)
        case .toWord:
            let out = request.workFolder.appendingPathComponent("out.docx")
            try Data(text.utf8).write(to: out)
            return .newFile(out, banner: ResultBanner("Saved"))
        default:
            let out = request.workFolder.appendingPathComponent("page 1.png")
            try Data(text.utf8).write(to: out)
            return .newFiles([out], banner: ResultBanner("Saved"))
        }
    }
}

/// A one-page PDF saying `text`.
private func batchPDF(_ text: String) -> Data {
    let data = NSMutableData()
    var box = CGRect(x: 0, y: 0, width: 612, height: 792)
    guard let consumer = CGDataConsumer(data: data as CFMutableData), let context = CGContext(consumer: consumer, mediaBox: &box, nil) else { return Data() }
    context.beginPDFPage(nil)
    let line = CTLineCreateWithAttributedString(NSAttributedString(string: text, attributes: [.font: NSFont.systemFont(ofSize: 18)]))
    context.textPosition = CGPoint(x: 72, y: 700)
    CTLineDraw(line, context)
    context.endPDFPage()
    context.closePDF()
    return data as Data
}

@MainActor
private func batchPipeline() {
    let script = BatchScript()
    let tools = installBatch(script)
    let provider = PipelineProvider()
    let registry = FakeTools()
    Services.tools = registry
    registry.providers = Dictionary(uniqueKeysWithValues: provider.tools.map { ($0, provider as any ToolProviding) })
    let folder = batchFolder("pipeline")
    let report = folder.appendingPathComponent("Report.pdf"), broken = folder.appendingPathComponent("Broken.pdf")
    try? batchPDF("Report").write(to: report)
    try? batchPDF("Broken").write(to: broken)
    let reportBytes = try? Data(contentsOf: report)

    func run(_ pipeline: BatchPipeline, _ files: [URL]) -> [BatchEvent] {
        var events: [BatchEvent] = []
        _ = complete { for try await event in Services.batch.run(pipeline, on: files) { events.append(event) } }
        return events
    }
    func text(_ url: URL?) -> String { url.flatMap { PDFDocument(url: $0)?.string }?.trimmingCharacters(in: .whitespacesAndNewlines) ?? "" }

    // OCR in place, then make smaller: one file, named by the last tool that names one, next to the original.
    let events = run(BatchPipeline(steps: [BatchStep(tool: .recogniseText), BatchStep(tool: .makeSmaller)]), [report, broken])
    let outputs = events.compactMap { if case .finished(_, let made) = $0 { made } else { nil } }.flatMap { $0 }
    check(outputs.map(\.lastPathComponent) == ["Report (smaller).pdf"], "the result is named and placed: \(outputs.map(\.lastPathComponent))")
    check(text(outputs.first) == "Report ocr small", "each step worked on the one before: \(text(outputs.first))")
    check((try? Data(contentsOf: report)) == reportBytes, "the original is untouched")
    check(events.contains { if case .failed(let file, let message) = $0 { file == broken && message == "This one is broken." } else { false } },
          "a failing file is reported and the others go on")
    check(events.contains { if case .step(_, let tool, _) = $0 { tool == .makeSmaller } else { false } }, "progress per step")
    // The same again: " 2", never over the first result.
    let second = run(BatchPipeline(steps: [BatchStep(tool: .makeSmaller)]), [report])
    check(second.contains { if case .finished(_, let made) = $0 { made.first?.lastPathComponent == "Report (smaller) 2.pdf" } else { false } }, "a second run doesn't overwrite")

    // Every step in place: "(edited)"; into a folder; a Word file at the end; pictures into "<name> images".
    let results = batchFolder("pipeline-results")
    let edited = run(BatchPipeline(steps: [BatchStep(tool: .recogniseText)], outputFolder: results), [report])
    check(edited.contains { if case .finished(_, let made) = $0 { made == [results.appendingPathComponent("Report (edited).pdf")] } else { false } },
          "in-place steps give an edited copy, in the chosen folder")
    let word = run(BatchPipeline(steps: [BatchStep(tool: .recogniseText), BatchStep(tool: .toWord)]), [report])
    check(word.contains { if case .finished(_, let made) = $0 { made.first?.lastPathComponent == "Report.docx" } else { false } }, "a Word file at the end")
    let images = run(BatchPipeline(steps: [BatchStep(tool: .toImages)]), [report])
    check(images.contains { if case .finished(_, let made) = $0 { made.first?.deletingLastPathComponent().lastPathComponent == "Report images" } else { false } },
          "pictures go into a folder")

    // The panel runs the same, shows the results in Finder and says what failed.
    let session = ToolSession(tool: .manyFiles, provider: tools, document: nil, inputs: [report, broken])
    script.tools = [.makeSmaller]
    _ = complete { await session.perform(BatchTools.Action.add) }
    _ = complete { await session.run() }
    check(script.revealed.last?.first?.lastPathComponent == "Report (smaller) 3.pdf", "the results are shown in Finder: \(script.revealed)")
    check(session.message?.text == "Done 1 of 2 files. “Broken.pdf”: This one is broken.", "the failure is said: \(session.message?.text ?? "-")")
    installFakes()
}
