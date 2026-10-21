import Foundation
import PDFKit
import SuperPDFCore

/// The bytes EditKit reads and edits for an open document: the document's snapshot. It keeps what EditKit wrote (the
/// marked spans that name our headers, watermarks and Bates numbers, forms, whole fonts) because DocumentKit writes the
/// changes made through PDFKit into the document's own bytes instead of letting PDFKit redraw them. The snapshot is kept
/// for the same document object until it changes, so panels asking again don't write the file each time.
@MainActor
enum EditSource {
    private struct Snapshot {
        weak var pdf: PDFDocument?
        let state: String
        let source: PDFSource
        let key: String
    }

    private static var snapshots: [UUID: Snapshot] = [:]

    /// The source to work on and a key that changes whenever its bytes do.
    static func current(for document: DocumentHandle) -> (source: PDFSource, key: String) {
        if let url = document.url, !document.state.isEdited {
            let source = PDFSource.file(url, password: document.password)
            return (source, source.fingerprint())
        }
        let pdf = document.pdf
        let state = Self.state(of: pdf)
        if let snapshot = snapshots[document.id], snapshot.pdf === pdf, snapshot.state == state { return (snapshot.source, snapshot.key) }
        let source = document.snapshot()
        let key = "snapshot:" + UUID().uuidString
        snapshots[document.id] = Snapshot(pdf: pdf, state: state, source: source, key: key)
        return (source, key)
    }

    static func source(for document: DocumentHandle) -> PDFSource { current(for: document).source }

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
