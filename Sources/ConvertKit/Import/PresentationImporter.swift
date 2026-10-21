import CoreGraphics
import Foundation
import ImageIO
import PDFModelKit
import SuperPDFCore

// PowerPoint → PDF, built in (features #37; features §3.2: "own OOXML reader for .pptx: text, images, basic shapes,
// backgrounds; no animations or SmartArt"). Each visible slide becomes one page at the slide's size, drawn with Quartz
// and Core Text so the text stays real text. Slides inherit from their layout and master (placeholders, text styles,
// backgrounds, decorations); colours come from the theme through the master's colour map. Charts, SmartArt and
// embedded objects are drawn from their fallback picture when the file has one.

enum PPTXImporter {
    static func convert(_ input: URL, to output: URL, options: ImportOptions) throws -> ImportReport {
        let deck = try SlideDeck(url: input)
        return try SlideRenderer(deck: deck).write(to: output)
    }
}

/// Copy of the PowerPoint importer (ux §1.1 tone).
enum SlideStrings {
    /// The contents entry of a slide without a title.
    static func untitled(_ number: Int) -> String { "Slide \(number)" }
    static let leftOut = "Some charts, diagrams or embedded objects couldn’t be drawn, so they were left out."
}

enum SlideError: Error, Equatable {
    case notAPresentation
    case damaged(String)
    case tooLarge
}

/// Bounds that keep a hostile file from running away with time or memory.
enum SlideLimits {
    static let slides = 2_000
    static let shapesPerSlide = 5_000
    static let groupDepth = 32
    static let textCharacters = 200_000
    static let tableCells = 10_000
    static let imagePixels = 4_096
    static let cachedPixels = 150_000_000
}

/// A package relationship (`_rels/*.rels`).
struct SlideRelationship {
    var type: String
    /// The part path inside the package, or the URL for external targets.
    var target: String
    var isExternal: Bool
}

/// One XML part with its relationships.
final class SlidePart {
    let path: String
    let root: XMLNode
    let relationships: [String: SlideRelationship]

    init(path: String, root: XMLNode, relationships: [String: SlideRelationship]) {
        self.path = path; self.root = root; self.relationships = relationships
    }

    /// The part a relationship id points at (internal targets only).
    func target(_ id: String?) -> String? {
        guard let id, let rel = relationships[id], !rel.isExternal else { return nil }
        return rel.target
    }

    /// The first internal relationship whose type ends with `suffix` ("/slideLayout").
    func target(ofType suffix: String) -> String? {
        relationships.values.filter { !$0.isExternal && $0.type.hasSuffix(suffix) }.map(\.target).sorted().first
    }
}

/// The package: parts parsed on demand and kept, pictures decoded once.
final class SlideDeck {
    let zip: ZipArchive
    /// The slide size in points.
    let size: CGSize
    /// Slide part paths in presentation order.
    let slidePaths: [String]
    let presentation: SlidePart
    let title: String?
    private var parts: [String: SlidePart] = [:]
    private var themes: [String: SlideTheme] = [:]
    private var images: [String: CGImage] = [:]
    private var missingImages: Set<String> = []
    private var cachedPixels = 0

    convenience init(url: URL) throws {
        let zip: ZipArchive
        do { zip = try ZipArchive(url: url) } catch { throw SlideError.notAPresentation }
        try self.init(zip: zip)
    }

    init(zip: ZipArchive) throws {
        self.zip = zip
        let root = (try? Self.relationships(in: zip, of: ""))?.values.first { $0.type.hasSuffix("/officeDocument") }?.target ?? "ppt/presentation.xml"
        guard let presentationRoot = try Self.xml(in: zip, root) else { throw SlideError.notAPresentation }
        guard presentationRoot.name == "presentation" else { throw SlideError.notAPresentation }
        let presentation = SlidePart(path: root, root: presentationRoot, relationships: (try? Self.relationships(in: zip, of: root)) ?? [:])
        self.presentation = presentation

        let sz = presentationRoot.child("sldSz")
        let cx = Double(sz?.attr("cx") ?? "") ?? 9_144_000, cy = Double(sz?.attr("cy") ?? "") ?? 6_858_000
        func side(_ emu: Double) -> CGFloat { CGFloat(min(max(emu.isFinite ? emu / slideEMU : 720, 72), 14_400)) }
        size = CGSize(width: side(cx), height: side(cy))

        let ids = presentationRoot.child("sldIdLst")?.children("sldId") ?? []
        guard ids.count <= SlideLimits.slides else { throw SlideError.tooLarge }
        slidePaths = ids.compactMap { presentation.target($0.attr("r:id")) }

        let core = try? Self.xml(in: zip, "docProps/core.xml")
        let titleText = core?.child("title")?.allText.trimmingCharacters(in: .whitespacesAndNewlines)
        title = titleText?.isEmpty == false ? titleText : nil
        parts[root] = presentation
    }

    /// A part by path, parsed once; nil when the package has no such part.
    func part(_ path: String?) throws -> SlidePart? {
        guard let path else { return nil }
        if let cached = parts[path] { return cached }
        guard let root = try Self.xml(in: zip, path) else { return nil }
        let part = SlidePart(path: path, root: root, relationships: (try? Self.relationships(in: zip, of: path)) ?? [:])
        parts[path] = part
        return part
    }

    func theme(for master: SlidePart?) -> SlideTheme {
        guard let path = master?.target(ofType: "/theme") else { return SlideTheme(nil) }
        if let cached = themes[path] { return cached }
        let theme = SlideTheme((try? part(path))?.root)
        themes[path] = theme
        return theme
    }

    /// The picture a relationship of `part` names, decoded and capped at `SlideLimits.imagePixels` a side; nil for
    /// missing media and formats ImageIO can't read (EMF, WMF).
    func image(_ part: SlidePart, _ id: String) -> CGImage? {
        guard let path = part.target(id), !missingImages.contains(path) else { return nil }
        if let cached = images[path] { return cached }
        guard let data = try? zip.data(path), let source = CGImageSourceCreateWithData(data as CFData, nil), CGImageSourceGetCount(source) > 0 else {
            missingImages.insert(path)
            return nil
        }
        let options: [CFString: Any] = [kCGImageSourceCreateThumbnailFromImageAlways: true, kCGImageSourceCreateThumbnailWithTransform: true,
                                        kCGImageSourceThumbnailMaxPixelSize: SlideLimits.imagePixels, kCGImageSourceShouldCacheImmediately: true]
        guard let image = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary) else {
            missingImages.insert(path)
            return nil
        }
        let pixels = image.width * image.height
        if cachedPixels + pixels <= SlideLimits.cachedPixels {
            images[path] = image
            cachedPixels += pixels
        }
        return image
    }

    // MARK: Package reading

    private static func xml(in zip: ZipArchive, _ path: String) throws -> XMLNode? {
        guard let data = try zip.data(path) else { return nil }
        do { return try XML.parse(data) } catch { throw SlideError.damaged(path) }
    }

    /// The relationships of `part` ("" for the package's own), targets resolved to part paths.
    static func relationships(in zip: ZipArchive, of part: String) throws -> [String: SlideRelationship] {
        let folder = (part as NSString).deletingLastPathComponent
        let relsPath = (folder.isEmpty ? "" : folder + "/") + "_rels/" + (part as NSString).lastPathComponent + ".rels"
        guard let root = try xml(in: zip, relsPath) else { return [:] }
        var result: [String: SlideRelationship] = [:]
        for rel in root.children("Relationship") {
            guard let id = rel.attr("Id"), let target = rel.attr("Target") else { continue }
            let external = rel.attr("TargetMode") == "External"
            result[id] = SlideRelationship(type: rel.attr("Type") ?? "", target: external ? target : resolve(target, from: folder), isExternal: external)
        }
        return result
    }

    /// A relative target ("../media/image1.png") against the part's folder ("ppt/slides") → "ppt/media/image1.png".
    static func resolve(_ target: String, from folder: String) -> String {
        let decoded = target.removingPercentEncoding ?? target
        var components = decoded.hasPrefix("/") ? [] : folder.split(separator: "/").map(String.init)
        for piece in decoded.split(separator: "/").map(String.init) {
            switch piece {
            case ".", "": continue
            case "..": if !components.isEmpty { components.removeLast() }
            default: components.append(piece)
            }
        }
        return components.joined(separator: "/")
    }
}

/// Draws the visible slides into a PDF.
final class SlideRenderer {
    let deck: SlideDeck
    private var leftOutSomething = false

    init(deck: SlideDeck) { self.deck = deck }

    func write(to output: URL) throws -> ImportReport {
        var slides: [(part: SlidePart, number: Int)] = []
        for (index, path) in deck.slidePaths.enumerated() {
            guard let part = try deck.part(path), part.root.name == "sld" else { continue }
            if let show = part.root.attr("show"), ["0", "false", "off"].contains(show) { continue }
            slides.append((part, index + 1))
        }
        guard !slides.isEmpty else { throw ComposeError.nothingToConvert }

        var box = CGRect(origin: .zero, size: deck.size)
        var info: [CFString: Any] = [kCGPDFContextCreator: Strings.appName]
        if let title = deck.title { info[kCGPDFContextTitle] = title }
        guard let context = CGContext(output as CFURL, mediaBox: &box, info as CFDictionary) else { throw ComposeError.cannotCreatePDF }
        var outline: [PDFOutlineItem] = []
        do {
            for (page, slide) in slides.enumerated() {
                context.beginPDFPage(nil)
                context.saveGState()
                context.translateBy(x: 0, y: deck.size.height)
                context.scaleBy(x: 1, y: -1)
                defer {
                    context.restoreGState()
                    context.endPDFPage()
                }
                let title = try SlideCanvas(deck: deck, slide: slide.part, number: slide.number, context: context).draw()
                leftOutSomething = leftOutSomething || title.leftOut
                outline.append(PDFOutlineItem(title: title.text ?? SlideStrings.untitled(page + 1), destination: PDFDestination(page: page)))
            }
        } catch {
            context.closePDF()
            try? FileManager.default.removeItem(at: output)
            throw error
        }
        context.closePDF()
        return ImportReport(notices: leftOutSomething ? [SlideStrings.leftOut] : [], outline: outline)
    }
}
