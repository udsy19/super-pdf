import CoreGraphics
import Foundation
import PDFModelKit
import RenderKit
import SuperPDFCore

// The byte-level page work of PagesKit (features §1.2), off the main actor on `PDFSource` bytes: writing page subsets
// (extract, split), combining files, split plans (size, contents entries, blank separators), page labels, resizing, and
// the ink measurements behind blank-page and white-margin detection. Nothing here touches PDFKit or `Services`.

enum PageEngine {
    // MARK: Writing pages

    /// The pages (0-based, in the order given) of `source` as a new PDF.
    static func pages(_ indices: [Int], of source: PDFSource) throws -> Data {
        let model = try PDFModel(source)
        return try pages(indices, of: model)
    }

    static func pages(_ indices: [Int], of model: PDFModel) throws -> Data {
        let out = PDFModel()
        try out.insertPages(from: model, pages: indices, at: 0)
        return try out.data()
    }

    /// One file per group, named by `name(k)` (1-based) in `folder`.
    static func write(_ groups: [[Int]], of source: PDFSource, to folder: URL, progress: ToolProgress = .ignored,
                      name: (Int) -> String) throws -> [URL] {
        let model = try PDFModel(source)
        return try groups.enumerated().map { k, group in
            try Task.checkCancellation()
            let url = folder.appendingPathComponent(name(k + 1))
            try pages(group, of: model).write(to: url)
            progress.report(completed: k + 1, of: groups.count, label: url.lastPathComponent)
            return url
        }
    }

    // MARK: Combine (features #18)

    struct CombineInput: Sendable {
        var source: PDFSource
        /// The contents entry's title ("Budget").
        var title: String
    }

    /// The inputs one after another; with `contents`, a top-level contents entry per input at its first page, the input's
    /// own entries nested under it.
    static func combine(_ inputs: [CombineInput], contents: Bool) throws -> (data: Data, pages: Int) {
        let out = PDFModel()
        var outline: [PDFOutlineItem] = []
        for input in inputs {
            let model = try PDFModel(input.source)
            let start = out.pageCount
            try out.insertPages(from: model, pages: Array(0..<model.pageCount), at: start)
            guard contents, model.pageCount > 0 else { continue }
            let children = model.outlines().map { shifted($0, by: start) }
            outline.append(PDFOutlineItem(title: input.title, destination: PDFDestination(page: start), children: children))
        }
        if contents { out.setOutlines(outline) }
        return (try out.data(), out.pageCount)
    }

    private static func shifted(_ item: PDFOutlineItem, by offset: Int) -> PDFOutlineItem {
        var item = item
        if var destination = item.destination { destination.page += offset; item.destination = destination }
        item.children = item.children.map { shifted($0, by: offset) }
        return item
    }

    // MARK: Split plans (features #23)

    /// Every `n` pages.
    static func groups(every n: Int, count: Int) -> [[Int]] {
        let n = max(n, 1)
        return stride(from: 0, to: count, by: n).map { Array($0..<min($0 + n, count)) }
    }

    /// A part starts at each start page (sorted, de-duplicated); pages before the first start form a part of their own.
    static func groups(startingAt starts: [Int], count: Int) -> [[Int]] {
        let cuts = Array(Set(starts.filter { $0 > 0 && $0 < count })).sorted()
        let bounds = [0] + cuts + [count]
        return zip(bounds, bounds.dropFirst()).compactMap { $0 < $1 ? Array($0..<$1) : nil }
    }

    /// Parts separated by blank pages; the blank pages themselves are dropped (scan batches, features #23).
    static func groups(separatedBy blanks: Set<Int>, count: Int) -> [[Int]] {
        var groups: [[Int]] = [], current: [Int] = []
        for index in 0..<count {
            if blanks.contains(index) {
                if !current.isEmpty { groups.append(current); current = [] }
            } else {
                current.append(index)
            }
        }
        if !current.isEmpty { groups.append(current) }
        return groups
    }

    /// Consecutive pages whose sizes add up to at most `limit` bytes (a page bigger than the limit is a part alone).
    static func groups(sizes: [Int], limit: Int) -> [[Int]] {
        var groups: [[Int]] = [], current: [Int] = [], total = 0
        for (index, size) in sizes.enumerated() {
            if !current.isEmpty, total + size > limit { groups.append(current); current = []; total = 0 }
            current.append(index); total += size
        }
        if !current.isEmpty { groups.append(current) }
        return groups
    }

    /// Each page's share of the file: the size of the page written alone, less what every one-page file carries.
    static func pageSizes(_ source: PDFSource) throws -> [Int] {
        let model = try PDFModel(source)
        let overhead = try PDFModel().data().count
        return try (0..<model.pageCount).map { max(try pages([$0], of: model).count - overhead, 1) }
    }

    /// The first pages of the top-level contents entries.
    static func contentsStarts(_ source: PDFSource) throws -> [Int] {
        try PDFModel(source).outlines().compactMap { $0.destination?.page }
    }

    // MARK: Ink (blank pages, white margins)

    /// Luminance below this (0–255) counts as ink.
    static let inkThreshold: UInt8 = 200
    /// A page is blank when less than this share of its area carries ink (scanner specks and the paper's grain stay under).
    static let blankShare = 0.0004

    /// A page drawn in grey (white paper), at most `side` pixels on its long side, and the points per pixel.
    struct GreyPage {
        var pixels: [UInt8]
        var width: Int
        var height: Int
        var pointsPerPixel: Double

        func luminance(x: Int, y: Int) -> UInt8 { pixels[y * width + x] }
    }

    static func grey(_ page: CGPDFPage, side: Int = 400) throws -> GreyPage {
        let size = PDFPages.displayedSize(page)
        let scale = Double(side) / max(size.width, size.height, 1)
        let width = max(Int((size.width * scale).rounded()), 1), height = max(Int((size.height * scale).rounded()), 1)
        var pixels = [UInt8](repeating: 255, count: width * height)
        try pixels.withUnsafeMutableBytes { buffer in
            guard let context = CGContext(data: buffer.baseAddress, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width,
                                          space: CGColorSpaceCreateDeviceGray(), bitmapInfo: CGImageAlphaInfo.none.rawValue) else {
                throw RenderError.cannotCreateContext
            }
            context.setFillColor(gray: 1, alpha: 1)
            context.fill(CGRect(x: 0, y: 0, width: width, height: height))
            PDFPages.draw(page, in: context, fitting: CGRect(x: 0, y: 0, width: width, height: height))
        }
        return GreyPage(pixels: pixels, width: width, height: height, pointsPerPixel: 1 / scale)
    }

    /// The share of the page (inside a 3% border, where scanners leave edges) that carries ink.
    static func inkShare(_ page: GreyPage) -> Double {
        let dx = page.width * 3 / 100, dy = page.height * 3 / 100
        var ink = 0, total = 0
        for y in dy..<max(page.height - dy, dy) {
            for x in dx..<max(page.width - dx, dx) {
                total += 1
                if page.luminance(x: x, y: y) < inkThreshold { ink += 1 }
            }
        }
        return total == 0 ? 0 : Double(ink) / Double(total)
    }

    /// The blank pages of a document (features #23 "blank-page separators").
    static func blankPages(_ source: PDFSource) throws -> Set<Int> {
        let document = try PDFPages.open(source)
        var blanks: Set<Int> = []
        for index in 0..<document.numberOfPages where try inkShare(grey(PDFPages.page(document, at: index))) < blankShare {
            blanks.insert(index)
        }
        return blanks
    }

    /// The white around the ink of a page as seen (top, left, bottom, right in points, rounded down so no ink is cut);
    /// nil for a blank page.
    static func whiteMargins(_ page: GreyPage) -> Insets? {
        var minX = page.width, minY = page.height, maxX = -1, maxY = -1
        for y in 0..<page.height {
            for x in 0..<page.width where page.luminance(x: x, y: y) < 245 {
                minX = min(minX, x); maxX = max(maxX, x); minY = min(minY, y); maxY = max(maxY, y)
            }
        }
        guard maxX >= 0 else { return nil }
        let p = page.pointsPerPixel
        // Row 0 of a bitmap context's buffer is the top of the page.
        return Insets(top: (Double(minY) * p).rounded(.down), left: (Double(minX) * p).rounded(.down),
                      bottom: (Double(page.height - 1 - maxY) * p).rounded(.down), right: (Double(page.width - 1 - maxX) * p).rounded(.down))
    }

    /// The white margins every one of `pages` shares (the smallest on each side), so cropping them cuts no ink anywhere.
    static func sharedWhiteMargins(_ source: PDFSource, pages: [Int]) throws -> Insets? {
        let document = try PDFPages.open(source)
        var shared: Insets?
        for index in pages {
            guard let margins = try whiteMargins(grey(PDFPages.page(document, at: index), side: 800)) else { continue }
            shared = shared.map { Insets(top: min($0.top, margins.top), left: min($0.left, margins.left),
                                         bottom: min($0.bottom, margins.bottom), right: min($0.right, margins.right)) } ?? margins
        }
        return shared
    }

    // MARK: Page labels (features #31)

    static func setPageLabels(_ ranges: [PDFPageLabelRange], in data: Data, password: String?) throws -> Data {
        let model = try PDFModel(data: data, password: password)
        model.setPageLabels(ranges)
        return try model.data()   // QPDF keeps an encrypted file's encryption
    }

    // MARK: Resize (features #29)

    /// Pages drawn onto `paper` (portrait size; turned to match each page's orientation as seen): scaled to fit, or, with
    /// `padOnly`, kept at their size with space added around (scaled down only when bigger than the paper). The other
    /// page boxes go, so the new paper is what shows; annotations move with the content.
    static func resize(_ source: PDFSource, pages indices: [Int], paper: CGSize, padOnly: Bool) throws -> Data {
        let model = try PDFModel(source)
        for index in indices {
            guard let page = model.page(at: index) else { continue }
            let crop = page.box(.crop)
            let quarter = page.rotation % 180 != 0
            // The paper as seen, in page space (a page turned a quarter is landscape in its own space when seen upright).
            let seenLandscape = quarter ? crop.height > crop.width : crop.width > crop.height
            var target = seenLandscape ? CGSize(width: max(paper.width, paper.height), height: min(paper.width, paper.height))
                                       : CGSize(width: min(paper.width, paper.height), height: max(paper.width, paper.height))
            if quarter { target = CGSize(width: target.height, height: target.width) }
            let transform = fitTransform(crop, into: target, padOnly: padOnly)
            page.addContent(Data(String(format: "q %.5f 0 0 %.5f %.4f %.4f cm\n", transform.a, transform.d, transform.tx, transform.ty).utf8), prepend: true)
            page.addContent(Data("\nQ\n".utf8))
            for box in [PDFBox.crop, .bleed, .trim, .art] { page.setBox(box, nil) }
            page.setBox(.media, CGRect(origin: .zero, size: target))
            for annotation in page.annotations {
                if let rect = annotation["Rect"]?.rect { annotation.set("Rect", .rect(rect.applying(transform).standardized)) }
            }
        }
        return try model.data()
    }

    /// Maps `box` centred into a sheet of `target` (origin 0,0): scaled to fit, or not enlarged when `padOnly`.
    static func fitTransform(_ box: CGRect, into target: CGSize, padOnly: Bool) -> CGAffineTransform {
        var scale = min(target.width / max(box.width, 1), target.height / max(box.height, 1))
        if padOnly { scale = min(scale, 1) }
        let tx = (target.width - box.width * scale) / 2 - box.minX * scale
        let ty = (target.height - box.height * scale) / 2 - box.minY * scale
        return CGAffineTransform(a: scale, b: 0, c: 0, d: scale, tx: tx, ty: ty)
    }
}

/// White or cropped space on each side of a page as seen (points).
struct Insets: Hashable, Sendable {
    var top: Double
    var left: Double
    var bottom: Double
    var right: Double

    static let zero = Insets(top: 0, left: 0, bottom: 0, right: 0)
    var isZero: Bool { self == .zero }
}

/// Crop box maths (features #28): margins taken off a page as people see it (after /Rotate) become a box in the page's
/// own space.
enum CropMath {
    /// The rect left after taking `insets` (as seen) off `box` (page space) on a page turned `rotation` degrees clockwise;
    /// nil when less than a point would be left either way.
    static func crop(_ box: CGRect, insets: Insets, rotation: Int) -> CGRect? {
        // Which page-space side each seen side is: (minX, minY, maxX, maxY) insets.
        let (minX, minY, maxX, maxY): (Double, Double, Double, Double)
        switch ((rotation % 360) + 360) % 360 {
        case 90: (minX, minY, maxX, maxY) = (insets.top, insets.left, insets.bottom, insets.right)
        case 180: (minX, minY, maxX, maxY) = (insets.right, insets.top, insets.left, insets.bottom)
        case 270: (minX, minY, maxX, maxY) = (insets.bottom, insets.right, insets.top, insets.left)
        default: (minX, minY, maxX, maxY) = (insets.left, insets.bottom, insets.right, insets.top)
        }
        let width = box.width - minX - maxX, height = box.height - minY - maxY
        guard width >= 1, height >= 1 else { return nil }
        return CGRect(x: box.minX + minX, y: box.minY + minY, width: width, height: height)
    }
}
