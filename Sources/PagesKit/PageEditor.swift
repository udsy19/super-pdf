import Foundation
import PDFKit
import SuperPDFCore

/// `Services.pages` (features §1.2): every edit of an open document's page list, as one undo step. Pages are PDFKit
/// pages on the main actor; an edit records the page list before and after and undo puts the other one back, so the
/// thumbnails, the organiser, the panels and batch steps share one behaviour.
@MainActor
final class PageEditor: PageEditing {
    func perform(_ operation: PageOperation, in document: DocumentHandle) async throws -> UndoGroup {
        guard document.state.permissions.pageChanges else { throw PageEditError.notAllowed }
        let pdf = document.pdf
        let before = Self.pages(of: pdf)
        let count = before.count
        func check(_ indices: [Int]) throws {
            guard !indices.isEmpty, indices.allSatisfy({ (0..<count).contains($0) }) else { throw PageEditError.pagesOutOfRange }
        }

        let after: [PDFPage]
        let name: String
        switch operation {
        case .rotate(let indices, let quarterTurns):
            try check(indices)
            let pages = indices.compactMap { pdf.page(at: $0) }
            let turn = { (sign: Int) in
                for page in pages { page.rotation = ((page.rotation + sign * quarterTurns * 90) % 360 + 360) % 360 }
            }
            turn(1)
            return UndoGroup(PagesStrings.Undo.rotate, undo: { turn(-1) }, redo: { turn(1) })

        case .delete(let indices):
            try check(indices)
            let doomed = Set(indices)
            guard doomed.count < count else { throw PageEditError.lastPage }
            after = before.enumerated().filter { !doomed.contains($0.offset) }.map(\.element)
            name = PagesStrings.Undo.delete

        case .move(let indices, let to):
            try check(indices)
            let moving = Set(indices)
            let moved = before.enumerated().filter { moving.contains($0.offset) }.map(\.element)
            var rest = before.enumerated().filter { !moving.contains($0.offset) }.map(\.element)
            rest.insert(contentsOf: moved, at: min(max(to, 0), rest.count))
            after = rest
            name = PagesStrings.Undo.move

        case .duplicate(let indices):
            try check(indices)
            let copies = indices.sorted().compactMap { before[$0].copy() as? PDFPage }
            var list = before
            list.insert(contentsOf: copies, at: (indices.max() ?? count - 1) + 1)
            after = list
            name = PagesStrings.Undo.duplicate

        case .insertBlank(let index):
            guard (-1..<count).contains(index) else { throw PageEditError.pagesOutOfRange }
            let neighbour = before[max(index, 0)]
            let blank = PDFPage()
            blank.setBounds(neighbour.bounds(for: .mediaBox), for: .mediaBox)
            blank.rotation = neighbour.rotation
            var list = before
            list.insert(blank, at: index + 1)
            after = list
            name = PagesStrings.Undo.insertBlank

        case .insertFile(let source, let indices, let at):
            guard (0...count).contains(at) else { throw PageEditError.pagesOutOfRange }
            var list = before
            list.insert(contentsOf: try Self.copies(of: source, pages: indices), at: at)
            after = list
            name = PagesStrings.Undo.insert

        case .replace(let range, let source, let indices):
            try check([range.lowerBound, range.upperBound])
            let incoming = try Self.copies(of: source, pages: indices)
            // Comments and links stay where the old and new page have the same size (features #25).
            for (old, new) in zip(before[range], incoming) where old.bounds(for: .mediaBox).size == new.bounds(for: .mediaBox).size {
                for annotation in old.annotations where annotation.type != "Widget" {
                    if let copy = annotation.copy() as? PDFAnnotation { new.addAnnotation(copy) }
                }
            }
            var list = before
            list.replaceSubrange(range, with: incoming)
            after = list
            name = PagesStrings.Undo.replace

        case .reverse:
            after = before.reversed()
            name = PagesStrings.Undo.reverse
        }

        Self.setPages(after, in: pdf)
        return UndoGroup(name, undo: { Self.setPages(before, in: pdf) }, redo: { Self.setPages(after, in: pdf) })
    }

    func extract(_ pages: [Int], from document: DocumentHandle) throws -> Data {
        guard !pages.isEmpty, pages.allSatisfy({ (0..<document.pageCount).contains($0) }) else { throw PageEditError.pagesOutOfRange }
        return try PageEngine.pages(pages, of: document.snapshot())
    }

    func copy(_ pages: [Int], from source: DocumentHandle, to target: DocumentHandle, at index: Int) throws -> UndoGroup {
        guard target.state.permissions.pageChanges else { throw PageEditError.notAllowed }
        guard !pages.isEmpty, pages.allSatisfy({ (0..<source.pageCount).contains($0) }), (0...target.pageCount).contains(index) else {
            throw PageEditError.pagesOutOfRange
        }
        let pdf = target.pdf
        let before = Self.pages(of: pdf)
        var after = before
        after.insert(contentsOf: pages.compactMap { source.pdf.page(at: $0)?.copy() as? PDFPage }, at: index)
        Self.setPages(after, in: pdf)
        return UndoGroup(PagesStrings.Undo.insert, undo: { Self.setPages(before, in: pdf) }, redo: { Self.setPages(after, in: pdf) })
    }

    // MARK: Page lists

    static func pages(of pdf: PDFDocument) -> [PDFPage] { (0..<pdf.pageCount).compactMap { pdf.page(at: $0) } }

    /// Makes the document's pages exactly `target` (by identity): removes the pages not in it, then puts each page in its
    /// place, leaving the pages already there alone.
    static func setPages(_ target: [PDFPage], in pdf: PDFDocument) {
        let keep = Set(target.map(ObjectIdentifier.init))
        for index in stride(from: pdf.pageCount - 1, through: 0, by: -1) {
            if let page = pdf.page(at: index), !keep.contains(ObjectIdentifier(page)) { pdf.removePage(at: index) }
        }
        for (index, page) in target.enumerated() {
            if index < pdf.pageCount, pdf.page(at: index) === page { continue }
            // PDFKit's exchangePage(at:withPageAt:) can throw on pages it has just moved, so a page already here is
            // taken out and put back in its place.
            if page.document === pdf, case let current = pdf.index(for: page), current > index, current < pdf.pageCount {
                pdf.removePage(at: current)
            }
            pdf.insert(page, at: index)
        }
    }

    /// Copies of a file's pages (all when `pages` is empty), ready to insert.
    static func copies(of source: PDFSource, pages indices: [Int]) throws -> [PDFPage] {
        guard let other = PDFDocument(data: try source.bytes()) else { throw PageEditError.pagesOutOfRange }
        if other.isLocked, let password = source.password { other.unlock(withPassword: password) }
        let wanted = indices.isEmpty ? Array(0..<other.pageCount) : indices
        guard wanted.allSatisfy({ (0..<other.pageCount).contains($0) }) else { throw PageEditError.pagesOutOfRange }
        return wanted.compactMap { other.page(at: $0)?.copy() as? PDFPage }
    }
}
