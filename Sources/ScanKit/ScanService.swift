import AppKit
import Combine
import Foundation
import SuperPDFCore

/// `Services.scan` (features #101–#104): the device list (Image Capture scanners plus Continuity Camera), scans as
/// streams of pages, and the photo pipeline (find the sheet, straighten it, clean it up). Picture work runs off the
/// main actor; devices are driven on it.
@MainActor
final class ScanService: Scanning {
    /// The one Continuity Camera row: the system's menu picks the actual iPhone or iPad (features #101).
    static let continuitySource = ScanSource(id: "continuity-camera", kind: .continuityCamera, name: "iPhone or iPad")

    let scanners: ScannerBrowsing
    let continuity: ContinuityCamera
    private let subject = CurrentValueSubject<[ScanSource], Never>([])
    /// Where scanners write their sheets before they are read in.
    private let folder: () -> URL

    init(scanners: ScannerBrowsing? = nil, continuity: ContinuityCamera? = nil,
         folder: @escaping () -> URL = { SuperPDFPaths.ensure(SuperPDFPaths.work.appendingPathComponent("Scans-" + UUID().uuidString)) }) {
        self.scanners = scanners ?? ImageCaptureScanners()
        self.continuity = continuity ?? ContinuityCamera()
        self.folder = folder
        self.scanners.onChange = { [weak self] list in self?.publish(list) }
        publish(self.scanners.scanners)
    }

    var sources: [ScanSource] { subject.value }
    var sourceChanges: AnyPublisher<[ScanSource], Never> { subject.eraseToAnyPublisher() }

    func startBrowsing() { scanners.start() }
    func stopBrowsing() { scanners.stop() }

    private func publish(_ list: [ScannerInfo]) {
        subject.send([Self.continuitySource] + ScannerList.sources(list))
    }

    // MARK: Scanning

    func scan(from source: ScanSource, settings: ScanSettings) -> AsyncThrowingStream<ScannedPage, Error> {
        switch source.kind {
        case .continuityCamera: continuityPages()
        case .scanner: scannerPages(source, settings: settings)
        case .camera: AsyncThrowingStream { $0.finish(throwing: ScanFailure.noScanner) }
        }
    }

    private func scannerPages(_ source: ScanSource, settings: ScanSettings) -> AsyncThrowingStream<ScannedPage, Error> {
        let job = ScannerJob(resolution: settings.resolution, colorMode: settings.colorMode, duplex: settings.duplex,
                             paper: settings.paper.size, folder: folder())
        let files = scanners.scan(source.id, job: job)
        let resolution = Double(settings.resolution)
        return Self.mapped(files) { url in
            let data = try Data(contentsOf: url)
            try? FileManager.default.removeItem(at: url)
            return [try Self.page(fromPicture: data, resolution: resolution)]
        }
    }

    /// One delivery from the iPhone or iPad: "Scan Documents" pages as they are, a "Take Photo" picture through the
    /// photo pipeline (find the sheet, straighten it).
    private func continuityPages() -> AsyncThrowingStream<ScannedPage, Error> {
        Self.mapped(continuity.importNext()) { delivery in
            switch delivery {
            case .pdf(let data): return try ScanPDF.rasterize(data)
            case .picture(let data):
                if let document = try DocumentDetector.detect(in: data) { return [try DocumentDetector.straighten(data, to: document)] }
                return [try DocumentDetector.wholePhoto(data)]
            }
        }
    }

    /// Each element turned into pages off the main actor, in order.
    private static func mapped<T: Sendable>(_ upstream: AsyncThrowingStream<T, Error>,
                                            _ transform: @escaping @Sendable (T) throws -> [ScannedPage]) -> AsyncThrowingStream<ScannedPage, Error> {
        AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    for try await element in upstream {
                        let pages = try await Task.detached { try transform(element) }.value
                        pages.forEach { continuation.yield($0) }
                    }
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    /// A scanner's sheet as a page; the picture is kept as the device wrote it.
    nonisolated static func page(fromPicture data: Data, resolution: Double) throws -> ScannedPage {
        let image = try ScanImage.decode(data)
        return ScannedPage(image: data, pixelSize: image.extent.size, resolution: resolution)
    }

    // MARK: Photos and clean-up

    func detectDocument(in photo: Data) async throws -> DetectedDocument? {
        try await Task.detached { try DocumentDetector.detect(in: photo) }.value
    }

    func straighten(_ photo: Data, to document: DetectedDocument) async throws -> ScannedPage {
        try await Task.detached { try DocumentDetector.straighten(photo, to: document) }.value
    }

    func cleanUp(_ page: ScannedPage, options: CleanUpOptions) async throws -> ScannedPage {
        try await Task.detached { try ScanCleaner.clean(page, options: options) }.value
    }
}
