import AppKit
import SuperPDFCore
import UniformTypeIdentifiers

/// What the "Do this to many files" panel asks of the system, swappable in the self-test: no menu pops up, no panel or
/// alert opens and Finder is never asked to show anything there.
@MainActor
public struct BatchEnvironment {
    /// "Add a tool…": a menu of the tools a pipeline can run, by section, where the pointer is.
    public var chooseTool: @MainActor ([ToolTile]) async -> ToolID? = { tiles in
        await MenuChoice.pick(tiles.map { tile in (tile.menuTitle, tile.symbol, tile.section.title, tile.id) })
    }
    /// "Use a routine…": the saved routines.
    public var chooseRoutine: @MainActor ([Routine]) async -> Routine? = { routines in
        await MenuChoice.pick(routines.map { ($0.name, "square.stack.3d.up", nil, $0) })
    }
    /// "Save as routine…": a name, or nil when cancelled.
    public var askRoutineName: @MainActor () async -> String? = {
        let alert = NSAlert()
        alert.messageText = BatchStrings.routineNamePrompt
        alert.informativeText = BatchStrings.routineNameInfo
        let field = NSTextField(frame: NSRect(x: 0, y: 0, width: 240, height: 24))
        field.placeholderString = BatchStrings.routineNamePlaceholder
        alert.accessoryView = field
        alert.addButton(withTitle: BatchStrings.save)
        alert.addButton(withTitle: BatchStrings.cancel)
        alert.window.initialFirstResponder = field
        guard alert.runModal() == .alertFirstButtonReturn else { return nil }
        let name = field.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        return name.isEmpty ? nil : name
    }
    /// "Save results in a folder…".
    public var chooseFolder: @MainActor () async -> URL? = {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.canCreateDirectories = true
        return panel.runModal() == .OK ? panel.url : nil
    }
    /// Shows the results in Finder when the run is done.
    public var reveal: @MainActor ([URL]) -> Void = { NSWorkspace.shared.activateFileViewerSelecting($0) }

    public init() {}
}

/// The "Do this to many files" tile (features #75; ux §5.3, archetype E): the steps in order, each a tool added with
/// "Add a tool…" and ticked to run; the files or folders to run on; where the results go; routines to reuse.
@MainActor
final class BatchTools: ToolProviding {
    let runner: BatchRunning
    var environment = BatchEnvironment()
    let tools: [ToolID] = [.manyFiles]
    /// Steps a Quick Action or link asked for, by the files the panel was opened with.
    private var pending: [Set<URL>: [ToolID]] = [:]
    /// The number of files the last list expands to (folders included), so the button can say it on every change.
    private var counted: (files: [URL], count: Int) = ([], 0)

    init(runner: BatchRunning) { self.runner = runner }

    enum Key {
        static let pipeline = "pipeline", steps = "steps", files = "files", folder = "folder"
    }

    enum Action {
        static let add = "add", useRoutine = "use-routine", saveRoutine = "save-routine", chooseFolder = "choose-folder"
        static let nextToOriginals = "next-to-originals"
    }

    /// The tools a pipeline can run: file-level tools that work with their panel's defaults, in catalogue order.
    static let runnable: [ToolID] = [
        .numberPages, .resizePages, .booklet, .split,
        .toWord, .toExcel, .toPowerPoint, .toImages, .toTextOrWeb, .forArchiving,
        .watermark, .batesNumbering,
        .lockIn, .removeHiddenInfo,
        .makeSmaller, .recogniseText, .repair,
    ]

    /// Tools whose results aren't one PDF (Word files, pictures, parts): nothing can run after them.
    static let endsPipeline: Set<ToolID> = [.toWord, .toExcel, .toPowerPoint, .toImages, .toTextOrWeb, .split]

    /// Opens the panel with these steps and files (a Quick Action or link for a document tool on several files).
    func open(steps: [ToolID], files: [URL]) {
        pending[Set(files.map(\.standardizedFileURL))] = steps.filter(Self.runnable.contains)
        Services.tools?.openPanel(.manyFiles, for: nil, inputs: files)
    }

    // MARK: Values

    /// Every step added, in order (ticked or not).
    func pipeline(_ values: ToolValues, inputs: [URL]) -> [ToolID] {
        guard values[Key.pipeline] != nil else { return pending[Set(inputs.map(\.standardizedFileURL))] ?? [] }
        return values.strings(Key.pipeline).compactMap(ToolID.init(rawValue:))
    }

    /// The ticked steps, in order.
    func activeSteps(_ values: ToolValues, inputs: [URL]) -> [ToolID] {
        let all = pipeline(values, inputs: inputs)
        guard values[Key.steps] != nil else { return all }
        let ticked = Set(values.strings(Key.steps))
        return all.enumerated().filter { ticked.contains(String($0.offset)) }.map(\.element)
    }

    func folder(_ values: ToolValues) -> URL? { values.files(Key.folder).first }

    private func count(_ files: [URL]) -> Int {
        if counted.files != files { counted = (files, BatchRunner.expand(files).count) }
        return counted.count
    }

    /// The first step that has others after it although nothing can follow it.
    static func misplaced(_ steps: [ToolID]) -> ToolID? { steps.dropLast().first(where: endsPipeline.contains) }

    // MARK: Panel

    func panel(for tool: ToolID, context: ToolContext) -> ToolPanel {
        let all = pipeline(context.values, inputs: context.inputs)
        let active = activeSteps(context.values, inputs: context.inputs)
        let files = context.values.queue(Key.files, inputs: context.inputs)
        let fileCount = count(files)
        var controls: [ToolControl] = []
        if all.isEmpty {
            controls.append(.note(BatchStrings.stepsNote))
        } else {
            let rows = all.enumerated().map { ToolOption(String($0.offset), BatchStrings.step($0.offset + 1, ToolCatalog.tile($0.element).name),
                                                         symbol: ToolCatalog.tile($0.element).symbol) }
            controls.append(.checklist(id: Key.steps, items: rows, selected: rows.map(\.id)))
        }
        controls.append(.action(id: Action.add, title: BatchStrings.addTool, isDestructive: false, symbol: "plus"))
        controls.append(.files(id: Key.files, label: BatchStrings.filesLabel, types: [UTType.item.identifier, UTType.folder.identifier],
                               allowsMultiple: true))
        let folder = folder(context.values)
        controls.append(.note(folder.map { BatchStrings.resultsIn($0.lastPathComponent) } ?? BatchStrings.resultsNextToOriginals))

        var more: [ToolControl] = []
        if !runner.routines.isEmpty { more.append(.action(id: Action.useRoutine, title: BatchStrings.useRoutine, isDestructive: false)) }
        if !active.isEmpty { more.append(.action(id: Action.saveRoutine, title: BatchStrings.saveRoutine, isDestructive: false)) }
        more.append(folder == nil ? .action(id: Action.chooseFolder, title: BatchStrings.chooseFolder, isDestructive: false)
                                  : .action(id: Action.nextToOriginals, title: BatchStrings.nextToOriginals, isDestructive: false))

        var message: ToolMessage?
        if let misplaced = Self.misplaced(active) {
            message = ToolMessage(.error, BatchStrings.mustBeLast(ToolCatalog.tile(misplaced).name))
        } else if active.isEmpty {
            message = ToolMessage(.info, BatchStrings.needsSteps)
        } else if fileCount == 0 {
            message = ToolMessage(.info, BatchStrings.needsFiles)
        }
        let canRun = !active.isEmpty && fileCount > 0 && Self.misplaced(active) == nil
        return ToolPanel(.convert, controls: controls, moreOptions: more,
                         primary: ToolButton(fileCount > 0 ? BatchStrings.run(fileCount) : BatchStrings.run, isEnabled: canRun),
                         output: .inPlace, message: message)
    }

    // MARK: Actions

    func handle(action: String, context: ToolContext) async throws -> ToolValues {
        var values = context.values
        let all = pipeline(values, inputs: context.inputs)
        let active = activeSteps(values, inputs: context.inputs)
        switch action {
        case Action.add:
            guard let tool = await environment.chooseTool(Self.runnable.map(ToolCatalog.tile)) else { return values }
            let ticked = values[Key.steps] == nil ? all.indices.map(String.init) : values.strings(Key.steps)
            values[Key.pipeline] = .strings((all + [tool]).map(\.rawValue))
            values[Key.steps] = .strings(ticked + [String(all.count)])
        case Action.useRoutine:
            guard let routine = await environment.chooseRoutine(runner.routines) else { return values }
            let steps = routine.pipeline.steps.map(\.tool).filter(Self.runnable.contains)
            values[Key.pipeline] = .strings(steps.map(\.rawValue))
            values[Key.steps] = .strings(steps.indices.map(String.init))
            values[Key.folder] = routine.pipeline.outputFolder.map { .files([$0]) }
        case Action.saveRoutine:
            guard !active.isEmpty, let name = await environment.askRoutineName() else { return values }
            try runner.save(Routine(name: name, pipeline: BatchPipeline(steps: active.map { BatchStep(tool: $0) }, outputFolder: folder(values))))
        case Action.chooseFolder:
            guard let folder = await environment.chooseFolder() else { return values }
            values[Key.folder] = .files([folder])
        case Action.nextToOriginals:
            values[Key.folder] = nil
        default:
            break
        }
        return values
    }

    // MARK: Run

    func run(_ request: ToolRequest, progress: ToolProgress) async throws -> ToolResult {
        let steps = activeSteps(request.values, inputs: request.inputs)
        let files = BatchRunner.expand(request.values.queue(Key.files, inputs: request.inputs))
        guard !steps.isEmpty, !files.isEmpty, Self.misplaced(steps) == nil else { return .none }
        let pipeline = BatchPipeline(steps: steps.map { BatchStep(tool: $0) }, outputFolder: folder(request.values))
        var outputs: [URL] = [], failures: [(file: URL, reason: String)] = [], started = 0
        for try await event in runner.run(pipeline, on: files) {
            switch event {
            case .started(let file):
                started += 1
                progress.report(completed: started - 1, of: files.count,
                                label: BatchStrings.progress(file: file.lastPathComponent, tool: ToolCatalog.tile(steps[0]).name))
            case .step(let file, let tool, _):
                progress.report(completed: started - 1, of: files.count,
                                label: BatchStrings.progress(file: file.lastPathComponent, tool: ToolCatalog.tile(tool).name))
            case .finished(_, let made):
                outputs += made
            case .failed(let file, let reason):
                failures.append((file, reason))
            }
        }
        progress.report(completed: files.count, of: files.count)
        if !outputs.isEmpty { environment.reveal(outputs) }
        if let first = failures.first {
            throw ToolError(BatchStrings.someFailed(done: files.count - failures.count, total: files.count, first: first.file.lastPathComponent,
                                                    reason: first.reason))
        }
        return .none
    }
}

/// A pop-up menu of choices where the pointer is, grouped under section titles; the chosen value, or nil.
@MainActor
enum MenuChoice {
    static func pick<Value>(_ items: [(title: String, symbol: String?, section: String?, value: Value)]) async -> Value? {
        guard !items.isEmpty else { return nil }
        let menu = NSMenu()
        let target = Target()
        var section: String?
        for (index, item) in items.enumerated() {
            if let heading = item.section, heading != section {
                if section != nil { menu.addItem(.separator()) }
                section = heading
                menu.addItem(NSMenuItem.sectionHeader(title: heading))
            }
            let entry = NSMenuItem(title: item.title, action: #selector(Target.chose(_:)), keyEquivalent: "")
            entry.target = target
            entry.tag = index
            if let symbol = item.symbol { entry.image = NSImage(systemSymbolName: symbol, accessibilityDescription: nil) }
            menu.addItem(entry)
        }
        menu.popUp(positioning: nil, at: NSEvent.mouseLocation, in: nil)
        return target.chosen.map { items[$0].value }
    }

    private final class Target: NSObject {
        var chosen: Int?
        @objc func chose(_ sender: NSMenuItem) { chosen = sender.tag }
    }
}
