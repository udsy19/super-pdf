import AppKit
import CoreGraphics
import CoreText
import Foundation
import ImageIO
import PDFModelKit
import RenderKit
import SuperPDFCore

// What the Word, Excel and PowerPoint writers share (features #50–#52): OPC package parts (content types, relationships,
// document properties), units, page geometry as displayed, page pictures, and styled runs from LayoutKit words. Off
// the main actor; output is deterministic (no dates, stable ids).

/// One relationship of an OPC part.
struct OfficeRelationship {
    var id: String
    var type: String
    var target: String

    static let officeDocument = "http://schemas.openxmlformats.org/officeDocument/2006/relationships/officeDocument"
    static let coreProperties = "http://schemas.openxmlformats.org/package/2006/relationships/metadata/core-properties"
    static let extendedProperties = "http://schemas.openxmlformats.org/officeDocument/2006/relationships/extended-properties"
    static let image = "http://schemas.openxmlformats.org/officeDocument/2006/relationships/image"
    static let styles = "http://schemas.openxmlformats.org/officeDocument/2006/relationships/styles"
    static let settings = "http://schemas.openxmlformats.org/officeDocument/2006/relationships/settings"
    static let numbering = "http://schemas.openxmlformats.org/officeDocument/2006/relationships/numbering"
    static let worksheet = "http://schemas.openxmlformats.org/officeDocument/2006/relationships/worksheet"
    static let slide = "http://schemas.openxmlformats.org/officeDocument/2006/relationships/slide"
    static let slideLayout = "http://schemas.openxmlformats.org/officeDocument/2006/relationships/slideLayout"
    static let slideMaster = "http://schemas.openxmlformats.org/officeDocument/2006/relationships/slideMaster"
    static let theme = "http://schemas.openxmlformats.org/officeDocument/2006/relationships/theme"
    static let presProps = "http://schemas.openxmlformats.org/officeDocument/2006/relationships/presProps"
    static let viewProps = "http://schemas.openxmlformats.org/officeDocument/2006/relationships/viewProps"
    static let tableStyles = "http://schemas.openxmlformats.org/officeDocument/2006/relationships/tableStyles"
}

/// Building an OPC package (ECMA-376 Part 2) into a ZIP.
struct OfficePackage {
    static let xmlHeader = #"<?xml version="1.0" encoding="UTF-8" standalone="yes"?>"# + "\n"

    /// Parts in the order added: path, bytes, whether to deflate.
    private var parts: [(String, Data, Bool)] = []
    /// Part name ("/word/document.xml") → content type.
    private var overrides: [(String, String)] = []
    private var mediaTypes: Set<String> = []

    /// Adds an XML part with its content type (an override in [Content_Types].xml); `nil` for .rels parts.
    mutating func add(_ path: String, xml: String, contentType: String?) {
        parts.append((path, Data((Self.xmlHeader + xml).utf8), true))
        if let contentType { overrides.append(("/" + path, contentType)) }
    }

    /// Adds a picture ("word/media/image1.png"); its extension gets a default content type.
    mutating func add(_ path: String, media: Data) {
        parts.append((path, media, false))
        mediaTypes.insert((path as NSString).pathExtension.lowercased())
    }

    mutating func addRelationships(_ path: String, _ relationships: [OfficeRelationship]) {
        add(path, xml: Self.relationships(relationships), contentType: nil)
    }

    /// docProps/core.xml and app.xml plus the package relationships to them and to the main part.
    mutating func addProperties(title: String, mainPart: String) {
        add("docProps/core.xml", xml: """
            <cp:coreProperties xmlns:cp="http://schemas.openxmlformats.org/package/2006/metadata/core-properties" \
            xmlns:dc="http://purl.org/dc/elements/1.1/" xmlns:dcterms="http://purl.org/dc/terms/" \
            xmlns:xsi="http://www.w3.org/2001/XMLSchema-instance"><dc:title>\(XML.escape(title))</dc:title>\
            <dc:creator>\(XML.escape(Strings.appName))</dc:creator></cp:coreProperties>
            """, contentType: "application/vnd.openxmlformats-package.core-properties+xml")
        add("docProps/app.xml", xml: """
            <Properties xmlns="http://schemas.openxmlformats.org/officeDocument/2006/extended-properties" \
            xmlns:vt="http://schemas.openxmlformats.org/officeDocument/2006/docPropsVTypes"><Application>\(XML.escape(Strings.appName))</Application></Properties>
            """, contentType: "application/vnd.openxmlformats-officedocument.extended-properties+xml")
        addRelationships("_rels/.rels", [
            OfficeRelationship(id: "rId1", type: OfficeRelationship.officeDocument, target: mainPart),
            OfficeRelationship(id: "rId2", type: OfficeRelationship.coreProperties, target: "docProps/core.xml"),
            OfficeRelationship(id: "rId3", type: OfficeRelationship.extendedProperties, target: "docProps/app.xml"),
        ])
    }

    /// The finished ZIP, [Content_Types].xml first.
    func finish() -> Data {
        var defaults = [("rels", "application/vnd.openxmlformats-package.relationships+xml"), ("xml", "application/xml")]
        for ext in mediaTypes.sorted() {
            switch ext {
            case "png": defaults.append(("png", "image/png"))
            case "jpeg", "jpg": defaults.append((ext, "image/jpeg"))
            default: break
            }
        }
        var types = #"<Types xmlns="http://schemas.openxmlformats.org/package/2006/content-types">"#
        for (ext, type) in defaults { types += #"<Default Extension="\#(ext)" ContentType="\#(type)"/>"# }
        for (part, type) in overrides { types += #"<Override PartName="\#(XML.escape(part))" ContentType="\#(type)"/>"# }
        types += "</Types>"
        var zip = ZipWriter()
        zip.add("[Content_Types].xml", Self.xmlHeader + types)
        for (path, data, compress) in parts { zip.add(path, data, compress: compress) }
        return zip.finish()
    }

    static func relationships(_ relationships: [OfficeRelationship]) -> String {
        var xml = #"<Relationships xmlns="http://schemas.openxmlformats.org/package/2006/relationships">"#
        for r in relationships {
            xml += #"<Relationship Id="\#(r.id)" Type="\#(r.type)" Target="\#(XML.escape(r.target))"/>"#
        }
        return xml + "</Relationships>"
    }
}

/// Lengths in the units OOXML uses.
enum OfficeUnits {
    /// English Metric Units: 12,700 per point.
    static func emu(_ points: CGFloat) -> Int { Int((points * 12_700).rounded()) }
    /// Twentieths of a point (Word's page sizes, indents and table widths).
    static func twips(_ points: CGFloat) -> Int { Int((points * 20).rounded()) }
}

/// A page as LayoutKit saw it, in the displayed frame Office documents use: /Rotate applied, origin at the top left,
/// y down, points.
enum OfficeGeometry {
    static func displayedSize(_ page: LayoutPage) -> CGSize {
        page.rotation % 180 == 0 ? page.size : CGSize(width: page.size.height, height: page.size.width)
    }

    /// A page-space rectangle (origin bottom left, y up, before /Rotate) in the displayed, top-left frame.
    static func displayedRect(_ rect: CGRect, in page: LayoutPage) -> CGRect {
        let w = page.size.width, h = page.size.height
        func map(_ p: CGPoint) -> CGPoint {
            switch ((page.rotation % 360) + 360) % 360 {
            case 90: CGPoint(x: p.y, y: p.x)
            case 180: CGPoint(x: w - p.x, y: p.y)
            case 270: CGPoint(x: h - p.y, y: w - p.x)
            default: CGPoint(x: p.x, y: h - p.y)
            }
        }
        let corners = [CGPoint(x: rect.minX, y: rect.minY), CGPoint(x: rect.maxX, y: rect.minY),
                       CGPoint(x: rect.minX, y: rect.maxY), CGPoint(x: rect.maxX, y: rect.maxY)].map(map)
        let xs = corners.map(\.x), ys = corners.map(\.y)
        return CGRect(x: xs.min()!, y: ys.min()!, width: xs.max()! - xs.min()!, height: ys.max()! - ys.min()!)
    }

    /// Text of one table cell grid, from the cells' row/column spans: column widths and row heights in points, taken from
    /// the single-span cells' bounds (displayed frame).
    static func grid(_ table: LayoutTable, in page: LayoutPage) -> (columns: [CGFloat], rows: [CGFloat]) {
        let bounds = displayedRect(table.bounds, in: page)
        func edges(count: Int, start: CGFloat, end: CGFloat, key: (LayoutTableCell) -> (index: Int, span: Int, min: CGFloat)) -> [CGFloat] {
            var starts = [CGFloat?](repeating: nil, count: count)
            for cell in table.cells {
                let k = key(cell)
                guard k.index < count else { continue }
                starts[k.index] = min(starts[k.index] ?? .greatestFiniteMagnitude, k.min)
            }
            starts[0] = start
            // Fill gaps evenly between known starts.
            var filled: [CGFloat] = []
            for i in 0..<count {
                if let s = starts[i] { filled.append(max(s, filled.last ?? s)); continue }
                let next = (i + 1..<count).first { starts[$0] != nil }
                let previous = filled.last ?? start
                let target = next.flatMap { starts[$0] } ?? end
                let steps = CGFloat((next ?? count) - i + 1)
                filled.append(previous + (target - previous) / steps)
            }
            var sizes: [CGFloat] = []
            for i in 0..<count { sizes.append(max((i + 1 < count ? filled[i + 1] : end) - filled[i], 6)) }
            return sizes
        }
        let columns = edges(count: max(table.columnCount, 1), start: bounds.minX, end: bounds.maxX) { cell in
            (cell.column, cell.columnSpan, displayedRect(cell.bounds, in: page).minX)
        }
        let rows = edges(count: max(table.rowCount, 1), start: bounds.minY, end: bounds.maxY) { cell in
            (cell.row, cell.rowSpan, displayedRect(cell.bounds, in: page).minY)
        }
        return (columns, rows)
    }

    /// The cell that covers each grid position (row, column), for writers that need every position filled.
    static func owners(_ table: LayoutTable) -> [[LayoutTableCell?]] {
        var grid = [[LayoutTableCell?]](repeating: [LayoutTableCell?](repeating: nil, count: max(table.columnCount, 1)),
                                         count: max(table.rowCount, 1))
        for cell in table.cells {
            for r in cell.row..<min(cell.row + max(cell.rowSpan, 1), grid.count) {
                for c in cell.column..<min(cell.column + max(cell.columnSpan, 1), grid[r].count) where grid[r][c] == nil {
                    grid[r][c] = cell
                }
            }
        }
        return grid
    }
}

/// A run of words with the same style.
struct OfficeRun: Equatable {
    var text: String
    var font: String?
    var size: Double
    var bold: Bool
    var italic: Bool
    /// "RRGGBB", nil for black or unknown.
    var color: String?
}

enum OfficeText {
    /// The block's lines as styled runs: one array per line, words joined by spaces, a run per change of style.
    static func lines(_ block: LayoutBlock) -> [[OfficeRun]] {
        block.lines.map { runs($0.words) }
    }

    /// The block as one flowing paragraph: lines joined by a space (or nothing after a hyphen).
    static func paragraph(_ block: LayoutBlock) -> [OfficeRun] {
        var result: [OfficeRun] = []
        for (index, line) in block.lines.enumerated() {
            var lineRuns = runs(line.words)
            guard !lineRuns.isEmpty else { continue }
            if index > 0, let last = result.last {
                if !last.text.hasSuffix("-") { lineRuns[0].text = " " + lineRuns[0].text }
            }
            for run in lineRuns { append(run, to: &result) }
        }
        return result
    }

    static func runs(_ words: [LayoutWord]) -> [OfficeRun] {
        var result: [OfficeRun] = []
        for (index, word) in words.enumerated() {
            var run = OfficeRun(text: (index > 0 ? " " : "") + word.text, font: fontFamily(word.fontName),
                                size: word.fontSize > 0 ? word.fontSize : 12, bold: word.isBold, italic: word.isItalic, color: color(word.color))
            if index > 0, var last = result.last, last.sameStyle(as: run) {
                last.text += run.text
                result[result.count - 1] = last
            } else {
                if index > 0 && result.isEmpty { run.text.removeFirst() }
                result.append(run)
            }
        }
        return result
    }

    private static func append(_ run: OfficeRun, to runs: inout [OfficeRun]) {
        if var last = runs.last, last.sameStyle(as: run) {
            last.text += run.text
            runs[runs.count - 1] = last
        } else {
            runs.append(run)
        }
    }

    /// "#1A2B3C" → "1A2B3C"; nil for black and for anything unreadable.
    static func color(_ hex: String?) -> String? {
        guard var hex = hex?.uppercased() else { return nil }
        if hex.hasPrefix("#") { hex.removeFirst() }
        if hex.count == 8 { hex = String(hex.prefix(6)) }
        guard hex.count == 6, hex.allSatisfy(\.isHexDigit), hex != "000000" else { return nil }
        return hex
    }

    private static let familyCache = OfficeFamilyCache()

    /// A PDF font name as the family name Office apps know: the subset tag and style suffixes dropped, the PostScript
    /// name resolved through Core Text when the font is on this Mac ("ABCDEF+TimesNewRomanPS-BoldMT" → "Times New Roman").
    static func fontFamily(_ fontName: String?) -> String? {
        // The system's own UI font (".SFNS…") isn't a family Office apps know: leave the run in the document's font.
        guard var name = fontName, !name.isEmpty, !name.hasPrefix(".") else { return nil }
        if let plus = name.firstIndex(of: "+"), name.distance(from: name.startIndex, to: plus) == 6 {
            name = String(name[name.index(after: plus)...])
        }
        if let cached = familyCache.get(name) { return cached }
        var family: String?
        let font = CTFontCreateWithName(name as CFString, 12, nil)
        if (CTFontCopyPostScriptName(font) as String).caseInsensitiveCompare(name) == .orderedSame {
            family = CTFontCopyFamilyName(font) as String
        }
        if family == nil {
            var base = name.split(whereSeparator: { $0 == "-" || $0 == "," }).first.map(String.init) ?? name
            for suffix in ["PSMT", "MT", "PS"] where base.hasSuffix(suffix) && base.count > suffix.count + 2 {
                base.removeLast(suffix.count)
                break
            }
            // "TimesNewRoman" → "Times New Roman"
            var spaced = ""
            for (i, ch) in base.enumerated() {
                if i > 0, ch.isUppercase, let prev = spaced.last, prev.isLowercase { spaced.append(" ") }
                spaced.append(ch)
            }
            family = spaced
        }
        familyCache.set(name, family)
        return family
    }
}

extension OfficeRun {
    func sameStyle(as other: OfficeRun) -> Bool {
        font == other.font && abs(size - other.size) < 0.25 && bold == other.bold && italic == other.italic && color == other.color
    }
}

private final class OfficeFamilyCache: @unchecked Sendable {
    private let lock = NSLock()
    private var values: [String: String?] = [:]
    func get(_ key: String) -> String?? { lock.withLock { values[key] } }
    func set(_ key: String, _ value: String?) { lock.withLock { values[key] = value } }
}

/// Page pictures for the writers (Word, PowerPoint, web page, EPUB): whole pages, regions of them, and pages without
/// their text. Pages are rendered when asked, one at a time, and only the last one is kept (the writers go page by
/// page), so a long document never holds every page picture in memory.
final class OfficePictures {
    let dpi: Double
    private let document: CGPDFDocument
    private var last: (index: Int, image: CGImage)?

    init(_ source: PDFSource, dpi: Double) throws {
        self.dpi = dpi
        document = try PDFPages.open(source)
    }

    /// The pages (0-based) without their text objects (BT … ET in the page content and in its form XObjects one level
    /// deep), for picture backgrounds that editable text sits on; other pages as they are.
    static func withoutText(_ source: PDFSource, pages: [Int], dpi: Double) throws -> OfficePictures {
        let model = try PDFModel(source)
        var done: Set<Int> = []
        for index in Set(pages) {
            guard let page = model.page(at: index) else { continue }
            var stream = try page.contentStream()
            if removeText(&stream) { page.setContentStream(stream) }
            guard let xobjects = page.resources?["XObject"] else { continue }
            for key in xobjects.keys {
                guard let form = xobjects[key], form.type == .stream, form["Subtype"]?.name == "Form" else { continue }
                if let id = form.objectID { guard done.insert(id).inserted else { continue } }
                guard form.canDecode(to: .all), let data = try? form.streamData(decode: .all) else { continue }
                var formStream = PDFContentStream(parsing: data)
                if removeText(&formStream) { form.setStreamData(formStream.serialized()) }
            }
        }
        return try OfficePictures(.data(try model.data(), password: source.password), dpi: dpi)
    }

    /// Page `index` (0-based) as displayed, at `dpi`.
    func page(_ index: Int) -> CGImage? {
        if let last, last.index == index { return last.image }
        guard let page = try? PDFPages.page(document, at: index), let image = try? Rasterizer.render(page, dpi: dpi) else { return nil }
        last = (index, image)
        return image
    }

    /// A region of page `index` (displayed frame: points from the top left).
    func crop(page index: Int, rect: CGRect) -> CGImage? {
        guard let image = page(index) else { return nil }
        let scale = dpi / 72
        let pixels = CGRect(x: rect.minX * scale, y: rect.minY * scale, width: rect.width * scale, height: rect.height * scale).integral
            .intersection(CGRect(x: 0, y: 0, width: image.width, height: image.height))
        guard pixels.width >= 1, pixels.height >= 1 else { return nil }
        return image.cropping(to: pixels)
    }

    /// Drops text objects; true when anything changed.
    static func removeText(_ stream: inout PDFContentStream) -> Bool {
        var kept: [PDFContentOperation] = []
        var inText = false
        var changed = false
        for op in stream.operations {
            if op.operator == "BT" { inText = true; changed = true; continue }
            if op.operator == "ET" { inText = false; continue }
            if !inText { kept.append(op) }
        }
        if changed { stream.operations = kept }
        return changed
    }

    static func png(_ image: CGImage) throws -> Data { try ImageEncoder.encode(image, format: .png, dpi: 72) }
    static func jpeg(_ image: CGImage, quality: Double = 0.85) throws -> Data { try ImageEncoder.encode(image, format: .jpeg, quality: quality, dpi: 72) }
}
