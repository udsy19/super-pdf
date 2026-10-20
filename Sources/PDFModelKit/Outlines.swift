import CoreGraphics
import Foundation

// Outlines (bookmarks, ISO 32000-2 §12.3.3) and destinations (§12.3.2): read the whole tree with explicit, named and
// GoTo-action destinations resolved to page indices, and write a tree back.

/// Where a destination shows its page (§12.3.2.2). Nil coordinates keep the viewer's current value.
public enum PDFDestinationView: Hashable, Sendable {
    case xyz(left: Double?, top: Double?, zoom: Double?)
    case fit
    case fitH(top: Double?)
    case fitV(left: Double?)
    case fitR(CGRect)
    case fitB
    case fitBH(top: Double?)
    case fitBV(left: Double?)
}

/// An explicit destination: a page (0-based) and a view.
public struct PDFDestination: Hashable, Sendable {
    public var page: Int
    public var view: PDFDestinationView

    public init(page: Int, view: PDFDestinationView = .fit) { self.page = page; self.view = view }
}

/// A bookmark.
public struct PDFOutlineItem: Hashable, Sendable {
    public var title: String
    public var destination: PDFDestination?
    /// A URI action's target, when the item opens a link instead.
    public var uri: String?
    /// Shown expanded.
    public var isOpen: Bool
    /// /C as RGB 0…1.
    public var color: [Double]?
    /// /F bits: 1 italic, 2 bold.
    public var flags: Int
    public var children: [PDFOutlineItem]

    public init(title: String, destination: PDFDestination? = nil, uri: String? = nil, isOpen: Bool = false,
                color: [Double]? = nil, flags: Int = 0, children: [PDFOutlineItem] = []) {
        self.title = title; self.destination = destination; self.uri = uri; self.isOpen = isOpen
        self.color = color; self.flags = flags; self.children = children
    }
}

extension PDFModel {
    // MARK: Destinations

    /// Resolves a destination value: an explicit array, a name or string looked up in /Dests or the /Dests name
    /// tree, or a dictionary with /D.
    public func destination(from object: PDFObject?) -> PDFDestination? {
        resolveDestination(object, depth: 0)
    }

    private func resolveDestination(_ object: PDFObject?, depth: Int) -> PDFDestination? {
        guard let object, depth < 8 else { return nil }
        switch object.type {
        case .array:
            return explicitDestination(object)
        case .name:
            return resolveDestination(root["Dests"]?[object.name!], depth: depth + 1)
        case .string:
            guard let tree = root["Names"]?["Dests"] else { return nil }
            return resolveDestination(PDFNameTree.value(for: object.stringData!, in: tree), depth: depth + 1)
        case .dictionary:
            return resolveDestination(object["D"], depth: depth + 1)
        default:
            return nil
        }
    }

    private func explicitDestination(_ array: PDFObject) -> PDFDestination? {
        guard let target = array[0] else { return nil }
        let page: Int
        if let number = target.int, !target.isIndirect {
            page = number   // a remote-style page number
        } else {
            guard let p = PDFPage(target).index else { return nil }
            page = p
        }
        let args = (1..<max(array.count, 1)).map { array[$0]?.number }
        func arg(_ i: Int) -> Double? { i < args.count ? args[i] : nil }
        let view: PDFDestinationView
        switch array[1]?.name {
        case "XYZ": view = .xyz(left: arg(1), top: arg(2), zoom: arg(3).flatMap { $0 == 0 ? nil : $0 })
        case "FitH": view = .fitH(top: arg(1))
        case "FitV": view = .fitV(left: arg(1))
        case "FitR":
            let n = (1...4).compactMap(arg)
            view = n.count == 4 ? .fitR(CGRect(x: n[0], y: n[1], width: n[2] - n[0], height: n[3] - n[1]).standardized) : .fit
        case "FitB": view = .fitB
        case "FitBH": view = .fitBH(top: arg(1))
        case "FitBV": view = .fitBV(left: arg(1))
        default: view = .fit
        }
        return PDFDestination(page: page, view: view)
    }

    /// An explicit destination array for this model.
    public func destinationValue(_ destination: PDFDestination) -> PDFValue? {
        guard let page = page(at: destination.page), let ref = page.object.reference else { return nil }
        func n(_ v: Double?) -> PDFValue { v.map { PDFValue.number($0) } ?? .null }
        let rest: [PDFValue]
        switch destination.view {
        case .xyz(let l, let t, let z): rest = [.name("XYZ"), n(l), n(t), n(z)]
        case .fit: rest = [.name("Fit")]
        case .fitH(let t): rest = [.name("FitH"), n(t)]
        case .fitV(let l): rest = [.name("FitV"), n(l)]
        case .fitR(let r): rest = [.name("FitR")] + PDFValue.rect(r).arrayValue!
        case .fitB: rest = [.name("FitB")]
        case .fitBH(let t): rest = [.name("FitBH"), n(t)]
        case .fitBV(let l): rest = [.name("FitBV"), n(l)]
        }
        return .array([ref] + rest)
    }

    // MARK: Outlines

    /// The bookmark tree (empty when the file has none).
    public func outlines() -> [PDFOutlineItem] {
        var seen: Set<Int> = []
        return outlineChildren(of: root["Outlines"], seen: &seen, depth: 0)
    }

    private func outlineChildren(of parent: PDFObject?, seen: inout Set<Int>, depth: Int) -> [PDFOutlineItem] {
        guard depth < 64 else { return [] }
        var items: [PDFOutlineItem] = []
        var node = parent?["First"]
        while let current = node {
            if let id = current.objectID { guard seen.insert(id).inserted else { break } }
            var destination = destination(from: current["Dest"])
            var uri: String?
            if let action = current["A"] {
                switch action["S"]?.name {
                case "GoTo": destination = destination ?? self.destination(from: action["D"])
                case "URI": uri = action["URI"]?.stringData.map { String(decoding: $0, as: UTF8.self) }
                default: break
                }
            }
            items.append(PDFOutlineItem(
                title: current["Title"]?.text ?? "",
                destination: destination,
                uri: uri,
                isOpen: (current["Count"]?.int ?? 0) > 0,
                color: current["C"]?.items.compactMap(\.number),
                flags: current["F"]?.int ?? 0,
                children: outlineChildren(of: current, seen: &seen, depth: depth + 1)))
            node = current["Next"]
        }
        return items
    }

    /// Replaces the bookmark tree (an empty list removes it).
    public func setOutlines(_ items: [PDFOutlineItem]) {
        guard !items.isEmpty else { root.remove("Outlines"); return }
        let outlines = makeIndirect(.dictionary(["Type": .name("Outlines")]))
        let visible = writeOutlineChildren(items, parent: outlines)
        outlines.set("Count", .integer(visible))
        root.set("Outlines", outlines)
    }

    /// Writes `items` under `parent` and returns how many entries show when `parent` is open.
    private func writeOutlineChildren(_ items: [PDFOutlineItem], parent: PDFObject) -> Int {
        let nodes = items.map { _ in makeIndirect(.dictionary([:])) }
        var visible = 0
        for (i, item) in items.enumerated() {
            let node = nodes[i]
            node.set("Title", .text(item.title))
            node.set("Parent", parent)
            if i > 0 { node.set("Prev", nodes[i - 1]) }
            if i + 1 < nodes.count { node.set("Next", nodes[i + 1]) }
            if let uri = item.uri {
                node.set("A", .dictionary(["S": .name("URI"), "URI": .ascii(uri)]))
            } else if let destination = item.destination, let value = destinationValue(destination) {
                node.set("Dest", value)
            }
            if let color = item.color, color.count == 3 { node.set("C", .array(color.map { .number($0) })) }
            if item.flags != 0 { node.set("F", .integer(item.flags)) }
            visible += 1
            if !item.children.isEmpty {
                let childVisible = writeOutlineChildren(item.children, parent: node)
                node.set("Count", .integer(item.isOpen ? childVisible : -childVisible))
                if item.isOpen { visible += childVisible }
            }
        }
        if let first = nodes.first, let last = nodes.last {
            parent.set("First", first)
            parent.set("Last", last)
        }
        return visible
    }
}
