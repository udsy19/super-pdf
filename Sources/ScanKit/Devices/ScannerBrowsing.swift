import Foundation
import SuperPDFCore

/// A scanner as the device browser reports it, before it becomes a `ScanSource` row.
struct ScannerInfo: Hashable, Sendable {
    enum State: Hashable, Sendable {
        case ready
        /// Opening a session (the device list says it is getting ready).
        case connecting
        /// Another app holds the scanner.
        case busy
    }

    var id: String
    var name: String
    var state: State
}

/// What a scan asks of the device (features #102), in the device's own terms.
struct ScannerJob: Hashable, Sendable {
    var resolution: Int
    var colorMode: ScanColorMode
    var duplex: Bool
    /// Points; nil scans the device's whole area.
    var paper: CGSize?
    var folder: URL
}

/// The scanners on this Mac and the network (Image Capture in the app, a fake in the self-test). Calls arrive on the
/// main actor; `onChange` is called there too.
@MainActor
protocol ScannerBrowsing: AnyObject {
    var scanners: [ScannerInfo] { get }
    var onChange: (@MainActor ([ScannerInfo]) -> Void)? { get set }
    func start()
    func stop()
    /// Sheet by sheet, one picture file each, until the device is done.
    func scan(_ scannerID: String, job: ScannerJob) -> AsyncThrowingStream<URL, Error>
}

/// Device list rows (ux §5.3 Scan step 1): ready scanners first, then by name; the status line says why one can't
/// scan yet.
enum ScannerList {
    static func sources(_ scanners: [ScannerInfo]) -> [ScanSource] {
        scanners.sorted {
            ($0.state == .ready ? 0 : 1, $0.name.localizedLowercase) < ($1.state == .ready ? 0 : 1, $1.name.localizedLowercase)
        }.map { ScanSource(id: $0.id, kind: .scanner, name: $0.name, status: status($0)) }
    }

    static func status(_ scanner: ScannerInfo) -> String? {
        switch scanner.state {
        case .ready: nil
        case .connecting: ScanStrings.connecting
        case .busy: ScanStrings.busy
        }
    }
}
