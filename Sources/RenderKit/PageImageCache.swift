import CoreGraphics
import Foundation
import SuperPDFCore

/// Page images for thumbnails, the workspace and view tiles: rendered off the main actor, at most a few at a time,
/// kept in a byte-limited cache keyed by document fingerprint, page and pixel size. The same request in flight twice
/// is rendered once; a cancelled caller stops waiting without stopping the render for others. Open `CGPDFDocument`s are
/// kept for the last few sources so a scroll through thumbnails does not reparse the file per page.
public actor PageImageCache {
    public static let shared = PageImageCache()

    private final class ImageBox { let image: CGImage; init(_ image: CGImage) { self.image = image } }
    private final class DocumentBox { let document: CGPDFDocument; init(_ document: CGPDFDocument) { self.document = document } }

    private let images = NSCache<NSString, ImageBox>()
    private let documents = NSCache<NSString, DocumentBox>()
    private var inFlight: [String: Task<CGImage, Error>] = [:]
    private let maxConcurrent: Int
    private var active = 0
    private var waiters: [CheckedContinuation<Void, Never>] = []

    /// `byteLimit` bounds the cached pixels (default: a sixteenth of physical memory, at most 256 MB).
    public init(byteLimit: Int = min(Int(ProcessInfo.processInfo.physicalMemory / 16), 256 << 20), maxConcurrent: Int = max(2, ProcessInfo.processInfo.activeProcessorCount / 2)) {
        images.totalCostLimit = byteLimit
        documents.countLimit = 4
        self.maxConcurrent = maxConcurrent
    }

    /// The page fitted in `maxPixelSize`, from the cache when present.
    public func image(_ source: PDFSource, page index: Int, maxPixelSize: CGSize, colorSpace: RenderColorSpace = .sRGB) async throws -> CGImage {
        let fingerprint = source.fingerprint()
        let key = "\(fingerprint)/\(index)/\(Int(maxPixelSize.width))x\(Int(maxPixelSize.height))/\(colorSpace.rawValue)"
        if let hit = images.object(forKey: key as NSString) { return hit.image }
        if let running = inFlight[key] { return try await running.value }
        let task = Task<CGImage, Error> { [self] in
            await acquire()
            defer { release() }
            let document = try await self.document(source, fingerprint: fingerprint)
            let image = try await Task.detached(priority: .userInitiated) {
                try Rasterizer.render(try PDFPages.page(document, at: index), fitting: maxPixelSize, colorSpace: colorSpace)
            }.value
            images.setObject(ImageBox(image), forKey: key as NSString, cost: image.bytesPerRow * image.height)
            return image
        }
        inFlight[key] = task
        defer { inFlight[key] = nil }
        return try await task.value
    }

    /// The page count of a source, through the kept document.
    public func pageCount(_ source: PDFSource) async throws -> Int {
        try await document(source, fingerprint: source.fingerprint()).numberOfPages
    }

    /// Drops everything cached for a source (after an edit).
    public func invalidate(_ source: PDFSource) {
        let fingerprint = source.fingerprint()
        documents.removeObject(forKey: fingerprint as NSString)
        // NSCache cannot enumerate; images keyed by the old fingerprint simply age out, since an edited source gets a
        // new fingerprint and never asks for them again.
    }

    public func removeAll() { images.removeAllObjects(); documents.removeAllObjects() }

    private func document(_ source: PDFSource, fingerprint: String) async throws -> CGPDFDocument {
        if let kept = documents.object(forKey: fingerprint as NSString) { return kept.document }
        let document = try await Task.detached(priority: .userInitiated) { try PDFPages.open(source) }.value
        documents.setObject(DocumentBox(document), forKey: fingerprint as NSString)
        return document
    }

    private func acquire() async {
        if active < maxConcurrent { active += 1; return }
        await withCheckedContinuation { waiters.append($0) }
        active += 1
    }

    private func release() {
        active -= 1
        if !waiters.isEmpty { waiters.removeFirst().resume() }
    }
}
