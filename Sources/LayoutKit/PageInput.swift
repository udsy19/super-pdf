import CoreGraphics
import Foundation
import SuperPDFCore

// What one page hands the analyser: positioned words (PDFKit or OCR) plus the page's drawing (ruling lines, images,
// vector clusters). Pure values, so the analysis runs off the main actor and fixtures can be built by hand.

/// A thin horizontal or vertical stroke or filled rectangle: a table ruling, an underline or a separator.
public struct Ruling: Hashable, Sendable {
    public var bounds: CGRect
    public var isHorizontal: Bool

    public init(bounds: CGRect, isHorizontal: Bool) { self.bounds = bounds; self.isHorizontal = isHorizontal }

    /// The ruling's fixed coordinate (y for horizontal, x for vertical).
    var position: CGFloat { isHorizontal ? bounds.midY : bounds.midX }
    /// The ruling's extent along its direction.
    var span: ClosedRange<CGFloat> { isHorizontal ? bounds.minX...bounds.maxX : bounds.minY...bounds.maxY }
}

/// The page's drawing, as `PageGraphicsScanner` reads it from the content stream.
public struct PageGraphics: Hashable, Sendable {
    public var rulings: [Ruling]
    /// Placed image XObjects (and inline images), page space.
    public var images: [CGRect]
    /// Bounding boxes of filled or stroked paths that are not rulings.
    public var vectors: [CGRect]

    public init(rulings: [Ruling] = [], images: [CGRect] = [], vectors: [CGRect] = []) {
        self.rulings = rulings; self.images = images; self.vectors = vectors
    }

    public static let empty = PageGraphics()
}

/// One page's input to `LayoutAnalyzer`.
public struct PageInput: Hashable, Sendable {
    public var index: Int
    /// Crop box size, unrotated.
    public var size: CGSize
    public var rotation: Int
    public var origin: TextOrigin
    public var words: [LayoutWord]
    public var graphics: PageGraphics

    public init(index: Int, size: CGSize, rotation: Int = 0, origin: TextOrigin = .embedded, words: [LayoutWord], graphics: PageGraphics = .empty) {
        self.index = index; self.size = size; self.rotation = rotation; self.origin = origin; self.words = words; self.graphics = graphics
    }
}
