import CoreGraphics
import Foundation
import PDFModelKit
import SuperPDFCore

// Form data and comments out of a PDF (features #59): FDF (form values), XFDF (form values and markup annotations) and
// JSON (form values), read from the object model off the main actor.

enum DataExport {
    static func write(_ source: PDFSource, format: ConversionFormat, to url: URL) throws {
        let model = try PDFModel(source)
        let fields = DataExportField.read(model)
        let data: Data
        switch format {
        case .fdf: data = fdf(fields)
        case .xfdf: data = Data(xfdf(fields, annotations: DataExportAnnotation.read(model)).utf8)
        case .json: data = try json(fields)
        default: throw ConvertError.unsupported(format.rawValue)
        }
        try data.write(to: url, options: .atomic)
    }

    // MARK: FDF (ISO 32000-2 §12.7.8)

    static func fdf(_ fields: [DataExportField]) -> Data {
        // The header, then a comment of high bytes that marks the file as binary.
        var out = Data("%FDF-1.2\n".utf8)
        out.append(contentsOf: [0x25, 0xE2, 0xE3, 0xCF, 0xD3, 0x0A])
        let tree = DataExportNode.tree(fields)
        let body = PDFValue.dictionary(["FDF": .dictionary(["Fields": .array(tree.children.map(\.fdfValue))])])
        out.append(Data("1 0 obj\n".utf8))
        out.append(body.serialized())
        out.append(Data("\nendobj\ntrailer\n<< /Root 1 0 R >>\n%%EOF\n".utf8))
        return out
    }

    // MARK: XFDF (ISO 19444-1)

    static func xfdf(_ fields: [DataExportField], annotations: [DataExportAnnotation]) -> String {
        var xml = "<?xml version=\"1.0\" encoding=\"UTF-8\"?>\n<xfdf xmlns=\"http://ns.adobe.com/xfdf/\" xml:space=\"preserve\">\n"
        let tree = DataExportNode.tree(fields)
        if !tree.children.isEmpty {
            xml += " <fields>\n"
            for child in tree.children { xml += child.xfdf(indent: 2) }
            xml += " </fields>\n"
        }
        if !annotations.isEmpty {
            xml += " <annots>\n"
            for annotation in annotations { xml += annotation.xfdf }
            xml += " </annots>\n"
        }
        xml += "</xfdf>\n"
        return xml
    }

    // MARK: JSON

    static func json(_ fields: [DataExportField]) throws -> Data {
        var object: [String: Any] = [:]
        for field in fields {
            switch field.value {
            case .none: object[field.name] = NSNull()
            case .text(let text): object[field.name] = text
            case .state(let state): object[field.name] = state
            case .choices(let choices): object[field.name] = choices
            }
        }
        return try JSONSerialization.data(withJSONObject: object, options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes])
    }
}

/// A terminal field's value, as the exports write it.
struct DataExportField: Hashable {
    enum Value: Hashable {
        case none
        case text(String)
        /// A check box's or radio button's state name ("Yes", "Off").
        case state(String)
        /// A list box with several choices.
        case choices([String])
    }

    var name: String
    var value: Value

    /// Every field that holds data (push buttons and signatures carry none), in field-tree order.
    static func read(_ model: PDFModel) -> [DataExportField] {
        model.formFields().compactMap { field in
            guard field.type != "Sig", !field.isPushButton, !field.name.isEmpty else { return nil }
            var value = field.value
            if let reference = value?.referenceValue {
                let object = model.object(id: reference.id, generation: reference.generation)
                // A long or rich text value can be a stream; otherwise the referenced object's value.
                if object.type == .stream, let data = try? object.streamData(decode: .all) {
                    value = .string(data)
                } else {
                    value = object.value
                }
            }
            let isMultiSelect = field.type == "Ch" && field.flags & (1 << 21) != 0
            switch value {
            case .some(.string(let bytes)):
                return DataExportField(name: field.name, value: .text(PDFText.decode(bytes)))
            case .some(.name(let state)):
                return DataExportField(name: field.name, value: .state(state))
            case .some(.array(let items)):
                let texts = items.compactMap { $0.textValue ?? $0.nameValue }
                return DataExportField(name: field.name, value: isMultiSelect || texts.count != 1 ? .choices(texts) : .text(texts[0]))
            case .some(.integer(let n)):
                return DataExportField(name: field.name, value: .text(String(n)))
            case .some(.real(let n)):
                return DataExportField(name: field.name, value: .text(String(n)))
            default:
                // Check boxes and radio buttons without /V are off.
                return DataExportField(name: field.name, value: field.type == "Btn" ? .state("Off") : .none)
            }
        }
    }
}

/// Field names split at "." into the hierarchy FDF and XFDF write.
private final class DataExportNode {
    let name: String
    var value: DataExportField.Value?
    var children: [DataExportNode] = []

    init(_ name: String) { self.name = name }

    static func tree(_ fields: [DataExportField]) -> DataExportNode {
        let root = DataExportNode("")
        for field in fields {
            var node = root
            for part in field.name.split(separator: ".", omittingEmptySubsequences: false).map(String.init) {
                if let existing = node.children.first(where: { $0.name == part }) {
                    node = existing
                } else {
                    let child = DataExportNode(part)
                    node.children.append(child)
                    node = child
                }
            }
            node.value = field.value
        }
        return root
    }

    var fdfValue: PDFValue {
        var dictionary: [String: PDFValue] = ["T": .text(name)]
        switch value {
        case .some(.text(let text)): dictionary["V"] = .text(text)
        case .some(.state(let state)): dictionary["V"] = .name(state)
        case .some(.choices(let choices)): dictionary["V"] = .array(choices.map { .text($0) })
        case .some(.none), nil: break
        }
        if !children.isEmpty { dictionary["Kids"] = .array(children.map(\.fdfValue)) }
        return .dictionary(dictionary)
    }

    func xfdf(indent: Int) -> String {
        let pad = String(repeating: " ", count: indent)
        var xml = "\(pad)<field name=\"\(XML.escape(name))\">\n"
        switch value {
        case .some(.text(let text)): xml += "\(pad) <value>\(XML.escape(text))</value>\n"
        case .some(.state(let state)): xml += "\(pad) <value>\(XML.escape(state))</value>\n"
        case .some(.choices(let choices)): for choice in choices { xml += "\(pad) <value>\(XML.escape(choice))</value>\n" }
        case .some(.none), nil: break
        }
        for child in children { xml += child.xfdf(indent: indent + 1) }
        xml += "\(pad)</field>\n"
        return xml
    }
}

/// A markup annotation (a comment) for XFDF's <annots>.
struct DataExportAnnotation {
    /// XFDF's element names for the markup subtypes; links, widgets and pop-ups are not comments.
    static let elements: [String: String] = [
        "Text": "text", "FreeText": "freetext", "Highlight": "highlight", "Underline": "underline", "StrikeOut": "strikeout",
        "Squiggly": "squiggly", "Square": "square", "Circle": "circle", "Line": "line", "Polygon": "polygon", "PolyLine": "polyline",
        "Ink": "ink", "Stamp": "stamp", "Caret": "caret", "FileAttachment": "fileattachment", "Sound": "sound",
    ]

    var element: String
    var page: Int
    var rect: CGRect
    var color: String?
    var contents: String?
    var author: String?
    var date: String?
    var name: String?
    var flags: Int
    var coords: [Double]
    var ink: [[Double]]
    var line: [Double]

    static func read(_ model: PDFModel) -> [DataExportAnnotation] {
        var found: [DataExportAnnotation] = []
        for (index, page) in model.pages.enumerated() {
            for annotation in page.annotations {
                guard let subtype = annotation["Subtype"]?.name, let element = elements[subtype] else { continue }
                let numbers: (PDFObject?) -> [Double] = { $0?.items.compactMap(\.number) ?? [] }
                found.append(DataExportAnnotation(
                    element: element, page: index, rect: annotation["Rect"]?.rect ?? .zero,
                    color: hexColor(numbers(annotation["C"])), contents: annotation["Contents"]?.text, author: annotation["T"]?.text,
                    date: annotation["M"]?.text, name: annotation["NM"]?.text, flags: annotation["F"]?.int ?? 0,
                    coords: numbers(annotation["QuadPoints"]) + numbers(annotation["Vertices"]),
                    ink: annotation["InkList"]?.items.map { $0.items.compactMap(\.number) } ?? [],
                    line: numbers(annotation["L"])))
            }
        }
        return found
    }

    /// "#RRGGBB" from DeviceRGB, grey or CMYK components.
    private static func hexColor(_ c: [Double]) -> String? {
        let rgb: [Double]
        switch c.count {
        case 1: rgb = [c[0], c[0], c[0]]
        case 3: rgb = c
        case 4: rgb = [(1 - c[0]) * (1 - c[3]), (1 - c[1]) * (1 - c[3]), (1 - c[2]) * (1 - c[3])]
        default: return nil
        }
        return "#" + rgb.map { String(format: "%02X", Int((min(max($0, 0), 1) * 255).rounded())) }.joined()
    }

    private static func list(_ values: [Double]) -> String { values.map { DataExportAnnotation.number($0) }.joined(separator: ",") }

    private static func number(_ value: Double) -> String {
        value.rounded() == value ? String(Int(value)) : String(format: "%.3f", value)
    }

    var xfdf: String {
        let r = rect.standardized
        var attributes = "page=\"\(page)\" rect=\"\(Self.list([r.minX, r.minY, r.maxX, r.maxY]))\" flags=\"\(flags)\""
        if let color { attributes += " color=\"\(color)\"" }
        if let author { attributes += " title=\"\(XML.escape(author))\"" }
        if let date { attributes += " date=\"\(XML.escape(date))\"" }
        if let name { attributes += " name=\"\(XML.escape(name))\"" }
        if !coords.isEmpty { attributes += " coords=\"\(Self.list(coords))\"" }
        if line.count == 4 {
            attributes += " start=\"\(Self.list(Array(line[0...1])))\" end=\"\(Self.list(Array(line[2...3])))\""
        }
        var xml = "  <\(element) \(attributes)>\n"
        if let contents, !contents.isEmpty { xml += "   <contents>\(XML.escape(contents))</contents>\n" }
        if !ink.isEmpty {
            xml += "   <inklist>\n"
            for stroke in ink {
                let points = stride(from: 0, to: stroke.count - 1, by: 2).map { "\(Self.number(stroke[$0])),\(Self.number(stroke[$0 + 1]))" }
                xml += "    <gesture>\(points.joined(separator: ";"))</gesture>\n"
            }
            xml += "   </inklist>\n"
        }
        xml += "  </\(element)>\n"
        return xml
    }
}
