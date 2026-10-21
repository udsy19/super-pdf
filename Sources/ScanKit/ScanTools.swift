import AppKit
import SuperPDFCore

/// The Scan tiles (ux §5.3 "Scan with iPhone / scanner / From a photo", archetype G): step 1 picks the device (or the
/// photos), step 2 scans (or straightens), step 3 shows the pages with "Clean up" on, "Scan another" and Done. Done adds
/// the pages at the end of the open PDF as one undoable step, or opens them as a new PDF; "Recognise text" in More
/// options runs FixKit's OCR (`Services.fix`) over them first.
@MainActor
final class ScanTools: ToolProviding {
    enum Key {
        static let device = "device", colour = "colour", resolution = "resolution", paper = "paper", duplex = "duplex"
        static let cleanUp = "cleanUp", recognise = "recognise", photos = "photos"
    }

    enum Action {
        static let scan = "scan", tryAgain = "tryAgain", scanAnother = "scanAnother"
    }

    let tools: [ToolID] = [.scanWithIPhone, .scanWithScanner, .fromPhoto]
    let service: ScanService
    /// How long step 1 waits for the first scanners before saying none were found.
    var browseWait: TimeInterval = 2

    private var sessions: [String: ScanSession] = [:]
    /// Each photo's straightened page and whether a sheet was found in it, by file.
    private var photoPages: [URL: (page: ScannedPage, found: Bool)] = [:]

    init(service: ScanService) { self.service = service }

    func session(_ tool: ToolID, _ document: DocumentHandle?) -> ScanSession {
        let key = tool.rawValue + "|" + (document?.id.uuidString ?? "-")
        if let session = sessions[key] { return session }
        let session = ScanSession()
        sessions[key] = session
        return session
    }

    // MARK: Panels

    func panel(for tool: ToolID, context: ToolContext) -> ToolPanel {
        let step = min(max(context.values.int(ToolPanel.stepValue), 0), 2)
        let session = session(tool, context.document)
        if step == 2 { return pagesStep(tool, session: session, context: context) }
        switch tool {
        case .scanWithIPhone: return step == 0 ? iPhoneDevice(session) : iPhoneScan(session)
        case .scanWithScanner: return step == 0 ? scannerDevice(session, context) : scannerScan(session, context)
        default: return step == 0 ? photoChoice(context) : photoStraighten(session, context)
        }
    }

    private func next(enabled: Bool = true) -> ToolButton { ToolButton(Strings.Panel.next, isEnabled: enabled) }

    /// Step 1 starts a scan afresh: going back to it drops pages gathered before.
    private func iPhoneDevice(_ session: ScanSession) -> ToolPanel {
        if !session.isWorking { session.reset() }
        return ToolPanel(.flow, steps: ScanStrings.deviceSteps, currentStep: 0, controls: [.note(ScanStrings.iPhoneNeeds)], primary: next())
    }

    private func iPhoneScan(_ session: ScanSession) -> ToolPanel {
        let camera = service.continuity
        let source = ScanService.continuitySource
        let service = self.service
        return ToolPanel(.flow, steps: ScanStrings.deviceSteps, currentStep: 1, controls: [
            .note(ScanStrings.iPhoneHint),
            .custom(id: "import") {
                ContinuityImportView(camera: camera) { [weak session] in
                    session?.start(service.scan(from: source, settings: ScanSettings()), working: ScanStrings.waitingForIPhone)
                }
            },
            .custom(id: "pages") { ScanPagesView(session: session) },
        ], primary: next())
    }

    private func scannerSources() -> [ScanSource] { service.sources.filter { $0.kind == .scanner } }

    private func scannerDevice(_ session: ScanSession, _ context: ToolContext) -> ToolPanel {
        if !session.isWorking { session.reset() }
        service.startBrowsing()
        let sources = scannerSources()
        guard !sources.isEmpty else {
            return ToolPanel(.flow, steps: ScanStrings.deviceSteps, currentStep: 0, controls: [.note(ScanStrings.lookingForScanners)],
                             primary: next(enabled: false), message: ScanFailure.noScanner.toolError.message)
        }
        let selected = sources.first { $0.id == context.values.string(Key.device) } ?? sources.first { $0.status == nil } ?? sources[0]
        let options = sources.map { ToolOption($0.id, $0.name, detail: $0.status, symbol: "scanner") }
        return ToolPanel(.flow, steps: ScanStrings.deviceSteps, currentStep: 0,
                         controls: [.radio(id: Key.device, options: options, selected: selected.id)], primary: next())
    }

    static func resolutions() -> [Int] { Array(Set([150, 300, 600, Defaults[.scanResolution]])).sorted() }

    /// US Letter where people use it, else A4.
    static var defaultPaper: String {
        ["US", "CA", "MX", "PH", "CL", "CO"].contains(Locale.current.region?.identifier ?? "") ? "letter" : "a4"
    }

    static func paper(_ id: String) -> PaperSize {
        switch id {
        case "letter": .letter
        case "legal": .legal
        case "glass": .fitContent
        default: .a4
        }
    }

    private func scannerScan(_ session: ScanSession, _ context: ToolContext) -> ToolPanel {
        typealias S = ScanStrings
        return ToolPanel(.flow, steps: S.deviceSteps, currentStep: 1, controls: [
            .popup(id: Key.colour, label: S.colour, options: [
                ToolOption(ScanColorMode.color.rawValue, S.colourOption), ToolOption(ScanColorMode.grayscale.rawValue, S.greyOption),
                ToolOption(ScanColorMode.blackAndWhite.rawValue, S.blackAndWhiteOption),
            ], selected: Defaults[.scanColorMode].rawValue),
            .popup(id: Key.resolution, label: S.resolution, options: Self.resolutions().map { ToolOption(String($0), S.dpi($0)) },
                   selected: String(Defaults[.scanResolution])),
            .popup(id: Key.paper, label: S.paperSize, options: [
                ToolOption("a4", S.a4), ToolOption("letter", S.letter), ToolOption("legal", S.legal), ToolOption("glass", S.wholeGlass),
            ], selected: Self.defaultPaper),
            .action(id: Action.scan, title: S.scan, isDestructive: false, symbol: "scanner"),
            .custom(id: "pages") { ScanPagesView(session: session) },
        ], moreOptions: [.toggle(id: Key.duplex, label: S.bothSides, isOn: false)], primary: next(enabled: !session.isWorking))
    }

    private func photoFiles(_ context: ToolContext) -> [URL] { Self.photoFiles(context.values, context.inputs) }

    /// The photos chosen in the panel and dropped on it, each once.
    static func photoFiles(_ values: ToolValues, _ inputs: [URL]) -> [URL] {
        var seen = Set<URL>()
        return (values.files(Key.photos) + inputs).filter { seen.insert($0).inserted }
    }

    private func photoChoice(_ context: ToolContext) -> ToolPanel {
        let files = photoFiles(context)
        return ToolPanel(.flow, steps: ScanStrings.photoSteps, currentStep: 0, controls: [
            .files(id: Key.photos, label: ScanStrings.photos, types: ["public.image"], allowsMultiple: true),
        ], primary: next(enabled: !files.isEmpty), message: files.isEmpty ? ToolMessage(.info, ScanStrings.choosePhotos) : nil)
    }

    private func photoStraighten(_ session: ScanSession, _ context: ToolContext) -> ToolPanel {
        let rows = photoFiles(context).enumerated().map { index, url in
            let value = photoPages[url].map { $0.found ? ScanStrings.pageFound : ScanStrings.wholePhoto } ?? ScanStrings.finding
            return ToolOption(url.path, ScanStrings.photo(index + 1), detail: url.lastPathComponent, value: value)
        }
        return ToolPanel(.flow, steps: ScanStrings.photoSteps, currentStep: 1, controls: [
            .list(rows),
            .custom(id: "pages") { ScanPagesView(session: session) },
        ], primary: next(enabled: !session.isWorking))
    }

    private func pagesStep(_ tool: ToolID, session: ScanSession, context: ToolContext) -> ToolPanel {
        typealias S = ScanStrings
        var controls: [ToolControl] = [
            .custom(id: "pages") { ScanPagesView(session: session) },
            .toggle(id: Key.cleanUp, label: S.cleanUp, isOn: Defaults[.cleanUpScans], rowLabel: nil),
            .note(context.document == nil ? S.newPDF : S.atTheEnd),
        ]
        if tool != .fromPhoto {
            controls.insert(.action(id: Action.scanAnother, title: S.scanAnother, isDestructive: false, symbol: "plus"), at: 1)
        }
        let more: [ToolControl] = Services.fix == nil ? [] : [.toggle(id: Key.recognise, label: S.recogniseText, isOn: false)]
        let steps = tool == .fromPhoto ? S.photoSteps : S.deviceSteps
        return ToolPanel(.flow, steps: steps, currentStep: 2, controls: controls, moreOptions: more,
                         primary: ToolButton(Strings.Panel.done, isEnabled: !session.pages.isEmpty && !session.isWorking),
                         output: context.document == nil ? .newDocument(name: S.newDocumentName) : .inPlace,
                         message: session.pages.isEmpty && !session.isWorking ? ToolMessage(.info, S.nothingYet) : nil)
    }

    // MARK: Preview: devices arriving, photos straightened

    func preview(for tool: ToolID, context: ToolContext) async -> ToolPreview {
        switch tool {
        case .scanWithScanner where context.values.int(ToolPanel.stepValue) == 0:
            await waitForScanners()
        case .fromPhoto where context.values.int(ToolPanel.stepValue) >= 1:
            let session = session(tool, context.document)
            try? await straightenPhotos(photoFiles(context), into: session)
        default:
            break
        }
        return .none
    }

    /// Gives the browser a moment to report scanners, so step 1 lists them without a click.
    private func waitForScanners() async {
        let deadline = Date().addingTimeInterval(browseWait)
        while scannerSources().isEmpty && Date() < deadline && !Task.isCancelled {
            try? await Task.sleep(nanoseconds: 100_000_000)
        }
    }

    /// Finds and straightens each photo once (cached by file), and shows the results as the session's pages.
    private func straightenPhotos(_ files: [URL], into session: ScanSession) async throws {
        session.isWorking = true
        defer { session.isWorking = false }
        for url in files where photoPages[url] == nil {
            let data: Data
            do { data = try Data(contentsOf: url) } catch { throw ScanFailure.unreadable }
            do {
                if let document = try await service.detectDocument(in: data) {
                    photoPages[url] = (try await service.straighten(data, to: document), true)
                } else {
                    photoPages[url] = (try await Task.detached { try DocumentDetector.wholePhoto(data) }.value, false)
                }
            } catch {
                throw ScanFailure.unreadable
            }
        }
        session.pages = files.compactMap { photoPages[$0]?.page }
    }

    // MARK: Actions

    func handle(action: String, context: ToolContext) async throws -> ToolValues {
        var values = context.values
        let session = session(context.tool, context.document)
        switch (context.tool, action) {
        case (.scanWithScanner, Action.scan):
            guard let source = scannerSources().first(where: { $0.id == values.string(Key.device) }) ?? scannerSources().first else {
                throw ScanFailure.noScanner.toolError
            }
            let settings = ScanSettings(resolution: Int(values.string(Key.resolution)) ?? Defaults[.scanResolution],
                                        colorMode: ScanColorMode(rawValue: values.string(Key.colour)) ?? Defaults[.scanColorMode],
                                        duplex: values.bool(Key.duplex), paper: Self.paper(values.string(Key.paper, default: Self.defaultPaper)),
                                        cleanUp: Defaults[.cleanUpScans])
            if let error = await session.collect(service.scan(from: source, settings: settings), working: ScanStrings.scanning) {
                throw (error as? ScanFailure)?.toolError ?? ToolError(ScanFailure.failed(error.localizedDescription).errorDescription ?? "")
            }
            values[ToolPanel.stepValue] = .int(2)
        case (.scanWithScanner, Action.tryAgain):
            service.startBrowsing()
            await waitForScanners()
            if scannerSources().isEmpty { throw ScanFailure.noScanner.toolError }
        case (_, Action.scanAnother):
            values[ToolPanel.stepValue] = .int(1)
        default:
            break
        }
        return values
    }

    // MARK: Run

    func run(_ request: ToolRequest, progress: ToolProgress) async throws -> ToolResult {
        let session = session(request.tool, request.document)
        if request.tool == .fromPhoto {
            do { try await straightenPhotos(Self.photoFiles(request.values, request.inputs), into: session) } catch let error as ScanFailure { throw error.toolError }
        }
        var pages = session.pages
        guard !pages.isEmpty else { throw ToolError(ToolMessage(.info, ScanStrings.nothingYet)) }
        let total = pages.count
        if request.values.bool(Key.cleanUp, default: Defaults[.cleanUpScans]) {
            for index in pages.indices {
                try Task.checkCancellation()
                progress.report(completed: index, of: total, page: nil)
                pages[index] = try await service.cleanUp(pages[index], options: CleanUpOptions())
            }
        }
        progress.report(completed: total, of: total)
        let ready = pages
        var pdf = try await Task.detached { try ScanPDF.make(ready) }.value
        if request.values.bool(Key.recognise), let fix = Services.fix {
            pdf = try await fix.recognize(.data(pdf), pages: Array(0..<total), options: OCROptions(cleanUp: false), progress: progress).data
        }
        try Task.checkCancellation()
        session.reset()
        guard let document = request.document else {
            return .newDocument(pdf, name: ScanStrings.newDocumentName, banner: nil)
        }
        do {
            let group = try await Services.pages.perform(.insertFile(.data(pdf), pages: [], at: document.pageCount), in: document)
            return .inPlace(undoable: UndoGroup(ScanStrings.undoName, group.change), banner: nil)
        } catch let error as PageEditError {
            throw ToolError(error.errorDescription ?? "")
        }
    }
}
