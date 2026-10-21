import AppKit
import CoreText
import Foundation
import PDFModelKit
import SuperPDFCore

// The signing package (features #84 step 2): the document with a one-page cover in front ("Open in any PDF app, sign in
// the highlighted spots, send it back"), a form field in each place a person signs, tinted in their colour and labelled
// with their name, and `request.json` embedded so the file is recognised when it comes back. Field names and the cover's
// reference line carry the request id too, for files another app rewrote without the attachment.

enum RequestPackage {
    /// Pages of the package before the document's own.
    static let coverPages = 1
    /// The label tab above each field.
    static let tabHeight: CGFloat = 12

    static func build(_ source: PDFSource, request: SignatureRequest) throws -> Data {
        let model = try PDFModel(source)
        guard let first = model.page(at: 0) else { throw PDFModelError.invalidOperation("no pages") }
        // Models whose streams QPDF copies when `model` is written: they live until then.
        let cover = try PDFModel(data: try coverPage(request, size: first.displaySize))
        var sources = [cover]
        try model.insertPages(from: cover, pages: [0], at: 0)

        let acroForm = model.ensureAcroForm()
        let helvetica = model.makeIndirect(.dictionary(["Type": .name("Font"), "Subtype": .name("Type1"), "BaseFont": .name("Helvetica"),
                                                        "Encoding": .name("WinAnsiEncoding")]))
        acroForm.set("DR", .dictionary(["Font": .dictionary(["Helv": helvetica.reference!])]))
        acroForm.set("DA", .ascii("/Helv 0 Tf 0 g"))

        var counters: [String: Int] = [:]
        let order = request.signers.sorted { $0.order < $1.order }
        for field in request.fields {
            guard let signerIndex = order.firstIndex(where: { $0.id == field.signerID }), let page = model.page(at: field.page + coverPages) else { continue }
            let signer = order[signerIndex]
            let base = "\(prefix(request.id))-\(signerIndex + 1)-\(field.kind.rawValue)"
            counters[base, default: 0] += 1
            try addField(field, name: "\(base)-\(counters[base]!)", signer: signer, page: page, to: model, sources: &sources)
        }

        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        model.addEmbeddedFile(try encoder.encode(request.manifest), name: SigningPackageManifest.attachmentName,
                              mimeType: "application/json", description: "Super PDF signature request", creationDate: request.created)
        let data = try model.data()
        withExtendedLifetime(sources) {}
        return data
    }

    /// "sp-1a2b3c4d": the start of every field name in a package.
    static func prefix(_ id: UUID) -> String { "sp-" + String(id.uuidString.lowercased().prefix(8)) }

    /// The request a file answers: its embedded manifest, else (a file another app rewrote without the attachment) the
    /// id prefix in its field names, matched against `known`. The cover's reference line is the last resort, read by
    /// the caller with PDFKit.
    static func requestID(in data: Data, known: [UUID]) -> UUID? {
        guard let model = try? PDFModel(data: data) else { return nil }
        if let json = try? model.embeddedFileData(named: SigningPackageManifest.attachmentName) {
            let decoder = JSONDecoder()
            decoder.dateDecodingStrategy = .iso8601
            if let manifest = try? decoder.decode(SigningPackageManifest.self, from: json) { return manifest.requestID }
        }
        let names = model.formFields().map(\.name)
        return known.first { id in names.contains { $0.hasPrefix(prefix(id) + "-") } }
    }

    // MARK: Fields

    private static func addField(_ field: RequestField, name: String, signer: Signer, page: PDFModelKit.PDFPage, to model: PDFModel,
                                 sources: inout [PDFModel]) throws {
        let rotation = page.rotation
        let widget = widgetRect(field.rect, rotation: rotation)
        let color = NSColor(hex: signer.color).usingColorSpace(.sRGB) ?? .systemPurple
        let tab = label(field.kind, signer: signer)
        let off = try Appearance.formXObject(in: model, rect: widget, rotation: rotation, sources: &sources) { box, context in
            drawField(label: tab, color: color.cgColor, ticked: false, in: box, context: context)
        }
        let tint: PDFValue = .array(components(color.blended(withFraction: 0.85, of: .white) ?? color).map { .number($0) })
        let border: PDFValue = .array(components(color).map { .number($0) })
        var dict: [String: PDFValue] = [
            "Type": .name("Annot"), "Subtype": .name("Widget"), "T": .text(name), "TU": .text("\(signer.name): \(SignStrings.fieldKind(field.kind))"),
            "F": .integer(4), "Rect": .rect(widget), "MK": .dictionary(["BG": tint, "BC": border]),
        ]
        switch field.kind {
        case .signature, .initials:
            dict["FT"] = .name("Sig")
            dict["AP"] = .dictionary(["N": off.reference!])
        case .date, .name:
            dict["FT"] = .name("Tx")
            dict["DA"] = .ascii("/Helv 0 Tf 0 g")
            dict["AP"] = .dictionary(["N": off.reference!])
        case .checkbox:
            let on = try Appearance.formXObject(in: model, rect: widget, rotation: rotation, sources: &sources) { box, context in
                drawField(label: tab, color: color.cgColor, ticked: true, in: box, context: context)
            }
            dict["FT"] = .name("Btn")
            dict["V"] = .name("Off")
            dict["AS"] = .name("Off")
            dict["AP"] = .dictionary(["N": .dictionary(["Yes": on.reference!, "Off": off.reference!])])
        }
        model.addField(.dictionary(dict), on: page)
    }

    /// The field's box with its label tab, which sits above the box as the page is shown.
    static func widgetRect(_ field: CGRect, rotation: Int) -> CGRect {
        let rect = field.standardized
        return switch ((rotation % 360) + 360) % 360 {
        case 90: CGRect(x: rect.minX - tabHeight, y: rect.minY, width: rect.width + tabHeight, height: rect.height)
        case 180: CGRect(x: rect.minX, y: rect.minY - tabHeight, width: rect.width, height: rect.height + tabHeight)
        case 270: CGRect(x: rect.minX, y: rect.minY, width: rect.width + tabHeight, height: rect.height)
        default: CGRect(x: rect.minX, y: rect.minY, width: rect.width, height: rect.height + tabHeight)
        }
    }

    /// A field as the mockup shows it: a light box in the person's colour with a tab above naming them and the kind.
    static func drawField(label: String, color: CGColor, ticked: Bool, in box: CGRect, context: CGContext) {
        let field = CGRect(x: box.minX, y: box.minY, width: box.width, height: box.height - tabHeight)
        context.setFillColor(color.copy(alpha: 0.12) ?? color)
        context.fill(field)
        context.setStrokeColor(color.copy(alpha: 0.7) ?? color)
        context.setLineWidth(0.75)
        context.stroke(field.insetBy(dx: 0.375, dy: 0.375))
        let tabWidth = min(box.width, Appearance.lineWidth(label, size: 7, bold: true) + 8)
        let tab = CGRect(x: box.minX, y: field.maxY, width: tabWidth, height: tabHeight)
        context.setFillColor(color)
        context.addPath(CGPath(roundedRect: tab, cornerWidth: 2, cornerHeight: 2, transform: nil))
        context.fillPath()
        Appearance.drawOutlined(label, in: tab.insetBy(dx: 4, dy: 0), size: 7, context: context, bold: true, color: CGColor(gray: 1, alpha: 1))
        if ticked {
            let s = min(field.width, field.height) * 0.7
            let check = CGRect(x: field.midX - s / 2, y: field.midY - s / 2, width: s, height: s)
            context.setStrokeColor(Appearance.ink)
            context.setLineWidth(max(s * 0.12, 1))
            context.setLineCap(.round)
            context.move(to: CGPoint(x: check.minX, y: check.midY))
            context.addLine(to: CGPoint(x: check.minX + s * 0.38, y: check.minY + s * 0.1))
            context.addLine(to: CGPoint(x: check.maxX, y: check.maxY))
            context.strokePath()
        }
    }

    // MARK: Cover

    static func coverPage(_ request: SignatureRequest, size: CGSize) throws -> Data {
        try Appearance.onePagePDF(size: size) { context in
            let margin: CGFloat = 64
            var y = size.height - margin
            func paragraph(_ text: String, size fontSize: CGFloat, bold: Bool = false, color: CGColor = Appearance.ink, gap: CGFloat = 10) {
                let attributes: [CFString: Any] = [kCTFontAttributeName: Appearance.font(size: fontSize, bold: bold), kCTForegroundColorAttributeName: color]
                let string = CFAttributedStringCreate(nil, text as CFString, attributes as CFDictionary)!
                let setter = CTFramesetterCreateWithAttributedString(string)
                let width = size.width - margin * 2
                let fit = CTFramesetterSuggestFrameSizeWithConstraints(setter, CFRange(), nil, CGSize(width: width, height: .greatestFiniteMagnitude), nil)
                let frame = CTFramesetterCreateFrame(setter, CFRange(), CGPath(rect: CGRect(x: margin, y: y - fit.height, width: width, height: fit.height),
                                                                               transform: nil), nil)
                CTFrameDraw(frame, context)
                y -= fit.height + gap
            }
            paragraph(SignStrings.coverTitle(request.documentName), size: 22, bold: true, gap: 14)
            paragraph(SignStrings.coverInstructions, size: 14, gap: 24)
            if !request.message.isEmpty { paragraph(request.message, size: 12, gap: 24) }
            paragraph(SignStrings.coverWho, size: 13, bold: true, gap: 8)
            let order = request.signers.sorted { $0.order < $1.order }
            for (index, signer) in order.enumerated() {
                let color = (NSColor(hex: signer.color).usingColorSpace(.sRGB) ?? .systemPurple).cgColor
                context.setFillColor(color)
                context.fillEllipse(in: CGRect(x: margin, y: y - 13, width: 10, height: 10))
                let count = request.fields.filter { $0.signerID == signer.id }.count
                let line = (request.signInOrder ? "\(index + 1). " : "") + "\(signer.name) — \(signer.email) — \(SignStrings.fields(count))"
                Appearance.drawLine(line, in: CGRect(x: margin + 18, y: y - 16, width: size.width - margin * 2 - 18, height: 16), size: 12,
                                    context: context)
                y -= 24
            }
            if request.signInOrder { y -= 4; paragraph(SignStrings.coverOrder, size: 12) }
            Appearance.drawLine(SignStrings.coverReference(request.id), in: CGRect(x: margin, y: margin / 2, width: size.width - margin * 2, height: 12),
                                size: 8, context: context, color: CGColor(gray: 0.45, alpha: 1))
        }
    }

    // MARK: Helpers

    /// The tab's words: "Margaret · Signature".
    static func label(_ kind: RequestFieldKind, signer: Signer) -> String { "\(firstName(signer.name)) · \(SignStrings.fieldKind(kind))" }

    static func firstName(_ name: String) -> String {
        name.split(separator: " ").first.map(String.init) ?? name
    }

    private static func components(_ color: NSColor) -> [Double] {
        let c = color.usingColorSpace(.sRGB) ?? color
        return [Double(c.redComponent), Double(c.greenComponent), Double(c.blueComponent)]
    }
}
