import AppKit
import CoreGraphics
import Foundation
import SuperPDFCore

// PDF → Word (features #50): an own .docx writer over LayoutKit's blocks, and .rtf through NSAttributedString.
// "Keep the look" puts every block in a text box where it sat on the page (one Word section per PDF page, the page's
// size); "Flowing text" writes paragraphs in reading order with heading styles, real Word lists, tables and inline
// pictures, a page break between PDF pages, running headers and footers left out.

enum WordWriter {
    static func writeDOCX(_ layout: LayoutDocument, source: PDFSource, keepLayout: Bool, to url: URL) throws {
        var builder = OfficeDocxBuilder(layout: layout, source: source, title: url.deletingPathExtension().lastPathComponent)
        let data = try builder.build(keepLayout: keepLayout)
        try data.write(to: url, options: .atomic)
    }

    static func writeRTF(_ layout: LayoutDocument, to url: URL) throws {
        let text = OfficeRichText.attributedString(layout)
        let data = try text.data(from: NSRange(location: 0, length: text.length), documentAttributes: [.documentType: NSAttributedString.DocumentType.rtf])
        try data.write(to: url, options: .atomic)
    }
}

// MARK: - DOCX

/// A Word list format from a printed marker ("•", "3.", "(b)", "iv)").
struct OfficeListStyle: Hashable {
    /// w:numFmt: bullet, decimal, lowerLetter, upperLetter, lowerRoman, upperRoman.
    var format: String
    /// Text around the number ("%1." / "(%1)"), or the bullet character.
    var prefix: String
    var suffix: String
    var start: Int

    /// The abstract numbering this style shares with others of the same look (the start differs per list).
    var look: String { "\(format)|\(prefix)|\(suffix)" }

    static func parse(_ marker: String) -> OfficeListStyle? {
        let marker = marker.trimmingCharacters(in: .whitespaces)
        guard !marker.isEmpty else { return nil }
        if !marker.contains(where: { $0.isLetter || $0.isNumber }) {
            return OfficeListStyle(format: "bullet", prefix: String(marker.prefix(1)), suffix: "", start: 1)
        }
        let punctuation = CharacterSet(charactersIn: "().:]")
        let core = marker.trimmingCharacters(in: punctuation)
        guard !core.isEmpty, let range = marker.range(of: core) else { return nil }
        let prefix = String(marker[..<range.lowerBound]), suffix = String(marker[range.upperBound...])
        if core.allSatisfy(\.isNumber), let n = Int(core) {
            return OfficeListStyle(format: "decimal", prefix: prefix, suffix: suffix, start: n)
        }
        let lower = core.lowercased()
        if (core.count > 1 || lower == "i"), lower.allSatisfy({ "ivxlcdm".contains($0) }), let n = romanValue(lower) {
            return OfficeListStyle(format: core == lower ? "lowerRoman" : "upperRoman", prefix: prefix, suffix: suffix, start: n)
        }
        if core.count == 1, let scalar = lower.unicodeScalars.first, ("a"..."z").contains(Character(scalar)) {
            let n = Int(scalar.value) - 96
            return OfficeListStyle(format: core == lower ? "lowerLetter" : "upperLetter", prefix: prefix, suffix: suffix, start: n)
        }
        return nil
    }

    private static func romanValue(_ text: String) -> Int? {
        let values: [Character: Int] = ["i": 1, "v": 5, "x": 10, "l": 50, "c": 100, "d": 500, "m": 1000]
        var total = 0, previous = 0
        for ch in text.reversed() {
            guard let v = values[ch] else { return nil }
            total += v < previous ? -v : v
            previous = max(previous, v)
        }
        return total > 0 ? total : nil
    }
}

struct OfficeDocxBuilder {
    let layout: LayoutDocument
    let source: PDFSource
    let title: String

    private var media: [(name: String, data: Data)] = []
    private var imageRelationships: [OfficeRelationship] = []
    private var drawingID = 1
    private var zOrder = 1
    private var pagePictures: OfficePictures?
    /// Abstract numberings by look, and the w:num instances (numId → abstract id, start).
    private var abstractLooks: [String: (id: Int, style: OfficeListStyle)] = [:]
    private var nums: [(numID: Int, abstractID: Int, start: Int)] = []

    static let pictureDPI: Double = 150

    init(layout: LayoutDocument, source: PDFSource, title: String) {
        self.layout = layout; self.source = source; self.title = title
    }

    private static let namespaces = """
        xmlns:mc="http://schemas.openxmlformats.org/markup-compatibility/2006" \
        xmlns:r="http://schemas.openxmlformats.org/officeDocument/2006/relationships" \
        xmlns:w="http://schemas.openxmlformats.org/wordprocessingml/2006/main" \
        xmlns:w14="http://schemas.microsoft.com/office/word/2010/wordml" \
        xmlns:wp="http://schemas.openxmlformats.org/drawingml/2006/wordprocessingDrawing" \
        xmlns:wp14="http://schemas.microsoft.com/office/word/2010/wordprocessingDrawing" \
        xmlns:a="http://schemas.openxmlformats.org/drawingml/2006/main" \
        xmlns:pic="http://schemas.openxmlformats.org/drawingml/2006/picture" \
        xmlns:wps="http://schemas.microsoft.com/office/word/2010/wordprocessingShape" \
        mc:Ignorable="w14 wp14"
        """

    mutating func build(keepLayout: Bool) throws -> Data {
        if layout.pages.contains(where: { !$0.figures.isEmpty }) { pagePictures = try? OfficePictures(source, dpi: Self.pictureDPI) }
        let body = keepLayout ? keepTheLookBody() : flowingBody()

        var package = OfficePackage()
        package.add("word/document.xml", xml: "<w:document \(Self.namespaces)><w:body>\(body)</w:body></w:document>",
                    contentType: "application/vnd.openxmlformats-officedocument.wordprocessingml.document.main+xml")
        package.add("word/styles.xml", xml: stylesXML(), contentType: "application/vnd.openxmlformats-officedocument.wordprocessingml.styles+xml")
        package.add("word/settings.xml", xml: """
            <w:settings xmlns:w="http://schemas.openxmlformats.org/wordprocessingml/2006/main"><w:defaultTabStop w:val="720"/>\
            <w:compat><w:compatSetting w:name="compatibilityMode" w:uri="http://schemas.microsoft.com/office/word" w:val="15"/></w:compat></w:settings>
            """, contentType: "application/vnd.openxmlformats-officedocument.wordprocessingml.settings+xml")
        var relationships = [OfficeRelationship(id: "rId1", type: OfficeRelationship.styles, target: "styles.xml"),
                             OfficeRelationship(id: "rId2", type: OfficeRelationship.settings, target: "settings.xml")]
        if !nums.isEmpty {
            package.add("word/numbering.xml", xml: numberingXML(),
                        contentType: "application/vnd.openxmlformats-officedocument.wordprocessingml.numbering+xml")
            relationships.append(OfficeRelationship(id: "rId3", type: OfficeRelationship.numbering, target: "numbering.xml"))
        }
        for item in media { package.add("word/media/\(item.name)", media: item.data) }
        package.addRelationships("word/_rels/document.xml.rels", relationships + imageRelationships)
        package.addProperties(title: title, mainPart: "word/document.xml")
        return package.finish()
    }

    // MARK: Keep the look

    private mutating func keepTheLookBody() -> String {
        var xml = ""
        if layout.pages.isEmpty { return "<w:p/>" + Self.sectionXML(size: CGSize(width: 612, height: 792), margins: 72) }
        for (pageNumber, page) in layout.pages.enumerated() {
            let size = OfficeGeometry.displayedSize(page)
            var drawings = ""
            for figure in page.figures {
                drawings += pictureAnchor(figure, page: page)
            }
            for block in Self.blocksInOrder(page) {
                drawings += textBoxAnchor(block, page: page)
            }
            // Floating tables sit in the body, each followed by a tiny paragraph so Word doesn't merge them.
            for table in Self.tablesInOrder(page) {
                xml += floatingTable(table, page: page) + "<w:p>\(Self.tinyParagraphProperties(section: nil))</w:p>"
            }
            let isLast = pageNumber == layout.pages.count - 1
            let section = Self.sectionXML(size: size, margins: 0)
            xml += "<w:p>\(Self.tinyParagraphProperties(section: isLast ? nil : section))\(drawings)</w:p>"
            if isLast { xml += section }
        }
        return xml
    }

    /// Every block on the page: reading order first, then running headers, footers and page numbers.
    static func blocksInOrder(_ page: LayoutPage) -> [LayoutBlock] {
        var ordered: [LayoutBlock] = []
        var seen: Set<Int> = []
        for element in page.readingOrder {
            if case .block(let id) = element, let block = page.blocks.first(where: { $0.id == id }), seen.insert(id).inserted { ordered.append(block) }
        }
        ordered += page.blocks.filter { !seen.contains($0.id) }
        return ordered
    }

    static func tablesInOrder(_ page: LayoutPage) -> [LayoutTable] {
        var ordered: [LayoutTable] = []
        for element in page.readingOrder {
            if case .table(let id) = element, let table = page.tables.first(where: { $0.id == id }) { ordered.append(table) }
        }
        return ordered + page.tables.filter { t in !ordered.contains { $0.id == t.id } }
    }

    private static func tinyParagraphProperties(section: String?) -> String {
        #"<w:pPr><w:spacing w:before="0" w:after="0" w:line="20" w:lineRule="exact"/><w:rPr><w:sz w:val="2"/></w:rPr>\#(section ?? "")</w:pPr>"#
    }

    static func sectionXML(size: CGSize, margins: CGFloat) -> String {
        let w = min(OfficeUnits.twips(size.width), 31_680), h = min(OfficeUnits.twips(size.height), 31_680), m = OfficeUnits.twips(margins)
        let orient = size.width > size.height ? #" w:orient="landscape""# : ""
        return #"<w:sectPr><w:pgSz w:w="\#(w)" w:h="\#(h)"\#(orient)/><w:pgMar w:top="\#(m)" w:right="\#(m)" w:bottom="\#(m)" w:left="\#(m)" w:header="0" w:footer="0" w:gutter="0"/><w:cols w:space="720"/></w:sectPr>"#
    }

    private mutating func textBoxAnchor(_ block: LayoutBlock, page: LayoutPage) -> String {
        let pageSize = OfficeGeometry.displayedSize(page)
        let rect = OfficeGeometry.displayedRect(block.bounds, in: page)
        // Slack for fonts that set a little wider than the PDF's; the box grows downwards to fit its text.
        let width = min(rect.width * 1.1 + 4, max(pageSize.width - rect.minX, rect.width))
        let height = rect.height * 1.25 + 4
        var lines = OfficeText.lines(block)
        if case .listItem(_, let marker) = block.kind, !lines.isEmpty, !lines[0].isEmpty {
            lines[0][0].text = marker + " " + lines[0][0].text
        }
        var runs = ""
        for (index, line) in lines.enumerated() {
            if index > 0 { runs += "<w:r><w:br/></w:r>" }
            runs += line.map(Self.runXML).joined()
        }
        let paragraph = "<w:p><w:pPr>\(Self.spacing(block))\(Self.justification(block))</w:pPr>\(runs)</w:p>"
        let id = nextDrawingID()
        let z = nextZ()
        let cx = OfficeUnits.emu(width), cy = OfficeUnits.emu(height)
        return """
            <w:r><mc:AlternateContent><mc:Choice Requires="wps"><w:drawing><wp:anchor distT="0" distB="0" distL="0" distR="0" simplePos="0" \
            relativeHeight="\(z)" behindDoc="0" locked="0" layoutInCell="1" allowOverlap="1"><wp:simplePos x="0" y="0"/>\
            <wp:positionH relativeFrom="page"><wp:posOffset>\(OfficeUnits.emu(rect.minX))</wp:posOffset></wp:positionH>\
            <wp:positionV relativeFrom="page"><wp:posOffset>\(OfficeUnits.emu(rect.minY))</wp:posOffset></wp:positionV>\
            <wp:extent cx="\(cx)" cy="\(cy)"/><wp:effectExtent l="0" t="0" r="0" b="0"/><wp:wrapNone/>\
            <wp:docPr id="\(id)" name="Text \(id)"/><wp:cNvGraphicFramePr/>\
            <a:graphic><a:graphicData uri="http://schemas.microsoft.com/office/word/2010/wordprocessingShape"><wps:wsp>\
            <wps:cNvSpPr txBox="1"/><wps:spPr><a:xfrm><a:off x="0" y="0"/><a:ext cx="\(cx)" cy="\(cy)"/></a:xfrm>\
            <a:prstGeom prst="rect"><a:avLst/></a:prstGeom><a:noFill/><a:ln><a:noFill/></a:ln></wps:spPr>\
            <wps:txbx><w:txbxContent>\(paragraph)</w:txbxContent></wps:txbx>\
            <wps:bodyPr rot="0" vert="horz" wrap="square" lIns="0" tIns="0" rIns="0" bIns="0" anchor="t" anchorCtr="0"><a:spAutoFit/></wps:bodyPr>\
            </wps:wsp></a:graphicData></a:graphic></wp:anchor></w:drawing></mc:Choice></mc:AlternateContent></w:r>
            """
    }

    private mutating func pictureAnchor(_ figure: LayoutFigure, page: LayoutPage) -> String {
        let rect = OfficeGeometry.displayedRect(figure.bounds, in: page)
        guard let relationship = pictureRelationship(figure, page: page, rect: rect) else { return "" }
        let id = nextDrawingID()
        let z = nextZ()
        let cx = OfficeUnits.emu(rect.width), cy = OfficeUnits.emu(rect.height)
        return """
            <w:r><w:drawing><wp:anchor distT="0" distB="0" distL="0" distR="0" simplePos="0" relativeHeight="\(z)" behindDoc="1" \
            locked="0" layoutInCell="1" allowOverlap="1"><wp:simplePos x="0" y="0"/>\
            <wp:positionH relativeFrom="page"><wp:posOffset>\(OfficeUnits.emu(rect.minX))</wp:posOffset></wp:positionH>\
            <wp:positionV relativeFrom="page"><wp:posOffset>\(OfficeUnits.emu(rect.minY))</wp:posOffset></wp:positionV>\
            <wp:extent cx="\(cx)" cy="\(cy)"/><wp:effectExtent l="0" t="0" r="0" b="0"/><wp:wrapNone/>\
            <wp:docPr id="\(id)" name="Picture \(id)"/><wp:cNvGraphicFramePr><a:graphicFrameLocks noChangeAspect="1"/></wp:cNvGraphicFramePr>\
            \(Self.pictureGraphic(id: id, relationship: relationship, cx: cx, cy: cy))</wp:anchor></w:drawing></w:r>
            """
    }

    private static func pictureGraphic(id: Int, relationship: String, cx: Int, cy: Int) -> String {
        """
        <a:graphic><a:graphicData uri="http://schemas.openxmlformats.org/drawingml/2006/picture"><pic:pic>\
        <pic:nvPicPr><pic:cNvPr id="\(id)" name="Picture \(id)"/><pic:cNvPicPr/></pic:nvPicPr>\
        <pic:blipFill><a:blip r:embed="\(relationship)"/><a:stretch><a:fillRect/></a:stretch></pic:blipFill>\
        <pic:spPr><a:xfrm><a:off x="0" y="0"/><a:ext cx="\(cx)" cy="\(cy)"/></a:xfrm><a:prstGeom prst="rect"><a:avLst/></a:prstGeom></pic:spPr>\
        </pic:pic></a:graphicData></a:graphic>
        """
    }

    /// The figure cropped from its page picture, added as a media part; the relationship id.
    private mutating func pictureRelationship(_ figure: LayoutFigure, page: LayoutPage, rect: CGRect) -> String? {
        guard let cropped = pagePictures?.crop(page: page.index, rect: rect) else { return nil }
        let isPhoto = figure.kind == .image
        guard let data = try? (isPhoto ? OfficePictures.jpeg(cropped) : OfficePictures.png(cropped)) else { return nil }
        let name = "image\(media.count + 1).\(isPhoto ? "jpeg" : "png")"
        media.append((name, data))
        let id = "rId\(10 + imageRelationships.count)"
        imageRelationships.append(OfficeRelationship(id: id, type: OfficeRelationship.image, target: "media/\(name)"))
        return id
    }

    private func floatingTable(_ table: LayoutTable, page: LayoutPage) -> String {
        let rect = OfficeGeometry.displayedRect(table.bounds, in: page)
        let position = #"<w:tblpPr w:leftFromText="0" w:rightFromText="0" w:topFromText="0" w:bottomFromText="0" w:vertAnchor="page" w:horzAnchor="page" w:tblpX="\#(OfficeUnits.twips(rect.minX))" w:tblpY="\#(OfficeUnits.twips(rect.minY))"/>"#
        return tableXML(table, page: page, positioning: position, fitWidth: nil)
    }

    // MARK: Flowing text

    private mutating func flowingBody() -> String {
        guard let first = layout.pages.first else { return "<w:p/>" + Self.sectionXML(size: CGSize(width: 612, height: 792), margins: 72) }
        let size = OfficeGeometry.displayedSize(first)
        let margins = Self.margins(first)
        let textWidth = max(size.width - 2 * margins, 144)
        var xml = ""
        var currentList: (look: String, numID: Int)?
        for (pageNumber, page) in layout.pages.enumerated() {
            if pageNumber > 0 { xml += #"<w:p><w:r><w:br w:type="page"/></w:r></w:p>"# }
            for element in page.readingOrder {
                switch element {
                case .block(let id):
                    guard let block = page.blocks.first(where: { $0.id == id }) else { continue }
                    switch block.kind {
                    case .header, .footer, .pageNumber:
                        continue
                    case .listItem(let level, let marker):
                        if let style = OfficeListStyle.parse(marker) {
                            let numID: Int
                            if let list = currentList, list.look == style.look || level > 0 {
                                numID = list.numID
                            } else {
                                numID = newNum(style)
                                currentList = (style.look, numID)
                            }
                            xml += paragraphXML(block, properties: #"<w:pStyle w:val="ListParagraph"/><w:numPr><w:ilvl w:val="\#(min(level, 8))"/><w:numId w:val="\#(numID)"/></w:numPr>"#)
                        } else {
                            currentList = nil
                            var runs = OfficeText.paragraph(block)
                            if !runs.isEmpty { runs[0].text = marker + "\t" + runs[0].text }
                            xml += "<w:p><w:pPr><w:pStyle w:val=\"ListParagraph\"/><w:ind w:left=\"720\" w:hanging=\"360\"/></w:pPr>\(runs.map(Self.runXML).joined())</w:p>"
                        }
                        continue
                    case .heading(let level):
                        xml += paragraphXML(block, properties: #"<w:pStyle w:val="Heading\#(min(max(level, 1), 6))"/>"#)
                    case .caption:
                        xml += paragraphXML(block, properties: #"<w:pStyle w:val="Caption"/>"#)
                    case .paragraph:
                        xml += paragraphXML(block, properties: Self.justification(block))
                    }
                    currentList = nil
                case .table(let id):
                    currentList = nil
                    guard let table = page.tables.first(where: { $0.id == id }) else { continue }
                    xml += tableXML(table, page: page, positioning: "", fitWidth: textWidth) + "<w:p/>"
                case .figure(let id):
                    currentList = nil
                    guard let figure = page.figures.first(where: { $0.id == id }) else { continue }
                    xml += inlinePicture(figure, page: page, maxWidth: textWidth)
                }
            }
        }
        return xml + Self.sectionXML(size: size, margins: margins)
    }

    private func paragraphXML(_ block: LayoutBlock, properties: String) -> String {
        let runs = OfficeText.paragraph(block).map(Self.runXML).joined()
        return "<w:p>\(properties.isEmpty ? "" : "<w:pPr>\(properties)</w:pPr>")\(runs)</w:p>"
    }

    private mutating func inlinePicture(_ figure: LayoutFigure, page: LayoutPage, maxWidth: CGFloat) -> String {
        let rect = OfficeGeometry.displayedRect(figure.bounds, in: page)
        guard let relationship = pictureRelationship(figure, page: page, rect: rect) else { return "" }
        let scale = min(1, maxWidth / max(rect.width, 1))
        let cx = OfficeUnits.emu(rect.width * scale), cy = OfficeUnits.emu(rect.height * scale)
        let id = nextDrawingID()
        return """
            <w:p><w:r><w:drawing><wp:inline distT="0" distB="0" distL="0" distR="0"><wp:extent cx="\(cx)" cy="\(cy)"/>\
            <wp:effectExtent l="0" t="0" r="0" b="0"/><wp:docPr id="\(id)" name="Picture \(id)"/>\
            <wp:cNvGraphicFramePr><a:graphicFrameLocks noChangeAspect="1"/></wp:cNvGraphicFramePr>\
            \(Self.pictureGraphic(id: id, relationship: relationship, cx: cx, cy: cy))</wp:inline></w:drawing></w:r></w:p>
            """
    }

    /// Margins from where the first page's text sits, kept between half an inch and an inch and a half.
    private static func margins(_ page: LayoutPage) -> CGFloat {
        let rects = page.blocks.filter { if case .paragraph = $0.kind { true } else { false } }.map { OfficeGeometry.displayedRect($0.bounds, in: page) }
        guard let left = rects.map(\.minX).min() else { return 72 }
        return min(max(left, 36), 108)
    }

    // MARK: Tables

    private func tableXML(_ table: LayoutTable, page: LayoutPage, positioning: String, fitWidth: CGFloat?) -> String {
        var (columns, rows) = OfficeGeometry.grid(table, in: page)
        if let fitWidth {
            let total = columns.reduce(0, +)
            if total > fitWidth { columns = columns.map { $0 * fitWidth / total } }
        }
        let owners = OfficeGeometry.owners(table)
        let bodySize = Self.bodySize(layout)
        var xml = "<w:tbl><w:tblPr><w:tblStyle w:val=\"TableGrid\"/>\(positioning)<w:tblW w:w=\"\(OfficeUnits.twips(columns.reduce(0, +)))\" w:type=\"dxa\"/>"
        xml += #"<w:tblLayout w:type="fixed"/><w:tblCellMar><w:left w:w="57" w:type="dxa"/><w:right w:w="57" w:type="dxa"/></w:tblCellMar><w:tblLook w:val="0000" w:firstRow="0" w:lastRow="0" w:firstColumn="0" w:lastColumn="0" w:noHBand="1" w:noVBand="1"/></w:tblPr>"#
        xml += "<w:tblGrid>" + columns.map { "<w:gridCol w:w=\"\(OfficeUnits.twips($0))\"/>" }.joined() + "</w:tblGrid>"
        for r in 0..<owners.count {
            let header = table.hasHeaderRow && r == 0
            xml += "<w:tr><w:trPr><w:trHeight w:val=\"\(OfficeUnits.twips(rows[min(r, rows.count - 1)]))\" w:hRule=\"atLeast\"/>\(header ? "<w:tblHeader/>" : "")</w:trPr>"
            var c = 0
            while c < owners[r].count {
                guard let cell = owners[r][c] else {
                    xml += "<w:tc><w:tcPr><w:tcW w:w=\"\(OfficeUnits.twips(columns[c]))\" w:type=\"dxa\"/></w:tcPr><w:p/></w:tc>"
                    c += 1
                    continue
                }
                let span = max(1, min(cell.columnSpan, owners[r].count - c))
                let width = columns[c..<c + span].reduce(0, +)
                var properties = "<w:tcW w:w=\"\(OfficeUnits.twips(width))\" w:type=\"dxa\"/>"
                if span > 1 { properties += "<w:gridSpan w:val=\"\(span)\"/>" }
                if cell.rowSpan > 1 { properties += cell.row == r ? #"<w:vMerge w:val="restart"/>"# : "<w:vMerge/>" }
                var content = "<w:p/>"
                if cell.row == r {
                    let paragraphs = cell.text.components(separatedBy: .newlines)
                    content = paragraphs.map { text in
                        let run = OfficeRun(text: text, font: nil, size: bodySize, bold: header, italic: false, color: nil)
                        return #"<w:p><w:pPr><w:spacing w:before="0" w:after="0"/></w:pPr>\#(text.isEmpty ? "" : Self.runXML(run))</w:p>"#
                    }.joined()
                }
                xml += "<w:tc><w:tcPr>\(properties)</w:tcPr>\(content)</w:tc>"
                c += span
            }
            xml += "</w:tr>"
        }
        return xml + "</w:tbl>"
    }

    // MARK: Runs and paragraphs

    static func runXML(_ run: OfficeRun) -> String {
        var properties = ""
        if let font = run.font {
            let f = XML.escape(font)
            properties += #"<w:rFonts w:ascii="\#(f)" w:hAnsi="\#(f)" w:cs="\#(f)" w:eastAsia="\#(f)"/>"#
        }
        if run.bold { properties += "<w:b/><w:bCs/>" }
        if run.italic { properties += "<w:i/><w:iCs/>" }
        if let color = run.color { properties += "<w:color w:val=\"\(color)\"/>" }
        let half = max(2, Int((run.size * 2).rounded()))
        properties += "<w:sz w:val=\"\(half)\"/><w:szCs w:val=\"\(half)\"/>"
        return "<w:r><w:rPr>\(properties)</w:rPr><w:t xml:space=\"preserve\">\(XML.escape(run.text))</w:t></w:r>"
    }

    /// Exact line spacing from the block's baselines, so a text box holds its lines where the PDF had them.
    private static func spacing(_ block: LayoutBlock) -> String {
        let baselines = block.lines.map(\.baseline)
        let size = block.lines.flatMap(\.words).map(\.fontSize).max() ?? 12
        guard baselines.count > 1 else { return #"<w:spacing w:before="0" w:after="0"/>"# }
        let gaps = zip(baselines, baselines.dropFirst()).map { abs($0 - $1) }.sorted()
        let line = max(gaps[gaps.count / 2], size)
        return #"<w:spacing w:before="0" w:after="0" w:line="\#(OfficeUnits.twips(line))" w:lineRule="exact"/>"#
    }

    /// Centred or right-aligned when every line of a multi-line block says so.
    static func justification(_ block: LayoutBlock) -> String {
        guard block.lines.count > 1 else { return "" }
        let bounds = block.bounds
        let centred = block.lines.allSatisfy { abs($0.bounds.midX - bounds.midX) < 3 } && block.lines.contains { $0.bounds.width < bounds.width - 12 }
        if centred { return #"<w:jc w:val="center"/>"# }
        let right = block.lines.allSatisfy { abs($0.bounds.maxX - bounds.maxX) < 2 } && block.lines.contains { $0.bounds.minX > bounds.minX + 12 }
        return right ? #"<w:jc w:val="right"/>"# : ""
    }

    // MARK: Numbering, styles

    private mutating func newNum(_ style: OfficeListStyle) -> Int {
        let abstractID: Int
        if let existing = abstractLooks[style.look] {
            abstractID = existing.id
        } else {
            abstractID = abstractLooks.count
            abstractLooks[style.look] = (abstractID, style)
        }
        let numID = nums.count + 1
        nums.append((numID, abstractID, style.start))
        return numID
    }

    private func numberingXML() -> String {
        var xml = #"<w:numbering xmlns:w="http://schemas.openxmlformats.org/wordprocessingml/2006/main">"#
        for (_, entry) in abstractLooks.sorted(by: { $0.value.id < $1.value.id }) {
            let style = entry.style
            xml += "<w:abstractNum w:abstractNumId=\"\(entry.id)\"><w:multiLevelType w:val=\"hybridMultilevel\"/>"
            for level in 0..<9 {
                let text = style.format == "bullet" ? style.prefix : "\(style.prefix)%\(level + 1)\(style.suffix)"
                let left = 720 + level * 360
                xml += "<w:lvl w:ilvl=\"\(level)\"><w:start w:val=\"1\"/><w:numFmt w:val=\"\(style.format)\"/><w:lvlText w:val=\"\(XML.escape(text))\"/>"
                xml += "<w:lvlJc w:val=\"left\"/><w:pPr><w:ind w:left=\"\(left)\" w:hanging=\"360\"/></w:pPr></w:lvl>"
            }
            xml += "</w:abstractNum>"
        }
        for num in nums {
            xml += "<w:num w:numId=\"\(num.numID)\"><w:abstractNumId w:val=\"\(num.abstractID)\"/>"
            xml += "<w:lvlOverride w:ilvl=\"0\"><w:startOverride w:val=\"\(num.start)\"/></w:lvlOverride></w:num>"
        }
        return xml + "</w:numbering>"
    }

    private func stylesXML() -> String {
        let font = XML.escape(Self.mainFont(layout) ?? "Calibri")
        let body = max(2, Int((Self.bodySize(layout) * 2).rounded()))
        var xml = #"<w:styles xmlns:w="http://schemas.openxmlformats.org/wordprocessingml/2006/main">"#
        xml += #"<w:docDefaults><w:rPrDefault><w:rPr><w:rFonts w:ascii="\#(font)" w:hAnsi="\#(font)" w:cs="\#(font)" w:eastAsia="\#(font)"/><w:sz w:val="\#(body)"/><w:szCs w:val="\#(body)"/><w:lang w:val="en-US"/></w:rPr></w:rPrDefault>"#
        xml += #"<w:pPrDefault><w:pPr><w:spacing w:after="120" w:line="264" w:lineRule="auto"/></w:pPr></w:pPrDefault></w:docDefaults>"#
        xml += #"<w:style w:type="paragraph" w:default="1" w:styleId="Normal"><w:name w:val="Normal"/><w:qFormat/></w:style>"#
        let headingSizes = [32, 28, 26, 24, 22, 22]
        for level in 1...6 {
            xml += #"<w:style w:type="paragraph" w:styleId="Heading\#(level)"><w:name w:val="heading \#(level)"/><w:basedOn w:val="Normal"/><w:next w:val="Normal"/><w:uiPriority w:val="9"/><w:qFormat/>"#
            xml += #"<w:pPr><w:keepNext/><w:keepLines/><w:spacing w:before="240" w:after="120"/><w:outlineLvl w:val="\#(level - 1)"/></w:pPr><w:rPr><w:b/><w:bCs/><w:sz w:val="\#(headingSizes[level - 1])"/><w:szCs w:val="\#(headingSizes[level - 1])"/></w:rPr></w:style>"#
        }
        xml += #"<w:style w:type="paragraph" w:styleId="Caption"><w:name w:val="caption"/><w:basedOn w:val="Normal"/><w:next w:val="Normal"/><w:qFormat/><w:rPr><w:i/><w:iCs/><w:sz w:val="18"/><w:szCs w:val="18"/></w:rPr></w:style>"#
        xml += #"<w:style w:type="paragraph" w:styleId="ListParagraph"><w:name w:val="List Paragraph"/><w:basedOn w:val="Normal"/><w:qFormat/><w:pPr><w:ind w:left="720"/><w:contextualSpacing/></w:pPr></w:style>"#
        xml += #"<w:style w:type="table" w:default="1" w:styleId="TableNormal"><w:name w:val="Normal Table"/><w:uiPriority w:val="99"/><w:semiHidden/><w:tblPr><w:tblInd w:w="0" w:type="dxa"/><w:tblCellMar><w:top w:w="0" w:type="dxa"/><w:left w:w="108" w:type="dxa"/><w:bottom w:w="0" w:type="dxa"/><w:right w:w="108" w:type="dxa"/></w:tblCellMar></w:tblPr></w:style>"#
        let border = #"w:val="single" w:sz="4" w:space="0" w:color="auto""#
        xml += #"<w:style w:type="table" w:styleId="TableGrid"><w:name w:val="Table Grid"/><w:basedOn w:val="TableNormal"/><w:uiPriority w:val="39"/><w:pPr><w:spacing w:after="0" w:line="240" w:lineRule="auto"/></w:pPr><w:tblPr><w:tblBorders><w:top \#(border)/><w:left \#(border)/><w:bottom \#(border)/><w:right \#(border)/><w:insideH \#(border)/><w:insideV \#(border)/></w:tblBorders></w:tblPr></w:style>"#
        return xml + "</w:styles>"
    }

    /// The font family most text is set in.
    static func mainFont(_ layout: LayoutDocument) -> String? {
        var counts: [String: Int] = [:]
        for page in layout.pages {
            for word in page.blocks.flatMap({ $0.lines.flatMap(\.words) }) {
                if let family = OfficeText.fontFamily(word.fontName) { counts[family, default: 0] += word.text.count }
            }
        }
        return counts.max { $0.value == $1.value ? $0.key > $1.key : $0.value < $1.value }?.key
    }

    /// The median word size, for table cells (which carry no style of their own).
    static func bodySize(_ layout: LayoutDocument) -> Double {
        let sizes = layout.pages.flatMap { $0.blocks.flatMap { $0.lines.flatMap(\.words) } }.map(\.fontSize).filter { $0 > 0 }.sorted()
        return sizes.isEmpty ? 11 : sizes[sizes.count / 2]
    }

    private mutating func nextDrawingID() -> Int { defer { drawingID += 1 }; return drawingID }
    private mutating func nextZ() -> Int { defer { zOrder += 1 }; return 251_658_240 + zOrder }
}

// MARK: - RTF

/// The flowing structure as attributed text (RTF has no pictures here; tables become text tables).
enum OfficeRichText {
    static func attributedString(_ layout: LayoutDocument) -> NSAttributedString {
        let out = NSMutableAttributedString()
        let bodySize = OfficeDocxBuilder.bodySize(layout)
        for (pageNumber, page) in layout.pages.enumerated() {
            if pageNumber > 0, out.length > 0 { out.append(NSAttributedString(string: "\u{0C}", attributes: [.font: font(nil, size: bodySize, bold: false, italic: false)])) }
            for element in page.readingOrder {
                switch element {
                case .block(let id):
                    guard let block = page.blocks.first(where: { $0.id == id }) else { continue }
                    let style = NSMutableParagraphStyle()
                    style.paragraphSpacing = 6
                    var runs = OfficeText.paragraph(block)
                    switch block.kind {
                    case .header, .footer, .pageNumber:
                        continue
                    case .heading:
                        style.paragraphSpacingBefore = 12
                        runs = runs.map { var r = $0; r.bold = true; return r }
                    case .listItem(let level, let marker):
                        let indent = CGFloat(36 + 18 * level)
                        style.headIndent = indent
                        style.firstLineHeadIndent = indent - 18
                        style.tabStops = [NSTextTab(textAlignment: .left, location: indent)]
                        if !runs.isEmpty { runs[0].text = marker + "\t" + runs[0].text }
                    case .caption, .paragraph:
                        break
                    }
                    for run in runs { out.append(attributed(run, style: style)) }
                    out.append(NSAttributedString(string: "\n", attributes: [.paragraphStyle: style, .font: font(nil, size: bodySize, bold: false, italic: false)]))
                case .table(let id):
                    guard let table = page.tables.first(where: { $0.id == id }) else { continue }
                    out.append(tableText(table, bodySize: bodySize))
                case .figure:
                    continue
                }
            }
        }
        return out
    }

    private static func tableText(_ table: LayoutTable, bodySize: Double) -> NSAttributedString {
        let out = NSMutableAttributedString()
        let textTable = NSTextTable()
        textTable.numberOfColumns = max(table.columnCount, 1)
        textTable.layoutAlgorithm = .automaticLayoutAlgorithm
        let cells = table.cells.sorted { ($0.row, $0.column) < ($1.row, $1.column) }
        for cell in cells {
            let block = NSTextTableBlock(table: textTable, startingRow: cell.row, rowSpan: max(cell.rowSpan, 1),
                                         startingColumn: cell.column, columnSpan: max(cell.columnSpan, 1))
            block.setWidth(0.5, type: .absoluteValueType, for: .border)
            block.setBorderColor(.black)
            block.setWidth(3, type: .absoluteValueType, for: .padding)
            let style = NSMutableParagraphStyle()
            style.textBlocks = [block]
            let bold = table.hasHeaderRow && cell.row == 0
            out.append(NSAttributedString(string: cell.text.replacingOccurrences(of: "\n", with: " ") + "\n",
                                          attributes: [.font: font(nil, size: bodySize, bold: bold, italic: false), .paragraphStyle: style]))
        }
        return out
    }

    private static func attributed(_ run: OfficeRun, style: NSParagraphStyle) -> NSAttributedString {
        var attributes: [NSAttributedString.Key: Any] = [.font: font(run.font, size: run.size, bold: run.bold, italic: run.italic), .paragraphStyle: style]
        if let hex = run.color { attributes[.foregroundColor] = NSColor(hex: hex) }
        return NSAttributedString(string: run.text, attributes: attributes)
    }

    static func font(_ family: String?, size: Double, bold: Bool, italic: Bool) -> NSFont {
        let size = CGFloat(size > 0 ? size : 12)
        var traits: NSFontDescriptor.SymbolicTraits = []
        if bold { traits.insert(.bold) }
        if italic { traits.insert(.italic) }
        if let family {
            let descriptor = NSFontDescriptor(fontAttributes: [.family: family]).withSymbolicTraits(traits)
            if let font = NSFont(descriptor: descriptor, size: size), font.familyName == family { return font }
        }
        let base = NSFont.systemFont(ofSize: size)
        return NSFont(descriptor: base.fontDescriptor.withSymbolicTraits(traits), size: size) ?? base
    }
}
