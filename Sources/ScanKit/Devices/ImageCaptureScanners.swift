import Foundation
import ImageCaptureCore
import SuperPDFCore
import UniformTypeIdentifiers

/// Flatbed and sheet-fed scanners through Image Capture (features #102): an `ICDeviceBrowser` for local, shared and
/// network scanners, and one `ICScannerDevice` session per scan that writes each sheet as a picture file.
@MainActor
final class ImageCaptureScanners: NSObject, ScannerBrowsing {
    private(set) var scanners: [ScannerInfo] = []
    var onChange: (@MainActor ([ScannerInfo]) -> Void)?

    private var browser: ICDeviceBrowser?
    private var devices: [String: ICScannerDevice] = [:]
    private var runs: [String: ScannerRun] = [:]

    func start() {
        guard browser == nil else { return }
        let browser = ICDeviceBrowser()
        browser.delegate = self
        let mask = ICDeviceTypeMask.scanner.rawValue | ICDeviceLocationTypeMask.local.rawValue
            | ICDeviceLocationTypeMask.shared.rawValue | ICDeviceLocationTypeMask.bonjour.rawValue
        browser.browsedDeviceTypeMask = ICDeviceTypeMask(rawValue: mask) ?? .scanner
        browser.start()
        self.browser = browser
    }

    func stop() {
        guard runs.isEmpty else { return }
        browser?.stop()
        browser = nil
        devices = [:]
        scanners = []
    }

    func scan(_ scannerID: String, job: ScannerJob) -> AsyncThrowingStream<URL, Error> {
        AsyncThrowingStream { continuation in
            guard let device = devices[scannerID] else {
                continuation.finish(throwing: ScanFailure.noScanner)
                return
            }
            let run = ScannerRun(device: device, job: job, continuation: continuation) { [weak self] state in
                self?.update(scannerID, state: state)
            } finished: { [weak self] in
                self?.runs[scannerID] = nil
            }
            runs[scannerID] = run
            continuation.onTermination = { _ in Task { @MainActor in run.cancel() } }
            run.start()
        }
    }

    private func update(_ id: String, state: ScannerInfo.State) {
        guard let index = scanners.firstIndex(where: { $0.id == id }), scanners[index].state != state else { return }
        scanners[index].state = state
        onChange?(scanners)
    }

    fileprivate func added(_ device: ICDevice) {
        guard let scanner = device as? ICScannerDevice, let id = scanner.uuidString else { return }
        devices[id] = scanner
        scanners.removeAll { $0.id == id }
        scanners.append(ScannerInfo(id: id, name: scanner.name ?? ScanStrings.unnamedScanner, state: .ready))
        onChange?(scanners)
    }

    fileprivate func removed(_ device: ICDevice) {
        guard let id = device.uuidString else { return }
        devices[id] = nil
        scanners.removeAll { $0.id == id }
        onChange?(scanners)
    }
}

extension ImageCaptureScanners: ICDeviceBrowserDelegate {
    nonisolated func deviceBrowser(_ browser: ICDeviceBrowser, didAdd device: ICDevice, moreComing: Bool) {
        MainActor.assumeIsolated { added(device) }
    }

    nonisolated func deviceBrowser(_ browser: ICDeviceBrowser, didRemove device: ICDevice, moreGoing: Bool) {
        MainActor.assumeIsolated { removed(device) }
    }
}

/// One scan: open a session, pick the document feeder when it has paper (else the flatbed), set colour, resolution,
/// size and both sides, then collect the sheets until the device reports the scan complete.
@MainActor
private final class ScannerRun: NSObject {
    private let device: ICScannerDevice
    private let job: ScannerJob
    private let continuation: AsyncThrowingStream<URL, Error>.Continuation
    private let state: @MainActor (ScannerInfo.State) -> Void
    private let finished: @MainActor () -> Void
    private var reversed: [URL]?
    private var done = false
    private var triedFlatbed = false

    init(device: ICScannerDevice, job: ScannerJob, continuation: AsyncThrowingStream<URL, Error>.Continuation,
         state: @escaping @MainActor (ScannerInfo.State) -> Void, finished: @escaping @MainActor () -> Void) {
        self.device = device; self.job = job; self.continuation = continuation; self.state = state; self.finished = finished
    }

    func start() {
        device.delegate = self
        state(.connecting)
        if device.hasOpenSession { selectUnit() } else { device.requestOpenSession() }
    }

    func cancel() {
        guard !done else { return }
        device.cancelScan()
        end(nil)
    }

    private func selectUnit() {
        let units = device.availableFunctionalUnitTypes.map(\.uintValue)
        let feeder = ICScannerFunctionalUnitType.documentFeeder.rawValue
        let type: ICScannerFunctionalUnitType = units.contains(feeder) && !triedFlatbed ? .documentFeeder : .flatbed
        if device.selectedFunctionalUnit.type == type { configure(device.selectedFunctionalUnit) } else { device.requestSelect(type) }
    }

    private func configure(_ unit: ICScannerFunctionalUnit) {
        if let feeder = unit as? ICScannerFunctionalUnitDocumentFeeder {
            // An empty feeder falls back to the flatbed when there is one.
            if !feeder.documentLoaded, device.availableFunctionalUnitTypes.contains(where: { $0.uintValue == ICScannerFunctionalUnitType.flatbed.rawValue }) {
                triedFlatbed = true
                device.requestSelect(.flatbed)
                return
            }
            if feeder.supportsDuplexScanning { feeder.duplexScanningEnabled = job.duplex }
            feeder.documentType = Self.documentType(job.paper)
            if feeder.reverseFeederPageOrder { reversed = [] }
        } else {
            unit.measurementUnit = .inches
            let physical = unit.physicalSize
            if let paper = job.paper {
                unit.scanArea = CGRect(x: 0, y: 0, width: min(paper.width / 72, physical.width), height: min(paper.height / 72, physical.height))
            } else {
                unit.scanArea = CGRect(origin: .zero, size: physical)
            }
        }
        unit.resolution = Self.nearest(job.resolution, in: unit.supportedResolutions)
        switch job.colorMode {
        case .color: unit.pixelDataType = .RGB; unit.bitDepth = .depth8Bits
        case .grayscale: unit.pixelDataType = .gray; unit.bitDepth = .depth8Bits
        case .blackAndWhite: unit.pixelDataType = .BW; unit.bitDepth = .depth1Bit
        }
        device.transferMode = .fileBased
        device.downloadsDirectory = job.folder
        device.documentName = "Scan"
        device.documentUTI = (job.colorMode == .blackAndWhite ? UTType.png : UTType.jpeg).identifier
        state(.ready)
        device.requestScan()
    }

    static func nearest(_ resolution: Int, in supported: IndexSet) -> Int {
        supported.min { abs($0 - resolution) < abs($1 - resolution) } ?? resolution
    }

    static func documentType(_ paper: CGSize?) -> ICScannerDocumentType {
        guard let paper else { return .typeDefault }
        if abs(paper.height - 1008) < 2 { return .typeUSLegal }
        if abs(paper.width - 612) < 2 { return .typeUSLetter }
        return .typeA4
    }

    private func end(_ error: Error?) {
        guard !done else { return }
        done = true
        if let error { continuation.finish(throwing: error) } else {
            reversed?.reversed().forEach { continuation.yield($0) }
            continuation.finish()
        }
        if device.hasOpenSession { device.requestCloseSession() }
        state(.ready)
        finished()
    }
}

extension ScannerRun: ICScannerDeviceDelegate {
    nonisolated func device(_ device: ICDevice, didOpenSessionWithError error: Error?) {
        MainActor.assumeIsolated {
            if error != nil {
                state(.busy)
                done = true
                continuation.finish(throwing: ScanFailure.scannerBusy)
                finished()
            } else {
                selectUnit()
            }
        }
    }

    nonisolated func device(_ device: ICDevice, didCloseSessionWithError error: Error?) {}

    nonisolated func didRemove(_ device: ICDevice) {
        MainActor.assumeIsolated { end(ScanFailure.noScanner) }
    }

    nonisolated func scannerDevice(_ scanner: ICScannerDevice, didSelect functionalUnit: ICScannerFunctionalUnit, error: Error?) {
        MainActor.assumeIsolated {
            if let error { end(ScanFailure.failed(error.localizedDescription)) } else { configure(functionalUnit) }
        }
    }

    nonisolated func scannerDevice(_ scanner: ICScannerDevice, didScanTo url: URL) {
        MainActor.assumeIsolated {
            if reversed != nil { reversed?.append(url) } else { continuation.yield(url) }
        }
    }

    nonisolated func scannerDevice(_ scanner: ICScannerDevice, didCompleteScanWithError error: Error?) {
        MainActor.assumeIsolated { end(error.map { ScanFailure.failed($0.localizedDescription) }) }
    }
}
