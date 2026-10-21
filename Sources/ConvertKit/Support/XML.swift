import Foundation

// A small XML tree for the readers (OOXML, OpenDocument manifests, EPUB packages, HWPX) and escaping for the writers.
// Names keep their prefix (`w:p`); lookups match the local part, so readers don't depend on the prefixes a producer
// chose. External entities are never resolved.

final class XMLNode {
    enum Content {
        case text(String)
        case element(XMLNode)
    }

    /// The qualified name as written ("w:p").
    let qualifiedName: String
    /// The local part ("p").
    let name: String
    let attributes: [String: String]
    private(set) var content: [Content] = []

    init(_ qualifiedName: String, attributes: [String: String] = [:]) {
        self.qualifiedName = qualifiedName
        name = qualifiedName.split(separator: ":").last.map(String.init) ?? qualifiedName
        self.attributes = attributes
    }

    var children: [XMLNode] {
        content.compactMap { if case .element(let node) = $0 { node } else { nil } }
    }

    /// The text directly inside this element.
    var text: String {
        content.reduce(into: "") { if case .text(let t) = $1 { $0 += t } }
    }

    /// All text inside, depth first.
    var allText: String {
        content.reduce(into: "") {
            switch $1 {
            case .text(let t): $0 += t
            case .element(let node): $0 += node.allText
            }
        }
    }

    func child(_ local: String) -> XMLNode? { children.first { $0.name == local } }
    func children(_ local: String) -> [XMLNode] { children.filter { $0.name == local } }

    /// The first descendant with this local name, depth first.
    func first(_ local: String) -> XMLNode? {
        for child in children {
            if child.name == local { return child }
            if let found = child.first(local) { return found }
        }
        return nil
    }

    /// Every descendant with this local name, in document order.
    func all(_ local: String) -> [XMLNode] {
        var found: [XMLNode] = []
        for child in children {
            if child.name == local { found.append(child) }
            found += child.all(local)
        }
        return found
    }

    /// An attribute by qualified name ("r:id") or, failing that, by local name ("id").
    func attr(_ name: String) -> String? {
        if let value = attributes[name] { return value }
        let local = name.split(separator: ":").last.map(String.init) ?? name
        return attributes.first { ($0.key.split(separator: ":").last.map(String.init) ?? $0.key) == local }?.value
    }

    /// Follows a path of local names ("spPr/xfrm/off").
    func path(_ path: String) -> XMLNode? {
        path.split(separator: "/").reduce(self as XMLNode?) { $0?.child(String($1)) }
    }

    fileprivate func append(_ node: XMLNode) { content.append(.element(node)) }

    fileprivate func append(_ text: String) {
        if case .text(let previous)? = content.last {
            content[content.count - 1] = .text(previous + text)
        } else {
            content.append(.text(text))
        }
    }
}

enum XML {
    struct ParseError: Error { var message: String }

    /// Parses a document; whitespace-only text between elements is dropped unless `keepWhitespace`.
    static func parse(_ data: Data, keepWhitespace: Bool = false) throws -> XMLNode {
        let builder = Builder(keepWhitespace: keepWhitespace)
        let parser = XMLParser(data: data)
        parser.shouldProcessNamespaces = false
        parser.shouldResolveExternalEntities = false
        parser.delegate = builder
        guard parser.parse(), let root = builder.root else {
            throw ParseError(message: parser.parserError?.localizedDescription ?? "unreadable XML")
        }
        return root
    }

    /// Text for element content and attribute values: the five entities escaped, characters XML 1.0 forbids dropped.
    static func escape(_ text: String) -> String {
        var out = ""
        out.reserveCapacity(text.utf8.count)
        for scalar in text.unicodeScalars {
            switch scalar {
            case "&": out += "&amp;"
            case "<": out += "&lt;"
            case ">": out += "&gt;"
            case "\"": out += "&quot;"
            case "'": out += "&apos;"
            case "\t", "\n", "\r": out.unicodeScalars.append(scalar)
            default:
                let v = scalar.value
                if v >= 0x20 && v != 0xFFFE && v != 0xFFFF && !(0xD800...0xDFFF).contains(v) { out.unicodeScalars.append(scalar) }
            }
        }
        return out
    }

    private final class Builder: NSObject, XMLParserDelegate {
        let keepWhitespace: Bool
        var root: XMLNode?
        var stack: [XMLNode] = []

        init(keepWhitespace: Bool) { self.keepWhitespace = keepWhitespace }

        func parser(_ parser: XMLParser, didStartElement elementName: String, namespaceURI: String?, qualifiedName: String?,
                    attributes: [String: String] = [:]) {
            let node = XMLNode(elementName, attributes: attributes)
            if let top = stack.last { top.append(node) } else { root = node }
            stack.append(node)
        }

        func parser(_ parser: XMLParser, didEndElement elementName: String, namespaceURI: String?, qualifiedName: String?) {
            _ = stack.popLast()
        }

        func parser(_ parser: XMLParser, foundCharacters string: String) {
            guard let top = stack.last else { return }
            if !keepWhitespace, string.allSatisfy(\.isWhitespace), !Self.keepsSpace(top) { return }
            top.append(string)
        }

        func parser(_ parser: XMLParser, foundCDATA CDATABlock: Data) {
            stack.last?.append(String(decoding: CDATABlock, as: UTF8.self))
        }

        /// Text runs (`w:t`, `a:t`, `hp:t`, `t`) keep their spaces.
        private static func keepsSpace(_ node: XMLNode) -> Bool { node.name == "t" || node.attr("xml:space") == "preserve" }
    }
}
