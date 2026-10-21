import Foundation
import PDFKit
import PDFModelKit
import SuperPDFCore

/// The bytes EditKit reads and edits for an open document.
///
/// `DocumentHandle.snapshot()` of an edited document is PDFKit's serialisation, and PDFKit writes by redrawing every
/// page: the marked spans that name our headers, watermarks and Bates numbers are gone, forms are inlined and fonts come
/// back as subsets of the glyphs already used. So every EditKit save carries a revision name in the catalog and its
/// bytes are kept here; while the window shows exactly those bytes (the loaded document carries the revision and nothing
/// was changed on it through PDFKit since) they are what EditKit works on. Anything else reads the snapshot, kept for the
/// same document object until it changes, so panels asking again don't redraw the file each time.
@MainActor
enum EditSource {
    /// The catalog key holding the revision of an EditKit save.
    nonisolated static let revisionKey = "SPRevision"

    private struct Saved {
        let bytes: Data
        let password: String?
        /// What PDFKit shows for these bytes, to tell a later change made on the window's document.
        let state: String
    }

    private struct Snapshot {
        weak var pdf: PDFDocument?
        let state: String
        let source: PDFSource
        let key: String
    }

    /// The newest saves, oldest first; the undo stack holds the same bytes, so keeping them costs no copy.
    private static var saved: [(revision: String, value: Saved)] = []
    private static let keep = 24
    private static var snapshots: [UUID: Snapshot] = [:]

    /// The source to work on and a key that changes whenever its bytes do.
    static func current(for document: DocumentHandle) -> (source: PDFSource, key: String) {
        if let url = document.url, !document.state.isEdited {
            let source = PDFSource.file(url, password: document.password)
            return (source, source.fingerprint())
        }
        let pdf = document.pdf
        let state = Self.state(of: pdf)
        if let revision = revision(of: pdf), let entry = saved.last(where: { $0.revision == revision })?.value, entry.state == state {
            return (.data(entry.bytes, password: entry.password), "revision:" + revision)
        }
        if let snapshot = snapshots[document.id], snapshot.pdf === pdf, snapshot.state == state { return (snapshot.source, snapshot.key) }
        let source = document.snapshot()
        let key = "snapshot:" + UUID().uuidString
        snapshots[document.id] = Snapshot(pdf: pdf, state: state, source: source, key: key)
        return (source, key)
    }

    static func source(for document: DocumentHandle) -> PDFSource { current(for: document).source }

    /// Names a new revision in `model`'s catalog; call just before saving and `remember` the bytes under it.
    nonisolated static func stamp(_ model: PDFModel) -> String {
        let revision = "R" + UUID().uuidString.replacingOccurrences(of: "-", with: "")
        model.root.set(revisionKey, .name(revision))
        return revision
    }

    /// Keeps the bytes of a save for when the document shows them.
    static func remember(_ bytes: Data, revision: String, password: String?) {
        guard let pdf = PDFDocument(data: bytes) else { return }
        if pdf.isLocked, let password { pdf.unlock(withPassword: password) }
        saved.removeAll { $0.revision == revision }
        saved.append((revision, Saved(bytes: bytes, password: password, state: state(of: pdf))))
        if saved.count > keep { saved.removeFirst(saved.count - keep) }
    }

    /// The revision an EditKit save left in the catalog the document was loaded from.
    private static func revision(of pdf: PDFDocument) -> String? {
        guard let catalog = pdf.documentRef?.catalog else { return nil }
        var name: UnsafePointer<CChar>?
        guard CGPDFDictionaryGetName(catalog, revisionKey, &name), let name else { return nil }
        return String(cString: name)
    }

    /// What PDFKit can change on an open document without new bytes: the pages and their order, rotation and boxes,
    /// the annotations, the outline and the document's attributes.
    private static func state(of pdf: PDFDocument) -> String {
        var parts: [String] = ["\(pdf.pageCount)"]
        func rect(_ r: CGRect) -> String { String(format: "%.2f,%.2f,%.2f,%.2f", r.minX, r.minY, r.width, r.height) }
        for index in 0..<pdf.pageCount {
            guard let page = pdf.page(at: index) else { continue }
            parts.append("p\(page.pageRef?.pageNumber ?? -1) \(page.rotation) \(rect(page.bounds(for: .mediaBox))) \(rect(page.bounds(for: .cropBox)))")
            for annotation in page.annotations {
                let colour = annotation.color.usingColorSpace(.deviceRGB).map { String(format: "%.3f %.3f %.3f %.3f", $0.redComponent, $0.greenComponent, $0.blueComponent, $0.alphaComponent) } ?? ""
                parts.append(["a", annotation.type ?? "", rect(annotation.bounds), annotation.contents ?? "", colour, annotation.widgetStringValue ?? "",
                              "\(annotation.buttonWidgetState.rawValue)", annotation.fieldName ?? "", "\(annotation.border?.lineWidth ?? 0)",
                              annotation.url?.absoluteString ?? "", annotation.userName ?? "",
                              "\(annotation.shouldDisplay)\(annotation.shouldPrint)"].joined(separator: "|"))
            }
        }
        var outline: [String] = []
        func walk(_ item: PDFOutline, depth: Int) {
            for i in 0..<item.numberOfChildren {
                guard let child = item.child(at: i) else { continue }
                outline.append("\(depth) \(child.label ?? "") \(child.destination.flatMap { $0.page.map(pdf.index(for:)) } ?? -1)")
                walk(child, depth: depth + 1)
            }
        }
        if let root = pdf.outlineRoot { walk(root, depth: 0) }
        parts.append(outline.joined(separator: "/"))
        let attributes = pdf.documentAttributes ?? [:]
        for key in [PDFDocumentAttribute.titleAttribute, .authorAttribute, .subjectAttribute, .keywordsAttribute, .creatorAttribute] {
            parts.append("\(attributes[key] ?? "")")
        }
        return parts.joined(separator: "\n")
    }
}
