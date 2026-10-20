import Combine
import CoreGraphics
import Foundation

// Scanning (ScanKit: `Services.scan`; features #101–#104).

/// Where pages come from.
public enum ScanSourceKind: String, Codable, Sendable {
    /// Continuity Camera "Scan Documents" on a nearby iPhone or iPad.
    case continuityCamera
    /// An Image Capture scanner (flatbed or document feeder).
    case scanner
    /// The Mac's camera or a photo.
    case camera
}

public struct ScanSource: Hashable, Identifiable, Sendable {
    public var id: String
    public var kind: ScanSourceKind
    public var name: String
    /// Nil when ready; otherwise the status line the device list shows.
    public var status: String?

    public init(id: String, kind: ScanSourceKind, name: String, status: String? = nil) {
        self.id = id; self.kind = kind; self.name = name; self.status = status
    }
}

public struct ScanSettings: Codable, Hashable, Sendable {
    public var resolution: Int
    public var colorMode: ScanColorMode
    public var duplex: Bool
    public var paper: PaperSize
    /// Deskew, crop and whiten each page afterwards.
    public var cleanUp: Bool

    public init(resolution: Int = 300, colorMode: ScanColorMode = .color, duplex: Bool = false, paper: PaperSize = .a4, cleanUp: Bool = true) {
        self.resolution = resolution; self.colorMode = colorMode; self.duplex = duplex; self.paper = paper; self.cleanUp = cleanUp
    }
}

/// "Clean up a scan" steps (features #104).
public struct CleanUpOptions: Codable, Hashable, Sendable {
    public var deskew: Bool
    public var removeBorders: Bool
    public var despeckle: Bool
    public var whitenBackground: Bool
    public var autoRotate: Bool

    public init(deskew: Bool = true, removeBorders: Bool = true, despeckle: Bool = true, whitenBackground: Bool = true, autoRotate: Bool = true) {
        self.deskew = deskew; self.removeBorders = removeBorders; self.despeckle = despeckle; self.whitenBackground = whitenBackground
        self.autoRotate = autoRotate
    }
}

/// A scanned or photographed page, encoded (JPEG/PNG/HEIC) so it can cross actors.
public struct ScannedPage: Sendable {
    public var image: Data
    public var pixelSize: CGSize
    public var resolution: Double

    public init(image: Data, pixelSize: CGSize, resolution: Double) { self.image = image; self.pixelSize = pixelSize; self.resolution = resolution }
}

/// A document found in a photo: its corners in image coordinates (0…1, origin bottom-left, Vision's convention).
public struct DetectedDocument: Hashable, Sendable {
    public var topLeft: CGPoint
    public var topRight: CGPoint
    public var bottomRight: CGPoint
    public var bottomLeft: CGPoint
    public var confidence: Double

    public init(topLeft: CGPoint, topRight: CGPoint, bottomRight: CGPoint, bottomLeft: CGPoint, confidence: Double) {
        self.topLeft = topLeft; self.topRight = topRight; self.bottomRight = bottomRight; self.bottomLeft = bottomLeft
        self.confidence = confidence
    }
}

@MainActor
public protocol Scanning: AnyObject {
    /// Devices found while browsing.
    var sources: [ScanSource] { get }
    var sourceChanges: AnyPublisher<[ScanSource], Never> { get }
    func startBrowsing()
    func stopBrowsing()
    /// Pages as they arrive; the stream ends when the device is done ("Scan more" starts another).
    func scan(from source: ScanSource, settings: ScanSettings) -> AsyncThrowingStream<ScannedPage, Error>
    func detectDocument(in photo: Data) async throws -> DetectedDocument?
    /// Perspective-corrects a photo to the detected corners.
    func straighten(_ photo: Data, to document: DetectedDocument) async throws -> ScannedPage
    func cleanUp(_ page: ScannedPage, options: CleanUpOptions) async throws -> ScannedPage
}
