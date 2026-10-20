import Foundation

// The logical structure tree (ISO 32000-2 §14.7): read it into values and write one back with its parent tree, page
// /StructParents and /MarkInfo, for auto-tagging, reading order and alt text (features #97, #123). Marking the content
// with MCIDs is done on the content streams (`PDFContentStream.markedContent`).

/// A structure element.
public struct PDFStructureElement: Hashable, Sendable {
    /// /S as written ("P", "H1", "Figure", or a role-mapped custom type).
    public var type: String
    public var title: String?
    public var alternateText: String?
    public var actualText: String?
    public var language: String?
    /// /ID.
    public var identifier: String?
    /// /A attributes as written (a dictionary or an array of them).
    public var attributes: PDFValue?
    /// The default page of its content (/Pg).
    public var page: Int?
    public var kids: [PDFStructureKid]

    public init(type: String, title: String? = nil, alternateText: String? = nil, actualText: String? = nil,
                language: String? = nil, identifier: String? = nil, attributes: PDFValue? = nil, page: Int? = nil,
                kids: [PDFStructureKid] = []) {
        self.type = type; self.title = title; self.alternateText = alternateText; self.actualText = actualText
        self.language = language; self.identifier = identifier; self.attributes = attributes; self.page = page; self.kids = kids
    }
}

public enum PDFStructureKid: Hashable, Sendable {
    case element(PDFStructureElement)
    /// Marked content with /MCID `mcid` on `page`.
    case markedContent(page: Int, mcid: Int)
    /// An annotation (by object number) on `page`.
    case annotation(page: Int, objectID: Int)
}

public struct PDFStructureTree: Hashable, Sendable {
    /// /RoleMap: custom type → standard type.
    public var roleMap: [String: String]
    /// The children of the structure tree root, in reading order.
    public var elements: [PDFStructureElement]

    public init(roleMap: [String: String] = [:], elements: [PDFStructureElement]) {
        self.roleMap = roleMap; self.elements = elements
    }
}

extension PDFModel {
    // MARK: Reading

    /// The structure tree; nil when the file is not tagged.
    public func structureTree() -> PDFStructureTree? {
        guard let treeRoot = root["StructTreeRoot"], treeRoot.type == .dictionary else { return nil }
        var roleMap: [String: String] = [:]
        if let map = treeRoot["RoleMap"] {
            for key in map.keys { if let target = map[key]?.name { roleMap[key] = target } }
        }
        var seen: Set<Int> = []
        let kids = structureKids(treeRoot["K"], page: nil, seen: &seen, depth: 0)
        return PDFStructureTree(roleMap: roleMap, elements: kids.compactMap { if case .element(let e) = $0 { e } else { nil } })
    }

    private func structureKids(_ k: PDFObject?, page: Int?, seen: inout Set<Int>, depth: Int) -> [PDFStructureKid] {
        guard let k, depth < 256 else { return [] }
        if k.type == .array { return k.items.flatMap { structureKids($0, page: page, seen: &seen, depth: depth) } }
        if let mcid = k.int { return page.map { [.markedContent(page: $0, mcid: mcid)] } ?? [] }
        guard k.type == .dictionary else { return [] }
        if let id = k.objectID { guard seen.insert(id).inserted else { return [] } }
        let kidPage = k["Pg"].flatMap { PDFPage($0).index } ?? page
        switch k["Type"]?.name {
        case "MCR":
            guard let mcid = k["MCID"]?.int, let p = kidPage else { return [] }
            return [.markedContent(page: p, mcid: mcid)]
        case "OBJR":
            guard let id = k["Obj"]?.objectID, let p = kidPage else { return [] }
            return [.annotation(page: p, objectID: id)]
        default:
            guard let type = k["S"]?.name else { return [] }
            return [.element(PDFStructureElement(
                type: type,
                title: k["T"]?.text,
                alternateText: k["Alt"]?.text,
                actualText: k["ActualText"]?.text,
                language: k["Lang"]?.text,
                identifier: k["ID"]?.text,
                attributes: k["A"].map { $0.reference ?? $0.value },
                page: k["Pg"].flatMap { PDFPage($0).index },
                kids: structureKids(k["K"], page: kidPage, seen: &seen, depth: depth + 1)))]
        }
    }

    // MARK: Writing

    /// Replaces the structure tree (nil removes it): writes the elements, the parent tree, each page's
    /// /StructParents, annotations' /StructParent and the catalog's /MarkInfo.
    public func setStructureTree(_ tree: PDFStructureTree?) throws {
        let allPages = pages
        for page in allPages {
            page.object.remove("StructParents")
            for annot in page.annotations { annot.remove("StructParent") }
        }
        root.remove("StructTreeRoot")
        guard let tree else {
            root.remove("MarkInfo")
            return
        }
        let treeRoot = makeIndirect(.dictionary(["Type": .name("StructTreeRoot")]))
        if !tree.roleMap.isEmpty { treeRoot.set("RoleMap", .dictionary(tree.roleMap.mapValues { .name($0) })) }

        var mcidOwners: [Int: [Int: PDFObject]] = [:]          // page → MCID → element
        var annotationOwners: [(PDFObject, PDFObject)] = []      // annotation → element
        func pageRef(_ index: Int) throws -> PDFValue {
            guard index >= 0, index < allPages.count, let ref = allPages[index].object.reference else {
                throw PDFModelError.invalidOperation("structure refers to page \(index)")
            }
            return ref
        }
        func write(_ element: PDFStructureElement, parent: PDFObject, inheritedPage: Int?) throws -> PDFObject {
            let node = makeIndirect(.dictionary(["Type": .name("StructElem"), "S": .name(element.type)]))
            node.set("P", parent)
            let page = element.page ?? inheritedPage
            if let p = element.page { node.set("Pg", try pageRef(p)) }
            if let v = element.title { node.set("T", .text(v)) }
            if let v = element.alternateText { node.set("Alt", .text(v)) }
            if let v = element.actualText { node.set("ActualText", .text(v)) }
            if let v = element.language { node.set("Lang", .text(v)) }
            if let v = element.identifier { node.set("ID", .text(v)) }
            if let v = element.attributes { node.set("A", v) }
            let kids = make(.array([]))
            for kid in element.kids {
                switch kid {
                case .element(let child):
                    kids.append(try write(child, parent: node, inheritedPage: page))
                case .markedContent(let p, let mcid):
                    if p == page && element.page != nil {
                        kids.append(.integer(mcid))
                    } else {
                        kids.append(.dictionary(["Type": .name("MCR"), "Pg": try pageRef(p), "MCID": .integer(mcid)]))
                    }
                    mcidOwners[p, default: [:]][mcid] = node
                case .annotation(let p, let id):
                    let annot = object(id: id)
                    guard annot.type == .dictionary else { throw PDFModelError.invalidOperation("no annotation \(id)") }
                    kids.append(.dictionary(["Type": .name("OBJR"), "Pg": try pageRef(p), "Obj": annot.reference!]))
                    annotationOwners.append((annot, node))
                }
            }
            if kids.count == 1, let only = kids[0] { node.set("K", only) } else if kids.count > 0 { node.set("K", kids) }
            return node
        }
        let top = make(.array([]))
        for element in tree.elements { top.append(try write(element, parent: treeRoot, inheritedPage: nil)) }
        treeRoot.set("K", top)

        var entries: [(key: Int, value: PDFObject)] = []
        var key = 0
        for page in mcidOwners.keys.sorted() {
            let owners = mcidOwners[page]!
            let array = makeIndirect(.array(Array(repeating: .null, count: (owners.keys.max() ?? -1) + 1)))
            for (mcid, element) in owners { array.replaceItem(at: mcid, with: element) }
            allPages[page].object.set("StructParents", .integer(key))
            entries.append((key, array))
            key += 1
        }
        for (annot, element) in annotationOwners {
            annot.set("StructParent", .integer(key))
            entries.append((key, element))
            key += 1
        }
        treeRoot.set("ParentTree", makeIndirect(PDFNumberTree.make(in: self, entries: entries)))
        treeRoot.set("ParentTreeNextKey", .integer(key))
        root.set("StructTreeRoot", treeRoot)
        root.set("MarkInfo", .dictionary(["Marked": .bool(true)]))
    }
}
