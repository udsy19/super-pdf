import Foundation
import PDFModelKit

// A removed page must leave the file. Taking it out of the page tree isn't enough: bookmarks, named destinations,
// links, the open action, article threads, the structure tree (its elements' /Pg, marked-content and object
// references, the parent tree) and form fields still point at it or at its annotations, and anything reachable is
// written. So a save that removes pages takes every such reference out (or points it elsewhere) before the whole file
// is rewritten, and what only the removed pages used is no longer reachable and isn't written:
// - bookmarks that go to a removed page go, their children take their place;
// - named destinations of a removed page go; links on other pages that go there lose their destination or action;
// - an open action that goes there goes to the first page instead;
// - article beads on a removed page leave their thread (a thread left without beads goes);
// - structure elements whose content was only on removed pages go with their subtree; others lose the marked-content
//   and object references to them; parent tree and ID tree entries for them go;
// - page labels keep the label each remaining page had.
// Last, a sweep over everything still reachable clears any other reference to a removed page, its annotations or a
// removed structure element, so nothing of them is written whatever the file links them from.

final class RemovedPages {
    let model: PDFModel
    /// Object numbers of the removed pages, of the annotations only they had, and of removed structure elements.
    let pages: Set<Int>
    let annotations: Set<Int>
    private(set) var elements: Set<Int> = []
    private let removed: [PDFObject]
    private var namedTree: [Data: PDFObject]?

    /// `removed` are the file's pages the save leaves out; `kept` the pages of the result.
    init(model: PDFModel, removed: [PDFObject], kept: [PDFObject]) {
        self.model = model
        self.removed = removed
        pages = Set(removed.compactMap(\.objectID))
        let keptAnnotations = Set(kept.flatMap { $0["Annots"]?.items ?? [] }.compactMap(\.objectID))
        annotations = Set(removed.flatMap { $0["Annots"]?.items ?? [] }.compactMap(\.objectID)).subtracting(keptAnnotations)
    }

    /// The removed pages' widgets (they leave the form).
    var widgets: Set<Int> {
        Set(removed.flatMap { $0["Annots"]?.items ?? [] }.filter { $0["Subtype"]?.name == "Widget" }.compactMap(\.objectID)).intersection(annotations)
    }

    /// Takes the removed pages out of everything (run once the page tree is final). `sources` is, per page of the
    /// result, its index in the file before (nil for a page from elsewhere). Returns how many stray references the
    /// final sweep cleared.
    func run(sources: [Int?]) -> Int {
        guard !pages.isEmpty else { return 0 }
        outline()
        links()
        openAction()
        threads()
        structureTree()
        namedDestinations()
        formOrder()
        pageLabels(sources)
        return sweep()
    }

    // MARK: Destinations

    /// The explicit destination array a destination (array, name, string or dictionary with /D) resolves to.
    private func explicit(_ destination: PDFObject?, depth: Int = 0) -> PDFObject? {
        guard let destination, depth < 8 else { return nil }
        switch destination.type {
        case .array: return destination
        case .dictionary: return explicit(destination["D"], depth: depth + 1)
        case .name: return explicit(model.root["Dests"]?[destination.name!], depth: depth + 1)
        case .string:
            if namedTree == nil {
                namedTree = Dictionary((model.root["Names"]?["Dests"]).map(PDFNameTree.entries)?.map { ($0.key, $0.value) } ?? [],
                                       uniquingKeysWith: { a, _ in a })
            }
            return explicit(namedTree?[destination.stringData!], depth: depth + 1)
        default: return nil
        }
    }

    private func goesToRemovedPage(_ destination: PDFObject?) -> Bool {
        explicit(destination)?[0]?.objectID.map(pages.contains) ?? false
    }

    /// Where a link or bookmark goes: its /Dest, or its GoTo action's.
    private func goesToRemovedPage(item: PDFObject) -> Bool {
        if goesToRemovedPage(item["Dest"]) { return true }
        guard let action = item["A"], action["S"]?.name == "GoTo" else { return false }
        return goesToRemovedPage(action["D"])
    }

    // MARK: Bookmarks

    private struct Bookmark {
        var object: PDFObject
        var children: [Bookmark]
        var isOpen: Bool { (object["Count"]?.int ?? 0) > 0 }
    }

    private func outline() {
        guard let root = model.root["Outlines"] else { return }
        var seen: Set<Int> = []
        func read(_ parent: PDFObject, depth: Int) -> [Bookmark] {
            guard depth < 64 else { return [] }
            var items: [Bookmark] = []
            var node = parent["First"]
            while let current = node, current.type == .dictionary {
                if let id = current.objectID { guard seen.insert(id).inserted else { break } }
                items.append(Bookmark(object: current, children: read(current, depth: depth + 1)))
                node = current["Next"]
            }
            return items
        }
        var dropped = false
        func prune(_ items: [Bookmark]) -> [Bookmark] {
            items.flatMap { item -> [Bookmark] in
                var item = item
                item.children = prune(item.children)
                guard goesToRemovedPage(item: item.object) else { return [item] }
                dropped = true
                return item.children
            }
        }
        let items = prune(read(root, depth: 0))
        guard dropped else { return }
        let visible = Self.link(items, under: root)
        root.set("Count", .integer(visible))
    }

    /// Chains `items` under `parent` (/Parent, /Prev, /Next, /First, /Last, /Count) and returns how many show when
    /// `parent` is open.
    private static func link(_ items: [Bookmark], under parent: PDFObject) -> Int {
        var visible = 0
        for (index, item) in items.enumerated() {
            let object = item.object
            let open = item.isOpen
            object.set("Parent", parent)
            if index > 0 { object.set("Prev", items[index - 1].object) } else { object.remove("Prev") }
            if index + 1 < items.count { object.set("Next", items[index + 1].object) } else { object.remove("Next") }
            visible += 1
            if item.children.isEmpty {
                object.remove("First"); object.remove("Last"); object.remove("Count")
            } else {
                let shown = link(item.children, under: object)
                object.set("Count", .integer(open ? shown : -shown))
                if open { visible += shown }
            }
        }
        if let first = items.first, let last = items.last {
            parent.set("First", first.object)
            parent.set("Last", last.object)
        } else {
            parent.remove("First"); parent.remove("Last")
        }
        return visible
    }

    // MARK: Links, the open action, threads

    private func links() {
        for page in model.pages {
            for annotation in page.annotations where annotation.type == .dictionary {
                if goesToRemovedPage(annotation["Dest"]) { annotation.remove("Dest") }
                if let action = annotation["A"], action["S"]?.name == "GoTo", goesToRemovedPage(action["D"]) { annotation.remove("A") }
            }
        }
    }

    private func openAction() {
        guard let open = model.root["OpenAction"], let first = model.page(at: 0)?.object.reference else { return }
        let destination = open.type == .array ? open : open["S"]?.name == "GoTo" ? open["D"] : nil
        guard let array = explicit(destination), array[0]?.objectID.map(pages.contains) == true else { return }
        let view = Array((array.value.arrayValue ?? []).dropFirst())
        let moved = PDFValue.array([first] + (view.isEmpty ? [.name("Fit")] : view))
        if open.type == .array { model.root.set("OpenAction", moved) } else { open.set("D", moved) }
    }

    private func threads() {
        guard let threads = model.root["Threads"], threads.type == .array else { return }
        for index in stride(from: threads.count - 1, through: 0, by: -1) {
            guard let thread = threads[index], let first = thread["F"] else { continue }
            var beads: [PDFObject] = []
            var seen: Set<Int> = []
            var bead: PDFObject? = first
            while let current = bead, current.type == .dictionary, beads.count < 100_000 {
                if let id = current.objectID { guard seen.insert(id).inserted else { break } }
                beads.append(current)
                bead = current["N"]
            }
            let kept = beads.filter { !($0["P"]?.objectID.map(pages.contains) ?? false) }
            guard kept.count < beads.count else { continue }
            if kept.isEmpty { threads.removeItem(at: index); continue }
            for (i, bead) in kept.enumerated() {
                bead.set("N", kept[(i + 1) % kept.count])
                bead.set("V", kept[(i + kept.count - 1) % kept.count])
            }
            thread.set("F", kept[0])
            kept[0].set("T", thread)
        }
        if threads.count == 0 { model.root.remove("Threads") }
    }

    // MARK: The structure tree

    private func structureTree() {
        guard let tree = model.root["StructTreeRoot"], tree.type == .dictionary else { return }
        var visited: Set<Int> = []
        _ = pruneKids(of: tree, page: nil, visited: &visited, depth: 0)

        // The parent tree: the removed pages' and annotations' entries go, and references to removed elements.
        if let parentTree = tree["ParentTree"] {
            var removedKeys = Set(removed.compactMap { $0["StructParents"]?.int })
            for page in removed {
                for annotation in page["Annots"]?.items ?? [] where annotation.objectID.map(annotations.contains) == true {
                    if let key = annotation["StructParent"]?.int { removedKeys.insert(key) }
                }
            }
            var changed = false
            let entries = PDFNumberTree.entries(of: parentTree).filter { entry in
                if removedKeys.contains(entry.key) || entry.value.objectID.map(elements.contains) == true { changed = true; return false }
                if entry.value.type == .array {
                    for (i, item) in entry.value.items.enumerated() where item.objectID.map(elements.contains) == true {
                        entry.value.replaceItem(at: i, with: .null); changed = true
                    }
                }
                return true
            }
            if changed { tree.set("ParentTree", PDFNumberTree.make(in: model, entries: entries)) }
        }
        if let ids = tree["IDTree"] {
            let entries = PDFNameTree.entries(of: ids)
            let kept = entries.filter { !($0.value.objectID.map(elements.contains) ?? false) }
            if kept.count < entries.count { tree.set("IDTree", PDFNameTree.make(in: model, entries: kept)) }
        }
    }

    /// Prunes `element`'s /K of content on removed pages (`page` is the page its kids are on unless they say). Returns
    /// whether anything is left of it.
    private func pruneKids(of element: PDFObject, page: Int?, visited: inout Set<Int>, depth: Int) -> Bool {
        let own = element["Pg"]?.objectID ?? page
        guard let k = element["K"] else { return !(own.map(pages.contains) ?? false) }
        let single = k.type != .array
        let kids = single ? [k] : k.items
        var keep: [Bool] = []
        for kid in kids {
            switch kid.type {
            case .integer:
                keep.append(!(own.map(pages.contains) ?? false))
            case .dictionary:
                let type = kid["Type"]?.name
                if type == "MCR" || type == "OBJR" {
                    let on = kid["Pg"]?.objectID ?? own
                    var gone = on.map(pages.contains) ?? false
                    if type == "OBJR", let object = kid["Obj"] {
                        gone = gone || object.objectID.map(annotations.contains) == true || object["P"]?.objectID.map(pages.contains) == true
                    }
                    keep.append(!gone)
                } else {
                    if let id = kid.objectID { guard visited.insert(id).inserted else { keep.append(true); continue } }
                    let left = depth < 256 && pruneKids(of: kid, page: own, visited: &visited, depth: depth + 1)
                    if !left { markRemoved(kid) }
                    keep.append(left)
                }
            default:
                keep.append(true)
            }
        }
        if element["Pg"]?.objectID.map(pages.contains) == true { element.remove("Pg") }
        if keep.allSatisfy({ $0 }) { return true }
        if single {
            element.remove("K")
        } else {
            for index in stride(from: kids.count - 1, through: 0, by: -1) where !keep[index] { k.removeItem(at: index) }
            if k.count == 0 { element.remove("K") }
        }
        return keep.contains(true)
    }

    /// A removed element (what was under it went before it).
    private func markRemoved(_ element: PDFObject) {
        if let id = element.objectID { elements.insert(id) }
    }

    // MARK: Names, form order, labels

    private func namedDestinations() {
        if let dests = model.root["Dests"], dests.type == .dictionary {
            for key in dests.keys where goesToRemovedPage(dests[key]) { dests.remove(key) }
        }
        if let names = model.root["Names"], let tree = names["Dests"] {
            let entries = PDFNameTree.entries(of: tree)
            var kept: [(key: Data, value: PDFObject)] = []
            for entry in entries where !goesToRemovedPage(entry.value) { kept.append(entry) }
            if kept.count < entries.count {
                if kept.isEmpty { names.remove("Dests") } else { names.set("Dests", PDFNameTree.make(in: model, entries: kept)) }
            }
        }
    }

    /// The calculation order keeps only fields still in the form (fields of removed pages left it).
    private func formOrder() {
        guard let form = model.acroForm, let order = form["CO"], order.type == .array else { return }
        var fields: Set<Int> = []
        func collect(_ array: PDFObject?, depth: Int) {
            guard let array, depth < 32 else { return }
            for item in array.items {
                if let id = item.objectID { guard fields.insert(id).inserted else { continue } }
                collect(item["Kids"], depth: depth + 1)
            }
        }
        collect(form["Fields"], depth: 0)
        for index in stride(from: order.count - 1, through: 0, by: -1) where !(order[index]?.objectID.map(fields.contains) ?? false) {
            order.removeItem(at: index)
        }
    }

    /// Each remaining page keeps the label it had; a page from elsewhere continues the numbering before it.
    private func pageLabels(_ sources: [Int?]) {
        let ranges = model.pageLabels()
        guard !ranges.isEmpty else { return }
        var result: [PDFPageLabelRange] = []
        var previous: (style: PDFPageLabelRange.Style?, prefix: String, number: Int)?
        for (index, source) in sources.enumerated() {
            var label: (style: PDFPageLabelRange.Style?, prefix: String, number: Int)
            if let source, let range = ranges.last(where: { $0.startPage <= source }) {
                label = (range.style, range.prefix, range.firstNumber + source - range.startPage)
            } else if let previous {
                label = (previous.style, previous.prefix, previous.number + 1)
            } else {
                label = (.decimal, "", 1)
            }
            if let previous, previous.style == label.style, previous.prefix == label.prefix, previous.number + 1 == label.number {
                // The range before goes on.
            } else {
                result.append(PDFPageLabelRange(startPage: index, style: label.style, prefix: label.prefix, firstNumber: label.number))
            }
            previous = label
        }
        model.setPageLabels(result)
    }

    // MARK: The sweep

    /// Clears every remaining reference to a removed page, annotation or element in what the trailer reaches: a
    /// dictionary entry goes, an array item becomes null. Returns how many were cleared.
    private func sweep() -> Int {
        let gone = pages.union(annotations).union(elements)
        func isGone(_ value: PDFValue) -> Bool {
            if case .reference(let id, _) = value { return gone.contains(id) }
            return false
        }
        func contains(_ value: PDFValue) -> Bool {
            switch value {
            case .reference(let id, _): return gone.contains(id)
            case .array(let items): return items.contains(where: contains)
            case .dictionary(let dictionary): return dictionary.values.contains(where: contains)
            default: return false
            }
        }
        func cleaned(_ value: PDFValue) -> PDFValue {
            switch value {
            case .reference(let id, _) where gone.contains(id): return .null
            case .array(let items): return .array(items.map(cleaned))
            case .dictionary(let dictionary): return .dictionary(dictionary.filter { !isGone($0.value) }.mapValues(cleaned))
            default: return value
            }
        }
        var cleared = 0
        var seen: Set<Int> = []
        var queue: [PDFObject] = [model.trailer]
        while let object = queue.popLast() {
            guard let holder = object.type == .stream ? object.streamDictionary : object else { continue }
            var value = holder.value
            switch value {
            case .dictionary(let dictionary):
                for (key, item) in dictionary where contains(item) {
                    cleared += 1
                    if isGone(item) { holder.remove(key) } else { holder.set(key, cleaned(item)) }
                }
            case .array(let items):
                for (index, item) in items.enumerated() where contains(item) {
                    cleared += 1
                    holder.replaceItem(at: index, with: cleaned(item))
                }
            default:
                continue
            }
            value = cleaned(value)
            var references: [(Int, Int)] = []
            func collect(_ value: PDFValue) {
                switch value {
                case .reference(let id, let generation): references.append((id, generation))
                case .array(let items): items.forEach(collect)
                case .dictionary(let dictionary): dictionary.values.forEach(collect)
                default: break
                }
            }
            collect(value)
            for (id, generation) in references where seen.insert(id).inserted {
                let next = model.object(id: id, generation: generation)
                if next.type == .dictionary || next.type == .array || next.type == .stream { queue.append(next) }
            }
        }
        return cleared
    }
}
