import AppKit
import BatchKit
import ConvertKit
import DocumentKit
import EditKit
import FixKit
import FormsKit
import LayoutKit
import MarkupKit
import PagesKit
import PDFKit
import PDFModelKit
import ProtectKit
import RenderKit
import ScanKit
@testable import SignKit
import SuperPDFCore
import ToolsKit
import UniformTypeIdentifiers

// The app's checks (WP16): `superpdf://` links, what Info.plist and the Quick Actions' plists promise against what the
// code does, and the end-to-end chains of ARCHITECTURE WP16 through the real modules, wired as the app wires them (with
// in-memory keys and no windows): a photographed page → recognise text → make smaller → PDF/A, run as one routine and
// checked; combine → sign with a certificate → verify; a request for signatures → its package → two returns → sealed
// and verified. Nothing is launched, shown, opened or sent.

func registerAppTests() {
    SelfTest.cases.append(("App.routes", { appRoutes() }))
    SelfTest.cases.append(("App.infoPlist", { appInfoPlist() }))
    SelfTest.cases.append(("App.quickActions", { appQuickActions() }))
    SelfTest.cases.append(("App.scanToArchive", { appScanToArchive() }))
    SelfTest.cases.append(("App.combineAndSign", { appCombineAndSign() }))
    SelfTest.cases.append(("App.requestToSeal", { appRequestToSeal() }))
    SelfTest.cases.append(("App.e2eOutputs", { appE2EOutputs() }))
}

private let repository = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()

private func appFolder(_ name: String) -> URL {
    SuperPDFPaths.ensure(scratch.appendingPathComponent("App-\(name)-\(UUID().uuidString)", isDirectory: true))
}

// MARK: - Links

@MainActor
private func appRoutes() {
    let files = [URL(fileURLWithPath: "/Users/me/Lease & terms – final.pdf"), URL(fileURLWithPath: "/tmp/Ünïcode #1?.docx")]
    for route in [AppRoute.open(files), .tool(.makeSmaller, files: files), .tool(.combineFiles, files: []), .open([])] {
        check(AppRoute(route.url) == route, "\(route.url.absoluteString) reads back")
    }
    check(AppRoute.tool(.recogniseText, files: [files[0]]).url.absoluteString.hasPrefix("superpdf://tool/recognise-text?file=/Users/me/Lease"),
          "the link's shape: \(AppRoute.tool(.recogniseText, files: [files[0]]).url.absoluteString)")
    check(AppRoute(URL(string: "superpdf://open?file=relative.pdf&file=/a.pdf")!) == .open([URL(fileURLWithPath: "/a.pdf")]), "relative paths are ignored")
    for bad in ["superpdf://tool/no-such-tool", "superpdf://tool", "superpdf://launch-missiles", "https://open?file=/a.pdf"] {
        check(AppRoute(URL(string: bad)!) == nil, "\(bad) is refused")
    }
}

// MARK: - Info.plist and entitlements against the code

@MainActor
private func appInfoPlist() {
    guard let info = NSDictionary(contentsOf: repository.appendingPathComponent("Resources/Info.plist")) as? [String: Any] else {
        check(false, "Resources/Info.plist reads"); return
    }
    check(info["CFBundleIdentifier"] as? String == SuperPDFPaths.bundleID && info["CFBundleExecutable"] as? String == "SuperPDF", "bundle id and executable")
    let schemes = (info["CFBundleURLTypes"] as? [[String: Any]])?.flatMap { $0["CFBundleURLSchemes"] as? [String] ?? [] } ?? []
    check(schemes == [SuperPDFPaths.urlScheme], "the superpdf:// scheme")
    let types = info["CFBundleDocumentTypes"] as? [[String: Any]] ?? []
    let pdf = types.first { ($0["LSItemContentTypes"] as? [String])?.contains(UTType.pdf.identifier) == true }
    check(pdf?["NSDocumentClass"] as? String == NSStringFromClass(PDFFileDocument.self) && pdf?["CFBundleTypeRole"] as? String == "Editor",
          "PDFs open as DocumentKit's document class, editable")
    check(pdf?["LSHandlerRank"] as? String == "Default" && types.filter { $0["CFBundleTypeName"] as? String != "PDF document" }.allSatisfy { $0["LSHandlerRank"] as? String == "Alternate" },
          "PDFs rank Default (Quick Look's Open with; a choice in Finder sticks), everything else Alternate")
    // Every file type the converters take is one Super PDF says it opens (Finder's Open With, the Dock).
    let claimed = types.flatMap { ($0["LSItemContentTypes"] as? [String] ?? []).compactMap(UTType.init) }
    let claimedExtensions = Set(types.flatMap { $0["CFBundleTypeExtensions"] as? [String] ?? [] })
    let imported = (info["UTImportedTypeDeclarations"] as? [[String: Any]] ?? []).flatMap {
        (($0["UTTypeTagSpecification"] as? [String: Any])?["public.filename-extension"] as? [String]) ?? []
    }
    let missing = ConverterTable.toPDF.flatMap(\.inputs).filter { ext in
        if claimedExtensions.contains(ext) || imported.contains(ext) { return false }
        // Packages (.rtfd) only resolve to their declared type as packages.
        let type = [UTType(filenameExtension: ext), UTType(filenameExtension: ext, conformingTo: .package)].compactMap { $0 }.first(where: \.isDeclared)
        return !(type.map { type in claimed.contains { type.conforms(to: $0) } } ?? false)
    }
    check(missing.isEmpty, "every convertible type is a document type: missing \(missing)")
    for key in ["NSCameraUsageDescription", "NSMicrophoneUsageDescription", "NSContactsUsageDescription", "NSAppleEventsUsageDescription"] {
        check((info[key] as? String)?.isEmpty == false, "\(key) says why")
    }
    check(info["NSCameraUseContinuityCameraDeviceType"] as? Bool == true, "Continuity Camera")
    check((info["NSServices"] as? [[String: Any]])?.first?["NSMessage"] as? String == "openSelectionAsPDF", "the Services item")
    check((info["LSMinimumSystemVersion"] as? String) == "14.0", "macOS 14")

    let entitlements = NSDictionary(contentsOf: repository.appendingPathComponent("Resources/SuperPDF.entitlements")) as? [String: Any] ?? [:]
    for key in ["com.apple.security.device.camera", "com.apple.security.device.audio-input", "com.apple.security.personal-information.addressbook",
                "com.apple.security.automation.apple-events"] {
        check(entitlements[key] as? Bool == true, "entitlement \(key)")
    }
    check(entitlements["com.apple.security.app-sandbox"] == nil, "the app isn't sandboxed")
}

@MainActor
private func appQuickActions() {
    let folder = repository.appendingPathComponent("Resources/QuickActions", isDirectory: true)
    let plists = ((try? FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil)) ?? []).filter { $0.pathExtension == "plist" }
    check(Set(plists.map { $0.deletingPathExtension().lastPathComponent }) == Set(QuickAction.allCases.map(\.bundleName)), "one plist per Quick Action")
    check(QuickAction.allCases.map(\.title) == ["Combine in Super PDF", "Make Smaller", "Convert to PDF", "Recognise Text"], "features §2.5's names")
    for action in QuickAction.allCases {
        guard let info = NSDictionary(contentsOf: folder.appendingPathComponent(action.bundleName + ".plist")) as? [String: Any] else {
            check(false, "\(action.bundleName).plist reads"); continue
        }
        check(QuickAction(bundleInfo: info) == action, "\(action.title): says which action it is")
        check(info["CFBundleIdentifier"] as? String == action.bundleID && info["CFBundleDisplayName"] as? String == action.title, "\(action.title): id and name")
        let ext = info["NSExtension"] as? [String: Any] ?? [:]
        let attributes = ext["NSExtensionAttributes"] as? [String: Any] ?? [:]
        check(ext["NSExtensionPointIdentifier"] as? String == "com.apple.services" && ext["NSExtensionPrincipalClass"] as? String == "QuickActionRequestHandler",
              "\(action.title): a Finder action entered through its handler")
        let rule = attributes["NSExtensionActivationRule"] as? String ?? ""
        check(rule.contains(action.acceptsPDFsOnly ? "com.adobe.pdf" : "public.item"), "\(action.title): shows for the right files")
        check(attributes["NSExtensionServiceAllowsFinderPreviewItem"] as? Bool == true, "\(action.title): in Finder's Quick Actions")
        let route = AppRoute(AppRoute.tool(action.tool, files: [URL(fileURLWithPath: "/a.pdf")]).url)
        check(route == .tool(action.tool, files: [URL(fileURLWithPath: "/a.pdf")]), "\(action.title): its link reaches \(action.tool.rawValue)")
    }
    check(QuickAction.allCases.filter { ToolCatalog.tile($0.tool).needsDocument }.allSatisfy { BatchKitModule.canRun($0.tool) },
          "Quick Actions for document tools can run on several files")
}

// MARK: - The app's modules, wired as the app wires them

@MainActor
private final class AppPrompter: DocumentPrompting {
    func password(for fileName: String, retry: Bool) async -> String? { nil }
    func confirmRepair(of fileName: String, canRepair: Bool) async -> Bool { canRepair }
    func firstSave(of fileName: String, window: NSWindow?) async -> (answer: FirstSaveAnswer, always: Bool)? { nil }
    func closeWithUnsavedChanges(window: NSWindow?) async -> CloseAnswer { .discard }
    func saveLocation(proposing proposal: URL, window: NSWindow?) async -> URL? { proposal }
    func ownerPassword(for fileName: String, retry: Bool, window: NSWindow?) async -> String? { nil }
}

@MainActor
private final class AppSharing: RequestSharing {
    var sent: [URL] = []
    func share(_ file: URL, to recipients: [String], subject: String, message: String, via channel: SharingChannel) throws { sent.append(file) }
}

/// Every module in the launch sequence's order, with in-memory signing keys, no windows and nothing shown in Finder.
@MainActor
@discardableResult
private func installApp(_ folder: URL) -> DocumentManager {
    installFakes()
    let manager = DocumentManager(controller: NSDocumentController(), prompter: AppPrompter(),
                                  autosaveFolder: folder.appendingPathComponent("Autosave", isDirectory: true),
                                  fallbackFolder: SuperPDFPaths.ensure(folder.appendingPathComponent("Desktop", isDirectory: true)),
                                  displaysWindows: false, notesSystemRecents: false)
    Services.documents = manager
    LayoutKitModule.install()
    RenderKitModule.install()
    PagesKitModule.install()
    ConvertKitModule.install()
    EditKitModule.install()
    MarkupKitModule.install()
    FormsKitModule.install()
    SignKitModule.install(keys: MemorySigningKeyStore(), signatureKey: MemorySignatureKey(), sharing: AppSharing())
    ProtectKitModule.install()
    FixKitModule.install()
    ScanKitModule.install()
    var batch = BatchEnvironment()
    batch.reveal = { _ in }
    BatchKitModule.install(environment: batch)
    ToolsKitModule.install()
    return manager
}

@MainActor
private func closeAll(_ manager: DocumentManager) {
    for handle in manager.openDocuments {
        manager.document(for: handle)?.updateChangeCount(.changeCleared)
        manager.document(for: handle)?.close()
    }
    installFakes()
}

@MainActor
private func await_<T>(_ what: String, _ work: @escaping @MainActor () async throws -> T) -> T? {
    switch complete(300, work) {
    case .success(let value)?: return value
    case .failure(let error)?: check(false, "\(what): \(error)"); return nil
    case nil: check(false, "\(what): timed out"); return nil
    }
}

private func text(_ url: URL) -> String { PDFDocument(url: url)?.string ?? "" }

// MARK: - Scan → recognise text → make smaller → PDF/A

@MainActor
private func appScanToArchive() {
    let folder = appFolder("scan")
    let manager = installApp(folder)
    defer { closeAll(manager) }

    // From a photo: find the sheet, straighten it, clean it up, make it a PDF page.
    guard let page = await_("scan", { () -> ScannedPage in
        let photo = scanFixturePhoto()
        guard let found = try await Services.scan.detectDocument(in: photo) else { throw FakeError(message: "no sheet found") }
        return try await Services.scan.cleanUp(try await Services.scan.straighten(photo, to: found), options: CleanUpOptions())
    }) else { return }
    let picture = folder.appendingPathComponent("Scan.jpg"), scan = folder.appendingPathComponent("Scan.pdf")
    try? page.image.write(to: picture)
    guard await_("picture → PDF", { try await Services.convert.convert(ConversionJob(inputs: [picture], output: .pdf, destination: scan), progress: .ignored) }) != nil
    else { return }
    check(PDFDocument(url: scan)?.pageCount == 1 && text(scan).trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, "a scanned page: a picture, no text yet")

    // "OCR, compress, PDF/A" as one routine on the file, every step through its tile's own provider.
    let routine = Routine(name: "Archive scans", pipeline: BatchPipeline(steps: [BatchStep(tool: .recogniseText), BatchStep(tool: .makeSmaller),
                                                                                  BatchStep(tool: .forArchiving)]))
    try? Services.batch.save(routine)
    var events: [BatchEvent] = []
    _ = await_("routine") { for try await event in Services.batch.run(routine.pipeline, on: [scan]) { events.append(event) } }
    let failures = events.compactMap { if case .failed(_, let message) = $0 { message } else { nil } }
    check(failures.isEmpty, "every step ran: \(failures)")
    guard let archive = events.compactMap({ if case .finished(_, let made) = $0 { made.first } else { nil } }).first else {
        check(false, "the routine made a file"); return
    }
    check(archive.lastPathComponent == "Scan (archive).pdf" && archive.deletingLastPathComponent() == folder, "named by its last step, next to the scan")
    check(text(archive).lowercased().contains("quick brown fox"), "the text was recognised and survives: \(text(archive).prefix(80))")
    let issues = await_("PDF/A check") { try await Services.fix.check(.file(archive), profile: .pdfA(.a2b), progress: .ignored) } ?? []
    check(!issues.contains { $0.severity == .failed }, "it passes the PDF/A-2b check: \(issues.filter { $0.severity == .failed }.map(\.title))")
    check(FileManager.default.fileExists(atPath: scan.path) && text(scan).trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, "the scan itself is unchanged")
}

// MARK: - Combine → sign → verify

@MainActor
private func appCombineAndSign() {
    let folder = appFolder("combine")
    let manager = installApp(folder)
    defer { closeAll(manager) }
    let lease = folder.appendingPathComponent("Lease.pdf"), schedule = folder.appendingPathComponent("Schedule.pdf")
    try? makePDF(pages: 2).write(to: lease)
    try? makePDF(pages: 1).write(to: schedule)

    // Combine files, as from the welcome window: the queue, then a new document "Combined".
    guard let provider = Services.tools.provider(for: .combineFiles) else { check(false, "Combine has a provider"); return }
    let session = ToolSession(tool: .combineFiles, provider: provider, document: nil, inputs: [lease, schedule])
    check(session.panel.primary.title == "Combine 2 files" && session.canRun, "Combine 2 files")
    _ = await_("combine") { await session.run() }
    guard let combined = manager.openDocuments.first(where: { $0.displayName == "Combined" }) else { check(false, "Combined opened"); return }
    check(combined.pageCount == 3 && combined.state.origin == .createdHere, "3 pages, made here")
    let combinedURL = folder.appendingPathComponent("Combined.pdf")
    try? combined.snapshot().bytes().write(to: combinedURL)

    // Sign with a certificate made on this Mac, then verify: valid, nothing changed since.
    guard let identity = await_("identity", { try await Services.sign.createIdentity(name: "Udaya Vijay Anand", email: nil) }) else { return }
    let signed = folder.appendingPathComponent("Combined (signed).pdf")
    _ = await_("sign") {
        try await Services.sign.sign(.file(combinedURL), options: CertificateSignOptions(identityID: identity.id, page: 2,
                                                                                          rect: CGRect(x: 72, y: 72, width: 200, height: 60),
                                                                                          reason: "I agree"), to: signed)
    }
    guard let first = await_("verify", { try await Services.sign.verify(.file(signed)) }), let report = first.first else {
        check(false, "the signature is found"); return
    }
    check(first.count == 1 && report.signerName == "Udaya Vijay Anand" && !report.changedAfterSigning, "one signature by its signer: \(first)")
    check(report.validity == .valid, "the person's own certificate verifies: \(report.validity)")
    check(PDFDocument(url: signed)?.pageCount == 3, "the signed copy keeps every page")

    // A change after signing is caught.
    if var bytes = try? Data(contentsOf: signed), let range = bytes.range(of: Data("Page 1".utf8)) {
        bytes.replaceSubrange(range, with: Data("Page X".utf8))
        let tampered = folder.appendingPathComponent("Tampered.pdf")
        try? bytes.write(to: tampered)
        let after = await_("verify tampered") { try await Services.sign.verify(.file(tampered)) }
        check(after?.first.map { $0.validity == .modified || $0.validity == .invalid } ?? true, "changed bytes don't verify: \(String(describing: after))")
    }
}

// MARK: - Request signatures → package → returns → seal

@MainActor
private func appRequestToSeal() {
    let folder = appFolder("request")
    let manager = installApp(folder)
    defer { closeAll(manager) }
    let lease = folder.appendingPathComponent("Lease agreement.pdf")
    try? makePDF(pages: 1).write(to: lease)
    guard let document = await_("open", { try await manager.open(lease) }) else { return }

    let margaret = Signer(name: "Margaret Ellison", email: "m.ellison@example.com", color: "#FF9500", order: 0)
    let priya = Signer(name: "Priya Natarajan", email: "priya@example.com", color: "#AF52DE", order: 1)
    let request = SignatureRequest(documentName: "Lease agreement", signers: [margaret, priya], fields: [
        RequestField(kind: .signature, signerID: margaret.id, page: 0, rect: CGRect(x: 72, y: 120, width: 180, height: 40)),
        RequestField(kind: .date, signerID: margaret.id, page: 0, rect: CGRect(x: 72, y: 80, width: 120, height: 24)),
        RequestField(kind: .signature, signerID: priya.id, page: 0, rect: CGRect(x: 340, y: 120, width: 180, height: 40)),
    ])
    let requests = Services.requests!
    try? requests.save(request)
    guard let package = await_("package", { try await requests.makePackage(for: request, from: document) }),
          let packageData = try? Data(contentsOf: package), let model = try? PDFModel(data: packageData) else { return }
    check(model.pageCount == 2 && model.formFields().filter { $0.type == "Sig" }.count == 2, "the package: a cover, the page, the fields")

    // Margaret signs in another app: her name in her box, the date in its field.
    guard let other = PDFDocument(data: packageData), let page = other.page(at: 1) else { check(false, "the package opens"); return }
    let note = PDFAnnotation(bounds: request.fields[0].rect, forType: .freeText, withProperties: nil)
    note.contents = "Margaret Ellison"
    note.color = .clear
    page.addAnnotation(note)
    page.annotations.first { $0.fieldName?.contains("-date-") == true }?.widgetStringValue = "21 Oct 2026"
    let margaretCopy = folder.appendingPathComponent("Lease agreement – Margaret.pdf")
    other.write(to: margaretCopy)
    let afterMargaret = await_("Margaret's copy") { try await requests.receive(margaretCopy) } ?? nil
    check(afterMargaret?.signers.first?.state == .done && afterMargaret?.isComplete == false, "Margaret is done: \(afterMargaret?.signers.map(\.state) ?? [])")

    // Priya signs in Super PDF with her certificate, in her field, on the copy so far.
    let current = SuperPDFPaths.request(request.id).appendingPathComponent("current/Lease agreement.pdf")
    guard let identity = await_("identity", { try await Services.sign.createIdentity(name: "Priya Natarajan", email: nil) }) else { return }
    let priyaCopy = folder.appendingPathComponent("Lease agreement (signed by Priya).pdf")
    _ = await_("Priya signs") {
        try await Services.sign.sign(.file(current), options: CertificateSignOptions(identityID: identity.id, page: 1, rect: request.fields[2].rect), to: priyaCopy)
    }
    guard let complete = await_("Priya's copy", { try await requests.receive(priyaCopy) }) ?? nil else { check(false, "Priya's copy is matched"); return }
    check(complete.isComplete, "everyone signed: \(complete.signers.map(\.state))")

    // Seal and finish: an audit page and the sender's certificate; both signatures check out.
    guard let sender = await_("sender", { try await Services.sign.createIdentity(name: "Udaya Vijay Anand", email: nil) }),
          let sealed = await_("seal", { try await requests.seal(complete, identityID: sender.id) }) else { return }
    check(PDFDocument(url: sealed)?.page(at: (PDFDocument(url: sealed)?.pageCount ?? 1) - 1)?.string?.contains("Signature record") == true,
          "an audit page at the end")
    let reports = await_("verify sealed") { try await Services.sign.verify(.file(sealed)) } ?? []
    check(reports.count == 2 && reports.allSatisfy { $0.validity != .modified && $0.validity != .invalid } && reports.last?.changedAfterSigning == false,
          "the seal and Priya's signature are intact: \(reports.map(\.validity))")
    check(requests.requests.first { $0.id == request.id }?.sealedAt != nil, "the request is sealed")
}

// MARK: - The GUI run's outputs, made headlessly (scripts/e2e.sh)

/// What scripts/e2e.sh asks of the real app — Make smaller, Combine, Black out, Sign (a placed signature), To Word — done
/// here through the same panels without a window, then checked by the script's own verifier
/// (`swift scripts/e2e-check.swift verify`), so the GUI run's checks are known to pass when the app does its job.
@MainActor
private func appE2EOutputs() {
    let folder = appFolder("e2e")
    let manager = installApp(folder)
    defer { closeAll(manager) }
    guard tool("/usr/bin/swift", "scripts/e2e-check.swift", "fixtures", folder.path) == 0 else { check(false, "the e2e fixtures are written"); return }
    let lease = folder.appendingPathComponent("Lease.pdf"), schedule = folder.appendingPathComponent("Schedule.pdf")
    guard let document = await_("open", { try await manager.open(lease) }) else { return }
    func session(_ tool: ToolID, inputs: [URL] = []) -> ToolSession? {
        Services.tools.provider(for: tool).map { ToolSession(tool: tool, provider: $0, document: document, inputs: inputs) }
    }

    guard let smaller = session(.makeSmaller) else { check(false, "Make smaller"); return }
    _ = await_("estimates") { await smaller.updatePreview() }
    _ = await_("make smaller") { await smaller.run() }
    check(smaller.message == nil, "Make smaller ran: \(smaller.message?.text ?? "")")

    guard let combine = session(.combineFiles, inputs: [schedule]) else { check(false, "Combine"); return }
    _ = await_("combine") { await combine.run() }
    if let combined = manager.openDocuments.first(where: { $0.displayName == "Combined" }) {
        try? combined.snapshot().bytes().write(to: folder.appendingPathComponent("Combined.pdf"))
    } else { check(false, "Combine made a document") }

    guard let blackOut = session(.blackOut) else { check(false, "Black out"); return }
    blackOut.set("mode", .string("find"))
    blackOut.set("query", .string("CONFIDENTIAL"))
    _ = await_("find") { await blackOut.updatePreview() }
    check(blackOut.panel.primary.title.hasPrefix("Black out 1"), "found once: \(blackOut.panel.primary.title)")
    _ = await_("black out") { await blackOut.run() }

    let signature = SavedSignature(kind: .signature, image: SignatureInk.typed("Udaya Vijay Anand", fontName: SignatureInk.scriptFonts.first ?? "")
                                       ?? Data())
    try? Services.sign.save(signature)
    if let group = try? Services.sign.place(signature, on: 1, in: CGRect(x: 230, y: 650, width: 180, height: 50), document: document) {
        let work = SuperPDFPaths.ensure(folder.appendingPathComponent("work", isDirectory: true))
        _ = await_("place") { try await manager.apply(.inPlace(undoable: group, banner: nil), of: ToolRequest(tool: .sign, document: document, workFolder: work)) }
        try? document.snapshot().bytes().write(to: folder.appendingPathComponent("Lease (signed).pdf"))
    } else { check(false, "the signature is placed") }

    guard let word = session(.toWord) else { check(false, "To Word"); return }
    _ = await_("to word") { await word.run() }

    check(tool("/usr/bin/swift", "scripts/e2e-check.swift", "verify", folder.path) == 0, "the GUI run's checks pass on these outputs")
}

/// Runs a command line tool from the repository's folder; its exit status (output goes to the log).
@discardableResult
private func tool(_ path: String, _ arguments: String...) -> Int32 {
    let process = Process()
    process.executableURL = URL(fileURLWithPath: path)
    process.arguments = arguments
    process.currentDirectoryURL = repository
    guard (try? process.run()) != nil else { return -1 }
    while process.isRunning { RunLoop.main.run(until: Date().addingTimeInterval(0.05)) }
    return process.terminationStatus
}
