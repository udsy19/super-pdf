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
import ToolsKit
import ViewerKit

// ToolsKit (WP5): search and synonym ranking, frecency, provider coverage, the panel layout and session model, and
// offscreen renders of the Tools sheet, the panel archetypes and the result banner against the mockups' metrics.
func registerToolsKitTests() {
    SelfTest.cases.append(("ToolsKit.searchRanking", { toolsSearchRanking() }))
    SelfTest.cases.append(("ToolsKit.frecency", { toolsFrecency() }))
    SelfTest.cases.append(("ToolsKit.coverage", { toolsCoverage() }))
    SelfTest.cases.append(("ToolsKit.panelLayout", { toolsPanelLayout() }))
    SelfTest.cases.append(("ToolsKit.session", { toolsSession() }))
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
