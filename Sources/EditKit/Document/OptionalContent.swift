import Foundation
import PDFModelKit

// Layers (features #71, #12; ISO 32000-2 §8.11): the optional content groups, their default visibility, and
// "flatten layers", which removes the content of hidden groups and the layer machinery.

public struct ContentLayer: Hashable, Sendable {
    /// The OCG's object number.
    public var id: Int
    public var name: String
    public var isVisible: Bool
}

public enum OptionalContent {
    /// The document's layers in the default configuration's order.
    public static func layers(in model: PDFModel) -> [ContentLayer] {
        guard let properties = model.root["OCProperties"], let groups = properties["OCGs"] else { return [] }
        let off = Set((properties["D"]?["OFF"]?.items ?? []).compactMap(\.objectID))
        var seen: Set<Int> = []
        var out: [ContentLayer] = []
        for group in (properties["D"]?["Order"]?.items ?? []) + groups.items {
            guard let id = group.objectID, group.type == .dictionary, group["Type"]?.name == "OCG", seen.insert(id).inserted else { continue }
            out.append(ContentLayer(id: id, name: group["Name"]?.text ?? "Layer \(out.count + 1)", isVisible: !off.contains(id)))
        }
        return out
    }

    /// Shows or hides a layer by default.
    public static func setVisible(_ visible: Bool, layer id: Int, in model: PDFModel) {
        guard let properties = model.root["OCProperties"] else { return }
        let defaults = properties.dictionary("D")
        let group = model.object(id: id)
        for key in ["ON", "OFF"] {
            let array = defaults.array(key)
            for index in stride(from: array.count - 1, through: 0, by: -1) where array[index]?.objectID == id { array.removeItem(at: index) }
        }
        defaults.array(visible ? "ON" : "OFF").append(group)
    }

    /// The object numbers of hidden groups.
    public static func hiddenLayers(in model: PDFModel) -> Set<Int> {
        Set(layers(in: model).filter { !$0.isVisible }.map(\.id))
    }

    /// Removes the content of hidden layers from every page (marked spans and XObjects) and the layer machinery, so
    /// what was shown is all that is left.
    public static func flatten(_ model: PDFModel) throws {
        let hidden = hiddenLayers(in: model)
        for page in model.pages {
            var stream = try page.contentStream()
            let resources = page.resources
            stream.removeMarkedContent { span in
                guard span.tag == "OC" else { return false }
                if let name = span.properties?.nameValue, let group = resources?["Properties"]?[name] { return isHidden(group, hidden: hidden) }
                return false
            }
            // XObjects with a hidden /OC: drop the operations that draw them.
            var removed: Set<Int> = []
            for (index, op) in stream.operations.enumerated() where op.operator == "Do" {
                guard let name = op.operands.first?.nameValue, let xobject = resources?["XObject"]?[name], let oc = xobject["OC"] else { continue }
                if isHidden(oc, hidden: hidden) { removed.insert(index) }
            }
            if !removed.isEmpty { stream.operations = stream.operations.enumerated().filter { !removed.contains($0.offset) }.map(\.element) }
            page.setContentStream(stream)
            // Annotations on hidden layers.
            if let annots = page.object["Annots"] {
                for index in stride(from: annots.count - 1, through: 0, by: -1) {
                    if let oc = annots[index]?["OC"], isHidden(oc, hidden: hidden) { annots.removeItem(at: index) }
                }
            }
            for annotation in page.annotations { annotation.remove("OC") }
            // Visible XObjects lose their /OC so no viewer hides them later.
            if let xobjects = resources?["XObject"] { for name in xobjects.keys { xobjects[name]?.remove("OC") } }
        }
        model.root.remove("OCProperties")
    }

    static func isHidden(_ oc: PDFObject, hidden: Set<Int>) -> Bool {
        if let id = oc.objectID, hidden.contains(id) { return true }
        if oc["Type"]?.name == "OCMD", let groups = oc["OCGs"] {
            if let id = groups.objectID { return hidden.contains(id) }
            let ids = groups.items.compactMap(\.objectID)
            switch oc["P"]?.name ?? "AnyOn" {
            case "AllOn": return ids.contains(where: hidden.contains)
            case "AnyOff": return !ids.contains(where: hidden.contains)
            case "AllOff": return ids.contains { !hidden.contains($0) }
            default: return !ids.isEmpty && ids.allSatisfy(hidden.contains)
            }
        }
        return false
    }
}
