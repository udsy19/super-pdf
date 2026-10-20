import Foundation
import SuperPDFCore

/// One open tool panel, headless: the provider, its context and values, the panel it describes, the live preview, the
/// run with progress, and the message above the footer (ux §5.1). The panel view draws it; module self-tests drive a
/// provider with it exactly as the app does (set values, press buttons, run) without a window:
///
///     let session = ToolSession(tool: .split, provider: provider, document: makeDocument(pages: 8))
///     session.set("every", .int(2))
///     let result = await session.run()   // applied through Services.documents
@MainActor
public final class ToolSession: ObservableObject {
    public enum Phase: Equatable {
        case editing
        /// The run is working; the last progress update, if any.
        case running(ToolProgress.Update?)
        case finished
    }

    public let tile: ToolTile
    public var tool: ToolID { tile.id }
    public let provider: any ToolProviding
    public let document: DocumentHandle?
    public let availability: ToolAvailability

    @Published public private(set) var panel: ToolPanel
    @Published public private(set) var layout: PanelLayout
    @Published public private(set) var values: ToolValues
    @Published public private(set) var scope: Scope
    @Published public private(set) var selection: [Int]
    @Published public private(set) var currentPage: Int
    public let inputs: [URL]
    @Published public private(set) var preview: ToolPreview = .none
    /// A failure from an action or a run; cleared by the next change.
    @Published public private(set) var failure: ToolMessage?
    @Published public private(set) var phase: Phase = .editing
    /// Where the output goes when chosen with Change… or the "…" save panel.
    @Published public private(set) var chosenDestination: URL?
    @Published public var isMoreOptionsOpen: Bool {
        didSet { Defaults[Self.moreOptionsKey(tool)] = isMoreOptionsOpen }
    }

    /// Asks where to save (the "…" buttons and Change…), starting at the proposed URL; nil cancels. Unset (headless),
    /// the proposed URL is used.
    public var chooseDestination: (@MainActor (_ proposed: URL, _ policy: OutputPolicy, _ prompt: String) async -> URL?)?
    /// Shows a confirmation; false cancels the run. Unset (headless), the run goes ahead.
    public var confirm: (@MainActor (ToolConfirmation) async -> Bool)?
    /// Called after a run's result is applied (the host closes the panel).
    public var onFinish: (@MainActor (ToolResult) -> Void)?

    private var previewTask: Task<Void, Never>?
    private var runTask: Task<ToolResult, Error>?

    public init(tile: ToolTile, provider: any ToolProviding, document: DocumentHandle?, inputs: [URL] = [], selection: [Int] = [],
                currentPage: Int = 0) {
        self.tile = tile
        self.provider = provider
        self.document = document
        self.inputs = inputs
        self.selection = selection
        self.currentPage = currentPage
        availability = provider.availability(of: tile.id)
        let scope: Scope = selection.count > 1 ? .selected(selection) : .all
        self.scope = scope
        isMoreOptionsOpen = Defaults[Self.moreOptionsKey(tile.id)]
        var start = Defaults[Self.valuesKey(tile.id)]
        start[ToolPanel.stepValue] = .int(0)
        values = start
        let context = ToolContext(tool: tile.id, document: document, selection: selection, currentPage: currentPage, scope: scope,
                                  values: start, inputs: inputs)
        let panel = provider.panel(for: tile.id, context: context)
        self.panel = panel
        layout = PanelLayout(panel)
        settleValues()
    }

    /// Convenience for tests and callers holding only the id.
    public convenience init(tool: ToolID, provider: any ToolProviding, document: DocumentHandle?, inputs: [URL] = [],
                            selection: [Int] = [], currentPage: Int = 0) {
        self.init(tile: ToolCatalog.tile(tool), provider: provider, document: document, inputs: inputs, selection: selection,
                  currentPage: currentPage)
    }

    public var context: ToolContext {
        ToolContext(tool: tool, document: document, selection: selection, currentPage: currentPage, scope: scope, values: values,
                    inputs: inputs)
    }

    // MARK: - Values

    /// The value a control shows: the current one, else the control's own.
    public func value(of control: ToolControl) -> ToolValue? {
        control.id.flatMap { values[$0] } ?? control.initialValue
    }

    public func set(_ id: String, _ value: ToolValue) {
        guard values[id] != value else { return }
        values[id] = value
        changed()
    }

    public func setScope(_ scope: Scope) {
        guard self.scope != scope else { return }
        self.scope = scope
        changed()
    }

    /// The sidebar's selection or the page in view changed while the panel is open; picking several thumbnails switches
    /// the scope to them (ux §5.1).
    public func updateSelection(_ pages: [Int], currentPage page: Int) {
        guard pages != selection || page != currentPage else { return }
        selection = pages
        currentPage = page
        if pages.count > 1 { scope = .selected(pages) } else if case .selected = scope { scope = .all }
        changed()
    }

    /// Asks the provider for the panel again with the current context.
    public func refresh() {
        panel = provider.panel(for: tool, context: context)
        layout = PanelLayout(panel)
        settleValues()
    }

    private func changed() {
        failure = nil
        refresh()
        rememberChoices()
        schedulePreview()
    }

    /// Gives every control a value: its own when it has none or the remembered one no longer fits; asks again when that
    /// changed anything the provider described the panel from.
    private func settleValues() {
        for _ in 0..<2 {
            var changedAny = false
            for control in panel.controls + panel.moreOptions {
                guard let id = control.id, let initial = control.initialValue else { continue }
                if let current = values[id], Self.fits(current, control) { continue }
                values[id] = initial
                changedAny = true
            }
            guard changedAny else { return }
            panel = provider.panel(for: tool, context: context)
            layout = PanelLayout(panel)
        }
    }

    private static func fits(_ value: ToolValue, _ control: ToolControl) -> Bool {
        switch (control, value) {
        case (.segmented(_, _, let options, _), .string(let id)), (.radio(_, let options, _), .string(let id)),
             (.popup(_, _, let options, _), .string(let id)):
            options.contains { $0.id == id }
        case (.slider(_, _, let range, _, _, _), .double(let v)): range.contains(v)
        case (.slider(_, _, let range, _, _, _), .int(let v)): range.contains(Double(v))
        case (.stepper(_, _, let range, _), .int(let v)): range.contains(v)
        case (.toggle, .bool), (.text, .string), (.files, .files), (.checklist, .strings), (.chips, .strings): true
        case (.positionGrid(_, let columns, let rows, _), .int(let v)): (0..<(columns * rows)).contains(v)
        default: false
        }
    }

    /// Choices are remembered per tool; text, files, lists and the step never are (a password or a name to black out
    /// must not outlive the panel).
    private func rememberChoices() {
        var kept = ToolValues()
        for control in panel.controls + panel.moreOptions {
            switch control {
            case .segmented, .radio, .popup, .slider, .stepper, .toggle, .positionGrid:
                if let id = control.id, let value = values[id] { kept[id] = value }
            default: break
            }
        }
        Defaults[Self.valuesKey(tool)] = kept
    }

    static func valuesKey(_ tool: ToolID) -> Defaults.Key<ToolValues> { .init("toolsKit.values." + tool.rawValue, default: ToolValues()) }
    static func moreOptionsKey(_ tool: ToolID) -> Defaults.Key<Bool> { .init("toolsKit.moreOptions." + tool.rawValue, default: false) }

    // MARK: - Preview

    private func schedulePreview() {
        previewTask?.cancel()
        previewTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(SPMotion.previewDebounce * 1_000_000_000))
            guard !Task.isCancelled else { return }
            await self?.updatePreview()
        }
    }

    /// Asks for the live preview now, then the panel again (estimates a preview computed can show in it).
    public func updatePreview() async {
        let next = await provider.preview(for: tool, context: context)
        guard !Task.isCancelled else { return }
        preview = next
        refresh()
    }

    /// The summary lines of the current preview (drawn at the top of the panel).
    public var summary: [String] {
        if case .summary(let lines) = preview { return lines }
        return []
    }

    // MARK: - Messages and buttons

    /// What shows above the footer: a failure, else the panel's message, else why the tile can't run.
    public var message: ToolMessage? {
        if let failure { return failure }
        if let message = panel.message { return message }
        if case .unavailable(let sentence) = availability { return ToolMessage(.info, sentence) }
        return nil
    }

    public var isRunning: Bool { if case .running = phase { true } else { false } }

    /// The primary button can run: the provider says so, the tile can run, nothing is running.
    public var canRun: Bool {
        if case .unavailable = availability { return false }
        return panel.primary.isEnabled && !isRunning
    }

    /// Before the last step of a flow (G) the primary button goes to the next step.
    public var primaryAdvancesStep: Bool { !layout.steps.isEmpty && layout.currentStep < layout.steps.count - 1 }
    public var canGoBack: Bool { !layout.steps.isEmpty && layout.currentStep > 0 }

    public func next() { set(ToolPanel.stepValue, .int(layout.currentStep + 1)) }
    public func back() { set(ToolPanel.stepValue, .int(max(layout.currentStep - 1, 0))) }

    /// The secondary button is Cancel unless the provider names another action ("Remove watermark").
    public var secondaryIsCancel: Bool { panel.secondary.map { $0.title == Strings.Panel.cancel } ?? true }

    /// An `.action` button, a message's action or the secondary button: the provider answers with the values to go on with.
    public func perform(_ action: String) async {
        failure = nil
        do {
            values = try await provider.handle(action: action, context: context)
            refresh()
            rememberChoices()
            schedulePreview()
        } catch {
            failure = Self.message(for: error)
        }
    }

    /// The primary button: the next step of a flow, else the run.
    @discardableResult
    public func primary() async -> ToolResult? {
        if primaryAdvancesStep { next(); return nil }
        return await run()
    }

    // MARK: - Output

    /// Where the output goes: the chosen place, else DocumentKit's name next to the original (ux §7.2).
    public var destination: URL? {
        if let chosenDestination { return chosenDestination }
        switch panel.output {
        case .inPlace, .newDocument: return nil
        default: return Services.documents?.destination(for: panel.output, of: document, source: document?.url ?? inputs.first)
        }
    }

    /// "Saves “Report (smaller).pdf” next to the original" (with Change…), or for Black out and Sign
    /// "Saves “Lease agreement (signed).pdf” · the original is untouched"; nil for in-place edits and new unsaved documents.
    public var outputLine: (text: String, fileName: String, offersChange: Bool)? {
        guard let destination else { return nil }
        let name = destination.lastPathComponent
        if case .sibling(let suffix, _) = panel.output, suffix.keepsOriginalUntouched {
            return (Strings.Panel.savesOriginalUntouched(name), name, false)
        }
        return (Strings.Panel.savesNextToOriginal(name), name, true)
    }

    /// Change…: asks for another place.
    public func changeDestination() async {
        guard let proposed = destination, let chooseDestination else { return }
        if let chosen = await chooseDestination(proposed, panel.output, ToolsKitStrings.savePrompt(panel.primary.title)) {
            chosenDestination = chosen
        }
    }

    // MARK: - Run

    /// Runs the tool on the current values and hands the result to DocumentKit; nil when cancelled, stopped or failed
    /// (the failure shows above the footer).
    @discardableResult
    public func run() async -> ToolResult? {
        guard canRun else { return nil }
        failure = nil
        var target = destination
        if panel.primary.title.hasSuffix("…"), chosenDestination == nil, let proposed = target, let chooseDestination {
            guard let chosen = await chooseDestination(proposed, panel.output, ToolsKitStrings.savePrompt(panel.primary.title)) else { return nil }
            target = chosen
        }
        if let confirmation = panel.confirmation, let confirm, !(await confirm(confirmation)) { return nil }

        let work = SuperPDFPaths.ensure(SuperPDFPaths.work.appendingPathComponent(UUID().uuidString, isDirectory: true))
        defer { try? FileManager.default.removeItem(at: work) }
        let pages = document.map { scope.pages(count: $0.pageCount, current: currentPage) } ?? []
        let request = ToolRequest(tool: tool, document: document, source: document?.snapshot(), pages: pages, values: values,
                                  inputs: inputs, destination: target, workFolder: work)
        phase = .running(nil)
        let progress = ToolProgress { [weak self] update in
            Task { @MainActor in
                guard let self, case .running = self.phase else { return }
                self.phase = .running(update)
            }
        }
        let provider = self.provider
        let task = Task { @MainActor in try await provider.run(request, progress: progress) }
        runTask = task
        do {
            let result = try await task.value
            try Task.checkCancellation()
            try await Services.documents.apply(result, of: request)
            Services.tools?.recordUse(tool)
            phase = .finished
            onFinish?(result)
            return result
        } catch is CancellationError {
            phase = .editing
        } catch {
            phase = .editing
            failure = Self.message(for: error)
        }
        runTask = nil
        return nil
    }

    /// Stop: cancels the run (ux §5.1 "Page 14 of 120 · Stop").
    public func stop() { runTask?.cancel() }

    /// "Page 14 of 120" or the provider's label while running.
    public var progressLabel: String? {
        guard case .running(let update?) = phase else { return nil }
        return update.label ?? Strings.Panel.progress(page: min(update.completed + 1, update.total), of: update.total)
    }

    static func message(for error: Error) -> ToolMessage {
        if let error = error as? ToolError { return error.message }
        return ToolMessage(.error, ToolsKitStrings.somethingWentWrong, details: String(describing: error))
    }

    deinit {
        previewTask?.cancel()
        runTask?.cancel()
    }
}
