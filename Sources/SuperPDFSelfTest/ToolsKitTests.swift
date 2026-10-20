import AppKit
import PDFKit
import BatchKit
import ConvertKit
import EditKit
import FixKit
import FormsKit
import MarkupKit
import PagesKit
import ProtectKit
import ScanKit
import SignKit
import SuperPDFCore
@testable import ToolsKit
import ViewerKit

// ToolsKit (WP5): search and synonym ranking, frecency, provider coverage, the panel layout and session model, and
// offscreen renders of the Tools sheet, the panel archetypes and the result banner against the mockups' metrics.
func registerToolsKitTests() {
    SelfTest.cases.append(("ToolsKit.searchRanking", { toolsSearchRanking() }))
    SelfTest.cases.append(("ToolsKit.frecency", { toolsFrecency() }))
    SelfTest.cases.append(("ToolsKit.coverage", { toolsCoverage() }))
    SelfTest.cases.append(("ToolsKit.panelLayout", { toolsPanelLayout() }))
    SelfTest.cases.append(("ToolsKit.session", { toolsSession() }))
    SelfTest.cases.append(("ToolsKit.sheetModel", { toolsSheetModel() }))
    SelfTest.cases.append(("ToolsKit.sheetRender", { toolsSheetRender() }))
    SelfTest.cases.append(("ToolsKit.panelRenders", { toolsPanelRenders() }))
    SelfTest.cases.append(("ToolsKit.bannerRender", { toolsBannerRender() }))
    SelfTest.cases.append(("ToolsKit.registry", { toolsRegistry() }))
    SelfTest.cases.append(("ToolsKit.overlay", { toolsOverlay() }))
    SelfTest.cases.append(("ToolsKit.speed", { toolsSpeed() }))
}

// MARK: - Search (ux §4)

@MainActor
private func toolsSearchRanking() {
    func first(_ query: String) -> ToolID? { ToolSearch.rank(query).first?.id }
    func ids(_ query: String) -> [ToolID] { ToolSearch.rank(query).map(\.id) }

    // ux §4's examples.
    for query in ["compress", "optimize", "reduce", "shrink", "smaller", "Make smaller", "COMPRESS", "reduce file size"] {
        check(first(query) == .makeSmaller, "“\(query)” → Make smaller first (got \(first(query)?.rawValue ?? "nothing"))")
    }
    check(first("ocr") == .recogniseText, "“ocr” → Recognise text")
    check(first("OCR") == .recogniseText, "“OCR” → Recognise text")
    check(first("redact") == .blackOut, "“redact” → Black out")
    check(first("black out") == .blackOut, "“black out” → Black out")
    check(first("merge") == .combineFiles, "“merge” → Combine files")
    check(first("sign") == .sign, "“sign” → Sign")
    check(first("word") == .toWord, "“word” → To Word")
    check(first("docx") == .toWord && ids("docx").contains(.anyFileToPDF), "“docx” → To Word, and Any file → PDF")
    check(first("pdf to word") == .toWord, "“pdf to word” → To Word")
    check(first("word to pdf") == .anyFileToPDF, "“word to pdf” → Any file → PDF")
    check(first("images to pdf") == .imagesToPDF, "“images to pdf” → Images → PDF (the arrow reads as “to”)")
    check(first("pdf/a") == .forArchiving && first("pdfa") == .forArchiving, "“pdf/a”, “pdfa” → For archiving")
    check(first("encrypt") == .addPassword && first("decrypt") == .removePassword, "encrypt / decrypt")
    check(first("flatten") == .lockIn, "“flatten” → Lock in notes & fields")
    check(first("rotate") == .rotatePages, "“rotate” → Rotate pages")
    check(first("headers") == .headersAndFooters, "“headers” → Headers & footers")
    check(first("headers & footers") == .headersAndFooters && first("headers and footers") == .headersAndFooters, "“&” reads as “and”")
    check(first("organize") == .rearrangePages && first("organise") == .rearrangePages, "both spellings of organise")
    // Typos and other spellings.
    check(first("recognize text") == .recogniseText, "“recognize text” (US spelling) → Recognise text")
    check(first("watermrk") == .watermark, "“watermrk” (typo) → Watermark")
    check(first("compres") == .makeSmaller, "“compres” (half typed) → Make smaller")
    // Accents and curly quotes fold.
    check(first("Rémove password") == .removePassword, "accents fold")
    // Empty and nonsense.
    check(ToolSearch.rank("").count == ToolCatalog.tiles.count && ToolSearch.rank("  ").map(\.id) == ToolCatalog.tiles.map(\.id),
          "an empty query lists every tile in catalogue order")
    check(ToolSearch.rank("zzzqqq").isEmpty, "nonsense finds nothing")
    check(ToolSearch.rank("pdf").count > 0, "“pdf” still finds tiles")
    // Ties prefer frecency.
    let pages = ToolSearch.rank("pages")
    let boosted = ToolSearch.rank("pages", boost: { $0 == pages.last!.id ? 1 : 0 })
    check(pages.count > 1, "“pages” finds several tiles")
    check(ToolSearch.normalize("Images → PDF") == "images to pdf" && ToolSearch.normalize("Don’t  “Word”") == "dont word",
          "normalisation")
    _ = boosted
    // Speed: a keystroke is far below a frame.
    let start = Date()
    for query in ["s", "sm", "sma", "smal", "small", "smalle", "smaller"] { for _ in 0..<20 { _ = ToolSearch.rank(query) } }
    let perQuery = Date().timeIntervalSince(start) / 140
    check(perQuery < 0.004, "search takes \(Int(perQuery * 1_000_000)) µs per keystroke (< 4 ms)")
}

// MARK: - Frecency

@MainActor
private func toolsFrecency() {
    let now = Date(timeIntervalSince1970: 2_000_000_000)
    let day: TimeInterval = 86_400
    var f = Frecency()
    check(f.top(5, now: now).isEmpty, "empty on first launch")
    for _ in 0..<3 { f.record(.sign, at: now - 20 * day) }          // 3 × 50
    f.record(.makeSmaller, at: now - 1 * day)                         // 100
    f.record(.makeSmaller, at: now - 2 * day)                         // 100
    f.record(.toWord, at: now - 200 * day)                            // 10
    f.record(.blackOut, at: now - 1 * day)                            // 100
    check(f.score(.makeSmaller, now: now) == 200 && f.score(.sign, now: now) == 150 && f.score(.toWord, now: now) == 10,
          "weights by age")
    check(f.top(5, now: now) == [.makeSmaller, .sign, .blackOut, .toWord], "ordered by score, then recency: \(f.top(5, now: now))")
    for n in 0..<15 { f.record(.crop, at: now - Double(n) * 3600) }
    check(f.uses[ToolID.crop.rawValue]?.count == Frecency.usesKept, "keeps the last ten uses")
    check(f.top(2, now: now) == [.crop, .makeSmaller], "top(n) caps")
    check(roundTrips(f), "frecency is Codable")
}

// MARK: - Coverage (ARCHITECTURE "Launch sequence")

@MainActor
private func toolsCoverage() {
    let all = ModuleID.allCases.compactMap { module -> FakeToolProvider? in
        let tools = ToolCatalog.tiles(ownedBy: module).map(\.id)
        return tools.isEmpty ? nil : FakeToolProvider(tools)
    }
    check(ToolCoverage.issues(all, requireAll: true).isEmpty, "one provider per module covers every tile")
    check(ToolCoverage.map(all).count == ToolCatalog.tiles.count, "the map serves every tile")

    var missing = all
    missing.removeFirst()
    let lost = ToolCatalog.tiles(ownedBy: ToolCatalog.tile(all[0].tools[0]).owner).map(\.id)
    check(Set(ToolCoverage.issues(missing, requireAll: true)) == Set(lost.map { .missing($0) }), "a missing module is reported per tile")
    check(ToolCoverage.issues(missing, requireAll: false).isEmpty, "while modules are placeholders, absent ones are fine")

    let duplicate = all + [FakeToolProvider([.split])]
    check(ToolCoverage.issues(duplicate, requireAll: true) == [.duplicate(.split)], "a duplicate is reported")
    let partial = [FakeToolProvider([.split, .crop])]
    if case .incomplete(.pagesKit, let left)? = ToolCoverage.issues(partial, requireAll: false).first {
        check(Set(left) == Set(ToolCatalog.tiles(ownedBy: .pagesKit).map(\.id)).subtracting([.split, .crop]), "the rest of PagesKit")
    } else {
        check(false, "a module that covers only part of its tiles is reported")
    }
    check(ToolCoverage.issues([FakeToolProvider([.split, .toWord])], requireAll: false).contains(.mixedOwners([.convertKit, .pagesKit])),
          "a provider spanning modules is reported")

    // The real modules, installed as at launch: every one that registers tools covers all of its tiles exactly once;
    // strict (every tile served) once no module is a placeholder any more.
    installFakes()
    PagesKitModule.install(); ConvertKitModule.install(); EditKitModule.install(); MarkupKitModule.install()
    FormsKitModule.install(); SignKitModule.install(); ProtectKitModule.install(); FixKitModule.install()
    ScanKitModule.install(); BatchKitModule.install(); ViewerKitModule.install()
    let registered = Services.toolProviders
    let strict = Set(registered.flatMap(\.tools)).count == ToolCatalog.tiles.count
    let issues = ToolCoverage.issues(registered, requireAll: strict)
    check(issues.isEmpty, "registered providers: \(issues)")
    installFakes()
}

// MARK: - Panel layout (ux §5.1–§5.2)

@MainActor
private func toolsPanelLayout() {
    func kinds(_ layout: PanelLayout) -> [String] {
        layout.body.map { item in
            switch item {
            case .scope: "scope"
            case .moreOptions: "more"
            case .control(let control): control.id ?? "note"
            }
        }
    }

    // Watermark: the scope after the last choice, a note after the disclosure.
    let watermark = ToolPanel(.livePreview, showsScope: true, controls: [
        .segmented(id: "kind", options: [ToolOption("text", "Text"), ToolOption("picture", "Picture")], selected: "text"),
        .text(id: "text", label: nil, placeholder: "", value: "DRAFT", isSecure: false),
        .slider(id: "lightness", label: "Lightness", range: 0...100, step: 1, value: 30, format: .percent),
        .popup(id: "angle", label: "Angle", options: [ToolOption("diagonal", "Diagonal")], selected: "diagonal"),
        .moreOptions,
        .note("Drag the word on the page to move it."),
    ], moreOptions: [.toggle(id: "print", label: "Only when printing", isOn: false)], primary: ToolButton("Add watermark"))
    let wl = PanelLayout(watermark)
    check(kinds(wl) == ["kind", "text", "lightness", "angle", "scope", "more", "note"], "watermark order: \(kinds(wl))")
    check(wl.headerSwitch == nil, "a C panel keeps its segmented control in the body")

    // To Word: the scope where the provider put it.
    let toWord = ToolPanel(.convert, showsScope: true, controls: [
        .segmented(id: "format", label: "Format", options: [ToolOption("docx", "Word (.docx)")], selected: "docx"),
        .note("“Keep the look” places text…"), .scope, .list([ToolOption("text", "Text and headings", value: "12 pages")]),
    ], primary: ToolButton("Save as Word…"), output: .sameName(ext: "docx"))
    check(kinds(PanelLayout(toWord)) == ["format", "note", "scope", "note"], "to word order: \(kinds(PanelLayout(toWord)))")

    // No scope marker and no choice: the scope goes first; no More options when there are none.
    let plain = PanelLayout(ToolPanel(.oneChoice, showsScope: true, controls: [.note("x")], primary: ToolButton("Go")))
    check(kinds(plain) == ["scope", "note"], "scope first without choices")
    check(kinds(PanelLayout(ToolPanel(.oneChoice, controls: [.scope, .moreOptions], primary: ToolButton("Go")))).isEmpty,
          "markers without scope or options draw nothing")

    // Black out (D): the leading switch moves to the header.
    let blackOut = PanelLayout(ToolPanel(.mode, controls: [
        .segmented(id: "mode", options: [ToolOption("hand", "Mark by hand"), ToolOption("find", "Find and mark")], selected: "find"),
        .text(id: "find", label: nil, placeholder: "", value: "", isSecure: false),
        .toggle(id: "hidden", label: "Also remove hidden information", isOn: true),
    ], primary: ToolButton("Black out 7 items", isDestructive: true)))
    check(blackOut.headerSwitch?.id == "mode" && kinds(blackOut) == ["find", "hidden"], "D: header switch")

    // Three choices at most: the fourth and fifth go to the top of More options.
    let crowded = PanelLayout(ToolPanel(.oneChoice, controls: (1...5).map { .toggle(id: "t\($0)", label: "T\($0)", isOn: false) }
        + [.note("n")], moreOptions: [.toggle(id: "m", label: "M", isOn: false)], primary: ToolButton("Go")))
    check(crowded.visibleChoices == 3 && kinds(crowded) == ["t1", "t2", "t3", "note", "more"], "three visible choices")
    check(crowded.moreOptions.map { $0.id ?? "" } == ["t4", "t5", "m"], "overflow first in More options")

    // G: steps come out of the panel, clamped.
    let flow = PanelLayout(ToolPanel(.flow, steps: ["1 Who", "2 Where", "3 Send"], currentStep: 7, primary: ToolButton("Next: Send")))
    check(flow.steps.count == 3 && flow.currentStep == 2, "G steps, clamped")
}

// MARK: - Session (the host flow, headless)

/// A provider with a scope, a choice that changes the panel, an action, a preview, a confirmation and a failing mode.
@MainActor
private final class SessionProvider: ToolProviding {
    let tools: [ToolID] = [.makeSmaller]
    var panels = 0
    var previews = 0
    var runs: [ToolRequest] = []
    var fail: Error?
    var estimate = "≈ 2.8 MB"

    func panel(for tool: ToolID, context: ToolContext) -> ToolPanel {
        panels += 1
        let preset = context.values.string("preset", default: "good")
        return ToolPanel(.presetAndMore, hint: "Shrinks the file so it’s easier to send. The pages stay the same.", showsScope: true,
                         controls: [
                            .radio(id: "preset", options: [
                                ToolOption("good", "Good (recommended)", detail: "Pictures stay sharp", value: estimate),
                                ToolOption("email", "Email", detail: "Smallest", value: "≈ 1.7 MB"),
                            ], selected: "good"),
                            .text(id: "secret", label: nil, placeholder: "", value: "", isSecure: true),
                         ] + (preset == "email" ? [.toggle(id: "strip", label: "Remove comments", isOn: true)] : []),
                         moreOptions: [.slider(id: "quality", label: "Quality", range: 0...100, step: 1, value: 70, format: .percent)],
                         primary: ToolButton("Make smaller"), output: .sibling(.smaller, ext: "pdf"),
                         confirmation: preset == "email" ? ToolConfirmation(message: "Sure?", confirm: ToolButton("Go")) : nil)
    }

    func preview(for tool: ToolID, context: ToolContext) async -> ToolPreview {
        previews += 1
        estimate = "≈ 2.5 MB"
        return .summary(["Now: 6.1 MB · 12 pages"])
    }

    func handle(action: String, context: ToolContext) async throws -> ToolValues {
        if action == "boom" { throw ToolError("This file is already as small as it gets.") }
        var values = context.values
        values["preset"] = .string("email")
        return values
    }

    func run(_ request: ToolRequest, progress: ToolProgress) async throws -> ToolResult {
        runs.append(request)
        progress.report(completed: 1, of: 2)
        if let fail { throw fail }
        let out = request.workFolder.appendingPathComponent("out.pdf")
        try makePDF(pages: 1).write(to: out)
        return .newFile(out, banner: Strings.Banner.madeSmaller(before: 6_100_000, after: 1_700_000))
    }
}

@MainActor
private func toolsSession() {
    installFakes()
    let folder = scratch.appendingPathComponent("session", isDirectory: true)
    SuperPDFPaths.ensure(folder)
    let url = folder.appendingPathComponent("Report.pdf")
    try? makePDF(pages: 6).write(to: url)
    let document = makeDocument(pages: 6, url: url)
    let provider = SessionProvider()
    let session = ToolSession(tool: .makeSmaller, provider: provider, document: document, selection: [1, 3], currentPage: 1)

    check(session.scope == .selected([1, 3]), "several selected thumbnails make the scope “Selected”")
    check(session.values.string("preset") == "good" && session.values.double("quality") == 70, "values start from the panel")
    check(session.panel.hint?.hasPrefix("Shrinks") == true, "the panel's own hint")
    check(session.outputLine?.text == "Saves “Report (smaller).pdf” next to the original", "output line: \(session.outputLine?.text ?? "nil")")
    check(session.outputLine?.offersChange == true, "a plain copy offers Change…")

    // A choice changes the panel at once.
    session.set("preset", .string("email"))
    check(session.panel.controls.contains { $0.id == "strip" } && session.values.bool("strip") == true, "a new control gets its value")
    session.set("secret", .string("hunter2"))
    session.set("preset", .string("good"))

    // Remembered: choices yes, secure text no.
    let again = ToolSession(tool: .makeSmaller, provider: provider, document: document)
    check(again.values.string("preset") == "good" && again.values.string("secret") == "", "choices are remembered, text never")
    check(again.scope == .all, "one or no selected page: All")

    // Preview: summary lines, and the panel asked again so the estimate shows.
    _ = complete { await session.updatePreview() }
    check(session.summary == ["Now: 6.1 MB · 12 pages"], "summary lines")
    if case .radio(_, let options, _) = session.panel.controls[0] { check(options[0].value == "≈ 2.5 MB", "estimate after preview") }

    // Debounced preview after a change.
    let before = provider.previews
    session.set("quality", .double(40))
    session.set("quality", .double(41))
    RunLoop.main.run(until: Date().addingTimeInterval(0.3))
    check(provider.previews == before + 1, "one preview per pause (\(provider.previews - before))")

    // Actions: values come back; failures show above the footer and clear on the next change.
    _ = complete { await session.perform("boom") }
    check(session.message?.text == "This file is already as small as it gets." && session.message?.kind == .error, "action failure")
    session.set("quality", .double(50))
    check(session.failure == nil, "a change clears the failure")
    _ = complete { await session.perform("email") }
    check(session.values.string("preset") == "email", "an action's values replace the panel's")

    // Confirmation declined: nothing runs.
    session.confirm = { _ in false }
    _ = complete { await session.run() }
    check(provider.runs.isEmpty, "a declined confirmation runs nothing")
    session.confirm = { _ in true }

    // Run: request built from the scope and the destination; result applied, use recorded, finish called.
    var finished = false
    session.onFinish = { _ in finished = true }
    let result = complete { await session.run() }
    let request = provider.runs.last
    check(request?.pages == [1, 3] && request?.destination?.lastPathComponent == "Report (smaller).pdf"
          && request?.source == .file(url, password: nil), "request: pages, destination, source")
    check((Services.documents as? FakeDocuments)?.applied.last?.0 == .makeSmaller, "result applied through DocumentKit")
    check((Services.tools as? FakeTools)?.uses == [.makeSmaller], "use recorded")
    check(finished && session.phase == .finished, "finished")
    if case .success(let r?)? = result, case .newFile = r {} else { check(false, "run returns the result") }
    check(request.map { !FileManager.default.fileExists(atPath: $0.workFolder.path) } == true, "the work folder is cleaned up")

    // Failures: a ToolError's copy, anything else the plain sentence with the details behind Show details.
    let failing = ToolSession(tool: .makeSmaller, provider: provider, document: document)
    provider.fail = ToolError("“Report.pdf” couldn’t be opened.")
    _ = complete { await failing.run() }
    check(failing.message?.text == "“Report.pdf” couldn’t be opened." && failing.phase == .editing, "ToolError copy")
    provider.fail = FakeError(message: "code 42")
    _ = complete { await failing.run() }
    check(failing.message?.text == "Something went wrong. Nothing was changed." && failing.message?.details?.contains("42") == true,
          "other errors: plain words, code behind details")
    provider.fail = nil

    // A save-panel title asks where to save; cancelling runs nothing.
    let saveAs = ToolSession(tool: .makeSmaller, provider: SaveAsProvider(), document: document)
    var asked: (URL, String)?
    saveAs.chooseDestination = { proposed, _, prompt in asked = (proposed, prompt); return nil }
    _ = complete { await saveAs.run() }
    check(asked?.0.lastPathComponent == "Report.docx" && asked?.1 == "Save as Word", "“…” asks where, from the proposed name")
    check((saveAs.provider as? SaveAsProvider)?.ran == false, "cancelled save panel runs nothing")

    // Flow steps: Next / Back through the reserved value.
    let flow = ToolSession(tool: .requestSignatures, provider: FlowProvider(), document: document)
    check(flow.primaryAdvancesStep && !flow.canGoBack, "step 1: Next")
    _ = complete { await flow.primary() }
    _ = complete { await flow.primary() }
    check(flow.layout.currentStep == 2 && !flow.primaryAdvancesStep && flow.canGoBack, "step 3: run, Back")
    flow.back()
    check(flow.layout.currentStep == 1, "Back")

    // Unavailable tiles explain and can't run.
    let unavailable = ToolSession(tool: .makeSmaller, provider: UnavailableProvider(), document: document)
    check(unavailable.message?.text == "Needs something." && !unavailable.canRun, "unavailable: sentence, no run")
    // Selection changes while open.
    session.updateSelection([0, 2, 4], currentPage: 0)
    check(session.scope == .selected([0, 2, 4]), "selecting thumbnails switches the scope")
}

@MainActor
private final class SaveAsProvider: ToolProviding {
    let tools: [ToolID] = [.toWord]
    var ran = false
    func panel(for tool: ToolID, context: ToolContext) -> ToolPanel {
        ToolPanel(.convert, primary: ToolButton("Save as Word…"), output: .sameName(ext: "docx"))
    }
    func run(_ request: ToolRequest, progress: ToolProgress) async throws -> ToolResult { ran = true; return .none }
}

@MainActor
private final class FlowProvider: ToolProviding {
    let tools: [ToolID] = [.requestSignatures]
    func panel(for tool: ToolID, context: ToolContext) -> ToolPanel {
        ToolPanel(.flow, steps: ["1 Who", "2 Where", "3 Send"], currentStep: context.values.int(ToolPanel.stepValue),
                  primary: ToolButton("Next"))
    }
    func run(_ request: ToolRequest, progress: ToolProgress) async throws -> ToolResult { .none }
}

@MainActor
private final class UnavailableProvider: ToolProviding {
    let tools: [ToolID] = [.makeSmaller]
    func availability(of tool: ToolID) -> ToolAvailability { .unavailable("Needs something.") }
    func panel(for tool: ToolID, context: ToolContext) -> ToolPanel { ToolPanel(.oneChoice, primary: ToolButton("Go")) }
    func run(_ request: ToolRequest, progress: ToolProgress) async throws -> ToolResult { .none }
}

// MARK: - Offscreen renders

/// A borderless window that says it is key, so controls draw active.
private final class RenderWindow: NSWindow {
    override var isKeyWindow: Bool { true }
    override var isMainWindow: Bool { true }
}

/// Renders a view at 2× like the mockups (which are 2× PNGs of CSS pixels = points).
@MainActor
private func render(_ view: NSView, size: NSSize, dark: Bool = false) -> NSBitmapImageRep {
    let window = RenderWindow(contentRect: NSRect(origin: .zero, size: size), styleMask: [.borderless], backing: .buffered, defer: false)
    window.appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
    window.contentView = view
    view.frame = NSRect(origin: .zero, size: size)
    view.layoutSubtreeIfNeeded()
    RunLoop.main.run(until: Date().addingTimeInterval(0.05))
    view.layoutSubtreeIfNeeded()
    view.displayIfNeeded()
    let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: Int(size.width * 2), pixelsHigh: Int(size.height * 2), bitsPerSample: 8,
                               samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
    rep.size = size
    window.appearance.map { appearance in appearance.performAsCurrentDrawingAppearance { view.cacheDisplay(in: view.bounds, to: rep) } }
    return rep
}

/// Writes a render where `SUPERPDF_RENDERS` points (for review next to the mockups); returns the path.
@discardableResult
private func save(_ rep: NSBitmapImageRep, _ name: String) -> String? {
    guard let folder = ProcessInfo.processInfo.environment["SUPERPDF_RENDERS"] else { return nil }
    let url = URL(fileURLWithPath: folder).appendingPathComponent(name + ".png")
    try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
    try? rep.representation(using: .png, properties: [:])?.write(to: url)
    return url.path
}

// MARK: - Tools sheet

@MainActor
private func toolsSheetModel() {
    Defaults.reset(.showRecentlyUsed)
    var recents: [ToolTile] = []
    let model = ToolsSheetModel(recents: { recents })
    check(model.groups.map(\.section) == ToolSection.allCases.map(Optional.some), "first launch: no Recently used row")
    recents = [.makeSmaller, .sign].map(ToolCatalog.tile)
    model.reload()
    check(model.groups.first?.section == nil && model.groups.first?.tiles.map(\.id) == [.makeSmaller, .sign], "Recently used first")
    Defaults[.showRecentlyUsed] = false
    model.reload()
    check(model.groups.first?.section == .pages, "the setting hides Recently used")
    Defaults.reset(.showRecentlyUsed)

    model.search("compress")
    check(model.groups.count == 1 && model.groups[0].section == .fixAndCheck && model.returnTarget?.id == .makeSmaller,
          "search filters sections; Return opens the best match")
    model.search("word")
    check(model.returnTarget?.id == .toWord && model.groups.allSatisfy { $0.section != nil }, "no Recently used while searching")
    model.search("zzzz")
    check(model.isEmpty && model.returnTarget == nil, "nothing found")
    model.search("")
    check(model.selection == nil, "no keyboard tile until an arrow")

    // Arrows over five columns: Recently used (2) then Pages (11).
    model.move(.down, columns: 5)
    check(model.selection == .init(group: 0, index: 0), "first arrow picks the first tile")
    model.move(.right, columns: 5); model.move(.right, columns: 5)
    check(model.selection == .init(group: 1, index: 0), "right wraps into the next section")
    model.move(.down, columns: 5); model.move(.right, columns: 5)
    check(model.selection == .init(group: 1, index: 6), "down keeps the column")
    model.move(.down, columns: 5); model.move(.down, columns: 5)
    check(model.selection == .init(group: 2, index: 0), "down from the last row goes to the next section, same column if it has it")
    model.move(.up, columns: 5)
    check(model.selection == .init(group: 1, index: 10), "up into the last row of the section above")
    model.move(.up, columns: 5); model.move(.up, columns: 5); model.move(.up, columns: 5)
    check(model.selection == .init(group: 0, index: 0), "up into Recently used")
    check(model.group(of: .protect) == 6, "⌘6 finds Protect after Recently used")
}

@MainActor
private func toolsSheetRender() {
    Style.opaqueBackgrounds = true
    defer { Style.opaqueBackgrounds = false }
    for dark in [false, true] {
        let model = ToolsSheetModel(recents: { [.makeSmaller, .sign, .combineFiles, .toWord, .blackOut].map(ToolCatalog.tile) })
        let controller = ToolsSheetController(model: model, availability: { _ in .ready },
                                              actions: .init(choose: { _, _ in }, close: {}, addToToolbar: { _ in }, addToDockMenu: { _ in }))
        controller.prepare(query: "")
        let sheet = controller.view as! ToolsSheetView
        sheet.search.showsFocus = true
        sheet.grid.allTiles.first { $0.tile.id == .rearrangePages && $0.frame.minY > 200 }?.isHovered = true
        let rep = render(sheet, size: SPMetrics.ToolsSheet.size, dark: dark)
        let path = save(rep, dark ? "tools-sheet-dark" : "tools-sheet")
        if let path { print("  render: \(path)") }
        guard !dark, let mockup = Mockup("tools-sheet", origin: CGPoint(x: 180, y: 122), size: SPMetrics.ToolsSheet.size) else { continue }
        let mine = Pixels(rep)
        // Down the first column, inside the tiles' left padding: the search field and the tiles are the white runs.
        let column = 30
        let theirs = mockup.pixels.runs(x: column, from: 0, to: 600, minLength: 20, where: Pixels.isWhite)
        let ours = mine.runs(x: column, from: 0, to: 600, minLength: 20, where: Pixels.isWhite)
        compare(ours, theirs, count: 3, tolerance: 3, "sheet: search field and the first two tile rows (pt, top/length)")
        // Across the first tile row: five tiles 150 wide, 16 apart, from 24.
        if let row = theirs.dropFirst().first, let myRow = ours.dropFirst().first {
            let across = mockup.pixels.runs(y: row.start + 4, from: 0, to: 880, minLength: 100, where: Pixels.isWhite)
            let mineAcross = mine.runs(y: myRow.start + 4, from: 0, to: 880, minLength: 100, where: Pixels.isWhite)
            compare(mineAcross, across, count: 5, tolerance: 3, "sheet: tile columns (pt, left/width)")
        }
    }
}

// MARK: - Panels as the mockups draw them

/// The six mockup panels described with the panel vocabulary (the wave C modules describe the real ones).
@MainActor
private final class MockupProvider: ToolProviding {
    let tools: [ToolID] = [.makeSmaller, .watermark, .toWord, .blackOut, .sign, .requestSignatures]

    func panel(for tool: ToolID, context: ToolContext) -> ToolPanel {
        switch tool {
        case .makeSmaller:
            return ToolPanel(.presetAndMore, hint: "Shrinks the file so it’s easier to send. The pages stay the same.", controls: [
                .radio(id: "preset", options: [
                    ToolOption("good", "Good (recommended)", detail: "Pictures stay sharp on screen and in print", value: "≈ 2.8 MB"),
                    ToolOption("email", "Email", detail: "Smallest. Fine for reading, pictures a little softer", value: "≈ 1.7 MB"),
                    ToolOption("best", "Best quality", detail: "Only removes what nobody will see", value: "≈ 5.1 MB"),
                ], selected: "good"),
                .note("Comments, form entries and bookmarks are kept."),
            ], moreOptions: [.slider(id: "quality", label: "Quality", range: 0...100, step: 1, value: 70, format: .percent)],
               primary: ToolButton("Make smaller"), output: .sibling(.smaller, ext: "pdf"))
        case .watermark:
            return ToolPanel(.livePreview, hint: "Stamps a word or a logo across every page. You can see it on the page as you type.",
                             showsScope: true, controls: [
                .segmented(id: "kind", options: [ToolOption("text", "Text"), ToolOption("picture", "Picture")], selected: "text"),
                .text(id: "text", label: nil, placeholder: "", value: "DRAFT", isSecure: false),
                .slider(id: "lightness", label: "Lightness", range: 0...100, step: 1, value: 30, format: .percent),
                .popup(id: "angle", label: "Angle", options: [ToolOption("straight", "Straight"), ToolOption("diagonal", "Diagonal"),
                                                              ToolOption("custom", "Custom…")], selected: "diagonal"),
                .moreOptions,
                .note("Drag the word on the page to move it. Nothing is saved until you click Add watermark."),
            ], moreOptions: [.toggle(id: "print", label: "Only when printing", isOn: false)], primary: ToolButton("Add watermark"))
        case .toWord:
            return ToolPanel(.convert, hint: "Makes a Word document you can edit. Text, headings, tables and pictures come across.",
                             showsScope: true, controls: [
                .segmented(id: "format", label: "Format", options: [ToolOption("docx", "Word (.docx)"), ToolOption("rtf", "Rich text (.rtf)")],
                           selected: "docx"),
                .segmented(id: "layout", label: "Layout", options: [ToolOption("look", "Keep the look"), ToolOption("flow", "Flowing text")],
                           selected: "look"),
                .note("“Keep the look” places text where it is on the page — best for forms and brochures. “Flowing text” makes "
                      + "paragraphs that reflow — best for letters and reports."),
                .scope,
                .list([ToolOption("text", "Text and headings", value: "12 pages"), ToolOption("tables", "1 table", value: "p. 3"),
                       ToolOption("pictures", "9 pictures", value: "kept")]),
                .note("Converted by the built-in converter, on this Mac."),
            ], primary: ToolButton("Save as Word…"), output: .sameName(ext: "docx"))
        case .blackOut:
            return ToolPanel(.mode, hint: "Permanently hides names, numbers or anything private. Your original file stays as it is.",
                             controls: [
                .segmented(id: "mode", options: [ToolOption("hand", "Mark by hand"), ToolOption("find", "Find and mark")], selected: "find"),
                .text(id: "find", label: nil, placeholder: "", value: "Natarajan", isSecure: false),
                .chips(id: "patterns", options: [ToolOption("phone", "Phone numbers", value: "2"), ToolOption("email", "Emails", value: "2"),
                                                 ToolOption("card", "Card numbers"), ToolOption("ni", "National Insurance", value: "1"),
                                                 ToolOption("dates", "Dates"), ToolOption("pattern", "Pattern…")],
                       selected: ["phone", "email", "ni"], allowsMultiple: true),
                .note("7 found on 2 pages"),
                .checklist(id: "found", items: [ToolOption("n", "“Natarajan”", value: "p. 1, 3"), ToolOption("p1", "07700 900 417", value: "p. 3"),
                                                ToolOption("p2", "01225 448 912", value: "p. 3"),
                                                ToolOption("e", "priya.natarajan@example.com", value: "p. 3"),
                                                ToolOption("ni", "QQ 12 34 56 C", value: "p. 3")],
                           selected: ["n", "p1", "p2", "e", "ni"]),
                .toggle(id: "hidden", label: "Also remove hidden information (metadata, comments)", isOn: true),
                .toggle(id: "redacted", label: "Write “REDACTED” over the boxes", isOn: false),
            ], primary: ToolButton("Black out 7 items", isDestructive: true), output: .sibling(.blackedOut, ext: "pdf"))
        case .sign:
            return ToolPanel(.mode, hint: "Put your signature on the page. Click a signature, then click where it goes.", controls: [
                .segmented(id: "kind", options: [ToolOption("mine", "My signature"), ToolOption("certificate", "With a certificate")],
                           selected: "mine"),
                .custom(id: "pads", make: { SignaturePadsStandIn() }),
                .action(id: "create", title: "Create signature…", isDestructive: false, symbol: "plus"),
                .note("You can draw on the trackpad, hold a signed piece of paper up to the camera, or sign on your iPhone."),
                .toggle(id: "date", label: "Add today’s date next to it", isOn: true, rowLabel: "Date"),
            ], primary: ToolButton("Sign and save…"), output: .sibling(.signed, ext: "pdf"))
        default:
            return ToolPanel(.flow, hint: "Send this to people to sign. They can sign in any PDF app and send it back; we match the files "
                             + "when they return.", steps: ["1 Who", "2 Where", "3 Send"],
                             currentStep: context.values.int(ToolPanel.stepValue), controls: [
                .note("Click the page to place a field for the selected person."),
                .custom(id: "signers", make: { SignerRowsStandIn() }),
                .chips(id: "field", options: [ToolOption("signature", "Signature", symbol: "signature"), ToolOption("initials", "Initials"),
                                              ToolOption("date", "Date"), ToolOption("name", "Name"), ToolOption("tick", "Tick box")],
                       selected: ["signature"], allowsMultiple: false),
                .toggle(id: "order", label: "Sign in this order", isOn: true),
                .note("Fields show in each person’s colour. Everything stays on this Mac; nothing is uploaded."),
            ], primary: ToolButton("Next: Send"))
        }
    }

    func preview(for tool: ToolID, context: ToolContext) async -> ToolPreview {
        tool == .makeSmaller ? .summary(["Now: 6.1 MB · 12 pages · 9 pictures"]) : .none
    }

    func run(_ request: ToolRequest, progress: ToolProgress) async throws -> ToolResult { .none }
}

/// SignKit's signature pads, drawn roughly for the render (the real ones are SignKit's).
private final class SignaturePadsStandIn: NSView {
    override var intrinsicContentSize: NSSize { NSSize(width: 280, height: 84 * 2 + 14) }
    override var isFlipped: Bool { true }
    override func draw(_ dirtyRect: NSRect) {
        for (i, text) in ["Priya Natarajan", "PN"].enumerated() {
            let box = NSRect(x: 0.5, y: CGFloat(i) * 98 + 0.5, width: bounds.width - 1, height: 83)
            NSColor.white.setFill(); NSBezierPath(roundedRect: box, xRadius: 10, yRadius: 10).fill()
            (i == 0 ? NSColor.controlAccentColor : NSColor(white: 0, alpha: 0.16)).setStroke()
            NSBezierPath(roundedRect: box, xRadius: 10, yRadius: 10).stroke()
            let font = NSFont(name: "Snell Roundhand", size: i == 0 ? 30 : 22) ?? .systemFont(ofSize: 22)
            let attributes: [NSAttributedString.Key: Any] = [.font: font, .foregroundColor: NSColor(hex: "#1A2C6B")]
            let size = (text as NSString).size(withAttributes: attributes)
            (text as NSString).draw(at: NSPoint(x: box.midX - size.width / 2, y: box.midY - size.height / 2), withAttributes: attributes)
        }
    }
}

/// SignKit's signer rows, drawn roughly for the render.
private final class SignerRowsStandIn: NSView {
    override var intrinsicContentSize: NSSize { NSSize(width: 280, height: 44 * 2 + 14) }
    override var isFlipped: Bool { true }
    override func draw(_ dirtyRect: NSRect) {
        let rows = [("ME", "Margaret Ellison", "m.ellison@orchardlets.co.uk", NSColor.systemPurple),
                    ("PN", "Priya Natarajan", "priya.natarajan@example.com", NSColor.systemTeal)]
        for (i, row) in rows.enumerated() {
            let box = NSRect(x: 0.5, y: CGFloat(i) * 58 + 0.5, width: bounds.width - 1, height: 43)
            (i == 0 ? row.3.withAlphaComponent(0.08) : NSColor.white).setFill(); NSBezierPath(roundedRect: box, xRadius: 8, yRadius: 8).fill()
            (i == 0 ? row.3 : NSColor(white: 0, alpha: 0.1)).setStroke(); NSBezierPath(roundedRect: box, xRadius: 8, yRadius: 8).stroke()
            row.3.setFill(); NSBezierPath(ovalIn: NSRect(x: 10, y: box.midY - 13, width: 26, height: 26)).fill()
            (row.0 as NSString).draw(at: NSPoint(x: 15, y: box.midY - 7), withAttributes: [.font: NSFont.boldSystemFont(ofSize: 11), .foregroundColor: NSColor.white])
            (row.1 as NSString).draw(at: NSPoint(x: 46, y: box.minY + 5), withAttributes: [.font: NSFont.systemFont(ofSize: 13, weight: .semibold)])
            (row.2 as NSString).draw(at: NSPoint(x: 46, y: box.minY + 22), withAttributes: [.font: NSFont.systemFont(ofSize: 11), .foregroundColor: NSColor.secondaryLabelColor])
        }
    }
}

/// The panel column of the mockups: 320 × 708 at (850, 122) in the 1240 × 900 mockup page.
private let panelSize = NSSize(width: SPMetrics.ToolPanel.width, height: SPMetrics.Window.defaultSize.height - SPMetrics.Window.toolbarHeight)

@MainActor
private func toolsPanelRenders() {
    Style.opaqueBackgrounds = true
    defer { Style.opaqueBackgrounds = false }
    installFakes()
    let folder = scratch.appendingPathComponent("renders", isDirectory: true)
    SuperPDFPaths.ensure(folder)
    let url = folder.appendingPathComponent("Lease agreement.pdf")
    try? makePDF(pages: 12).write(to: url)
    let document = makeDocument(pages: 12, url: url)
    let provider = MockupProvider()
    let names: [ToolID: String] = [.makeSmaller: "panel-make-smaller", .watermark: "panel-watermark", .toWord: "panel-to-word",
                                   .blackOut: "panel-black-out", .sign: "panel-sign", .requestSignatures: "panel-request-signatures"]
    for tool in provider.tools {
        Defaults.reset(ToolSession.valuesKey(tool))
        let session = ToolSession(tool: tool, provider: provider, document: document)
        if tool == .requestSignatures { session.next() }
        _ = complete { await session.updatePreview() }
        let controller = ToolPanelController(session: session, onBack: {}, onClose: {})
        let rep = render(controller.view, size: panelSize)
        if let path = save(rep, names[tool]!) { print("  render: \(path)") }
        guard let mockup = Mockup(names[tool]!, origin: CGPoint(x: 850, y: 122), size: panelSize) else { continue }
        let mine = Pixels(rep), theirs = mockup.pixels
        // The primary button: the strongly coloured run near the bottom, right of its centred title.
        let x = 290
        let button = theirs.runs(x: x, from: 560, to: 708, minLength: 20, where: Pixels.isSaturated)
        let myButton = mine.runs(x: x, from: 560, to: 708, minLength: 20, where: Pixels.isSaturated)
        compare(myButton, button, count: 1, tolerance: 3, "\(tool.rawValue): primary button (pt, top/height)")
        // The title: rows holding dark text right of the category icon.
        let title = theirs.inkRows(x: 66...200, y: 0...44), myTitle = mine.inkRows(x: 66...200, y: 0...44)
        check(title.map { abs($0.lowerBound - (myTitle?.lowerBound ?? -99)) <= 3 && abs($0.upperBound - (myTitle?.upperBound ?? -99)) <= 3 } ?? false,
              "\(tool.rawValue): title rows \(String(describing: myTitle)) vs mockup \(String(describing: title))")
        // The first full-width edge below the hint (preset card, segmented bar, text field, step bar).
        let firstEdge = theirs.firstWideRow(from: 76, to: 200), myFirstEdge = mine.firstWideRow(from: 76, to: 200)
        check(abs((firstEdge ?? 0) - (myFirstEdge ?? 999)) <= 4,
              "\(tool.rawValue): first control under the hint at \(myFirstEdge.map(String.init) ?? "-") pt vs mockup \(firstEdge.map(String.init) ?? "-") pt")
    }
}


// MARK: - Comparing with the mockups

/// RGBA bytes of a bitmap in sRGB, top-left origin, addressed in points of a 2× image.
private struct Pixels {
    let width: Int, height: Int
    private let bytes: [UInt8]

    init(_ rep: NSBitmapImageRep) {
        let width = rep.pixelsWide, height = rep.pixelsHigh
        self.width = width; self.height = height
        var buffer = [UInt8](repeating: 0, count: width * height * 4)
        let space = CGColorSpace(name: CGColorSpace.sRGB)!
        buffer.withUnsafeMutableBytes { raw in
            let context = CGContext(data: raw.baseAddress, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width * 4,
                                    space: space, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
            context.setFillColor(CGColor(srgbRed: 1, green: 1, blue: 1, alpha: 1))
            context.fill(CGRect(x: 0, y: 0, width: width, height: height))
            if let image = rep.cgImage { context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height)) }
        }
        bytes = buffer
    }

    init(_ rep: NSBitmapImageRep, crop: CGRect) {
        let full = Pixels(rep)
        width = Int(crop.width); height = Int(crop.height)
        var buffer = [UInt8](repeating: 255, count: width * height * 4)
        for y in 0..<height {
            for x in 0..<width {
                let sx = Int(crop.minX) + x, sy = Int(crop.minY) + y
                guard sx < full.width, sy < full.height else { continue }
                for c in 0..<4 { buffer[(y * width + x) * 4 + c] = full.bytes[(sy * full.width + sx) * 4 + c] }
            }
        }
        bytes = buffer
    }

    /// The colour at a pixel (2× coordinates).
    func rgb(_ x: Int, _ y: Int) -> (r: Int, g: Int, b: Int) {
        let i = (min(max(y, 0), height - 1) * width + min(max(x, 0), width - 1)) * 4
        return (Int(bytes[i]), Int(bytes[i + 1]), Int(bytes[i + 2]))
    }

    static func isWhite(_ c: (r: Int, g: Int, b: Int)) -> Bool { c.r >= 250 && c.g >= 250 && c.b >= 250 }
    static func isSaturated(_ c: (r: Int, g: Int, b: Int)) -> Bool { max(c.r, c.g, c.b) - min(c.r, c.g, c.b) > 120 }

    /// Runs of matching pixels down column `x` (points), as (start, length) in points.
    func runs(x: Int, from: Int, to: Int, minLength: Int, where match: ((r: Int, g: Int, b: Int)) -> Bool) -> [(start: Int, length: Int)] {
        runs(count: (to - from) * 2, minLength: minLength) { match(rgb(x * 2, from * 2 + $0)) }.map { ($0.start / 2 + from, $0.length / 2) }
    }

    /// Runs of matching pixels along row `y` (points).
    func runs(y: Int, from: Int, to: Int, minLength: Int, where match: ((r: Int, g: Int, b: Int)) -> Bool) -> [(start: Int, length: Int)] {
        runs(count: (to - from) * 2, minLength: minLength) { match(rgb(from * 2 + $0, y * 2)) }.map { ($0.start / 2 + from, $0.length / 2) }
    }

    private func runs(count: Int, minLength: Int, _ match: (Int) -> Bool) -> [(start: Int, length: Int)] {
        var result: [(Int, Int)] = [], start: Int?
        for i in 0...count {
            let on = i < count && match(i)
            if on, start == nil { start = i }
            if !on, let s = start { if i - s >= minLength * 2 { result.append((s, i - s)) }; start = nil }
        }
        return result
    }

    /// The first and last rows (points) in a box that hold dark ink (text).
    func inkRows(x: ClosedRange<Int>, y: ClosedRange<Int>) -> ClosedRange<Int>? {
        let rows = (y.lowerBound * 2...y.upperBound * 2).filter { py in
            stride(from: x.lowerBound * 2, through: x.upperBound * 2, by: 1).contains { px in let c = rgb(px, py); return c.r + c.g + c.b < 250 }
        }
        guard let first = rows.first, let last = rows.last else { return nil }
        return first / 2...last / 2
    }

    /// The first row (points) where most of the panel's width (20…300 pt) moves away from the background: an edge of
    /// a full-width control, never a line of text.
    func firstWideRow(from: Int, to: Int) -> Int? {
        let base = rgb(8, from * 2)
        for py in from * 2..<to * 2 {
            let differing = stride(from: 40, to: 600, by: 2).filter { px in
                let c = rgb(px, py)
                return abs(c.r - base.r) + abs(c.g - base.g) + abs(c.b - base.b) > 12
            }.count
            if differing >= 168 { return py / 2 }
        }
        return nil
    }
}

/// A region of a mockup PNG (docs/mockups, 2× of a 1240 × 900 pt page).
private struct Mockup {
    let pixels: Pixels

    init?(_ name: String, origin: CGPoint, size: NSSize) {
        let url = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("docs/mockups/\(name).png")
        guard let data = try? Data(contentsOf: url), let rep = NSBitmapImageRep(data: data) else {
            check(false, "mockup \(name).png is readable")
            return nil
        }
        pixels = Pixels(rep, crop: CGRect(x: origin.x * 2, y: origin.y * 2, width: size.width * 2, height: size.height * 2))
    }
}

/// The first `count` runs agree within `tolerance` points at both ends.
private func compare(_ ours: [(start: Int, length: Int)], _ theirs: [(start: Int, length: Int)], count: Int, tolerance: Int,
                     _ what: String) {
    let a = Array(ours.prefix(count)), b = Array(theirs.prefix(count))
    let same = a.count == count && b.count == count && zip(a, b).allSatisfy {
        abs($0.start - $1.start) <= tolerance && abs($0.length - $1.length) <= tolerance
    }
    check(same, "\(what): ours \(a.map { "\($0.start)+\($0.length)" }) vs mockup \(b.map { "\($0.start)+\($0.length)" })")
}

// MARK: - Banner (ux §7.3)

@MainActor
private func toolsBannerRender() {
    installFakes()
    let document = makeDocument(pages: 12)
    let file = scratch.appendingPathComponent("Lease agreement (smaller).pdf")
    var banner = Strings.Banner.madeSmaller(before: 6_100_000, after: 1_700_000)
    banner.file = file
    var dismissed = 0, details = 0
    let view = ResultBannerView(banner: banner, document: document, showDetails: { details += 1 }, dismiss: { dismissed += 1 })
    let size = NSSize(width: SPMetrics.Window.defaultSize.width, height: SPMetrics.Banner.height)
    let rep = render(view, size: size)
    if let path = save(rep, "main-window-result-banner") { print("  render: \(path)") }
    check(view.buttons.map(\.title) == ["Show in Finder", "Share", "Undo"], "banner buttons: \(view.buttons.map(\.title))")
    if let mockup = Mockup("main-window-result", origin: CGPoint(x: 70, y: 122), size: size) {
        let isGreen: ((r: Int, g: Int, b: Int)) -> Bool = { $0.g > 150 && $0.g - $0.r > 60 && $0.g - $0.b > 30 }
        // A chord of the green circle above its check mark.
        compare(Pixels(rep).runs(y: 15, from: 0, to: 200, minLength: 8, where: isGreen),
                mockup.pixels.runs(y: 15, from: 0, to: 200, minLength: 8, where: isGreen), count: 1, tolerance: 2, "banner: the check (pt)")
        // The buttons' borders from the right edge.
        let dark: ((r: Int, g: Int, b: Int)) -> Bool = { $0.r < 235 }
        let ours = Pixels(rep).runs(y: 22, from: 1000, to: 1100, minLength: 0, where: dark).last
        let theirs = mockup.pixels.runs(y: 22, from: 1000, to: 1100, minLength: 0, where: dark).last
        check(abs((ours?.start ?? 0) - (theirs?.start ?? 99)) <= 3, "banner: right edge of Undo \(String(describing: ours)) vs \(String(describing: theirs))")
    }

    // Actions: no Finder, no other app (the system hooks are swapped).
    var revealed: [URL] = [], opened: [(URL, String)] = []
    let reveal = ToolsKitSystem.reveal, openIn = ToolsKitSystem.openInApp
    ToolsKitSystem.reveal = { revealed += $0 }
    ToolsKitSystem.openInApp = { opened.append(($0, $1)) }
    defer { ToolsKitSystem.reveal = reveal; ToolsKitSystem.openInApp = openIn }
    view.perform(.showInFinder, from: view)
    check(revealed == [file], "Show in Finder reveals the file")
    view.perform(.openIn(appName: "Word"), from: view)
    check(opened.first?.0 == file && opened.first?.1 == "Word", "Open in Word")
    var undone = false
    document.undoManager?.beginUndoGrouping()
    document.undoManager?.register(UndoGroup("Make Smaller", undo: { undone = true }, redo: {}))
    document.undoManager?.endUndoGrouping()
    view.perform(.undo, from: view)
    check(undone && dismissed == 1, "Undo undoes and hides the banner")
    view.perform(.showDetails, from: view)
    check(details == 1 && dismissed == 2, "Show reopens the panel")
}

// MARK: - The registry (Services.tools)

@MainActor
private func toolsRegistry() {
    installFakes()
    let registry = ToolsController()
    let pages = FakeToolProvider([.rotatePages, .deletePages])
    Services.toolProviders = [pages]
    check(registry.provider(for: .rotatePages) === pages && registry.provider(for: .readAloud) == nil, "providers are collected")
    let viewer = FakeToolProvider([.readAloud])
    Services.toolProviders.append(viewer)
    check(registry.provider(for: .readAloud) === viewer, "a provider added later (ViewerKit installs after ToolsKit) is found")

    Defaults.reset(.frecency)
    check(registry.recentlyUsed.isEmpty, "Recently used starts empty")
    registry.recordUse(.makeSmaller); registry.recordUse(.sign); registry.recordUse(.makeSmaller)
    check(registry.recentlyUsed.map(\.id) == [.makeSmaller, .sign], "Recently used by frecency")
    check(registry.search("compress").first?.id == .makeSmaller && registry.search("merge").first?.id == .combineFiles, "search")
    Defaults.reset(.frecency)

    // Sheet size: 880 × 620 inside the window less 80 pt each way, never under 640 × 480.
    check(ToolsController.sheetSize(in: NSSize(width: 1100, height: 708)) == NSSize(width: 880, height: 620), "sheet in a default window")
    check(ToolsController.sheetSize(in: NSSize(width: 800, height: 500)) == NSSize(width: 720, height: 480), "sheet clamped")
    check(ToolsController.sheetSize(in: NSSize(width: 600, height: 400)) == NSSize(width: 640, height: 480), "sheet minimum")

    // Panels go into the document's slot and come out again.
    let document = makeDocument(pages: 4)
    (Services.viewer as? FakeViewer)?.selection[document.id] = [0, 2]
    registry.openPanel(.rotatePages, for: document, inputs: [])
    let hosted = (Services.viewer as? FakeViewer)?.panels[document.id] as? ToolPanelController
    check(hosted?.session.tool == .rotatePages && hosted?.session.scope == .selected([0, 2]), "panel shown with the sidebar's selection")
    registry.openPanel(.deletePages, for: document, inputs: [])
    check(((Services.viewer as? FakeViewer)?.panels[document.id] as? ToolPanelController)?.session.tool == .deletePages, "switching tools")
    registry.closePanel(for: document)
    check((Services.viewer as? FakeViewer)?.panels[document.id] == nil, "closePanel empties the slot")

    // Toolbar items and the Dock menu.
    let item = registry.makeToolbarItem(.makeSmaller)
    check(item.itemIdentifier.rawValue == "tool.make-smaller" && item.label == "Make smaller" && item.image != nil && item.action != nil,
          "toolbar item for a tile")
    check(ToolID(toolbarItemIdentifier: item.itemIdentifier) == .makeSmaller && ToolID(toolbarItemIdentifier: .flexibleSpace) == nil,
          "toolbar identifiers round-trip")
    Defaults[.dockMenuTools] = [.combineFiles, .makeSmaller]
    let dock = registry.makeDockMenu()
    check(dock.items.map(\.title) == ["All Tools…", "", "Combine Files…", "Make Smaller…"], "Dock menu: \(dock.items.map(\.title))")
    Defaults.reset(.dockMenuTools)

    // The banner view factory.
    let banner = registry.makeBannerView(Strings.Banner.recognised(pages: 14), in: document, dismiss: {})
    check((banner as? ResultBannerView)?.buttons.map(\.title) == ["Undo"], "banner for Recognise text")

    // Jargon in hints for experts (Settings › Tools).
    check(TileView.jargonWord("compress") == "Compress" && TileView.jargonWord("ocr") == "OCR" && TileView.jargonWord("pdfa") == "PDF/A"
          && TileView.jargonWord("jpg to pdf") == "JPG to PDF", "jargon words")
    Defaults[.showJargonInHints] = true
    check(TileView.hintText(ToolCatalog.tile(.makeSmaller)).string == "Shrink the file so it’s easier to send (Compress)", "jargon hint")
    Defaults.reset(.showJargonInHints)
    Services.toolProviders = []
}

// MARK: - Live preview overlay

@MainActor
private func toolsOverlay() {
    let box = CGRect(x: 10, y: 20, width: 600, height: 800)
    func map(_ p: CGPoint, _ rotation: Int, width: CGFloat) -> CGPoint {
        p.applying(PageOverlayView.pageTransform(pageBox: box, rotation: rotation, viewSize: CGSize(width: width, height: 0)))
    }
    check(map(CGPoint(x: 10, y: 20), 0, width: 300) == .zero && map(CGPoint(x: 610, y: 820), 0, width: 300) == CGPoint(x: 300, y: 400),
          "upright page: lower-left to origin, scaled")
    check(map(CGPoint(x: 10, y: 820), 90, width: 800) == CGPoint(x: 800, y: 600), "turned right: the top-left corner goes to the top-right")
    check(map(CGPoint(x: 10, y: 20), 180, width: 600) == CGPoint(x: 600, y: 800), "upside down")
    check(map(CGPoint(x: 10, y: 20), 270, width: 800) == CGPoint(x: 800, y: 0), "turned left")

    // Installing on a PDF view asks for overlay views of the pages it lays out.
    let pdfView = PDFView(frame: NSRect(x: 0, y: 0, width: 600, height: 800))
    let window = RenderWindow(contentRect: pdfView.frame, styleMask: [.borderless], backing: .buffered, defer: false)
    window.contentView = pdfView
    pdfView.document = PDFDocument(data: makePDF(pages: 2))
    pdfView.layoutDocumentView()
    weak let installed = PreviewOverlay.installed(on: pdfView)
    check(installed != nil, "the overlay stays alive while its view does (PDFView holds it weakly)")
    let overlay = PreviewOverlay.installed(on: pdfView)
    pdfView.layoutDocumentView()
    RunLoop.main.run(until: Date().addingTimeInterval(0.1))
    check(PreviewOverlay.installed(on: pdfView) === overlay, "one overlay per view")
    check(overlay.overlayViewCount > 0, "overlay views for the laid-out pages (\(overlay.overlayViewCount))")
    var drawn = 0
    overlay.draw = { _, _ in drawn += 1 }
    pdfView.documentView?.displayIfNeeded()
    _ = drawn
}

// MARK: - Speed (the sheet opens at once, search keeps up with typing)

@MainActor
private func toolsSpeed() {
    Style.opaqueBackgrounds = true
    defer { Style.opaqueBackgrounds = false }
    let window = RenderWindow(contentRect: NSRect(origin: .zero, size: SPMetrics.ToolsSheet.size), styleMask: [.borderless],
                              backing: .buffered, defer: false)
    var start = Date()
    let model = ToolsSheetModel(recents: { [.makeSmaller, .sign].map(ToolCatalog.tile) })
    let controller = ToolsSheetController(model: model, availability: { _ in .ready },
                                          actions: .init(choose: { _, _ in }, close: {}, addToToolbar: { _ in }, addToDockMenu: { _ in }))
    controller.prepare(query: "")
    window.contentView = controller.view
    controller.view.frame = NSRect(origin: .zero, size: SPMetrics.ToolsSheet.size)
    controller.view.layoutSubtreeIfNeeded()
    controller.view.displayIfNeeded()
    let first = Date().timeIntervalSince(start)
    start = Date()
    controller.prepare(query: "")
    controller.view.layoutSubtreeIfNeeded()
    controller.view.displayIfNeeded()
    let again = Date().timeIntervalSince(start)
    print("  sheet: first open \(Int(first * 1000)) ms (debug build), reopen \(Int(again * 1000)) ms")
    check(again < 0.1, "the sheet reopens in under 100 ms (\(Int(again * 1000)) ms)")
    check(first < 0.5, "the sheet builds in under 500 ms in a debug build (\(Int(first * 1000)) ms)")

    let sheet = controller.view as! ToolsSheetView
    start = Date()
    for text in ["s", "sm", "sma", "smal", "small", "smalle", "smaller", "smalle", "small", ""] {
        sheet.search.field.stringValue = text
        controller.controlTextDidChange(Notification(name: NSControl.textDidChangeNotification))
        controller.view.layoutSubtreeIfNeeded()
    }
    let perKey = Date().timeIntervalSince(start) / 10
    print("  sheet: \(String(format: "%.1f", perKey * 1000)) ms per keystroke")
    check(perKey < 0.016, "filtering keeps up with typing (\(String(format: "%.1f", perKey * 1000)) ms per key)")
    check(model.query == "", "typing reached the model")
}
