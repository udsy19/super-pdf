import Foundation
import PDFModelKit

// Named destinations (features #114; ISO 32000-2 §12.3.2.3): the catalog's /Dests dictionary (PDF 1.1) and the
// /Names /Dests name tree, read together and written back as one name tree.

public struct NamedDestination: Hashable, Sendable {
    public var name: String
    public var destination: PDFDestination

    public init(name: String, destination: PDFDestination) { self.name = name; self.destination = destination }
}

public enum NamedDestinations {
    /// Every named destination, sorted by name.
    public static func read(from model: PDFModel) -> [NamedDestination] {
        var out: [String: PDFDestination] = [:]
        if let dests = model.root["Dests"] {
            for key in dests.keys { if let destination = model.destination(from: dests[key]) { out[key] = destination } }
        }
        if let tree = model.root["Names"]?["Dests"] {
            for (key, value) in PDFNameTree.entries(of: tree) {
                if let destination = model.destination(from: value) { out[PDFText.decode(key)] = destination }
            }
        }
        return out.map { NamedDestination(name: $0.key, destination: $0.value) }.sorted { $0.name < $1.name }
    }

    /// Writes the full list (replacing both forms with one name tree).
    public static func write(_ destinations: [NamedDestination], to model: PDFModel) {
        model.root.remove("Dests")
        let entries: [(key: Data, value: PDFObject)] = destinations.compactMap { item in
            guard let value = model.destinationValue(item.destination) else { return nil }
            return (PDFText.encode(item.name), model.make(.dictionary(["D": value])))
        }
        if entries.isEmpty {
            model.root["Names"]?.remove("Dests")
            if model.root["Names"]?.keys.isEmpty == true { model.root.remove("Names") }
            return
        }
        let names = model.root.dictionary("Names")
        names.set("Dests", PDFNameTree.make(in: model, entries: entries))
    }

    /// Adds or replaces one destination.
    public static func set(_ destination: NamedDestination, in model: PDFModel) {
        var all = read(from: model).filter { $0.name != destination.name }
        all.append(destination)
        write(all, to: model)
    }

    /// Renames a destination, keeping links that use the old name working by updating their actions.
    public static func rename(_ name: String, to newName: String, in model: PDFModel) {
        let all = read(from: model).map { item -> NamedDestination in
            item.name == name ? NamedDestination(name: newName, destination: item.destination) : item
        }
        write(all, to: model)
        for page in model.pages {
            for annotation in page.annotations {
                if let dest = annotation["Dest"], dest.text == name { annotation.set("Dest", .text(newName)) }
                if let action = annotation["A"], action["S"]?.name == "GoTo", action["D"]?.text == name { action.set("D", .text(newName)) }
            }
        }
    }

    public static func remove(_ name: String, from model: PDFModel) {
        write(read(from: model).filter { $0.name != name }, to: model)
    }
}
