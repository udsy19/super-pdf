import AppKit
@testable import ConvertKit
import CoreText
import ImageIO
@testable import LayoutKit
import PDFKit
import PDFModelKit
import RenderKit
import SuperPDFCore
import ToolsKit
import UniformTypeIdentifiers

// ConvertKit (WP7): the registry and its availability, the LibreOffice helper (a fake `soffice` always; the installed
// one headless on generated files with SUPERPDF_SELFTEST_LIBREOFFICE=1), app automation through a fake script runner,
// every built-in converter into PDF on files generated here, the exports out of PDF (Word, Excel, PowerPoint, text, web
// page, EPUB, pictures, PDF/A, PDF/X, form data), and the panels driven through ToolSession. No case opens an app or a
// URL: openers and script runners are fakes.
func registerConvertKitTests() {
    SelfTest.cases.append(("ConvertKit.zip", { convertZip() }))
    SelfTest.cases.append(("ConvertKit.registry", { convertRegistry() }))
    SelfTest.cases.append(("ConvertKit.libreOfficeDetection", { convertLibreOfficeDetection() }))
    SelfTest.cases.append(("ConvertKit.libreOfficeRunner", { convertLibreOfficeRunner() }))
    SelfTest.cases.append(("ConvertKit.libreOfficeInstalled", { convertRealLibreOffice() }))
    SelfTest.cases.append(("ConvertKit.automation", { convertAutomation() }))
    SelfTest.cases.append(("ConvertKit.wordAndText", { convertAttributedText() }))
    SelfTest.cases.append(("ConvertKit.web", { convertWeb() }))
    SelfTest.cases.append(("ConvertKit.markdown", { convertMarkdown() }))
    SelfTest.cases.append(("ConvertKit.epub", { convertEPUB() }))
    SelfTest.cases.append(("ConvertKit.mail", { convertMail() }))
    SelfTest.cases.append(("ConvertKit.hwpx", { convertHWPX() }))
    SelfTest.cases.append(("ConvertKit.iWork", { convertIWork() }))
    SelfTest.cases.append(("ConvertKit.images", { convertImages() }))
    SelfTest.cases.append(("ConvertKit.structuredText", { convertStructuredText() }))
    SelfTest.cases.append(("ConvertKit.zipToPDF", { convertZipToPDF() }))
    SelfTest.cases.append(("ConvertKit.quickLook", { convertQuickLook() }))
    SelfTest.cases.append(("ConvertKit.textExports", { convertTextExports() }))
    SelfTest.cases.append(("ConvertKit.imageExports", { convertImageExports() }))
    SelfTest.cases.append(("ConvertKit.panels", { convertPanels() }))
    SelfTest.cases.append(("ConvertKit.runs", { convertRuns() }))
    registerConvertKitArchiveTests()
    registerConvertKitSheetsTests()
    registerConvertKitSlidesTests()
    registerConvertKitWritersTests()
}

// MARK: - Fixtures and fakes

private func ckFolder() -> URL {
    SuperPDFPaths.ensure(scratch.appendingPathComponent("convertkit-\(UUID().uuidString)", isDirectory: true))
}

private func ckText(_ url: URL) -> String { PDFDocument(url: url)?.string ?? "" }
private func ckPages(_ url: URL) -> Int { PDFDocument(url: url)?.pageCount ?? 0 }

/// Records what a fake was asked (on the main actor).
private final class Recorder: @unchecked Sendable {
    var urls: [URL] = []
    var scripts: [String] = []
}

/// A helper service that sees LibreOffice only at `libreOffice` and the given apps, opening pages into `recorder`.
@MainActor
private func ckHelpers(libreOffice: URL? = nil, apps: Set<OfficeApp> = [], recorder: Recorder = Recorder()) -> HelperService {
    Defaults[.libreOfficePath] = nil
    return HelperService(open: { recorder.urls.append($0) },
                         findApp: { id in apps.first { $0.bundleIdentifier == id }.map { _ in URL(fileURLWithPath: "/Applications/Fake.app") } },
                         candidates: libreOffice.map { [$0] } ?? [])
}

@MainActor
private func ckService(_ helpers: HelperService, recorder: Recorder = Recorder(), scriptWritesPDF: Bool = true) -> ConvertService {
    ConvertService(helpers: helpers, runScript: { script in
        await MainActor.run { recorder.scripts.append(script) }
        // The fake app "exports": write a PDF where the script says.
        guard scriptWritesPDF, let range = script.range(of: #"(?<=POSIX file ")[^"]+\.pdf"#, options: .regularExpression)
            ?? script.range(of: #"(?<=file name ")[^"]+\.pdf"#, options: .regularExpression)
            ?? script.range(of: #"(?<=filename ")[^"]+\.pdf"#, options: .regularExpression) else { return }
        try makePDF(pages: 2).write(to: URL(fileURLWithPath: String(script[range])))
    }, isRunning: { $0 == .word })
}

/// A PNG (or JPEG with an EXIF orientation) of `size` pixels, a red square on white.
private func ckImage(_ url: URL, size: CGSize = CGSize(width: 400, height: 200), type: UTType = .png, orientation: Int = 1) {
    let context = CGContext(data: nil, width: Int(size.width), height: Int(size.height), bitsPerComponent: 8, bytesPerRow: 0,
                            space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue)!
    context.setFillColor(CGColor(gray: 1, alpha: 1)); context.fill(CGRect(origin: .zero, size: size))
    context.setFillColor(CGColor(srgbRed: 1, green: 0, blue: 0, alpha: 1)); context.fill(CGRect(x: 20, y: 20, width: 60, height: 60))
    let destination = CGImageDestinationCreateWithURL(url as CFURL, type.identifier as CFString, 1, nil)!
    CGImageDestinationAddImage(destination, context.makeImage()!, [kCGImagePropertyOrientation: orientation] as CFDictionary)
    CGImageDestinationFinalize(destination)
}

/// A two-page TIFF.
private func ckTIFF(_ url: URL) {
    let destination = CGImageDestinationCreateWithURL(url as CFURL, UTType.tiff.identifier as CFString, 2, nil)!
    for gray in [0.2, 0.8] {
        let context = CGContext(data: nil, width: 100, height: 140, bitsPerComponent: 8, bytesPerRow: 0, space: CGColorSpaceCreateDeviceGray(),
                                bitmapInfo: CGImageAlphaInfo.none.rawValue)!
        context.setFillColor(CGColor(gray: gray, alpha: 1)); context.fill(CGRect(x: 0, y: 0, width: 100, height: 140))
        CGImageDestinationAddImage(destination, context.makeImage()!, nil)
    }
    CGImageDestinationFinalize(destination)
}

/// A PDF with a heading, two paragraphs and a picture, made with Core Text.
private func ckSourcePDF(_ url: URL, pages: Int = 2) {
    var box = CGRect(x: 0, y: 0, width: 612, height: 792)
    let context = CGContext(url as CFURL, mediaBox: &box, [kCGPDFContextTitle: "Quarterly report"] as CFDictionary)!
    for n in 1...pages {
        context.beginPDFPage(nil)
        func draw(_ text: String, size: CGFloat, bold: Bool = false, y: CGFloat) {
            let font = bold ? NSFont.boldSystemFont(ofSize: size) : NSFont.systemFont(ofSize: size)
            let line = CTLineCreateWithAttributedString(NSAttributedString(string: text, attributes: [.font: font]))
            context.textPosition = CGPoint(x: 72, y: y)
            CTLineDraw(line, context)
        }
        let topics = ["Orchards in spring", "Harvest and storage", "Selling at market"]
        draw(topics[(n - 1) % topics.count], size: 22, bold: true, y: 700)
        draw("The first paragraph on this page is about apples and how they grow on old trees.", size: 11, y: 660)
        draw("A second paragraph follows here, about pears, plums and the weather in the valley.", size: 11, y: 630)
        let image = CGContext(data: nil, width: 120, height: 80, bitsPerComponent: 8, bytesPerRow: 0, space: CGColorSpace(name: CGColorSpace.sRGB)!,
                              bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue)!
        image.setFillColor(CGColor(srgbRed: 0, green: 0.5, blue: 1, alpha: 1)); image.fill(CGRect(x: 0, y: 0, width: 120, height: 80))
        context.draw(image.makeImage()!, in: CGRect(x: 72, y: 400, width: 180, height: 120))
        context.endPDFPage()
    }
    context.closePDF()
}

/// A ZIP of `files` (path → contents), written with ConvertKit's writer.
private func ckZip(_ url: URL, _ files: [(String, Data)], storedFirst: Bool = false) {
    var zip = ZipWriter()
    for (index, file) in files.enumerated() { zip.add(file.0, file.1, compress: !(storedFirst && index == 0)) }
    try? zip.finish().write(to: url)
}

@MainActor
private func ckAwait<T>(_ work: @escaping @MainActor () async throws -> T) -> T? {
    switch complete(120, work) {
    case .success(let value)?: return value
    case .failure(let error)?: check(false, "failed: \(error)"); return nil
    case nil: check(false, "timed out"); return nil
    }
}

@MainActor
private func ckError<T>(_ work: @escaping @MainActor () async throws -> T) -> Error? {
    if case .failure(let error)? = complete(120, work) { return error }
    return nil
}

// MARK: - ZIP

@MainActor
private func convertZip() {
    let folder = ckFolder()
    let text = String(repeating: "Hello, archive. ", count: 200)
    var zip = ZipWriter()
    zip.add("a.txt", text)
    zip.add("folder/b.bin", Data([0, 1, 2, 3]), compress: false)
    zip.add("../escape.txt", "nope")
    let data = zip.finish()
    guard let archive = try? ZipArchive(data: data) else { check(false, "the written ZIP reads back"); return }
    check(archive.entries.map(\.path) == ["a.txt", "folder/b.bin", "../escape.txt"], "entries in order")
    check(archive.entries[0].method == 8 && archive.entries[1].method == 0, "deflated and stored entries")
    check((try? archive.data("a.txt")).flatMap { $0 }.map { String(decoding: $0, as: UTF8.self) } == text, "deflate round trip")
    check((try? archive.data("FOLDER/B.BIN")).flatMap { $0 } == Data([0, 1, 2, 3]), "part names match without case (OPC)")
    let out = folder.appendingPathComponent("out", isDirectory: true)
    try? FileManager.default.createDirectory(at: out, withIntermediateDirectories: true)
    let written = (try? archive.extract(to: out)) ?? []
    check(written.count == 2 && !FileManager.default.fileExists(atPath: folder.appendingPathComponent("escape.txt").path), "no path escapes the folder")
    var damaged = data
    damaged[40] ^= 0xFF
    check((try? ZipArchive(data: damaged).data("a.txt")) == nil, "a damaged entry fails its checksum")
    check((try? ZipArchive(data: Data("not a zip at all, really".utf8))) == nil, "not a ZIP")
    check(CRC32.checksum(Data("123456789".utf8)) == 0xCBF4_3926, "CRC-32 check value")
}

// MARK: - Registry

@MainActor
private func convertRegistry() {
    let recorder = Recorder()
    let service = ckService(ckHelpers(apps: [.word], recorder: recorder))
    check(service.offers(forExtension: "ods") == [ConverterOffer(engine: .libreOffice, availability: .needsLibreOffice)], "ods needs LibreOffice")
    check(service.converters(for: .init(filenameExtension: "docx")!, to: .pdf).first == ConverterOffer(engine: .builtIn(.attributedText), availability: .available),
          "docx: the built-in converter first")
    check(service.engine(for: URL(fileURLWithPath: "/x/a.docx")) == .builtIn(.attributedText), "docx runs built in")
    check(service.engine(for: URL(fileURLWithPath: "/x/a.docx"), preferring: .app(.word)) == .app(.word), "Word when asked and installed")
    check(service.engine(for: URL(fileURLWithPath: "/x/a.docx"), preferring: .libreOffice) == .builtIn(.attributedText), "LibreOffice missing: ignored")
    check(service.engine(for: URL(fileURLWithPath: "/x/a.ods")) == nil, "nothing reads ods here")
    check(service.engine(for: URL(fileURLWithPath: "/x/a.pages")) == .builtIn(.iWorkPreview), "Pages missing: the preview inside")
    check(service.engine(for: URL(fileURLWithPath: "/x/a.xls")) == .app(.excel) || service.engine(for: URL(fileURLWithPath: "/x/a.xls")) == nil,
          "xls needs LibreOffice or Excel")
    check(service.engine(for: URL(fileURLWithPath: "/x/a.msg")) == nil, "Mail can't export")
    check(service.availability(of: .builtIn(.imageExport), output: .webp) == (RenderKitImageSupport.webp ? .available : .unavailable), "WebP export only with an encoder")

    let error = service.noEngineError(URL(fileURLWithPath: "/x/Budget.ods"))
    check(error.message.text == "Spreadsheets saved as “.ods” need the free Office converter (LibreOffice, about 800 MB).", "Needs LibreOffice copy")
    check(error.message.action == ToolOption(ConvertAction.getLibreOffice, "Get LibreOffice"), "with Get LibreOffice")
    check(service.noEngineError(URL(fileURLWithPath: "/x/a.sketch")).message.text.hasPrefix("Super PDF can’t turn “.sketch” files"), "not convertible copy")

    let folder = ckFolder()
    check(service.canConvertToPDF(URL(fileURLWithPath: "/x/a.docx")) && service.canConvertToPDF(URL(fileURLWithPath: "/x/a.pdf")), "known types")
    check(!service.canConvertToPDF(folder), "a folder isn't a file")
    let swift = folder.appendingPathComponent("main.swift")
    try? "print(1)".write(to: swift, atomically: true, encoding: .utf8)
    check(service.canConvertToPDF(swift), "source code goes to Quick Look")

    // Every engine of the table has an answer, and every built-in importer is reachable.
    for route in ConverterTable.toPDF {
        for engine in route.engines { _ = service.availability(of: engine) }
    }
    service.helpers.getLibreOffice()
    check(recorder.urls == [LibreOffice.downloadPage], "Get LibreOffice opens the download page through the opener")
}

private enum RenderKitImageSupport {
    static var webp: Bool { ((CGImageDestinationCopyTypeIdentifiers() as? [String]) ?? []).contains("org.webmproject.webp") }
}

// MARK: - LibreOffice

/// A fake LibreOffice: a bundle whose `soffice` records its arguments and copies a PDF where LibreOffice would write it.
private func ckFakeLibreOffice(in folder: URL, sleeps: Bool = false) -> (app: URL, args: URL, pid: URL) {
    let app = folder.appendingPathComponent("LibreOffice.app")
    let macOS = app.appendingPathComponent("Contents/MacOS")
    try? FileManager.default.createDirectory(at: macOS, withIntermediateDirectories: true)
    let plist = ["CFBundleShortVersionString": "26.2.5.2"] as NSDictionary
    plist.write(to: app.appendingPathComponent("Contents/Info.plist"), atomically: true)
    let fixture = folder.appendingPathComponent("fixture.pdf")
    try? makePDF(pages: 3).write(to: fixture)
    let args = folder.appendingPathComponent("args.txt"), pid = folder.appendingPathComponent("pid.txt")
    let script = sleeps ? """
    #!/bin/sh
    echo $$ > '\(pid.path)'
    exec /bin/sleep 30
    """ : """
    #!/bin/sh
    printf '%s\\n' "$@" > '\(args.path)'
    out=""; prev=""; last=""
    for a in "$@"; do if [ "$prev" = "--outdir" ]; then out="$a"; fi; prev="$a"; last="$a"; done
    name=$(basename "$last"); stem="${name%.*}"
    cp '\(fixture.path)' "$out/$stem.pdf"
    """
    let soffice = macOS.appendingPathComponent("soffice")
    try? script.write(to: soffice, atomically: true, encoding: .utf8)
    try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: soffice.path)
    return (app, args, pid)
}

@MainActor
private func convertLibreOfficeDetection() {
    let folder = ckFolder()
    let fake = ckFakeLibreOffice(in: folder)
    check(LibreOffice.detect(override: nil, candidates: [folder.appendingPathComponent("Nope.app")]) == nil, "nothing there")
    let found = LibreOffice.detect(override: nil, candidates: [fake.app])
    check(found?.soffice.lastPathComponent == "soffice" && found?.version == "26.2.5.2", "an app bundle with its version")
    check(LibreOffice.detect(override: fake.app.appendingPathComponent("Contents/MacOS/soffice"), candidates: [])?.soffice.lastPathComponent == "soffice",
          "the Settings override, an executable")
    let helpers = ckHelpers(libreOffice: fake.app)
    if case .installed(let at, let version) = helpers.libreOffice {
        check(at.path.hasSuffix("Contents/MacOS/soffice") && version == "26.2.5.2", "status installed")
    } else {
        check(false, "the helper service finds the fake")
    }
    Defaults[.libreOfficePath] = fake.app
    let overridden = HelperService(open: { _ in }, findApp: { _ in nil }, candidates: [])
    check(overridden.installation != nil, "the Settings override is honoured")
    Defaults[.libreOfficePath] = nil
    overridden.detect()
    check(overridden.libreOffice == .notInstalled, "detect() looks again")

    let profile = folder.appendingPathComponent("profile")
    let args = LibreOffice.arguments(input: URL(fileURLWithPath: "/a/b.ods"), format: "pdf", outputFolder: URL(fileURLWithPath: "/out"), profile: profile)
    check(args.contains("--headless") && args.contains("--norestore") && args.contains("--nologo") && args.contains("--invisible"),
          "headless, no restore, no logo")
    check(args.first?.hasPrefix("-env:UserInstallation=file://") == true, "a private profile")
    LibreOffice.prepareProfile(profile)
    let registry = (try? String(contentsOf: profile.appendingPathComponent("user/registrymodifications.xcu"), encoding: .utf8)) ?? ""
    check(registry.contains("AutoCheckEnabled") && registry.contains("<value>false</value>"), "update checks off in the profile")
}

@MainActor
private func convertLibreOfficeRunner() {
    let folder = ckFolder()
    let fake = ckFakeLibreOffice(in: folder)
    let service = ckService(ckHelpers(libreOffice: fake.app))
    let ods = folder.appendingPathComponent("Budget.ods")
    try? Data("fake".utf8).write(to: ods)
    let out = folder.appendingPathComponent("Budget.pdf")
    let result = ckAwait { try await service.convert(ConversionJob(inputs: [ods], output: .pdf, destination: out), progress: .ignored) }
    check(result?.engine == .libreOffice && ckPages(out) == 3, "an .ods goes through LibreOffice")
    let args = (try? String(contentsOf: fake.args, encoding: .utf8))?.components(separatedBy: "\n") ?? []
    check(args.contains("--headless") && args.contains("--convert-to") && args.contains(ods.path), "the command line LibreOffice got")
    check(args.contains { $0.hasPrefix("-env:UserInstallation=") && $0.contains("lo-profile") }, "the app's private profile")

    // A run past its time limit is stopped, by its own process id.
    let sleeper = ckFakeLibreOffice(in: ckFolder(), sleeps: true)
    let installation = LibreOffice.Installation(soffice: sleeper.app.appendingPathComponent("Contents/MacOS/soffice"), version: nil)
    let started = Date()
    let error = ckError { try await LibreOffice.convert(ods, with: installation, profile: folder.appendingPathComponent("p"),
                                                         outputFolder: folder.appendingPathComponent("o"), timeout: 1) }
    check(error as? HelperFailure == .timedOut && Date().timeIntervalSince(started) < 10, "timed out after the limit")
    if let pidText = try? String(contentsOf: sleeper.pid, encoding: .utf8), let pid = Int32(pidText.trimmingCharacters(in: .whitespacesAndNewlines)) {
        var gone = false
        for _ in 0..<50 where !gone {
            gone = kill(pid, 0) != 0
            if !gone { RunLoop.main.run(until: Date().addingTimeInterval(0.1)) }
        }
        check(gone, "the stopped process is gone")
    } else {
        check(false, "the fake recorded its process id")
    }
}

/// The installed LibreOffice, for the cases that run it headless on generated files. Opt-in with
/// SUPERPDF_SELFTEST_LIBREOFFICE=1: even headless, LibreOffice checks in with LaunchServices as a regular app, so its
/// Dock icon can show for the seconds a conversion takes, and a plain self-test run shows nothing.
private func ckInstalledLibreOffice() -> LibreOffice.Installation? {
    guard ProcessInfo.processInfo.environment["SUPERPDF_SELFTEST_LIBREOFFICE"] == "1" else {
        print("  (the installed LibreOffice runs only with SUPERPDF_SELFTEST_LIBREOFFICE=1: skipped)")
        return nil
    }
    guard let installation = LibreOffice.detect(override: nil) else { print("  (LibreOffice not installed: skipped)"); return nil }
    return installation
}

/// The real LibreOffice, headless on generated OpenDocument files, when this Mac has it (skipped otherwise).
@MainActor
private func convertRealLibreOffice() {
    guard let installation = ckInstalledLibreOffice() else { return }
    let folder = ckFolder()
    let ods = folder.appendingPathComponent("Budget.ods")
    ckZip(ods, [
        ("mimetype", Data("application/vnd.oasis.opendocument.spreadsheet".utf8)),
        ("META-INF/manifest.xml", Data("""
        <?xml version="1.0" encoding="UTF-8"?>
        <manifest:manifest xmlns:manifest="urn:oasis:names:tc:opendocument:xmlns:manifest:1.0" manifest:version="1.2">
         <manifest:file-entry manifest:full-path="/" manifest:media-type="application/vnd.oasis.opendocument.spreadsheet"/>
         <manifest:file-entry manifest:full-path="content.xml" manifest:media-type="text/xml"/>
        </manifest:manifest>
        """.utf8)),
        ("content.xml", Data("""
        <?xml version="1.0" encoding="UTF-8"?>
        <office:document-content xmlns:office="urn:oasis:names:tc:opendocument:xmlns:office:1.0"
          xmlns:table="urn:oasis:names:tc:opendocument:xmlns:table:1.0" xmlns:text="urn:oasis:names:tc:opendocument:xmlns:text:1.0" office:version="1.2">
         <office:body><office:spreadsheet><table:table table:name="Budget">
          <table:table-row><table:table-cell office:value-type="string"><text:p>Rent</text:p></table:table-cell>
          <table:table-cell office:value-type="float" office:value="1200"><text:p>1200</text:p></table:table-cell></table:table-row>
          <table:table-row><table:table-cell office:value-type="string"><text:p>Groceries</text:p></table:table-cell>
          <table:table-cell office:value-type="float" office:value="350"><text:p>350</text:p></table:table-cell></table:table-row>
         </table:table></office:spreadsheet></office:body>
        </office:document-content>
        """.utf8)),
    ], storedFirst: true)
    let profile = folder.appendingPathComponent("profile", isDirectory: true)
    let produced = ckAwait { try await LibreOffice.convert(ods, with: installation, profile: profile, outputFolder: folder.appendingPathComponent("out")) }
    if let produced {
        let text = ckText(produced)
        check(text.contains("Rent") && text.contains("Groceries"), "LibreOffice converted the .ods (got \(text.prefix(60)))")
    }
}

// MARK: - App automation

@MainActor
private func convertAutomation() {
    let folder = ckFolder()
    let recorder = Recorder()
    let service = ckService(ckHelpers(apps: [.pages, .word]), recorder: recorder)
    let pages = folder.appendingPathComponent("Letter \"draft\".pages")
    try? Data("fake".utf8).write(to: pages)
    let out = folder.appendingPathComponent("out.pdf")
    let result = ckAwait { try await service.convert(ConversionJob(inputs: [pages], output: .pdf, destination: out), progress: .ignored) }
    check(result?.engine == .app(.pages) && ckPages(out) == 2, "Pages exports the file")
    let script = recorder.scripts.first ?? ""
    check(script.contains("tell application id \"com.apple.iWork.Pages\"") && script.contains("export theDocument to outFile as PDF"), "the Pages script")
    check(script.contains("Letter \\\"draft\\\".pages"), "quotes in file names are escaped")
    check(script.contains("\n    quit"), "Pages wasn't open, so it is told to quit afterwards")

    let docx = folder.appendingPathComponent("Memo.docx")
    try? (try? NSAttributedString(string: "Memo").data(from: NSRange(location: 0, length: 4), documentAttributes: [.documentType: NSAttributedString.DocumentType.officeOpenXML]))?.write(to: docx)
    _ = ckAwait { try await service.convert(ConversionJob(inputs: [docx], output: .pdf, engine: .app(.word), destination: out), progress: .ignored) }
    let word = recorder.scripts.last ?? ""
    check(word.contains("com.microsoft.Word") && word.contains("format PDF") && !word.contains("quit"), "Word was open already: not quit")
    for app in OfficeApp.allCases {
        let script = AppAutomation.exportScript(app, input: docx, output: out, quitAfterwards: false)
        check((script == nil) == (app == .mail), "\(app.name): a script exactly when the app can export")
    }
    check(AppAutomation.appStorePage(.pages)?.host == "apps.apple.com" && AppAutomation.appStorePage(.word) == nil, "App Store pages for iWork")
}

// MARK: - Into PDF

@MainActor
private func convertAttributedText() {
    let folder = ckFolder()
    let service = ckService(ckHelpers())
    let body = (1...120).map { "Paragraph \($0): the quick brown fox jumps over the lazy dog, again and again." }.joined(separator: "\n")
    let text = NSMutableAttributedString(string: "Annual letter\n" + body, attributes: [.font: NSFont.systemFont(ofSize: 12)])
    text.addAttribute(.font, value: NSFont.boldSystemFont(ofSize: 20), range: NSRange(location: 0, length: 13))
    text.addAttribute(.link, value: URL(string: "https://example.com")!, range: NSRange(location: 14, length: 9))
    let whole = NSRange(location: 0, length: text.length)
    let formats: [(String, NSAttributedString.DocumentType)] = [("docx", .officeOpenXML), ("odt", .openDocument), ("rtf", .rtf), ("doc", .docFormat)]
    for (ext, type) in formats {
        let url = folder.appendingPathComponent("Letter.\(ext)")
        guard let data = try? text.data(from: whole, documentAttributes: [.documentType: type]) else { check(false, "made a .\(ext) fixture"); continue }
        try? data.write(to: url)
        let out = folder.appendingPathComponent("\(ext).pdf")
        let result = ckAwait { try await service.convert(ConversionJob(inputs: [url], output: .pdf, paper: .a4, destination: out), progress: .ignored) }
        check(result?.engine == .builtIn(.attributedText), ".\(ext) built in")
        let pdf = PDFDocument(url: out)
        check((pdf?.pageCount ?? 0) >= 2, ".\(ext) paginates (\(pdf?.pageCount ?? 0) pages)")
        check(pdf?.string?.contains("Paragraph 120") == true && pdf?.string?.contains("Annual letter") == true, ".\(ext) keeps the text")
        check(pdf.map { abs($0.page(at: 0)!.bounds(for: .mediaBox).width - 595.28) < 1 } == true, ".\(ext) on A4")
    }
    // Plain text in Windows Latin 1.
    let txt = folder.appendingPathComponent("Notes.txt")
    try? "Café crème — naïve résumé".data(using: .windowsCP1252)!.write(to: txt)
    let out = folder.appendingPathComponent("txt.pdf")
    _ = ckAwait { try await service.convert(ConversionJob(inputs: [txt], output: .pdf, destination: out), progress: .ignored) }
    check(ckText(out).contains("Café crème") && ckText(out).contains("résumé"), "Windows Latin 1 text decoded")
    let links = PDFDocument(url: folder.appendingPathComponent("rtf.pdf"))?.page(at: 0)?.annotations.filter { $0.type == "Link" } ?? []
    check(!links.isEmpty, "links stay clickable")
}

@MainActor
private func convertWeb() {
    let folder = ckFolder()
    let service = ckService(ckHelpers())
    ckImage(folder.appendingPathComponent("logo.png"))
    let rows = (1...150).map { "<tr><td>Row \($0)</td><td>\($0 * 3)</td></tr>" }.joined()
    let html = """
    <html><head><title>Price list</title><style>td { padding: 2px 8px }</style></head><body>
    <h1>Price list</h1><p>Our prices, as of today.</p><img src="logo.png" width="200">
    <img src="https://example.com/tracker.png"><script>document.write('scripted')</script>
    <table>\(rows)</table><p>End of list.</p></body></html>
    """
    let page = folder.appendingPathComponent("Prices.html")
    try? html.write(to: page, atomically: true, encoding: .utf8)
    let out = folder.appendingPathComponent("prices.pdf")
    let result = ckAwait { try await service.convert(ConversionJob(inputs: [page], output: .pdf, paper: .letter, destination: out), progress: .ignored) }
    check(result?.engine == .builtIn(.webKit), "HTML through WebKit")
    let pdf = PDFDocument(url: out)
    check((pdf?.pageCount ?? 0) >= 3, "the long table runs over pages (\(pdf?.pageCount ?? 0))")
    let text = pdf?.string ?? ""
    check(text.contains("Price list") && text.contains("Row 150") && text.contains("End of list."), "text kept and selectable")
    check(!text.contains("scripted"), "page scripts don't run")
    check(pdf?.documentAttributes?[PDFDocumentAttribute.titleAttribute] as? String == "Price list", "the page title becomes the PDF title")
    // No row is cut in two: each "Row n" appears whole on exactly one page.
    let perPage = (0..<(pdf?.pageCount ?? 0)).map { pdf?.page(at: $0)?.string ?? "" }
    check((1...150).allSatisfy { n in perPage.filter { $0.contains("Row \(n)\n") || $0.hasSuffix("Row \(n)") || $0.contains("Row \(n) ") || $0.contains("Row \(n)\t") }.count <= 1 },
          "rows aren't repeated across page breaks")

    // Break points never fall inside a box.
    let breaks = WebRenderer.Paginator.pageBreaks(total: 1000, pageHeight: 300, boxes: [[290, 310], [580, 620], [700, 1000]])
    check(breaks.first == 0 && breaks.last == 1000, "breaks cover the page")
    check(!breaks.contains { b in [[290.0, 310.0], [580, 620]].contains { $0[0] + 0.5 < Double(b) && Double(b) < $0[1] - 0.5 } }, "no break inside a line")

    // SVG and a web archive.
    let svg = folder.appendingPathComponent("Shape.svg")
    try? #"<svg xmlns="http://www.w3.org/2000/svg" width="300" height="200"><rect width="300" height="200" fill="teal"/><text x="20" y="100">Vector label</text></svg>"#
        .write(to: svg, atomically: true, encoding: .utf8)
    let svgOut = folder.appendingPathComponent("svg.pdf")
    _ = ckAwait { try await service.convert(ConversionJob(inputs: [svg], output: .pdf, destination: svgOut), progress: .ignored) }
    check(ckText(svgOut).contains("Vector label"), "SVG text kept")
    let archive = folder.appendingPathComponent("Saved.webarchive")
    let png = (try? Data(contentsOf: folder.appendingPathComponent("logo.png"))) ?? Data()
    let plist: [String: Any] = [
        "WebMainResource": ["WebResourceData": Data("<html><body><h2>Archived page</h2><img src=\"https://example.com/i.png\"></body></html>".utf8),
                            "WebResourceURL": "https://example.com/", "WebResourceMIMEType": "text/html", "WebResourceTextEncodingName": "UTF-8"],
        "WebSubresources": [["WebResourceData": png, "WebResourceURL": "https://example.com/i.png", "WebResourceMIMEType": "image/png"]],
    ]
    try? PropertyListSerialization.data(fromPropertyList: plist, format: .binary, options: 0).write(to: archive)
    let unpacked = try? WebArchive.unpack(archive, into: folder.appendingPathComponent("unpacked"))
    check(unpacked.flatMap { try? String(contentsOf: $0, encoding: .utf8) }?.contains("example.com") == false, "archived pictures point at local copies")
    let archiveOut = folder.appendingPathComponent("archive.pdf")
    _ = ckAwait { try await service.convert(ConversionJob(inputs: [archive], output: .pdf, destination: archiveOut), progress: .ignored) }
    check(ckText(archiveOut).contains("Archived page"), "web archive rendered")
}

@MainActor
private func convertMarkdown() {
    let source = """
    # Trip plan

    Some *emphasis*, **strong** and `code`, plus a [link](https://example.com).

    - Pack bags
      - Socks
    - [x] Book train

    1. Wake up
    2. Leave

    > Quoted words

    | Day | Place |
    |:----|------:|
    | Mon | Paris |

    ```
    let x = 1 < 2
    ```

    Setext title
    ------------
    """
    let html = Markdown.html(source)
    check(html.contains("<h1>Trip plan</h1>") && html.contains("<h2>Setext title</h2>"), "headings")
    check(html.contains("<em>emphasis</em>") && html.contains("<strong>strong</strong>") && html.contains("<code>code</code>"), "inline styles")
    check(html.contains("<a href=\"https://example.com\">link</a>"), "links")
    check(html.contains("<ul>") && html.contains("<li>Socks</li>") && html.contains("<ol>") && html.contains("checkbox"), "lists, nested, tasks")
    check(html.contains("<blockquote>") && html.contains("<table>") && html.contains("text-align:right"), "quote and table")
    check(html.contains("let x = 1 &lt; 2"), "code escaped")

    let folder = ckFolder()
    let md = folder.appendingPathComponent("Plan.md")
    try? source.write(to: md, atomically: true, encoding: .utf8)
    let out = folder.appendingPathComponent("plan.pdf")
    let result = ckAwait { try await ckService(ckHelpers()).convert(ConversionJob(inputs: [md], output: .pdf, destination: out), progress: .ignored) }
    check(result?.engine == .builtIn(.markdown) && ckText(out).contains("Trip plan") && ckText(out).contains("Paris"), "Markdown → PDF")
}

@MainActor
private func convertEPUB() {
    let folder = ckFolder()
    let book = folder.appendingPathComponent("Novel.epub")
    func chapter(_ title: String, _ words: String) -> Data {
        Data("""
        <?xml version="1.0" encoding="UTF-8"?><html xmlns="http://www.w3.org/1999/xhtml"><head><title>\(title)</title></head>
        <body><h1>\(title)</h1><p>\(words)</p></body></html>
        """.utf8)
    }
    ckZip(book, [
        ("mimetype", Data("application/epub+zip".utf8)),
        ("META-INF/container.xml", Data(#"<?xml version="1.0"?><container version="1.0" xmlns="urn:oasis:names:tc:opendocument:xmlns:container"><rootfiles><rootfile full-path="OPS/book.opf" media-type="application/oebps-package+xml"/></rootfiles></container>"#.utf8)),
        ("OPS/book.opf", Data("""
        <?xml version="1.0"?><package xmlns="http://www.idpf.org/2007/opf" version="3.0" unique-identifier="id">
        <metadata xmlns:dc="http://purl.org/dc/elements/1.1/"><dc:title>The Test Novel</dc:title><dc:identifier id="id">x</dc:identifier></metadata>
        <manifest><item id="nav" href="nav.xhtml" media-type="application/xhtml+xml" properties="nav"/>
        <item id="c1" href="text/one.xhtml" media-type="application/xhtml+xml"/><item id="c2" href="text/two.xhtml" media-type="application/xhtml+xml"/></manifest>
        <spine><itemref idref="c1"/><itemref idref="c2"/></spine></package>
        """.utf8)),
        ("OPS/nav.xhtml", Data("""
        <?xml version="1.0"?><html xmlns="http://www.w3.org/1999/xhtml" xmlns:epub="http://www.idpf.org/2007/ops"><body>
        <nav epub:type="toc"><ol><li><a href="text/one.xhtml">Beginnings</a></li><li><a href="text/two.xhtml#top">Endings</a></li></ol></nav></body></html>
        """.utf8)),
        ("OPS/text/one.xhtml", chapter("One", "It was a dark and stormy night.")),
        ("OPS/text/two.xhtml", chapter("Two", "And they lived happily ever after.")),
    ], storedFirst: true)
    let out = folder.appendingPathComponent("novel.pdf")
    _ = ckAwait { try await ckService(ckHelpers()).convert(ConversionJob(inputs: [book], output: .pdf, destination: out), progress: .ignored) }
    let pdf = PDFDocument(url: out)
    check((pdf?.pageCount ?? 0) >= 2 && pdf?.string?.contains("stormy night") == true && pdf?.string?.contains("happily ever after") == true,
          "chapters rendered in spine order")
    let titles = (0..<(pdf?.outlineRoot?.numberOfChildren ?? 0)).compactMap { pdf?.outlineRoot?.child(at: $0)?.label }
    check(titles == ["Beginnings", "Endings"], "a contents entry per chapter from the book's contents (got \(titles))")
}

@MainActor
private func convertMail() {
    let folder = ckFolder()
    ckImage(folder.appendingPathComponent("photo.png"))
    let png = ((try? Data(contentsOf: folder.appendingPathComponent("photo.png"))) ?? Data()).base64EncodedString(options: .lineLength76Characters)
    let eml = """
    From: =?utf-8?B?SsO8cmdlbg==?= <jurgen@example.com>\r
    To: Ana <ana@example.com>\r
    Subject: =?iso-8859-1?Q?Caf=E9_tomorrow?=\r
    Date: Tue, 6 Oct 2026 09:30:00 +0200\r
    MIME-Version: 1.0\r
    Content-Type: multipart/mixed; boundary="outer"\r
    \r
    --outer\r
    Content-Type: multipart/alternative; boundary="inner"\r
    \r
    --inner\r
    Content-Type: text/plain; charset=utf-8\r
    \r
    Plain version.\r
    --inner\r
    Content-Type: text/html; charset=utf-8\r
    Content-Transfer-Encoding: quoted-printable\r
    \r
    <html><body><p>See you at the caf=C3=A9 at nine, soft=\r
    ly.</p></body></html>\r
    --inner--\r
    --outer\r
    Content-Type: image/png; name="photo.png"\r
    Content-Disposition: attachment; filename="photo.png"\r
    Content-Transfer-Encoding: base64\r
    \r
    \(png)\r
    --outer\r
    Content-Type: text/csv; name="list.csv"\r
    Content-Disposition: attachment; filename="list.csv"\r
    \r
    a,b\r
    --outer--\r
    """
    let url = folder.appendingPathComponent("Invite.eml")
    try? eml.write(to: url, atomically: true, encoding: .utf8)
    check(MIMEPart.decodeWords("=?utf-8?B?SsO8cmdlbg==?= <j@x>") == "Jürgen <j@x>", "encoded words")
    let out = folder.appendingPathComponent("mail.pdf")
    let result = ckAwait { try await ckService(ckHelpers()).convert(ConversionJob(inputs: [url], output: .pdf, destination: out), progress: .ignored) }
    check(result?.engine == .builtIn(.mail), "mail built in")
    let text = ckText(out)
    check(text.contains("Café tomorrow") && text.contains("Jürgen") && text.contains("café at nine, softly."), "headers and the HTML body (got \(text.prefix(80)))")
    check(!text.contains("Plain version."), "the HTML alternative wins")
    check(ckPages(out) >= 2, "the attached picture becomes a page")
    let embedded = (try? PDFModel(url: out))?.embeddedFiles().map(\.fileName) ?? []
    check(embedded == ["list.csv"], "other attachments ride along (got \(embedded))")
}

@MainActor
private func convertHWPX() {
    let folder = ckFolder()
    let url = folder.appendingPathComponent("보고서.hwpx")
    let ns = #"xmlns:hp="http://www.hancom.co.kr/hwpml/2011/paragraph" xmlns:hs="http://www.hancom.co.kr/hwpml/2011/section""#
    ckZip(url, [
        ("mimetype", Data("application/hwp+zip".utf8)),
        ("Contents/content.hpf", Data(#"<?xml version="1.0"?><opf:package xmlns:opf="http://www.idpf.org/2007/opf/"><opf:manifest><opf:item id="section0" href="Contents/section0.xml" media-type="application/xml"/></opf:manifest><opf:spine><opf:itemref idref="section0"/></opf:spine></opf:package>"#.utf8)),
        ("Contents/header.xml", Data(##"<?xml version="1.0"?><hh:head xmlns:hh="http://www.hancom.co.kr/hwpml/2011/head"><hh:charProperties><hh:charPr id="0" height="1000" textColor="#000000"/><hh:charPr id="1" height="1600" textColor="#000000"><hh:bold/></hh:charPr></hh:charProperties><hh:paraProperties><hh:paraPr id="0"><hh:align horizontal="CENTER"/></hh:paraPr></hh:paraProperties></hh:head>"##.utf8)),
        ("Contents/section0.xml", Data("""
        <?xml version="1.0"?><hs:sec \(ns)>
        <hp:p paraPrIDRef="0"><hp:run charPrIDRef="1"><hp:t>분기 보고서</hp:t></hp:run></hp:p>
        <hp:p><hp:run charPrIDRef="0"><hp:t>첫 번째 문단<hp:tab/>입니다.</hp:t></hp:run></hp:p>
        <hp:p><hp:run><hp:tbl><hp:tr><hp:tc><hp:subList><hp:p><hp:run><hp:t>매출</hp:t></hp:run></hp:p></hp:subList></hp:tc>
        <hp:tc><hp:subList><hp:p><hp:run><hp:t>1,200</hp:t></hp:run></hp:p></hp:subList></hp:tc></hp:tr></hp:tbl></hp:run></hp:p>
        </hs:sec>
        """.utf8)),
    ], storedFirst: true)
    let out = folder.appendingPathComponent("hwpx.pdf")
    let report = try? HWPXImporter.convert(url, to: out, options: ImportOptions())
    let text = ckText(out)
    check(report != nil && text.contains("분기 보고서") && text.contains("첫 번째 문단") && text.contains("매출") && text.contains("1,200"),
          "our .hwpx reader keeps paragraphs and tables (got \(text.prefix(60)))")
    // Without LibreOffice the service picks our reader.
    let viaService = folder.appendingPathComponent("service.pdf")
    let result = ckAwait { try await ckService(ckHelpers()).convert(ConversionJob(inputs: [url], output: .pdf, destination: viaService), progress: .ignored) }
    check(result?.engine == .builtIn(.hwpx), ".hwpx without LibreOffice: built in")
    let hwp = folder.appendingPathComponent("old.hwp")
    try? Data("HWP Document File".utf8).write(to: hwp)
    let error = ckError { try await ckService(ckHelpers()).convert(ConversionJob(inputs: [hwp], output: .pdf, destination: viaService), progress: .ignored) }
    check((error as? ToolError)?.message.action?.id == ConvertAction.getLibreOffice, ".hwp needs LibreOffice: Get LibreOffice")
}

@MainActor
private func convertIWork() {
    let folder = ckFolder()
    let service = ckService(ckHelpers())
    ckImage(folder.appendingPathComponent("preview.jpg"), size: CGSize(width: 600, height: 800), type: .jpeg)
    let jpeg = (try? Data(contentsOf: folder.appendingPathComponent("preview.jpg"))) ?? Data()
    let zipped = folder.appendingPathComponent("Letter.pages")
    ckZip(zipped, [("Index/Document.iwa", Data([1, 2, 3])), ("preview.jpg", jpeg)])
    let out = folder.appendingPathComponent("pages.pdf")
    let result = ckAwait { try await service.convert(ConversionJob(inputs: [zipped], output: .pdf, destination: out), progress: .ignored) }
    check(result?.engine == .builtIn(.iWorkPreview) && ckPages(out) == 1, "Pages missing: the preview picture")
    check(result?.notices == ["Only the preview inside “Letter.pages” could be used, which is usually the first page."], "with a notice")

    // An older package folder with the whole document as QuickLook/Preview.pdf.
    let package = folder.appendingPathComponent("Old.key", isDirectory: true)
    try? FileManager.default.createDirectory(at: package.appendingPathComponent("QuickLook"), withIntermediateDirectories: true)
    try? makePDF(pages: 4).write(to: package.appendingPathComponent("QuickLook/Preview.pdf"))
    let keyOut = folder.appendingPathComponent("key.pdf")
    let keyResult = ckAwait { try await service.convert(ConversionJob(inputs: [package], output: .pdf, destination: keyOut), progress: .ignored) }
    check(ckPages(keyOut) == 4 && keyResult?.notices.isEmpty == true, "the whole document when the file holds a PDF preview")
}

@MainActor
private func convertImages() {
    let folder = ckFolder()
    let png = folder.appendingPathComponent("a.png"), jpeg = folder.appendingPathComponent("b.jpg"), tiff = folder.appendingPathComponent("c.tiff")
    ckImage(png)
    ckImage(jpeg, size: CGSize(width: 400, height: 200), type: .jpeg, orientation: 6)
    ckTIFF(tiff)
    let out = folder.appendingPathComponent("images.pdf")
    let report = try? ImageImporter.convert([png, jpeg, tiff], to: out, options: ImportOptions(paper: .fitContent))
    let pdf = PDFDocument(url: out)
    check(report != nil && pdf?.pageCount == 4, "one page per picture, the TIFF's two pages expanded")
    let sizes = (0..<(pdf?.pageCount ?? 0)).map { pdf!.page(at: $0)!.bounds(for: .mediaBox).size }
    check(sizes.first == CGSize(width: 400, height: 200), "fit: the page is the picture's size")
    check(sizes.count > 1 && sizes[1] == CGSize(width: 200, height: 400), "EXIF orientation applied (portrait)")
    let a4 = folder.appendingPathComponent("a4.pdf")
    _ = try? ImageImporter.convert([png], to: a4, options: ImportOptions(paper: .a4, margins: 36))
    let a4Size = PDFDocument(url: a4)?.page(at: 0)?.bounds(for: .mediaBox).size ?? .zero
    check(abs(a4Size.width - 841.89) < 1 && abs(a4Size.height - 595.28) < 1, "A4, turned to landscape for a wide picture")
    let broken = folder.appendingPathComponent("broken.png")
    try? Data("nope".utf8).write(to: broken)
    let mixed = try? ImageImporter.convert([png, broken], to: folder.appendingPathComponent("mixed.pdf"), options: ImportOptions())
    check(mixed?.skipped == [broken] && mixed?.notices.first?.contains("“broken.png”") == true, "unreadable pictures are left out and named")
}

@MainActor
private func convertStructuredText() {
    let json = #"{"zeta":1,"alpha":[1,2,{"b":true}],"empty":{},"text":"a, b: {c}"}"#
    let pretty = StructuredTextImporter.prettyJSON(json)
    check(pretty.hasPrefix("{\n  \"zeta\": 1,\n  \"alpha\": [") && pretty.contains("\"empty\": {}") && pretty.contains("\"a, b: {c}\""),
          "JSON re-indented, key order and strings kept")
    check(StructuredTextImporter.prettyJSON("not json {") == "not json {", "not JSON: unchanged")
    check(StructuredTextImporter.prettyXML("<a><b>1</b></a>").contains("\n"), "XML re-indented")
    let folder = ckFolder()
    let url = folder.appendingPathComponent("data.json")
    try? json.write(to: url, atomically: true, encoding: .utf8)
    let out = folder.appendingPathComponent("json.pdf")
    _ = ckAwait { try await ckService(ckHelpers()).convert(ConversionJob(inputs: [url], output: .pdf, destination: out), progress: .ignored) }
    check(ckText(out).contains("\"alpha\""), "JSON → PDF")
}

@MainActor
private func convertZipToPDF() {
    let folder = ckFolder()
    ckImage(folder.appendingPathComponent("p.png"))
    let inner = folder.appendingPathComponent("inner.zip")
    ckZip(inner, [("deep.txt", Data("Deep inside".utf8))])
    let url = folder.appendingPathComponent("Bundle.zip")
    ckZip(url, [
        ("b-notes.txt", Data("Notes in the archive".utf8)),
        ("a-picture.png", (try? Data(contentsOf: folder.appendingPathComponent("p.png"))) ?? Data()),
        ("c-unknown.qqq", Data([0, 1, 2])),
        ("d-inner.zip", (try? Data(contentsOf: inner)) ?? Data()),
        ("__MACOSX/._junk", Data([0])),
    ])
    let out = folder.appendingPathComponent("zip.pdf")
    let result = ckAwait { try await ckService(ckHelpers()).convert(ConversionJob(inputs: [url], output: .pdf, destination: out), progress: .ignored) }
    let pdf = PDFDocument(url: out)
    check(pdf?.string?.contains("Notes in the archive") == true && pdf?.string?.contains("Deep inside") == true, "members and a ZIP inside a ZIP")
    let titles = (0..<(pdf?.outlineRoot?.numberOfChildren ?? 0)).compactMap { pdf?.outlineRoot?.child(at: $0)?.label }
    check(titles == ["a-picture", "b-notes", "d-inner"], "a contents entry per file, in name order (got \(titles))")
    check(result?.notices.contains { $0.contains("“c-unknown.qqq”") } == true, "the file that can't be converted is named")
}

@MainActor
private func convertQuickLook() {
    let folder = ckFolder()
    let url = folder.appendingPathComponent("script.swift")
    try? "let greeting = \"Hello from Quick Look\"\nprint(greeting)\n".write(to: url, atomically: true, encoding: .utf8)
    let out = folder.appendingPathComponent("ql.pdf")
    switch complete(60, { try await ckService(ckHelpers()).convert(ConversionJob(inputs: [url], output: .pdf, destination: out), progress: .ignored) }) {
    case .success(let result)?:
        check(result.engine == .builtIn(.quickLook) && ckPages(out) == 1, "Quick Look's picture of the first page")
        check(result.notices == [ConvertStrings.quickLookNotice], "with the notice")
    case .failure(let error)?:
        // Some Macs have no generator for a type; then the file can't be converted and the panel says so.
        check((error as? ToolError) != nil, "a failed preview is the panel's error: \(error)")
    case nil:
        check(false, "Quick Look timed out")
    }
}

// MARK: - Out of PDF

@MainActor
private func convertTextExports() {
    installFakes()
    LayoutKitModule.install()
    let folder = ckFolder()
    let source = folder.appendingPathComponent("Report.pdf")
    ckSourcePDF(source)
    let service = ckService(ckHelpers())
    func run(_ format: ConversionFormat, _ name: String) -> URL {
        let out = folder.appendingPathComponent(name)
        _ = ckAwait { try await service.convert(ConversionJob(inputs: [source], output: format, destination: out), progress: .ignored) }
        return out
    }
    let text = (try? String(contentsOf: run(.text, "Report.txt"), encoding: .utf8)) ?? ""
    check(text.contains("Orchards in spring") && text.contains("about pears, plums") && text.contains("Harvest and storage"), "PDF → text in reading order")
    let html = (try? String(contentsOf: run(.html, "Report.html"), encoding: .utf8)) ?? ""
    check(html.contains("<h1>Orchards in spring</h1>") && html.contains("<p>"), "PDF → HTML with structure")
    check(html.contains("data:image/jpeg;base64,"), "pictures inline in the web page")

    let epub = run(.epub, "Report.epub")
    guard let archive = try? ZipArchive(url: epub) else { check(false, "the EPUB is a ZIP"); return }
    check(archive.entries.first?.path == "mimetype" && archive.entries.first?.method == 0, "mimetype first and stored")
    check((try? archive.data("mimetype")).flatMap { $0 }.map { String(decoding: $0, as: UTF8.self) } == "application/epub+zip", "EPUB mimetype")
    let opf = (try? archive.data("OEBPS/content.opf")).flatMap { $0 }.flatMap { try? XML.parse($0) }
    let spine = opf?.first("spine")?.children("itemref").count ?? 0
    check(spine == 2, "a chapter per main heading (got \(spine))")
    let manifest = opf?.all("item").compactMap { $0.attr("href") } ?? []
    check(manifest.allSatisfy { (try? archive.data("OEBPS/" + $0)) ?? nil != nil }, "every manifest item is in the package")
    for href in manifest where href.hasSuffix(".xhtml") {
        let parsed = (try? archive.data("OEBPS/" + href)).flatMap { $0 }.flatMap { try? XML.parse($0) }
        check(parsed != nil, "\(href) is well-formed XHTML")
    }
    let roundTrip = folder.appendingPathComponent("roundtrip.pdf")
    _ = ckAwait { try await service.convert(ConversionJob(inputs: [epub], output: .pdf, destination: roundTrip), progress: .ignored) }
    check(ckText(roundTrip).contains("how they grow on old trees"), "our EPUB reads back through our EPUB importer")
    installFakes()
}

@MainActor
private func convertImageExports() {
    let folder = ckFolder()
    let source = folder.appendingPathComponent("Report.pdf")
    ckSourcePDF(source, pages: 3)
    var options = ExportOptions(format: .png)
    options.pages = [0, 2]
    let pngs = (try? ImageExport.export(.file(source), options: options, folder: folder.appendingPathComponent("png"), baseName: "Report", progress: .ignored)) ?? []
    check(pngs.map(\.lastPathComponent) == ["Report – page 1.png", "Report – page 3.png"], "one file per page, named by page")
    let size = pngs.first.flatMap { CGImageSourceCreateWithURL($0 as CFURL, nil) }.flatMap { CGImageSourceCopyPropertiesAtIndex($0, 0, nil) as? [CFString: Any] }
    check((size?[kCGImagePropertyPixelWidth] as? Int) == 1275, "150 dpi by default (612 pt → 1275 px)")
    options = ExportOptions(format: .tiff)
    options.multiPageTIFF = true
    options.dpi = 72
    let tiff = (try? ImageExport.export(.file(source), options: options, folder: folder.appendingPathComponent("tiff"), baseName: "Report", progress: .ignored)) ?? []
    check(tiff.count == 1 && tiff.first.flatMap { CGImageSourceCreateWithURL($0 as CFURL, nil) }.map(CGImageSourceGetCount) == 3, "one multi-page TIFF")
    options = ExportOptions(format: .jpeg)
    options.embeddedPictures = true
    let pictures = (try? ImageExport.export(.file(source), options: options, folder: folder.appendingPathComponent("pictures"), baseName: "Report", progress: .ignored)) ?? []
    check(!pictures.isEmpty && pictures[0].lastPathComponent.hasPrefix("Report – page 1 – picture 1."), "the pictures inside, at their own size")
    if let first = pictures.first, let image = CGImageSourceCreateWithURL(first as CFURL, nil), let props = CGImageSourceCopyPropertiesAtIndex(image, 0, nil) as? [CFString: Any] {
        check((props[kCGImagePropertyPixelWidth] as? Int) == 120, "native resolution kept")
    }
}

// MARK: - Panels and runs

@MainActor
private func convertPanels() {
    installFakes()
    let recorder = Recorder()
    let provider = ConvertToolProvider(service: ckService(ckHelpers(apps: [.word], recorder: recorder)), appName: { _ in "Word" })
    check(Set(provider.tools) == Set(ToolCatalog.tiles(ownedBy: .convertKit).map(\.id)), "serves every Convert tile")
    let document = makeDocument(pages: 3)

    let word = ToolSession(tool: .toWord, provider: provider, document: document)
    check(word.panel.primary.title == "Save as Word…" && word.panel.output == .sameName(ext: "docx") && word.panel.showsScope, "To Word panel")
    check(word.panel.controls.contains { if case .note(let text) = $0 { text == "Converted by: the built-in converter" } else { false } }, "names the engine")
    check(word.panel.controls.contains { if case .note(let text) = $0 { text == "3 pages are pictures — text will be recognised first" } else { false } } == false,
          "pages with text aren't called pictures")
    word.set("format", .string("rtf"))
    check(word.panel.primary.title == "Save as rich text…" && word.panel.output == .sameName(ext: "rtf"), "rich text")

    let blank = DocumentHandle(url: nil, displayName: "Scan", pdf: { let d = PDFDocument(); d.insert(PDFPage(), at: 0); d.insert(PDFPage(), at: 1); return d }())
    let scanned = ToolSession(tool: .toWord, provider: provider, document: blank)
    check(scanned.panel.controls.contains { if case .note(let text) = $0 { text == "2 pages are pictures — text will be recognised first" } else { false } },
          "scanned pages are announced")

    let excel = ToolSession(tool: .toExcel, provider: provider, document: document)
    check(excel.panel.primary.title == "Save as Excel…" && excel.panel.controls.contains { $0.id == "one-sheet-per-table" }, "To Excel panel")
    excel.set("format", .string("csv"))
    check(excel.panel.primary.title == "Save as CSV…" && !excel.panel.controls.contains { $0.id == "one-sheet-per-table" }, "CSV has one table stream")

    let images = ToolSession(tool: .toImages, provider: provider, document: document)
    check(images.panel.archetype == .presetAndMore && images.panel.primary.title == "Save images…" && images.panel.output == .folder(.images), "To images panel")
    _ = complete { await images.perform(ConvertAction.pictures) }
    check(images.values.bool("pictures-inside") && images.panel.controls.contains { $0.id == ConvertAction.pictures }, "the pictures inside, and back")

    let archive = ToolSession(tool: .forArchiving, provider: provider, document: document)
    if case .radio(_, let options, let selected)? = archive.panel.controls.first {
        check(options.map(\.title) == ["PDF/A-2b (recommended)", "PDF/A-1b (oldest readers)", "PDF/A-3b (keeps attachments)"] && selected == "2b",
              "the three PDF/A presets of ux §5.3")
    } else {
        check(false, "For archiving starts with its presets")
    }
    check(archive.panel.primary.title == "Save archive copy" && archive.panel.output == .sibling(.archive, ext: "pdf"), "archive copy next to the original")

    // Any file → PDF explains what's missing and offers what helps.
    let folder = ckFolder()
    let ods = folder.appendingPathComponent("Budget.ods"), pages = folder.appendingPathComponent("Letter.pages"), docx = folder.appendingPathComponent("Memo.docx")
    for url in [ods, pages, docx] { try? Data("x".utf8).write(to: url) }
    let any = ToolSession(tool: .anyFileToPDF, provider: provider, document: nil, inputs: [ods])
    check(any.message?.text == Strings.Errors.needsLibreOffice(kind: "Spreadsheets", fileExtension: "ods") && !any.canRun, "needs LibreOffice: explained, can't run")
    check(any.message?.action?.title == "Get LibreOffice", "with Get LibreOffice")
    _ = complete { await any.perform(ConvertAction.getLibreOffice) }
    check(recorder.urls.last == LibreOffice.downloadPage, "Get LibreOffice opens the download page (fake opener)")

    let iWork = ToolSession(tool: .anyFileToPDF, provider: provider, document: nil, inputs: [pages])
    check(iWork.message?.text == Strings.Errors.iWorkMissing(.pages) && iWork.message?.action?.title == "Get Pages" && iWork.canRun,
          "Pages missing: the preview, with Get Pages")
    _ = complete { await iWork.perform(ConvertAction.getApp(.pages)) }
    check(recorder.urls.last?.host == "apps.apple.com", "Get Pages opens the App Store page (fake opener)")

    let memo = ToolSession(tool: .anyFileToPDF, provider: provider, document: nil, inputs: [docx])
    check(memo.message?.text == Strings.Errors.needsOfficeApp(.word) && memo.message?.action?.title == "Use Word", "Word on this Mac is offered")
    _ = complete { await memo.perform(ConvertAction.useApp(.word)) }
    check(memo.panel.controls.contains { if case .note(let text) = $0 { text == "Microsoft Word will open to export this file" } else { false } },
          "Word's engine line once chosen")
    check(memo.message?.action?.title == Strings.Errors.useBuiltInConverter, "and the way back")
    check(memo.panel.primary.title == "Make PDF" && memo.panel.output == .newDocument(name: "Memo"), "Make PDF, a new document")

    let pictures = ToolSession(tool: .imagesToPDF, provider: provider, document: nil, inputs: [])
    check(!pictures.canRun, "Images → PDF waits for pictures")
    pictures.set("paper", .string("a4"))
    check(pictures.panel.controls.contains { $0.id == "margins" }, "margins with a paper size")
    for session in [word, excel, images, archive, any, iWork, memo, pictures] {
        check(session.panel.controls.filter(\.isChoice).count <= 3, "\(session.tool.rawValue): at most three choices")
    }
}

@MainActor
private func convertRuns() {
    installFakes()
    LayoutKitModule.install()
    let folder = ckFolder()
    let source = folder.appendingPathComponent("Report.pdf")
    ckSourcePDF(source)
    let document = DocumentHandle(url: source, pdf: PDFDocument(url: source)!, undoManager: makeUndoManager())
    let provider = ConvertToolProvider(service: ckService(ckHelpers()), appName: { _ in "TextEdit" })
    func request(_ tool: ToolID, _ values: ToolValues = ToolValues(), destination: String? = nil, inputs: [URL] = []) -> ToolRequest {
        ToolRequest(tool: tool, document: inputs.isEmpty ? document : nil, source: inputs.isEmpty ? document.snapshot() : nil,
                    pages: inputs.isEmpty ? [0, 1] : [], values: values, inputs: inputs,
                    destination: destination.map { folder.appendingPathComponent($0) }, workFolder: SuperPDFPaths.ensure(ckFolder()))
    }

    let text = ckAwait { try await provider.run(request(.toTextOrWeb, ToolValues(["format": .string("text")]), destination: "Report.txt"), progress: .ignored) }
    if case .newFile(let file, let banner)? = text {
        check(file.lastPathComponent == "Report.txt" && ((try? String(contentsOf: file, encoding: .utf8)) ?? "").contains("apples"), "To text writes the file")
        check(banner.text == "Saved “Report.txt”." && banner.actions == [.openIn(appName: "TextEdit"), .showInFinder], "Saved banner (ux §7.3)")
    } else {
        check(false, "To text gives a new file")
    }

    let images = ckAwait { try await provider.run(request(.toImages, ToolValues(["format": .string("jpeg"), "quality": .string("screen")]),
                                                          destination: "Report images"), progress: .ignored) }
    if case .newFiles(let files, let banner)? = images {
        check(files.count == 2 && files.allSatisfy { $0.pathExtension == "jpg" }, "two JPEGs for two pages")
        check(banner.text == "Saved 2 images in “Report images”.", "images banner (ux §7.3)")
    } else {
        check(false, "To images gives files")
    }

    let archived = ckAwait { try await provider.run(request(.forArchiving, ToolValues(["level": .string("2b")]), destination: "Report (archive).pdf"), progress: .ignored) }
    if case .newFile(let file, let banner)? = archived {
        check(PDFDocument(url: file) != nil, "the archive copy opens")
        check(banner.text == "Saved “Report (archive).pdf”. It passes the PDF/A-2b check.", "archive banner (got \(banner.text))")
    } else {
        check(false, "For archiving gives a new file")
    }

    let png = folder.appendingPathComponent("photo.png")
    ckImage(png)
    let made = ckAwait { try await provider.run(request(.imagesToPDF, ToolValues(["paper": .string("letter")]), inputs: [png]), progress: .ignored) }
    if case .newDocument(let data, let name, _)? = made {
        check(PDFDocument(data: data)?.pageCount == 1 && name == "photo", "Images → PDF: a new document named after the picture")
    } else {
        check(false, "Images → PDF gives a new document")
    }
    let txt = folder.appendingPathComponent("a.txt"), md = folder.appendingPathComponent("b.md")
    try? "Alpha".write(to: txt, atomically: true, encoding: .utf8)
    try? "# Beta".write(to: md, atomically: true, encoding: .utf8)
    let combined = ckAwait { try await provider.run(request(.anyFileToPDF, inputs: [txt, md]), progress: .ignored) }
    if case .newDocument(let data, let name, _)? = combined {
        let pdf = PDFDocument(data: data)
        check(name == "Combined" && pdf?.string?.contains("Alpha") == true && pdf?.string?.contains("Beta") == true, "Any file → PDF joins the files")
        check(pdf?.outlineRoot?.numberOfChildren == 2 && pdf?.pageCount == 2, "a contents entry per file, a page each")
    } else {
        check(false, "Any file → PDF gives a new document")
    }
    installFakes()
}

// MARK: - For archiving, the PDF/A check, data exports

// ConvertKit's For archiving (features #56, #57), the PDF/A check (#93) and form/comment data exports (#59), on PDFs
// made here with Quartz and PDFModelKit.
func registerConvertKitArchiveTests() {
    SelfTest.cases.append(("ConvertKit.archive.pdfaLevels", { archivePDFALevels() }))
    SelfTest.cases.append(("ConvertKit.archive.accessibleLevels", { archiveAccessibleLevels() }))
    SelfTest.cases.append(("ConvertKit.archive.verifierKnownBad", { archiveVerifierKnownBad() }))
    SelfTest.cases.append(("ConvertKit.archive.transparencyPart1", { archiveTransparencyPart1() }))
    SelfTest.cases.append(("ConvertKit.archive.pdfx", { archivePDFX() }))
    SelfTest.cases.append(("ConvertKit.archive.dataExport", { archiveDataExport() }))
}

// MARK: - Fixtures

private func archiveFolder() -> URL {
    SuperPDFPaths.ensure(FileManager.default.temporaryDirectory.appendingPathComponent("superpdf-archive-tests-\(UUID().uuidString)", isDirectory: true))
}

/// Quartz pages saying "Archive page n", optionally drawn half see-through.
private func archiveQuartzPDF(pages: Int, alpha: CGFloat = 1) -> Data {
    let data = NSMutableData()
    var box = CGRect(x: 0, y: 0, width: 612, height: 792)
    let info = [kCGPDFContextTitle: "Archive fixture", kCGPDFContextAuthor: "Self-test"] as CFDictionary
    guard let consumer = CGDataConsumer(data: data as CFMutableData), let context = CGContext(consumer: consumer, mediaBox: &box, info) else { return Data() }
    for n in 1...pages {
        context.beginPDFPage(nil)
        context.setAlpha(alpha)
        context.setFillColor(CGColor(srgbRed: 0.2, green: 0.4, blue: 0.8, alpha: 1))
        context.fill(CGRect(x: 72, y: 500, width: 200, height: 100))
        let line = CTLineCreateWithAttributedString(NSAttributedString(string: "Archive page \(n)", attributes: [.font: NSFont.systemFont(ofSize: 24)]))
        context.textPosition = CGPoint(x: 72, y: 700)
        CTLineDraw(line, context)
        context.endPDFPage()
    }
    context.closePDF()
    return data as Data
}

/// Two Quartz pages with a two-entry outline and an XML attachment.
private func archiveSource() throws -> Data {
    let model = try PDFModel(data: archiveQuartzPDF(pages: 2))
    model.setOutlines([PDFOutlineItem(title: "First", destination: PDFDestination(page: 0)),
                       PDFOutlineItem(title: "Second", destination: PDFDestination(page: 1))])
    model.addEmbeddedFile(Data("<invoice total=\"12\"/>".utf8), name: "invoice.xml", mimeType: "application/xml")
    return try model.data()
}

/// A page whose text uses Helvetica without the font program (the classic not-embedded font).
private func archiveUnembeddedFontPDF() throws -> Data {
    let model = PDFModel()
    let page = try model.addBlankPage(size: CGSize(width: 612, height: 792))
    let font = model.makeIndirect(.dictionary(["Type": .name("Font"), "Subtype": .name("Type1"), "BaseFont": .name("Helvetica"),
                                               "Encoding": .name("WinAnsiEncoding")]))
    page.object.set("Resources", .dictionary(["Font": .dictionary(["F1": font.reference!])]))
    page.setContentData(Data("BT /F1 24 Tf 72 700 Td (Hello archive) Tj ET".utf8))
    return try model.data()
}

private func archiveRules(_ problems: [PDFAProblem]) -> Set<String> { Set(problems.map(\.rule)) }

private func archiveText(_ url: URL) -> String {
    guard let document = PDFDocument(url: url) else { return "" }
    return (0..<document.pageCount).compactMap { document.page(at: $0)?.string }.joined(separator: "\n")
}

// MARK: - PDF/A

@MainActor
private func archivePDFALevels() {
    let folder = archiveFolder()
    defer { try? FileManager.default.removeItem(at: folder) }
    do {
        let source = PDFSource.data(try archiveSource())
        for level in [PDFALevel.a2b, .a1b, .a3b, .a2u] {
            let url = folder.appendingPathComponent("archive-\(level.rawValue).pdf")
            let problems = try ArchiveWriter.writePDFA(source, level: level, to: url)
            check(problems.isEmpty, "\(level.title): the result passes (\(problems.map(\.rule)))")
            let again = try PDFAVerifier.verify(.file(url), level: level)
            check(again.isEmpty, "\(level.title): re-verify passes")
            check(PDFDocument(url: url)?.pageCount == 2, "\(level.title): PDFKit opens both pages")
            check(archiveText(url).contains("Archive page 2"), "\(level.title): text still extractable")
            let model = try PDFModel(url: url)
            check(model.outlines().map(\.title) == ["First", "Second"] && model.outlines().map { $0.destination?.page } == [0, 1],
                  "\(level.title): outline kept")
            check(model.info("Producer") == Strings.appName && model.info("Title") == "Archive fixture", "\(level.title): /Info")
            if case .found(let part, let conformance, let filtered) = ArchiveXMP.identification(of: model) {
                check(part == level.archivePart && conformance == level.archiveConformance, "\(level.title): pdfaid")
                if level.archivePart == 1 { check(!filtered, "PDF/A-1 metadata stream is not compressed") }
            } else {
                check(false, "\(level.title): XMP identification")
            }
            let files = model.embeddedFiles()
            if level == .a3b {
                check(files.count == 1 && files.first?.relationship == "Unspecified" && files.first?.mimeType == "application/xml"
                      && model.root["AF"]?.count == 1, "PDF/A-3b keeps the attachment with AFRelationship")
                check((try? model.embeddedFileData(named: "invoice.xml")) == Data("<invoice total=\"12\"/>".utf8), "attachment bytes kept")
            } else {
                check(files.isEmpty, "\(level.title) drops attachments")
            }
            if level.archivePart == 1 {
                check(model.pages.allSatisfy { $0.object["Group"] == nil }, "PDF/A-1: no transparency groups")
            }
        }
        // The accessible levels need tags this untagged source doesn't have.
        let tagged = folder.appendingPathComponent("archive-2a.pdf")
        let problems = try ArchiveWriter.writePDFA(source, level: .a2a, to: tagged)
        check(archiveRules(problems) == ["tags"], "PDF/A-2a of an untagged file: only tags are missing (\(archiveRules(problems)))")
        check(problems.first?.message == ArchiveCopy.tags(.a2a), "tags copy")
    } catch {
        check(false, "PDF/A writing failed: \(error)")
    }
}

/// The archive fixture tagged: each page's content marked as a paragraph (MCID 0), a Document → P tree, a language.
private func archiveTaggedSource() throws -> Data {
    let model = try PDFModel(data: try archiveSource())
    for page in model.pages {
        page.setContentData(Data("/P <</MCID 0>> BDC\n".utf8) + (try page.contentData()) + Data("\nEMC\n".utf8))
    }
    try model.setStructureTree(PDFStructureTree(elements: [PDFStructureElement(type: "Document", kids: (0..<2).map { index in
        .element(PDFStructureElement(type: "P", page: index, kids: [.markedContent(page: index, mcid: 0)]))
    })]))
    model.root.set("Lang", .text("en-GB"))
    return try model.data()
}

/// The accessible "a" levels keep a tagged file's pages and tags (no re-render); they are offered only for tagged files.
@MainActor
private func archiveAccessibleLevels() {
    let folder = archiveFolder()
    defer { try? FileManager.default.removeItem(at: folder) }
    guard let taggedData = try? archiveTaggedSource(), let plain = try? archiveSource() else { check(false, "tagged fixture"); return }
    check(ArchiveWriter.isTagged(.data(taggedData)) && !ArchiveWriter.isTagged(.data(plain)), "tagged files are told apart")
    for level in [PDFALevel.a2a, .a1a, .a3a] {
        let url = folder.appendingPathComponent("archive-\(level.rawValue).pdf")
        do {
            let problems = try ArchiveWriter.writePDFA(.data(taggedData), level: level, to: url)
            check(problems.isEmpty, "\(level.title) of a tagged file passes (\(archiveRules(problems)))")
            let model = try PDFModel(url: url)
            let marked = model.pages.allSatisfy { (try? $0.contentStream().markedContent.contains { $0.mcid == 0 }) == true }
            check(marked, "\(level.title): the pages keep their marked content")
            let tree = model.structureTree()
            check(tree?.elements.first?.type == "Document" && tree?.elements.first?.kids.count == 2, "\(level.title): the tags are kept")
            check(model.root["MarkInfo"]?["Marked"]?.bool == true && model.root["Lang"]?.value == .text("en-GB"), "\(level.title): marked, language kept")
            if case .found(let part, let conformance, _) = ArchiveXMP.identification(of: model) {
                check(part == level.archivePart && conformance == "A", "\(level.title): pdfaid says A")
            } else { check(false, "\(level.title): XMP identification") }
            check(model.outlines().map(\.title) == ["First", "Second"], "\(level.title): outline kept")
            check(level == .a3a ? model.embeddedFiles().first?.relationship == "Unspecified" : model.embeddedFiles().isEmpty,
                  "\(level.title): attachments as the level allows")
            check(archiveText(url).contains("Archive page 2"), "\(level.title): text extractable")
        } catch { check(false, "\(level.title) failed: \(error)") }
    }

    // The panel offers the "a" levels once it knows the file is tagged, and saves with them.
    let taggedURL = folder.appendingPathComponent("Tagged.pdf"), plainURL = folder.appendingPathComponent("Plain.pdf")
    try? taggedData.write(to: taggedURL)
    try? plain.write(to: plainURL)
    let provider = ConvertToolProvider(service: ckService(ckHelpers()), appName: { _ in nil })
    func otherStandards(_ url: URL) -> [String] {
        let document = DocumentHandle(url: url, pdf: PDFDocument(url: url)!, undoManager: makeUndoManager())
        let session = ToolSession(tool: .forArchiving, provider: provider, document: document)
        _ = complete { await session.updatePreview() }
        guard case .popup(_, _, let options, _)? = session.panel.moreOptions.first else { return [] }
        return options.map(\.id)
    }
    check(otherStandards(plainURL) == ["none", "2u", "pdfx-4", "pdfx-1a"], "an untagged file isn't offered the accessible levels")
    let offered = otherStandards(taggedURL)
    check(offered == ["none", "2u", "2a", "1a", "3a", "pdfx-4", "pdfx-1a"] && offered.count <= 7, "a tagged file is: \(offered)")
    let document = DocumentHandle(url: taggedURL, pdf: PDFDocument(url: taggedURL)!, undoManager: makeUndoManager())
    let request = ToolRequest(tool: .forArchiving, document: document, source: document.snapshot(), values: ToolValues(["other-standard": .string("2a")]),
                              destination: folder.appendingPathComponent("Tagged (archive).pdf"), workFolder: SuperPDFPaths.ensure(ckFolder()))
    if case .newFile(let url, let banner)? = ckAwait({ try await provider.run(request, progress: .ignored) }), let model = try? PDFModel(url: url) {
        check(banner.text.contains("PDF/A-2a"), "the banner names the level: \(banner.text)")
        if case .found(_, let conformance, _) = ArchiveXMP.identification(of: model) { check(conformance == "A", "saved as PDF/A-2a") }
        else { check(false, "the panel's result is PDF/A") }
    } else { check(false, "the panel saves PDF/A-2a") }
}

@MainActor
private func archiveVerifierKnownBad() {
    do {
        // A plain Quartz file says nothing about PDF/A.
        let plain = try PDFAVerifier.verify(.data(archiveQuartzPDF(pages: 1)), level: .a2b)
        check(archiveRules(plain).isSuperset(of: ["metadata", "output-intent"]) && !archiveRules(plain).contains("fonts-not-embedded"),
              "plain Quartz: metadata and output intent (\(archiveRules(plain)))")

        // A script that runs on open.
        let scripted = try PDFModel(data: archiveQuartzPDF(pages: 1))
        scripted.root.set("OpenAction", .dictionary(["S": .name("JavaScript"), "JS": .text("app.alert('hi')")]))
        let scriptRules = archiveRules(try PDFAVerifier.verify(.data(scripted.data()), level: .a2b))
        check(scriptRules.contains("javascript"), "OpenAction JavaScript (\(scriptRules))")

        // A launch action on a link.
        let launching = try PDFModel(data: archiveQuartzPDF(pages: 1))
        let link = launching.makeIndirect(.dictionary(["Type": .name("Annot"), "Subtype": .name("Link"), "Rect": .rect(CGRect(x: 0, y: 0, width: 50, height: 20)),
                                                       "F": .integer(4), "A": .dictionary(["S": .name("Launch"), "F": .text("Calculator.app")])]))
        launching.pages[0].addAnnotation(link)
        let launchProblems = try PDFAVerifier.verify(.data(launching.data()), level: .a2b)
        check(launchProblems.contains { $0.rule == "actions" && $0.pages == [0] }, "Launch action on page 1")

        // Encrypted (opens without a password, but archive copies can't be encrypted).
        let locked = try PDFModel(data: archiveQuartzPDF(pages: 1))
        let lockedData = try locked.data(options: PDFWriteOptions(encryption: .encrypt(PDFEncryption(userPassword: "", ownerPassword: "owner"))))
        let lockedRules = archiveRules(try PDFAVerifier.verify(.data(lockedData), level: .a2b))
        check(lockedRules.contains("encrypted"), "encrypted")

        // Helvetica without its font program.
        let unembedded = try archiveUnembeddedFontPDF()
        let fontProblems = try PDFAVerifier.verify(.data(unembedded), level: .a2b)
        check(fontProblems.contains { $0.rule == "fonts-not-embedded" && $0.pages == [0] }, "not-embedded font on page 1")
        check(fontProblems.first { $0.rule == "fonts-not-embedded" }?.message == ArchiveCopy.fontsNotEmbedded, "font copy")
        // …which the writer fixes (Quartz embeds what it draws).
        let fixed = FileManager.default.temporaryDirectory.appendingPathComponent("superpdf-archive-font-\(UUID().uuidString).pdf")
        defer { try? FileManager.default.removeItem(at: fixed) }
        let after = try ArchiveWriter.writePDFA(.data(unembedded), level: .a2b, to: fixed)
        check(after.isEmpty, "writing embeds the font (\(archiveRules(after)))")
        check(archiveText(fixed).contains("Hello archive"), "text kept after embedding")

        // A level mismatch and attachments in part 1 and 2.
        let folder = archiveFolder()
        defer { try? FileManager.default.removeItem(at: folder) }
        let threeB = folder.appendingPathComponent("3b.pdf")
        _ = try ArchiveWriter.writePDFA(.data(archiveSource()), level: .a3b, to: threeB)
        let asOne = archiveRules(try PDFAVerifier.verify(.file(threeB), level: .a1b))
        check(asOne.contains("pdfa-identification") && asOne.contains("attachments"), "a PDF/A-3b file checked as 1b (\(asOne))")
        let asTwo = archiveRules(try PDFAVerifier.verify(.file(threeB), level: .a2b))
        check(asTwo.contains("attachments"), "PDF/A-2b: a non-archive attachment")

        // A note without an appearance, not set to print.
        let noted = try PDFModel(data: archiveQuartzPDF(pages: 2))
        noted.pages[1].addAnnotation(noted.makeIndirect(.dictionary(["Type": .name("Annot"), "Subtype": .name("Text"),
                                                                     "Rect": .rect(CGRect(x: 10, y: 10, width: 20, height: 20)),
                                                                     "Contents": .text("Hi")])))
        let notes = try PDFAVerifier.verify(.data(noted.data()), level: .a2b)
        check(notes.contains { $0.rule == "annotation-appearance" && $0.pages == [1] } && notes.contains { $0.rule == "annotation-print" },
              "note without appearance or print flag (\(archiveRules(notes)))")
    } catch {
        check(false, "verifier fixtures failed: \(error)")
    }
}

@MainActor
private func archiveTransparencyPart1() {
    let url = FileManager.default.temporaryDirectory.appendingPathComponent("superpdf-archive-alpha-\(UUID().uuidString).pdf")
    defer { try? FileManager.default.removeItem(at: url) }
    do {
        let source = PDFSource.data(archiveQuartzPDF(pages: 2, alpha: 0.5))
        let before = try PDFAVerifier.verify(source, level: .a1b)
        check(before.contains { $0.rule == "transparency" && $0.pages == [0, 1] }, "half see-through pages fail PDF/A-1 (\(archiveRules(before)))")
        let partTwo = archiveRules(try PDFAVerifier.verify(source, level: .a2b))
        check(!partTwo.contains("transparency"), "PDF/A-2 allows transparency")
        let problems = try ArchiveWriter.writePDFA(source, level: .a1b, to: url)
        check(problems.isEmpty, "PDF/A-1b flattens see-through pages (\(archiveRules(problems)))")
        check(PDFDocument(url: url)?.pageCount == 2, "both pages kept")
    } catch {
        check(false, "transparency fixture failed: \(error)")
    }
}

// MARK: - PDF/X

@MainActor
private func archivePDFX() {
    let folder = archiveFolder()
    defer { try? FileManager.default.removeItem(at: folder) }
    do {
        for level in [PDFXLevel.x4, .x1a] {
            let url = folder.appendingPathComponent("print-\(level.rawValue).pdf")
            try ArchiveWriter.writePDFX(.data(archiveSource()), level: level, to: url)
            let model = try PDFModel(url: url)
            let version = level == .x4 ? "PDF/X-4" : "PDF/X-1a:2001"
            check(model.info("GTS_PDFXVersion") == version, "\(level.title): GTS_PDFXVersion")
            check(model.trailer["Info"]?["Trapped"]?.name == "False", "\(level.title): Trapped false")
            check(model.pages.allSatisfy { $0.object["TrimBox"]?.rect != nil }, "\(level.title): a trim box on every page")
            let intent = model.root["OutputIntents"]?.items.first { $0["S"]?.name == "GTS_PDFX" }
            check(intent?["DestOutputProfile"]?.type == .stream, "\(level.title): output intent with its profile")
            let xmp = (try? model.root["Metadata"]?.streamData(decode: .all)).flatMap { try? XML.parse($0) }
            check(xmp.flatMap { ArchiveXMP.value($0, "pdfxid:GTS_PDFXVersion") } == version, "\(level.title): XMP pdfxid")
            if level == .x4 { check(model.version >= "1.6", "PDF/X-4 header is at least 1.6 (\(model.version))") }
            check(PDFDocument(url: url)?.pageCount == 2, "\(level.title): opens")
        }
    } catch {
        check(false, "PDF/X writing failed: \(error)")
    }
}

// MARK: - Data exports (#59)

@MainActor
private func archiveDataExport() {
    let folder = archiveFolder()
    defer { try? FileManager.default.removeItem(at: folder) }
    do {
        let model = PDFModel()
        let page = try model.addBlankPage(size: CGSize(width: 612, height: 792))
        func widget(_ extra: [String: PDFValue], y: Double) -> [String: PDFValue] {
            extra.merging(["Type": .name("Annot"), "Subtype": .name("Widget"), "F": .integer(4),
                           "Rect": .rect(CGRect(x: 72, y: y, width: 200, height: 20))]) { $1 }
        }
        model.addField(.dictionary(widget(["FT": .name("Tx"), "T": .text("name"), "V": .text("Zoë “Ñ” <&>")], y: 700)), on: page)
        model.addField(.dictionary(widget(["FT": .name("Btn"), "T": .text("agree"), "V": .name("Yes"), "AS": .name("Yes")], y: 650)), on: page)
        // address.city: a parent field with a terminal kid.
        let city = model.makeIndirect(.dictionary(widget(["FT": .name("Tx"), "T": .text("city"), "V": .text("Paris")], y: 600)))
        page.addAnnotation(city)
        let address = model.makeIndirect(.dictionary(["T": .text("address"), "Kids": .array([city.reference!])]))
        city.set("Parent", address)
        model.ensureAcroForm().array("Fields").append(address)
        page.addAnnotation(model.makeIndirect(.dictionary([
            "Type": .name("Annot"), "Subtype": .name("Highlight"), "Rect": .rect(CGRect(x: 72, y: 500, width: 100, height: 14)),
            "QuadPoints": .array([72, 514, 172, 514, 72, 500, 172, 500].map { .integer($0) }), "C": .array([.integer(1), .integer(1), .integer(0)]),
            "Contents": .text("Check this"), "T": .text("Ann"), "F": .integer(4),
        ])))
        let source = PDFSource.data(try model.data())

        let fdfURL = folder.appendingPathComponent("data.fdf")
        try DataExport.write(source, format: .fdf, to: fdfURL)
        let fdf = try Data(contentsOf: fdfURL)
        let fdfText = String(decoding: fdf, as: UTF8.self)
        check(fdf.starts(with: Data("%FDF-1.2\n".utf8)) && fdfText.contains("trailer") && fdfText.contains("%%EOF"), "FDF frame")
        check(fdfText.contains("(agree)") && fdfText.contains("/Yes") && fdfText.contains("(address)") && fdfText.contains("/Kids")
              && fdfText.contains("(Paris)"), "FDF names, hierarchy and values")
        let utf16 = "<" + PDFText.encode("Zoë “Ñ” <&>").map { String(format: "%02x", $0) }.joined() + ">"
        check(fdfText.hasPrefix("%FDF-1.2") && fdfText.contains(utf16) && utf16.hasPrefix("<feff"), "FDF keeps Unicode text as UTF-16")

        let xfdfURL = folder.appendingPathComponent("data.xfdf")
        try DataExport.write(source, format: .xfdf, to: xfdfURL)
        let xfdf = try XML.parse(Data(contentsOf: xfdfURL))
        let fields = xfdf.all("field")
        func value(_ name: String) -> String? { fields.first { $0.attr("name") == name }?.child("value")?.text }
        check(xfdf.name == "xfdf" && value("name") == "Zoë “Ñ” <&>" && value("agree") == "Yes", "XFDF field values")
        check(fields.first { $0.attr("name") == "address" }?.children("field").first?.attr("name") == "city" && value("city") == "Paris",
              "XFDF nests address.city")
        let highlight = xfdf.first("highlight")
        check(highlight?.attr("page") == "0" && highlight?.attr("title") == "Ann" && highlight?.attr("color") == "#FFFF00"
              && highlight?.child("contents")?.text == "Check this" && highlight?.attr("coords")?.split(separator: ",").count == 8,
              "XFDF highlight annotation")

        let jsonURL = folder.appendingPathComponent("data.json")
        try DataExport.write(source, format: .json, to: jsonURL)
        let json = try JSONSerialization.jsonObject(with: Data(contentsOf: jsonURL)) as? [String: Any]
        check(json?["name"] as? String == "Zoë “Ñ” <&>" && json?["agree"] as? String == "Yes" && json?["address.city"] as? String == "Paris",
              "JSON values by full name (\(json ?? [:]))")
    } catch {
        check(false, "data export failed: \(error)")
    }
}

// MARK: - Spreadsheets into PDF

// ConvertKit's spreadsheet importers (features #36 Excel → PDF, #43 CSV/TSV → PDF), on workbooks and text files built
// here (never the person's files).
func registerConvertKitSheetsTests() {
    SelfTest.cases.append(("ConvertKit.sheets.xlsx", { sheetsXLSX() }))
    SelfTest.cases.append(("ConvertKit.sheets.wide", { sheetsWide() }))
    SelfTest.cases.append(("ConvertKit.sheets.csv", { sheetsCSV() }))
    SelfTest.cases.append(("ConvertKit.sheets.tsv", { sheetsTSV() }))
    SelfTest.cases.append(("ConvertKit.sheets.bigCSV", { sheetsBigCSV() }))
    SelfTest.cases.append(("ConvertKit.sheets.damaged", { sheetsDamaged() }))
    SelfTest.cases.append(("ConvertKit.sheets.formats", { sheetsFormats() }))
}

// MARK: - Fixtures

private let sheetsFolder: URL = {
    let folder = scratch.appendingPathComponent("convertkit-sheets", isDirectory: true)
    try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    return folder
}()

private let sheetsMain = "http://schemas.openxmlformats.org/spreadsheetml/2006/main"
private let sheetsRelNS = "http://schemas.openxmlformats.org/officeDocument/2006/relationships"

/// A minimal but complete .xlsx: content types, package and workbook relationships, sheets, shared strings, styles.
private func sheetsWorkbook(_ sheets: [(name: String, xml: String, hidden: Bool)], sharedStrings: [String], styles: String,
                            extra: [String: String] = [:]) -> Data {
    var zip = ZipWriter()
    let overrides = sheets.indices.map {
        #"<Override PartName="/xl/worksheets/sheet\#($0 + 1).xml" ContentType="application/vnd.openxmlformats-officedocument.spreadsheetml.worksheet+xml"/>"#
    }.joined()
    zip.add("[Content_Types].xml", #"<?xml version="1.0" encoding="UTF-8"?><Types xmlns="http://schemas.openxmlformats.org/package/2006/content-types"><Default Extension="rels" ContentType="application/vnd.openxmlformats-package.relationships+xml"/><Default Extension="xml" ContentType="application/xml"/><Override PartName="/xl/workbook.xml" ContentType="application/vnd.openxmlformats-officedocument.spreadsheetml.sheet.main+xml"/>"# + overrides + "</Types>")
    zip.add("_rels/.rels", #"<?xml version="1.0" encoding="UTF-8"?><Relationships xmlns="http://schemas.openxmlformats.org/package/2006/relationships"><Relationship Id="rId1" Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/officeDocument" Target="xl/workbook.xml"/></Relationships>"#)
    let sheetList = sheets.enumerated().map { i, sheet in
        #"<sheet name="\#(sheet.name)" sheetId="\#(i + 1)" r:id="rId\#(i + 1)""# + (sheet.hidden ? #" state="hidden""# : "") + "/>"
    }.joined()
    zip.add("xl/workbook.xml", #"<?xml version="1.0" encoding="UTF-8"?><workbook xmlns="\#(sheetsMain)" xmlns:r="\#(sheetsRelNS)"><sheets>\#(sheetList)</sheets></workbook>"#)
    let rels = sheets.indices.map {
        #"<Relationship Id="rId\#($0 + 1)" Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/worksheet" Target="worksheets/sheet\#($0 + 1).xml"/>"#
    }.joined()
    zip.add("xl/_rels/workbook.xml.rels", #"<?xml version="1.0" encoding="UTF-8"?><Relationships xmlns="http://schemas.openxmlformats.org/package/2006/relationships">"# + rels
        + #"<Relationship Id="rIdS" Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/sharedStrings" Target="sharedStrings.xml"/><Relationship Id="rIdT" Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/styles" Target="/xl/styles.xml"/></Relationships>"#)
    for (i, sheet) in sheets.enumerated() {
        zip.add("xl/worksheets/sheet\(i + 1).xml", #"<?xml version="1.0" encoding="UTF-8"?><worksheet xmlns="\#(sheetsMain)" xmlns:r="\#(sheetsRelNS)">"# + sheet.xml + "</worksheet>")
    }
    let items = sharedStrings.map { "<si><t>\(XML.escape($0))</t></si>" }.joined()
    zip.add("xl/sharedStrings.xml", #"<?xml version="1.0" encoding="UTF-8"?><sst xmlns="\#(sheetsMain)" count="\#(sharedStrings.count)">"# + items + "</sst>")
    zip.add("xl/styles.xml", #"<?xml version="1.0" encoding="UTF-8"?><styleSheet xmlns="\#(sheetsMain)">"# + styles + "</styleSheet>")
    for (path, text) in extra { zip.add(path, text) }
    return zip.finish()
}

private let sheetsStyles = """
<numFmts count="2"><numFmt numFmtId="164" formatCode="0.0%"/><numFmt numFmtId="165" formatCode="yyyy-mm-dd"/></numFmts>
<fonts count="2"><font><sz val="11"/><name val="Calibri"/></font><font><b/><sz val="11"/><color rgb="FF1F4E79"/><name val="Calibri"/></font></fonts>
<fills count="3"><fill><patternFill patternType="none"/></fill><fill><patternFill patternType="gray125"/></fill><fill><patternFill patternType="solid"><fgColor theme="4" tint="0.79"/></patternFill></fill></fills>
<borders count="1"><border><left/><right/><top/><bottom/><diagonal/></border></borders>
<cellXfs count="6"><xf numFmtId="0" fontId="0" fillId="0" borderId="0"/><xf numFmtId="0" fontId="1" fillId="2" borderId="0" applyFont="1"/><xf numFmtId="4" fontId="0" fillId="0" borderId="0"/><xf numFmtId="164" fontId="0" fillId="0" borderId="0"/><xf numFmtId="165" fontId="0" fillId="0" borderId="0"/><xf numFmtId="0" fontId="0" fillId="0" borderId="0"><alignment horizontal="center" wrapText="1"/></xf></cellXfs>
"""

private func sheetsWrite(_ data: Data, _ name: String) -> URL {
    let url = sheetsFolder.appendingPathComponent(name)
    try? data.write(to: url)
    return url
}

private func sheetsConvert(_ input: URL, xlsx: Bool = true) -> (report: ImportReport?, pdf: PDFDocument?, error: Error?) {
    let output = sheetsFolder.appendingPathComponent(UUID().uuidString + ".pdf")
    do {
        let report = xlsx ? try XLSXImporter.convert(input, to: output, options: ImportOptions(paper: .a4, margins: 36))
            : try DelimitedTextImporter.convert(input, to: output, options: ImportOptions(paper: .a4, margins: 36))
        return (report, PDFDocument(url: output), nil)
    } catch {
        return (nil, nil, error)
    }
}

private func sheetsText(_ pdf: PDFDocument?) -> String {
    (pdf?.string ?? "").replacingOccurrences(of: "\u{00A0}", with: " ")
}

// MARK: - Cases

@MainActor
private func sheetsXLSX() {
    let summary = """
    <cols><col min="1" max="1" width="18" customWidth="1"/><col min="2" max="3" width="14" customWidth="1"/></cols>
    <sheetData>
    <row r="1"><c r="A1" t="s" s="1"><v>0</v></c><c r="B1" t="inlineStr"><is><t>Inline text</t></is></c></row>
    <row r="2"><c r="A2" s="2"><v>1234.5</v></c><c r="B2" s="3"><v>0.125</v></c><c r="C2" s="4"><v>45366</v></c></row>
    <row r="3"><c r="A3" t="str"><f>A1</f><v>Formula result</v></c><c r="B3" t="b"><v>1</v></c></row>
    <row r="4"><c r="A4" t="s" s="5"><v>1</v></c></row>
    </sheetData>
    <mergeCells count="1"><mergeCell ref="A4:C4"/></mergeCells>
    """
    let secret = #"<sheetData><row r="1"><c r="A1" t="inlineStr"><is><t>TopSecretValue</t></is></c></row></sheetData>"#
    let data = #"<sheetData><row r="1"><c r="A1" t="inlineStr"><is><r><t>Second </t></r><r><rPr><b/></rPr><t>sheet</t></r></is></c></row></sheetData>"#
    let url = sheetsWrite(sheetsWorkbook([("Summary", summary, false), ("Secret", secret, true), ("Data", data, false)],
                                         sharedStrings: ["Total due", "Merged title"], styles: sheetsStyles,
                                         extra: ["xl/charts/chart1.xml": "<c:chartSpace xmlns:c=\"x\"/>"]), "Budget.xlsx")
    let result = sheetsConvert(url)
    check(result.error == nil, "xlsx converts (\(String(describing: result.error)))")
    guard let pdf = result.pdf, let report = result.report else { return }
    check(pdf.pageCount == 2, "one page per visible sheet (got \(pdf.pageCount))")
    let text = sheetsText(pdf)
    let d = Locale.current.decimalSeparator ?? ".", g = Locale.current.groupingSeparator ?? ","
    for expected in ["Total due", "Inline text", "1\(g)234\(d)50", "12\(d)5%", "2024-03-15", "Formula result", "TRUE", "Merged title", "Second sheet"] {
        check(text.contains(expected), "xlsx text has “\(expected)”")
    }
    check(!text.contains("TopSecretValue"), "the hidden sheet is left out")
    check(report.outline.map(\.title) == ["Summary", "Data"] && report.outline.map { $0.destination?.page } == [0, 1],
          "a contents entry per visible sheet at its first page")
    check(report.notices == ["Charts in “Budget.xlsx” aren’t in the PDF, only the cells."], "the charts notice (\(report.notices))")
    // Through the registry's joiner the entries become the PDF's outline.
    let joined = sheetsFolder.appendingPathComponent("joined.pdf")
    let output = sheetsFolder.appendingPathComponent("budget.pdf")
    _ = try? XLSXImporter.convert(url, to: output, options: ImportOptions())
    _ = try? PDFAssembler.join([PDFAssembler.Part(url: output, title: nil, outline: report.outline)], to: joined)
    let outline = PDFDocument(url: joined)?.outlineRoot
    check(outline?.numberOfChildren == 2 && outline?.child(at: 0)?.label == "Summary", "the outline holds the sheet names")
}

@MainActor
private func sheetsWide() {
    let cells = (0..<30).map { c -> String in
        let letter = c < 26 ? String(UnicodeScalar(65 + c)!) : "A" + String(UnicodeScalar(65 + c - 26)!)
        return #"<c r="\#(letter)1" t="inlineStr"><is><t>Col\#(c + 1)</t></is></c>"#
    }.joined()
    let xml = #"<cols><col min="1" max="30" width="20" customWidth="1"/></cols><sheetData><row r="1">\#(cells)</row><row r="2"><c r="A2"><v>7</v></c></row></sheetData>"#
    let url = sheetsWrite(sheetsWorkbook([("Wide", xml, false)], sharedStrings: [], styles: sheetsStyles), "Wide.xlsx")
    let result = sheetsConvert(url)
    guard let pdf = result.pdf else { check(false, "wide sheet converts (\(String(describing: result.error)))"); return }
    let bounds = (0..<pdf.pageCount).compactMap { pdf.page(at: $0)?.bounds(for: .mediaBox) }
    check(bounds.allSatisfy { $0.width > $0.height }, "a sheet wider than portrait prints landscape")
    check(pdf.pageCount >= 4, "columns that don't fit continue on further pages (got \(pdf.pageCount))")
    let first = pdf.page(at: 0)?.string ?? "", last = pdf.page(at: pdf.pageCount - 1)?.string ?? ""
    check(first.contains("Col1") && !first.contains("Col30") && last.contains("Col30"), "left columns first, then over")
}

@MainActor
private func sheetsCSV() {
    let csv = "Name;Comment;Price\r\n\"Müller, Jörg\";\"He said \"\"hi\"\"\nsecond line\";12,50\r\nZoë;plain;3,00\r\n"
    let url = sheetsWrite(csv.data(using: .windowsCP1252)!, "People.csv")
    let decoded = SheetDelimited.decode(try! Data(contentsOf: url))
    check(decoded.contains("Müller") && decoded.contains("Zoë"), "Windows-1252 text decodes")
    check(SheetDelimited.detectDelimiter(decoded) == ";", "semicolons detected")
    let rows = SheetDelimited.parse(decoded, delimiter: ";", maxRows: 100, maxColumns: 100).rows
    check(rows.count == 3 && rows[1].count == 3 && rows[1][0] == "Müller, Jörg" && rows[1][1] == "He said \"hi\"\nsecond line",
          "quotes, doubled quotes and a line break inside a field (\(rows))")
    let result = sheetsConvert(url, xlsx: false)
    let text = sheetsText(result.pdf)
    for expected in ["Name", "Müller, Jörg", "He said \"hi\"", "second line", "Zoë", "12,50"] {
        check(text.contains(expected), "CSV text has “\(expected)” (\(String(describing: result.error)))")
    }
    check(SheetDelimited.isNumber("1,234.50") && SheetDelimited.isNumber("(3.50)") && SheetDelimited.isNumber("12%")
          && !SheetDelimited.isNumber("12 apples") && !SheetDelimited.isNumber("-"), "number detection")
}

@MainActor
private func sheetsTSV() {
    let url = sheetsWrite(Data("City\tPopulation\nParis, France\t2102650\nOslo\t709037\n".utf8), "Cities.tsv")
    let rows = SheetDelimited.parse(String(decoding: try! Data(contentsOf: url), as: UTF8.self), delimiter: "\t", maxRows: 10, maxColumns: 10).rows
    check(rows.count == 3 && rows[1] == ["Paris, France", "2102650"], "TSV keeps commas inside fields")
    let result = sheetsConvert(url, xlsx: false)
    let text = sheetsText(result.pdf)
    check(result.pdf?.pageCount == 1 && text.contains("Paris, France") && text.contains("709037"), "TSV converts (\(String(describing: result.error)))")
}

@MainActor
private func sheetsBigCSV() {
    var csv = "Index,Name,Value,Note\n"
    for i in 1...10_000 { csv += "\(i),Item \(i),\(Double(i) * 1.25),\(i % 7 == 0 ? "\"has, comma\"" : "plain")\n" }
    let url = sheetsWrite(Data(csv.utf8), "Big.csv")
    let start = Date()
    let result = sheetsConvert(url, xlsx: false)
    let seconds = Date().timeIntervalSince(start)
    check(seconds < 5, "10,000 rows convert in under 5 s (took \(String(format: "%.2f", seconds)) s)")
    guard let pdf = result.pdf else { check(false, "big CSV converts (\(String(describing: result.error)))"); return }
    check(pdf.pageCount > 50, "10,000 rows paginate (got \(pdf.pageCount) pages)")
    check((pdf.page(at: 1)?.string ?? "").contains("Index") && (pdf.page(at: pdf.pageCount - 1)?.string ?? "").contains("Index"),
          "the header row repeats on every page")
    check((pdf.page(at: pdf.pageCount - 1)?.string ?? "").contains("10000"), "the last row is there")
}

@MainActor
private func sheetsDamaged() {
    let garbage = sheetsWrite(Data((0..<4096).map { UInt8(truncatingIfNeeded: $0 &* 37 &+ 11) }), "Garbage.xlsx")
    check(sheetsConvert(garbage).error != nil, "garbage throws")
    var zip = ZipWriter()
    zip.add("hello.txt", "not a workbook")
    let notBook = sheetsWrite(zip.finish(), "NotBook.xlsx")
    check(sheetsConvert(notBook).error != nil, "a zip without a workbook throws")
    let truncated = sheetsWrite(sheetsWorkbook([("A", "<sheetData><row r=\"1\"><c r=\"A1\"><v>1</v></c></row></sheetData>", false)],
                                               sharedStrings: [], styles: sheetsStyles).prefix(300), "Truncated.xlsx")
    check(sheetsConvert(truncated).error != nil, "a truncated workbook throws")
    let empty = sheetsWrite(sheetsWorkbook([("Empty", "<sheetData/>", false)], sharedStrings: [], styles: sheetsStyles), "Empty.xlsx")
    check(sheetsConvert(empty).error as? SheetImportError == .empty, "an empty workbook throws")
    let hostile = #"<cols><col min="900" max="16384" width="9"/></cols><sheetData><row r="1048576"><c r="XFD1048576"><v>1</v></c></row><row r="1"><c r="A1"><v>2</v></c></row></sheetData><mergeCells><mergeCell ref="A1:XFD1048576"/></mergeCells>"#
    let far = sheetsWrite(sheetsWorkbook([("Far", hostile, false)], sharedStrings: [], styles: sheetsStyles), "Far.xlsx")
    let result = sheetsConvert(far)
    check(result.pdf != nil && (result.report?.notices.contains { $0.contains("very large") } ?? false),
          "cells past the limits are left out with a notice (\(String(describing: result.error)))")
    check(SheetDelimited.parse("\"unterminated, \"quote", delimiter: ",", maxRows: 10, maxColumns: 10).rows.count == 1, "an open quote doesn't hang")
}

@MainActor
private func sheetsFormats() {
    let d = Locale.current.decimalSeparator ?? ".", g = Locale.current.groupingSeparator ?? ","
    func f(_ code: String, _ value: Double, date1904: Bool = false) -> String { SheetNumberFormat(code: code).format(value, date1904: date1904) }
    let symbols = DateFormatter()
    symbols.locale = Locale.current
    let cases: [(String, Double, String)] = [
        ("General", 1234.5, "1234\(d)5"), ("General", 0.1 + 0.2, "0\(d)3"), ("General", 42, "42"), ("General", 123_456_789_012, "1\(d)23457E+11"),
        ("0.00", 3.14159, "3\(d)14"), ("#,##0", 1_234_567.8, "1\(g)234\(g)568"), ("#,##0.00", -1234.5, "-1\(g)234\(d)50"),
        ("$#,##0.00_);($#,##0.00)", -5, "($5\(d)00)"), ("$#,##0.00_);($#,##0.00)", 5, "$5\(d)00 "), ("0%", 0.256, "26%"),
        ("0.00E+00", 12345, "1\(d)23E+04"), ("# ?/?", 1.5, "1 1/2"), ("#,##0,", 1_234_567, "1\(g)235"), ("0.0%", 0.125, "12\(d)5%"),
        ("[Red]0.0;[Blue]-0.0", -2.5, "-2\(d)5"), ("[$€-407] #,##0.00", 9.5, "€ 9\(d)50"), (";;;", 5, ""), ("\"Qty: \"0", 3, "Qty: 3"),
        ("yyyy-mm-dd", 45366, "2024-03-15"), ("d-mmm-yy", 45366, "15-\(symbols.shortMonthSymbols[2])-24"),
        ("h:mm AM/PM", 0.75, "6:00 \(symbols.pmSymbol ?? "PM")"), ("[h]:mm:ss", 1.5, "36:00:00"), ("yyyy-mm-dd hh:mm", 45366.5, "2024-03-15 12:00"),
        ("mm:ss.0", 0.000_011_574_074, "00:01\(d)0"), ("dddd", 45366, symbols.weekdaySymbols[5]), ("yyyy-mm-dd", 60, "1900-02-29"),
        ("yyyy-mm-dd", 61, "1900-03-01"), ("yyyy-mm-dd", 1, "1900-01-01"),
    ]
    for (code, value, expected) in cases {
        let got = f(code, value)
        check(got == expected, "format “\(code)” of \(value): “\(got)” ≠ “\(expected)”")
    }
    check(f("yyyy-mm-dd", 0, date1904: true) == "1904-01-01" && f("yyyy-mm-dd", 1462, date1904: true) == "1908-01-02", "1904 date system")
    check(SheetNumberFormat(code: "yyyy-mm-dd").isDate && !SheetNumberFormat(code: "0.00E+00").isDate && SheetNumberFormat(code: "[h]:mm").isDate
          && !SheetNumberFormat(code: "[Red]0.00").isDate, "date detection")
    check(SheetNumberFormat.serial(iso: "2024-03-15T12:00:00Z", date1904: false) == 45366.5, "ISO dates to serials")
    check(SheetNumberFormat(code: "\"Note: \"@").format(text: "hi") == "Note: hi", "text sections")
    check(SheetWorksheetParser.reference("AB12")! == (11, 27) && SheetWorksheetParser.reference("$C$3")! == (2, 2)
          && SheetWorksheetParser.reference("12A") == nil, "cell references")
    check(SheetRels.resolve("../media/image1.png", from: "xl/drawings") == "xl/media/image1.png" && SheetRels.resolve("/xl/styles.xml", from: "xl") == "xl/styles.xml",
          "relationship targets")
}

// MARK: - Presentations into PDF

// The PowerPoint importer (features #37) on a generated deck: theme colours through the colour map, a master and layout
// whose placeholders the slides inherit, bullets, a picture, an ellipse, a table, a chart left out with a notice, a
// hidden slide; and damaged files.
func registerConvertKitSlidesTests() {
    SelfTest.cases.append(("ConvertKit.slides.deck", { slidesDeck() }))
    SelfTest.cases.append(("ConvertKit.slides.damaged", { slidesDamaged() }))
}

private let slidesP = "http://schemas.openxmlformats.org/presentationml/2006/main"
private let slidesA = "http://schemas.openxmlformats.org/drawingml/2006/main"
private let slidesR = "http://schemas.openxmlformats.org/officeDocument/2006/relationships"
private let slidesRel = "http://schemas.openxmlformats.org/officeDocument/2006/relationships"
private let slidesNS = "xmlns:p=\"\(slidesP)\" xmlns:a=\"\(slidesA)\" xmlns:r=\"\(slidesR)\""

private func slidesFolder() -> URL {
    let folder = FileManager.default.temporaryDirectory.appendingPathComponent("superpdf-slides-\(UUID().uuidString)", isDirectory: true)
    try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    return folder
}

private func slidesRels(_ rels: [(String, String, String)]) -> String {
    "<?xml version=\"1.0\" encoding=\"UTF-8\" standalone=\"yes\"?><Relationships xmlns=\"http://schemas.openxmlformats.org/package/2006/relationships\">"
        + rels.map { "<Relationship Id=\"\($0.0)\" Type=\"\(slidesRel)/\($0.1)\" Target=\"\($0.2)\"/>" }.joined() + "</Relationships>"
}

/// A 40 × 30 red PNG.
private func slidesPNG() -> Data {
    let context = CGContext(data: nil, width: 40, height: 30, bitsPerComponent: 8, bytesPerRow: 0, space: CGColorSpace(name: CGColorSpace.sRGB)!,
                            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
    context.setFillColor(CGColor(red: 1, green: 0, blue: 0, alpha: 1))
    context.fill(CGRect(x: 0, y: 0, width: 40, height: 30))
    let data = NSMutableData()
    let destination = CGImageDestinationCreateWithData(data, "public.png" as CFString, 1, nil)!
    CGImageDestinationAddImage(destination, context.makeImage()!, nil)
    CGImageDestinationFinalize(destination)
    return data as Data
}

private func slidesShape(id: Int, name: String, ph: String?, xfrm: String = "", geometry: String = "", fill: String = "", text: String) -> String {
    let nvPr = ph.map { "<p:nvPr>\($0)</p:nvPr>" } ?? "<p:nvPr/>"
    return "<p:sp><p:nvSpPr><p:cNvPr id=\"\(id)\" name=\"\(name)\"/><p:cNvSpPr/>\(nvPr)</p:nvSpPr><p:spPr>\(xfrm)\(geometry)\(fill)</p:spPr>\(text)</p:sp>"
}

private func slidesXfrm(_ x: Int, _ y: Int, _ cx: Int, _ cy: Int) -> String {
    "<a:xfrm><a:off x=\"\(x)\" y=\"\(y)\"/><a:ext cx=\"\(cx)\" cy=\"\(cy)\"/></a:xfrm>"
}

private func slidesBody(_ paragraphs: [(String, Int)]) -> String {
    "<p:txBody><a:bodyPr/><a:lstStyle/>" + paragraphs.map { text, level in
        "<a:p>\(level > 0 ? "<a:pPr lvl=\"\(level)\"/>" : "")<a:r><a:rPr lang=\"en-US\"/><a:t>\(text)</a:t></a:r></a:p>"
    }.joined() + "</p:txBody>"
}

private func slidesTree(_ shapes: String) -> String {
    "<p:cSld><p:spTree><p:nvGrpSpPr><p:cNvPr id=\"1\" name=\"\"/><p:cNvGrpSpPr/><p:nvPr/></p:nvGrpSpPr><p:grpSpPr/>\(shapes)</p:spTree></p:cSld>"
}

/// The generated deck: 16:9, theme accent 2 = #1A9E5C, three slides of which the last is hidden.
private func slidesMakeDeck() -> Data {
    let header = "<?xml version=\"1.0\" encoding=\"UTF-8\" standalone=\"yes\"?>"
    var zip = ZipWriter()
    zip.add("[Content_Types].xml", header + """
    <Types xmlns="http://schemas.openxmlformats.org/package/2006/content-types"><Default Extension="rels" ContentType="application/vnd.openxmlformats-package.relationships+xml"/><Default Extension="xml" ContentType="application/xml"/><Default Extension="png" ContentType="image/png"/><Override PartName="/ppt/presentation.xml" ContentType="application/vnd.openxmlformats-officedocument.presentationml.presentation.main+xml"/></Types>
    """)
    zip.add("_rels/.rels", slidesRels([("rId1", "officeDocument", "ppt/presentation.xml")]))
    zip.add("ppt/presentation.xml", header + """
    <p:presentation \(slidesNS)><p:sldMasterIdLst><p:sldMasterId id="2147483648" r:id="rId1"/></p:sldMasterIdLst><p:sldIdLst><p:sldId id="256" r:id="rId2"/><p:sldId id="257" r:id="rId3"/><p:sldId id="258" r:id="rId4"/></p:sldIdLst><p:sldSz cx="12192000" cy="6858000"/><p:notesSz cx="6858000" cy="9144000"/></p:presentation>
    """)
    zip.add("ppt/_rels/presentation.xml.rels", slidesRels([("rId1", "slideMaster", "slideMasters/slideMaster1.xml"), ("rId2", "slide", "slides/slide1.xml"),
                                                          ("rId3", "slide", "slides/slide2.xml"), ("rId4", "slide", "slides/slide3.xml"),
                                                          ("rId5", "theme", "theme/theme1.xml")]))
    zip.add("ppt/theme/theme1.xml", header + """
    <a:theme xmlns:a="\(slidesA)" name="Test"><a:themeElements><a:clrScheme name="Test"><a:dk1><a:sysClr val="windowText" lastClr="000000"/></a:dk1><a:lt1><a:sysClr val="window" lastClr="FFFFFF"/></a:lt1><a:dk2><a:srgbClr val="44546A"/></a:dk2><a:lt2><a:srgbClr val="E7E6E6"/></a:lt2><a:accent1><a:srgbClr val="4472C4"/></a:accent1><a:accent2><a:srgbClr val="1A9E5C"/></a:accent2><a:accent3><a:srgbClr val="A5A5A5"/></a:accent3><a:accent4><a:srgbClr val="FFC000"/></a:accent4><a:accent5><a:srgbClr val="5B9BD5"/></a:accent5><a:accent6><a:srgbClr val="70AD47"/></a:accent6><a:hlink><a:srgbClr val="0563C1"/></a:hlink><a:folHlink><a:srgbClr val="954F72"/></a:folHlink></a:clrScheme><a:fontScheme name="Test"><a:majorFont><a:latin typeface="Helvetica Neue"/></a:majorFont><a:minorFont><a:latin typeface="Helvetica"/></a:minorFont></a:fontScheme><a:fmtScheme name="Test"><a:fillStyleLst><a:solidFill><a:schemeClr val="phClr"/></a:solidFill></a:fillStyleLst><a:lnStyleLst><a:ln w="6350"><a:solidFill><a:schemeClr val="phClr"/></a:solidFill></a:ln></a:lnStyleLst><a:effectStyleLst/><a:bgFillStyleLst><a:solidFill><a:schemeClr val="phClr"/></a:solidFill></a:bgFillStyleLst></a:fmtScheme></a:themeElements></a:theme>
    """)
    let masterShapes = slidesShape(id: 2, name: "Title", ph: "<p:ph type=\"title\"/>", xfrm: slidesXfrm(838200, 365125, 10515600, 1325563), text: slidesBody([]))
        + slidesShape(id: 3, name: "Body", ph: "<p:ph type=\"body\" idx=\"1\"/>", xfrm: slidesXfrm(838200, 1825625, 10515600, 4351338), text: slidesBody([]))
    zip.add("ppt/slideMasters/slideMaster1.xml", header + """
    <p:sldMaster \(slidesNS)><p:cSld><p:bg><p:bgPr><a:solidFill><a:schemeClr val="bg1"/></a:solidFill><a:effectLst/></p:bgPr></p:bg><p:spTree><p:nvGrpSpPr><p:cNvPr id="1" name=""/><p:cNvGrpSpPr/><p:nvPr/></p:nvGrpSpPr><p:grpSpPr/>\(masterShapes)</p:spTree></p:cSld><p:clrMap bg1="lt1" tx1="dk1" bg2="lt2" tx2="dk2" accent1="accent1" accent2="accent2" accent3="accent3" accent4="accent4" accent5="accent5" accent6="accent6" hlink="hlink" folHlink="folHlink"/><p:sldLayoutIdLst><p:sldLayoutId id="2147483649" r:id="rId1"/></p:sldLayoutIdLst><p:txStyles><p:titleStyle><a:lvl1pPr algn="l"><a:defRPr sz="4400"><a:solidFill><a:schemeClr val="tx1"/></a:solidFill><a:latin typeface="+mj-lt"/></a:defRPr></a:lvl1pPr></p:titleStyle><p:bodyStyle><a:lvl1pPr marL="228600" indent="-228600"><a:buFont typeface="Arial"/><a:buChar char="•"/><a:defRPr sz="2800"><a:solidFill><a:schemeClr val="tx1"/></a:solidFill><a:latin typeface="+mn-lt"/></a:defRPr></a:lvl1pPr><a:lvl2pPr marL="685800" indent="-228600"><a:buChar char="–"/><a:defRPr sz="2400"><a:solidFill><a:schemeClr val="tx1"/></a:solidFill></a:defRPr></a:lvl2pPr></p:bodyStyle><p:otherStyle><a:lvl1pPr><a:defRPr sz="1800"><a:solidFill><a:schemeClr val="tx1"/></a:solidFill></a:defRPr></a:lvl1pPr></p:otherStyle></p:txStyles></p:sldMaster>
    """)
    zip.add("ppt/slideMasters/_rels/slideMaster1.xml.rels", slidesRels([("rId1", "slideLayout", "../slideLayouts/slideLayout1.xml"),
                                                                       ("rId2", "theme", "../theme/theme1.xml")]))
    let layoutShapes = slidesShape(id: 2, name: "Title", ph: "<p:ph type=\"title\"/>", text: slidesBody([("Click to add title", 0)]))
        + slidesShape(id: 3, name: "Content", ph: "<p:ph idx=\"1\"/>", text: slidesBody([("Click to add text", 0)]))
    zip.add("ppt/slideLayouts/slideLayout1.xml", header + "<p:sldLayout \(slidesNS) type=\"obj\">\(slidesTree(layoutShapes))<p:clrMapOvr><a:masterClrMapping/></p:clrMapOvr></p:sldLayout>")
    zip.add("ppt/slideLayouts/_rels/slideLayout1.xml.rels", slidesRels([("rId1", "slideMaster", "../slideMasters/slideMaster1.xml")]))

    // Slide 1: title and bullets, both placed by the master's placeholders.
    let slide1 = slidesShape(id: 2, name: "Title 1", ph: "<p:ph type=\"title\"/>", text: slidesBody([("Quarterly Review", 0)]))
        + slidesShape(id: 3, name: "Content 2", ph: "<p:ph idx=\"1\"/>", text: slidesBody([("Revenue up", 0), ("Costs down", 0), ("Margins steady", 1)]))
    // Slide 2: a picture, an ellipse in the theme's accent 2, a table, a chart with no picture, a chart with one.
    let picture = """
    <p:pic><p:nvPicPr><p:cNvPr id="4" name="Picture"/><p:cNvPicPr/><p:nvPr/></p:nvPicPr><p:blipFill><a:blip r:embed="rId2"/><a:stretch><a:fillRect/></a:stretch></p:blipFill><p:spPr>\(slidesXfrm(838200, 1825625, 3000000, 2000000))<a:prstGeom prst="rect"><a:avLst/></a:prstGeom></p:spPr></p:pic>
    """
    let ellipse = slidesShape(id: 5, name: "Oval", ph: nil, xfrm: slidesXfrm(5000000, 1825625, 2540000, 2540000),
                              geometry: "<a:prstGeom prst=\"ellipse\"><a:avLst/></a:prstGeom>", fill: "<a:solidFill><a:schemeClr val=\"accent2\"/></a:solidFill><a:ln><a:noFill/></a:ln>",
                              text: "")
    func cell(_ text: String) -> String { "<a:tc><a:txBody><a:bodyPr/><a:lstStyle/><a:p><a:r><a:rPr lang=\"en-US\"/><a:t>\(text)</a:t></a:r></a:p></a:txBody><a:tcPr/></a:tc>" }
    let table = """
    <p:graphicFrame><p:nvGraphicFramePr><p:cNvPr id="6" name="Table"/><p:cNvGraphicFramePr><a:graphicFrameLocks noGrp="1"/></p:cNvGraphicFramePr><p:nvPr/></p:nvGraphicFramePr><p:xfrm><a:off x="838200" y="4500000"/><a:ext cx="6096000" cy="741680"/></p:xfrm><a:graphic><a:graphicData uri="http://schemas.openxmlformats.org/drawingml/2006/table"><a:tbl><a:tblPr firstRow="1" bandRow="1"><a:tableStyleId>{5C22544A-7EE6-4342-B048-85BDC9FD1C3A}</a:tableStyleId></a:tblPr><a:tblGrid><a:gridCol w="3048000"/><a:gridCol w="3048000"/></a:tblGrid><a:tr h="370840">\(cell("Region"))\(cell("Total"))</a:tr><a:tr h="370840">\(cell("North"))\(cell("42"))</a:tr></a:tbl></a:graphicData></a:graphic></p:graphicFrame>
    """
    let chart = """
    <p:graphicFrame><p:nvGraphicFramePr><p:cNvPr id="7" name="Chart"/><p:cNvGraphicFramePr/><p:nvPr/></p:nvGraphicFramePr><p:xfrm><a:off x="9000000" y="5500000"/><a:ext cx="1000000" cy="800000"/></p:xfrm><a:graphic><a:graphicData uri="http://schemas.openxmlformats.org/drawingml/2006/chart"><c:chart xmlns:c="http://schemas.openxmlformats.org/drawingml/2006/chart" r:id="rId9"/></a:graphicData></a:graphic></p:graphicFrame>
    """
    let alternate = """
    <mc:AlternateContent xmlns:mc="http://schemas.openxmlformats.org/markup-compatibility/2006"><mc:Choice xmlns:cx1="http://schemas.microsoft.com/office/drawing/2015/9/8/chartex" Requires="cx1"><p:graphicFrame><p:nvGraphicFramePr><p:cNvPr id="8" name="Chart 2"/><p:cNvGraphicFramePr/><p:nvPr/></p:nvGraphicFramePr><p:xfrm><a:off x="10200000" y="5500000"/><a:ext cx="1000000" cy="800000"/></p:xfrm><a:graphic><a:graphicData uri="http://schemas.microsoft.com/office/drawing/2014/chartex"/></a:graphic></p:graphicFrame></mc:Choice><mc:Fallback><p:pic><p:nvPicPr><p:cNvPr id="8" name="Chart 2"/><p:cNvPicPr/><p:nvPr/></p:nvPicPr><p:blipFill><a:blip r:embed="rId2"/><a:stretch><a:fillRect/></a:stretch></p:blipFill><p:spPr>\(slidesXfrm(10200000, 5500000, 1000000, 800000))<a:prstGeom prst="rect"><a:avLst/></a:prstGeom></p:spPr></p:pic></mc:Fallback></mc:AlternateContent>
    """
    let slide2 = slidesShape(id: 2, name: "Title 1", ph: "<p:ph type=\"title\"/>", text: slidesBody([("Pictures and tables", 0)]))
        + picture + ellipse + table + chart + alternate
    let slide3 = slidesShape(id: 2, name: "Title 1", ph: "<p:ph type=\"title\"/>", text: slidesBody([("Hidden", 0)]))
    for (n, shapes, attributes) in [(1, slide1, ""), (2, slide2, ""), (3, slide3, " show=\"0\"")] {
        zip.add("ppt/slides/slide\(n).xml", header + "<p:sld \(slidesNS)\(attributes)>\(slidesTree(shapes))<p:clrMapOvr><a:masterClrMapping/></p:clrMapOvr></p:sld>")
        zip.add("ppt/slides/_rels/slide\(n).xml.rels", slidesRels([("rId1", "slideLayout", "../slideLayouts/slideLayout1.xml"), ("rId2", "image", "../media/image1.png")]))
    }
    zip.add("ppt/media/image1.png", slidesPNG(), compress: false)
    zip.add("docProps/core.xml", header + "<cp:coreProperties xmlns:cp=\"http://schemas.openxmlformats.org/package/2006/metadata/core-properties\" xmlns:dc=\"http://purl.org/dc/elements/1.1/\"><dc:title>Test deck</dc:title></cp:coreProperties>")
    return zip.finish()
}

/// The page's pixel at (x, y) in points from the top-left, rendered at 1 pixel per point.
private func slidesPixel(_ url: URL, page: Int, x: Int, y: Int) -> (r: Int, g: Int, b: Int)? {
    guard let document = CGPDFDocument(url as CFURL), let pdfPage = document.page(at: page + 1) else { return nil }
    let box = pdfPage.getBoxRect(.mediaBox)
    let width = Int(box.width), height = Int(box.height)
    guard let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width * 4,
                                  space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
    context.setFillColor(CGColor(red: 1, green: 1, blue: 1, alpha: 1))
    context.fill(CGRect(x: 0, y: 0, width: width, height: height))
    context.drawPDFPage(pdfPage)
    guard let data = context.data else { return nil }
    let bytes = data.bindMemory(to: UInt8.self, capacity: width * height * 4)
    let offset = (y * width + x) * 4
    return (Int(bytes[offset]), Int(bytes[offset + 1]), Int(bytes[offset + 2]))
}

@MainActor
private func slidesDeck() {
    let folder = slidesFolder()
    defer { try? FileManager.default.removeItem(at: folder) }
    let input = folder.appendingPathComponent("Deck.pptx"), output = folder.appendingPathComponent("Deck.pdf")
    do {
        try slidesMakeDeck().write(to: input)
        let start = Date()
        let report = try PPTXImporter.convert(input, to: output, options: ImportOptions())
        check(Date().timeIntervalSince(start) < 5, "a small deck converts in well under a few seconds")
        guard let pdf = PDFDocument(url: output) else { check(false, "the importer wrote a PDF"); return }
        check(pdf.pageCount == 2, "two visible slides → two pages (the hidden one is left out), got \(pdf.pageCount)")
        let size = pdf.page(at: 0)?.bounds(for: .mediaBox).size ?? .zero
        check(abs(size.width - 960) < 0.5 && abs(size.height - 540) < 0.5, "16:9 slides are 960 × 540 pt, got \(size)")
        let first = pdf.page(at: 0)?.string ?? "", second = pdf.page(at: 1)?.string ?? ""
        for text in ["Quarterly Review", "Revenue up", "Costs down", "Margins steady"] { check(first.contains(text), "slide 1 has real text “\(text)”") }
        check(first.contains("•"), "body paragraphs carry the master's bullet")
        check(!first.contains("Click to add"), "the layout's prompt text is not drawn")
        for text in ["Pictures and tables", "Region", "Total", "North", "42"] { check(second.contains(text), "slide 2 has real text “\(text)”") }
        check(!(pdf.string ?? "").contains("Hidden"), "the hidden slide is not drawn")

        // The title sits in the master's title placeholder (inherited through the layout): y 28.7–133 pt from the top.
        if let title = pdf.findString("Quarterly Review", withOptions: []).first, let page = pdf.page(at: 0) {
            let bounds = title.bounds(for: page)
            check(bounds.minX >= 66 && bounds.maxY <= 540 - 28 && bounds.minY >= 540 - 134, "title inside the inherited placeholder, got \(bounds)")
        } else {
            check(false, "the title can be found")
        }
        if let body = pdf.findString("Revenue up", withOptions: []).first, let page = pdf.page(at: 0) {
            let bounds = body.bounds(for: page)
            check(bounds.maxY <= 540 - 143 && bounds.minX > 66 + 10, "body text in the body placeholder, indented past its bullet, got \(bounds)")
        }

        // The ellipse is filled with the theme's accent 2 (#1A9E5C): its centre is at (493.7, 243.75) pt.
        if let pixel = slidesPixel(output, page: 1, x: 494, y: 244) {
            check(abs(pixel.r - 0x1A) <= 6 && abs(pixel.g - 0x9E) <= 6 && abs(pixel.b - 0x5C) <= 6, "ellipse in the theme accent colour, got \(pixel)")
        } else {
            check(false, "page 2 renders")
        }
        // The picture (red) fills its frame at (66, 143.75)–(302.2, 301.2) pt.
        if let pixel = slidesPixel(output, page: 1, x: 180, y: 220) {
            check(pixel.r > 230 && pixel.g < 70 && pixel.b < 40, "the picture is drawn, got \(pixel)")
        }
        // The table's header row takes the default style's accent 1 fill (#4472C4).
        if let pixel = slidesPixel(output, page: 1, x: 70, y: 357) {
            check(abs(pixel.r - 0x44) <= 8 && abs(pixel.g - 0x72) <= 8 && abs(pixel.b - 0xC4) <= 8, "table header fill, got \(pixel)")
        }

        check(report.outline.map(\.title) == ["Quarterly Review", "Pictures and tables"], "contents entries are the slide titles: \(report.outline.map(\.title))")
        check(report.outline.map { $0.destination?.page } == [0, 1], "contents entries point at their pages")
        check(report.notices == [SlideStrings.leftOut], "one notice for the chart that couldn't be drawn: \(report.notices)")
        check(SlideStrings.untitled(3) == "Slide 3", "untitled slide entry")
    } catch {
        check(false, "deck converts: \(error)")
    }
}

@MainActor
private func slidesDamaged() {
    let folder = slidesFolder()
    defer { try? FileManager.default.removeItem(at: folder) }
    let output = folder.appendingPathComponent("out.pdf")
    let garbage = folder.appendingPathComponent("Garbage.pptx")
    try? Data((0..<4096).map { UInt8(truncatingIfNeeded: $0 &* 2654435761 >> 7) }).write(to: garbage)
    check((try? PPTXImporter.convert(garbage, to: output, options: ImportOptions())) == nil, "random bytes throw")

    var empty = ZipWriter()
    empty.add("hello.txt", "not a presentation")
    let notDeck = folder.appendingPathComponent("NotADeck.pptx")
    try? empty.finish().write(to: notDeck)
    check((try? PPTXImporter.convert(notDeck, to: output, options: ImportOptions())) == nil, "a ZIP without a presentation throws")

    // A truncated deck: the central directory is gone.
    let deck = slidesMakeDeck()
    let truncated = folder.appendingPathComponent("Truncated.pptx")
    try? deck.prefix(deck.count / 2).write(to: truncated)
    check((try? PPTXImporter.convert(truncated, to: output, options: ImportOptions())) == nil, "a truncated deck throws")

    // Broken XML in a slide.
    var broken = ZipWriter()
    let reader = try? ZipArchive(data: deck)
    for entry in reader?.entries ?? [] {
        let data = (try? reader?.data(for: entry)) ?? Data()
        broken.add(entry.path, entry.path == "ppt/slides/slide1.xml" ? Data("<p:sld><unclosed".utf8) : data)
    }
    let brokenURL = folder.appendingPathComponent("Broken.pptx")
    try? broken.finish().write(to: brokenURL)
    check((try? PPTXImporter.convert(brokenURL, to: output, options: ImportOptions())) == nil, "a slide with broken XML throws")
    check(!FileManager.default.fileExists(atPath: output.path), "no half-written PDF is left behind")
}

// MARK: - Word, Excel and PowerPoint writers

// ConvertKit's PDF → Word / RTF / Excel / CSV / PowerPoint writers (features #50–#52), on a PDF drawn here: a heading,
// two paragraphs, a bulleted list, a ruled 3 × 3 table with numbers, a picture, and a second page. Packages are checked
// by reading them back (parts, relationships, content types, text, typed numbers), Word output also through
// NSAttributedString, and every file through LibreOffice when it is installed (headless, a scratch profile).
func registerConvertKitWritersTests() {
    SelfTest.cases.append(("ConvertKit.writers.listStyles", { writersListStyles() }))
    SelfTest.cases.append(("ConvertKit.writers.numbers", { writersNumbers() }))
    SelfTest.cases.append(("ConvertKit.writers.sheetNames", { writersSheetNames() }))
    SelfTest.cases.append(("ConvertKit.writers.docx", { writersDOCX() }))
    SelfTest.cases.append(("ConvertKit.writers.rtf", { writersRTF() }))
    SelfTest.cases.append(("ConvertKit.writers.xlsx", { writersXLSX() }))
    SelfTest.cases.append(("ConvertKit.writers.csv", { writersCSV() }))
    SelfTest.cases.append(("ConvertKit.writers.pptx", { writersPPTX() }))
    SelfTest.cases.append(("ConvertKit.writers.libreOffice", { writersLibreOffice() }))
}

// MARK: - Fixture

private let writersFolder = SuperPDFPaths.ensure(scratch.appendingPathComponent("writers", isDirectory: true))

/// A two-page PDF with the shapes the writers handle.
private let writersFixture: Data = {
    let data = NSMutableData()
    var box = CGRect(x: 0, y: 0, width: 612, height: 792)
    let context = CGContext(consumer: CGDataConsumer(data: data as CFMutableData)!, mediaBox: &box, nil)!
    func text(_ string: String, _ x: CGFloat, _ y: CGFloat, size: CGFloat = 12, bold: Bool = false) {
        let font = CTFontCreateWithName((bold ? "Helvetica-Bold" : "Helvetica") as CFString, size, nil)
        let line = CTLineCreateWithAttributedString(NSAttributedString(string: string, attributes: [.font: font]))
        context.textPosition = CGPoint(x: x, y: y)
        CTLineDraw(line, context)
    }
    context.beginPDFPage(nil)
    text("Quarterly Report", 72, 720, size: 24, bold: true)
    text("Sales grew steadily across every region this quarter, led by strong demand.", 72, 680)
    text("Costs stayed flat while the team shipped two new products on time.", 72, 650)
    text("•", 72, 610); text("Apples are in season", 90, 610)
    text("•", 72, 592); text("Pears ship next week", 90, 592)
    // A ruled table: 3 columns of 120 pt, 3 rows of 24 pt.
    context.setLineWidth(1)
    for row in 0...3 { context.move(to: CGPoint(x: 72, y: 520 - CGFloat(row) * 24)); context.addLine(to: CGPoint(x: 432, y: 520 - CGFloat(row) * 24)) }
    for column in 0...3 { context.move(to: CGPoint(x: 72 + CGFloat(column) * 120, y: 520)); context.addLine(to: CGPoint(x: 72 + CGFloat(column) * 120, y: 448)) }
    context.strokePath()
    let cells = [["Item", "Amount", "Share"], ["Widgets", "1,234.50", "12%"], ["Gadgets", "(56.00)", "8.5%"]]
    for (r, row) in cells.enumerated() {
        for (c, value) in row.enumerated() { text(value, 78 + CGFloat(c) * 120, 503 - CGFloat(r) * 24, bold: r == 0) }
    }
    // A picture.
    let pixels = CGContext(data: nil, width: 64, height: 48, bitsPerComponent: 8, bytesPerRow: 0, space: CGColorSpace(name: CGColorSpace.sRGB)!,
                           bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
    for y in 0..<48 { pixels.setFillColor(CGColor(srgbRed: CGFloat(y) / 48, green: 0.4, blue: 0.8, alpha: 1)); pixels.fill(CGRect(x: 0, y: y, width: 64, height: 1)) }
    context.draw(pixels.makeImage()!, in: CGRect(x: 72, y: 250, width: 200, height: 150))
    context.endPDFPage()
    context.beginPDFPage(nil)
    text("Next Steps", 72, 720, size: 24, bold: true)
    text("We will review the numbers again in the spring.", 72, 680)
    context.endPDFPage()
    context.closePDF()
    return data as Data
}()

@MainActor
private func writersLayout() -> LayoutDocument? {
    guard case .success(let layout)? = complete(300, { try await LayoutService().analyze(.data(writersFixture), pages: nil, options: LayoutOptions(recognition: .never)) }) else {
        check(false, "layout of the fixture"); return nil
    }
    return layout
}

/// Every part parses, every relationship points at a part, every part has a content type.
private func writersCheckPackage(_ url: URL, required: [String], _ label: String) -> ZipArchive? {
    guard let zip = try? ZipArchive(url: url) else { check(false, "\(label): opens as a ZIP"); return nil }
    let paths = Set(zip.entries.map(\.path))
    for part in required { check(paths.contains(part), "\(label): has \(part)") }
    check(zip.entries.first?.path == "[Content_Types].xml", "\(label): content types first")
    guard let typesData = try? zip.data("[Content_Types].xml"), let types = try? XML.parse(typesData) else { check(false, "\(label): content types parse"); return zip }
    let defaults = Set(types.children("Default").compactMap { $0.attr("Extension")?.lowercased() })
    let overrides = Set(types.children("Override").compactMap { $0.attr("PartName") })
    for entry in zip.entries {
        let ext = entry.path.hasSuffix(".rels") ? "rels" : (entry.path as NSString).pathExtension.lowercased()
        check(defaults.contains(ext) || overrides.contains("/" + entry.path), "\(label): content type for \(entry.path)")
        if ext == "xml" || ext == "rels" {
            check((try? XML.parse(try zip.data(for: entry))) != nil, "\(label): \(entry.path) is well-formed XML")
        }
        if ext == "rels", let rels = try? XML.parse(try zip.data(for: entry)) {
            // "word/_rels/document.xml.rels" → targets relative to "word/".
            let base = entry.path.replacingOccurrences(of: "_rels/", with: "").replacingOccurrences(of: ".rels", with: "")
            let folder = (base as NSString).deletingLastPathComponent
            for relationship in rels.children("Relationship") where relationship.attr("TargetMode") != "External" {
                guard let target = relationship.attr("Target") else { continue }
                var components = folder.isEmpty ? [] : folder.split(separator: "/").map(String.init)
                for piece in target.split(separator: "/").map(String.init) {
                    if piece == ".." { _ = components.popLast() } else if piece != "." { components.append(piece) }
                }
                let resolved = target.hasPrefix("/") ? String(target.dropFirst()) : components.joined(separator: "/")
                check(paths.contains(resolved), "\(label): relationship target \(target) of \(entry.path) exists")
            }
        }
    }
    return zip
}

private func writersText(_ zip: ZipArchive, _ prefix: String) -> String {
    zip.entries.filter { $0.path.hasPrefix(prefix) && $0.path.hasSuffix(".xml") }
        .compactMap { try? XML.parse(try zip.data(for: $0)).allText }.joined(separator: "\n")
}

// MARK: - Cases

@MainActor
private func writersListStyles() {
    check(OfficeListStyle.parse("3.") == OfficeListStyle(format: "decimal", prefix: "", suffix: ".", start: 3), "3. → decimal from 3")
    check(OfficeListStyle.parse("(b)") == OfficeListStyle(format: "lowerLetter", prefix: "(", suffix: ")", start: 2), "(b) → letters")
    check(OfficeListStyle.parse("iv)")?.format == "lowerRoman" && OfficeListStyle.parse("iv)")?.start == 4, "iv) → roman 4")
    check(OfficeListStyle.parse("A.")?.format == "upperLetter", "A. → capital letters")
    check(OfficeListStyle.parse("•")?.format == "bullet" && OfficeListStyle.parse("–")?.format == "bullet", "bullets")
    check(OfficeListStyle.parse("1.2.") == nil, "section numbers stay as text")
}

@MainActor
private func writersNumbers() {
    func p(_ s: String) -> OfficeNumber.Parsed? { OfficeNumber.parse(s) }
    check(p("1,234.50") == .init(value: 1234.5, format: "#,##0.00"), "thousands and decimals")
    check(p("(56.00)") == .init(value: -56, format: "0.00;(0.00)"), "parentheses are negative")
    check(p("12%") == .init(value: 0.12, format: "0%") && p("8.5%") == .init(value: 0.085, format: "0.0%"), "percentages")
    check(p("$9.99") == .init(value: 9.99, format: "\"$\"0.00") && p("12 €") == .init(value: 12, format: "0\"€\""), "currency")
    check(p("42") == .init(value: 42, format: nil) && p("-7") == .init(value: -7, format: nil) && p("−3") == .init(value: -3, format: nil), "plain numbers")
    check(p("1.234,50") == .init(value: 1234.5, format: "#,##0.00") && p("12,5")?.value == 12.5, "European style")
    check(p("0123") == nil && p("555-1234") == nil && p("abc") == nil && p("") == nil && p("1234567890123456789") == nil,
          "codes, phone numbers, words and long digit runs stay text")
    check(OfficeXLSX.column(0) == "A" && OfficeXLSX.column(25) == "Z" && OfficeXLSX.column(26) == "AA" && OfficeXLSX.column(701) == "ZZ", "column letters")
    check(OfficeCSV.field("a,b") == "\"a,b\"" && OfficeCSV.field("say \"hi\"") == "\"say \"\"hi\"\"\"" && OfficeCSV.field("plain") == "plain", "CSV quoting")
}

@MainActor
private func writersSheetNames() {
    let names = OfficeSheets.uniqueNames([OfficeSheet(name: "Bad:Name[1]/x"), OfficeSheet(name: "Table"), OfficeSheet(name: "table"),
                                          OfficeSheet(name: String(repeating: "L", count: 40)), OfficeSheet(name: "''")]).map(\.name)
    check(names == ["BadName1x", "Table", "table 2", String(repeating: "L", count: 31), "Sheet"], "sheet names: \(names)")
    check(names.allSatisfy { $0.count <= 31 && !$0.contains(where: { "[]:*?/\\".contains($0) }) }, "sheet names valid")
}

@MainActor
private func writersDOCX() {
    guard let layout = writersLayout() else { return }
    check(layout.pages.count == 2 && layout.pages[0].tables.count == 1 && !layout.pages[0].figures.isEmpty,
          "fixture analysed: \(layout.pages.map { "\($0.tables.count) tables, \($0.figures.count) figures" })")
    let required = ["[Content_Types].xml", "_rels/.rels", "word/document.xml", "word/styles.xml", "word/settings.xml",
                    "word/_rels/document.xml.rels", "docProps/core.xml", "docProps/app.xml"]

    // Flowing text.
    let flowing = writersFolder.appendingPathComponent("Flowing.docx")
    do { try WordWriter.writeDOCX(layout, source: .data(writersFixture), keepLayout: false, to: flowing) } catch { check(false, "flowing docx: \(error)"); return }
    if let zip = writersCheckPackage(flowing, required: required + ["word/numbering.xml"], "flowing docx"),
       let document = try? XML.parse(zip.data("word/document.xml")!) {
        let text = document.allText
        for phrase in ["Quarterly Report", "Sales grew steadily", "Apples are in season", "1,234.50", "Next Steps"] {
            check(text.contains(phrase), "flowing docx has “\(phrase)”")
        }
        check(document.all("pStyle").contains { $0.attr("w:val") == "Heading1" }, "heading style")
        check(!document.all("numPr").isEmpty, "a real Word list")
        check(document.all("tbl").count == 1 && document.all("tc").count == 9, "the table, 3 × 3")
        check(document.all("inline").count >= 1 && zip.entries.contains { $0.path.hasPrefix("word/media/") }, "an inline picture")
        check(document.all("br").contains { $0.attr("w:type") == "page" }, "a page break between pages")
        check(document.all("sectPr").count == 1, "one section")
    }
    if let read = try? NSAttributedString(url: flowing, options: [.documentType: NSAttributedString.DocumentType.officeOpenXML], documentAttributes: nil) {
        check(read.string.contains("Sales grew steadily") && read.string.contains("Apples are in season") && read.string.contains("Widgets"),
              "flowing docx reads back through NSAttributedString")
    } else {
        check(false, "flowing docx opens with NSAttributedString")
    }

    // Keep the look.
    let look = writersFolder.appendingPathComponent("Look.docx")
    do { try WordWriter.writeDOCX(layout, source: .data(writersFixture), keepLayout: true, to: look) } catch { check(false, "keep-the-look docx: \(error)"); return }
    if let zip = writersCheckPackage(look, required: required, "keep-the-look docx"), let document = try? XML.parse(zip.data("word/document.xml")!) {
        check(document.all("sectPr").count == 2, "a section per page")
        check(document.all("txbxContent").count >= 6, "blocks in text boxes (\(document.all("txbxContent").count))")
        check(document.all("anchor").allSatisfy { $0.child("positionH")?.attr("relativeFrom") == "page" }, "boxes positioned on the page")
        check(document.all("tblpPr").count == 1, "the table floats where it sat")
        let text = document.allText
        check(text.contains("Quarterly Report") && text.contains("Pears ship next week") && text.contains("12%"), "keep-the-look text")
        let pgSz = document.all("pgSz").first
        check(pgSz?.attr("w:w") == "12240" && pgSz?.attr("w:h") == "15840", "the page's size (Letter)")
    }
    // Deterministic.
    let again = SuperPDFPaths.ensure(writersFolder.appendingPathComponent("again", isDirectory: true)).appendingPathComponent("Look.docx")
    try? WordWriter.writeDOCX(layout, source: .data(writersFixture), keepLayout: true, to: again)
    check((try? Data(contentsOf: look)) == (try? Data(contentsOf: again)), "same input, same bytes")
}

@MainActor
private func writersRTF() {
    guard let layout = writersLayout() else { return }
    let url = writersFolder.appendingPathComponent("Report.rtf")
    do { try WordWriter.writeRTF(layout, to: url) } catch { check(false, "rtf: \(error)"); return }
    let raw = (try? String(contentsOf: url, encoding: .utf8)) ?? ""
    check(raw.hasPrefix("{\\rtf"), "an RTF file")
    guard let read = try? NSAttributedString(url: url, options: [.documentType: NSAttributedString.DocumentType.rtf], documentAttributes: nil) else {
        check(false, "rtf reads back"); return
    }
    for phrase in ["Quarterly Report", "Costs stayed flat", "Apples are in season", "Widgets", "Next Steps"] {
        check(read.string.contains(phrase), "rtf has “\(phrase)”")
    }
    var bold = false
    read.enumerateAttribute(.font, in: NSRange(location: 0, length: min(16, read.length))) { value, _, _ in
        if let font = value as? NSFont, font.fontDescriptor.symbolicTraits.contains(.bold) { bold = true }
    }
    check(bold, "the heading stays bold")
}

@MainActor
private func writersXLSX() {
    guard let layout = writersLayout() else { return }
    let required = ["[Content_Types].xml", "_rels/.rels", "xl/workbook.xml", "xl/_rels/workbook.xml.rels", "xl/styles.xml",
                    "xl/worksheets/sheet1.xml", "docProps/core.xml", "docProps/app.xml"]
    let perTable = writersFolder.appendingPathComponent("Tables.xlsx")
    do { try SpreadsheetWriter.writeXLSX(layout, oneSheetPerTable: true, to: perTable) } catch { check(false, "xlsx: \(error)"); return }
    if let zip = writersCheckPackage(perTable, required: required, "xlsx"),
       let workbook = try? XML.parse(zip.data("xl/workbook.xml")!), let sheet = try? XML.parse(zip.data("xl/worksheets/sheet1.xml")!),
       let styles = try? XML.parse(zip.data("xl/styles.xml")!) {
        let names = workbook.all("sheet").compactMap { $0.attr("name") }
        check(names == ["Table 1"], "one sheet per table: \(names)")
        let cells = sheet.all("c")
        func cell(_ ref: String) -> ConvertKit.XMLNode? { cells.first { $0.attr("r") == ref } }
        check(cell("A1")?.attr("t") == "inlineStr" && cell("A1")?.allText == "Item", "text cells inline")
        check(cell("B2")?.attr("t") == nil && cell("B2")?.child("v")?.text == "1234.5", "1,234.50 stored as the number 1234.5")
        check(cell("C2")?.child("v")?.text == "0.12" && cell("B3")?.child("v")?.text == "-56.0", "12% → 0.12, (56.00) → −56")
        let xfs = styles.first("cellXfs")?.children("xf") ?? []
        func format(of ref: String) -> String? { cell(ref)?.attr("s").flatMap(Int.init).flatMap { $0 < xfs.count ? xfs[$0].attr("numFmtId") : nil } }
        check(format(of: "B2") == "4" && format(of: "C2") == "9", "number formats: #,##0.00 and 0%")
        let headerFont = cell("A1")?.attr("s").flatMap(Int.init).flatMap { $0 < xfs.count ? xfs[$0].attr("fontId") : nil }
        check(headerFont == "1", "the header row in bold")
        check(!sheet.all("col").isEmpty, "column widths")
    }
    let perPage = writersFolder.appendingPathComponent("Pages.xlsx")
    try? SpreadsheetWriter.writeXLSX(layout, oneSheetPerTable: false, to: perPage)
    if let zip = writersCheckPackage(perPage, required: required + ["xl/worksheets/sheet2.xml"], "per-page xlsx"),
       let workbook = try? XML.parse(zip.data("xl/workbook.xml")!), let second = try? XML.parse(zip.data("xl/worksheets/sheet2.xml")!) {
        check(workbook.all("sheet").compactMap { $0.attr("name") } == ["Page 1", "Page 2"], "one sheet per page")
        check(second.allText.contains("Next Steps"), "a page without tables keeps its text")
    }
    // No tables: all the text on one sheet.
    let textOnly = LayoutDocument(pages: [layout.pages[1]])
    let text = writersFolder.appendingPathComponent("Text.xlsx")
    try? SpreadsheetWriter.writeXLSX(textOnly, oneSheetPerTable: true, to: text)
    if let zip = try? ZipArchive(url: text), let workbook = try? XML.parse(zip.data("xl/workbook.xml")!) {
        check(workbook.all("sheet").compactMap { $0.attr("name") } == ["Text"] && writersText(zip, "xl/worksheets").contains("We will review"),
              "the text fallback sheet")
    } else {
        check(false, "text fallback xlsx")
    }
}

@MainActor
private func writersCSV() {
    guard let layout = writersLayout() else { return }
    let url = writersFolder.appendingPathComponent("Tables.csv")
    do { try SpreadsheetWriter.writeCSV(layout, to: url) } catch { check(false, "csv: \(error)"); return }
    let data = (try? Data(contentsOf: url)) ?? Data()
    check(data.starts(with: [0xEF, 0xBB, 0xBF]), "UTF-8 byte-order mark")
    let text = String(decoding: data.dropFirst(3), as: UTF8.self)
    let lines = text.components(separatedBy: "\r\n")
    check(lines.first == "Item,Amount,Share", "header row: \(lines.first ?? "")")
    check(lines.contains("Widgets,\"1,234.50\",12%"), "a quoted number with a comma")
    check(text.hasSuffix("\r\n") && !text.contains("\r\n\r\n\r\n"), "CRLF line endings")
}

@MainActor
private func writersPPTX() {
    guard let layout = writersLayout() else { return }
    let required = ["[Content_Types].xml", "_rels/.rels", "ppt/presentation.xml", "ppt/_rels/presentation.xml.rels", "ppt/presProps.xml",
                    "ppt/viewProps.xml", "ppt/tableStyles.xml", "ppt/slideMasters/slideMaster1.xml", "ppt/slideLayouts/slideLayout1.xml",
                    "ppt/theme/theme1.xml", "ppt/slides/slide1.xml", "ppt/slides/slide2.xml", "docProps/core.xml", "docProps/app.xml"]
    let pictures = writersFolder.appendingPathComponent("Slides.pptx")
    do { try PresentationWriter.write(layout, source: .data(writersFixture), picturesUnderText: true, to: pictures) } catch { check(false, "pptx: \(error)"); return }
    if let zip = writersCheckPackage(pictures, required: required + ["ppt/media/image1.jpeg", "ppt/media/image2.jpeg"], "pptx"),
       let presentation = try? XML.parse(zip.data("ppt/presentation.xml")!), let slide = try? XML.parse(zip.data("ppt/slides/slide1.xml")!) {
        check(presentation.first("sldSz")?.attr("cx") == "7772400" && presentation.first("sldSz")?.attr("cy") == "10058400", "the slide is the page's size")
        check(presentation.all("sldId").count == 2, "a slide per page")
        check(slide.all("pic").count == 1 && slide.all("sp").count >= 5, "a page picture under text boxes")
        let text = slide.allText
        check(text.contains("Quarterly Report") && text.contains("Apples are in season") && text.contains("1,234.50"), "editable text on the slide")
        check(slide.all("rPr").contains { $0.attr("b") == "1" && $0.attr("sz") == "2400" }, "the heading keeps its size and weight")
    }
    // The picture under the text has no text: the heading's area is white, while the full render has ink there.
    if case .success(let pictures)? = complete(300, { try OfficePictures.withoutText(.data(writersFixture), pages: [0], dpi: 72) }),
       let clean = pictures.page(0), let full = try? OfficePictures(.data(writersFixture), dpi: 72).page(0) {
        func ink(_ image: CGImage) -> Double {
            guard let crop = image.cropping(to: CGRect(x: 72, y: 792 - 744, width: 200, height: 30)) else { return 0 }
            let context = CGContext(data: nil, width: crop.width, height: crop.height, bitsPerComponent: 8, bytesPerRow: crop.width,
                                    space: CGColorSpaceCreateDeviceGray(), bitmapInfo: CGImageAlphaInfo.none.rawValue)!
            context.draw(crop, in: CGRect(x: 0, y: 0, width: crop.width, height: crop.height))
            let bytes = context.data!.assumingMemoryBound(to: UInt8.self)
            let count = crop.width * crop.height
            return (0..<count).reduce(0.0) { $0 + Double(255 - Int(bytes[$1])) } / Double(count * 255)
        }
        check(ink(full) > 0.05 && ink(clean) < 0.005, "text removed from the page picture (ink \(ink(full)) → \(ink(clean)))")
    } else {
        check(false, "pages render without text")
    }

    let textOnly = writersFolder.appendingPathComponent("Text only.pptx")
    try? PresentationWriter.write(layout, source: .data(writersFixture), picturesUnderText: false, to: textOnly)
    if let zip = writersCheckPackage(textOnly, required: required, "text-only pptx"), let slide = try? XML.parse(zip.data("ppt/slides/slide1.xml")!) {
        let title = slide.all("sp").first { $0.first("ph")?.attr("type") == "title" }
        check(title?.allText == "Quarterly Report", "the heading is the title")
        let body = slide.all("sp").first { $0.first("ph")?.attr("idx") == "1" }
        check(body?.allText.contains("Sales grew steadily") == true && body?.allText.contains("Pears ship next week") == true, "the rest is body text")
        check(!zip.entries.contains { $0.path.hasPrefix("ppt/media/") }, "no pictures in text-only slides")
    }
}

/// LibreOffice reads each file back into a PDF with the text in it (skipped when LibreOffice isn't installed).
@MainActor
private func writersLibreOffice() {
    guard let installation = ckInstalledLibreOffice() else { return }
    let profile = SuperPDFPaths.ensure(writersFolder.appendingPathComponent("lo-profile", isDirectory: true))
    let files: [(String, String)] = [("Flowing.docx", "Apples are in season"), ("Look.docx", "Quarterly Report"), ("Tables.xlsx", "Widgets"),
                                     ("Slides.pptx", "Quarterly Report"), ("Text only.pptx", "Pears ship next week")]
    for (name, phrase) in files {
        let input = writersFolder.appendingPathComponent(name)
        guard FileManager.default.fileExists(atPath: input.path) else { check(false, "\(name) was written"); continue }
        let out = writersFolder.appendingPathComponent("lo-" + UUID().uuidString, isDirectory: true)
        let result = complete(200) { try await LibreOffice.convert(input, with: installation, profile: profile, outputFolder: out) }
        guard case .success(let pdf)? = result, let document = PDFDocument(url: pdf) else {
            check(false, "LibreOffice converts \(name): \(String(describing: result))"); continue
        }
        let text = (document.string ?? "").replacingOccurrences(of: "\n", with: " ")
        check(text.contains(phrase), "LibreOffice reads “\(phrase)” from \(name)")
    }
}
