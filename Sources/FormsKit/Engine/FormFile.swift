import CoreGraphics
import Foundation
import PDFModelKit
import SuperPDFCore

/// What PDFKit loses when it reads or writes a form, kept per open document: each field's `AF*` scripts (PDFKit drops
/// every /AA), the calculation order (/CO) and whether the file is an XFA form.
struct FormFacts: Equatable, Sendable {
    var scripts: [String: [AFAction: String]] = [:]
    var calculationOrder: [String] = []
    var isXFA = false
}

/// The AcroForm at the dictionary level, on bytes, off the main actor (ISO 32000-2 §12.7): reads the facts above and
/// adds, changes and removes fields. Every write keeps the file's own encryption.
enum FormFile {
    /// /AA keys of the scripts we keep.
    static let actionKeys: [AFAction: String] = [.keystroke: "K", .format: "F", .validate: "V", .calculate: "C"]

    // MARK: Reading

    static func facts(of data: Data, password: String?) throws -> FormFacts {
        let model = try PDFModel(data: data, password: password)
        var facts = FormFacts()
        guard let form = model.acroForm else { return facts }
        if let xfa = form["XFA"], !xfa.isNull { facts.isXFA = true }
        var names: [Int: String] = [:]
        for field in model.formFields() {
            if let id = field.object.objectID { names[id] = field.name }
            var scripts: [AFAction: String] = [:]
            for holder in [field.object] + field.widgets.map(\.object) {
                guard let actions = holder["AA"], actions.type == .dictionary else { continue }
                for (action, key) in actionKeys where scripts[action] == nil {
                    if let script = javaScript(actions[key]) { scripts[action] = script }
                }
            }
            if !scripts.isEmpty { facts.scripts[field.name] = scripts }
        }
        facts.calculationOrder = (form["CO"]?.items ?? []).compactMap { $0.objectID.flatMap { names[$0] } }
        return facts
    }

    /// The text of a JavaScript action: /JS as a string or a stream.
    private static func javaScript(_ action: PDFObject?) -> String? {
        guard let action, action.type == .dictionary, action["S"]?.name == "JavaScript", let js = action["JS"] else { return nil }
        switch js.type {
        case .string: return js.text
        case .stream: return (try? js.streamData()).map { PDFText.decode($0) }
        default: return nil
        }
    }

    // MARK: Writing

    /// Opens the bytes, runs `edit`, and writes them back with the same encryption.
    static func edit(_ data: Data, password: String?, _ edit: (PDFModel) throws -> Void) throws -> Data {
        let model = try PDFModel(data: data, password: password)
        unifyWidgets(model)
        try edit(model)
        return try model.data()
    }

    /// PDFKit writes a field whose dictionary is also its widget twice: once in /Fields and once in the page's
    /// /Annots, as two objects. Edits must reach the one readers draw, so each /Fields entry that is a widget on no page
    /// is replaced by the page's widget of the same name and place.
    static func unifyWidgets(_ model: PDFModel) {
        guard let fields = model.acroForm?["Fields"] else { return }
        var onPages: Set<Int> = []
        var byKey: [String: PDFObject] = [:]
        func key(_ object: PDFObject) -> String? {
            guard let name = object["T"]?.text, let rect = object["Rect"]?.rect else { return nil }
            return "\(name)|\(Int(rect.minX.rounded()))|\(Int(rect.minY.rounded()))|\(Int(rect.maxX.rounded()))|\(Int(rect.maxY.rounded()))"
        }
        for page in model.pages {
            for annotation in page.annotations where annotation["Subtype"]?.name == "Widget" {
                if let id = annotation.objectID { onPages.insert(id) }
                if let k = key(annotation) { byKey[k] = annotation }
            }
        }
        func visit(_ array: PDFObject, depth: Int) {
            guard depth < 32 else { return }
            for i in 0..<array.count {
                guard let entry = array[i] else { continue }
                if entry["Subtype"]?.name == "Widget", let id = entry.objectID, !onPages.contains(id), let k = key(entry), let widget = byKey[k],
                   let reference = widget.reference {
                    if let parent = entry["Parent"]?.reference { widget.set("Parent", parent) }
                    array.replaceItem(at: i, with: reference)
                } else if let kids = entry["Kids"] {
                    visit(kids, depth: depth + 1)
                }
            }
        }
        visit(fields, depth: 0)
    }

    /// The /AcroForm with what other readers need to draw fields: a default appearance, Helvetica and ZapfDingbats in
    /// /DR, and NeedAppearances so they build what isn't drawn yet.
    @discardableResult
    static func prepareForm(_ model: PDFModel) -> PDFObject {
        let form = model.ensureAcroForm()
        if form["DA"] == nil { form.set("DA", .ascii("/Helv 0 Tf 0 g")) }
        let fonts = form.dictionary("DR").dictionary("Font")
        if fonts["Helv"] == nil {
            fonts.set("Helv", model.makeIndirect(.dictionary(["Type": .name("Font"), "Subtype": .name("Type1"), "BaseFont": .name("Helvetica"),
                                                              "Encoding": .name("WinAnsiEncoding")])).reference!)
        }
        if fonts["ZaDb"] == nil {
            fonts.set("ZaDb", model.makeIndirect(.dictionary(["Type": .name("Font"), "Subtype": .name("Type1"), "BaseFont": .name("ZapfDingbats")])).reference!)
        }
        form.set("NeedAppearances", .bool(true))
        return form
    }

    /// Adds fields (each its own widget) on their pages; names must be unique in the form.
    static func add(_ fields: [FormField], to model: PDFModel) throws {
        prepareForm(model)
        for field in fields {
            guard let page = model.page(at: field.page) else { throw PDFModelError.invalidOperation("no page \(field.page + 1)") }
            var dictionary: [String: PDFValue] = [
                "Type": .name("Annot"), "Subtype": .name("Widget"), "T": .text(field.id), "F": .integer(4), "Rect": .rect(field.bounds),
                "Ff": .integer(flags(of: field)),
            ]
            if !field.tooltip.isEmpty { dictionary["TU"] = .text(field.tooltip) }
            switch field.kind {
            case .checkbox, .radioGroup:
                let on = field.options.first ?? "Yes"
                dictionary["FT"] = .name("Btn")
                dictionary["DA"] = .ascii("/ZaDb 0 Tf 0 g")
                dictionary["MK"] = .dictionary(["CA": .ascii("4")])
                let ticked = !field.value.isEmpty && field.value != "Off"
                dictionary["V"] = .name(ticked ? on : "Off")
                dictionary["AS"] = .name(ticked ? on : "Off")
                dictionary["AP"] = .dictionary(["N": .dictionary([on: tick(model, size: field.bounds.size).reference!,
                                                                 "Off": blank(model, size: field.bounds.size).reference!])])
            case .button, .image:
                dictionary["FT"] = .name("Btn")
                dictionary["MK"] = .dictionary(["TP": .integer(1)])
            case .signature:
                dictionary["FT"] = .name("Sig")
            case .dropdown, .list:
                dictionary["FT"] = .name("Ch")
                dictionary["DA"] = .ascii("/Helv 0 Tf 0 g")
                dictionary["Opt"] = .array(field.options.map { .text($0) })
                if !field.value.isEmpty { dictionary["V"] = .text(field.value) }
                if !field.defaultValue.isEmpty { dictionary["DV"] = .text(field.defaultValue) }
            case .text, .multilineText, .number, .date, .barcode:
                dictionary["FT"] = .name("Tx")
                dictionary["DA"] = .ascii("/Helv 0 Tf 0 g")
                if !field.value.isEmpty { dictionary["V"] = .text(field.value) }
                if !field.defaultValue.isEmpty { dictionary["DV"] = .text(field.defaultValue) }
            }
            let object = model.addField(.dictionary(dictionary), on: page)
            setScripts(field.scripts, on: object, in: model)
        }
        if fields.contains(where: { $0.scripts[.calculate] != nil }) {
            setCalculationOrder(calculationOrder(model) + fields.filter { $0.scripts[.calculate] != nil }.map(\.id), in: model)
        }
    }

    /// Changes a field's name, flags, tooltip, default, choices, place and scripts; `name` is its name before.
    static func update(_ field: FormField, named name: String, in model: PDFModel) throws {
        guard let current = model.formFields().first(where: { $0.name == name }) else {
            throw PDFModelError.invalidOperation("no field \(name)")
        }
        prepareForm(model)
        let object = current.object
        if field.id != name {
            // The partial name changes; a field inside a group keeps its parent.
            let parent = name.contains(".") ? String(name[..<name.lastIndex(of: ".")!]) + "." : ""
            object.set("T", .text(field.id.hasPrefix(parent) ? String(field.id.dropFirst(parent.count)) : field.id))
        }
        var flagBits = current.flags & ~3
        if field.isReadOnly { flagBits |= 1 }
        if field.isRequired { flagBits |= 2 }
        object.set("Ff", .integer(flagBits))
        if field.tooltip.isEmpty { object.remove("TU") } else { object.set("TU", .text(field.tooltip)) }
        if current.type == "Tx" || current.type == "Ch" {
            if field.defaultValue.isEmpty { object.remove("DV") } else { object.set("DV", .text(field.defaultValue)) }
        }
        if current.type == "Ch" { object.set("Opt", .array(field.options.map { .text($0) })) }
        if current.widgets.count == 1, field.bounds != .zero { current.widgets[0].object.set("Rect", .rect(field.bounds)) }
        setScripts(field.scripts, on: object, in: model)
        var order = calculationOrder(model).map { $0 == name ? field.id : $0 }
        if field.scripts[.calculate] == nil { order.removeAll { $0 == field.id } } else if !order.contains(field.id) { order.append(field.id) }
        setCalculationOrder(order, in: model)
    }

    static func remove(_ names: [String], from model: PDFModel) {
        let order = calculationOrder(model).filter { !names.contains($0) }
        for name in names { model.removeField(named: name) }
        if model.acroForm?["CO"] != nil { setCalculationOrder(order, in: model) }
    }

    // MARK: Parts

    private static func flags(of field: FormField) -> Int {
        var bits = 0
        if field.isReadOnly { bits |= 1 }
        if field.isRequired { bits |= 2 }
        switch field.kind {
        case .multilineText: bits |= 1 << 12
        case .dropdown: bits |= 1 << 17
        case .radioGroup: bits |= (1 << 15) | (1 << 14)
        case .button, .image: bits |= 1 << 16
        default: break
        }
        return bits
    }

    /// Sets (or, for actions without a script, removes) the field's /AA entries we keep; other /AA entries stay.
    private static func setScripts(_ scripts: [AFAction: String], on object: PDFObject, in model: PDFModel) {
        let existing = object["AA"]
        var actions: [String: PDFValue] = existing.flatMap { $0.type == .dictionary ? $0.value.dictionaryValue : nil } ?? [:]
        for (action, key) in actionKeys {
            if let script = scripts[action] {
                actions[key] = .dictionary(["S": .name("JavaScript"), "JS": .text(script)])
            } else {
                actions[key] = nil
            }
        }
        if actions.isEmpty { object.remove("AA") } else { object.set("AA", .dictionary(actions)) }
    }

    static func calculationOrder(_ model: PDFModel) -> [String] {
        guard let order = model.acroForm?["CO"]?.items, !order.isEmpty else { return [] }
        var names: [Int: String] = [:]
        for field in model.formFields() { if let id = field.object.objectID { names[id] = field.name } }
        return order.compactMap { $0.objectID.flatMap { names[$0] } }
    }

    private static func setCalculationOrder(_ order: [String], in model: PDFModel) {
        let fields = Dictionary(model.formFields().map { ($0.name, $0) }, uniquingKeysWith: { first, _ in first })
        var seen: Set<String> = []
        let references = order.filter { seen.insert($0).inserted }.compactMap { fields[$0]?.object.reference }
        let form = model.ensureAcroForm()
        if references.isEmpty { form.remove("CO") } else { form.set("CO", .array(references)) }
    }

    /// A tick drawn as a path, so the box needs no font.
    private static func tick(_ model: PDFModel, size: CGSize) -> PDFObject {
        let w = size.width, h = size.height
        let line = max(1, min(w, h) * 0.12)
        let path = String(format: "q 0 g 0 G %.2f w 1 J 1 j %.2f %.2f m %.2f %.2f l %.2f %.2f l S Q",
                          line, w * 0.2, h * 0.52, w * 0.42, h * 0.26, w * 0.8, h * 0.76)
        return model.makeStream(["Type": .name("XObject"), "Subtype": .name("Form"), "BBox": .rect(CGRect(origin: .zero, size: size))],
                                data: Data(path.utf8))
    }

    private static func blank(_ model: PDFModel, size: CGSize) -> PDFObject {
        model.makeStream(["Type": .name("XObject"), "Subtype": .name("Form"), "BBox": .rect(CGRect(origin: .zero, size: size))], data: Data())
    }
}
