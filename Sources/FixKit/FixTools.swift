import AppKit
import PDFKit
import SuperPDFCore
import Vision

/// The Fix & check tiles FixKit serves (ux §4.1, §5.3): Make smaller, Recognise text, Compare files, Check
/// accessibility, Check for printing and Repair. Panels are described from the values and from what the previews
/// computed (estimates, check results, changes, the repair diagnosis), which are cached per document and choices, so
/// `panel(for:)` stays cheap.
@MainActor
final class FixTools: ToolProviding {
    let service: FixService

    init(service: FixService) { self.service = service }

    let tools: [ToolID] = [.makeSmaller, .recogniseText, .compareFiles, .checkAccessibility, .checkForPrinting, .repair]

    // Caches, keyed by `key(document)` plus what the result depends on.
    private var sizes: [String: Int64] = [:]
    private var estimates: [String: [SizePreset: Int64]] = [:]
    private var audits: [String: SpaceAudit] = [:]
    private var textless: [String: [Int]] = [:]
    private var accessibility: [String: Checker.AccessibilityReport] = [:]
    private var printing: [String: [CheckIssue]] = [:]
    private var plates: [String: (image: CGImage, maxInk: Double, page: Int)] = [:]
    private var comparisons: [String: [LocatedChange]] = [:]
    private var diagnoses: [String: RepairDiagnosis] = [:]

    /// Changes whenever the document does as far as a panel can tell (identity, edited state, page count).
    private func key(_ document: DocumentHandle?) -> String {
        guard let document else { return "-" }
        return "\(document.id.uuidString)|\(document.state.isEdited)|\(document.pageCount)|\(ObjectIdentifier(document.pdf).hashValue)"
    }

    // MARK: Panels

    func panel(for tool: ToolID, context: ToolContext) -> ToolPanel {
        switch tool {
        case .makeSmaller: makeSmallerPanel(context)
        case .recogniseText: recognisePanel(context)
        case .compareFiles: comparePanel(context)
        case .checkAccessibility: accessibilityPanel(context)
        case .checkForPrinting: printingPanel(context)
        default: repairPanel(context)
        }
    }

    func preview(for tool: ToolID, context: ToolContext) async -> ToolPreview {
        guard let document = context.document else { return .none }
        switch tool {
        case .makeSmaller: return await makeSmallerPreview(document, context)
        case .compareFiles: return await comparePreview(document, context)
        case .checkAccessibility: return await accessibilityPreview(document)
        case .checkForPrinting: return await printingPreview(document, context)
        case .repair: await repairPreview(document); return .none
        default: return .none
        }
    }

    func handle(action: String, context: ToolContext) async throws -> ToolValues {
        guard context.tool == .compareFiles, let document = context.document,
              let changes = comparisons[compareKey(document, context)], !changes.isEmpty else { return context.values }
        // ‹ › move through the changes and show the page.
        var values = context.values
        let current = values.int(CompareIDs.cursor, default: -1)
        let next = action == CompareIDs.previous ? max(current - 1, 0) : min(current + 1, changes.count - 1)
        values[CompareIDs.cursor] = .int(next)
        if let page = changes[next].change.newPage, let pdfPage = document.pdf.page(at: page) {
            Services.viewer?.pdfView(for: document)?.go(to: pdfPage)
        }
        return values
    }

    func run(_ request: ToolRequest, progress: ToolProgress) async throws -> ToolResult {
        guard let source = request.source else { throw ToolError(FixStrings.Repair.failed(nil)) }
        switch request.tool {
        case .makeSmaller: return try await runMakeSmaller(request, source: source, progress: progress)
        case .recogniseText: return try await runRecognise(request, source: source, progress: progress)
        case .compareFiles: return try await runCompare(request, source: source)
        case .checkAccessibility: return try await runAccessibility(request, source: source)
        case .checkForPrinting: return try await runPrinting(request, source: source)
        default: return try await runRepair(request, source: source)
        }
    }

    private func output(_ request: ToolRequest, _ suffix: OutputSuffix) -> URL {
        let name = request.destination?.lastPathComponent ?? suffix.fileName(base: request.document?.displayName ?? "Document", ext: "pdf")
        return request.workFolder.appendingPathComponent(name)
    }

    // MARK: - Make smaller (ux §5.3)

    private enum SmallerIDs {
        static let preset = "preset"
        static func quality(_ preset: SizePreset) -> String { "quality." + preset.rawValue }
        static func dpi(_ preset: SizePreset) -> String { "dpi." + preset.rawValue }
        static let removeComments = "removeComments", removeBookmarks = "removeBookmarks", removeFonts = "removeFonts"
        static let fastWebView = "fastWebView"
    }

    private static let presetOrder: [SizePreset] = [.good, .email, .best]

    private func preset(_ values: ToolValues) -> SizePreset {
        SizePreset(rawValue: values.string(SmallerIDs.preset, default: SizePreset.good.rawValue)) ?? .good
    }

    /// The options a preset runs with: its defaults, the More options choices for it, and the shared toggles.
    private func options(_ preset: SizePreset, _ values: ToolValues) -> OptimizeOptions {
        var options = OptimizeOptions.defaults(for: preset)
        options.imageQuality = values.double(SmallerIDs.quality(preset), default: options.imageQuality)
        options.imageDPI = Double(values.string(SmallerIDs.dpi(preset), default: String(Int(options.imageDPI)))) ?? options.imageDPI
        options.removeCommentsAndForms = values.bool(SmallerIDs.removeComments)
        options.removeBookmarksAndAttachments = values.bool(SmallerIDs.removeBookmarks)
        options.removeExtraFonts = values.bool(SmallerIDs.removeFonts)
        options.linearize = values.bool(SmallerIDs.fastWebView)
        return options
    }

    private func estimateKey(_ document: DocumentHandle?, _ values: ToolValues) -> String {
        key(document) + "|" + Self.presetOrder.map { "\(options($0, values).hashValue)" }.joined(separator: ",")
    }

    private func makeSmallerPanel(_ context: ToolContext) -> ToolPanel {
        typealias S = FixStrings.MakeSmaller
        let chosen = preset(context.values)
        let known = estimates[estimateKey(context.document, context.values)]
        let presets = Self.presetOrder.map { preset in
            ToolOption(preset.rawValue, S.title(preset), value: known?[preset].map(S.estimate))
        }
        let defaults = OptimizeOptions.defaults(for: chosen)
        var more: [ToolControl] = [
            .slider(id: SmallerIDs.quality(chosen), label: S.imageQuality, range: 0.1...1, step: 0.05, value: defaults.imageQuality, format: .percent),
            .popup(id: SmallerIDs.dpi(chosen), label: S.sharpness, options: [72, 150, 300].map { ToolOption("\($0)", S.dpi($0)) },
                   selected: "\(Int(defaults.imageDPI))"),
            .toggle(id: SmallerIDs.removeComments, label: S.removeComments, isOn: false),
            .toggle(id: SmallerIDs.removeBookmarks, label: S.removeBookmarks, isOn: false),
            .toggle(id: SmallerIDs.removeFonts, label: S.removeFonts, isOn: false),
            .toggle(id: SmallerIDs.fastWebView, label: S.fastWebView, isOn: false),
        ]
        if let audit = audits[key(context.document)] {
            more.append(.note(S.spaceHeading))
            more.append(.list([("images", S.pictures, audit.images), ("fonts", S.fonts, audit.fonts), ("content", S.content, audit.content),
                               ("structure", S.structure, audit.structure), ("attachments", S.attachments, audit.attachments)]
                .filter { $0.2 > 0 }.map { ToolOption($0.0, $0.1, value: Formatting.bytes($0.2)) }))
        }
        // No preset gains anything: say so and disable the button (ux §5.3).
        let now = sizes[key(context.document)]
        let noGain = known.map { estimates in now.map { now in Self.presetOrder.allSatisfy { (estimates[$0] ?? now) >= now * 99 / 100 } } ?? false } ?? false
        return ToolPanel(.presetAndMore, hint: S.hint,
                         controls: [.radio(id: SmallerIDs.preset, options: presets, selected: SizePreset.good.rawValue)],
                         moreOptions: more,
                         primary: ToolButton(S.button, isEnabled: context.document != nil && !noGain),
                         output: .sibling(.smaller, ext: "pdf"),
                         message: noGain ? ToolMessage(.info, S.alreadySmall) : nil)
    }

    private func makeSmallerPreview(_ document: DocumentHandle, _ context: ToolContext) async -> ToolPreview {
        let documentKey = key(document), estimateKey = estimateKey(document, context.values)
        let source = document.snapshot()
        if sizes[documentKey] == nil { sizes[documentKey] = Self.size(of: source) }
        if estimates[estimateKey] == nil {
            let list = Self.presetOrder.map { options($0, context.values) }
            if let values = try? await service.estimates(source, options: list) {
                estimates[estimateKey] = Dictionary(uniqueKeysWithValues: zip(Self.presetOrder, values))
            }
        }
        if audits[documentKey] == nil, let audit = try? await service.audit(source) { audits[documentKey] = audit }
        return sizes[documentKey].map { .summary([FixStrings.MakeSmaller.now($0)]) } ?? .none
    }

    static func size(of source: PDFSource) -> Int64 {
        switch source {
        case .file(let url, _): Int64((try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0)
        case .data(let data, _): Int64(data.count)
        }
    }

    private func runMakeSmaller(_ request: ToolRequest, source: PDFSource, progress: ToolProgress) async throws -> ToolResult {
        let before = Self.size(of: source)
        let url = output(request, .smaller)
        try await service.optimize(source, options: options(preset(request.values), request.values), to: url, progress: progress)
        let after = Self.size(of: .file(url))
        guard after < before else {
            try? FileManager.default.removeItem(at: url)
            throw ToolError(ToolMessage(.info, FixStrings.MakeSmaller.alreadySmall))
        }
        return .newFile(url, banner: Strings.Banner.madeSmaller(before: before, after: after))
    }

    // MARK: - Recognise text (ux §5.3)

    private enum RecogniseIDs {
        static let language = "language", cleanUp = "cleanUp", editable = "editable", dpi = "dpi"
        static let automatic = "auto"
    }

    /// Automatic plus the Mac's preferred languages Vision reads (a popup has at most seven items, ux §5.1).
    static let languages: [ToolOption] = {
        let supported = Set((try? VNRecognizeTextRequest().supportedRecognitionLanguages()) ?? [])
        var options: [ToolOption] = []
        for preferred in Locale.preferredLanguages {
            let match = supported.first { $0 == preferred } ?? supported.first { $0.hasPrefix(Locale(identifier: preferred).language.languageCode?.identifier ?? "-") }
            guard let match, !options.contains(where: { $0.id == match }) else { continue }
            options.append(ToolOption(match, Locale.current.localizedString(forIdentifier: match) ?? match))
            if options.count == 6 { break }
        }
        return [ToolOption(RecogniseIDs.automatic, FixStrings.Recognise.automatic)] + options
    }()

    private func pagesWithoutText(_ document: DocumentHandle) -> [Int] {
        let documentKey = key(document)
        if let known = textless[documentKey] { return known }
        let pages = service.pagesWithoutText(in: document)
        textless[documentKey] = pages
        return pages
    }

    private func recognisePanel(_ context: ToolContext) -> ToolPanel {
        typealias R = FixStrings.Recognise
        var controls: [ToolControl] = []
        var todo: [Int] = []
        if let document = context.document {
            let without = pagesWithoutText(document)
            controls.append(.note(R.withoutText(without.count, of: document.pageCount)))
            let scoped = Set(context.scope.pages(count: document.pageCount, current: context.currentPage))
            todo = without.filter(scoped.contains)
        }
        controls += [
            .popup(id: RecogniseIDs.language, label: R.language, options: Self.languages, selected: RecogniseIDs.automatic),
            .toggle(id: RecogniseIDs.cleanUp, label: R.cleanUp, isOn: true),
        ]
        return ToolPanel(.presetAndMore, showsScope: true, controls: controls,
                         moreOptions: [
                            .toggle(id: RecogniseIDs.editable, label: R.editable, isOn: false),
                            .popup(id: RecogniseIDs.dpi, label: R.resolution, options: [150, 300, 600].map { ToolOption("\($0)", FixStrings.MakeSmaller.dpi($0)) },
                                   selected: "300"),
                         ],
                         primary: ToolButton(R.button, isEnabled: !todo.isEmpty), output: .inPlace)
    }

    private func runRecognise(_ request: ToolRequest, source: PDFSource, progress: ToolProgress) async throws -> ToolResult {
        guard let document = request.document else { throw ToolError(FixStrings.Repair.failed(nil)) }
        let without = Set(service.pagesWithoutText(in: document))
        let pages = request.pages.filter(without.contains)
        let language = request.values.string(RecogniseIDs.language, default: RecogniseIDs.automatic)
        let options = OCROptions(languages: language == RecogniseIDs.automatic ? [] : [language],
                                 cleanUp: request.values.bool(RecogniseIDs.cleanUp, default: true),
                                 editableText: request.values.bool(RecogniseIDs.editable),
                                 dpi: Double(request.values.string(RecogniseIDs.dpi, default: "300")) ?? 300)
        let before = try source.bytes()
        let report = try await service.recognize(source, pages: pages, options: options, progress: progress)
        guard report.recognizedPages > 0 else { throw ToolError(ToolMessage(.info, FixStrings.Recognise.nothingFound)) }
        return .inPlace(undoable: UndoGroup(FixStrings.Recognise.actionName, .contents(before: before, after: report.data)),
                        banner: Strings.Banner.recognised(pages: report.recognizedPages))
    }

    // MARK: - Compare files (ux §5.3)

    private enum CompareIDs {
        static let other = "other", textOnly = "textOnly", cursor = "cursor", previous = "previous", next = "next"
    }

    /// The other version: the file chosen or dropped, else the newest earlier version of the document (ux §5.3).
    private func otherFile(_ context: ToolContext) -> URL? {
        if let chosen = context.values.files(CompareIDs.other).first { return chosen }
        if let dropped = context.inputs.first { return dropped }
        guard let url = context.document?.url else { return nil }
        return NSFileVersion.otherVersionsOfItem(at: url)?.max { ($0.modificationDate ?? .distantPast) < ($1.modificationDate ?? .distantPast) }?.url
    }

    private func compareKey(_ document: DocumentHandle, _ context: ToolContext) -> String {
        key(document) + "|" + (otherFile(context)?.path ?? "-") + "|" + String(context.values.bool(CompareIDs.textOnly))
    }

    private func comparePanel(_ context: ToolContext) -> ToolPanel {
        typealias C = FixStrings.Compare
        var controls: [ToolControl] = [
            .files(id: CompareIDs.other, label: C.other, types: ["com.adobe.pdf"], allowsMultiple: false),
            .toggle(id: CompareIDs.textOnly, label: C.textOnly, isOn: false),
        ]
        var changes: [LocatedChange]?
        if let document = context.document, otherFile(context) != nil {
            changes = comparisons[compareKey(document, context)]
            if let changes {
                let pages = Dictionary(grouping: changes, by: { $0.change.newPage ?? 0 })
                controls.append(.note(C.summary(changes: changes.count, pages: pages.count)))
                if !changes.isEmpty {
                    controls.append(.list(pages.keys.sorted().map { ToolOption("page-\($0)", C.page($0 + 1), value: C.changes(pages[$0]!.count)) }))
                    controls.append(.action(id: CompareIDs.previous, title: C.previous, isDestructive: false, symbol: "chevron.left"))
                    controls.append(.action(id: CompareIDs.next, title: C.next, isDestructive: false, symbol: "chevron.right"))
                }
            } else {
                controls.append(.note(C.comparing))
            }
        } else {
            controls.append(.note(Strings.Empty.compare))
        }
        return ToolPanel(.mode, controls: controls, primary: ToolButton(C.button, isEnabled: !(changes ?? []).isEmpty),
                         output: .newDocument(name: C.reportName))
    }

    private func comparePreview(_ document: DocumentHandle, _ context: ToolContext) async -> ToolPreview {
        guard let other = otherFile(context) else { return .none }
        let compareKey = compareKey(document, context)
        if comparisons[compareKey] == nil {
            comparisons[compareKey] = (try? await service.locatedChanges(.file(other), document.snapshot(),
                                                                          textOnly: context.values.bool(CompareIDs.textOnly))) ?? []
        }
        let changes = comparisons[compareKey] ?? []
        guard !changes.isEmpty else { return .none }
        return .overlay { page, context in
            guard let index = page.document?.index(for: page) else { return }
            for located in changes where located.change.newPage == index {
                let token: SPColorToken = switch located.change.kind {
                case .visual: SPColor.highlightBlue
                case .deleted: SPColor.highlightPink
                default: SPColor.highlightGreen
                }
                context.setFillColor(Comparer.color(token.light, alpha: 0.4))
                for rect in located.newBoxes {
                    context.fill(located.change.kind == .deleted ? CGRect(x: rect.maxX + 1, y: rect.minY, width: 2.5, height: rect.height)
                                                                 : rect.insetBy(dx: -1, dy: -1))
                }
            }
        }
    }

    private func runCompare(_ request: ToolRequest, source: PDFSource) async throws -> ToolResult {
        guard let document = request.document else { throw ToolError(FixStrings.Repair.failed(nil)) }
        let context = ToolContext(tool: .compareFiles, document: document, values: request.values, inputs: request.inputs)
        guard let other = otherFile(context) else { throw ToolError(ToolMessage(.info, Strings.Empty.compare)) }
        let known = comparisons[compareKey(document, context)]
        let changes: [LocatedChange]
        if let known { changes = known } else {
            changes = try await service.locatedChanges(.file(other), source, textOnly: request.values.bool(CompareIDs.textOnly))
        }
        let newName = document.url?.lastPathComponent ?? document.displayName
        let data = try await Task.detached(priority: .userInitiated) {
            try Comparer.report(changes, new: source, oldName: other.lastPathComponent, newName: newName)
        }.value
        return .newDocument(data, name: FixStrings.Compare.reportName, banner: nil)
    }

    // MARK: - Check accessibility / Check for printing (ux §5.3)

    private enum CheckIDs {
        static let fixes = "fixes", plate = "plate", marks = "marks"
        static func description(_ key: String) -> String { "alt." + key }
    }

    private static func summary(_ issues: [CheckIssue]) -> ToolPreview {
        let groups: [(CheckIssue.Severity, String)] = [(.failed, FixStrings.Check.failed), (.needsAttention, FixStrings.Check.needsAttention),
                                                       (.passed, FixStrings.Check.passed)]
        return .summary(groups.compactMap { severity, label in
            let count = issues.filter { $0.severity == severity }.count
            return count == 0 ? nil : "\(label): \(count)"
        })
    }

    /// The fixes as a checklist (all ticked), the problems without one as notes.
    private static func results(_ issues: [CheckIssue]) -> [ToolControl] {
        let problems = issues.filter { $0.severity != .passed }
        let fixable = problems.filter { $0.fixTitle != nil }
        var controls: [ToolControl] = []
        if !fixable.isEmpty {
            controls.append(.checklist(id: CheckIDs.fixes, items: fixable.map { ToolOption($0.id, $0.fixTitle!, value: $0.pages.isEmpty ? nil : FixStrings.Check.pages($0.pages)) },
                                       selected: fixable.map(\.id)))
        }
        for issue in problems where issue.fixTitle == nil {
            controls.append(.note(issue.title + (issue.pages.isEmpty ? "" : " · " + FixStrings.Check.pages(issue.pages))))
        }
        return controls
    }

    private func accessibilityPanel(_ context: ToolContext) -> ToolPanel {
        guard let report = accessibility[key(context.document)] else {
            return ToolPanel(.presetAndMore, controls: [.note(FixStrings.Check.checking)], primary: ToolButton(FixStrings.Check.button, isEnabled: false),
                             output: .sibling(.edited, ext: "pdf"))
        }
        var controls = Self.results(report.issues)
        for figure in report.figures where !figure.hasDescription {
            controls.append(.text(id: CheckIDs.description(figure.key), label: FixStrings.Check.picture(page: figure.page + 1),
                                  placeholder: FixStrings.Check.describe, value: "", isSecure: false))
        }
        let ticked = !context.values.strings(CheckIDs.fixes).isEmpty
        let described = report.figures.contains { !context.values.string(CheckIDs.description($0.key)).trimmingCharacters(in: .whitespaces).isEmpty }
        return ToolPanel(.presetAndMore, controls: controls, primary: ToolButton(FixStrings.Check.button, isEnabled: ticked || described),
                         output: .sibling(.edited, ext: "pdf"))
    }

    private func accessibilityPreview(_ document: DocumentHandle) async -> ToolPreview {
        let documentKey = key(document)
        if accessibility[documentKey] == nil, let report = try? await service.accessibilityReport(document.snapshot()) {
            accessibility[documentKey] = report
        }
        return accessibility[documentKey].map { Self.summary($0.issues) } ?? .none
    }

    private func runAccessibility(_ request: ToolRequest, source: PDFSource) async throws -> ToolResult {
        let report = accessibility[key(request.document)]
        var descriptions: [String: String] = [:]
        for figure in report?.figures ?? [] {
            let text = request.values.string(CheckIDs.description(figure.key)).trimmingCharacters(in: .whitespacesAndNewlines)
            if !text.isEmpty { descriptions[figure.key] = text }
        }
        let url = output(request, .edited)
        try await service.fixAccessibility(Set(request.values.strings(CheckIDs.fixes)), in: source, descriptions: descriptions, to: url)
        return .newFile(url, banner: Strings.Banner.saved(url.lastPathComponent, openIn: nil))
    }

    private static let plateOptions: [(id: String, title: String, plate: Separation?)] = [
        ("all", FixStrings.Check.allInks, nil), ("c", FixStrings.Check.cyan, .cyan), ("m", FixStrings.Check.magenta, .magenta),
        ("y", FixStrings.Check.yellow, .yellow), ("k", FixStrings.Check.black, .black),
    ]

    private func plateKey(_ document: DocumentHandle, _ context: ToolContext) -> String {
        key(document) + "|" + context.values.string(CheckIDs.plate, default: "all") + "|\(context.currentPage)"
    }

    private func printingPanel(_ context: ToolContext) -> ToolPanel {
        let more: [ToolControl] = [
            .popup(id: CheckIDs.plate, label: FixStrings.Check.separations, options: Self.plateOptions.map { ToolOption($0.id, $0.title) }, selected: "all"),
            .toggle(id: CheckIDs.marks, label: FixStrings.Check.printerMarks, isOn: false),
        ]
        guard let document = context.document, let issues = printing[key(document)] else {
            return ToolPanel(.presetAndMore, controls: [.note(FixStrings.Check.checking)], moreOptions: more,
                             primary: ToolButton(FixStrings.Check.button, isEnabled: false), output: .sibling(.edited, ext: "pdf"))
        }
        var controls = Self.results(issues)
        if let plate = plates[plateKey(document, context)] { controls.append(.note(FixStrings.Check.inkCoverage(Int(plate.maxInk.rounded())))) }
        let enabled = !context.values.strings(CheckIDs.fixes).isEmpty || context.values.bool(CheckIDs.marks)
        return ToolPanel(.presetAndMore, controls: controls, moreOptions: more, primary: ToolButton(FixStrings.Check.button, isEnabled: enabled),
                         output: .sibling(.edited, ext: "pdf"))
    }

    private func printingPreview(_ document: DocumentHandle, _ context: ToolContext) async -> ToolPreview {
        let documentKey = key(document)
        let source = document.snapshot()
        if printing[documentKey] == nil, let issues = try? await service.check(source, profile: .printing, progress: .ignored) {
            printing[documentKey] = issues
        }
        // Output preview (features #95): one plate of the page in view, drawn over it.
        let choice = context.values.string(CheckIDs.plate, default: "all")
        guard let plate = Self.plateOptions.first(where: { $0.id == choice })?.plate, let render = Services.render else {
            return printing[documentKey].map(Self.summary) ?? .none
        }
        let plateKey = plateKey(document, context)
        if plates[plateKey] == nil, let result = try? await render.separation(source, page: context.currentPage, plate: plate, dpi: 72),
           let provider = CGDataProvider(data: result.image.data as CFData),
           let image = CGImage(pngDataProviderSource: provider, decode: nil, shouldInterpolate: true, intent: .defaultIntent) {
            plates[plateKey] = (image, result.maxInk, context.currentPage)
        }
        guard let shown = plates[plateKey] else { return .none }
        return .overlay { page, context in
            guard page.document?.index(for: page) == shown.page else { return }
            let size = page.bounds(for: .cropBox).size
            context.saveGState()
            context.concatenate(Self.displayToPage(size: size, rotation: page.rotation))
            let displayed = page.rotation % 180 == 0 ? size : CGSize(width: size.height, height: size.width)
            context.draw(shown.image, in: CGRect(origin: .zero, size: displayed))
            context.restoreGState()
        }
    }

    /// Display space (the page as shown, origin at its lower-left) → page space from the crop box, for `rotation`.
    static func displayToPage(size: CGSize, rotation: Int) -> CGAffineTransform {
        switch ((rotation % 360) + 360) % 360 {
        case 90: CGAffineTransform(a: 0, b: -1, c: 1, d: 0, tx: 0, ty: size.width).inverted()
        case 180: CGAffineTransform(a: -1, b: 0, c: 0, d: -1, tx: size.width, ty: size.height).inverted()
        case 270: CGAffineTransform(a: 0, b: 1, c: -1, d: 0, tx: size.height, ty: 0).inverted()
        default: .identity
        }
    }

    private func runPrinting(_ request: ToolRequest, source: PDFSource) async throws -> ToolResult {
        let url = output(request, .edited)
        try await service.fixPrinting(Set(request.values.strings(CheckIDs.fixes)), in: source, printerMarks: request.values.bool(CheckIDs.marks),
                                      title: request.document?.url?.lastPathComponent ?? request.document?.displayName ?? "", to: url)
        return .newFile(url, banner: Strings.Banner.saved(url.lastPathComponent, openIn: nil))
    }

    // MARK: - Repair (ux §5.3)

    private enum RepairIDs {
        static let embedFonts = "embedFonts", fastWebView = "fastWebView"
    }

    private func repairPanel(_ context: ToolContext) -> ToolPanel {
        var controls: [ToolControl] = []
        if let problems = diagnoses[key(context.document)]?.problems, !problems.isEmpty { controls.append(.note(problems.joined(separator: " "))) }
        controls.append(.toggle(id: RepairIDs.embedFonts, label: FixStrings.Repair.embedFonts, isOn: false))
        return ToolPanel(.oneChoice, controls: controls,
                         moreOptions: [.toggle(id: RepairIDs.fastWebView, label: FixStrings.MakeSmaller.fastWebView, isOn: false)],
                         primary: ToolButton(FixStrings.Repair.button, isEnabled: context.document != nil), output: .sibling(.repaired, ext: "pdf"))
    }

    private func repairPreview(_ document: DocumentHandle) async {
        let documentKey = key(document)
        guard diagnoses[documentKey] == nil, let url = document.url, !document.state.isEdited, let diagnosis = await service.diagnose(url) else { return }
        diagnoses[documentKey] = diagnosis
    }

    private func runRepair(_ request: ToolRequest, source: PDFSource) async throws -> ToolResult {
        let url = output(request, .repaired)
        _ = try await service.repair(source, embedFonts: request.values.bool(RepairIDs.embedFonts), to: url)
        if request.values.bool(RepairIDs.fastWebView) {
            let linear = request.workFolder.appendingPathComponent(UUID().uuidString + ".pdf")
            try await service.linearize(.file(url, password: source.password), to: linear)
            _ = try FileManager.default.replaceItemAt(url, withItemAt: linear)
        }
        return .newFile(url, banner: Strings.Banner.saved(url.lastPathComponent, openIn: nil))
    }
}
