import AppKit
import RenderKit
import SuperPDFCore
import UniformTypeIdentifiers

/// A converter that isn't there or can't do this input.
enum ConvertError: Error, Equatable {
    case unsupported(String)
}

/// `Services.convert`: the conversion registry runtime (features §3.2). Each file type has a ranked list of engines
/// (`ConverterTable`); the first one available on this Mac runs. Built-in converters are always there; LibreOffice is
/// used when the person installed it, and only for what the built-in ones can't read (or when asked: "Try with
/// LibreOffice"); an app (Pages, Word…) when it is installed, after the panel said it will open briefly.
@MainActor
public final class ConvertService: Converting {
    let helpers: HelperService
    private let runScript: ScriptRunner
    private let isRunning: @MainActor (OfficeApp) -> Bool

    public convenience init(helpers: HelperService) {
        self.init(helpers: helpers, runScript: AppAutomation.osascript,
                  isRunning: { !NSRunningApplication.runningApplications(withBundleIdentifier: $0.bundleIdentifier).isEmpty })
    }

    /// - Parameters:
    ///   - runScript: runs an app's export script (`osascript`; a fake in the self-test).
    ///   - isRunning: whether an app is open already, so it is quit afterwards only if the export launched it.
    init(helpers: HelperService, runScript: @escaping ScriptRunner, isRunning: @escaping @MainActor (OfficeApp) -> Bool) {
        self.helpers = helpers
        self.runScript = runScript
        self.isRunning = isRunning
    }

    // MARK: - The registry

    public func converters(for input: UTType, to output: ConversionFormat) -> [ConverterOffer] {
        offers(forExtension: input.preferredFilenameExtension ?? "", to: output)
    }

    func offers(forExtension ext: String, to output: ConversionFormat = .pdf) -> [ConverterOffer] {
        ConverterTable.engines(forExtension: ext, to: output).map { ConverterOffer(engine: $0, availability: availability(of: $0, output: output)) }
    }

    func availability(of engine: ConverterEngine, output: ConversionFormat = .pdf) -> ConverterAvailability {
        switch engine {
        case .builtIn(.postScript):
            return PostScriptImporter.isAvailable ? .available : .unavailable
        case .builtIn(.imageExport):
            guard let format = ImageFormat(rawValue: output.rawValue) else { return .available }
            return ImageEncoder.supportedFormats.contains(format) ? .available : .unavailable
        case .builtIn:
            return .available
        case .libreOffice:
            return helpers.installation != nil ? .available : .needsLibreOffice
        case .app(let app):
            guard AppAutomation.supports(app) else { return .unavailable }
            return helpers.officeApps[app] != nil ? .available : .needsApp(app)
        case .printFromOwningApp:
            return .unavailable
        }
    }

    /// The engine a file converts with: `preferred` when it is on the file's route and available, else the first
    /// available one; nil when none is (the panel explains why).
    func engine(for url: URL, preferring preferred: ConverterEngine? = nil) -> ConverterEngine? {
        let offers = offers(forExtension: url.pathExtension.lowercased())
        if let preferred, offers.contains(ConverterOffer(engine: preferred, availability: .available)) { return preferred }
        return offers.first { $0.availability == .available }?.engine
    }

    public func canConvertToPDF(_ url: URL) -> Bool {
        let ext = url.pathExtension.lowercased()
        if ext == "pdf" || ConverterTable.toPDF.contains(where: { $0.inputs.contains(ext) }) { return true }
        // Anything else goes to Quick Look, which previews documents and media but not folders or programs.
        var isFolder: ObjCBool = false
        guard FileManager.default.fileExists(atPath: url.path, isDirectory: &isFolder), !isFolder.boolValue,
              let type = UTType(filenameExtension: ext) else { return false }
        return [UTType.content, .compositeContent, .font, .threeDContent, .audiovisualContent].contains { type.conforms(to: $0) }
            && !type.conforms(to: .executable)
    }

    // MARK: - Running

    public func convert(_ job: ConversionJob, progress: ToolProgress) async throws -> ConversionResult {
        guard !job.inputs.isEmpty else { throw ToolError(ConvertStrings.nothingToConvert) }
        if job.output != .pdf { return try await export(job, progress: progress) }

        let work = SuperPDFPaths.ensure(SuperPDFPaths.work.appendingPathComponent("convert-" + UUID().uuidString, isDirectory: true))
        defer { try? FileManager.default.removeItem(at: work) }
        let options = ImportOptions(paper: job.paper, margins: job.margins)
        var parts: [PDFAssembler.Part] = []
        var notices: [String] = [], skipped: [URL] = [], engines: [ConverterEngine] = []
        for (index, input) in job.inputs.enumerated() {
            try Task.checkCancellation()
            progress.report(completed: index, of: job.inputs.count, label: ConvertStrings.converting(input.lastPathComponent))
            let converted = try await convertOne(input, preferring: job.engine, options: options, work: work, depth: 0)
            parts.append(PDFAssembler.Part(url: converted.url, title: job.inputs.count > 1 ? String.baseName(input) : nil,
                                           outline: converted.report.outline))
            notices += converted.report.notices
            skipped += converted.report.skipped
            if let engine = converted.engine { engines.append(engine) }
        }
        progress.report(completed: job.inputs.count, of: job.inputs.count)
        let joined = work.appendingPathComponent("joined.pdf")
        _ = try await Task.detached(priority: .userInitiated) {
            try PDFAssembler.join(parts, to: joined)
        }.value
        try Self.place(joined, at: job.destination)
        var seen: Set<String> = []
        return ConversionResult(outputs: [job.destination], engine: engines.first ?? .builtIn(.attributedText), skipped: skipped,
                                notices: notices.filter { seen.insert($0).inserted })
    }

    /// One file into a PDF in `work`: PDFs as they are, a ZIP through every member, the rest through its engine.
    /// `engine` is nil for a PDF that needed no converting.
    private func convertOne(_ url: URL, preferring preferred: ConverterEngine?, options: ImportOptions, work: URL,
                            depth: Int) async throws -> (url: URL, engine: ConverterEngine?, report: ImportReport) {
        if url.pathExtension.lowercased() == "pdf" { return (url, nil, ImportReport()) }
        guard let engine = engine(for: url, preferring: preferred) else { throw noEngineError(url) }
        let output = work.appendingPathComponent(UUID().uuidString + ".pdf")
        var report = ImportReport()
        do {
            switch engine {
            case .builtIn(.zip):
                report = try await convertZip(url, to: output, options: options, work: work, depth: depth)
            case .builtIn(let converter):
                report = try await Importers.run(converter, input: url, output: output, options: options)
            case .libreOffice:
                guard let installation = helpers.installation else { throw noEngineError(url) }
                let folder = work.appendingPathComponent("lo-" + UUID().uuidString, isDirectory: true)
                let produced = try await LibreOffice.convert(url, with: installation, profile: SuperPDFPaths.libreOfficeProfile, outputFolder: folder)
                try FileManager.default.moveItem(at: produced, to: output)
            case .app(let app):
                guard let script = AppAutomation.exportScript(app, input: url, output: output, quitAfterwards: !isRunning(app)) else {
                    throw noEngineError(url)
                }
                try await runScript(script)
            case .printFromOwningApp:
                throw noEngineError(url)
            }
            try Task.checkCancellation()
            guard FileManager.default.fileExists(atPath: output.path) else { throw HelperFailure.noOutput }
        } catch let error as CancellationError {
            throw error
        } catch let error as ToolError {
            throw error
        } catch {
            throw failure(url, engine: engine, error: error)
        }
        return (output, engine, report)
    }

    /// ZIP → PDF (features #44): every member converted in name order, a contents entry per file, the ones that can't be
    /// converted listed in the notice. Archives inside archives are opened two levels deep.
    private func convertZip(_ url: URL, to output: URL, options: ImportOptions, work: URL, depth: Int) async throws -> ImportReport {
        guard depth < 3 else { throw ConvertError.unsupported("nested archive") }
        let folder = SuperPDFPaths.ensure(work.appendingPathComponent("zip-" + UUID().uuidString, isDirectory: true))
        let files = try await Task.detached(priority: .userInitiated) { try ZipArchive(url: url).extract(to: folder) }.value
        let members = files.filter { !$0.lastPathComponent.hasPrefix(".") }
            .sorted { $0.path.localizedStandardCompare($1.path) == .orderedAscending }
        var parts: [PDFAssembler.Part] = []
        var report = ImportReport()
        for member in members {
            try Task.checkCancellation()
            let name = member.path.replacingOccurrences(of: folder.path + "/", with: "")
            guard engine(for: member) != nil || member.pathExtension.lowercased() == "pdf" else {
                report.skipped.append(member); report.notices.append(name); continue
            }
            do {
                let converted = try await convertOne(member, preferring: nil, options: options, work: work, depth: depth + 1)
                parts.append(PDFAssembler.Part(url: converted.url, title: String.baseName(member), outline: converted.report.outline))
                report.skipped += converted.report.skipped
            } catch is CancellationError {
                throw CancellationError()
            } catch {
                report.skipped.append(member); report.notices.append(name)
            }
        }
        guard !parts.isEmpty else { throw ToolError(ConvertStrings.nothingInArchive(url.lastPathComponent)) }
        _ = try await Task.detached(priority: .userInitiated) { try PDFAssembler.join(parts, to: output) }.value
        if !report.notices.isEmpty { report.notices = [ConvertStrings.leftOut(report.notices)] }
        return report
    }

    /// Out of PDF: the first input, in `job.output`.
    private func export(_ job: ConversionJob, progress: ToolProgress) async throws -> ConversionResult {
        var options = ExportOptions(format: job.output)
        options.pages = job.pages
        options.keepLayout = job.keepLayout
        options.oneSheetPerTable = job.keepLayout
        options.picturesUnderText = job.keepLayout
        options.dpi = job.dpi
        options.quality = job.quality
        let input = job.inputs[0]
        let result = try await export(.file(input), options: options, destination: job.destination, baseName: String.baseName(input),
                                      progress: progress)
        return ConversionResult(outputs: result.outputs, engine: ConverterTable.engines(forExtension: "pdf", to: job.output).first ?? .builtIn(.textExport),
                                notices: result.notices + result.problems.map(\.message))
    }

    /// Out of PDF with the panel's choices; the layout-reading formats ask LayoutKit first (scanned pages are recognised
    /// on the way, features #50).
    func export(_ source: PDFSource, options: ExportOptions, destination: URL, baseName: String, progress: ToolProgress) async throws -> ExportResult {
        guard availability(of: ConverterTable.engines(forExtension: "pdf", to: options.format).first ?? .printFromOwningApp,
                           output: options.format) == .available else {
            throw ToolError(Strings.Errors.notConvertible("pdf"))
        }
        do {
            var layout: LayoutDocument?
            if options.needsLayout {
                progress.report(completed: 0, of: 1, label: ConvertStrings.readingPages)
                layout = try await Services.layout.analyze(source, pages: options.pages.isEmpty ? nil : options.pages, options: LayoutOptions())
            }
            try Task.checkCancellation()
            return try await Exporter.run(source, layout: layout, options: options, destination: destination, baseName: baseName, progress: progress)
        } catch let error as CancellationError {
            throw error
        } catch let error as ToolError {
            throw error
        } catch {
            throw ToolError(Strings.Errors.conversionFailed(baseName + ".pdf"), details: String(describing: error))
        }
    }

    // MARK: - Errors (ux §7.4)

    /// Why a file has no engine: LibreOffice missing (with "Get LibreOffice"), or a type nothing here reads.
    func noEngineError(_ url: URL) -> ToolError {
        let ext = url.pathExtension.lowercased()
        if offers(forExtension: ext).contains(where: { $0.availability == .needsLibreOffice }) {
            return ToolError(Strings.Errors.needsLibreOffice(kind: ConvertStrings.kind(ofExtension: ext), fileExtension: ext),
                             action: ToolOption(ConvertAction.getLibreOffice, Strings.Errors.getLibreOffice))
        }
        return ToolError(Strings.Errors.notConvertible(ext.isEmpty ? url.lastPathComponent : ext))
    }

    /// "Something went wrong converting …", with "Try with LibreOffice" when it is installed and can read the file.
    private func failure(_ url: URL, engine: ConverterEngine, error: Error) -> ToolError {
        let canRetry = engine != .libreOffice && helpers.installation != nil
            && ConverterTable.engines(forExtension: url.pathExtension).contains(.libreOffice)
        return ToolError(Strings.Errors.conversionFailed(url.lastPathComponent),
                         action: canRetry ? ToolOption(ConvertAction.tryLibreOffice, Strings.Errors.tryWithLibreOffice) : nil,
                         details: String(describing: error))
    }

    /// Copies `file` to `destination`, replacing what is there (the caller's own output path).
    nonisolated static func place(_ file: URL, at destination: URL) throws {
        let fm = FileManager.default
        try fm.createDirectory(at: destination.deletingLastPathComponent(), withIntermediateDirectories: true)
        if fm.fileExists(atPath: destination.path) { try fm.removeItem(at: destination) }
        try fm.copyItem(at: file, to: destination)
    }
}

/// Action ids the panels and the service's errors share (`ToolProviding.handle(action:)`).
enum ConvertAction {
    static let getLibreOffice = "get-libreoffice"
    static let tryLibreOffice = "try-libreoffice"
    static let useBuiltIn = "use-built-in"
    /// "use-app.pages"
    static func useApp(_ app: OfficeApp) -> String { "use-app." + app.rawValue }
    /// "get-app.pages"
    static func getApp(_ app: OfficeApp) -> String { "get-app." + app.rawValue }
    static let pictures = "pictures"
}
