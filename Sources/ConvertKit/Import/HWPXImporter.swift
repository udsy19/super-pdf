import AppKit
import SuperPDFCore

/// Hangul .hwpx → PDF (features #45) when LibreOffice isn't installed: our own basic reader of the OWPML package
/// (paragraphs with their character and paragraph properties, tables, pictures), laid out with TextKit.
enum HWPXImporter {
    static func convert(_ input: URL, to output: URL, options: ImportOptions) throws -> ImportReport {
        let archive = try ZipArchive(url: input)
        let package = try Package(archive)
        let text = NSMutableAttributedString()
        for section in package.sections {
            guard let data = try archive.data(section) else { continue }
            let root = try XML.parse(data, keepWhitespace: true)
            for paragraph in root.children("p") { package.append(paragraph, to: text) }
        }
        guard text.length > 0 else { throw ComposeError.nothingToConvert }
        try TextPaginator.write(text, to: output, paper: options.textPaper, margins: CGFloat(options.margins), title: String.baseName(input))
        return ImportReport()
    }

    /// The package: sections in reading order, character and paragraph properties, pictures.
    struct Package {
        var sections: [String] = []
        var characters: [String: (size: CGFloat, bold: Bool, italic: Bool, underline: Bool, color: NSColor)] = [:]
        var alignments: [String: NSTextAlignment] = [:]
        var pictures: [String: Data] = [:]

        init(_ archive: ZipArchive) throws {
            var manifest: [String: String] = [:]
            if let hpf = try archive.data("Contents/content.hpf") {
                let opf = try XML.parse(hpf)
                for item in opf.all("item") {
                    if let id = item.attr("id"), let href = item.attr("href") { manifest[id] = href }
                }
                sections = opf.all("itemref").compactMap { $0.attr("idref").flatMap { manifest[$0] } }
            }
            if sections.isEmpty {
                sections = archive.entries.map(\.path).filter { $0.hasPrefix("Contents/section") && $0.hasSuffix(".xml") }
                    .sorted { $0.localizedStandardCompare($1) == .orderedAscending }
            }
            guard !sections.isEmpty else { throw ConvertError.unsupported("not a Hangul file") }
            if let header = try archive.data("Contents/header.xml"), let root = try? XML.parse(header) {
                for property in root.all("charPr") {
                    guard let id = property.attr("id") else { continue }
                    let size = CGFloat(Double(property.attr("height") ?? "1000") ?? 1000) / 100
                    let color = property.attr("textColor").flatMap { $0.hasPrefix("#") ? NSColor(hex: $0) : nil } ?? .black
                    characters[id] = (max(size, 4), property.child("bold") != nil, property.child("italic") != nil,
                                      property.child("underline").map { $0.attr("type") != "NONE" } ?? false, color)
                }
                for property in root.all("paraPr") {
                    guard let id = property.attr("id") else { continue }
                    alignments[id] = switch property.first("align")?.attr("horizontal")?.uppercased() {
                    case "CENTER": .center
                    case "RIGHT": .right
                    case "JUSTIFY", "DISTRIBUTE": .justified
                    default: .natural
                    }
                }
            }
            for (id, href) in manifest where href.lowercased().hasPrefix("bindata/") {
                pictures[id] = try archive.data(href)
            }
        }

        func attributes(_ characterID: String?, alignment: NSTextAlignment) -> [NSAttributedString.Key: Any] {
            let properties = characterID.flatMap { characters[$0] }
            var font = NSFont.systemFont(ofSize: properties?.size ?? 10)
            var traits: NSFontDescriptor.SymbolicTraits = []
            if properties?.bold == true { traits.insert(.bold) }
            if properties?.italic == true { traits.insert(.italic) }
            if !traits.isEmpty { font = NSFont(descriptor: font.fontDescriptor.withSymbolicTraits(traits), size: font.pointSize) ?? font }
            let style = NSMutableParagraphStyle()
            style.alignment = alignment
            style.paragraphSpacing = 3
            style.lineHeightMultiple = 1.15
            var attributes: [NSAttributedString.Key: Any] = [.font: font, .foregroundColor: properties?.color ?? NSColor.black, .paragraphStyle: style]
            if properties?.underline == true { attributes[.underlineStyle] = NSUnderlineStyle.single.rawValue }
            return attributes
        }

        /// One `hp:p`: its runs' text, tables and pictures, ending with a paragraph break.
        func append(_ paragraph: XMLNode, to text: NSMutableAttributedString, inCell cell: NSTextTableBlock? = nil) {
            let alignment = paragraph.attr("paraPrIDRef").flatMap { alignments[$0] } ?? .natural
            var paragraphAttributes = attributes(paragraph.attr("charPrIDRef"), alignment: alignment)
            if let cell, let style = (paragraphAttributes[.paragraphStyle] as? NSParagraphStyle)?.mutableCopy() as? NSMutableParagraphStyle {
                style.textBlocks = [cell]
                paragraphAttributes[.paragraphStyle] = style
            }
            for run in paragraph.children("run") {
                var runAttributes = attributes(run.attr("charPrIDRef") ?? paragraph.attr("charPrIDRef"), alignment: alignment)
                runAttributes[.paragraphStyle] = paragraphAttributes[.paragraphStyle]
                for child in run.children {
                    switch child.name {
                    case "t":
                        for content in child.content {
                            switch content {
                            case .text(let string): text.append(NSAttributedString(string: string, attributes: runAttributes))
                            case .element(let node) where node.name == "tab": text.append(NSAttributedString(string: "\t", attributes: runAttributes))
                            case .element(let node) where node.name == "lineBreak": text.append(NSAttributedString(string: "\u{2028}", attributes: runAttributes))
                            default: break
                            }
                        }
                    case "tbl":
                        appendTable(child, to: text)
                    case "pic":
                        if let id = child.first("img")?.attr("binaryItemIDRef"), let data = pictures[id], let image = NSImage(data: data) {
                            let attachment = NSTextAttachment()
                            attachment.image = image
                            attachment.bounds = CGRect(origin: .zero, size: image.size)
                            let picture = NSMutableAttributedString(attachment: attachment)
                            picture.addAttributes([.paragraphStyle: paragraphAttributes[.paragraphStyle]!], range: NSRange(location: 0, length: picture.length))
                            text.append(picture)
                        }
                    default:
                        break
                    }
                }
            }
            text.append(NSAttributedString(string: "\n", attributes: paragraphAttributes))
        }

        private func appendTable(_ table: XMLNode, to text: NSMutableAttributedString) {
            let rows = table.children("tr")
            let columns = max(rows.map { $0.children("tc").count }.max() ?? 1, 1)
            let textTable = NSTextTable()
            textTable.numberOfColumns = columns
            textTable.collapsesBorders = true
            for (r, row) in rows.enumerated() {
                for (c, cell) in row.children("tc").enumerated() {
                    let span = Int(cell.first("cellSpan")?.attr("colSpan") ?? "1") ?? 1
                    let rowSpan = Int(cell.first("cellSpan")?.attr("rowSpan") ?? "1") ?? 1
                    let block = NSTextTableBlock(table: textTable, startingRow: r, rowSpan: max(rowSpan, 1), startingColumn: c, columnSpan: max(span, 1))
                    block.setWidth(0.5, type: .absoluteValueType, for: .border)
                    block.setBorderColor(.darkGray)
                    block.setWidth(3, type: .absoluteValueType, for: .padding)
                    let paragraphs = cell.all("p")
                    if paragraphs.isEmpty {
                        let style = NSMutableParagraphStyle()
                        style.textBlocks = [block]
                        text.append(NSAttributedString(string: "\n", attributes: [.paragraphStyle: style, .font: NSFont.systemFont(ofSize: 10)]))
                    }
                    for paragraph in paragraphs { append(paragraph, to: text, inCell: block) }
                }
            }
        }
    }
}
