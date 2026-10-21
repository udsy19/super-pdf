import AppKit
import PDFKit
import SuperPDFCore
import UniformTypeIdentifiers

/// The Convert tiles (ux §4.1, §5.3): To Word, To Excel, To PowerPoint, To images, To text or web page, For archiving
/// (PDF/A), Images → PDF and Any file → PDF.
@MainActor
final class ConvertToolProvider: ToolProviding {
    let service: ConvertService
    let tools: [ToolID] = ToolCatalog.tiles(ownedBy: .convertKit).map(\.id)
    /// The banner's "Open in …" app for a file type; LaunchServices in the app.
    private let appName: @MainActor (_ fileExtension: String) -> String?
    /// Pages without text, per document and page count (asked on every panel change, worked out once).
    private var picturePages: [String: [Int]] = [:]
    private var lastDetection = Date.distantPast

    init(service: ConvertService, appName: @escaping @MainActor (String) -> String? = ConvertToolProvider.defaultAppName) {
        self.service = service
        self.appName = appName
    }

    private var helpers: HelperService { service.helpers }

    // MARK: - Panels (ux §5.3)

    func panel(for tool: ToolID, context: ToolContext) -> ToolPanel {
        let values = context.values
        switch tool {
        case .toWord:
            let format = values.string(V.format, default: "docx")
            let controls: [ToolControl] = [
                .segmented(id: V.format, label: S.format, options: [ToolOption("docx", "Word (.docx)"), ToolOption("rtf", "Rich text (.rtf)")], selected: "docx"),
                .segmented(id: V.layout, label: S.layout, options: [ToolOption("keep", S.keepTheLook), ToolOption("flow", S.flowingText)], selected: "keep"),
            ]
            return exportPanel(context, controls: controls + engineLine(.wordWriter), ext: format,
                               primary: format == "rtf" ? S.saveAsRichText : S.saveAsWord)
        case .toExcel:
            let format = values.string(V.format, default: "xlsx")
            let controls: [ToolControl] = [
                .segmented(id: V.format, label: S.format, options: [ToolOption("xlsx", "Excel (.xlsx)"), ToolOption("csv", "CSV (.csv)")], selected: "xlsx"),
                .toggle(id: V.perTable, label: S.oneSheetPerTable, isOn: true),
            ]
            return exportPanel(context, controls: (format == "csv" ? [controls[0]] : controls) + engineLine(.spreadsheetWriter), ext: format,
                               primary: format == "csv" ? S.saveAsCSV : S.saveAsExcel)
        case .toPowerPoint:
            return exportPanel(context, controls: [.toggle(id: V.pictures, label: S.editableTextOverPictures, isOn: true)] + engineLine(.presentationWriter),
                               ext: "pptx", primary: S.saveAsPowerPoint)
        case .toTextOrWeb:
            let format = values.string(V.format, default: "text")
            let ext = format == "html" ? "html" : format == "epub" ? "epub" : "txt"
            let control = ToolControl.segmented(id: V.format, label: S.format,
                                                options: [ToolOption("text", S.text), ToolOption("html", S.html), ToolOption("epub", S.epub)], selected: "text")
            let primary = format == "html" ? S.saveAsWebPage : format == "epub" ? S.saveAsEPUB : S.saveAsText
            return exportPanel(context, controls: [control] + engineLine(format == "html" ? .htmlExport : format == "epub" ? .epubExport : .textExport),
                               ext: ext, primary: primary, scannedNote: true)
        case .toImages:
            return imagesPanel(context)
        case .forArchiving:
            return archivePanel(context)
        case .imagesToPDF, .anyFileToPDF:
            return toPDFPanel(tool, context)
        default:
            return ToolPanel(.convert, primary: ToolButton(S.makePDF, isEnabled: false))
        }
    }

    private func engineLine(_ converter: BuiltInConverter) -> [ToolControl] {
        [.note(Strings.Panel.engineLine(.builtIn(converter)))]
    }

    /// PDF → Word / Excel / PowerPoint / text: format, choices, the engine line, "Save as …" next to the original.
    private func exportPanel(_ context: ToolContext, controls: [ToolControl], ext: String, primary: String, scannedNote: Bool = true) -> ToolPanel {
        var controls = controls
        if scannedNote, let note = scannedPagesNote(context) { controls.append(.note(note)) }
        return ToolPanel(.convert, showsScope: true, controls: controls, primary: ToolButton(primary, isEnabled: context.document != nil),
                         output: .sameName(ext: ext))
    }

    /// "3 pages are pictures — text will be recognised first" (ux §5.3) for the pages in scope.
    private func scannedPagesNote(_ context: ToolContext) -> String? {
        guard let document = context.document else { return nil }
        let key = "\(document.id)/\(document.pageCount)/\(document.state.isEdited)"
        if picturePages[key] == nil {
            picturePages[key] = (0..<document.pageCount).filter { index in
                (document.pdf.page(at: index)?.string ?? "").trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            }
        }
        let scope = Set(context.scope.pages(count: document.pageCount, current: context.currentPage))
        let count = picturePages[key]!.filter(scope.contains).count
        return count == 0 ? nil : S.picturePages(count)
    }

    private func imagesPanel(_ context: ToolContext) -> ToolPanel {
        let values = context.values
        let embedded = values.bool(V.embedded)
        let format = values.string(V.format, default: "png")
        var controls: [ToolControl] = [
            .segmented(id: V.format, label: S.format, options: [ToolOption("png", "PNG"), ToolOption("jpeg", "JPEG"), ToolOption("tiff", "TIFF")], selected: "png"),
        ]
        var more: [ToolControl] = []
        if embedded {
            controls = [.note(S.picturesInsideNote)]
        } else {
            controls.append(.radio(id: V.quality, options: [
                ToolOption("good", S.qualityGood, detail: S.qualityGoodDetail),
                ToolOption("print", S.qualityPrint, detail: S.qualityPrintDetail),
                ToolOption("screen", S.qualityScreen, detail: S.qualityScreenDetail),
            ], selected: "good"))
            if format == "jpeg" {
                more.append(.slider(id: V.jpegQuality, label: S.jpegQuality, range: 0.3...1, step: 0.05, value: 0.85, format: .percent))
            }
            if format == "tiff" { more.append(.toggle(id: V.multiPage, label: S.oneTIFF, isOn: false)) }
        }
        controls.append(.action(id: ConvertAction.pictures, title: embedded ? S.exportPagesInstead : S.exportPicturesInstead, isDestructive: false))
        return ToolPanel(.presetAndMore, showsScope: true, controls: controls, moreOptions: more,
                         primary: ToolButton(S.saveImages, isEnabled: context.document != nil), output: .folder(.images))
    }

    private func archivePanel(_ context: ToolContext) -> ToolPanel {
        let other = context.values.string(V.otherStandard, default: "none")
        var controls: [ToolControl] = []
        if other == "none" {
            controls.append(.radio(id: V.level, options: [
                ToolOption(PDFALevel.a2b.rawValue, "PDF/A-2b (recommended)", detail: S.level2bDetail),
                ToolOption(PDFALevel.a1b.rawValue, "PDF/A-1b (oldest readers)", detail: S.level1bDetail),
                ToolOption(PDFALevel.a3b.rawValue, "PDF/A-3b (keeps attachments)", detail: S.level3bDetail),
            ], selected: PDFALevel.a2b.rawValue))
        } else {
            controls.append(.note(S.otherStandardChosen))
        }
        controls.append(.note(S.archiveCheckNote))
        let more: [ToolControl] = [.popup(id: V.otherStandard, label: S.otherStandard, options: [
            ToolOption("none", S.none), ToolOption(PDFALevel.a2u.rawValue, "PDF/A-2u", detail: S.level2uDetail),
            ToolOption(PDFXLevel.x4.rawValue, "PDF/X-4", detail: S.forPrinters), ToolOption(PDFXLevel.x1a.rawValue, "PDF/X-1a", detail: S.forPrinters),
        ], selected: "none")]
        return ToolPanel(.presetAndMore, controls: controls, moreOptions: more, primary: ToolButton(S.saveArchiveCopy, isEnabled: context.document != nil),
                         output: .sibling(.archive, ext: "pdf"))
    }

    /// Images → PDF and Any file → PDF: the list, paper, margins, which engine converts, and what's missing.
    private func toPDFPanel(_ tool: ToolID, _ context: ToolContext) -> ToolPanel {
        detectNowAndThen()
        let files = inputs(context)
        let paper = context.values.string(V.paper, default: "fit")
        var controls: [ToolControl] = [
            .files(id: V.files, label: tool == .imagesToPDF ? S.pictures : S.files, types: [tool == .imagesToPDF ? UTType.image.identifier : UTType.item.identifier],
                   allowsMultiple: true),
            .segmented(id: V.paper, label: S.paper, options: [ToolOption("fit", S.fitEachPicture),
                                                               ToolOption("a4", "A4"), ToolOption("letter", "Letter")], selected: "fit"),
        ]
        if paper != "fit" {
            controls.append(.popup(id: V.margins, label: S.margins, options: [
                ToolOption("0", S.marginNone), ToolOption("18", S.marginSmall), ToolOption("36", S.marginNormal), ToolOption("72", S.marginWide),
            ], selected: "36"))
        }
        var message: ToolMessage?
        var canRun = !files.isEmpty
        if tool == .imagesToPDF {
            controls.append(contentsOf: engineLine(.images))
            if let other = files.first(where: { !ImageImporter.extensions.contains($0.pathExtension.lowercased()) }) {
                message = ToolMessage(.warning, Strings.Errors.notConvertible(other.pathExtension.lowercased()))
                canRun = false
            }
        } else {
            let plan = self.plan(files, values: context.values)
            controls += plan.engines.map { .note(Strings.Panel.engineLine($0)) }
            message = plan.message
            canRun = canRun && plan.canRun
        }
        return ToolPanel(.convert, controls: controls, primary: ToolButton(S.makePDF, isEnabled: canRun),
                         output: .newDocument(name: documentName(files)), message: message)
    }

    /// Which engines will run for these files and the one message the panel shows (ux §7.4): a file nothing can read
    /// (or that needs LibreOffice) stops the run; an iWork file without its app goes ahead with the preview inside; a
    /// built-in conversion offers the Office app on this Mac.
    private func plan(_ files: [URL], values: ToolValues) -> (engines: [ConverterEngine], message: ToolMessage?, canRun: Bool) {
        let preferred = Self.engine(from: values.string(V.engine))
        var engines: [ConverterEngine] = []
        var blocking: ToolMessage?, iWork: ToolMessage?, offer: ToolMessage?
        for file in files {
            let ext = file.pathExtension.lowercased()
            if ext == "pdf" { continue }
            guard let engine = service.engine(for: file, preferring: preferred) else {
                if blocking == nil {
                    let error = service.noEngineError(file)
                    blocking = ToolMessage(.warning, error.message.text, action: error.message.action)
                }
                continue
            }
            if !engines.contains(engine) { engines.append(engine) }
            let offers = service.offers(forExtension: ext)
            if engine == .builtIn(.iWorkPreview), iWork == nil,
               case .needsApp(let app)? = offers.first(where: { if case .needsApp = $0.availability { true } else { false } })?.availability {
                iWork = ToolMessage(.info, Strings.Errors.iWorkMissing(app), action: ToolOption(ConvertAction.getApp(app), Strings.Errors.getApp(app)))
            }
            if offer == nil {
                if case .app(let app) = engine, offers.contains(where: { if case .builtIn = $0.engine { true } else { false } }) {
                    offer = ToolMessage(.info, Strings.Errors.needsOfficeApp(app), action: ToolOption(ConvertAction.useBuiltIn, Strings.Errors.useBuiltInConverter))
                } else if case .builtIn = engine, ext != "pages", ext != "numbers", ext != "key",
                          let better = offers.first(where: { if case .app = $0.engine { $0.availability == .available } else { false } }),
                          case .app(let app) = better.engine {
                    offer = ToolMessage(.info, Strings.Errors.needsOfficeApp(app), action: ToolOption(ConvertAction.useApp(app), Strings.Errors.useApp(app)))
                }
            }
        }
        return (engines, blocking ?? iWork ?? offer, blocking == nil)
    }

    /// The files of an Images → PDF / Any file → PDF panel: dropped on the tile, then added in the list.
    private func inputs(_ context: ToolContext) -> [URL] {
        var seen: Set<URL> = []
        return (context.inputs + context.values.files(V.files)).filter { seen.insert($0.standardizedFileURL).inserted }
    }

    private func documentName(_ files: [URL]) -> String {
        files.count == 1 ? String.baseName(files[0]) : S.combinedName
    }

    /// LibreOffice or an app may have been installed while Super PDF was open: look again, at most every few seconds.
    private func detectNowAndThen() {
        guard Date().timeIntervalSince(lastDetection) > 5 else { return }
        lastDetection = Date()
        helpers.detect()
    }

    // MARK: - Actions

    func handle(action: String, context: ToolContext) async throws -> ToolValues {
        var values = context.values
        switch action {
        case ConvertAction.getLibreOffice:
            helpers.getLibreOffice()
            lastDetection = .distantPast
        case ConvertAction.tryLibreOffice:
            values[V.engine] = .string(Self.engineValue(.libreOffice))
        case ConvertAction.useBuiltIn:
            values[V.engine] = .string("built-in")
        case ConvertAction.pictures:
            values[V.embedded] = .bool(!values.bool(V.embedded))
        default:
            if let app = OfficeApp.allCases.first(where: { ConvertAction.useApp($0) == action }) {
                values[V.engine] = .string(Self.engineValue(.app(app)))
            } else if let app = OfficeApp.allCases.first(where: { ConvertAction.getApp($0) == action }) {
                helpers.getApp(app)
                lastDetection = .distantPast
            }
        }
        return values
    }

    static func engineValue(_ engine: ConverterEngine) -> String {
        switch engine {
        case .libreOffice: "libreoffice"
        case .app(let app): "app." + app.rawValue
        case .builtIn, .printFromOwningApp: "built-in"
        }
    }

    /// The panel's engine choice; "built-in" means the file's own built-in converter (nil lets the ranking decide, and
    /// the ranking always starts with the built-in one where there is one).
    static func engine(from value: String) -> ConverterEngine? {
        if value == "libreoffice" { return .libreOffice }
        if value.hasPrefix("app."), let app = OfficeApp(rawValue: String(value.dropFirst(4))) { return .app(app) }
        return nil
    }

    // MARK: - Runs

    func run(_ request: ToolRequest, progress: ToolProgress) async throws -> ToolResult {
        let values = request.values
        switch request.tool {
        case .imagesToPDF, .anyFileToPDF:
            return try await runToPDF(request, progress: progress)
        case .forArchiving:
            return try await runArchive(request, progress: progress)
        default:
            break
        }
        guard let source = request.source ?? request.inputs.first.map({ PDFSource.file($0) }) else {
            throw ToolError(ConvertStrings.nothingToConvert)
        }
        let base = request.document?.displayName ?? request.inputs.first.map(String.baseName) ?? S.combinedName
        var options = ExportOptions(format: .docx)
        options.pages = request.pages
        switch request.tool {
        case .toWord:
            options.format = values.string(V.format, default: "docx") == "rtf" ? .rtf : .docx
            options.keepLayout = values.string(V.layout, default: "keep") == "keep"
        case .toExcel:
            options.format = values.string(V.format, default: "xlsx") == "csv" ? .csv : .xlsx
            options.oneSheetPerTable = values.bool(V.perTable, default: true)
        case .toPowerPoint:
            options.format = .pptx
            options.picturesUnderText = values.bool(V.pictures, default: true)
        case .toTextOrWeb:
            options.format = switch values.string(V.format, default: "text") { case "html": .html; case "epub": .epub; default: .text }
        case .toImages:
            options.format = ConversionFormat(rawValue: values.string(V.format, default: "png")) ?? .png
            options.dpi = switch values.string(V.quality, default: "good") { case "print": 300; case "screen": 72; default: 150 }
            options.quality = values.double(V.jpegQuality, default: 0.85)
            options.multiPageTIFF = values.bool(V.multiPage)
            options.embeddedPictures = values.bool(V.embedded)
            let folderName = request.destination?.lastPathComponent ?? OutputFolder.images.folderName(base: base)
            let folder = request.workFolder.appendingPathComponent("images", isDirectory: true)
            let result = try await service.export(source, options: options, destination: folder, baseName: base, progress: progress)
            guard !result.outputs.isEmpty else { throw ToolError(S.noPicturesInside) }
            return .newFiles(result.outputs, banner: Strings.Banner.savedImages(result.outputs.count, folder: folderName))
        default:
            throw ToolError(ConvertStrings.nothingToConvert)
        }
        let ext = options.format == .text ? "txt" : options.format.rawValue
        let name = request.destination?.lastPathComponent ?? "\(base).\(ext)"
        let output = request.workFolder.appendingPathComponent(name)
        _ = try await service.export(source, options: options, destination: output, baseName: base, progress: progress)
        return .newFile(output, banner: Strings.Banner.saved(name, openIn: appName((name as NSString).pathExtension)))
    }

    private func runArchive(_ request: ToolRequest, progress: ToolProgress) async throws -> ToolResult {
        guard let source = request.source ?? request.inputs.first.map({ PDFSource.file($0) }) else { throw ToolError(ConvertStrings.nothingToConvert) }
        let base = request.document?.displayName ?? request.inputs.first.map(String.baseName) ?? S.combinedName
        let name = request.destination?.lastPathComponent ?? OutputSuffix.archive.fileName(base: base, ext: "pdf")
        let output = request.workFolder.appendingPathComponent(name)
        let other = request.values.string(V.otherStandard, default: "none")
        var options = ExportOptions(format: .pdfA)
        if let x = PDFXLevel(rawValue: other) {
            options.format = .pdfX
            options.pdfXLevel = x
            _ = try await service.export(source, options: options, destination: output, baseName: base, progress: progress)
            return .newFile(output, banner: Strings.Banner.saved(name, openIn: nil))
        }
        options.pdfALevel = PDFALevel(rawValue: other) ?? PDFALevel(rawValue: request.values.string(V.level, default: "2b")) ?? .a2b
        progress.report(completed: 0, of: 1, label: S.archiving)
        let result = try await service.export(source, options: options, destination: output, baseName: base, progress: progress)
        return .newFile(output, banner: Strings.Banner.archived(name, level: options.pdfALevel, unfixed: result.problems.count))
    }

    private func runToPDF(_ request: ToolRequest, progress: ToolProgress) async throws -> ToolResult {
        var seen: Set<URL> = []
        let files = (request.inputs + request.values.files(V.files)).filter { seen.insert($0.standardizedFileURL).inserted }
        guard !files.isEmpty else { throw ToolError(ConvertStrings.nothingToConvert) }
        let paper: PaperSize = switch request.values.string(V.paper, default: "fit") { case "a4": .a4; case "letter": .letter; default: .fitContent }
        let margins = Double(request.values.string(V.margins, default: "36")) ?? 36
        let output = request.workFolder.appendingPathComponent("converted.pdf")
        let notices: [String]
        if request.tool == .imagesToPDF {
            progress.report(completed: 0, of: files.count, label: ConvertStrings.converting(files[0].lastPathComponent))
            let options = ImportOptions(paper: paper, margins: margins)
            let report = try await Task.detached(priority: .userInitiated) {
                try ImageImporter.convert(files, to: output, options: options)
            }.value
            notices = report.notices
        } else {
            let job = ConversionJob(inputs: files, output: .pdf, engine: Self.engine(from: request.values.string(V.engine)), paper: paper,
                                    margins: margins, destination: output)
            notices = try await service.convert(job, progress: progress).notices
        }
        let data = try Data(contentsOf: output)
        return .newDocument(data, name: documentName(files), banner: notices.isEmpty ? nil : ResultBanner(notices.joined(separator: " ")))
    }

    /// The app that opens a file type, by the name people know ("Word", "Pages").
    static func defaultAppName(_ fileExtension: String) -> String? {
        guard let type = UTType(filenameExtension: fileExtension), let app = NSWorkspace.shared.urlForApplication(toOpen: type) else { return nil }
        let name = FileManager.default.displayName(atPath: app.path).replacingOccurrences(of: ".app", with: "")
        return OfficeApp.allCases.first { $0.name == name }?.shortName ?? name
    }

    /// Value ids of the Convert panels.
    enum V {
        static let format = "format", layout = "layout", perTable = "one-sheet-per-table", pictures = "pictures-under-text"
        static let quality = "quality", jpegQuality = "jpeg-quality", multiPage = "multi-page-tiff", embedded = "pictures-inside"
        static let level = "level", otherStandard = "other-standard"
        static let files = "files", paper = "paper", margins = "margins", engine = "engine"
    }

    private typealias S = ConvertPanelStrings
}
