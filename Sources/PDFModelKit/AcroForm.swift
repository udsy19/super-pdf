import CoreGraphics
import Foundation

// Interactive forms at the dictionary level (ISO 32000-2 §12.7): the /AcroForm dictionary, the field tree with
// inherited /FT, /Ff, /V and /DA, widgets with their pages, value edits, adding and removing fields. Appearance
// streams and AF* scripts are FormsKit's.

/// A widget annotation of a field.
public struct PDFFormWidget {
    public var object: PDFObject
    /// 0-based, nil when the widget is on no page.
    public var page: Int?
    public var rect: CGRect
    /// /AS: the appearance state shown (check boxes and radio buttons).
    public var appearanceState: String?
    /// The "on" states of its normal appearance (/AP /N keys other than Off).
    public var onStates: [String]
}

/// A terminal form field (one that has a value; its widgets are itself or its kids).
public struct PDFFormField {
    public var object: PDFObject
    /// The fully qualified name ("address.city").
    public var name: String
    /// /FT inherited: "Tx", "Btn", "Ch" or "Sig".
    public var type: String?
    /// /Ff inherited.
    public var flags: Int
    /// /V inherited, as a value (a reference for signature fields).
    public var value: PDFValue?
    public var defaultValue: PDFValue?
    /// /DA inherited (from the AcroForm when the field tree has none).
    public var defaultAppearance: String?
    public var widgets: [PDFFormWidget]

    public var isReadOnly: Bool { flags & 1 != 0 }
    public var isRequired: Bool { flags & 2 != 0 }
    public var isRadio: Bool { type == "Btn" && flags & (1 << 15) != 0 }
    public var isPushButton: Bool { type == "Btn" && flags & (1 << 16) != 0 }
    public var isCheckBox: Bool { type == "Btn" && !isRadio && !isPushButton }
}

extension PDFModel {
    /// The catalog's /AcroForm.
    public var acroForm: PDFObject? { root["AcroForm"].flatMap { $0.type == .dictionary ? $0 : nil } }

    /// The /AcroForm dictionary, created (indirect, with an empty /Fields) when missing.
    public func ensureAcroForm() -> PDFObject {
        if let form = acroForm { return form }
        let form = makeIndirect(.dictionary(["Fields": .array([])]))
        root.set("AcroForm", form)
        return form
    }

    /// Every terminal field in field-tree order.
    public func formFields() -> [PDFFormField] {
        guard let fields = acroForm?["Fields"] else { return [] }
        let pageIndex = pageIndexByObjectID()
        let formDA = acroForm?["DA"]?.stringData.map { String(decoding: $0, as: UTF8.self) }
        var result: [PDFFormField] = []
        var seen: Set<Int> = []
        func visit(_ node: PDFObject, parentName: String?, depth: Int) {
            guard depth < 64, node.type == .dictionary else { return }
            if let id = node.objectID { guard seen.insert(id).inserted else { return } }
            let partial = node["T"]?.text
            let name = [parentName, partial].compactMap { $0 }.joined(separator: ".")
            // Kids that have their own /T are fields; kids without are this field's widgets.
            let kids = node["Kids"]?.items ?? []
            let fieldKids = kids.filter { $0.has("T") }
            if !fieldKids.isEmpty {
                for kid in fieldKids { visit(kid, parentName: name.isEmpty ? nil : name, depth: depth + 1) }
                let widgetKids = kids.filter { !$0.has("T") }
                guard !widgetKids.isEmpty else { return }
            }
            let widgetObjects = kids.isEmpty ? [node] : kids.filter { !$0.has("T") }
            let widgets = widgetObjects.map { widget -> PDFFormWidget in
                let onStates = (widget["AP"]?["N"]?.keys ?? []).filter { $0 != "Off" }
                return PDFFormWidget(object: widget,
                                     page: widget["P"]?.objectID.flatMap { pageIndex[$0] } ?? pageOfAnnotation(widget),
                                     rect: widget["Rect"]?.rect ?? .zero,
                                     appearanceState: widget["AS"]?.name,
                                     onStates: onStates)
            }
            result.append(PDFFormField(
                object: node, name: name,
                type: node.inherited("FT")?.name,
                flags: node.inherited("Ff")?.int ?? 0,
                value: node.inherited("V").map { $0.reference ?? $0.value },
                defaultValue: node.inherited("DV").map { $0.reference ?? $0.value },
                defaultAppearance: node.inherited("DA")?.stringData.map { String(decoding: $0, as: UTF8.self) } ?? formDA,
                widgets: widgets))
        }
        for field in fields.items { visit(field, parentName: nil, depth: 0) }
        return result
    }

    /// Sets a field's /V. For check boxes and radio buttons pass `.name(state)` (or `.name("Off")`): each widget's
    /// /AS follows. Turns on /NeedAppearances so viewers rebuild what FormsKit has not drawn.
    public func setFieldValue(_ name: String, _ value: PDFValue) throws {
        guard let field = formFields().first(where: { $0.name == name }) else {
            throw PDFModelError.invalidOperation("no field \(name)")
        }
        field.object.set("V", value)
        if field.type == "Btn", let state = value.nameValue {
            for widget in field.widgets {
                widget.object.set("AS", .name(widget.onStates.contains(state) ? state : "Off"))
            }
        }
        ensureAcroForm().set("NeedAppearances", .bool(true))
    }

    /// Adds a field whose dictionary is also its widget (/Subtype /Widget, /Rect…) on `page`: listed in /Fields and
    /// the page's /Annots.
    @discardableResult
    public func addField(_ field: PDFValue, on page: PDFPage) -> PDFObject {
        let object = page.addAnnotation(makeIndirect(field))
        ensureAcroForm().array("Fields").append(object)
        return object
    }

    /// Removes a field (by fully qualified name) with its widgets from /Fields, its parent's /Kids and the pages'
    /// /Annots. False when there is no such field.
    @discardableResult
    public func removeField(named name: String) -> Bool {
        guard let field = formFields().first(where: { $0.name == name }) else { return false }
        let widgetIDs = Set(field.widgets.compactMap(\.object.objectID))
        for page in pages {
            guard let annots = page.object["Annots"] else { continue }
            for i in (0..<annots.count).reversed() where annots[i]?.objectID.map(widgetIDs.contains) == true { annots.removeItem(at: i) }
        }
        let container = field.object["Parent"]?["Kids"] ?? acroForm?["Fields"]
        if let container, let id = field.object.objectID {
            for i in (0..<container.count).reversed() where container[i]?.objectID == id { container.removeItem(at: i) }
        }
        return true
    }

    /// Object number → page index, for widget and annotation lookups.
    func pageIndexByObjectID() -> [Int: Int] {
        var map: [Int: Int] = [:]
        for (i, page) in pages.enumerated() { if let id = page.object.objectID { map[id] = i } }
        return map
    }

    /// The page whose /Annots lists `annotation` (for widgets without /P).
    private func pageOfAnnotation(_ annotation: PDFObject) -> Int? {
        guard let id = annotation.objectID else { return nil }
        for (i, page) in pages.enumerated() where page.annotations.contains(where: { $0.objectID == id }) { return i }
        return nil
    }
}
