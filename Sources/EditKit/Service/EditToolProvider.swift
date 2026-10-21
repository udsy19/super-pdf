import AppKit
import PDFKit
import PDFModelKit
import SuperPDFCore
import UniformTypeIdentifiers

/// EditKit's tiles (ux §4.1 Edit): Edit text & images (D), Headers & footers, Watermark, Bates numbering, Stamps and
/// Links (C), each with its live preview on the page and an in-place, undoable result.
@MainActor
final class EditToolProvider: ToolProviding {
    let service: EditService

    private var sessions: [UUID: EditModeSession] = [:]
    private var headerFields: [UUID: HeaderFields] = [:]
    private var linkAreas: [UUID: LinkArea] = [:]
    /// A line the last action left in the panel ("Made 3 links.", "Replaced 2 words.").
    private var notes: [UUID: String] = [:]
    private var scriptCounts: [UUID: (fingerprint: String, count: Int)] = [:]
    /// The page in view when the Stamps panel was last asked: the stamp goes where its preview showed it.
    private var stampPages: [UUID: Int] = [:]
    private var destinationNameCache: [UUID: (key: String, names: [String])] = [:]

    init(service: EditService) { self.service = service }

    var tools: [ToolID] { ToolCatalog.tiles(ownedBy: .editKit).map(\.id) }

    // MARK: Keys

    enum Key {
        static let tool = "tool", font = "font", size = "size", style = "style", colour = "colour", align = "align"
        static let find = "find", replace = "replace", matchCase = "matchCase", wholeWords = "wholeWords", picture = "picture"
        static let fields = "fields", margins = "margins", shrink = "shrink", replaceExisting = "replaceExisting", dateFormat = "dateFormat", startNumber = "startNumber"
        static let kind = "kind", text = "text", lightness = "lightness", angle = "angle", turn = "turn", scale = "scale", behind = "behind"
        static let position = "position", printOnly = "printOnly", screenOnly = "screenOnly"
        static let prefix = "prefix", suffix = "suffix", start = "start", digits = "digits", continueLast = "continueLast"
        static let stamp = "stamp", custom = "custom", opacity = "opacity", name = "name", everyPage = "everyPage"
        static let linkKind = "linkKind", page = "page", url = "url", file = "file", destination = "destination", area = "area"
    }

    enum Action {
        static let selectionChanged = "selectionChanged", removeScripts = "removeScripts", replaceAll = "replaceAll"
        static let flip = "flip", rotate = "rotate", replaceImage = "replaceImage", editIn = "editIn", deleteImage = "deleteImage"
        static let detect = "detect"
    }

    // MARK: Panels

    func panel(for tool: ToolID, context: ToolContext) -> ToolPanel {
        switch tool {
        case .editTextAndImages: editPanel(context)
        case .headersAndFooters: headersPanel(context)
        case .watermark: watermarkPanel(context)
        case .batesNumbering: batesPanel(context)
        case .stamps: stampsPanel(context)
        default: linksPanel(context)
        }
    }

    func preview(for tool: ToolID, context: ToolContext) async -> ToolPreview {
        guard let document = context.document else { return .none }
        switch tool {
        case .headersAndFooters:
            let header = Self.header(context)
            guard !header.fields.isEmpty else { return .none }
            return decorationOverlay(.headerFooter(header), context: context, document: document)
        case .watermark:
            guard let decoration = Self.watermark(context) else { return .none }
            return decorationOverlay(decoration, context: context, document: document)
        case .batesNumbering:
            return decorationOverlay(.bates(bates(context)), context: context, document: document)
        case .stamps:
            let (design, rect, rotation, opacity, name) = stamp(context)
            guard let rect else { return .none }
            let pages = Set(context.values.bool(Key.everyPage) ? Array(0..<document.pageCount) : [context.currentPage])
            let pdf = document.pdf
            return .overlay { page, cg in
                guard page.document === pdf, pages.contains(pdf.index(for: page)) else { return }
                StampWriter.preview(design, name: name, in: rect, rotation: rotation, opacity: opacity, cg: cg)
            }
        case .links:
            guard let area = linkAreas[document.id], let page = area.page, let rect = area.rect else { return .none }
            let pdf = document.pdf
            return .overlay { pdfPage, cg in
                guard pdfPage.document === pdf, pdf.index(for: pdfPage) == page else { return }
                cg.setFillColor(NSColor.controlAccentColor.withAlphaComponent(0.12).cgColor)
                cg.fill(rect)
                cg.setStrokeColor(NSColor.controlAccentColor.cgColor)
                cg.setLineWidth(1.5)
                cg.stroke(rect)
            }
        case .editTextAndImages:
            await refreshScriptCount(document)
            return .none
        default:
            return .none
        }
    }

    private func decorationOverlay(_ decoration: Decoration, context: ToolContext, document: DocumentHandle) -> ToolPreview {
        let pages = Set(scopePages(context))
        let pdf = document.pdf
        let decorationContext = EditService.context(for: document, bates: { if case .bates(let b) = decoration { b } else { nil } }())
        return .overlay { page, cg in
            guard page.document === pdf else { return }
            let index = pdf.index(for: page)
            guard pages.contains(index) else { return }
            DecorationPreview.draw(decoration, pageIndex: index, page: page, context: decorationContext, in: cg)
        }
    }

    func handle(action: String, context: ToolContext) async throws -> ToolValues {
        var values = context.values
        guard let document = context.document else { return values }
        switch (context.tool, action) {
        case (.headersAndFooters, HeaderFields.changedAction):
            if let store = headerFields[document.id] { values[Key.fields] = .strings(store.texts) }
        case (.headersAndFooters, ToolPanel.secondaryAction):
            try await applyInPlace(try await service.remove(.headerFooter, from: document), to: document)
            notes[document.id] = EditKitStrings.Headers.removed
        case (.watermark, ToolPanel.secondaryAction):
            let kinds = service.decorations(in: document)
            for kind in [DecorationKind.watermark, .background] where kinds.contains(kind) {
                try await applyInPlace(try await service.remove(kind, from: document), to: document)
            }
        case (.batesNumbering, ToolPanel.secondaryAction):
            try await applyInPlace(try await service.remove(.bates, from: document), to: document)
        case (.links, LinkArea.changedAction):
            if let area = linkAreas[document.id], let page = area.page, let rect = area.rect {
                let numbers: [Double] = [rect.minX, rect.minY, rect.width, rect.height]
                values[Key.area] = .strings([String(page)] + numbers.map { String($0) })
            }
        case (.links, Action.detect):
            let (count, undo) = LinkTools.detectLinks(in: document, pages: scopePages(context))
            if count > 0 { try await applyInPlace(undo, to: document) }
            notes[document.id] = EditKitStrings.Links.detected(count)
        case (.editTextAndImages, _):
            values = try await handleEdit(action: action, context: context, document: document)
        default:
            break
        }
        return values
    }

    func run(_ request: ToolRequest, progress: ToolProgress) async throws -> ToolResult {
        guard let document = request.document else { return .none }
        let values = request.values
        switch request.tool {
        case .editTextAndImages:
            sessions[document.id] = nil
            return .none
        case .headersAndFooters:
            let header = Self.header(values)
            guard !header.fields.isEmpty else { throw ToolError(EditKitStrings.Headers.nothingToAdd) }
            let group = try await service.apply(.headerFooter(header), to: request.pages, in: document, replacing: values.bool(Key.replaceExisting, default: true))
            return .inPlace(undoable: group, banner: nil)
        case .watermark:
            guard let decoration = Self.watermark(values) else {
                throw ToolError(values.string(Key.kind, default: "text") == "picture" ? EditKitStrings.Watermark.choosePicture : EditKitStrings.Watermark.typeSomething)
            }
            let group = try await service.apply(decoration, to: request.pages, in: document, replacing: true)
            return .inPlace(undoable: group, banner: nil)
        case .batesNumbering:
            let numbering = bates(values)
            let group = try await service.apply(.bates(numbering), to: request.pages, in: document, replacing: true)
            BatesContinuation.remember(numbering, pages: request.pages.count)
            return .inPlace(undoable: group, banner: nil)
        case .stamps:
            let current = stampPages[document.id] ?? request.pages.first ?? 0
            let (design, rect, rotation, opacity, name) = stamp(values, document: document, currentPage: current)
            guard let rect else { return .none }
            let pages = values.bool(Key.everyPage) ? Array(0..<document.pageCount) : [current]
            let group = try await EditEngine.edit(document, name: EditKitStrings.Undo.stamp) { model in
                for index in pages { if let page = model.page(at: index) { try StampWriter.add(design, name: name, in: rect, rotation: rotation, opacity: opacity, page: page) } }
            }
            return .inPlace(undoable: group, banner: nil)
        case .links:
            guard let (page, rect) = Self.area(values) else { throw ToolError(EditKitStrings.Links.noArea) }
            let target = try Self.linkTarget(values, document: document)
            guard let group = LinkTools.addLink(over: rect, page: page, to: target, in: document) else { return .none }
            linkAreas[document.id]?.rect = nil
            return .inPlace(undoable: group, banner: nil)
        default:
            return .none
        }
    }

    /// Applies an action's in-place edit (a removal, detected links) through DocumentKit, as a run would.
    private func applyInPlace(_ group: UndoGroup, to document: DocumentHandle) async throws {
        let work = SuperPDFPaths.ensure(SuperPDFPaths.work.appendingPathComponent(UUID().uuidString, isDirectory: true))
        let request = ToolRequest(tool: .editTextAndImages, document: document, source: EditSource.source(for: document), workFolder: work)
        try await Services.documents.apply(.inPlace(undoable: group, banner: nil), of: request)
    }

    private func scopePages(_ context: ToolContext) -> [Int] {
        guard let document = context.document else { return [] }
        return context.scope.pages(count: document.pageCount, current: context.currentPage)
    }

    // MARK: Edit text & images (D)

    func session(for document: DocumentHandle) -> EditModeSession {
        if let session = sessions[document.id] { return session }
        let session = EditModeSession(document: document)
        session.onChange = { [weak self] in self?.selectionChanged(in: document) }
        sessions[document.id] = session
        return session
    }

    private func selectionChanged(in document: DocumentHandle) {
        NotificationCenter.default.post(name: ToolPanel.performActionNotification, object: document, userInfo: [ToolPanel.actionKey: Action.selectionChanged])
    }

    private func editPanel(_ context: ToolContext) -> ToolPanel {
        guard let document = context.document else { return ToolPanel(.mode, primary: ToolButton(Strings.Panel.done)) }
        let session = self.session(for: document)
        let v = context.values
        let toolChoice = Tool(rawValue: v.string(Key.tool, default: "select")) ?? .select
        session.tool = EditModeSession.Tool(rawValue: toolChoice.rawValue) ?? .select
        if session.tool == .addImage { session.pendingImage = v.files(Key.picture).first }
        var controls: [ToolControl] = [
            .segmented(id: Key.tool, options: [ToolOption("select", EditKitStrings.Edit.select), ToolOption("addText", EditKitStrings.Edit.addText),
                                               ToolOption("addImage", EditKitStrings.Edit.addImage), ToolOption("find", EditKitStrings.Edit.findReplace)],
                       selected: "select"),
            .custom(id: "mode", make: { [session] in EditModePalette(session: session) }),
        ]
        var more: [ToolControl] = []
        switch toolChoice {
        case .select:
            if let block = session.block() {
                controls += propertiesStrip(for: block, session: session, values: v)
                if !block.isEditable { controls.append(.note(EditKitStrings.Edit.notEditable)) } else if session.selectedBlockNeedsSubstitute {
                    controls.append(.note(EditKitStrings.Edit.fontsSubstituted))
                } else {
                    controls.append(.note(EditKitStrings.Edit.blockSelected))
                }
            } else if session.image() != nil {
                controls += [
                    .note(EditKitStrings.Edit.imageSelected),
                    .action(id: Action.flip, title: EditKitStrings.Edit.flipHorizontal, isDestructive: false, symbol: "arrow.left.and.right.righttriangle.left.righttriangle.right"),
                    .action(id: Action.rotate, title: EditKitStrings.Edit.rotate, isDestructive: false, symbol: "rotate.right"),
                    .action(id: Action.replaceImage, title: EditKitStrings.Edit.replaceImage, isDestructive: false, symbol: "photo"),
                    .action(id: Action.editIn, title: EditKitStrings.Edit.editIn, isDestructive: false, symbol: "arrow.up.forward.app"),
                    .action(id: Action.deleteImage, title: EditKitStrings.Edit.deleteImage, isDestructive: true, symbol: "trash"),
                ]
            } else {
                controls.append(.note(EditKitStrings.Edit.selectNote))
            }
        case .addText:
            controls.append(.note(EditKitStrings.Edit.addTextNote))
        case .addImage:
            controls.append(.files(id: Key.picture, label: EditKitStrings.Edit.pictureLabel, types: Self.imageTypes, allowsMultiple: false))
            controls.append(.note(EditKitStrings.Edit.addImageNote))
        case .find:
            controls += [
                .text(id: Key.find, label: EditKitStrings.Edit.find, placeholder: "", value: "", isSecure: false),
                .text(id: Key.replace, label: EditKitStrings.Edit.replaceWith, placeholder: "", value: "", isSecure: false),
                .action(id: Action.replaceAll, title: EditKitStrings.Edit.replaceAll, isDestructive: false, symbol: "arrow.triangle.2.circlepath"),
            ]
            more += [.toggle(id: Key.matchCase, label: EditKitStrings.Edit.matchCase, isOn: false), .toggle(id: Key.wholeWords, label: EditKitStrings.Edit.wholeWords, isOn: false)]
        }
        if let note = notes[document.id] { controls.append(.note(note)) }
        if let substitution = session.lastSubstitution { controls.append(.note(Strings.Errors.fontMissing(substitution.from, substitute: substitution.to))) }
        var message: ToolMessage?
        if let count = scriptCounts[document.id], count.fingerprint == EditSource.current(for: document).key, count.count > 0 {
            message = ToolMessage(.warning, EditKitStrings.Edit.scriptsFound, action: ToolOption(Action.removeScripts, EditKitStrings.Edit.removeScripts))
        }
        return ToolPanel(.mode, hint: EditKitStrings.Edit.hint, controls: controls, moreOptions: more, primary: ToolButton(Strings.Panel.done), secondary: nil,
                         message: message)
    }

    private enum Tool: String { case select, addText, addImage, find }

    static let imageTypes = ["public.png", "public.jpeg", "public.tiff", "public.heic", "com.compuserve.gif", "com.microsoft.bmp", "org.webmproject.webp"]

    /// Font, size, bold/italic, colour and alignment of the selected block; the values drive `pendingStyle`.
    private func propertiesStrip(for block: TextBlock, session: EditModeSession, values v: ToolValues) -> [ToolControl] {
        let facts = block.style.font.facts
        let ownFamily = FontMatcher.match(facts, size: 12).font.familyName ?? facts.familyName
        var families = ["Helvetica", "Times New Roman", "Georgia", "Courier New", "Avenir Next", "Verdana"]
        if !families.contains(ownFamily) { families.insert(ownFamily, at: 0) }
        families = Array(families.prefix(7))
        let ownSize = (block.style.pageFontSize * 2).rounded() / 2
        let ownStyle = [facts.isBold ? "bold" : nil, facts.isItalic ? "italic" : nil].compactMap { $0 }
        let ownColour = block.style.colorHex ?? "#000000"
        var colours = EditKitStrings.colourChoices.map { ToolOption($0.id, $0.title) }
        if !colours.contains(where: { $0.id.caseInsensitiveCompare(ownColour) == .orderedSame }) { colours.insert(ToolOption(ownColour, ownColour), at: 0) }
        colours = Array(colours.prefix(7))
        // What the values say, against the block's own: only differences become pending style.
        var style = EditModeSession.Style()
        let family = v.string(Key.font, default: ownFamily)
        if family != ownFamily { style.fontFamily = family }
        let size = v.double(Key.size, default: ownSize)
        if abs(size - ownSize) > 0.01 { style.size = size }
        let chosenStyle = v[Key.style].map { _ in v.strings(Key.style) } ?? ownStyle
        if chosenStyle.contains("bold") != facts.isBold { style.bold = chosenStyle.contains("bold") }
        if chosenStyle.contains("italic") != facts.isItalic { style.italic = chosenStyle.contains("italic") }
        let colour = v.string(Key.colour, default: ownColour)
        if colour.caseInsensitiveCompare(ownColour) != .orderedSame { style.color = colour }
        let align = v.string(Key.align, default: block.alignment.rawValue)
        if let alignment = TextAlignment(rawValue: align), alignment != block.alignment { style.alignment = alignment }
        session.pendingStyle = style
        return [
            .popup(id: Key.font, label: EditKitStrings.Edit.font, options: families.map { ToolOption($0, $0) }, selected: ownFamily),
            .stepper(id: Key.size, label: EditKitStrings.Edit.size, range: 4...144, value: Int(ownSize.rounded())),
            .chips(id: Key.style, options: [ToolOption("bold", EditKitStrings.Edit.bold), ToolOption("italic", EditKitStrings.Edit.italic)], selected: ownStyle, allowsMultiple: true),
            .popup(id: Key.colour, label: EditKitStrings.Edit.colour, options: colours, selected: colours.first { $0.id.caseInsensitiveCompare(ownColour) == .orderedSame }?.id ?? ownColour),
            .segmented(id: Key.align, label: EditKitStrings.Edit.alignment, options: [
                ToolOption("left", EditKitStrings.Edit.alignLeft), ToolOption("center", EditKitStrings.Edit.alignCenter),
                ToolOption("right", EditKitStrings.Edit.alignRight), ToolOption("justified", EditKitStrings.Edit.alignJustified),
            ], selected: block.alignment.rawValue),
        ]
    }

    private func handleEdit(action: String, context: ToolContext, document: DocumentHandle) async throws -> ToolValues {
        var values = context.values
        let session = self.session(for: document)
        switch action {
        case Action.selectionChanged:
            // A new selection starts the strip from the block's own look.
            for key in [Key.font, Key.size, Key.style, Key.colour, Key.align] { values[key] = nil }
            if session.selection == nil { notes[document.id] = nil }
        case Action.removeScripts:
            try await session.removeScripts()
            scriptCounts[document.id] = nil
            notes[document.id] = EditKitStrings.Edit.scriptsRemoved
        case Action.replaceAll:
            let find = values.string(Key.find)
            guard !find.isEmpty else { notes[document.id] = EditKitStrings.Edit.nothingFound; return values }
            let options = FindReplaceOptions(matchCase: values.bool(Key.matchCase), wholeWords: values.bool(Key.wholeWords))
            let report = try await session.replaceAll(find, with: values.string(Key.replace), options: options, pages: scopePages(context))
            notes[document.id] = report.replaced == 0 && report.notFitting == 0 ? EditKitStrings.Edit.nothingFound : EditKitStrings.Edit.replaced(report.replaced, notFitting: report.notFitting)
        case Action.flip:
            try await session.flipImage()
        case Action.rotate:
            try await session.rotateImage(by: -90)
        case Action.deleteImage:
            try await session.deleteSelection()
        case Action.replaceImage:
            if let file = await chooseImage() { try await session.replaceImage(with: file) }
        case Action.editIn:
            try editElsewhere(session)
        default:
            break
        }
        return values
    }

    /// Asks for a picture (the Replace sheet). Replaced by the self-test.
    var chooseImage: @MainActor () async -> URL? = {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = EditToolProvider.imageTypes.compactMap { UTType($0) }
        panel.allowsMultipleSelection = false
        return panel.runModal() == .OK ? panel.url : nil
    }

    /// Opens the picture in the app the person uses for pictures; when the file changes, the page takes it back
    /// (features #61 "Edit in…"). Replaced by the self-test.
    var openForEditing: @MainActor (URL) -> Void = { url in NSWorkspace.shared.open(url) }

    private var watchers: [UUID: DispatchSourceFileSystemObject] = [:]

    private func editElsewhere(_ session: EditModeSession) throws {
        let folder = SuperPDFPaths.ensure(SuperPDFPaths.work.appendingPathComponent("edit-in-\(UUID().uuidString)", isDirectory: true))
        guard let file = try session.exportImage(to: folder) else { return }
        let descriptor = open(file.path, O_EVTONLY)
        guard descriptor >= 0 else { openForEditing(file); return }
        let source = DispatchSource.makeFileSystemObjectSource(fileDescriptor: descriptor, eventMask: [.write, .rename, .extend], queue: .main)
        source.setEventHandler { [weak session] in
            guard let session else { return }
            Task { @MainActor in try? await session.replaceImage(with: file) }
        }
        source.setCancelHandler { close(descriptor) }
        source.resume()
        watchers[session.document.id]?.cancel()
        watchers[session.document.id] = source
        openForEditing(file)
    }

    private func refreshScriptCount(_ document: DocumentHandle) async {
        let fingerprint = EditSource.current(for: document).key
        guard scriptCounts[document.id]?.fingerprint != fingerprint else { return }
        let count = (try? await service.scripts(in: document).count) ?? 0
        scriptCounts[document.id] = (fingerprint, count)
    }

    // MARK: Headers & footers (C)

    private func headersPanel(_ context: ToolContext) -> ToolPanel {
        let v = context.values
        var controls: [ToolControl] = []
        if let document = context.document {
            let texts = v.strings(Key.fields)
            controls.append(.custom(id: Key.fields, make: { [weak self] in
                let store = HeaderFields(document: document, texts: texts)
                self?.headerFields[document.id] = store
                return HeaderFieldsView(store: store)
            }))
        }
        controls += [
            .popup(id: Key.font, label: EditKitStrings.Headers.font, options: EditKitStrings.fontChoices.map { ToolOption($0.id, $0.title) }, selected: "Helvetica"),
            .stepper(id: Key.size, label: EditKitStrings.Headers.size, range: 6...36, value: 10),
        ]
        let more: [ToolControl] = [
            .stepper(id: Key.margins, label: EditKitStrings.Headers.margins, range: 12...144, value: 36),
            .toggle(id: Key.shrink, label: EditKitStrings.Headers.shrink, isOn: false),
            .toggle(id: Key.replaceExisting, label: EditKitStrings.Headers.replace, isOn: true),
            .popup(id: Key.dateFormat, label: EditKitStrings.Headers.dateFormat, options: EditKitStrings.dateFormats.map { ToolOption($0.id, $0.title) }, selected: "d MMMM yyyy"),
            .stepper(id: Key.startNumber, label: EditKitStrings.Headers.startNumber, range: 1...99_999, value: 1),
        ]
        if let document = context.document, let note = notes[document.id] { controls.append(.note(note)) }
        let hasFields = !Self.header(v).fields.isEmpty
        let exists = context.document.map { service.decorations(in: $0).contains(.headerFooter) } ?? false
        return ToolPanel(.livePreview, hint: EditKitStrings.Headers.hint, showsScope: true, controls: controls, moreOptions: more,
                         primary: ToolButton(EditKitStrings.Headers.add, isEnabled: hasFields),
                         secondary: exists ? ToolButton(EditKitStrings.Headers.remove, isDestructive: true) : ToolButton(Strings.Panel.cancel))
    }

    static func header(_ context: ToolContext) -> HeaderFooter { header(context.values) }

    static func header(_ v: ToolValues) -> HeaderFooter {
        HeaderFooter(fields: HeaderFields.fields(from: v.strings(Key.fields)),
                     style: DecorationStyle(fontName: v.string(Key.font, default: "Helvetica"), fontSize: Double(v.int(Key.size, default: 10)), color: "#000000"),
                     margins: Double(v.int(Key.margins, default: 36)), shrinkPage: v.bool(Key.shrink), dateFormat: v.string(Key.dateFormat, default: "d MMMM yyyy"),
                     startNumber: v.int(Key.startNumber, default: 1))
    }

    // MARK: Watermark (C)

    private func watermarkPanel(_ context: ToolContext) -> ToolPanel {
        let v = context.values
        let kind = v.string(Key.kind, default: "text")
        var controls: [ToolControl] = [
            .segmented(id: Key.kind, options: [ToolOption("text", EditKitStrings.Watermark.text), ToolOption("picture", EditKitStrings.Watermark.picture),
                                               ToolOption("colour", EditKitStrings.Watermark.colour)], selected: "text"),
        ]
        switch kind {
        case "picture":
            controls.append(.files(id: Key.picture, label: EditKitStrings.Watermark.pictureLabel, types: Self.imageTypes + ["com.adobe.pdf"], allowsMultiple: false))
        case "colour":
            controls.append(.popup(id: Key.colour, label: EditKitStrings.Watermark.colourLabel, options: EditKitStrings.backgroundColours.map { ToolOption($0.id, $0.title) }, selected: "#FFF2CC"))
        default:
            controls.append(.text(id: Key.text, label: nil, placeholder: EditKitStrings.Watermark.textPlaceholder, value: EditKitStrings.Watermark.textPlaceholder, isSecure: false))
        }
        if kind != "colour" {
            controls.append(.slider(id: Key.lightness, label: EditKitStrings.Watermark.lightness, range: 5...100, step: 1, value: 30, format: .percent))
            controls.append(.popup(id: Key.angle, label: EditKitStrings.Watermark.angle, options: [
                ToolOption("diagonal", EditKitStrings.Watermark.diagonal), ToolOption("straight", EditKitStrings.Watermark.straight), ToolOption("custom", EditKitStrings.Watermark.custom),
            ], selected: "diagonal"))
            if v.string(Key.angle, default: "diagonal") == "custom" {
                controls.append(.slider(id: Key.turn, label: EditKitStrings.Watermark.customAngle, range: -90...90, step: 1, value: 30, format: .degrees))
            }
        }
        var more: [ToolControl] = []
        if kind == "text" {
            more += [
                .popup(id: Key.font, label: EditKitStrings.Watermark.font, options: EditKitStrings.fontChoices.map { ToolOption($0.id, $0.title) }, selected: "Helvetica-Bold"),
                .popup(id: "textColour", label: EditKitStrings.Watermark.colourLabel, options: EditKitStrings.colourChoices.map { ToolOption($0.id, $0.title) }, selected: "#555555"),
            ]
        }
        if kind != "colour" {
            more += [
                .slider(id: Key.scale, label: EditKitStrings.Watermark.size, range: 10...100, step: 1, value: 50, format: .percent),
                .toggle(id: Key.behind, label: EditKitStrings.Watermark.behind, isOn: false),
                .positionGrid(id: Key.position, columns: 3, rows: 3, selected: 4),
                .toggle(id: Key.printOnly, label: EditKitStrings.Watermark.printOnly, isOn: false),
                .toggle(id: Key.screenOnly, label: EditKitStrings.Watermark.screenOnly, isOn: false),
            ]
        }
        controls.append(.note(EditKitStrings.Watermark.dragNote))
        let kinds = context.document.map { service.decorations(in: $0) } ?? []
        let exists = kinds.contains(.watermark) || kinds.contains(.background)
        let primaryTitle = kind == "colour" ? EditKitStrings.Watermark.addBackground : EditKitStrings.Watermark.add
        let removeTitle = kinds.contains(.watermark) ? EditKitStrings.Watermark.remove : EditKitStrings.Watermark.removeBackground
        return ToolPanel(.livePreview, hint: EditKitStrings.Watermark.hint, showsScope: true, controls: controls, moreOptions: more,
                         primary: ToolButton(primaryTitle, isEnabled: Self.watermark(v) != nil),
                         secondary: exists ? ToolButton(removeTitle, isDestructive: true) : ToolButton(Strings.Panel.cancel))
    }

    static func watermark(_ context: ToolContext) -> Decoration? { watermark(context.values) }

    /// The decoration the values describe; nil when there is nothing to show yet.
    static func watermark(_ v: ToolValues) -> Decoration? {
        let kind = v.string(Key.kind, default: "text")
        let content: DecorationContent
        switch kind {
        case "picture":
            guard let file = v.files(Key.picture).first else { return nil }
            content = .file(file)
        case "colour":
            content = .color(v.string(Key.colour, default: "#FFF2CC"))
        default:
            let text = v.string(Key.text, default: EditKitStrings.Watermark.textPlaceholder).trimmingCharacters(in: .whitespacesAndNewlines)
            guard !text.isEmpty else { return nil }
            content = .text(text, DecorationStyle(fontName: v.string(Key.font, default: "Helvetica-Bold"), fontSize: 48, color: v.string("textColour", default: "#555555")))
        }
        let rotation: Double = switch v.string(Key.angle, default: "diagonal") {
        case "straight": 0
        case "custom": v.double(Key.turn, default: 30)
        default: 45
        }
        let visibility: Watermark.Visibility = v.bool(Key.printOnly) ? .printOnly : v.bool(Key.screenOnly) ? .screenOnly : .always
        let watermark = Watermark(content: content, opacity: kind == "colour" ? 1 : v.double(Key.lightness, default: 30) / 100, rotation: rotation,
                                  position: PagePosition(rawValue: v.int(Key.position, default: 4)) ?? .center, scale: v.double(Key.scale, default: 50) / 100,
                                  layer: v.bool(Key.behind) ? .behind : .over, visibility: visibility)
        return kind == "colour" ? .background(watermark) : .watermark(watermark)
    }

    // MARK: Bates (C)

    private func batesPanel(_ context: ToolContext) -> ToolPanel {
        let v = context.values
        let numbering = bates(v)
        var controls: [ToolControl] = [
            .text(id: Key.prefix, label: EditKitStrings.Bates.prefix, placeholder: "ABC", value: "", isSecure: false),
            .stepper(id: Key.start, label: EditKitStrings.Bates.start, range: 1...999_999_999, value: 1),
            .positionGrid(id: Key.position, columns: 3, rows: 2, selected: 5),
            .note(EditKitStrings.Bates.example(numbering.label(numbering.start))),
        ]
        if v.bool(Key.continueLast) { controls.append(.note(EditKitStrings.Bates.next(numbering.start))) }
        let more: [ToolControl] = [
            .text(id: Key.suffix, label: EditKitStrings.Bates.suffix, placeholder: "", value: "", isSecure: false),
            .stepper(id: Key.digits, label: EditKitStrings.Bates.digits, range: 3...10, value: 6),
            .toggle(id: Key.continueLast, label: EditKitStrings.Bates.continueLast, isOn: false),
            .popup(id: Key.font, label: EditKitStrings.Bates.font, options: EditKitStrings.fontChoices.map { ToolOption($0.id, $0.title) }, selected: "Helvetica"),
            .stepper(id: Key.size, label: EditKitStrings.Bates.size, range: 6...36, value: 10),
        ]
        let exists = context.document.map { service.decorations(in: $0).contains(.bates) } ?? false
        return ToolPanel(.livePreview, hint: EditKitStrings.Bates.hint, showsScope: true, controls: controls, moreOptions: more,
                         primary: ToolButton(EditKitStrings.Bates.add),
                         secondary: exists ? ToolButton(EditKitStrings.Bates.remove, isDestructive: true) : ToolButton(Strings.Panel.cancel))
    }

    func bates(_ context: ToolContext) -> BatesNumbering { bates(context.values) }

    /// The numbering the values describe; "carry on from the last file" takes the remembered next number.
    func bates(_ v: ToolValues) -> BatesNumbering {
        let grid = v.int(Key.position, default: 5)
        let position: PagePosition = grid < 3 ? (PagePosition(rawValue: grid) ?? .topRight) : (PagePosition(rawValue: grid + 3) ?? .bottomRight)
        var numbering = BatesNumbering(prefix: v.string(Key.prefix), suffix: v.string(Key.suffix), start: v.int(Key.start, default: 1),
                                       digits: v.int(Key.digits, default: 6), position: position,
                                       style: DecorationStyle(fontName: v.string(Key.font, default: "Helvetica"), fontSize: Double(v.int(Key.size, default: 10))))
        if v.bool(Key.continueLast) { numbering.start = BatesContinuation.remembered(for: numbering) }
        return numbering
    }

    // MARK: Stamps (C)

    private func stampsPanel(_ context: ToolContext) -> ToolPanel {
        let controls: [ToolControl] = [
            .chips(id: Key.stamp, options: StampDesign.standard.map { ToolOption($0.id, EditKitStrings.Stamps.title($0)) }, selected: ["approved"], allowsMultiple: false),
            .positionGrid(id: Key.position, columns: 3, rows: 3, selected: 4),
            .slider(id: Key.size, label: EditKitStrings.Stamps.size, range: 10...100, step: 1, value: 35, format: .percent),
            .note(EditKitStrings.Stamps.dragNote),
        ]
        let more: [ToolControl] = [
            .files(id: Key.custom, label: EditKitStrings.Stamps.custom, types: Self.imageTypes + ["com.adobe.pdf"], allowsMultiple: false),
            .slider(id: Key.turn, label: EditKitStrings.Stamps.turn, range: -45...45, step: 1, value: 0, format: .degrees),
            .slider(id: Key.opacity, label: EditKitStrings.Stamps.opacity, range: 20...100, step: 1, value: 100, format: .percent),
            .text(id: Key.name, label: EditKitStrings.Stamps.name, placeholder: NSFullUserName(), value: Self.defaultName, isSecure: false),
            .toggle(id: Key.everyPage, label: EditKitStrings.Stamps.everyPage, isOn: false),
        ]
        if let document = context.document { stampPages[document.id] = context.currentPage }
        return ToolPanel(.livePreview, hint: EditKitStrings.Stamps.hint, controls: controls, moreOptions: more, primary: ToolButton(EditKitStrings.Stamps.add))
    }

    static var defaultName: String { Defaults[.authorName].isEmpty ? NSFullUserName() : Defaults[.authorName] }

    func stamp(_ context: ToolContext) -> (StampDesign, CGRect?, Double, Double, String) {
        guard let document = context.document else { return (StampDesign.standard[0], nil, 0, 1, Self.defaultName) }
        return stamp(context.values, document: document, currentPage: context.currentPage)
    }

    /// The stamp the values describe and where it goes on the page (the grid spot, `size` % of the page width wide).
    func stamp(_ v: ToolValues, document: DocumentHandle, currentPage: Int) -> (StampDesign, CGRect?, Double, Double, String) {
        var design = StampDesign.standard.first { $0.id == v.strings(Key.stamp).first } ?? StampDesign.standard[0]
        if let file = v.files(Key.custom).first { design = StampDesign(id: "custom", text: file.deletingPathExtension().lastPathComponent, file: file) }
        let name = v.string(Key.name, default: Self.defaultName)
        guard let page = document.pdf.page(at: currentPage) else { return (design, nil, 0, 1, name) }
        let bounds = page.bounds(for: .cropBox)
        let shown = page.rotation % 180 == 0 ? bounds.size : CGSize(width: bounds.height, height: bounds.width)
        let natural = StampWriter.naturalSize(design, name: name)
        let width = min(shown.width * v.double(Key.size, default: 35) / 100, shown.width - 72)
        let size = CGSize(width: width, height: width * natural.height / max(natural.width, 1))
        let margins = 36.0
        let grid = v.int(Key.position, default: 4)
        let column = grid % 3, row = grid / 3
        let x: Double = column == 0 ? margins : column == 1 ? (shown.width - size.width) / 2 : shown.width - margins - size.width
        let y: Double = row == 0 ? shown.height - margins - size.height : row == 1 ? (shown.height - size.height) / 2 : margins
        // Into page space (the page may be rotated).
        let display = PDFModelKitCompat.displayTransform(box: CGRect(origin: .zero, size: bounds.size), rotation: ((page.rotation % 360) + 360) % 360)
        var rect = CGRect(x: x, y: y, width: size.width, height: size.height).applying(display.inverted())
        rect.origin.x += bounds.minX; rect.origin.y += bounds.minY
        return (design, rect, v.double(Key.turn, default: 0), v.double(Key.opacity, default: 100) / 100, name)
    }

    // MARK: Links (C)

    private func linksPanel(_ context: ToolContext) -> ToolPanel {
        let v = context.values
        let kind = v.string(Key.linkKind, default: "page")
        var controls: [ToolControl] = [
            .segmented(id: Key.linkKind, label: nil, options: [ToolOption("page", EditKitStrings.Links.goToPage), ToolOption("web", EditKitStrings.Links.web),
                                                               ToolOption("file", EditKitStrings.Links.file)], selected: "page"),
        ]
        let pageCount = max(context.document?.pageCount ?? 1, 1)
        switch kind {
        case "web":
            controls.append(.text(id: Key.url, label: EditKitStrings.Links.url, placeholder: EditKitStrings.Links.urlPlaceholder, value: "", isSecure: false))
        case "file":
            controls.append(.files(id: Key.file, label: EditKitStrings.Links.fileLabel, types: ["public.item"], allowsMultiple: false))
        default:
            controls.append(.stepper(id: Key.page, label: EditKitStrings.Links.page, range: 1...pageCount, value: min(context.currentPage + 1, pageCount)))
            if let document = context.document {
                let names = destinationNames(in: document)
                if !names.isEmpty, names.count <= 6 {
                    controls.append(.popup(id: Key.destination, label: EditKitStrings.Links.destination, options: [ToolOption("", "—")] + names.map { ToolOption($0, $0) }, selected: ""))
                }
            }
        }
        if let document = context.document {
            controls.append(.custom(id: Key.area, make: { [weak self] in
                let area = self?.linkAreas[document.id] ?? LinkArea(document: document)
                self?.linkAreas[document.id] = area
                return LinkDrawingPalette(area: area)
            }))
            if let (page, _) = Self.area(v) { controls.append(.note(EditKitStrings.Links.area(page: page))) }
            controls.append(.action(id: Action.detect, title: EditKitStrings.Links.detect, isDestructive: false, symbol: "link.badge.plus"))
            if let note = notes[document.id] { controls.append(.note(note)) }
        }
        let ready = Self.area(v) != nil && (context.document.map { (try? Self.linkTarget(v, document: $0)) != nil } ?? false)
        return ToolPanel(.livePreview, hint: EditKitStrings.Links.hint, showsScope: false, controls: controls, primary: ToolButton(EditKitStrings.Links.add, isEnabled: ready))
    }

    /// The document's named places, read once per version of its bytes (the panel is asked on every change).
    private func destinationNames(in document: DocumentHandle) -> [String] {
        let (source, key) = EditSource.current(for: document)
        if let cached = destinationNameCache[document.id], cached.key == key { return cached.names }
        let names = (try? PDFModel(source)).map { NamedDestinations.read(from: $0).map(\.name) } ?? []
        destinationNameCache[document.id] = (key, names)
        return names
    }

    /// The self-test's way in for the grid and the drawn box (the views post the same actions).
    func testSetHeaderFields(_ fields: HeaderFields) { headerFields[fields.document.id] = fields }
    func testSetLinkArea(page: Int, rect: CGRect, in document: DocumentHandle) {
        let area = linkAreas[document.id] ?? LinkArea(document: document)
        area.page = page; area.rect = rect
        linkAreas[document.id] = area
    }

    static func area(_ v: ToolValues) -> (page: Int, rect: CGRect)? {
        let parts = v.strings(Key.area)
        guard parts.count == 5, let page = Int(parts[0]), let x = Double(parts[1]), let y = Double(parts[2]), let w = Double(parts[3]), let h = Double(parts[4]) else { return nil }
        return (page, CGRect(x: x, y: y, width: w, height: h))
    }

    static func linkTarget(_ v: ToolValues, document: DocumentHandle) throws -> LinkTarget {
        switch v.string(Key.linkKind, default: "page") {
        case "web":
            guard let url = LinkTools.url(from: v.string(Key.url)) else { throw ToolError(EditKitStrings.Links.badURL) }
            return .url(url)
        case "file":
            guard let file = v.files(Key.file).first else { throw ToolError(EditKitStrings.Links.chooseFile) }
            return .file(file)
        default:
            let destination = v.string(Key.destination)
            if !destination.isEmpty { return .destination(destination) }
            return .page(min(max(v.int(Key.page, default: 1) - 1, 0), max(document.pageCount - 1, 0)))
        }
    }
}
