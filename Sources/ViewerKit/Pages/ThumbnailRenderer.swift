import AppKit
import PDFKit

/// A request for one thumbnail; cancelling it (the cell scrolled away or was reused) skips the render if it has not
/// started.
public final class ThumbnailRequest: @unchecked Sendable {
    private let lock = NSLock()
    private var cancelled = false

    public var isCancelled: Bool { lock.withLock { cancelled } }
    public func cancel() { lock.withLock { cancelled = true } }
}

/// Page thumbnails for the sidebar, the organiser, search results and the welcome window's recents, rendered lazily and
/// off the main thread (performance budgets: 500-page documents open in under 150 ms and scroll at 120 Hz; idle memory
/// under 150 MB). PDFKit objects stay on the main actor (ARCHITECTURE "Rules"): the page's `CGPDFPage`, crop box and
/// rotation are read there, and Quartz draws the page on a background queue. Images are cached by page, rotation and
/// pixel width in a byte-bounded `NSCache`.
@MainActor
public final class ThumbnailRenderer {
    public static let shared = ThumbnailRenderer()

    /// About 160 sidebar thumbnails at 2×; NSCache evicts beyond this.
    public static let cacheBytes = 48 << 20

    private let cache = ImageCache()
    private let queue = DispatchQueue(label: "com.udsy.superpdf.thumbnails", qos: .userInitiated)
    /// A serial per PDFPage object, so a page that deallocates never lends its address to a stale image.
    private let serials = NSMapTable<PDFPage, NSNumber>.weakToStrongObjects()
    private var nextSerial = 0

    /// Renders done, and how many of them ran off the main thread (the self-test's lazy/off-main check).
    public private(set) var renders = 0
    public private(set) var offMainRenders = 0

    init() { cache.storage.totalCostLimit = Self.cacheBytes }

    /// The image if it is already rendered.
    public func cachedImage(for page: PDFPage, pixelWidth: Int) -> CGImage? {
        cache.storage.object(forKey: key(page, pixelWidth) as NSString)?.image
    }

    /// Renders `page` at `pixelWidth` (height follows the page's rotated aspect) and calls `completion` on the main
    /// actor; returns nil when the image was cached and `completion` already ran.
    @discardableResult
    public func image(for page: PDFPage, pixelWidth: Int, completion: @escaping @MainActor (CGImage) -> Void) -> ThumbnailRequest? {
        let key = key(page, pixelWidth)
        if let cached = cache.storage.object(forKey: key as NSString) {
            completion(cached.image)
            return nil
        }
        let request = ThumbnailRequest()
        guard let pageRef = page.pageRef else {
            // Pages made in memory (a new blank page) have no Quartz page; PDFKit draws those on the main actor.
            DispatchQueue.main.async { [weak self] in
                guard let self, !request.isCancelled, let image = Self.renderWithPDFKit(page, pixelWidth: pixelWidth) else { return }
                self.store(image, key: key, offMain: false)
                completion(image)
            }
            return request
        }
        let input = RenderInput(page: pageRef, box: page.bounds(for: .cropBox), rotation: page.rotation, pixelWidth: pixelWidth)
        let cache = cache
        queue.async { [weak self] in
            guard !request.isCancelled else { return }
            if let cached = cache.storage.object(forKey: key as NSString) {
                DispatchQueue.main.async { if !request.isCancelled { completion(cached.image) } }
                return
            }
            guard let image = Self.render(input) else { return }
            let offMain = !Thread.isMainThread
            DispatchQueue.main.async {
                self?.store(image, key: key, offMain: offMain)
                if !request.isCancelled { completion(image) }
            }
        }
        return request
    }

    public func removeAll() { cache.storage.removeAllObjects() }

    // MARK: Rendering

    private func key(_ page: PDFPage, _ pixelWidth: Int) -> String {
        let serial: Int
        if let known = serials.object(forKey: page) {
            serial = known.intValue
        } else {
            nextSerial += 1
            serial = nextSerial
            serials.setObject(NSNumber(value: serial), forKey: page)
        }
        return "\(serial)-\(page.rotation)-\(pixelWidth)"
    }

    private func store(_ image: CGImage, key: String, offMain: Bool) {
        renders += 1
        if offMain { offMainRenders += 1 }
        cache.storage.setObject(CGImageBox(image), forKey: key as NSString, cost: image.bytesPerRow * image.height)
    }

    private struct RenderInput: @unchecked Sendable {
        var page: CGPDFPage
        var box: CGRect
        var rotation: Int
        var pixelWidth: Int
    }

    /// The page's crop box turned by its rotation (clockwise, as /Rotate), scaled to `pixelWidth`, on white.
    private nonisolated static func render(_ input: RenderInput) -> CGImage? {
        let box = input.box
        guard box.width > 0, box.height > 0, input.pixelWidth > 0 else { return nil }
        let rotation = ((input.rotation % 360) + 360) % 360
        let turned = rotation == 90 || rotation == 270
        let size = turned ? CGSize(width: box.height, height: box.width) : box.size
        let scale = CGFloat(input.pixelWidth) / size.width
        let height = max(1, Int((size.height * scale).rounded()))
        guard let context = CGContext(data: nil, width: input.pixelWidth, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                                      space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                      bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue) else { return nil }
        context.setFillColor(CGColor(gray: 1, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: input.pixelWidth, height: height))
        context.interpolationQuality = .high
        context.scaleBy(x: scale, y: scale)
        context.concatenate(pageTransform(box: box, rotation: rotation))
        context.clip(to: box)
        context.drawPDFPage(input.page)
        return context.makeImage()
    }

    /// Maps page space to the turned page's space with its origin at the lower left.
    nonisolated static func pageTransform(box: CGRect, rotation: Int) -> CGAffineTransform {
        switch rotation {
        case 90: CGAffineTransform(a: 0, b: -1, c: 1, d: 0, tx: -box.minY, ty: box.maxX)
        case 180: CGAffineTransform(a: -1, b: 0, c: 0, d: -1, tx: box.maxX, ty: box.maxY)
        case 270: CGAffineTransform(a: 0, b: 1, c: -1, d: 0, tx: box.maxY, ty: -box.minX)
        default: CGAffineTransform(translationX: -box.minX, y: -box.minY)
        }
    }

    private static func renderWithPDFKit(_ page: PDFPage, pixelWidth: Int) -> CGImage? {
        let bounds = page.bounds(for: .cropBox)
        let turned = page.rotation % 180 != 0
        let aspect = turned ? bounds.width / max(bounds.height, 1) : bounds.height / max(bounds.width, 1)
        let image = page.thumbnail(of: NSSize(width: CGFloat(pixelWidth), height: CGFloat(pixelWidth) * aspect), for: .cropBox)
        return image.cgImage(forProposedRect: nil, context: nil, hints: nil)
    }
}

/// NSCache is thread-safe; this lets the render queue read it.
final class ImageCache: @unchecked Sendable {
    let storage = NSCache<NSString, CGImageBox>()
}

final class CGImageBox: @unchecked Sendable {
    let image: CGImage
    init(_ image: CGImage) { self.image = image }
}
