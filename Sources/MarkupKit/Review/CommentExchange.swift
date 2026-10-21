import AppKit
import PDFKit
import PDFModelKit
import SuperPDFCore

// Comments in and out of the document (features #59, #77): XFDF (Adobe's XML exchange format, ISO 19444-1) both
// ways, FDF and CSV out. Replies and review states travel with `inreplyto`, `replyType`, `state` and `statemodel`, so a
// round trip through Acrobat keeps threads.

enum CommentExchangeError: LocalizedError {
    case unreadable
    case unsupported

    var errorDescription: String? {
        switch self {
        case .unreadable: "This file doesn’t contain comments Super PDF can read."
        case .unsupported: "Super PDF can import comments from XFDF files."
        }
    }
}

@MainActor
enum CommentExchange {
    // MARK: XFDF out

    static func xfdf(of document: DocumentHandle, ledger: AnnotationLedger) -> Data {
        let root = XMLElement(name: "xfdf")
        root.addNamespace(XMLNode.namespace(withName: "", stringValue: "http://ns.adobe.com/xfdf/") as! XMLNode)
        root.addAttribute(XMLNode.attribute(withName: "xml:space", stringValue: "preserve") as! XMLNode)
        let annots = XMLElement(name: "annots")
        for index in 0..<document.pageCount {
            guard let page = document.pdf.page(at: index) else { continue }
            for annotation in page.annotations where AnnotationLedger.isMarkup(annotation) {
                if let element = element(for: annotation, page: index, ledger: ledger) { annots.addChild(element) }
            }
        }
        root.addChild(annots)
        if let url = document.url {
            let file = XMLElement(name: "f")
            file.addAttribute(XMLNode.attribute(withName: "href", stringValue: url.lastPathComponent) as! XMLNode)
            root.addChild(file)
        }
        let xml = XMLDocument(rootElement: root)
        xml.version = "1.0"
        xml.characterEncoding = "UTF-8"
        return xml.xmlData(options: [.nodePrettyPrint])
    }

    private static let elementNames: [String: String] = [
        "Highlight": "highlight", "Underline": "underline", "StrikeOut": "strikeout", "Squiggly": "squiggly", "Text": "text",
        "FreeText": "freetext", "Square": "square", "Circle": "circle", "Line": "line", "Polygon": "polygon", "PolyLine": "polyline",
        "Ink": "ink", "Stamp": "stamp", "Caret": "caret", "FileAttachment": "fileattachment", "Sound": "sound",
    ]

    private static func element(for annotation: PDFAnnotation, page: Int, ledger: AnnotationLedger) -> XMLElement? {
        guard let type = annotation.type, let name = elementNames[type] else { return nil }
        let element = XMLElement(name: name)
        func set(_ key: String, _ value: String?) {
            guard let value, !value.isEmpty else { return }
            element.addAttribute(XMLNode.attribute(withName: key, stringValue: value) as! XMLNode)
        }
        let id = AnnotationLedger.id(of: annotation)
        let record = ledger[id]
        set("page", String(page))
        set("rect", numbers([annotation.bounds.minX, annotation.bounds.minY, annotation.bounds.maxX, annotation.bounds.maxY]))
        set("name", id)
        set("title", annotation.userName)
        set("subject", annotation.value(forAnnotationKey: .subject) as? String)
        set("date", annotation.modificationDate.map { PDFDate.string($0) })
        set("creationdate", annotation.value(forAnnotationKey: .creationDate) as? String)
        if annotation.color.alphaComponent > 0.01 { set("color", MarkupColor(annotation.color).hexRGB) }
        if annotation.color.alphaComponent > 0.01, annotation.color.alphaComponent < 0.99 { set("opacity", numbers([annotation.color.alphaComponent])) }
        set("flags", flags(of: annotation, record: record))
        set("intent", (annotation.value(forAnnotationKey: .intent) as? String).map { $0.trimmingCharacters(in: CharacterSet(charactersIn: "/")) })
        if let parent = record.parent {
            set("inreplyto", parent)
            set("replyType", record.replyType == "Group" ? "group" : "reply")
        }
        if let state = annotation.value(forAnnotationKey: .state) as? String {
            set("state", state)
            set("statemodel", annotation.value(forAnnotationKey: .stateModel) as? String ?? "Review")
        }
        switch type {
        case "Highlight", "Underline", "StrikeOut", "Squiggly":
            let o = annotation.bounds.origin
            set("coords", numbers((annotation.quadrilateralPoints ?? []).flatMap { [$0.pointValue.x + o.x, $0.pointValue.y + o.y] }))
        case "Square", "Circle", "Polygon", "PolyLine", "Ink", "Line":
            set("width", numbers([annotation.border?.lineWidth ?? 1]))
            if annotation.border?.style == .dashed { set("style", "dash"); set("dashes", numbers((annotation.border?.dashPattern as? [CGFloat]) ?? [3, 2])) }
            if let interior = annotation.interiorColor, interior.alphaComponent > 0.01 { set("interior-color", MarkupColor(interior).hexRGB) }
        default: break
        }
        switch type {
        case "Line":
            let (start, end) = AnnotationEditing.lineEnds(of: annotation)
            set("start", numbers([start.x, start.y]))
            set("end", numbers([end.x, end.y]))
            set("head", lineStyleName(annotation.startLineStyle))
            set("tail", lineStyleName(annotation.endLineStyle))
        case "Polygon", "PolyLine":
            let vertices = XMLElement(name: "vertices", stringValue: Measure.points(of: annotation).map { numbers([$0.x, $0.y]) }.joined(separator: ";"))
            element.addChild(vertices)
        case "Ink":
            let list = XMLElement(name: "inklist")
            let o = annotation.bounds.origin
            for path in annotation.paths ?? [] {
                list.addChild(XMLElement(name: "gesture", stringValue: points(of: path).map { numbers([$0.x + o.x, $0.y + o.y]) }.joined(separator: ";")))
            }
            element.addChild(list)
        case "Text":
            set("icon", annotation.iconType == .comment ? "Comment" : "Note")
        case "Stamp":
            set("icon", annotation.stampName)
        case "FreeText":
            let font = annotation.font ?? NSFont(name: "Helvetica", size: 12)!
            let color = MarkupColor(annotation.fontColor ?? .black)
            element.addChild(XMLElement(name: "defaultappearance", stringValue: "/\(font.fontName) \(numbers([font.pointSize])) Tf \(numbers([color.red, color.green, color.blue])) rg"))
            element.addChild(XMLElement(name: "defaultstyle", stringValue: "font: \(font.fontName) \(numbers([font.pointSize]))pt; color: \(color.hexRGB)"))
            set("justification", annotation.alignment == .center ? "centered" : annotation.alignment == .right ? "right" : "left")
        case "FileAttachment":
            set("file", record.file?.fileName)
            set("icon", record.icon)
            if let file = record.file { element.addChild(dataElement(file.data, extra: ["mimetype": file.mimeType])) }
        case "Sound":
            set("icon", record.icon)
            if let sound = record.sound {
                set("bits", String(sound.bits)); set("channels", String(sound.channels)); set("rate", numbers([sound.rate]))
                set("encoding", sound.encoding)
                element.addChild(dataElement(sound.samples, extra: [:]))
            }
        default: break
        }
        if let contents = annotation.contents, !contents.isEmpty {
            element.addChild(XMLElement(name: "contents", stringValue: contents))
        }
        return element
    }

    /// XFDF's `<data MODE="raw" encoding="hex">` for a clipped file or a voice note.
    private static func dataElement(_ data: Data, extra: [String: String?]) -> XMLElement {
        let element = XMLElement(name: "data", stringValue: data.map { String(format: "%02X", $0) }.joined())
        var attributes: [String: String?] = ["MODE": "raw", "encoding": "hex", "length": String(data.count)]
        attributes.merge(extra) { a, _ in a }
        for (key, value) in attributes.sorted(by: { $0.key < $1.key }) {
            if let value { element.addAttribute(XMLNode.attribute(withName: key, stringValue: value) as! XMLNode) }
        }
        return element
    }

    private static func hexData(_ element: XMLElement?) -> Data? {
        guard let text = element?.stringValue?.filter(\.isHexDigit), text.count.isMultiple(of: 2) else { return nil }
        var data = Data(capacity: text.count / 2)
        var index = text.startIndex
        while index < text.endIndex {
            let next = text.index(index, offsetBy: 2)
            guard let byte = UInt8(text[index..<next], radix: 16) else { return nil }
            data.append(byte)
            index = next
        }
        return data
    }

    private static func flags(of annotation: PDFAnnotation, record: LedgerRecord) -> String? {
        if let flags = record.flags { return flagNames(flags) }
        var names: [String] = []
        if !annotation.shouldDisplay { names.append("noview") }
        if annotation.shouldPrint { names.append("print") }
        return names.joined(separator: ",")
    }

    private static func flagNames(_ flags: Int) -> String {
        [(1, "invisible"), (2, "hidden"), (4, "print"), (8, "nozoom"), (16, "norotate"), (32, "noview"), (64, "readonly"), (128, "locked")]
            .filter { flags & $0.0 != 0 }.map(\.1).joined(separator: ",")
    }

    private static func flagValue(_ names: String) -> Int {
        let table = ["invisible": 1, "hidden": 2, "print": 4, "nozoom": 8, "norotate": 16, "noview": 32, "readonly": 64, "locked": 128]
        return names.split(separator: ",").reduce(0) { $0 | (table[$1.trimmingCharacters(in: .whitespaces).lowercased()] ?? 0) }
    }

    static func numbers(_ values: [CGFloat]) -> String { numbers(values.map(Double.init)) }

    static func numbers(_ values: [Double]) -> String {
        values.map { value in
            let rounded = (value * 1000).rounded() / 1000
            return rounded == rounded.rounded() ? String(Int(rounded)) : String(rounded)
        }.joined(separator: ",")
    }

    private static func lineStyleName(_ style: PDFLineStyle) -> String {
        switch style {
        case .none: "None"
        case .square: "Square"
        case .circle: "Circle"
        case .diamond: "Diamond"
        case .openArrow: "OpenArrow"
        case .closedArrow: "ClosedArrow"
        @unknown default: "None"
        }
    }

    private static func lineStyle(_ name: String?) -> PDFLineStyle {
        switch name?.lowercased() {
        case "square": .square
        case "circle": .circle
        case "diamond": .diamond
        case "openarrow": .openArrow
        case "closedarrow": .closedArrow
        default: .none
        }
    }

    static func points(of path: NSBezierPath) -> [CGPoint] {
        var result: [CGPoint] = []
        var buffer = [NSPoint](repeating: .zero, count: 3)
        for index in 0..<path.elementCount {
            switch path.element(at: index, associatedPoints: &buffer) {
            case .moveTo, .lineTo: result.append(buffer[0])
            case .curveTo, .cubicCurveTo: result.append(buffer[2])
            case .quadraticCurveTo: result.append(buffer[1])
            case .closePath: break
            @unknown default: break
            }
        }
        return result
    }

    // MARK: XFDF in

    /// Adds the XFDF file's comments to the document (those whose name is already there are skipped) and returns them
    /// with their pages, ready for one undo step.
    static func importXFDF(_ data: Data, into document: DocumentHandle, ledger: AnnotationLedger) throws -> [(PDFAnnotation, PDFKit.PDFPage)] {
        guard let xml = try? XMLDocument(data: data), let root = xml.rootElement(), root.localName == "xfdf" else {
            throw CommentExchangeError.unreadable
        }
        let existing = Set(CommentList.items(in: document, ledger: ledger).map(\.id))
            .union((0..<document.pageCount).flatMap { document.pdf.page(at: $0)?.annotations.map { AnnotationLedger.id(of: $0) } ?? [] })
        let elements = root.elements(forName: "annots").flatMap { $0.children?.compactMap { $0 as? XMLElement } ?? [] }
        var added: [(PDFAnnotation, PDFKit.PDFPage)] = []
        var links: [(String, String, String)] = []
        for element in elements {
            func attribute(_ key: String) -> String? { element.attribute(forName: key)?.stringValue }
            guard let pageIndex = attribute("page").flatMap(Int.init), let page = document.pdf.page(at: pageIndex),
                  let annotation = annotation(from: element, attribute: attribute) else { continue }
            let id = attribute("name") ?? UUID().uuidString.lowercased()
            if existing.contains(id) { continue }
            annotation.setValue(id, forAnnotationKey: .superPDFID)
            annotation.setValue(id, forAnnotationKey: .name)
            AnnotationFactory.setAuthor(attribute("title") ?? "", of: annotation)
            if let date = attribute("date").flatMap(PDFDate.date) { annotation.modificationDate = date }
            if let created = attribute("creationdate") { annotation.setValue(created, forAnnotationKey: .creationDate) }
            if let subject = attribute("subject") { annotation.setValue(subject, forAnnotationKey: .subject) }
            if let contents = element.elements(forName: "contents").first?.stringValue { annotation.contents = contents }
            if let intent = attribute("intent") { annotation.setValue("/" + intent, forAnnotationKey: .intent) }
            if let state = attribute("state") {
                annotation.setValue(state, forAnnotationKey: .state)
                annotation.setValue(attribute("statemodel") ?? "Review", forAnnotationKey: .stateModel)
                annotation.shouldDisplay = false
            }
            if let flags = attribute("flags").map(flagValue), flags & (32 | 2) != 0 { annotation.shouldDisplay = false }
            if let parent = attribute("inreplyto") {
                links.append((id, parent, attribute("replyType")?.lowercased() == "group" ? "Group" : "R"))
                annotation.shouldDisplay = false
                if attribute("state") == nil {
                    var record = ledger[id]
                    record.flags = attribute("flags").map(flagValue) ?? 4
                    ledger[id] = record
                }
            }
            // A clipped file or a voice note brings its bytes (features #79).
            if let bytes = hexData(element.elements(forName: "data").first) {
                var record = ledger[id]
                record.icon = attribute("icon")
                if element.localName == "fileattachment" {
                    record.file = AttachedFile(fileName: attribute("file") ?? annotation.contents ?? "Attachment", data: bytes,
                                               mimeType: element.elements(forName: "data").first?.attribute(forName: "mimetype")?.stringValue)
                } else {
                    record.sound = SoundClip(samples: bytes, rate: attribute("rate").flatMap(Double.init) ?? 8000,
                                             channels: attribute("channels").flatMap(Int.init) ?? 1, bits: attribute("bits").flatMap(Int.init) ?? 8,
                                             encoding: attribute("encoding") ?? "Raw")
                }
                ledger[id] = record
            }
            page.addAnnotation(annotation)
            added.append((annotation, page))
        }
        for (child, parent, type) in links {
            var record = ledger[child]
            record.parent = parent
            record.replyType = type
            ledger[child] = record
        }
        return added
    }

    private static func annotation(from element: XMLElement, attribute: (String) -> String?) -> PDFAnnotation? {
        let numbersOf = { (text: String?) -> [CGFloat] in
            (text ?? "").split(whereSeparator: { $0 == "," || $0 == ";" || $0 == " " }).compactMap { Double($0) }.map { CGFloat($0) }
        }
        let rectNumbers = numbersOf(attribute("rect"))
        guard rectNumbers.count == 4 else { return nil }
        let rect = Geometry.rect(CGPoint(x: rectNumbers[0], y: rectNumbers[1]), CGPoint(x: rectNumbers[2], y: rectNumbers[3]))
        let color = attribute("color").map { MarkupColor(hex: $0).nsColor }
        let name = element.localName ?? ""
        let annotation: PDFAnnotation
        switch name {
        case "highlight", "underline", "strikeout", "squiggly":
            let coords = numbersOf(attribute("coords"))
            let lines = stride(from: 0, to: coords.count - 7, by: 8).map { i in
                Geometry.bounds(of: stride(from: i, to: i + 8, by: 2).map { CGPoint(x: coords[$0], y: coords[$0 + 1]) })
            }
            let style: TextMarkupStyle = name == "underline" ? .underline : name == "highlight" ? .highlight(.yellow) : .strikethrough
            guard let markup = AnnotationFactory.textMarkup(style, lines: lines.isEmpty ? [rect] : lines, author: "") else { return nil }
            if name == "squiggly" { return nil }
            annotation = markup
        case "text":
            annotation = PDFAnnotation(bounds: rect, forType: .text, withProperties: nil)
            annotation.iconType = attribute("icon") == "Comment" ? .comment : .note
        case "freetext":
            annotation = PDFAnnotation(bounds: rect, forType: .freeText, withProperties: nil)
            let appearance = element.elements(forName: "defaultappearance").first?.stringValue ?? ""
            let parts = appearance.split(separator: " ")
            if let tf = parts.firstIndex(of: "Tf"), tf >= 2, let size = Double(parts[tf - 1]) {
                annotation.font = NSFont(name: String(parts[tf - 2].dropFirst()), size: size) ?? NSFont(name: "Helvetica", size: size)
            }
            if let rg = parts.firstIndex(of: "rg"), rg >= 3, let r = Double(parts[rg - 3]), let g = Double(parts[rg - 2]), let b = Double(parts[rg - 1]) {
                annotation.fontColor = NSColor(srgbRed: r, green: g, blue: b, alpha: 1)
            }
            annotation.alignment = attribute("justification") == "centered" ? .center : attribute("justification") == "right" ? .right : .left
            annotation.color = MarkupColor.clear.nsColor
        case "square", "circle":
            annotation = PDFAnnotation(bounds: rect, forType: name == "square" ? .square : .circle, withProperties: nil)
        case "line":
            let start = numbersOf(attribute("start")), end = numbersOf(attribute("end"))
            guard start.count == 2, end.count == 2 else { return nil }
            annotation = PDFAnnotation(bounds: rect, forType: .line, withProperties: nil)
            AnnotationEditing.setLine(annotation, from: CGPoint(x: start[0], y: start[1]), to: CGPoint(x: end[0], y: end[1]))
            annotation.startLineStyle = lineStyle(attribute("head"))
            annotation.endLineStyle = lineStyle(attribute("tail"))
        case "polygon", "polyline":
            let values = numbersOf(element.elements(forName: "vertices").first?.stringValue)
            let points = stride(from: 0, to: values.count - 1, by: 2).map { CGPoint(x: values[$0], y: values[$0 + 1]) }
            guard points.count > 1 else { return nil }
            annotation = AnnotationFactory.polygon(points, closed: name == "polygon")
            annotation.bounds = rect
        case "ink":
            annotation = PDFAnnotation(bounds: rect, forType: .ink, withProperties: nil)
            for gesture in element.elements(forName: "inklist").first?.elements(forName: "gesture") ?? [] {
                let values = numbersOf(gesture.stringValue)
                let points = stride(from: 0, to: values.count - 1, by: 2).map { CGPoint(x: values[$0] - rect.minX, y: values[$0 + 1] - rect.minY) }
                guard let first = points.first else { continue }
                let path = NSBezierPath()
                path.move(to: first)
                points.dropFirst().forEach { path.line(to: $0) }
                annotation.add(path)
            }
        case "stamp":
            let stamp = StandardStamp(rawValue: attribute("icon") ?? "") ?? .approved
            let drawn = DrawnAnnotation(bounds: rect, type: .stamp, drawing: .stamp(stamp, detail: attribute("title") ?? ""))
            drawn.stampName = stamp.rawValue
            annotation = drawn
        case "caret":
            annotation = DrawnAnnotation(bounds: rect, type: .caret, drawing: .caret)
        case "fileattachment":
            annotation = DrawnAnnotation(bounds: rect, type: .fileAttachment, drawing: .paperclip)
        case "sound":
            annotation = DrawnAnnotation(bounds: rect, type: .sound, drawing: .speaker)
        default:
            return nil
        }
        if let color { annotation.color = color }
        if let interior = attribute("interior-color") { annotation.interiorColor = MarkupColor(hex: interior).nsColor }
        if let width = attribute("width").flatMap(Double.init) {
            let border = PDFBorder()
            border.lineWidth = width
            if attribute("style") == "dash" { border.style = .dashed; border.dashPattern = numbersOf(attribute("dashes")) }
            annotation.border = border
        }
        return annotation
    }

    // MARK: FDF and CSV out

    static func fdf(of document: DocumentHandle, ledger: AnnotationLedger) -> Data {
        var objects: [PDFValue] = []
        var ids: [String: Int] = [:]
        var pending: [(index: Int, child: String, parent: String)] = []
        for index in 0..<document.pageCount {
            guard let page = document.pdf.page(at: index) else { continue }
            for annotation in page.annotations where AnnotationLedger.isMarkup(annotation) {
                guard let type = annotation.type, elementNames[type] != nil else { continue }
                let id = AnnotationLedger.id(of: annotation)
                var dictionary: [String: PDFValue] = [
                    "Type": .name("Annot"), "Subtype": .name(type), "Page": .integer(index), "Rect": .rect(annotation.bounds),
                    "NM": .text(id), "T": .text(annotation.userName ?? ""), "Contents": .text(annotation.contents ?? ""),
                ]
                if let date = annotation.modificationDate { dictionary["M"] = .ascii(PDFDate.string(date)) }
                if annotation.color.alphaComponent > 0.01 {
                    let c = MarkupColor(annotation.color)
                    dictionary["C"] = .array([.real(c.red), .real(c.green), .real(c.blue)])
                }
                if AnnotationEditing.textMarkupTypes.contains(type) {
                    let o = annotation.bounds.origin
                    dictionary["QuadPoints"] = .array((annotation.quadrilateralPoints ?? []).flatMap { [PDFValue.real(Double($0.pointValue.x + o.x)), .real(Double($0.pointValue.y + o.y))] })
                }
                if let state = annotation.value(forAnnotationKey: .state) as? String {
                    dictionary["State"] = .text(state)
                    dictionary["StateModel"] = .text(annotation.value(forAnnotationKey: .stateModel) as? String ?? "Review")
                }
                objects.append(.dictionary(dictionary))
                ids[id] = objects.count + 1   // object 1 is the catalog
                if let parent = ledger[id].parent { pending.append((objects.count - 1, id, parent)) }
            }
        }
        for link in pending {
            guard let target = ids[link.parent], case .dictionary(var dictionary) = objects[link.index] else { continue }
            dictionary["IRT"] = .reference(target, 0)
            dictionary["RT"] = .name(ledger[link.child].replyType ?? "R")
            objects[link.index] = .dictionary(dictionary)
        }
        var fdf: [String: PDFValue] = ["Annots": .array(objects.indices.map { .reference($0 + 2, 0) })]
        if let url = document.url { fdf["F"] = .text(url.lastPathComponent) }
        var out = Data("%FDF-1.2\n%\u{E2}\u{E3}\u{CF}\u{D3}\n".utf8)
        func write(_ number: Int, _ value: PDFValue) {
            out.append(Data("\(number) 0 obj\n".utf8))
            value.write(into: &out)
            out.append(Data("\nendobj\n".utf8))
        }
        write(1, .dictionary(["FDF": .dictionary(fdf)]))
        for (offset, object) in objects.enumerated() { write(offset + 2, object) }
        out.append(Data("trailer\n<< /Root 1 0 R >>\n%%EOF\n".utf8))
        return out
    }

    static func csv(_ items: [CommentItem]) -> Data {
        func field(_ text: String) -> String {
            text.contains(where: { $0 == "," || $0 == "\"" || $0.isNewline }) ? "\"" + text.replacingOccurrences(of: "\"", with: "\"\"") + "\"" : text
        }
        let formatter = ISO8601DateFormatter()
        var lines = ["Page,Type,Author,Date,Status,Comment,Text,Replies"]
        for item in items {
            let replies = item.replies.map { "\($0.author): \($0.text)" }.joined(separator: "\n")
            lines.append([String(item.page + 1), CommentList.title(of: item.kind), item.author, item.modified.map(formatter.string) ?? "",
                          item.status == .none ? "" : CommentList.state(for: item.status), item.text, item.quotedText ?? "", replies]
                .map(field).joined(separator: ","))
        }
        return Data((lines.joined(separator: "\r\n") + "\r\n").utf8)
    }
}
