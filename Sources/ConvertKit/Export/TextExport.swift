import CoreGraphics
import Foundation
import PDFModelKit
import RenderKit
import SuperPDFCore

/// PDF → plain text, web page and EPUB book (features #54, #55): the text in reading order (columns read one after the
/// other, running headers and footers left out), and for HTML/EPUB the structure LayoutKit found — headings,
/// paragraphs, lists, tables, pictures. The EPUB has a chapter per top-level contents entry (else per main heading).
enum TextExport {
    // MARK: Text

    static func text(_ layout: LayoutDocument) -> String {
        layout.pages.map { page in
            page.readingOrder.compactMap { element -> String? in
                switch element {
                case .block(let id):
                    guard let block = page.blocks.first(where: { $0.id == id }) else { return nil }
                    return reflow(block.lines.map(\.text))
                case .table(let id):
                    guard let table = page.tables.first(where: { $0.id == id }) else { return nil }
                    return (0..<table.rowCount).map { row in
                        table.cells.filter { $0.row == row }.sorted { $0.column < $1.column }.map(\.text).joined(separator: "\t")
                    }.joined(separator: "\n")
                case .figure:
                    return nil
                }
            }.joined(separator: "\n\n")
        }.filter { !$0.isEmpty }.joined(separator: "\n\n") + "\n"
    }

    /// A block's lines as one paragraph: words hyphenated at a line end are joined again.
    static func reflow(_ lines: [String]) -> String {
        var out = ""
        for line in lines {
            let text = line.trimmingCharacters(in: .whitespaces)
            guard !text.isEmpty else { continue }
            if out.isEmpty { out = text; continue }
            if out.hasSuffix("-"), let last = out.dropLast().last, last.isLetter, let first = text.first, first.isLowercase {
                out.removeLast(); out += text
            } else {
                out += " " + text
            }
        }
        return out
    }

    // MARK: HTML

    /// Pictures in the web page and the book: 150 dpi JPEG cut out of the page.
    static let pictureDPI: Double = 150

    private static func jpeg(_ figure: LayoutFigure, page: LayoutPage, pictures: OfficePictures) -> Data? {
        let rect = OfficeGeometry.displayedRect(figure.bounds, in: page)
        guard rect.width >= 2, rect.height >= 2, let cut = pictures.crop(page: page.index, rect: rect) else { return nil }
        return try? OfficePictures.jpeg(cut)
    }

    static func html(_ layout: LayoutDocument, source: PDFSource, title: String) throws -> String {
        let pictures = try OfficePictures(source, dpi: pictureDPI)
        let body = layout.pages.map { page in
            bodyHTML(page, xhtml: false) { figure in
                jpeg(figure, page: page, pictures: pictures).map { "data:image/jpeg;base64," + $0.base64EncodedString() }
            }
        }.joined(separator: "\n")
        return HTMLPage.document(title: title, body: body, extraStyle: "body { max-width: 720px; margin: 24px auto; padding: 0 16px; font-size: 15px; }")
    }

    /// The page's elements in reading order as HTML (XHTML when `xhtml`: self-closed empty elements). `picture` gives a
    /// figure's `src`, nil leaves it out.
    static func bodyHTML(_ page: LayoutPage, xhtml: Bool, picture: (LayoutFigure) -> String?) -> String {
        var out = ""
        var openList: (tag: String, level: Int)?
        func closeList() { if let list = openList { out += "</\(list.tag)>\n"; openList = nil } }
        for element in page.readingOrder {
            switch element {
            case .block(let id):
                guard let block = page.blocks.first(where: { $0.id == id }) else { continue }
                switch block.kind {
                case .heading(let level):
                    closeList()
                    let n = min(max(level, 1), 6)
                    out += "<h\(n)>" + runs(block) + "</h\(n)>\n"
                case .listItem(_, let marker):
                    let tag = marker.rangeOfCharacter(from: .alphanumerics) != nil ? "ol" : "ul"
                    if openList?.tag != tag { closeList(); out += "<\(tag)>\n"; openList = (tag, 0) }
                    out += "<li>" + runs(block, dropping: marker) + "</li>\n"
                case .caption:
                    closeList()
                    out += "<p class=\"caption\"><small>" + runs(block) + "</small></p>\n"
                case .paragraph:
                    closeList()
                    out += "<p>" + runs(block) + "</p>\n"
                case .header, .footer, .pageNumber:
                    continue
                }
            case .table(let id):
                closeList()
                guard let table = page.tables.first(where: { $0.id == id }) else { continue }
                out += "<table>\n"
                for row in 0..<table.rowCount {
                    let tag = row == 0 && table.hasHeaderRow ? "th" : "td"
                    out += "<tr>" + table.cells.filter { $0.row == row }.sorted { $0.column < $1.column }.map { cell in
                        let spans = (cell.columnSpan > 1 ? " colspan=\"\(cell.columnSpan)\"" : "") + (cell.rowSpan > 1 ? " rowspan=\"\(cell.rowSpan)\"" : "")
                        return "<\(tag)\(spans)>" + XML.escape(cell.text) + "</\(tag)>"
                    }.joined() + "</tr>\n"
                }
                out += "</table>\n"
            case .figure(let id):
                closeList()
                guard let figure = page.figures.first(where: { $0.id == id }), let src = picture(figure) else { continue }
                out += "<p><img src=\"\(XML.escape(src))\" alt=\"\"" + (xhtml ? " />" : ">") + "</p>\n"
            }
        }
        closeList()
        return out
    }

    /// A block's words as HTML, bold and italic kept, lines reflowed (a hyphen at a line end joins the word).
    private static func runs(_ block: LayoutBlock, dropping marker: String? = nil) -> String {
        var out = ""
        var hyphenated = false
        for (number, line) in block.lines.enumerated() {
            var words = line.words
            if number == 0, let marker, words.first?.text == marker { words.removeFirst() }
            for (index, word) in words.enumerated() {
                var text = XML.escape(word.text)
                if index == 0, hyphenated, word.text.first?.isLowercase == true {
                    out.removeLast()
                } else if !out.isEmpty {
                    out += " "
                }
                if word.isBold { text = "<strong>\(text)</strong>" }
                if word.isItalic { text = "<em>\(text)</em>" }
                out += text
                hyphenated = index == words.count - 1 && word.text.count > 1 && word.text.hasSuffix("-") && !word.isBold && !word.isItalic
            }
        }
        return out
    }

    // MARK: EPUB

    static func epub(_ layout: LayoutDocument, source: PDFSource, title: String, to url: URL) throws {
        let pictures = try OfficePictures(source, dpi: pictureDPI)
        let chapters = try chapterRanges(layout, source: source)
        var zip = ZipWriter()
        zip.add("mimetype", "application/epub+zip", compress: false)
        zip.add("META-INF/container.xml", """
        <?xml version="1.0" encoding="UTF-8"?>
        <container version="1.0" xmlns="urn:oasis:names:tc:opendocument:xmlns:container">
          <rootfiles><rootfile full-path="OEBPS/content.opf" media-type="application/oebps-package+xml"/></rootfiles>
        </container>
        """)
        zip.add("OEBPS/style.css", "body { font-family: serif; line-height: 1.45; } table { border-collapse: collapse; } td, th { border: 1px solid #999; padding: 2px 5px; } img { max-width: 100%; } .caption { color: #555; }")
        var manifest: [String] = []
        var pictureCount = 0
        for (number, chapter) in chapters.enumerated() {
            var body = ""
            for page in layout.pages where chapter.pages.contains(page.index) {
                body += bodyHTML(page, xhtml: true) { figure in
                    guard let jpeg = jpeg(figure, page: page, pictures: pictures) else { return nil }
                    pictureCount += 1
                    let name = "images/picture-\(pictureCount).jpg"
                    zip.add("OEBPS/" + name, jpeg, compress: false)
                    manifest.append("<item id=\"picture-\(pictureCount)\" href=\"\(name)\" media-type=\"image/jpeg\"/>")
                    return name
                }
            }
            zip.add("OEBPS/chapter-\(number + 1).xhtml", """
            <?xml version="1.0" encoding="UTF-8"?>
            <!DOCTYPE html>
            <html xmlns="http://www.w3.org/1999/xhtml" xmlns:epub="http://www.idpf.org/2007/ops">
            <head><meta charset="utf-8"/><title>\(XML.escape(chapter.title))</title><link rel="stylesheet" href="style.css" type="text/css"/></head>
            <body>
            \(body.isEmpty ? "<p></p>" : body)
            </body></html>
            """)
        }
        let language = Locale.current.language.languageCode?.identifier ?? "en"
        let identifier = "urn:uuid:" + UUID().uuidString.lowercased()
        let modified = ISO8601DateFormatter().string(from: Date()).replacingOccurrences(of: #"\.\d+"#, with: "", options: .regularExpression)
        let items = chapters.indices.map { "<item id=\"chapter-\($0 + 1)\" href=\"chapter-\($0 + 1).xhtml\" media-type=\"application/xhtml+xml\"/>" }
        let spine = chapters.indices.map { "<itemref idref=\"chapter-\($0 + 1)\"/>" }
        zip.add("OEBPS/content.opf", """
        <?xml version="1.0" encoding="UTF-8"?>
        <package xmlns="http://www.idpf.org/2007/opf" version="3.0" unique-identifier="book-id">
          <metadata xmlns:dc="http://purl.org/dc/elements/1.1/">
            <dc:identifier id="book-id">\(identifier)</dc:identifier>
            <dc:title>\(XML.escape(title))</dc:title>
            <dc:language>\(language)</dc:language>
            <meta property="dcterms:modified">\(modified)</meta>
          </metadata>
          <manifest>
            <item id="nav" href="nav.xhtml" media-type="application/xhtml+xml" properties="nav"/>
            <item id="ncx" href="toc.ncx" media-type="application/x-dtbncx+xml"/>
            <item id="style" href="style.css" media-type="text/css"/>
            \((items + manifest).joined(separator: "\n    "))
          </manifest>
          <spine toc="ncx">
            \(spine.joined(separator: "\n    "))
          </spine>
        </package>
        """)
        let links = chapters.enumerated().map { "<li><a href=\"chapter-\($0.offset + 1).xhtml\">\(XML.escape($0.element.title))</a></li>" }
        zip.add("OEBPS/nav.xhtml", """
        <?xml version="1.0" encoding="UTF-8"?>
        <!DOCTYPE html>
        <html xmlns="http://www.w3.org/1999/xhtml" xmlns:epub="http://www.idpf.org/2007/ops">
        <head><meta charset="utf-8"/><title>\(XML.escape(title))</title></head>
        <body><nav epub:type="toc" id="toc"><ol>\(links.joined())</ol></nav></body></html>
        """)
        let points = chapters.enumerated().map { index, chapter in
            "<navPoint id=\"p\(index + 1)\" playOrder=\"\(index + 1)\"><navLabel><text>\(XML.escape(chapter.title))</text></navLabel><content src=\"chapter-\(index + 1).xhtml\"/></navPoint>"
        }
        zip.add("OEBPS/toc.ncx", """
        <?xml version="1.0" encoding="UTF-8"?>
        <ncx xmlns="http://www.daisy.org/z3986/2005/ncx/" version="2005-1">
          <head><meta name="dtb:uid" content="\(identifier)"/></head>
          <docTitle><text>\(XML.escape(title))</text></docTitle>
          <navMap>\(points.joined())</navMap>
        </ncx>
        """)
        try zip.finish().write(to: url, options: .atomic)
    }

    struct Chapter { var title: String; var pages: Set<Int> }

    /// Chapters: the file's top-level contents entries; else a chapter at each main heading; else one chapter.
    static func chapterRanges(_ layout: LayoutDocument, source: PDFSource) throws -> [Chapter] {
        let exported = layout.pages.map(\.index)
        guard let first = exported.first else { return [Chapter(title: "1", pages: [])] }
        let entries = ((try? PDFModel(source))?.outlines() ?? []).compactMap { item -> (String, Int)? in
            item.destination.map { (item.title, $0.page) }
        }.sorted { $0.1 < $1.1 }
        var starts: [(title: String, page: Int)] = entries.filter { exported.contains($0.1) }.map { ($0.0, $0.1) }
        if starts.isEmpty {
            for page in layout.pages {
                for element in page.readingOrder {
                    guard case .block(let id) = element, let block = page.blocks.first(where: { $0.id == id }),
                          case .heading(let level) = block.kind, level == 1 else { continue }
                    if starts.last?.page != page.index { starts.append((reflow(block.lines.map(\.text)), page.index)) }
                }
            }
        }
        if starts.first?.page != first { starts.insert((starts.isEmpty ? TextExportStrings.wholeDocument : TextExportStrings.beginning, first), at: 0) }
        return starts.enumerated().map { index, start in
            let end = index + 1 < starts.count ? starts[index + 1].page : Int.max
            return Chapter(title: start.title, pages: Set(exported.filter { $0 >= start.page && $0 < end }))
        }.filter { !$0.pages.isEmpty }
    }
}

enum TextExportStrings {
    /// The one chapter of an EPUB made from a file without contents or headings.
    static let wholeDocument = "Document"
    /// The pages before the first contents entry.
    static let beginning = "Beginning"
}
