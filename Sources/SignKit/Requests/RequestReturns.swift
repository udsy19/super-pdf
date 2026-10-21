import AppKit
import PDFKit
import SuperPDFCore

// Reading a returned copy (features #84 step 3). Whatever app the person signed in (Preview's signature, Acrobat's
// Fill & Sign or a digital signature, typed text, a ticked box, a printed-to-PDF copy), what counts is what their fields
// show now: a field is filled when its box holds ink that the package didn't have. A filled field that can't come
// across as an appended update is copied over as a picture of that box (vector, as PDFKit draws the returned page).

@MainActor
enum RequestReturns {
    /// The fields of `fields` whose boxes in `returned` hold new ink compared with `package`.
    static func filledFields(returned: Data, package: Data, fields: [RequestField]) -> Set<UUID> {
        guard let returnedDocument = PDFDocument(data: returned), let packageDocument = PDFDocument(data: package) else { return [] }
        var filled: Set<UUID> = []
        for field in fields {
            let index = field.page + RequestPackage.coverPages
            guard let mine = returnedDocument.page(at: index), let sent = packageDocument.page(at: index),
                  let after = gray(mine, rect: field.rect), let before = gray(sent, rect: field.rect), after.count == before.count else { continue }
            var ink = 0
            for i in 0..<after.count where after[i] < 120 && before[i] > 170 { ink += 1 }
            if ink >= max(8, after.count / 300) { filled.insert(field.id) }
        }
        return filled
    }

    /// The box `rect` (page space) of page `index` of `returned` as a one-page vector PDF, the way PDFKit shows it, with
    /// the package's own unsigned signature boxes taken away and its field tints cleared, so only what the person added
    /// (and the page under it) comes across.
    static func region(of returned: Data, page index: Int, rect: CGRect, fieldPrefix: String, signedFields: Set<String>) -> Data? {
        guard let document = PDFDocument(data: returned), let page = document.page(at: index) else { return nil }
        for annotation in page.annotations where annotation.fieldName?.hasPrefix(fieldPrefix) == true {
            if annotation.widgetFieldType == .signature && !signedFields.contains(annotation.fieldName ?? "") {
                page.removeAnnotation(annotation)
            } else if annotation.widgetFieldType != .signature {
                annotation.removeValue(forAnnotationKey: .appearanceDictionary)
                annotation.backgroundColor = .clear
                let border = PDFBorder()
                border.lineWidth = 0
                annotation.border = border
            }
        }
        let drawn = rect.standardized.applying(page.transform(for: .mediaBox))
        let data = NSMutableData()
        var box = CGRect(origin: .zero, size: drawn.size)
        guard let consumer = CGDataConsumer(data: data as CFMutableData), let context = CGContext(consumer: consumer, mediaBox: &box, nil) else { return nil }
        context.beginPDFPage(nil)
        context.translateBy(x: -drawn.minX, y: -drawn.minY)
        context.clip(to: drawn)
        page.draw(with: .mediaBox, to: context)
        context.endPDFPage()
        context.closePDF()
        return data as Data
    }

    /// The reference line of a package's cover, for files that lost their attachment and field names.
    static func coverReference(in data: Data, known: [UUID]) -> UUID? {
        guard let text = PDFDocument(data: data)?.page(at: 0)?.string?.lowercased() else { return nil }
        return known.first { text.contains($0.uuidString.lowercased()) }
    }

    /// Grey levels of `rect` (page space) of `page` at 2 pixels per point, annotations included.
    private static func gray(_ page: PDFPage, rect: CGRect) -> [UInt8]? {
        let drawn = rect.standardized.applying(page.transform(for: .mediaBox))
        let scale: CGFloat = 2
        let width = max(Int(drawn.width * scale), 1), height = max(Int(drawn.height * scale), 1)
        guard width * height < 4_000_000,
              let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width,
                                      space: CGColorSpaceCreateDeviceGray(), bitmapInfo: CGImageAlphaInfo.none.rawValue) else { return nil }
        context.setFillColor(CGColor(gray: 1, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        context.scaleBy(x: scale, y: scale)
        context.translateBy(x: -drawn.minX, y: -drawn.minY)
        page.draw(with: .mediaBox, to: context)
        guard let pixels = context.data?.assumingMemoryBound(to: UInt8.self) else { return nil }
        return Array(UnsafeBufferPointer(start: pixels, count: width * height))
    }
}
