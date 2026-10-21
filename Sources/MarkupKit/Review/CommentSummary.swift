import AppKit
import CoreText
import PDFKit
import SuperPDFCore

// "Summarise comments to PDF…" (features #117, Acrobat's three layouts): the pages that have comments, each with its
// comments beside it joined by connector lines; or the comments alone, numbered; or each page with numbered markers
// followed by its numbered comments. Drawn with Quartz into a new PDF.

@MainActor
enum CommentSummary {
    static let letter = CGSize(width: 612, height: 792)
    static let margin: CGFloat = 36

    static func render(_ document: DocumentHandle, items: [CommentItem], options: CommentSummaryOptions) -> Data {
        let data = NSMutableData()
        var box = CGRect(origin: .zero, size: letter)
        guard let consumer = CGDataConsumer(data: data as CFMutableData),
              let context = CGContext(consumer: consumer, mediaBox: &box, [kCGPDFContextTitle as String: "Comments on \(document.displayName)"] as CFDictionary)
        else { return Data() }
        let byPage = Dictionary(grouping: items, by: \.page)
        let pages = byPage.keys.sorted()
        let fontSize = CGFloat(max(6, min(options.fontSize, 24)))
        switch options.layout {
        case .connectorLines:
            for index in pages {
                guard let page = document.pdf.page(at: index) else { continue }
                connectorPage(page, number: index + 1, items: byPage[index] ?? [], fontSize: fontSize, context: context)
            }
        case .commentsOnly:
            var writer = ListWriter(context: context, fontSize: fontSize)
            writer.title("Summary of comments on " + Strings.quoted(document.url?.lastPathComponent ?? document.displayName))
            var number = 1
            for index in pages {
                writer.heading("Page \(index + 1)")
                for item in byPage[index] ?? [] { writer.entry(number, item); number += 1 }
            }
            if pages.isEmpty { writer.heading(Strings.Empty.highlightsAndNotes) }
            writer.finish()
        case .sequenceNumbers:
            for index in pages {
                guard let page = document.pdf.page(at: index) else { continue }
                let pageItems = byPage[index] ?? []
                numberedPage(page, items: pageItems, context: context)
                var writer = ListWriter(context: context, fontSize: fontSize)
                writer.heading("Page \(index + 1)")
                for (offset, item) in pageItems.enumerated() { writer.entry(offset + 1, item) }
                writer.finish()
            }
        }
        if pages.isEmpty, options.layout != .commentsOnly {
            var writer = ListWriter(context: context, fontSize: fontSize)
            writer.heading(Strings.Empty.highlightsAndNotes)
            writer.finish()
        }
        context.closePDF()
        return data as Data
    }

    // MARK: Layouts

    /// Landscape: the page on the left, the comments on the right, a line from each mark to its comment; comments that
    /// don't fit continue on another sheet showing the page again.
    private static func connectorPage(_ page: PDFPage, number: Int, items: [CommentItem], fontSize: CGFloat, context: CGContext) {
        let sheet = CGRect(x: 0, y: 0, width: letter.height, height: letter.width)
        let pageArea = CGRect(x: margin, y: margin, width: sheet.width / 2 - margin * 1.5, height: sheet.height - margin * 2)
        let column = CGRect(x: sheet.width / 2 + margin / 2, y: margin, width: sheet.width / 2 - margin * 1.5, height: sheet.height - margin * 2)
        var remaining = items[...]
        repeat {
            var mediaBox = sheet
            context.beginPage(mediaBox: &mediaBox)
            let transform = drawPage(page, in: pageArea, context: context)
            var top = column.maxY
            drawText(header("Page \(number)", size: fontSize + 2), in: CGRect(x: column.minX, y: top - 40, width: column.width, height: 40), context: context)
            top -= fontSize * 2.2
            var placed = 0
            for item in remaining {
                let text = entryText(nil, item, size: fontSize)
                let height = min(textHeight(text, width: column.width - 12) + 10, column.height * 0.8)
                guard top - height >= column.minY || placed == 0 else { break }
                let card = CGRect(x: column.minX, y: top - height, width: column.width, height: height)
                context.setFillColor(CGColor(gray: 0.97, alpha: 1))
                context.setStrokeColor(CGColor(gray: 0.75, alpha: 1))
                context.setLineWidth(0.5)
                context.addPath(CGPath(roundedRect: card, cornerWidth: 4, cornerHeight: 4, transform: nil))
                context.drawPath(using: .fillStroke)
                drawText(text, in: card.insetBy(dx: 6, dy: 5), context: context)
                let mark = CGPoint(x: item.bounds.midX, y: item.bounds.midY).applying(transform)
                context.setStrokeColor(CGColor(srgbRed: 0.12, green: 0.37, blue: 0.75, alpha: 0.8))
                context.setLineWidth(0.75)
                context.move(to: mark)
                context.addLine(to: CGPoint(x: card.minX, y: card.maxY - fontSize))
                context.strokePath()
                context.setFillColor(CGColor(srgbRed: 0.12, green: 0.37, blue: 0.75, alpha: 1))
                context.fillEllipse(in: CGRect(x: mark.x - 2, y: mark.y - 2, width: 4, height: 4))
                top -= height + 8
                placed += 1
            }
            remaining = remaining.dropFirst(placed)
            context.endPage()
        } while !remaining.isEmpty
    }

    /// The page at its own size with a numbered disc at each comment.
    private static func numberedPage(_ page: PDFPage, items: [CommentItem], context: CGContext) {
        var mediaBox = CGRect(origin: .zero, size: page.bounds(for: .cropBox).size)
        context.beginPage(mediaBox: &mediaBox)
        let transform = drawPage(page, in: mediaBox, context: context)
        for (offset, item) in items.enumerated() {
            let center = CGPoint(x: item.bounds.minX, y: item.bounds.maxY).applying(transform)
            let disc = CGRect(x: center.x - 8, y: center.y - 8, width: 16, height: 16)
            context.setFillColor(CGColor(srgbRed: 0.12, green: 0.37, blue: 0.75, alpha: 1))
            context.fillEllipse(in: disc)
            let label = NSAttributedString(string: "\(offset + 1)", attributes: [.font: NSFont(name: "Helvetica-Bold", size: 9)!, .foregroundColor: NSColor.white])
            let line = CTLineCreateWithAttributedString(label)
            let width = CTLineGetTypographicBounds(line, nil, nil, nil)
            context.textPosition = CGPoint(x: disc.midX - width / 2, y: disc.midY - 3)
            CTLineDraw(line, context)
        }
        context.endPage()
    }

    /// Draws the page (with its markup) fitted into `area`; returns page space → sheet space.
    @discardableResult
    private static func drawPage(_ page: PDFPage, in area: CGRect, context: CGContext) -> CGAffineTransform {
        let crop = page.bounds(for: .cropBox)
        let rotated = page.rotation % 180 == 0 ? crop.size : CGSize(width: crop.height, height: crop.width)
        let scale = min(area.width / rotated.width, area.height / rotated.height)
        let origin = CGPoint(x: area.midX - rotated.width * scale / 2, y: area.midY - rotated.height * scale / 2)
        context.saveGState()
        context.translateBy(x: origin.x, y: origin.y)
        context.scaleBy(x: scale, y: scale)
        context.setFillColor(.white)
        context.fill(CGRect(origin: .zero, size: rotated))
        page.draw(with: .cropBox, to: context)
        context.restoreGState()
        context.setStrokeColor(CGColor(gray: 0.7, alpha: 1))
        context.setLineWidth(0.5)
        context.stroke(CGRect(origin: origin, size: CGSize(width: rotated.width * scale, height: rotated.height * scale)))
        let display = page.transform(for: .cropBox)
        return display.concatenating(CGAffineTransform(scaleX: scale, y: scale)).concatenating(CGAffineTransform(translationX: origin.x, y: origin.y))
    }

    // MARK: Text

    static func header(_ text: String, size: CGFloat) -> NSAttributedString {
        NSAttributedString(string: text, attributes: [.font: NSFont(name: "Helvetica-Bold", size: size) ?? .boldSystemFont(ofSize: size)])
    }

    /// "1. Highlight · Alice · 20 Oct 2026 at 14:03 · Accepted", the quoted text, the comment, then each reply.
    static func entryText(_ number: Int?, _ item: CommentItem, size: CGFloat) -> NSAttributedString {
        let regular = NSFont(name: "Helvetica", size: size) ?? .systemFont(ofSize: size)
        let bold = NSFont(name: "Helvetica-Bold", size: size) ?? .boldSystemFont(ofSize: size)
        let grey = NSColor(white: 0.35, alpha: 1)
        let text = NSMutableAttributedString()
        var head = [CommentList.title(of: item.kind)]
        if !item.author.isEmpty { head.append(item.author) }
        if let date = item.modified { head.append(date.formatted(date: .abbreviated, time: .shortened)) }
        if item.status != .none { head.append(CommentList.state(for: item.status)) }
        text.append(NSAttributedString(string: (number.map { "\($0). " } ?? "") + head.joined(separator: " · "), attributes: [.font: bold]))
        if let quoted = item.quotedText, !quoted.isEmpty {
            text.append(NSAttributedString(string: "\n“\(quoted)”", attributes: [.font: regular, .foregroundColor: grey]))
        }
        if !item.text.isEmpty { text.append(NSAttributedString(string: "\n" + item.text, attributes: [.font: regular])) }
        for reply in item.replies {
            text.append(NSAttributedString(string: "\n    ↳ \(reply.author): \(reply.text)", attributes: [.font: regular, .foregroundColor: grey]))
        }
        return text
    }

    static func textHeight(_ text: NSAttributedString, width: CGFloat) -> CGFloat {
        let setter = CTFramesetterCreateWithAttributedString(text)
        return ceil(CTFramesetterSuggestFrameSizeWithConstraints(setter, CFRange(), nil, CGSize(width: width, height: .greatestFiniteMagnitude), nil).height)
    }

    static func drawText(_ text: NSAttributedString, in rect: CGRect, context: CGContext) {
        let setter = CTFramesetterCreateWithAttributedString(text)
        let frame = CTFramesetterCreateFrame(setter, CFRange(), CGPath(rect: rect, transform: nil), nil)
        context.textMatrix = .identity
        CTFrameDraw(frame, context)
    }

    /// Letter pages of headings and numbered entries, breaking pages as they fill.
    @MainActor struct ListWriter {
        let context: CGContext
        let fontSize: CGFloat
        private var top: CGFloat = 0
        private var open = false
        private let width = letter.width - margin * 2

        init(context: CGContext, fontSize: CGFloat) { self.context = context; self.fontSize = fontSize }

        mutating func title(_ text: String) { place(header(text, size: fontSize + 6), gap: fontSize) }
        mutating func heading(_ text: String) { place(header(text, size: fontSize + 2), gap: fontSize * 0.6) }
        mutating func entry(_ number: Int, _ item: CommentItem) { place(entryText(number, item, size: fontSize), gap: fontSize * 0.8) }

        private mutating func place(_ text: NSAttributedString, gap: CGFloat) {
            let height = min(CommentSummary.textHeight(text, width: width), letter.height - margin * 2)
            if !open || top - height < margin { newPage() }
            CommentSummary.drawText(text, in: CGRect(x: margin, y: top - height, width: width, height: height), context: context)
            top -= height + gap
        }

        private mutating func newPage() {
            if open { context.endPage() }
            var box = CGRect(origin: .zero, size: letter)
            context.beginPage(mediaBox: &box)
            open = true
            top = letter.height - margin
        }

        mutating func finish() {
            if open { context.endPage() }
            open = false
        }
    }
}
