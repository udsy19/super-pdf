import AppKit
import PDFKit
import SuperPDFCore

// The comments of a document as the Highlights and Notes sidebar and the Comments list show them (features #8, #77):
// every markup annotation once, with its replies and its latest review status folded in (Acrobat's model: a reply is a
// Text annotation with /IRT and /RT /R; a status is one with /State and /StateModel /Review).

@MainActor
enum CommentList {
    static func kind(of annotation: PDFAnnotation) -> MarkupKind? {
        if Measure.kind(of: annotation) != nil { return .measurement }
        switch annotation.type ?? "" {
        case "Highlight": return .highlight
        case "Underline": return .underline
        case "StrikeOut": return .strikeOut
        case "Text": return .note
        case "FreeText":
            let intent = (annotation.value(forAnnotationKey: .intent) as? String) ?? ""
            return intent.hasSuffix("FreeTextCallout") ? .callout : .textBox
        case "Ink": return .ink
        case "Square", "Circle", "Line", "Polygon", "PolyLine": return .shape
        case "Stamp": return .stamp
        case "FileAttachment": return .attachment
        case "Sound": return .sound
        case "Caret": return .caret
        default: return nil
        }
    }

    /// Preview's sidebar names for the kinds (PVHighlightAnnotationType…).
    static func title(of kind: MarkupKind) -> String {
        switch kind {
        case .highlight: "Highlight"
        case .underline: "Underline"
        case .strikeOut: "Strikethrough"
        case .note: "Note"
        case .textBox: "Text"
        case .callout: "Callout"
        case .ink: "Drawing"
        case .shape: "Shape"
        case .stamp: "Stamp"
        case .attachment: "Attachment"
        case .sound: "Voice note"
        case .link: "Link"
        case .measurement: "Measurement"
        case .caret: "Insert text"
        }
    }

    static func status(fromState state: String?, model: String?) -> ReviewStatus? {
        guard let state, (model ?? "Review").caseInsensitiveCompare("Review") == .orderedSame else { return nil }
        return switch state.lowercased() {
        case "accepted": .accepted
        case "rejected": .rejected
        case "completed": .completed
        case "resolved": .resolved
        case "none", "cancelled": ReviewStatus.none
        default: nil
        }
    }

    static func state(for status: ReviewStatus) -> String {
        switch status {
        case .none: "None"
        case .accepted: "Accepted"
        case .rejected: "Rejected"
        case .completed: "Completed"
        case .resolved: "Resolved"
        }
    }

    static func isStatus(_ annotation: PDFAnnotation) -> Bool { annotation.value(forAnnotationKey: .state) != nil }

    /// Every comment of the document, page by page in the order of the page's annotations.
    static func items(in document: DocumentHandle, ledger: AnnotationLedger) -> [CommentItem] {
        var tops: [CommentItem] = []
        var replies: [String: [(Date, CommentReply)]] = [:]
        var statuses: [String: (Date, ReviewStatus)] = [:]
        for index in 0..<document.pageCount {
            guard let page = document.pdf.page(at: index) else { continue }
            for annotation in page.annotations where AnnotationLedger.isMarkup(annotation) {
                let id = AnnotationLedger.id(of: annotation)
                let date = annotation.modificationDate ?? .distantPast
                if let parent = ledger[id].parent {
                    if isStatus(annotation) {
                        let status = status(fromState: annotation.value(forAnnotationKey: .state) as? String,
                                            model: annotation.value(forAnnotationKey: .stateModel) as? String)
                        if let status, statuses[parent].map({ $0.0 <= date }) ?? true { statuses[parent] = (date, status) }
                    } else if ledger[id].replyType != "Group" {
                        replies[parent, default: []].append((date, CommentReply(id: id, author: annotation.userName ?? "",
                                                                                 modified: annotation.modificationDate,
                                                                                 text: annotation.contents ?? "")))
                    }
                    continue
                }
                guard let kind = kind(of: annotation) else { continue }
                tops.append(CommentItem(id: id, page: index, kind: kind, author: annotation.userName ?? "", modified: annotation.modificationDate,
                                        text: annotation.contents ?? "", quotedText: quotedText(of: annotation, on: page),
                                        bounds: annotation.bounds))
            }
        }
        return tops.map { item in
            var item = item
            item.replies = (replies[item.id] ?? []).sorted { $0.0 < $1.0 }.map(\.1)
            item.status = statuses[item.id]?.1 ?? .none
            return item
        }
    }

    /// The words under text markup (and under a proofreading strike).
    static func quotedText(of annotation: PDFAnnotation, on page: PDFPage) -> String? {
        guard AnnotationEditing.textMarkupTypes.contains(annotation.type ?? "") else { return nil }
        let points = (annotation.quadrilateralPoints ?? []).map { $0.pointValue }
        let origin = annotation.bounds.origin
        var parts: [String] = []
        for start in stride(from: 0, to: points.count - 3, by: 4) {
            let quad = points[start..<start + 4].map { CGPoint(x: $0.x + origin.x, y: $0.y + origin.y) }
            let rect = Geometry.bounds(of: quad)
            // A hair inside the line box, so neighbouring lines' characters stay out.
            if let text = page.selection(for: rect.insetBy(dx: 0, dy: rect.height * 0.2))?.string?.trimmingCharacters(in: .whitespacesAndNewlines),
               !text.isEmpty {
                parts.append(text)
            }
        }
        return parts.isEmpty ? nil : parts.joined(separator: " ")
    }

    /// The annotation a comment id names.
    static func annotation(_ id: String, in document: DocumentHandle) -> (PDFAnnotation, PDFPage)? {
        for index in 0..<document.pageCount {
            guard let page = document.pdf.page(at: index) else { continue }
            if let match = page.annotations.first(where: { ($0.value(forAnnotationKey: .superPDFID) as? String) == id }) { return (match, page) }
        }
        return nil
    }
}
