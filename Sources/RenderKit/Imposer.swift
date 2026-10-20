import CoreGraphics
import CoreText
import Foundation
import SuperPDFCore

/// Booklet, N-up and contact sheets (features #32, #33; ux §5.3 Booklet). Pages are drawn as vectors into cells of the
/// sheet, scaled to fit and centred. `.fitContent` paper sizes the sheet from the first page.
public enum Imposer {
    public static let margin: CGFloat = 18
    public static let gutter: CGFloat = 12

    public static func impose(_ source: PDFSource, layout: Imposition, paper: PaperSize, to destination: URL) throws {
        let document = try PDFPages.open(source)
        let count = document.numberOfPages
        guard count > 0 else { throw RenderError.noSuchPage(0) }
        let first = try PDFPages.page(document, at: 0)
        let pageSize = PDFPages.displayedSize(first)
        var sheets: [PDFWriter.Page] = []

        switch layout {
        case .booklet:
            // Saddle stitch: sheet k, front = (n − 2k, 2k + 1), back = (2k + 2, n − 2k − 1), n padded to a multiple of 4.
            let padded = (count + 3) / 4 * 4
            let sheet = paper.size.map { CGSize(width: max($0.width, $0.height), height: min($0.width, $0.height)) } ?? CGSize(width: pageSize.width * 2, height: pageSize.height)
            for k in 0..<(padded / 4) {
                for side in [(padded - 2 * k, 2 * k + 1), (2 * k + 2, padded - 2 * k - 1)] {
                    sheets.append(sheetPage(document, sheet: sheet, columns: 2, rows: 1, pageNumbers: [side.0, side.1], labels: false))
                }
            }
        case .nUp(let n):
            let columns = Int(Double(max(n, 1)).squareRoot().rounded(.up)), rows = (max(n, 1) + columns - 1) / columns
            let sheet: CGSize
            if let size = paper.size {
                sheet = columns > rows ? CGSize(width: max(size.width, size.height), height: min(size.width, size.height)) : CGSize(width: min(size.width, size.height), height: max(size.width, size.height))
            } else {
                sheet = CGSize(width: pageSize.width * CGFloat(columns), height: pageSize.height * CGFloat(rows))
            }
            let perSheet = columns * rows
            for start in stride(from: 1, through: count, by: perSheet) {
                sheets.append(sheetPage(document, sheet: sheet, columns: columns, rows: rows, pageNumbers: Array(start..<min(start + perSheet, count + 1)), labels: false))
            }
        case .contactSheet(let columns):
            let columns = max(columns, 1)
            let sheet = paper.size ?? PaperSize.letter.size!
            let cellWidth = (sheet.width - 2 * margin - CGFloat(columns - 1) * gutter) / CGFloat(columns)
            let cellHeight = cellWidth * pageSize.height / max(pageSize.width, 1) + labelHeight
            let rows = max(Int((sheet.height - 2 * margin + gutter) / (cellHeight + gutter)), 1)
            let perSheet = columns * rows
            for start in stride(from: 1, through: count, by: perSheet) {
                sheets.append(sheetPage(document, sheet: sheet, columns: columns, rows: rows, pageNumbers: Array(start..<min(start + perSheet, count + 1)), labels: true, cellHeight: cellHeight))
            }
        }
        try PDFWriter.write(to: destination, info: PDFPages.metadata(document), pages: sheets)
    }

    static let labelHeight: CGFloat = 14

    /// One output sheet with `pageNumbers` (1-based; numbers past the document are blank cells) laid out in a grid.
    static func sheetPage(_ document: CGPDFDocument, sheet: CGSize, columns: Int, rows: Int, pageNumbers: [Int], labels: Bool, cellHeight: CGFloat? = nil) -> PDFWriter.Page {
        PDFWriter.Page(size: sheet) { context in
            let cellWidth = (sheet.width - 2 * margin - CGFloat(columns - 1) * gutter) / CGFloat(columns)
            let height = cellHeight ?? (sheet.height - 2 * margin - CGFloat(rows - 1) * gutter) / CGFloat(rows)
            for (slot, number) in pageNumbers.enumerated() {
                guard number >= 1, number <= document.numberOfPages, let page = document.page(at: number) else { continue }
                let column = slot % columns, row = slot / columns
                let x = margin + CGFloat(column) * (cellWidth + gutter)
                let y = sheet.height - margin - CGFloat(row + 1) * height - CGFloat(row) * gutter
                let cell = CGRect(x: x, y: y + (labels ? labelHeight : 0), width: cellWidth, height: height - (labels ? labelHeight : 0))
                PDFPages.draw(page, in: context, fitting: cell)
                if labels {
                    let shown = PDFPages.drawnRect(page, fitting: cell)
                    context.setStrokeColor(CGColor(gray: 0.75, alpha: 1))
                    context.setLineWidth(0.5)
                    context.stroke(shown.insetBy(dx: -0.25, dy: -0.25))
                    let label = CTLineCreateWithAttributedString(NSAttributedString(string: "\(number)", attributes: [
                        .font: CTFontCreateWithName("Helvetica" as CFString, 9, nil), .foregroundColor: CGColor(gray: 0.35, alpha: 1)]))
                    let width = CTLineGetTypographicBounds(label, nil, nil, nil)
                    context.textPosition = CGPoint(x: cell.midX - width / 2, y: y + 3)
                    CTLineDraw(label, context)
                }
            }
        }
    }
}
