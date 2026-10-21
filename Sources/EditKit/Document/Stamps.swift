import AppKit
import CoreGraphics
import Foundation
import PDFModelKit
import SuperPDFCore

// Stamps (features #68): the standard set (Approved, Draft, Confidential, Final, Received, Sign here…), dynamic stamps
// with the name, date and time, and custom stamps from a picture or a PDF. A stamp is a Stamp annotation with an
// appearance stream we draw (a rounded border and the words in Helvetica-Bold), so every reader shows it the same.

public struct StampDesign: Codable, Hashable, Sendable {
    public enum Shape: String, Codable, CaseIterable, Sendable { case rounded, plain }

    public var id: String
    /// The words on the stamp; `{name}`, `{date}` and `{time}` are filled in (dynamic stamps).
    public var text: String
    /// "#RRGGBB".
    public var color: String
    public var shape: Shape
    /// A picture or PDF for custom stamps.
    public var file: URL?

    public init(id: String, text: String, color: String = "#C0392B", shape: Shape = .rounded, file: URL? = nil) {
        self.id = id; self.text = text; self.color = color; self.shape = shape; self.file = file
    }

    public var isDynamic: Bool { text.contains("{") }

    /// Acrobat's standard business stamps.
    public static let standard: [StampDesign] = [
        StampDesign(id: "approved", text: "APPROVED", color: "#2E8B57"),
        StampDesign(id: "draft", text: "DRAFT", color: "#C0392B"),
        StampDesign(id: "confidential", text: "CONFIDENTIAL", color: "#C0392B"),
        StampDesign(id: "final", text: "FINAL", color: "#2E8B57"),
        StampDesign(id: "received", text: "RECEIVED", color: "#1F5FBF"),
        StampDesign(id: "sign-here", text: "SIGN HERE", color: "#C0392B", shape: .plain),
        StampDesign(id: "reviewed", text: "REVIEWED", color: "#1F5FBF"),
        StampDesign(id: "void", text: "VOID", color: "#C0392B"),
        StampDesign(id: "approved-by", text: "APPROVED by {name} {date}", color: "#2E8B57"),
        StampDesign(id: "received-on", text: "RECEIVED {date} {time}", color: "#1F5FBF"),
        StampDesign(id: "revised", text: "REVISED {date}", color: "#1F5FBF"),
    ]

    /// The words with the dynamic parts filled in.
    public func rendered(name: String, date: Date = Date()) -> String {
        let day = DateFormatter(), time = DateFormatter()
        day.dateStyle = .medium; day.timeStyle = .none
        time.dateStyle = .none; time.timeStyle = .short
        return text.replacingOccurrences(of: "{name}", with: name).replacingOccurrences(of: "{date}", with: day.string(from: date))
            .replacingOccurrences(of: "{time}", with: time.string(from: date))
    }
}

enum StampWriter {
    static let fontSize = 20.0
    static let padding = 10.0
    static let border = 2.5

    /// The natural size of a text stamp (points).
    static func naturalSize(_ design: StampDesign, name: String) -> CGSize {
        if let file = design.file, let picture = DecorationPicture.load(file) { return CGSize(width: 200, height: 200 / picture.aspect) }
        let text = design.rendered(name: name)
        let font = NSFont(name: "Helvetica-Bold", size: fontSize) ?? NSFont.boldSystemFont(ofSize: fontSize)
        let width = DecorationLayout.textWidth(text, font: font)
        return CGSize(width: width + padding * 2 + border * 2, height: fontSize * 1.25 + padding + border * 2)
    }

    /// Adds the stamp as an annotation with its appearance, in `rect` on page `index` (rotated `rotation` degrees).
    @discardableResult
    static func add(_ design: StampDesign, name: String, in rect: CGRect, rotation: Double, opacity: Double, page: PDFPage) throws -> PDFObject {
        let model = page.model
        let size = naturalSize(design, name: name)
        let form = model.makeStream(["Type": .name("XObject"), "Subtype": .name("Form"), "BBox": .rect(CGRect(origin: .zero, size: size)),
                                     "Group": .dictionary(["S": .name("Transparency"), "CS": .name("DeviceRGB")])], data: Data())
        var ops: [PDFContentOperation] = []
        if opacity < 1 {
            let state = model.makeIndirect(.dictionary(["Type": .name("ExtGState"), "ca": .number(opacity), "CA": .number(opacity)]))
            ops.append(PDFContentOperation("gs", [.name(FormResources(form: form).addResource(state, category: "ExtGState", prefix: "Gs"))]))
        }
        if let file = design.file, let picture = DecorationPicture.load(file) {
            let pictureForm = try DecorationWriter.pictureForm(picture, in: model)
            let bbox = pictureForm["BBox"]?.rect ?? CGRect(x: 0, y: 0, width: 1, height: 1)
            let fit = CGAffineTransform(translationX: -bbox.minX, y: -bbox.minY).concatenating(CGAffineTransform(a: size.width / max(bbox.width, 0.001), b: 0, c: 0, d: size.height / max(bbox.height, 0.001), tx: 0, ty: 0))
            let resource = FormResources(form: form).addResource(pictureForm, category: "XObject", prefix: "Fx")
            ops.append(contentsOf: PDFContentStream.isolated([ContentSurgery.cm(fit), PDFContentOperation("Do", [.name(resource)])]))
        } else {
            let text = design.rendered(name: name)
            let (font, resource) = FontEmbedder.standardFont("Helvetica-Bold", on: FormResources(form: form))
            let shown = font.canShow(text) ? text : String(text.unicodeScalars.filter { font.canShow(String($0)) }.map(Character.init))
            let bytes = font.encode(shown) ?? Data()
            let rgb = BlockStyle.colorOps(for: design.color)
            let stroke = rgb.map { op in PDFContentOperation(op.operator == "g" ? "G" : "RG", op.operands) }
            ops.append(contentsOf: rgb + stroke)
            if design.shape == .rounded {
                ops.append(PDFContentOperation("w", [.number(border)]))
                ops.append(contentsOf: roundedRect(CGRect(x: border / 2, y: border / 2, width: size.width - border, height: size.height - border), radius: 8))
                ops.append(PDFContentOperation("S"))
            }
            let textWidth = font.width(of: shown, size: fontSize)
            ops.append(PDFContentOperation("BT"))
            ops.append(PDFContentOperation("Tf", [.name(resource), .number(fontSize)]))
            ops.append(PDFContentOperation("Tm", [.integer(1), .integer(0), .integer(0), .integer(1), .number(ContentSurgery.round((size.width - textWidth) / 2)),
                                                  .number(ContentSurgery.round((size.height - fontSize * 0.72) / 2))]))
            ops.append(PDFContentOperation("Tj", [.string(bytes)]))
            ops.append(PDFContentOperation("ET"))
        }
        form.setStreamData(PDFContentStream(operations: ops).serialized())
        // The appearance's Matrix rotates the stamp about its centre; /Rect is the rotated box on the page.
        let rotate = CGAffineTransform(translationX: size.width / 2, y: size.height / 2).rotated(by: rotation * .pi / 180).translatedBy(x: -size.width / 2, y: -size.height / 2)
        form.set("Matrix", .matrix(rotate))
        let annotation = model.makeIndirect(.dictionary([
            "Type": .name("Annot"), "Subtype": .name("Stamp"), "Rect": .rect(rect), "F": .integer(4),
            "Name": .name("#" + design.id), "Contents": .text(design.rendered(name: name)), "T": .text(name),
            "M": .ascii(PDFDate.string(Date())), "CA": .number(opacity),
        ]))
        annotation.set("AP", .dictionary([:]))
        annotation["AP"]?.set("N", form)
        return page.addAnnotation(annotation)
    }

    static func roundedRect(_ r: CGRect, radius: Double) -> [PDFContentOperation] {
        let k = 0.5523 * radius
        func p(_ x: Double, _ y: Double) -> [PDFValue] { [.number(ContentSurgery.round(x)), .number(ContentSurgery.round(y))] }
        return [
            PDFContentOperation("m", p(r.minX + radius, r.minY)),
            PDFContentOperation("l", p(r.maxX - radius, r.minY)),
            PDFContentOperation("c", p(r.maxX - radius + k, r.minY) + p(r.maxX, r.minY + radius - k) + p(r.maxX, r.minY + radius)),
            PDFContentOperation("l", p(r.maxX, r.maxY - radius)),
            PDFContentOperation("c", p(r.maxX, r.maxY - radius + k) + p(r.maxX - radius + k, r.maxY) + p(r.maxX - radius, r.maxY)),
            PDFContentOperation("l", p(r.minX + radius, r.maxY)),
            PDFContentOperation("c", p(r.minX + radius - k, r.maxY) + p(r.minX, r.maxY - radius + k) + p(r.minX, r.maxY - radius)),
            PDFContentOperation("l", p(r.minX, r.minY + radius)),
            PDFContentOperation("c", p(r.minX, r.minY + radius - k) + p(r.minX + radius - k, r.minY) + p(r.minX + radius, r.minY)),
            PDFContentOperation("h"),
        ]
    }

    /// Draws a stamp's preview over the page.
    static func preview(_ design: StampDesign, name: String, in rect: CGRect, rotation: Double, opacity: Double, cg: CGContext) {
        let size = naturalSize(design, name: name)
        cg.saveGState()
        cg.setAlpha(CGFloat(opacity))
        cg.translateBy(x: rect.midX, y: rect.midY)
        cg.rotate(by: rotation * .pi / 180)
        cg.scaleBy(x: rect.width / max(size.width, 1), y: rect.height / max(size.height, 1))
        cg.translateBy(x: -size.width / 2, y: -size.height / 2)
        if let file = design.file, let picture = DecorationPicture.load(file) {
            DecorationPreview.draw(DecorationItem(content: .picture(picture), frame: CGRect(origin: .zero, size: size), rotation: 0, opacity: 1, layer: .over,
                                                  visibility: .always, kind: .watermark, artifactSubtype: "Watermark"), in: cg)
        } else {
            let color = NSColor(hex: design.color)
            if design.shape == .rounded {
                cg.setStrokeColor(color.cgColor)
                cg.setLineWidth(border)
                cg.addPath(CGPath(roundedRect: CGRect(x: border / 2, y: border / 2, width: size.width - border, height: size.height - border), cornerWidth: 8, cornerHeight: 8, transform: nil))
                cg.strokePath()
            }
            let font = NSFont(name: "Helvetica-Bold", size: fontSize) ?? NSFont.boldSystemFont(ofSize: fontSize)
            let text = design.rendered(name: name)
            let line = CTLineCreateWithAttributedString(NSAttributedString(string: text, attributes: [.font: font, .foregroundColor: color]))
            cg.textMatrix = .identity
            cg.textPosition = CGPoint(x: (size.width - DecorationLayout.textWidth(text, font: font)) / 2, y: (size.height - fontSize * 0.72) / 2)
            CTLineDraw(line, cg)
        }
        cg.restoreGState()
    }
}
