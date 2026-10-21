import Combine
import CoreGraphics
import Foundation
import LayoutKit
import PDFKit
import PDFModelKit
import SuperPDFCore

/// `Services.forms` (features #80, #81, #59). Filling works on the open document's PDFKit widgets on the main actor,
/// so what the person types and what FormsKit fills share one place and one undo stack; scripts run through the `AF*`
/// emulator. Making a form changes the AcroForm through PDFModelKit on the document's bytes (`.contents` undo steps),
/// so fields are real fields in every reader. PDFKit drops field scripts when it reads a file, so FormsKit keeps them
/// per document (`FormFacts`, read once from the file) and puts them back when the document is saved.
@MainActor
final class FormService: FormServicing {
    let emulator: any AFScriptEmulator

    /// Scripts, calculation order and XFA by document.
    private var facts: [UUID: FormFacts] = [:]
    /// The field values each document had when FormsKit last looked, and the PDFKit document they belong to: the
    /// difference is what the person typed or ticked on the page.
    private var known: [UUID: (pdf: ObjectIdentifier, values: [String: String])] = [:]
    /// Counts value changes per document (the Fill panel's field list follows it).
    private(set) var revisions: [UUID: Int] = [:]
    /// The last entry a field refused, until the next good one.
    private(set) var rejections: [UUID: String] = [:]
    private var bag = Set<AnyCancellable>()

    init(emulator: any AFScriptEmulator = AFEmulator()) {
        self.emulator = emulator
    }

    /// Follows open documents: remembers their values when they open and forgets them when they close.
    func watch(_ documents: DocumentManaging) {
        documents.events.sink { [weak self] event in
            MainActor.assumeIsolated {
                guard let self else { return }
                switch event {
                case .opened(let id):
                    if let document = documents.openDocuments.first(where: { $0.id == id }) { self.remember(document) }
                case .closed(let id):
                    self.facts[id] = nil; self.known[id] = nil; self.revisions[id] = nil; self.rejections[id] = nil
                default:
                    break
                }
            }
        }.store(in: &bag)
    }

    // MARK: Reading

    /// A field's widgets on the open document, in page and annotation order.
    struct Widget {
        var page: Int
        var annotation: PDFAnnotation
    }

    func widgets(of pdf: PDFDocument) -> [(name: String, widgets: [Widget])] {
        var order: [String] = []
        var byName: [String: [Widget]] = [:]
        for index in 0..<pdf.pageCount {
            guard let page = pdf.page(at: index) else { continue }
            for annotation in page.annotations where annotation.type == "Widget" {
                guard let name = annotation.fieldName, !name.isEmpty else { continue }
                if byName[name] == nil { order.append(name) }
                byName[name, default: []].append(Widget(page: index, annotation: annotation))
            }
        }
        return order.map { ($0, byName[$0]!) }
    }

    func facts(for document: DocumentHandle) -> FormFacts {
        if let known = facts[document.id] { return known }
        var read = FormFacts()
        if let url = document.url, let data = try? Data(contentsOf: url, options: .mappedIfSafe) {
            read = (try? FormFile.facts(of: data, password: document.password)) ?? FormFacts()
        }
        facts[document.id] = read
        return read
    }

    func fields(in document: DocumentHandle) -> [FormField] {
        let facts = facts(for: document)
        var tab = 0
        return widgets(of: document.pdf).compactMap { name, widgets -> FormField? in
            guard let first = widgets.first else { return nil }
            let annotation = first.annotation
            let scripts = facts.scripts[name] ?? [:]
            let flags = (annotation.annotationKeyValues["/Ff"] as? NSNumber)?.intValue ?? 0
            defer { tab += 1 }
            return FormField(id: name, kind: Self.kind(of: annotation, widgets: widgets.count, scripts: scripts), page: first.page,
                             bounds: annotation.bounds, value: value(of: widgets), defaultValue: annotation.widgetDefaultStringValue ?? "",
                             options: options(of: widgets), tooltip: annotation.annotationKeyValues["/TU"] as? String ?? "",
                             isRequired: flags & 2 != 0, isReadOnly: annotation.isReadOnly || flags & 1 != 0, tabIndex: tab, scripts: scripts)
        }
    }

    static func kind(of annotation: PDFAnnotation, widgets: Int, scripts: [AFAction: String]) -> FormFieldKind {
        switch annotation.widgetFieldType {
        case .button:
            switch annotation.widgetControlType {
            case .radioButtonControl: return .radioGroup
            case .checkBoxControl: return .checkbox
            default: return .button
            }
        case .choice:
            return annotation.isListChoice ? .list : .dropdown
        case .signature:
            return .signature
        default:
            if annotation.isMultiline { return .multilineText }
            switch FieldFormat(scripts: scripts) {
            case .number, .percent: return .number
            case .date, .time: return .date
            default: return .text
            }
        }
    }

    /// Text and choices: the string; tick boxes: the on state's name or "Off"; radio buttons: the chosen button's.
    private func value(of widgets: [Widget]) -> String {
        guard let first = widgets.first?.annotation else { return "" }
        switch first.widgetFieldType {
        case .button:
            guard first.widgetControlType != .pushButtonControl else { return "" }
            return widgets.first { $0.annotation.buttonWidgetState == .onState }.map { $0.annotation.buttonWidgetStateString } ?? "Off"
        case .text, .choice:
            return first.widgetStringValue ?? ""
        default:
            return ""
        }
    }

    private func options(of widgets: [Widget]) -> [String] {
        guard let first = widgets.first?.annotation else { return [] }
        switch first.widgetFieldType {
        case .choice: return first.choices ?? []
        case .button where first.widgetControlType != .pushButtonControl:
            var seen: Set<String> = []
            return widgets.map(\.annotation.buttonWidgetStateString).filter { !$0.isEmpty && seen.insert($0).inserted }
        default: return []
        }
    }

    /// Every field's value by name.
    func values(of document: DocumentHandle) -> [String: String] {
        Dictionary(widgets(of: document.pdf).map { ($0.name, value(of: $0.widgets)) }, uniquingKeysWith: { first, _ in first })
    }

    /// Starts following a document's values (the first look; later looks find what changed).
    func remember(_ document: DocumentHandle) {
        known[document.id] = (ObjectIdentifier(document.pdf), values(of: document))
    }

    // MARK: Writing values

    /// Puts a value into a field's widgets: text and choices as they are, tick boxes on unless the value is empty or
    /// "Off", radio buttons on the button whose state is the value.
    func write(_ value: String, to name: String, in pdf: PDFDocument) {
        guard let widgets = widgets(of: pdf).first(where: { $0.name == name })?.widgets else { return }
        for widget in widgets {
            let annotation = widget.annotation
            switch annotation.widgetFieldType {
            case .button:
                switch annotation.widgetControlType {
                case .pushButtonControl: continue
                case .radioButtonControl:
                    annotation.buttonWidgetState = annotation.buttonWidgetStateString == value ? .onState : .offState
                default:
                    let on = !["", "Off", "No", "false", "0"].contains(value)
                    let matches = widgets.count == 1 || annotation.buttonWidgetStateString == value
                    annotation.buttonWidgetState = on && matches ? .onState : .offState
                }
            case .text, .choice:
                if annotation.widgetStringValue != value { annotation.widgetStringValue = value }
            default:
                continue
            }
        }
    }

    private func redraw(_ document: DocumentHandle?) {
        guard let document, let view = Services.viewer?.pdfView(for: document) else { return }
        for index in 0..<document.pdf.pageCount { if let page = document.pdf.page(at: index) { view.annotationsChanged(on: page) } }
    }

    /// The value a field shows for an entry: its format script's output, else the entry.
    func formatted(_ value: String, scripts: [AFAction: String]) -> String {
        guard let format = scripts[.format], case .value(let shown) = emulator.run(format, action: .format, value: value, fields: [:]) else { return value }
        return shown
    }

    /// The keystroke and validate scripts' verdict on an entry; nil when it is fine.
    func rejection(of value: String, scripts: [AFAction: String], fields: [String: String]) -> String? {
        for action in [AFAction.keystroke, .validate] {
            guard let script = scripts[action] else { continue }
            if case .rejected(let message) = emulator.run(script, action: action, value: value, fields: fields) { return message }
        }
        return nil
    }

    /// Every field's number for calculations: values through their own format read back ("$1,234.50" → "1234.5").
    func rawValues(of document: DocumentHandle) -> [String: String] {
        let facts = facts(for: document)
        return values(of: document).reduce(into: [:]) { raw, entry in
            raw[entry.key] = AFEmulator.rawValue(of: entry.value, format: facts.scripts[entry.key]?[.format])
        }
    }

    /// Runs the calculate scripts in the form's calculation order (then field order) and shows their results.
    func recalculate(_ document: DocumentHandle) {
        let facts = facts(for: document)
        let names = widgets(of: document.pdf).map(\.name)
        var seen: Set<String> = []
        let order = (facts.calculationOrder + names).filter { facts.scripts[$0]?[.calculate] != nil && names.contains($0) && seen.insert($0).inserted }
        for name in order {
            guard let script = facts.scripts[name]?[.calculate] else { continue }
            let raw = rawValues(of: document)
            guard case .value(let result) = emulator.run(script, action: .calculate, value: raw[name] ?? "", fields: raw) else { continue }
            let shown = formatted(result, scripts: facts.scripts[name] ?? [:])
            if values(of: document)[name] != shown { write(shown, to: name, in: document.pdf) }
        }
    }

    /// Whether any field has a script the emulator can't run (ux §7.4 "This form uses scripts we don’t run.").
    func hasUnsupportedScripts(_ document: DocumentHandle) -> Bool {
        facts(for: document).scripts.values.contains { scripts in
            scripts.contains { action, script in
                if case .unsupported = emulator.run(script, action: action, value: "", fields: [:]) { return true }
                return false
            }
        }
    }

    /// New entries (formatted by each field's scripts), the calculations after them, and one undo step for all.
    private func change(_ entries: [String: String], in document: DocumentHandle, undoName: String) -> UndoGroup {
        let before = values(of: document)
        let facts = facts(for: document)
        for (name, entry) in entries {
            write(formatted(entry, scripts: facts.scripts[name] ?? [:]), to: name, in: document.pdf)
        }
        recalculate(document)
        return settle(document, before: before, undoName: undoName)
    }

    /// Records the values now as known and returns the undo step from `before` to them.
    private func settle(_ document: DocumentHandle, before: [String: String], undoName: String) -> UndoGroup {
        let after = values(of: document)
        let pdf = document.pdf
        known[document.id] = (ObjectIdentifier(pdf), after)
        revisions[document.id, default: 0] += 1
        redraw(document)
        let changed = after.keys.filter { before[$0] != after[$0] }.sorted()
        let id = document.id
        let apply = { [weak self, weak document] (values: [String: String]) in
            guard let self else { return }
            for name in changed { self.write(values[name] ?? "", to: name, in: pdf) }
            if let document, document.pdf === pdf {
                self.known[id] = (ObjectIdentifier(pdf), self.values(of: document))
                self.revisions[id, default: 0] += 1
                self.redraw(document)
            }
        }
        return UndoGroup(undoName, undo: { apply(before) }, redo: { apply(after) })
    }

    /// What the person typed or ticked on the page since FormsKit last looked: each changed entry is checked
    /// (keystroke and validate scripts; a refused one goes back to what it was, and its message is kept for the panel)
    /// and formatted, the calculations run, and the whole change, typing included, becomes one undo step. Both nil when
    /// nothing changed.
    func reconcile(_ document: DocumentHandle) -> (undo: UndoGroup?, rejected: String?) {
        guard let previous = known[document.id], previous.pdf == ObjectIdentifier(document.pdf) else {
            remember(document)
            return (nil, nil)
        }
        let now = values(of: document)
        let changed = now.filter { previous.values[$0.key] != $0.value }
        guard !changed.isEmpty else { return (nil, nil) }
        let facts = facts(for: document)
        let raw = rawValues(of: document)
        var rejected: String?
        for (name, entry) in changed.sorted(by: { $0.key < $1.key }) {
            let scripts = facts.scripts[name] ?? [:]
            if let message = rejection(of: entry, scripts: scripts, fields: raw) {
                write(previous.values[name] ?? "", to: name, in: document.pdf)
                rejected = message
                continue
            }
            let shown = formatted(entry, scripts: scripts)
            if shown != entry { write(shown, to: name, in: document.pdf) }
        }
        rejections[document.id] = rejected
        recalculate(document)
        let unchanged = values(of: document) == previous.values
        let group = settle(document, before: previous.values, undoName: FormsStrings.Undo.fill)
        return (unchanged ? nil : group, rejected)
    }

    // MARK: FormFilling

    func setValue(_ value: String, forField id: String, in document: DocumentHandle) -> UndoGroup {
        change([id: value], in: document, undoName: FormsStrings.Undo.fill)
    }

    func autoFill(_ profile: AutoFillProfile, in document: DocumentHandle) -> (filled: [String], undo: UndoGroup) {
        var entries: [String: String] = [:]
        var order: [String] = []
        for field in fields(in: document) where [.text, .multilineText, .date, .dropdown].contains(field.kind) && !field.isReadOnly && field.value.isEmpty {
            guard let key = AutoFillKey.key(for: field) else { continue }
            var value = profile.values[key]
            if key == AutoFillKey.name, value == nil {
                let parts = [profile.values[AutoFillKey.firstName], profile.values[AutoFillKey.lastName]].compactMap { $0 }
                value = parts.isEmpty ? nil : parts.joined(separator: " ")
            }
            if field.kind == .dropdown, let wanted = value { value = field.options.first { $0.caseInsensitiveCompare(wanted) == .orderedSame } }
            guard let value, !value.isEmpty else { continue }
            entries[field.id] = value
            order.append(field.id)
        }
        return (order, change(entries, in: document, undoName: FormsStrings.Undo.autoFill))
    }

    func clear(_ document: DocumentHandle) -> UndoGroup {
        var entries: [String: String] = [:]
        for field in fields(in: document) where !field.isReadOnly && ![.button, .signature, .image].contains(field.kind) {
            entries[field.id] = field.defaultValue.isEmpty && [.checkbox, .radioGroup].contains(field.kind) ? "Off" : field.defaultValue
        }
        return change(entries, in: document, undoName: FormsStrings.Undo.clear)
    }

    func importData(from file: URL, into document: DocumentHandle) throws -> UndoGroup {
        guard let format = FormData.format(of: file) else { throw FormData.Failure.unreadable }
        let values = try FormData.decode(try Data(contentsOf: file), as: format)
        let names = Set(widgets(of: document.pdf).map(\.name))
        let entries = values.filter { names.contains($0.key) }
        guard !entries.isEmpty else { throw FormData.Failure.unreadable }
        return change(entries, in: document, undoName: FormsStrings.Undo.importData)
    }

    func exportData(from document: DocumentHandle, as format: FormDataFormat, to destination: URL) async throws {
        let output: ConversionFormat
        switch format {
        case .csv:
            let fields = fields(in: document).filter { ![.button, .signature, .image].contains($0.kind) }
            try FormData.csv(fields.map { ($0.id, $0.value) }).write(to: destination, options: .atomic)
            return
        case .fdf: output = .fdf
        case .xfdf: output = .xfdf
        case .json: output = .json
        }
        let work = SuperPDFPaths.ensure(SuperPDFPaths.work.appendingPathComponent(UUID().uuidString, isDirectory: true))
        defer { try? FileManager.default.removeItem(at: work) }
        let input = work.appendingPathComponent(document.url?.lastPathComponent ?? document.displayName + ".pdf")
        // PDFKit's copy: the values as they are on screen (and without the password a protected file has).
        guard let data = document.pdf.dataRepresentation() else { throw FormData.Failure.unreadable }
        try data.write(to: input)
        _ = try await Services.convert.convert(ConversionJob(inputs: [input], output: output, destination: destination), progress: .ignored)
    }

    func isXFA(_ document: DocumentHandle) -> Bool { facts(for: document).isXFA }

    // MARK: FormBuilding

    func detectFields(in document: DocumentHandle, pages: [Int]) async throws -> [FormField] {
        let indices = pages.isEmpty ? Array(0..<document.pageCount) : pages.filter { (0..<document.pageCount).contains($0) }
        guard !indices.isEmpty else { return [] }
        let source = document.snapshot()
        var crops: [Int: CGRect] = [:]
        var occupied: [Int: [CGRect]] = [:]
        for index in indices {
            guard let page = document.pdf.page(at: index) else { continue }
            let crop = page.bounds(for: .cropBox)
            crops[index] = crop
            occupied[index] = page.annotations.filter { $0.type == "Widget" }.map { $0.bounds.offsetBy(dx: -crop.minX, dy: -crop.minY) }
        }
        let layout = try await Services.layout.analyze(source, pages: indices,
                                                        options: LayoutOptions(recognition: .whenPageHasNoText, detectTables: false, excludeHeadersAndFooters: false))
        var words = Dictionary(layout.pages.map { page in (page.index, page.blocks.flatMap { $0.lines.flatMap(\.words) }) }, uniquingKeysWith: { a, _ in a })
        // Box glyphs ("☐ I agree") are symbols LayoutKit's words leave out; PDFKit still knows where each one is.
        for index in indices {
            guard let page = document.pdf.page(at: index), let text = page.string as NSString?, let crop = crops[index] else { continue }
            for offset in 0..<text.length {
                guard let scalar = UnicodeScalar(text.character(at: offset)), FieldDetector.checkGlyphs.contains(Character(scalar)) else { continue }
                let bounds = page.selection(for: NSRange(location: offset, length: 1))?.bounds(for: page) ?? .zero
                guard bounds.width > 0, bounds.height > 0 else { continue }
                words[index, default: []].append(LayoutWord(text: String(Character(scalar)), bounds: bounds.offsetBy(dx: -crop.minX, dy: -crop.minY)))
            }
        }
        let data = try source.bytes()
        let password = source.password
        let found = try await Task.detached(priority: .userInitiated) { () -> [(Int, [DetectedField])] in
            guard let provider = CGDataProvider(data: data as CFData), let pdf = CGPDFDocument(provider) else { throw FormData.Failure.unreadable }
            if pdf.isEncrypted, !pdf.isUnlocked { _ = password.map { pdf.unlockWithPassword($0) } }
            return indices.compactMap { index in
                guard let page = pdf.page(at: index + 1) else { return nil }
                let size = page.getBoxRect(.cropBox).size
                return (index, FieldDetector.detect(words: words[index] ?? [], graphics: PageGraphicsScanner.scan(page), pageSize: size,
                                                    occupied: occupied[index] ?? []))
            }
        }.value
        var names = Set(widgets(of: document.pdf).map(\.name))
        var fields: [FormField] = []
        for (index, detected) in found {
            let origin = crops[index]?.origin ?? .zero
            for field in detected {
                let kindName = Self.kindTitle(field.kind)
                let name = Self.unique(field.label.isEmpty ? kindName : field.label, among: &names)
                let scripts: [AFAction: String] = switch field.kind {
                case .date: FieldFormat.date.scripts()
                case .number: FieldFormat.number.scripts()
                default: [:]
                }
                fields.append(FormField(id: name, kind: field.kind, page: index, bounds: field.bounds.offsetBy(dx: origin.x, dy: origin.y),
                                        tooltip: field.label, tabIndex: fields.count, scripts: scripts))
            }
        }
        return fields
    }

    func add(_ fields: [FormField], to document: DocumentHandle) throws -> UndoGroup {
        var names = Set(widgets(of: document.pdf).map(\.name))
        let unique = fields.map { field -> FormField in
            var field = field
            field.id = Self.unique(field.id, among: &names)
            return field
        }
        let group = try rewrite(document, undoName: FormsStrings.Undo.addFields) { try FormFile.add(unique, to: $0) }
        update(facts: document) { facts in
            for field in unique where !field.scripts.isEmpty { facts.scripts[field.id] = field.scripts }
            facts.calculationOrder += unique.filter { $0.scripts[.calculate] != nil }.map(\.id)
        }
        return group
    }

    func update(_ field: FormField, in document: DocumentHandle) throws -> UndoGroup {
        try update([(field, field.id)], in: document)
    }

    /// Changes fields, renames included (`name` is each field's name before), as one undo step.
    func update(_ changes: [(field: FormField, name: String)], in document: DocumentHandle) throws -> UndoGroup {
        let group = try rewrite(document, undoName: FormsStrings.Undo.changeField) { model in
            for (field, name) in changes { try FormFile.update(field, named: name, in: model) }
        }
        update(facts: document) { facts in
            for (field, name) in changes {
                facts.scripts[name] = nil
                facts.scripts[field.id] = field.scripts.isEmpty ? nil : field.scripts
                facts.calculationOrder = facts.calculationOrder.map { $0 == name ? field.id : $0 }
                if field.scripts[.calculate] == nil { facts.calculationOrder.removeAll { $0 == field.id } }
                else if !facts.calculationOrder.contains(field.id) { facts.calculationOrder.append(field.id) }
            }
        }
        return group
    }

    func remove(_ fieldIDs: [String], from document: DocumentHandle) throws -> UndoGroup {
        let group = try rewrite(document, undoName: FormsStrings.Undo.removeFields) { FormFile.remove(fieldIDs, from: $0) }
        update(facts: document) { facts in
            for id in fieldIDs { facts.scripts[id] = nil }
            facts.calculationOrder.removeAll { fieldIDs.contains($0) }
        }
        return group
    }

    /// Puts the fields' widgets in this order on their pages (the order Tab follows); fields not named keep their
    /// order after them.
    func setTabOrder(_ fieldIDs: [String], in document: DocumentHandle) -> UndoGroup {
        let rank = Dictionary(fieldIDs.enumerated().map { ($1, $0) }, uniquingKeysWith: { first, _ in first })
        let group = try? rewrite(document, undoName: FormsStrings.Undo.tabOrder) { model in
            let fields = model.formFields()
            var widgetRank: [Int: Int] = [:]
            for field in fields {
                for widget in field.widgets { if let id = widget.object.objectID { widgetRank[id] = rank[field.name] ?? Int.max } }
            }
            for page in model.pages {
                guard let annots = page.object["Annots"], annots.count > 1 else { continue }
                let items = annots.items
                let sorted = items.enumerated().sorted { a, b in
                    let ra = a.element.objectID.flatMap { widgetRank[$0] }, rb = b.element.objectID.flatMap { widgetRank[$0] }
                    switch (ra, rb) {
                    case let (x?, y?) where x != y: return x < y
                    default: return a.offset < b.offset
                    }
                }.map(\.element)
                for (i, item) in sorted.enumerated() { annots.replaceItem(at: i, with: item) }
                page.object.remove("Tabs")
            }
        }
        return group ?? UndoGroup(FormsStrings.Undo.tabOrder, undo: {}, redo: {})
    }

    // MARK: Parts

    /// An AcroForm edit of the document's current bytes as a `.contents` undo step (DocumentKit applies it).
    private func rewrite(_ document: DocumentHandle, undoName: String, _ edit: (PDFModel) throws -> Void) throws -> UndoGroup {
        let before = try document.snapshot().bytes()
        let after = try FormFile.edit(before, password: document.password, edit)
        return UndoGroup(undoName, .contents(before: before, after: after))
    }

    private func update(facts document: DocumentHandle, _ change: (inout FormFacts) -> Void) {
        var current = facts(for: document)
        change(&current)
        facts[document.id] = current
    }

    /// "Name", then "Name 2", "Name 3"… when taken.
    static func unique(_ base: String, among names: inout Set<String>) -> String {
        let base = base.trimmingCharacters(in: .whitespacesAndNewlines).replacingOccurrences(of: ".", with: " ")
        var name = base.isEmpty ? FormsStrings.Kind.text : base
        var n = 2
        while names.contains(name) { name = "\(base) \(n)"; n += 1 }
        names.insert(name)
        return name
    }

    static func kindTitle(_ kind: FormFieldKind) -> String {
        switch kind {
        case .checkbox, .radioGroup: FormsStrings.Kind.tick
        case .dropdown, .list: FormsStrings.Kind.choice
        case .date: FormsStrings.Kind.date
        case .signature: FormsStrings.Kind.signature
        case .number: FormsStrings.Kind.number
        case .multilineText: FormsStrings.Kind.multiline
        case .image, .button: FormsStrings.Kind.picture
        case .text, .barcode: FormsStrings.Kind.text
        }
    }
}
