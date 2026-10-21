import AppKit
import PDFKit
import SuperPDFCore
import UniformTypeIdentifiers

/// The Mark up tiles (ux §4.1, §5.3): Highlight & notes and Draw & shapes open Preview's markup bar with a palette of
/// its tools; Comments list reviews, answers, summarises and exchanges comments; Attach a file clips a file or a
/// voice note to the page; Measure measures on plans with a scale.
@MainActor
final class MarkupToolProvider: ToolProviding {
    let service: MarkupService
    /// Asks where to save exported comments, and which file to import; replaced by the self-test.
    var chooseExport: @MainActor (_ proposed: String) async -> URL? = { name in
        let panel = NSSavePanel()
        panel.nameFieldStringValue = name
        return await panel.begin() == .OK ? panel.url : nil
    }
    var chooseImport: @MainActor () async -> URL? = {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [UTType(filenameExtension: "xfdf") ?? .xml, .xml]
        return await panel.begin() == .OK ? panel.url : nil
    }
    /// The voice note recorded for a document, until it is attached.
    private var recordings: [UUID: URL] = [:]

    init(service: MarkupService) { self.service = service }

    var tools: [ToolID] { ToolCatalog.tiles(ownedBy: .markupKit).map(\.id) }

    func panel(for tool: ToolID, context: ToolContext) -> ToolPanel {
        switch tool {
        case .highlightAndNotes: palettePanel(context, entries: highlightEntries, swatches: highlightSwatches, hint: MarkupKitStrings.Panel.highlightHint)
        case .drawAndShapes: palettePanel(context, entries: drawEntries, swatches: strokeSwatches, hint: MarkupKitStrings.Panel.drawHint)
        case .commentsList: commentsPanel(context)
        case .attachFile: attachPanel(context)
        case .measure: measurePanel(context)
        default: ToolPanel(.mode, primary: ToolButton(Strings.Panel.done))
        }
    }

    // MARK: Highlight & notes, Draw & shapes (archetype D)

    private var highlightEntries: [PaletteEntry] {
        [PaletteEntry(title: "Highlight", symbol: "highlighter", shortcut: MarkupKitStrings.shortcut(for: .highlightText), tool: .highlight,
                      style: { if case .highlight = $0.textMarkup {} else { $0.textMarkup = .highlight(.yellow) } }),
         PaletteEntry(title: "Underline", symbol: "underline", shortcut: MarkupKitStrings.shortcut(for: .underlineText), tool: .highlight,
                      style: { $0.textMarkup = .underline }),
         PaletteEntry(title: "Strikethrough", symbol: "strikethrough", shortcut: MarkupKitStrings.shortcut(for: .strikeThroughText), tool: .highlight,
                      style: { $0.textMarkup = .strikethrough }),
         PaletteEntry(title: "Note", symbol: "note.text", shortcut: MarkupKitStrings.shortcut(for: .note), tool: .note),
         PaletteEntry(title: "Text", symbol: "character.textbox", shortcut: MarkupKitStrings.shortcut(for: .text), tool: .text)]
        + CorrectionKind.allCases.map { PaletteEntry(title: $0.title, symbol: $0 == .insertText ? "control" : $0 == .deleteText ? "delete.left" : "arrow.left.arrow.right",
                                                     shortcut: nil, tool: .correction($0)) }
    }

    private var drawEntries: [PaletteEntry] {
        [PaletteEntry(title: "Sketch", symbol: "scribble.variable", tool: .sketch), PaletteEntry(title: "Draw", symbol: "pencil.tip", tool: .draw)]
        + ShapeKind.allCases.map { PaletteEntry(title: $0.title, symbol: $0.symbol, shortcut: MarkupKitStrings.shortcut(for: $0), tool: .shape($0)) }
    }

    private var highlightSwatches: [(String, MarkupColor, (inout MarkupStyle) -> Void)] {
        HighlightColor.allCases.map { color in (color.title, MarkupColor(color.color), { $0.textMarkup = .highlight(color) }) }
    }

    private var strokeSwatches: [(String, MarkupColor, (inout MarkupStyle) -> Void)] {
        MarkupPalette.colors.map { name, color in ("Color", color, { $0.stroke = color }) }
    }

    private func palettePanel(_ context: ToolContext, entries: [PaletteEntry], swatches: [(String, MarkupColor, (inout MarkupStyle) -> Void)], hint: String) -> ToolPanel {
        guard let document = context.document else { return ToolPanel(.mode, primary: ToolButton(Strings.Panel.done, isEnabled: false), secondary: nil) }
        let session = service.session(for: document)
        // Opening the tile opens the bar with the palette's first tool, unless one of its tools is already chosen.
        if !entries.contains(where: { $0.tool == session.tool }) {
            session.setBarVisible(true)
            if let first = entries.first { session.choose(first.tool) }
        }
        return ToolPanel(.mode, hint: hint, controls: [.custom(id: "palette", make: { ToolPaletteView(session: session, entries: entries, swatches: swatches) })],
                         primary: ToolButton(Strings.Panel.done), secondary: nil, output: .inPlace)
    }

    // MARK: Comments list (ux §5.3)

    private func commentsPanel(_ context: ToolContext) -> ToolPanel {
        guard let document = context.document else { return ToolPanel(.mode, primary: ToolButton(Strings.Panel.done, isEnabled: false), secondary: nil) }
        let session = service.session(for: document)
        let items = service.comments(in: document)
        let me = service.authorName
        let filter = context.values.strings("filter").first ?? "all"
        let sort = context.values.string("sort", default: "page")
        func count(_ id: String) -> String { String(CommentRowsView.filtered(items, filter: id, sort: sort, me: me).count) }
        let chips: [ToolOption] = [ToolOption("all", MarkupKitStrings.Panel.all, value: count("all")),
                                   ToolOption("mine", MarkupKitStrings.Panel.mine, value: count("mine")),
                                   ToolOption("unresolved", MarkupKitStrings.Panel.unresolved, value: count("unresolved"))]
        return ToolPanel(.mode, controls: [
            .chips(id: "filter", options: chips, selected: [filter], allowsMultiple: false),
            .popup(id: "sort", label: MarkupKitStrings.Panel.sort, options: [ToolOption("page", MarkupKitStrings.Panel.byPage),
                                                                              ToolOption("date", MarkupKitStrings.Panel.byDate),
                                                                              ToolOption("author", MarkupKitStrings.Panel.byAuthor)], selected: sort),
            .custom(id: "comments-\(filter)-\(sort)", make: {
                Services.viewer?.showSidebar(.highlightsAndNotes, in: document)
                return CommentRowsView(session: session, filter: filter, sort: sort)
            }),
            .action(id: "summarise", title: MarkupKitStrings.Panel.summarise, isDestructive: false, symbol: "doc.text"),
            .action(id: "import", title: MarkupKitStrings.Panel.importComments, isDestructive: false, symbol: "square.and.arrow.down"),
            .action(id: "export", title: MarkupKitStrings.Panel.exportComments, isDestructive: false, symbol: "square.and.arrow.up"),
        ], moreOptions: [
            .popup(id: "layout", label: MarkupKitStrings.Panel.summaryLayout, options: [
                ToolOption(CommentSummaryOptions.Layout.connectorLines.rawValue, MarkupKitStrings.Panel.connectorLines),
                ToolOption(CommentSummaryOptions.Layout.commentsOnly.rawValue, MarkupKitStrings.Panel.commentsOnly),
                ToolOption(CommentSummaryOptions.Layout.sequenceNumbers.rawValue, MarkupKitStrings.Panel.numbered)],
                   selected: CommentSummaryOptions.Layout.connectorLines.rawValue),
            .popup(id: "format", label: MarkupKitStrings.Panel.exportFormat, options: CommentFormat.allCases.map { ToolOption($0.rawValue, $0.rawValue.uppercased()) },
                   selected: CommentFormat.xfdf.rawValue),
        ], primary: ToolButton(Strings.Panel.done), secondary: nil, output: .inPlace)
    }

    func handle(action: String, context: ToolContext) async throws -> ToolValues {
        guard let document = context.document else { return context.values }
        switch action {
        case "summarise":
            let layout = CommentSummaryOptions.Layout(rawValue: context.values.string("layout")) ?? .connectorLines
            let data = try await service.summarizeComments(of: document, options: CommentSummaryOptions(layout: layout))
            try Services.documents?.openUntitled(data, name: MarkupKitStrings.Panel.summaryName(document.displayName))
        case "export":
            let format = CommentFormat(rawValue: context.values.string("format")) ?? .xfdf
            guard let url = await chooseExport("\(document.displayName).\(format.rawValue)") else { break }
            try service.exportComments(from: document, as: format, to: url)
        case "import":
            guard let url = await chooseImport() else { break }
            do {
                let group = try service.importComments(from: url, into: document)
                service.session(for: document).register(group)
                service.session(for: document).refresh()
            } catch {
                throw ToolError(error.localizedDescription)
            }
        case "setScale":
            let session = service.session(for: document)
            guard let line = session.lastDistance else { throw ToolError(MarkupKitStrings.Panel.needLine) }
            let real = Double(context.values.string("real").replacingOccurrences(of: ",", with: ".")) ?? 0
            guard real > 0 else { throw ToolError(MarkupKitStrings.Panel.needLength) }
            let scale = MeasureScale(pageDistance: line.points, realDistance: real, unit: unit(context.values))
            session.register(service.setScale(scale, in: document, page: line.page))
        default:
            break
        }
        return context.values
    }

    // MARK: Attach a file (archetype A)

    private func attachPanel(_ context: ToolContext) -> ToolPanel {
        let kind = context.values.string("kind", default: "file")
        let page = (context.document.flatMap { Services.viewer?.currentPage(in: $0) } ?? context.currentPage) + 1
        var controls: [ToolControl] = [.segmented(id: "kind", options: [ToolOption("file", MarkupKitStrings.Panel.file),
                                                                          ToolOption("voice", MarkupKitStrings.Panel.voiceNote)], selected: kind)]
        let ready: Bool
        if kind == "voice" {
            let documentID = context.document?.id
            controls.append(.custom(id: "recorder", make: { [weak self] in
                VoiceRecorderView { url in if let documentID { self?.recordings[documentID] = url } }
            }))
            ready = context.document.map { recordings[$0.id] != nil } ?? false
        } else {
            controls.append(.files(id: "file", label: MarkupKitStrings.Panel.fileLabel, types: [UTType.item.identifier], allowsMultiple: false))
            ready = !(context.values.files("file") + context.inputs).isEmpty
        }
        controls.append(.note(MarkupKitStrings.Panel.attachedTo(page: page)))
        return ToolPanel(.oneChoice, controls: controls,
                         primary: ToolButton(kind == "voice" ? MarkupKitStrings.Panel.attachVoiceNote : MarkupKitStrings.Panel.attachFile, isEnabled: ready),
                         output: .inPlace)
    }

    // MARK: Measure (archetype D)

    private static let mainUnits: [MeasureUnit] = [.mm, .cm, .m, .km, .inch, .ft, .mi]
    private static let otherUnits: [MeasureUnit] = [.yd, .pt, .pica]

    private func unit(_ values: ToolValues) -> MeasureUnit {
        if let other = MeasureUnit(rawValue: values.string("otherUnit")) { return other }
        return MeasureUnit(rawValue: values.string("unit")) ?? Defaults[.measureUnit]
    }

    private func measurePanel(_ context: ToolContext) -> ToolPanel {
        guard let document = context.document else { return ToolPanel(.mode, primary: ToolButton(Strings.Panel.done, isEnabled: false), secondary: nil) }
        let session = service.session(for: document)
        let kind = MeasureKind(rawValue: context.values.string("kind", default: MeasureKind.distance.rawValue)) ?? .distance
        if session.tool != .measure(kind) {
            session.setBarVisible(true)
            session.choose(.measure(kind))
        }
        let pageIndex = Services.viewer?.currentPage(in: document) ?? context.currentPage
        let scale = service.scale(in: document, page: pageIndex)
        let results: [ToolOption] = (document.pdf.page(at: pageIndex)?.annotations ?? []).compactMap { annotation in
            guard let measured = Measure.kind(of: annotation) else { return nil }
            return ToolOption(AnnotationLedger.id(of: annotation), measured.title, value: annotation.contents)
        }
        var controls: [ToolControl] = [
            .segmented(id: "kind", options: MeasureKind.allCases.map { ToolOption($0.rawValue, $0.title) }, selected: kind.rawValue),
            .text(id: "real", label: MarkupKitStrings.Panel.thisLineIs, placeholder: "10", value: "", isSecure: false),
            .popup(id: "unit", label: MarkupKitStrings.Panel.unit, options: Self.mainUnits.map { ToolOption($0.rawValue, $0.rawValue) },
                   selected: Self.mainUnits.contains(Defaults[.measureUnit]) ? Defaults[.measureUnit].rawValue : MeasureUnit.m.rawValue),
            .action(id: "setScale", title: MarkupKitStrings.Panel.setScale, isDestructive: false, symbol: "ruler"),
            .note(MarkupKitStrings.Panel.scale(Measure.ratio(scale))),
        ]
        controls.append(results.isEmpty ? .note(MarkupKitStrings.Panel.noMeasurements) : .list(results))
        return ToolPanel(.mode, controls: controls,
                         moreOptions: [.popup(id: "otherUnit", label: MarkupKitStrings.Panel.otherUnit,
                                              options: [ToolOption("", "—")] + Self.otherUnits.map { ToolOption($0.rawValue, $0.rawValue) }, selected: "")],
                         primary: ToolButton(Strings.Panel.done), secondary: nil, output: .inPlace)
    }

    // MARK: Run

    func run(_ request: ToolRequest, progress: ToolProgress) async throws -> ToolResult {
        guard let document = request.document else { return .none }
        switch request.tool {
        case .attachFile:
            let pageIndex = request.pages.first ?? Services.viewer?.currentPage(in: document) ?? 0
            guard let page = document.pdf.page(at: pageIndex) else { return .none }
            let file: URL?
            if request.values.string("kind", default: "file") == "voice" {
                file = recordings.removeValue(forKey: document.id)
            } else {
                file = (request.values.files("file") + request.inputs).first
            }
            guard let file else { return .none }
            let crop = page.bounds(for: .cropBox)
            let group = try service.attachFile(file, to: pageIndex, at: CGPoint(x: crop.minX + 24, y: crop.maxY - 24), in: document)
            return .inPlace(undoable: group, banner: nil)
        case .measure:
            Defaults[.measureUnit] = unit(request.values)
            service.existingSession(for: document)?.choose(.textSelection)
            return .none
        default:
            service.existingSession(for: document)?.choose(.textSelection)
            return .none
        }
    }
}
