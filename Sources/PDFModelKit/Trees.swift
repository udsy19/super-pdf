import Foundation

// Name trees and number trees (ISO 32000-2 §7.9.6, §7.9.7): read every entry in key order through /Kids, and write a
// tree back as one flat node (/Names or /Nums), which every reader accepts.

public enum PDFNameTree {
    /// Every entry, in tree order. Keys are the strings' bytes (`PDFText.decode` for text keys).
    public static func entries(of root: PDFObject) -> [(key: Data, value: PDFObject)] {
        var result: [(Data, PDFObject)] = []
        walk(root, leafKey: "Names", depth: 0, seen: []) { pairs in
            var i = 0
            while i + 1 < pairs.count {
                if let key = pairs[i].stringData { result.append((key, pairs[i + 1])) }
                i += 2
            }
        }
        return result
    }

    /// The value for `key`.
    public static func value(for key: Data, in root: PDFObject) -> PDFObject? {
        entries(of: root).first { $0.key == key }?.value
    }

    /// A one-node tree (a direct dictionary with /Names) holding `entries` sorted by key.
    public static func make(in model: PDFModel, entries: [(key: Data, value: PDFObject)]) -> PDFObject {
        let names = model.make(.array([]))
        for entry in entries.sorted(by: { $0.key.lexicographicallyPrecedes($1.key) }) {
            names.append(.string(entry.key))
            names.append(entry.value)
        }
        let node = model.make(.dictionary([:]))
        node.set("Names", names)
        return node
    }

    static func walk(_ node: PDFObject, leafKey: String, depth: Int, seen: Set<Int>, visit: ([PDFObject]) -> Void) {
        guard depth < 64 else { return }
        var seen = seen
        if let id = node.objectID { guard seen.insert(id).inserted else { return } }
        if let leaf = node[leafKey], leaf.type == .array { visit(leaf.items) }
        for kid in node["Kids"]?.items ?? [] { walk(kid, leafKey: leafKey, depth: depth + 1, seen: seen, visit: visit) }
    }
}

public enum PDFNumberTree {
    /// Every entry, in tree order.
    public static func entries(of root: PDFObject) -> [(key: Int, value: PDFObject)] {
        var result: [(Int, PDFObject)] = []
        PDFNameTree.walk(root, leafKey: "Nums", depth: 0, seen: []) { pairs in
            var i = 0
            while i + 1 < pairs.count {
                if let key = pairs[i].int { result.append((key, pairs[i + 1])) }
                i += 2
            }
        }
        return result
    }

    /// A one-node tree (a direct dictionary with /Nums) holding `entries` sorted by key.
    public static func make(in model: PDFModel, entries: [(key: Int, value: PDFObject)]) -> PDFObject {
        let nums = model.make(.array([]))
        for entry in entries.sorted(by: { $0.key < $1.key }) {
            nums.append(.integer(entry.key))
            nums.append(entry.value)
        }
        let node = model.make(.dictionary([:]))
        node.set("Nums", nums)
        return node
    }
}
