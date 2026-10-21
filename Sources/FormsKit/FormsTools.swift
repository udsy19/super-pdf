import AppKit
import PDFKit
import SuperPDFCore
import UniformTypeIdentifiers

/// FormsKit's tiles (ux §5.3): Fill a form and Make a form, both mode panels (D) whose document becomes interactive.
/// Clicks on the page reach the panel through `ToolPanel.performActionNotification` (`FormsPlacement`); flattening
/// ("Lock in notes & fields") is ProtectKit's.
@MainActor
final class FormsTools: ToolProviding {
    let service: FormService
    let contactCard: any ContactCardReading
    /// Where "Save the answers as a file…" writes and where "Fill in from a file…" reads; nil cancels. Panels by default.
    var chooseSaveURL: @MainActor (_ proposed: String, _ type: UTType) -> URL? = FormsTools.savePanel
    var chooseOpenURL: @MainActor () -> URL? = FormsTools.openPanel

    /// "Find fields for me" candidates per document, for the PDFKit document they were found on.
    private var candidates: [UUID: (pdf: ObjectIdentifier, fields: [FormField])] = [:]
    /// The fields clicked in "Set tab order" mode, in order.
    private var tabSequence: [UUID: [String]] = [:]
    /// The values of each document's open forms panel, for the page clicks.
    private(set) var modes: [UUID: (tool: ToolID, values: ToolValues)] = [:]

    init(service: FormService, contactCard: any ContactCardReading) {
        self.service = service
        self.contactCard = contactCard
    }

    var tools: [ToolID] { ToolCatalog.tiles(ownedBy: .formsKit).map(\.id) }

    enum Key {
        static let notice = "notice", anywhere = "anywhere", place = "place", dataFormat = "dataFormat"
        static let kind = "kind", selected = "selected", tabOrder = "tabOrder"
        static let name = "name:", required = "required:", defaultValue = "default:", format = "format:", calculate = "calc:"
        static let calculateFrom = "calcFrom:", choices = "choices:"
        static let properties = [name, required, defaultValue, format, calculate, calculateFrom, choices]
    }

    enum Action {
        static let autoFill = "forms.autofill", clear = "forms.clear", fillAnywhere = "forms.anywhere"
        static let saveData = "forms.saveData", loadData = "forms.loadData"
        static let detect = "forms.detect", remove = "forms.remove"
        /// Values changed on the page (FormWatcher).
        static let refresh = "forms.refresh"
        /// "forms.click|<page>|<x>|<y>" in page space (FormsPlacement).
        static let click = "forms.click"

        static func click(page: Int, at point: CGPoint) -> String { "\(click)|\(page)|\(point.x)|\(point.y)" }
    }

    // MARK: Panels

    func panel(for tool: ToolID, context: ToolContext) -> ToolPanel {
        if let document = context.document { modes[document.id] = (tool, context.values) }
        switch tool {
        case .fillForm: return fillPanel(context)
        case .makeForm: return makePanel(context)
        default: return ToolPanel(.mode, primary: ToolButton(Strings.Panel.done), secondary: nil)
        }
    }

    private func fillPanel(_ context: ToolContext) -> ToolPanel {
        guard let document = context.document else { return ToolPanel(.mode, primary: ToolButton(Strings.Panel.done), secondary: nil) }
        if service.isXFA(document) {
            return ToolPanel(.mode, primary: ToolButton(Strings.Panel.done), secondary: nil, message: ToolMessage(.info, Strings.Errors.xfaForm))
        }
        let fields = service.fields(in: document).filter { ![.button, .signature, .image].contains($0.kind) }
        var controls: [ToolControl] = []
        if !fields.isEmpty {
            let revision = service.revisions[document.id] ?? 0
            let rows = fields.map { field -> ToolOption in
                let shown = [.checkbox, .radioGroup].contains(field.kind) ? nil : (field.value.isEmpty ? nil : String(field.value.prefix(28)))
                return ToolOption(field.id, field.tooltip.isEmpty ? field.id : field.tooltip, value: shown)
            }
            let filled = fields.filter { !$0.value.isEmpty && $0.value != "Off" }.map(\.id)
            controls.append(.action(id: Action.autoFill, title: FormsStrings.autoFill, isDestructive: false, symbol: "person.crop.circle"))
            // The list follows the values: its id changes with them, so ticks are always what the form holds.
            controls.append(.checklist(id: "fields.\(revision)", items: rows, selected: filled))
            controls.append(.action(id: Action.clear, title: FormsStrings.clearForm, isDestructive: false))
        }
        let anywhere = context.values.bool(Key.anywhere)
        if anywhere {
            controls.append(.chips(id: Key.place, options: [ToolOption("text", FormsStrings.placeText, symbol: "character.cursor.ibeam"),
                                                            ToolOption("tick", FormsStrings.placeTick, symbol: "checkmark")],
                                   selected: ["text"], allowsMultiple: false))
        }
        if anywhere || !fields.isEmpty {
            controls.append(.custom(id: "forms.fill.placement", make: { [weak self] in
                FormsPlacement(document: document, tools: self, hint: nil)
            }))
        }
        let formats: [FormDataFormat] = [.xfdf, .fdf, .csv, .json]
        let more: [ToolControl] = fields.isEmpty ? [] : [
            .popup(id: Key.dataFormat, label: FormsStrings.dataFormat, options: formats.map { ToolOption($0.rawValue, $0.rawValue.uppercased()) },
                   selected: FormDataFormat.xfdf.rawValue),
            .action(id: Action.saveData, title: FormsStrings.saveData, isDestructive: false, symbol: "square.and.arrow.down"),
            .action(id: Action.loadData, title: FormsStrings.loadData, isDestructive: false, symbol: "square.and.arrow.up"),
        ]
        let pageHasFields = service.widgets(of: document.pdf).contains { $0.widgets.contains { $0.page == context.currentPage } }
        let message: ToolMessage? = if let refused = service.rejections[document.id] {
            ToolMessage(.warning, refused)
        } else if case .string(let notice)? = context.values[Key.notice] {
            ToolMessage(.info, notice)
        } else if !pageHasFields, !anywhere {
            ToolMessage(.info, FormsStrings.noFieldsOnPage, action: ToolOption(Action.fillAnywhere, FormsStrings.fillAnywhere))
        } else if service.hasUnsupportedScripts(document) {
            ToolMessage(.info, Strings.Errors.formHasScripts)
        } else {
            nil
        }
        return ToolPanel(.mode, controls: controls, moreOptions: more, primary: ToolButton(Strings.Panel.done), secondary: nil, message: message)
    }

    static let palette: [(FormFieldKind, String, String)] = [
        (.text, FormsStrings.Kind.text, "character.textbox"), (.checkbox, FormsStrings.Kind.tick, "checkmark.square"),
        (.dropdown, FormsStrings.Kind.choice, "filemenu.and.selection"), (.date, FormsStrings.Kind.date, "calendar"),
        (.signature, FormsStrings.Kind.signature, "signature"), (.number, FormsStrings.Kind.number, "number"),
        (.multilineText, FormsStrings.Kind.multiline, "text.alignleft"), (.image, FormsStrings.Kind.picture, "photo"),
    ]

    private func makePanel(_ context: ToolContext) -> ToolPanel {
        guard let document = context.document else { return ToolPanel(.mode, primary: ToolButton(Strings.Panel.done), secondary: nil) }
        let v = context.values
        let fields = service.fields(in: document)
        let found = candidates[document.id].flatMap { $0.pdf == ObjectIdentifier(document.pdf) ? $0.fields.count : nil }
        var controls: [ToolControl] = [
            .action(id: Action.detect, title: found.map { $0 > 0 ? FormsStrings.findFields(found: $0) : FormsStrings.findFields } ?? FormsStrings.findFields,
                    isDestructive: false, symbol: "wand.and.stars"),
            .chips(id: Key.kind, options: Self.palette.map { ToolOption($0.0.rawValue, $0.1, symbol: $0.2) }, selected: [], allowsMultiple: false),
            .custom(id: "forms.make.placement", make: { [weak self] in FormsPlacement(document: document, tools: self, hint: FormsStrings.selectHint) }),
        ]
        if let field = fields.first(where: { $0.id == v.string(Key.selected) }) {
            controls += properties(of: field, among: fields, values: v)
        }
        controls.append(.toggle(id: Key.tabOrder, label: FormsStrings.setTabOrder, isOn: false))
        let message: ToolMessage? = if case .string(let notice)? = v[Key.notice] { ToolMessage(.info, notice) } else { nil }
        return ToolPanel(.mode, controls: controls, primary: ToolButton(Strings.Panel.done), secondary: nil, message: message)
    }

    /// The selected field's properties (ux §5.3): name, required, default, format, "Calculate from…", and its choices.
    private func properties(of field: FormField, among fields: [FormField], values v: ToolValues) -> [ToolControl] {
        let id = field.id
        var controls: [ToolControl] = [
            .text(id: Key.name + id, label: FormsStrings.name, placeholder: id, value: id, isSecure: false),
            .toggle(id: Key.required + id, label: FormsStrings.required, isOn: field.isRequired),
        ]
        let isText = [.text, .multilineText, .number, .date].contains(field.kind)
        if isText || field.kind == .dropdown || field.kind == .list {
            controls.append(.text(id: Key.defaultValue + id, label: FormsStrings.defaultValue, placeholder: "", value: field.defaultValue, isSecure: false))
        }
        if field.kind == .dropdown || field.kind == .list {
            controls.append(.text(id: Key.choices + id, label: FormsStrings.choices, placeholder: FormsStrings.choicesPlaceholder,
                                  value: field.options.joined(separator: ", "), isSecure: false))
        }
        if isText {
            controls.append(.popup(id: Key.format + id, label: FormsStrings.format, options: FieldFormat.allCases.map { ToolOption($0.rawValue, $0.title) },
                                   selected: FieldFormat(scripts: field.scripts).rawValue))
            let current = FieldCalculation.parse(field.scripts[.calculate])
            controls.append(.popup(id: Key.calculate + id, label: FormsStrings.calculate,
                                   options: FieldCalculation.allCases.map { ToolOption($0.rawValue, $0.title) },
                                   selected: (current?.0 ?? .none).rawValue))
            if FieldCalculation(rawValue: v.string(Key.calculate + id, default: (current?.0 ?? .none).rawValue)) != FieldCalculation.none {
                let others = fields.filter { $0.id != id && [.text, .number].contains($0.kind) }
                controls.append(.chips(id: Key.calculateFrom + id, options: others.map { ToolOption($0.id, $0.tooltip.isEmpty ? $0.id : $0.tooltip) },
                                       selected: current?.1 ?? [], allowsMultiple: true))
            }
        }
        controls.append(.action(id: Action.remove, title: FormsStrings.removeField, isDestructive: true, symbol: "trash"))
        return controls
    }

    // MARK: Preview

    func preview(for tool: ToolID, context: ToolContext) async -> ToolPreview {
        guard let document = context.document else { return .none }
        if tool == .makeForm, candidates[document.id]?.pdf != ObjectIdentifier(document.pdf) {
            let pdf = ObjectIdentifier(document.pdf)
            if let found = try? await service.detectFields(in: document, pages: []) { candidates[document.id] = (pdf, found) }
        }
        let fields = service.fields(in: document)
        let selected = tool == .makeForm ? context.values.string(Key.selected) : ""
        let numbers = tool == .makeForm && context.values.bool(Key.tabOrder)
        // Page space from the crop box's lower-left corner, as the overlay draws.
        var boxes: [Int: [(rect: CGRect, id: String, tab: Int)]] = [:]
        for field in fields {
            guard let page = document.pdf.page(at: field.page) else { continue }
            let crop = page.bounds(for: .cropBox)
            boxes[field.page, default: []].append((field.bounds.offsetBy(dx: -crop.minX, dy: -crop.minY), field.id, field.tabIndex + 1))
        }
        guard !boxes.isEmpty else { return .none }
        return .overlay { page, context in
            guard let index = page.document?.index(for: page), let rects = boxes[index] else { return }
            let accent = SPColor.accent.color
            for box in rects {
                context.setFillColor(accent.withAlphaComponent(SPColor.redactionMarkFillOpacity).cgColor)
                context.fill(box.rect)
                if box.id == selected {
                    context.setStrokeColor(accent.cgColor)
                    context.setLineWidth(1.5)
                    context.stroke(box.rect.insetBy(dx: -1, dy: -1))
                }
                if numbers {
                    let text = NSAttributedString(string: "\(box.tab)", attributes: [.font: NSFont.boldSystemFont(ofSize: 9), .foregroundColor: accent])
                    let line = CTLineCreateWithAttributedString(text)
                    context.textPosition = CGPoint(x: box.rect.minX + 2, y: box.rect.maxY - 9)
                    CTLineDraw(line, context)
                }
            }
        }
    }

    // MARK: Actions

    func handle(action: String, context: ToolContext) async throws -> ToolValues {
        guard let document = context.document else { return context.values }
        var values = context.values
        values[Key.notice] = nil
        switch action {
        case Action.autoFill:
            let profile: AutoFillProfile?
            do { profile = try await contactCard.meCard() } catch { throw ToolError(FormsStrings.contactsDenied) }
            guard let profile else { values[Key.notice] = .string(FormsStrings.noMeCard); break }
            let (filled, group) = service.autoFill(profile, in: document)
            if !filled.isEmpty { try await apply(group, to: document, tool: context.tool) }
            values[Key.notice] = .string(filled.isEmpty ? FormsStrings.autoFillNothing : FormsStrings.autoFilled(filled.count))
        case Action.clear:
            try await apply(service.clear(document), to: document, tool: context.tool)
        case Action.fillAnywhere:
            values[Key.anywhere] = .bool(true)
            // The blanks of a printed page become fields to type into (the same finder as Make a form).
            let pages = Array(Set(context.scope.pages(count: document.pageCount, current: context.currentPage) + [context.currentPage])).sorted()
            let flat = pages.filter { page in !service.widgets(of: document.pdf).contains { $0.widgets.contains { $0.page == page } } }
            let found = try await service.detectFields(in: document, pages: flat)
            if !found.isEmpty { try await apply(try service.add(found, to: document), to: document, tool: context.tool) }
        case Action.saveData:
            let format = FormDataFormat(rawValue: values.string(Key.dataFormat, default: FormDataFormat.xfdf.rawValue)) ?? .xfdf
            let type = UTType(filenameExtension: format.rawValue) ?? .data
            guard let url = chooseSaveURL(document.displayName + "." + format.rawValue, type) else { break }
            try await service.exportData(from: document, as: format, to: url)
        case Action.loadData:
            guard let url = chooseOpenURL() else { break }
            do { try await apply(try service.importData(from: url, into: document), to: document, tool: context.tool) } catch let error as ToolError {
                throw error
            } catch {
                throw ToolError(FormsStrings.cantReadData(url.lastPathComponent))
            }
        case Action.detect:
            try await commitEdits(context, values: &values)
            let pdf = ObjectIdentifier(document.pdf)
            var found = candidates[document.id].flatMap { $0.pdf == pdf ? $0.fields : nil } ?? []
            if candidates[document.id]?.pdf != pdf { found = try await service.detectFields(in: document, pages: []) }
            candidates[document.id] = nil
            guard !found.isEmpty else { values[Key.notice] = .string(FormsStrings.noFieldsFound); break }
            try await apply(try service.add(found, to: document), to: document, tool: context.tool)
            values[Key.notice] = .string(FormsStrings.addedFields(found.count))
        case Action.remove:
            let id = values.string(Key.selected)
            guard !id.isEmpty else { break }
            try await commitEdits(context, values: &values)
            let current = values.string(Key.selected)
            try await apply(try service.remove([current], from: document), to: document, tool: context.tool)
            values[Key.selected] = nil
        case let click where click.hasPrefix(Action.click + "|"):
            let parts = click.split(separator: "|").map(String.init)
            guard parts.count == 4, let page = Int(parts[1]), let x = Double(parts[2]), let y = Double(parts[3]) else { break }
            try await self.click(page: page, at: CGPoint(x: x, y: y), context: context, values: &values)
        default:
            break
        }
        return values
    }

    /// A click on the page: in Make a form it picks a field (or, with "Set tab order", gives it the next number) or
    /// places a field of the chosen kind; in Fill anywhere it places a text box or a tick where there is none.
    private func click(page: Int, at point: CGPoint, context: ToolContext, values: inout ToolValues) async throws {
        guard let document = context.document, let pdfPage = document.pdf.page(at: page) else { return }
        let hit = service.fields(in: document).first { $0.page == page && $0.bounds.insetBy(dx: -2, dy: -2).contains(point) }
        let kind: FormFieldKind?
        if context.tool == .fillForm {
            guard hit == nil else { return }
            kind = values.strings(Key.place).first == "tick" ? .checkbox : .text
        } else {
            try await commitEdits(context, values: &values)
            if let hit {
                if values.bool(Key.tabOrder) {
                    var sequence = tabSequence[document.id, default: []].filter { $0 != hit.id }
                    sequence.append(hit.id)
                    tabSequence[document.id] = sequence
                    let rest = service.fields(in: document).map(\.id).filter { !sequence.contains($0) }
                    try await apply(service.setTabOrder(sequence + rest, in: document), to: document, tool: context.tool)
                } else {
                    values[Key.selected] = .string(hit.id)
                }
                return
            }
            kind = values.strings(Key.kind).first.flatMap(FormFieldKind.init(rawValue:))
        }
        guard let kind else { return }
        let size = Self.size(of: kind)
        let crop = pdfPage.bounds(for: .cropBox)
        var rect = CGRect(x: point.x - (kind == .checkbox ? size.width / 2 : 0), y: point.y - size.height / 2, width: size.width, height: size.height)
        rect.origin.x = min(max(rect.minX, crop.minX), crop.maxX - rect.width)
        rect.origin.y = min(max(rect.minY, crop.minY), crop.maxY - rect.height)
        var names = Set(service.widgets(of: document.pdf).map(\.name))
        let name = FormService.unique(FormService.kindTitle(kind) + " 1", among: &names)
        let scripts: [AFAction: String] = switch kind {
        case .date: FieldFormat.date.scripts()
        case .number: FieldFormat.number.scripts()
        default: [:]
        }
        let field = FormField(id: name, kind: kind, page: page, bounds: rect, scripts: scripts)
        try await apply(try service.add([field], to: document), to: document, tool: context.tool)
        if context.tool == .makeForm { values[Key.selected] = .string(name) }
    }

    /// The size a placed field starts at, in points.
    static func size(of kind: FormFieldKind) -> CGSize {
        switch kind {
        case .checkbox, .radioGroup: CGSize(width: 14, height: 14)
        case .multilineText: CGSize(width: 216, height: 60)
        case .number: CGSize(width: 72, height: 20)
        case .date: CGSize(width: 96, height: 20)
        case .dropdown, .list: CGSize(width: 120, height: 20)
        case .signature: CGSize(width: 180, height: 36)
        case .image, .button: CGSize(width: 120, height: 90)
        case .text, .barcode: CGSize(width: 144, height: 20)
        }
    }

    // MARK: Done

    func run(_ request: ToolRequest, progress: ToolProgress) async throws -> ToolResult {
        defer { if let document = request.document { modes[document.id] = nil; tabSequence[document.id] = nil } }
        guard request.tool == .makeForm, let document = request.document else { return .none }
        let context = ToolContext(tool: request.tool, document: document, values: request.values)
        guard let group = try edits(context) else { return .none }
        return .inPlace(undoable: group, banner: nil)
    }

    /// The property edits of every field whose controls were changed, as one undo step.
    private func edits(_ context: ToolContext) throws -> UndoGroup? {
        guard let document = context.document else { return nil }
        let v = context.values
        let fields = service.fields(in: document)
        let names = Set(fields.map(\.id))
        var changes: [(field: FormField, name: String)] = []
        for field in fields where Key.properties.contains(where: { v[$0 + field.id] != nil }) {
            var edited = field
            let newName = v.string(Key.name + field.id, default: field.id).trimmingCharacters(in: .whitespacesAndNewlines)
            if !newName.isEmpty, newName != field.id, !names.contains(newName) { edited.id = newName }
            edited.isRequired = v.bool(Key.required + field.id, default: field.isRequired)
            edited.defaultValue = v.string(Key.defaultValue + field.id, default: field.defaultValue)
            if v[Key.choices + field.id] != nil {
                edited.options = v.string(Key.choices + field.id).split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
            }
            // A format or calculation is rewritten only when it was changed, so ones we don't offer stay as they were.
            let format = FieldFormat(scripts: field.scripts)
            if let chosen = FieldFormat(rawValue: v.string(Key.format + field.id, default: format.rawValue)), chosen != format {
                edited.scripts[.format] = nil; edited.scripts[.keystroke] = nil
                edited.scripts.merge(chosen.scripts()) { _, new in new }
            }
            let current = FieldCalculation.parse(field.scripts[.calculate])
            if let chosen = FieldCalculation(rawValue: v.string(Key.calculate + field.id, default: (current?.0 ?? .none).rawValue)) {
                let sources = v[Key.calculateFrom + field.id] != nil ? v.strings(Key.calculateFrom + field.id) : current?.1 ?? []
                if chosen != (current?.0 ?? .none) || sources != (current?.1 ?? []) {
                    edited.scripts[.calculate] = chosen.script(of: sources)
                }
            }
            if edited != field { changes.append((edited, field.id)) }
        }
        return changes.isEmpty ? nil : try service.update(changes, in: document)
    }

    /// Applies pending property edits before the selection or the fields change; the selection follows a rename.
    private func commitEdits(_ context: ToolContext, values: inout ToolValues) async throws {
        guard context.tool == .makeForm, let document = context.document, let group = try edits(context) else { return }
        let selected = values.string(Key.selected)
        if !selected.isEmpty {
            let renamed = values.string(Key.name + selected, default: selected).trimmingCharacters(in: .whitespacesAndNewlines)
            if !renamed.isEmpty, renamed != selected { values[Key.selected] = .string(renamed) }
        }
        for key in values.storage.keys where Key.properties.contains(where: key.hasPrefix) { values[key] = nil }
        try await apply(group, to: document, tool: context.tool)
    }

    /// An in-place edit made from the panel, registered by DocumentKit like a run's result.
    private func apply(_ group: UndoGroup, to document: DocumentHandle, tool: ToolID) async throws {
        let work = SuperPDFPaths.ensure(SuperPDFPaths.work.appendingPathComponent(UUID().uuidString, isDirectory: true))
        try await Services.documents.apply(.inPlace(undoable: group, banner: nil), of: ToolRequest(tool: tool, document: document, workFolder: work))
    }

    // MARK: Panels

    private static func savePanel(_ proposed: String, _ type: UTType) -> URL? {
        let panel = NSSavePanel()
        panel.nameFieldStringValue = proposed
        panel.allowedContentTypes = [type]
        return panel.runModal() == .OK ? panel.url : nil
    }

    private static func openPanel() -> URL? {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = ["xfdf", "fdf", "csv", "json"].compactMap { UTType(filenameExtension: $0) }
        return panel.runModal() == .OK ? panel.url : nil
    }
}
