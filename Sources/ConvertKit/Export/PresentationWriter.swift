import CoreGraphics
import Foundation
import SuperPDFCore

// PDF → PowerPoint (features #52): an own .pptx writer. One slide per page. "Editable text over page pictures": the page
// drawn without its text as the slide's picture, and every text block as an editable text box where it sat, so the look
// stays and the words can be changed. Off: "Text only" slides with the largest heading as the title and the rest as
// body text in the layout's placeholders.

enum PresentationWriter {
    static func write(_ layout: LayoutDocument, source: PDFSource, picturesUnderText: Bool, to url: URL) throws {
        let data = try OfficePPTX.package(layout, source: source, picturesUnderText: picturesUnderText,
                                          title: url.deletingPathExtension().lastPathComponent)
        try data.write(to: url, options: .atomic)
    }
}

enum OfficePPTX {
    static let pictureDPI: Double = 160
    static let ns = #"xmlns:a="http://schemas.openxmlformats.org/drawingml/2006/main" xmlns:r="http://schemas.openxmlformats.org/officeDocument/2006/relationships" xmlns:p="http://schemas.openxmlformats.org/presentationml/2006/main""#

    /// The slide size: the first page's, in PowerPoint's allowed range (1–56 inches a side).
    static func slideSize(_ layout: LayoutDocument) -> CGSize {
        let size = layout.pages.first.map(OfficeGeometry.displayedSize) ?? CGSize(width: 720, height: 540)
        let scale = min(1, 4032 / max(size.width, size.height))
        return CGSize(width: min(max(size.width * scale, 72), 4032), height: min(max(size.height * scale, 72), 4032))
    }

    static func package(_ layout: LayoutDocument, source: PDFSource, picturesUnderText: Bool, title: String) throws -> Data {
        let slide = slideSize(layout)
        let pictures = picturesUnderText ? try OfficePictures.withoutText(source, pages: layout.pages.map(\.index), dpi: pictureDPI) : nil
        var package = OfficePackage()
        var presentationRelationships = [OfficeRelationship(id: "rId1", type: OfficeRelationship.slideMaster, target: "slideMasters/slideMaster1.xml")]
        var slideIDs = ""
        let pages = layout.pages.isEmpty ? [LayoutPage(index: 0, size: slide)] : layout.pages
        for (number, page) in pages.enumerated() {
            let n = number + 1
            var relationships = [OfficeRelationship(id: "rId1", type: OfficeRelationship.slideLayout, target: "../slideLayouts/slideLayout1.xml")]
            var shapes = ""
            if picturesUnderText {
                // The page fitted and centred on the slide.
                let pageSize = OfficeGeometry.displayedSize(page)
                let scale = min(slide.width / max(pageSize.width, 1), slide.height / max(pageSize.height, 1))
                let offset = CGPoint(x: (slide.width - pageSize.width * scale) / 2, y: (slide.height - pageSize.height * scale) / 2)
                var id = 2
                if let picture = pictures?.page(page.index), let jpeg = try? OfficePictures.jpeg(picture, quality: 0.82) {
                    package.add("ppt/media/image\(n).jpeg", media: jpeg)
                    relationships.append(OfficeRelationship(id: "rId2", type: OfficeRelationship.image, target: "../media/image\(n).jpeg"))
                    let frame = CGRect(x: offset.x, y: offset.y, width: pageSize.width * scale, height: pageSize.height * scale)
                    shapes += pictureShape(id: id, name: "Page \(page.index + 1)", relationship: "rId2", frame: frame)
                    id += 1
                }
                for block in OfficeDocxBuilder.blocksInOrder(page) {
                    let rect = OfficeGeometry.displayedRect(block.bounds, in: page)
                    var frame = CGRect(x: offset.x + rect.minX * scale, y: offset.y + rect.minY * scale,
                                       width: rect.width * scale * 1.08 + 4, height: rect.height * scale * 1.15 + 2)
                    frame.size.width = min(frame.width, max(slide.width - frame.minX, rect.width * scale))
                    shapes += textBox(id: id, block: block, frame: frame, scale: scale)
                    id += 1
                }
                // Table text cell by cell, over the rules the page picture keeps.
                let bodySize = OfficeDocxBuilder.bodySize(layout)
                for table in OfficeDocxBuilder.tablesInOrder(page) {
                    for cell in table.cells where !cell.text.isEmpty {
                        let rect = OfficeGeometry.displayedRect(cell.bounds, in: page).insetBy(dx: 2, dy: 1)
                        let frame = CGRect(x: offset.x + rect.minX * scale, y: offset.y + rect.minY * scale,
                                           width: rect.width * scale, height: rect.height * scale)
                        let run = OfficeRun(text: cell.text.replacingOccurrences(of: "\n", with: " "), font: nil, size: bodySize,
                                            bold: table.hasHeaderRow && cell.row == 0, italic: false, color: nil)
                        shapes += shape(id: id, name: "Cell \(id)", frame: frame,
                                        paragraphs: "<a:p><a:r>\(runProperties(run, scale: scale))<a:t>\(XML.escape(run.text))</a:t></a:r></a:p>")
                        id += 1
                    }
                }
            } else {
                shapes += textOnly(page)
            }
            package.add("ppt/slides/slide\(n).xml", xml: """
                <p:sld \(ns)><p:cSld><p:spTree><p:nvGrpSpPr><p:cNvPr id="1" name=""/><p:cNvGrpSpPr/><p:nvPr/></p:nvGrpSpPr>\
                <p:grpSpPr><a:xfrm><a:off x="0" y="0"/><a:ext cx="0" cy="0"/><a:chOff x="0" y="0"/><a:chExt cx="0" cy="0"/></a:xfrm></p:grpSpPr>\
                \(shapes)</p:spTree></p:cSld><p:clrMapOvr><a:masterClrMapping/></p:clrMapOvr></p:sld>
                """, contentType: "application/vnd.openxmlformats-officedocument.presentationml.slide+xml")
            package.addRelationships("ppt/slides/_rels/slide\(n).xml.rels", relationships)
            presentationRelationships.append(OfficeRelationship(id: "rId\(n + 1)", type: OfficeRelationship.slide, target: "slides/slide\(n).xml"))
            slideIDs += "<p:sldId id=\"\(255 + n)\" r:id=\"rId\(n + 1)\"/>"
        }
        let next = pages.count + 2
        presentationRelationships += [
            OfficeRelationship(id: "rId\(next)", type: OfficeRelationship.theme, target: "theme/theme1.xml"),
            OfficeRelationship(id: "rId\(next + 1)", type: OfficeRelationship.presProps, target: "presProps.xml"),
            OfficeRelationship(id: "rId\(next + 2)", type: OfficeRelationship.viewProps, target: "viewProps.xml"),
            OfficeRelationship(id: "rId\(next + 3)", type: OfficeRelationship.tableStyles, target: "tableStyles.xml"),
        ]
        let cx = OfficeUnits.emu(slide.width), cy = OfficeUnits.emu(slide.height)
        package.add("ppt/presentation.xml", xml: """
            <p:presentation \(ns) saveSubsetFonts="1"><p:sldMasterIdLst><p:sldMasterId id="2147483648" r:id="rId1"/></p:sldMasterIdLst>\
            <p:sldIdLst>\(slideIDs)</p:sldIdLst><p:sldSz cx="\(cx)" cy="\(cy)"/><p:notesSz cx="6858000" cy="9144000"/>\
            <p:defaultTextStyle><a:defPPr><a:defRPr lang="en-US"/></a:defPPr></p:defaultTextStyle></p:presentation>
            """, contentType: "application/vnd.openxmlformats-officedocument.presentationml.presentation.main+xml")
        package.addRelationships("ppt/_rels/presentation.xml.rels", presentationRelationships)
        package.add("ppt/presProps.xml", xml: "<p:presentationPr \(ns)/>",
                    contentType: "application/vnd.openxmlformats-officedocument.presentationml.presProps+xml")
        package.add("ppt/viewProps.xml", xml: """
            <p:viewPr \(ns)><p:normalViewPr><p:restoredLeft sz="15620"/><p:restoredTop sz="94660"/></p:normalViewPr>\
            <p:gridSpacing cx="76200" cy="76200"/></p:viewPr>
            """, contentType: "application/vnd.openxmlformats-officedocument.presentationml.viewProps+xml")
        package.add("ppt/tableStyles.xml", xml: #"<a:tblStyleLst xmlns:a="http://schemas.openxmlformats.org/drawingml/2006/main" def="{5C22544A-7EE6-4342-B048-85BDC9FD1C3A}"/>"#,
                    contentType: "application/vnd.openxmlformats-officedocument.presentationml.tableStyles+xml")
        package.add("ppt/slideMasters/slideMaster1.xml", xml: masterXML(slide),
                    contentType: "application/vnd.openxmlformats-officedocument.presentationml.slideMaster+xml")
        package.addRelationships("ppt/slideMasters/_rels/slideMaster1.xml.rels", [
            OfficeRelationship(id: "rId1", type: OfficeRelationship.slideLayout, target: "../slideLayouts/slideLayout1.xml"),
            OfficeRelationship(id: "rId2", type: OfficeRelationship.theme, target: "../theme/theme1.xml"),
        ])
        package.add("ppt/slideLayouts/slideLayout1.xml", xml: layoutXML(),
                    contentType: "application/vnd.openxmlformats-officedocument.presentationml.slideLayout+xml")
        package.addRelationships("ppt/slideLayouts/_rels/slideLayout1.xml.rels", [
            OfficeRelationship(id: "rId1", type: OfficeRelationship.slideMaster, target: "../slideMasters/slideMaster1.xml"),
        ])
        package.add("ppt/theme/theme1.xml", xml: themeXML(), contentType: "application/vnd.openxmlformats-officedocument.theme+xml")
        package.addProperties(title: title, mainPart: "ppt/presentation.xml")
        return package.finish()
    }

    // MARK: Shapes

    private static func xfrm(_ frame: CGRect) -> String {
        #"<a:xfrm><a:off x="\#(OfficeUnits.emu(frame.minX))" y="\#(OfficeUnits.emu(frame.minY))"/><a:ext cx="\#(max(OfficeUnits.emu(frame.width), 12_700))" cy="\#(max(OfficeUnits.emu(frame.height), 12_700))"/></a:xfrm>"#
    }

    static func pictureShape(id: Int, name: String, relationship: String, frame: CGRect) -> String {
        """
        <p:pic><p:nvPicPr><p:cNvPr id="\(id)" name="\(XML.escape(name))"/><p:cNvPicPr><a:picLocks noChangeAspect="1"/></p:cNvPicPr><p:nvPr/></p:nvPicPr>\
        <p:blipFill><a:blip r:embed="\(relationship)"/><a:stretch><a:fillRect/></a:stretch></p:blipFill>\
        <p:spPr>\(xfrm(frame))<a:prstGeom prst="rect"><a:avLst/></a:prstGeom></p:spPr></p:pic>
        """
    }

    private static func textBox(id: Int, block: LayoutBlock, frame: CGRect, scale: CGFloat) -> String {
        var lines = OfficeText.lines(block)
        if case .listItem(_, let marker) = block.kind, !lines.isEmpty, !lines[0].isEmpty { lines[0][0].text = marker + " " + lines[0][0].text }
        let algn: String
        switch OfficeDocxBuilder.justification(block) {
        case let j where j.contains("center"): algn = " algn=\"ctr\""
        case let j where j.contains("right"): algn = " algn=\"r\""
        default: algn = ""
        }
        var paragraph = "<a:p><a:pPr\(algn)/>"
        for (index, line) in lines.enumerated() {
            if index > 0 { paragraph += "<a:br>\(runProperties(line.first, scale: scale))</a:br>" }
            paragraph += line.map { run in "<a:r>\(runProperties(run, scale: scale))<a:t>\(XML.escape(run.text))</a:t></a:r>" }.joined()
        }
        paragraph += "</a:p>"
        return shape(id: id, name: "Text \(id)", frame: frame, paragraphs: paragraph)
    }

    private static func shape(id: Int, name: String, frame: CGRect, paragraphs: String) -> String {
        """
        <p:sp><p:nvSpPr><p:cNvPr id="\(id)" name="\(XML.escape(name))"/><p:cNvSpPr txBox="1"/><p:nvPr/></p:nvSpPr>\
        <p:spPr>\(xfrm(frame))<a:prstGeom prst="rect"><a:avLst/></a:prstGeom><a:noFill/></p:spPr>\
        <p:txBody><a:bodyPr wrap="square" lIns="0" tIns="0" rIns="0" bIns="0" rtlCol="0"><a:spAutoFit/></a:bodyPr><a:lstStyle/>\(paragraphs)</p:txBody></p:sp>
        """
    }

    static func runProperties(_ run: OfficeRun?, scale: CGFloat) -> String {
        guard let run else { return #"<a:rPr lang="en-US" dirty="0"/>"# }
        let size = min(max(Int((run.size * Double(scale) * 100).rounded()), 100), 400_000)
        var xml = #"<a:rPr lang="en-US" sz="\#(size)" b="\#(run.bold ? 1 : 0)" i="\#(run.italic ? 1 : 0)" dirty="0">"#
        if let color = run.color { xml += #"<a:solidFill><a:srgbClr val="\#(color)"/></a:solidFill>"# }
        if let font = run.font { xml += #"<a:latin typeface="\#(XML.escape(font))"/><a:cs typeface="\#(XML.escape(font))"/>"# }
        return xml + "</a:rPr>"
    }

    /// "Text only": the largest heading as the slide title, everything else as body paragraphs (list items as bullets at
    /// their level, other paragraphs without a bullet, table rows tab-separated).
    private static func textOnly(_ page: LayoutPage) -> String {
        let blocks = OfficeDocxBuilder.blocksInOrder(page).filter {
            switch $0.kind { case .header, .footer, .pageNumber: false; default: true }
        }
        let titleBlock = blocks.compactMap { block -> (LayoutBlock, Int)? in
            if case .heading(let level) = block.kind { return (block, level) }
            return nil
        }.min { $0.1 < $1.1 }?.0
        var shapes = ""
        if let titleBlock {
            let text = OfficeText.paragraph(titleBlock).map(\.text).joined()
            shapes += """
                <p:sp><p:nvSpPr><p:cNvPr id="2" name="Title 1"/><p:cNvSpPr><a:spLocks noGrp="1"/></p:cNvSpPr><p:nvPr><p:ph type="title"/></p:nvPr></p:nvSpPr>\
                <p:spPr/><p:txBody><a:bodyPr><a:normAutofit/></a:bodyPr><a:lstStyle/><a:p><a:r><a:rPr lang="en-US" dirty="0"/><a:t>\(XML.escape(text))</a:t></a:r></a:p></p:txBody></p:sp>
                """
        }
        var paragraphs = ""
        var elements: [LayoutElement] = page.readingOrder
        for block in blocks where !elements.contains(.block(block.id)) { elements.append(.block(block.id)) }
        for element in elements {
            switch element {
            case .block(let id):
                guard let block = blocks.first(where: { $0.id == id }), block.id != titleBlock?.id else { continue }
                let text = OfficeText.paragraph(block).map(\.text).joined()
                guard !text.isEmpty else { continue }
                if case .listItem(let level, _) = block.kind {
                    paragraphs += #"<a:p><a:pPr lvl="\#(min(level, 8))"/><a:r><a:rPr lang="en-US" dirty="0"/><a:t>\#(XML.escape(text))</a:t></a:r></a:p>"#
                } else {
                    paragraphs += #"<a:p><a:pPr marL="0" indent="0"><a:buNone/></a:pPr><a:r><a:rPr lang="en-US" dirty="0"/><a:t>\#(XML.escape(text))</a:t></a:r></a:p>"#
                }
            case .table(let id):
                guard let table = page.tables.first(where: { $0.id == id }) else { continue }
                for row in 0..<table.rowCount {
                    let text = table.cells.filter { $0.row == row }.sorted { $0.column < $1.column }.map(\.text).joined(separator: "\t")
                    paragraphs += #"<a:p><a:pPr marL="0" indent="0"><a:buNone/></a:pPr><a:r><a:rPr lang="en-US" dirty="0"/><a:t>\#(XML.escape(text))</a:t></a:r></a:p>"#
                }
            case .figure:
                continue
            }
        }
        if !paragraphs.isEmpty {
            shapes += """
                <p:sp><p:nvSpPr><p:cNvPr id="3" name="Content 2"/><p:cNvSpPr><a:spLocks noGrp="1"/></p:cNvSpPr><p:nvPr><p:ph idx="1"/></p:nvPr></p:nvSpPr>\
                <p:spPr/><p:txBody><a:bodyPr><a:normAutofit/></a:bodyPr><a:lstStyle/>\(paragraphs)</p:txBody></p:sp>
                """
        }
        return shapes
    }

    // MARK: Master, layout, theme

    private static func placeholderFrames(_ slide: CGSize) -> (title: CGRect, body: CGRect) {
        let margin = slide.width * 0.06
        let title = CGRect(x: margin, y: slide.height * 0.05, width: slide.width - 2 * margin, height: slide.height * 0.17)
        let body = CGRect(x: margin, y: slide.height * 0.25, width: slide.width - 2 * margin, height: slide.height * 0.68)
        return (title, body)
    }

    private static func masterXML(_ slide: CGSize) -> String {
        let frames = placeholderFrames(slide)
        let titleSize = Int(min(max(slide.height / 540 * 3600, 1200), 8000))
        let bodySize = Int(min(max(slide.height / 540 * 2400, 900), 6000))
        func level(_ n: Int, size: Int) -> String {
            let marL = 228_600 + n * 457_200
            return #"<a:lvl\#(n + 1)pPr marL="\#(marL)" indent="-228600" algn="l"><a:spcBef><a:spcPts val="600"/></a:spcBef><a:buFont typeface="Arial"/><a:buChar char="•"/><a:defRPr sz="\#(size)"><a:solidFill><a:schemeClr val="tx1"/></a:solidFill><a:latin typeface="+mn-lt"/><a:ea typeface="+mn-ea"/><a:cs typeface="+mn-cs"/></a:defRPr></a:lvl\#(n + 1)pPr>"#
        }
        let levels = (0..<9).map { level($0, size: max(bodySize - $0 * 200, 800)) }.joined()
        return """
            <p:sldMaster \(ns)><p:cSld><p:bg><p:bgPr><a:solidFill><a:schemeClr val="bg1"/></a:solidFill><a:effectLst/></p:bgPr></p:bg><p:spTree>\
            <p:nvGrpSpPr><p:cNvPr id="1" name=""/><p:cNvGrpSpPr/><p:nvPr/></p:nvGrpSpPr>\
            <p:grpSpPr><a:xfrm><a:off x="0" y="0"/><a:ext cx="0" cy="0"/><a:chOff x="0" y="0"/><a:chExt cx="0" cy="0"/></a:xfrm></p:grpSpPr>\
            <p:sp><p:nvSpPr><p:cNvPr id="2" name="Title Placeholder 1"/><p:cNvSpPr><a:spLocks noGrp="1"/></p:cNvSpPr><p:nvPr><p:ph type="title"/></p:nvPr></p:nvSpPr>\
            <p:spPr>\(xfrm(frames.title))<a:prstGeom prst="rect"><a:avLst/></a:prstGeom></p:spPr>\
            <p:txBody><a:bodyPr vert="horz" lIns="91440" tIns="45720" rIns="91440" bIns="45720" rtlCol="0" anchor="ctr"><a:normAutofit/></a:bodyPr><a:lstStyle/>\
            <a:p><a:r><a:rPr lang="en-US"/><a:t>Title</a:t></a:r></a:p></p:txBody></p:sp>\
            <p:sp><p:nvSpPr><p:cNvPr id="3" name="Text Placeholder 2"/><p:cNvSpPr><a:spLocks noGrp="1"/></p:cNvSpPr><p:nvPr><p:ph type="body" idx="1"/></p:nvPr></p:nvSpPr>\
            <p:spPr>\(xfrm(frames.body))<a:prstGeom prst="rect"><a:avLst/></a:prstGeom></p:spPr>\
            <p:txBody><a:bodyPr vert="horz" lIns="91440" tIns="45720" rIns="91440" bIns="45720" rtlCol="0"><a:normAutofit/></a:bodyPr><a:lstStyle/>\
            <a:p><a:pPr lvl="0"/><a:r><a:rPr lang="en-US"/><a:t>Text</a:t></a:r></a:p></p:txBody></p:sp>\
            </p:spTree></p:cSld>\
            <p:clrMap bg1="lt1" tx1="dk1" bg2="lt2" tx2="dk2" accent1="accent1" accent2="accent2" accent3="accent3" accent4="accent4" \
            accent5="accent5" accent6="accent6" hlink="hlink" folHlink="folHlink"/>\
            <p:sldLayoutIdLst><p:sldLayoutId id="2147483649" r:id="rId1"/></p:sldLayoutIdLst>\
            <p:txStyles><p:titleStyle><a:lvl1pPr algn="l"><a:spcBef><a:spcPct val="0"/></a:spcBef><a:buNone/>\
            <a:defRPr sz="\(titleSize)" b="1"><a:solidFill><a:schemeClr val="tx1"/></a:solidFill><a:latin typeface="+mj-lt"/><a:ea typeface="+mj-ea"/><a:cs typeface="+mj-cs"/></a:defRPr></a:lvl1pPr></p:titleStyle>\
            <p:bodyStyle>\(levels)</p:bodyStyle>\
            <p:otherStyle><a:defPPr><a:defRPr lang="en-US"/></a:defPPr></p:otherStyle></p:txStyles></p:sldMaster>
            """
    }

    private static func layoutXML() -> String {
        """
        <p:sldLayout \(ns) type="obj" preserve="1"><p:cSld name="Title and Content"><p:spTree>\
        <p:nvGrpSpPr><p:cNvPr id="1" name=""/><p:cNvGrpSpPr/><p:nvPr/></p:nvGrpSpPr>\
        <p:grpSpPr><a:xfrm><a:off x="0" y="0"/><a:ext cx="0" cy="0"/><a:chOff x="0" y="0"/><a:chExt cx="0" cy="0"/></a:xfrm></p:grpSpPr>\
        <p:sp><p:nvSpPr><p:cNvPr id="2" name="Title 1"/><p:cNvSpPr><a:spLocks noGrp="1"/></p:cNvSpPr><p:nvPr><p:ph type="title"/></p:nvPr></p:nvSpPr>\
        <p:spPr/><p:txBody><a:bodyPr/><a:lstStyle/><a:p><a:r><a:rPr lang="en-US"/><a:t>Title</a:t></a:r></a:p></p:txBody></p:sp>\
        <p:sp><p:nvSpPr><p:cNvPr id="3" name="Content Placeholder 2"/><p:cNvSpPr><a:spLocks noGrp="1"/></p:cNvSpPr><p:nvPr><p:ph idx="1"/></p:nvPr></p:nvSpPr>\
        <p:spPr/><p:txBody><a:bodyPr/><a:lstStyle/><a:p><a:pPr lvl="0"/><a:r><a:rPr lang="en-US"/><a:t>Text</a:t></a:r></a:p></p:txBody></p:sp>\
        </p:spTree></p:cSld><p:clrMapOvr><a:masterClrMapping/></p:clrMapOvr></p:sldLayout>
        """
    }

    private static func themeXML() -> String {
        func color(_ name: String, _ value: String) -> String { "<a:\(name)><a:srgbClr val=\"\(value)\"/></a:\(name)>" }
        let colors = [color("dk1", "000000"), color("lt1", "FFFFFF"), color("dk2", "44546A"), color("lt2", "E7E6E6"),
                      color("accent1", "4472C4"), color("accent2", "ED7D31"), color("accent3", "A5A5A5"), color("accent4", "FFC000"),
                      color("accent5", "5B9BD5"), color("accent6", "70AD47"), color("hlink", "0563C1"), color("folHlink", "954F72")].joined()
        let line = #"<a:ln w="9525" cap="flat" cmpd="sng" algn="ctr"><a:solidFill><a:schemeClr val="phClr"/></a:solidFill><a:prstDash val="solid"/><a:miter lim="800000"/></a:ln>"#
        let fill = #"<a:solidFill><a:schemeClr val="phClr"/></a:solidFill>"#
        return """
            <a:theme xmlns:a="http://schemas.openxmlformats.org/drawingml/2006/main" name="Office Theme"><a:themeElements>\
            <a:clrScheme name="Office">\(colors)</a:clrScheme>\
            <a:fontScheme name="Office"><a:majorFont><a:latin typeface="Helvetica Neue"/><a:ea typeface=""/><a:cs typeface=""/></a:majorFont>\
            <a:minorFont><a:latin typeface="Helvetica Neue"/><a:ea typeface=""/><a:cs typeface=""/></a:minorFont></a:fontScheme>\
            <a:fmtScheme name="Office"><a:fillStyleLst>\(fill)\(fill)\(fill)</a:fillStyleLst>\
            <a:lnStyleLst>\(line)\(line)\(line)</a:lnStyleLst>\
            <a:effectStyleLst><a:effectStyle><a:effectLst/></a:effectStyle><a:effectStyle><a:effectLst/></a:effectStyle><a:effectStyle><a:effectLst/></a:effectStyle></a:effectStyleLst>\
            <a:bgFillStyleLst>\(fill)\(fill)\(fill)</a:bgFillStyleLst></a:fmtScheme></a:themeElements>\
            <a:objectDefaults/><a:extraClrSchemeLst/></a:theme>
            """
    }
}
