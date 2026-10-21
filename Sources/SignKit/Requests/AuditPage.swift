import AppKit
import CoreText
import Foundation
import PDFModelKit
import SuperPDFCore

// The audit page appended before the seal (features #84 step 5): what was sent, to whom, when each person's copy came
// back and the SHA-256 of every file, and who sealed it. The sender's certificate signature sits at its foot.

struct AuditRecord: Sendable {
    var request: SignatureRequest
    var returns: [RequestService.ReturnRecord]
    var packageHash: String
    var sealedBy: String
    var sealedAt: Date
}

enum AuditPage {
    /// `master` with the audit page appended as an update, the page's index and the box for the seal's signature.
    static func append(_ record: AuditRecord, to master: Data) throws -> (data: Data, page: Int, signatureBox: CGRect) {
        var model = try PDFModel(data: master)
        if !model.canSaveIncrementally { model = try PDFModel(data: try model.data()) }
        let size = model.page(at: 0)?.displaySize ?? CGSize(width: 612, height: 792)
        let page = try PDFModel(data: try draw(record, size: size))
        let index = model.pageCount
        try model.insertPages(from: page, pages: [0], at: index)
        // QPDF copies the page's streams when `model` is written: its model lives until then.
        let data = try withExtendedLifetime(page) { model.canSaveIncrementally ? try model.incrementalData() : try model.data() }
        return (data, index, CGRect(x: margin, y: margin, width: 260, height: 64))
    }

    private static let margin: CGFloat = 64

    static func draw(_ record: AuditRecord, size: CGSize) throws -> Data {
        try Appearance.onePagePDF(size: size) { context in
            var y = size.height - margin
            let width = size.width - margin * 2
            func line(_ text: String, size fontSize: CGFloat, bold: Bool = false, gap: CGFloat = 4, color: CGColor = Appearance.ink) {
                y -= fontSize * 1.3
                Appearance.drawLine(text, in: CGRect(x: margin, y: y, width: width, height: fontSize * 1.3), size: fontSize, context: context,
                                    bold: bold, color: color)
                y -= gap
            }
            let grey = CGColor(gray: 0.4, alpha: 1)
            line(SignStrings.auditTitle, size: 20, bold: true, gap: 14)
            line(SignStrings.auditDocument(record.request.documentName), size: 11)
            line(SignStrings.coverReference(record.request.id), size: 11)
            line(SignStrings.auditSent(record.request.created), size: 11)
            line(SignStrings.auditPackage(record.packageHash), size: 8, gap: 16, color: grey)
            for signer in record.request.signers.sorted(by: { $0.order < $1.order }) {
                line("\(signer.name) <\(signer.email)>", size: 12, bold: true)
                line(SignStrings.auditReturned(signer.returnedAt), size: 11)
                for entry in record.returns where entry.signers.contains(signer.id) {
                    line(SignStrings.auditFile(entry.sha256), size: 8, color: grey)
                }
                y -= 10
            }
            line(SignStrings.auditSealed(record.sealedAt, by: record.sealedBy), size: 11, gap: 0)
        }
    }
}
