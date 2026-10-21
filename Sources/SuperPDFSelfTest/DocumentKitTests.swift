import AppKit
import Combine
import DocumentKit
import PDFKit
import PDFModelKit
import SuperPDFCore
import UniformTypeIdentifiers

// DocumentKit's checks (WP3): naming collisions, the save-policy state machine, the password and repair flows, undo and
// redo of page operations and engine edits, the save flow (autosave never touches the original before the first
// choice; Save a copy / Replace), applying tool results, recents and view state. Every file lives in a fresh temporary
// folder; no window, panel or alert is shown (a scripted prompter answers).

/// A handle over a file as DocumentKit opens one: the file's bytes are its authoritative contents, so saves keep its
/// structure (`DocumentBaseline`). Module tests that save use it.
@MainActor
func openedHandle(_ url: URL, state: DocumentState = DocumentState()) -> DocumentHandle {
    let handle = DocumentHandle(url: url, pdf: DocumentBaseline.document(url: url)!, state: state, undoManager: makeUndoManager())
    if let bytes = try? Data(contentsOf: url) { DocumentBaseline.attach(bytes, to: handle) }
    return handle
}

func registerDocumentKitTests() {
    SelfTest.cases.append(("DocumentKit.naming", { documentKitNaming() }))
    SelfTest.cases.append(("DocumentKit.savePolicy", { documentKitSavePolicy() }))
    SelfTest.cases.append(("DocumentKit.passwordFlow", { documentKitPasswordFlow() }))
    SelfTest.cases.append(("DocumentKit.repairFlow", { documentKitRepairFlow() }))
    SelfTest.cases.append(("DocumentKit.undoPageOperations", { documentKitUndo() }))
    SelfTest.cases.append(("DocumentKit.saveFlow", { documentKitSaveFlow() }))
    SelfTest.cases.append(("DocumentKit.applyResults", { documentKitApplyResults() }))
    SelfTest.cases.append(("DocumentKit.recentsAndViewState", { documentKitRecentsAndViewState() }))
    SelfTest.cases.append(("DocumentKit.saveFidelity", { documentKitSaveFidelity() }))
    SelfTest.cases.append(("DocumentKit.saveFidelityPagesRemoved", { documentKitSaveFidelityPagesRemoved() }))
    SelfTest.cases.append(("DocumentKit.saveFidelityEngineEdit", { documentKitSaveFidelityEngineEdit() }))
    SelfTest.cases.append(("DocumentKit.saveFidelityEncrypted", { documentKitSaveFidelityEncrypted() }))
    SelfTest.cases.append(("DocumentKit.saveFidelityPageInserted", { documentKitSaveFidelityPageInserted() }))
    SelfTest.cases.append(("DocumentKit.saveRemovedPagePrivacy", { documentKitSaveRemovedPagePrivacy() }))
    SelfTest.cases.append(("DocumentKit.saveXMP", { documentKitSaveXMP() }))
    SelfTest.cases.append(("DocumentKit.saveTracking", { documentKitSaveTracking() }))
    SelfTest.cases.append(("DocumentKit.performance", { documentKitPerformance() }))
}

// MARK: - Fixtures

/// A fresh folder for one case.
private func tempFolder(_ name: String) -> URL {
    SuperPDFPaths.ensure(scratch.appendingPathComponent("DocumentKit-\(name)-\(UUID().uuidString)", isDirectory: true))
}

/// A PDF that needs `password` to open.
private func makeEncryptedPDF(pages: Int, password: String) -> Data {
    let data = NSMutableData()
    var box = CGRect(x: 0, y: 0, width: 612, height: 792)
    let info = [kCGPDFContextUserPassword: password, kCGPDFContextOwnerPassword: password + "-owner"] as CFDictionary
    guard let consumer = CGDataConsumer(data: data as CFMutableData), let context = CGContext(consumer: consumer, mediaBox: &box, info) else {
        return Data()
    }
    for _ in 0..<pages { context.beginPDFPage(nil); context.endPDFPage() }
    context.closePDF()
    return data as Data
}

/// A PDF with its cross-reference table and trailer cut off, which PDFKit can't open.
private func makeDamagedPDF() -> Data {
    let good = makePDF(pages: 3)
    return good.prefix(good.count - 400)
}

/// Answers DocumentKit's questions from a script and records what was asked.
@MainActor
private final class ScriptedPrompter: DocumentPrompting {
    var passwords: [String?] = []
    var passwordAsks: [Bool] = []
    var repairAnswer = true
    var repairAsks: [Bool] = []
    var firstSaveAnswer: (answer: FirstSaveAnswer, always: Bool)?
    var firstSaveAsks = 0
    var closeAnswer: CloseAnswer = .cancel
    /// nil accepts the proposal.
    var saveLocation: URL?
    var proposals: [URL] = []

    func password(for fileName: String, retry: Bool) async -> String? {
        passwordAsks.append(retry)
        return passwords.isEmpty ? nil : passwords.removeFirst()
    }
    func confirmRepair(of fileName: String, canRepair: Bool) async -> Bool { repairAsks.append(canRepair); return repairAnswer && canRepair }
    func firstSave(of fileName: String, window: NSWindow?) async -> (answer: FirstSaveAnswer, always: Bool)? { firstSaveAsks += 1; return firstSaveAnswer }
    func closeWithUnsavedChanges(window: NSWindow?) async -> CloseAnswer { closeAnswer }
    func saveLocation(proposing proposal: URL, window: NSWindow?) async -> URL? { proposals.append(proposal); return saveLocation ?? proposal }
    func ownerPassword(for fileName: String, retry: Bool, window: NSWindow?) async -> String? {
        passwordAsks.append(retry)
        return passwords.isEmpty ? nil : passwords.removeFirst()
    }
}

/// QPDF recovery stand-in: writes a good 3-page PDF.
@MainActor
private final class StubRepairer: Repairing {
    var repaired: [PDFSource] = []
    func diagnose(_ url: URL) async -> RepairDiagnosis? { nil }
    func repair(_ source: PDFSource, embedFonts: Bool, to destination: URL) async throws -> RepairDiagnosis {
        repaired.append(source)
        try makePDF(pages: 3).write(to: destination)
        return RepairDiagnosis(problems: ["The file’s index is damaged."])
    }
    func linearize(_ source: PDFSource, to destination: URL) async throws {}
}

/// A manager with fakes around it, no windows and no system recents.
@MainActor
private func makeManager(_ folder: URL, prompter: ScriptedPrompter, repairer: Repairing? = nil) -> DocumentManager {
    installFakes()
    let manager = DocumentManager(controller: NSDocumentController(), prompter: prompter, repairer: { repairer },
                                  autosaveFolder: folder.appendingPathComponent("Autosave", isDirectory: true),
                                  fallbackFolder: SuperPDFPaths.ensure(folder.appendingPathComponent("Desktop", isDirectory: true)),
                                  displaysWindows: false, notesSystemRecents: false)
    Services.documents = manager
    return manager
}

@MainActor
private func closeAll(_ manager: DocumentManager) {
    for handle in manager.openDocuments {
        guard let document = manager.document(for: handle) else { continue }
        document.updateChangeCount(.changeCleared)
        document.close()
    }
}

// MARK: - Cases

@MainActor
private func documentKitNaming() {
    let folder = tempFolder("naming")
    let manager = makeManager(folder, prompter: ScriptedPrompter())
    let original = folder.appendingPathComponent("Report.pdf")
    try? makePDF(pages: 2).write(to: original)
    let document = makeDocument(pages: 2, url: original)

    let smaller = manager.destination(for: .sibling(.smaller, ext: "pdf"), of: document, source: nil)
    check(smaller == folder.appendingPathComponent("Report (smaller).pdf"), "sibling name next to the original")
    try? Data("x".utf8).write(to: folder.appendingPathComponent("Report (smaller).pdf"))
    check(manager.destination(for: .sibling(.smaller, ext: "pdf"), of: document, source: nil)?.lastPathComponent == "Report (smaller) 2.pdf",
          "a collision gets “ 2”")
    try? Data("x".utf8).write(to: folder.appendingPathComponent("Report (smaller) 2.pdf"))
    check(manager.destination(for: .sibling(.smaller, ext: "pdf"), of: document, source: nil)?.lastPathComponent == "Report (smaller) 3.pdf",
          "then “ 3”")
    check(manager.destination(for: .sibling(.part(1), ext: "pdf"), of: document, source: nil)?.lastPathComponent == "Report – part 1.pdf", "parts")
    check(manager.destination(for: .sameName(ext: "docx"), of: document, source: nil)?.lastPathComponent == "Report.docx", "same name, new format")
    try? FileManager.default.createDirectory(at: folder.appendingPathComponent("Report parts"), withIntermediateDirectories: true)
    check(manager.destination(for: .folder(.parts), of: document, source: nil)?.lastPathComponent == "Report parts 2", "folders get “ 2” too")
    check(manager.destination(for: .inPlace, of: document, source: nil) == nil, "in place has no destination")
    check(manager.destination(for: .newDocument(name: "Combined"), of: document, source: nil) == nil, "new documents have none")
    let untitled = makeDocument(pages: 1)
    check(manager.destination(for: .sibling(.smaller, ext: "pdf"), of: untitled, source: nil)?.deletingLastPathComponent().lastPathComponent == "Desktop",
          "unsaved documents write to the fallback folder")
    let source = folder.appendingPathComponent("Scan.pdf")
    check(manager.destination(for: .sibling(.clean, ext: "pdf"), of: nil, source: source)?.lastPathComponent == "Scan (clean).pdf", "named after a source file")

    // A read-only folder falls back rather than failing later.
    let locked = SuperPDFPaths.ensure(folder.appendingPathComponent("Locked", isDirectory: true))
    try? FileManager.default.setAttributes([.posixPermissions: 0o555], ofItemAtPath: locked.path)
    check(OutputNaming.folder(for: locked.appendingPathComponent("A.pdf"), fallback: folder) == folder, "unwritable folder → fallback")
    try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: locked.path)

    // Placing never replaces a file that appeared meanwhile.
    let work = SuperPDFPaths.ensure(folder.appendingPathComponent("work", isDirectory: true))
    let output = work.appendingPathComponent("out.pdf")
    try? Data("new".utf8).write(to: output)
    let taken = folder.appendingPathComponent("Taken.pdf")
    try? Data("keep me".utf8).write(to: taken)
    let placed = try? OutputNaming.place(output, at: taken)
    check(placed?.lastPathComponent == "Taken 2.pdf", "placing beside an existing file numbers it")
    check((try? Data(contentsOf: taken)) == Data("keep me".utf8), "the existing file is untouched")
    check(placed.map { (try? Data(contentsOf: $0)) == Data("new".utf8) } == true && !FileManager.default.fileExists(atPath: output.path),
          "the output moved")
    let madeFolder = try? OutputNaming.makeFolder(at: folder.appendingPathComponent("Report parts"))
    check(madeFolder?.lastPathComponent == "Report parts 2", "folder creation numbers too")
    closeAll(manager)
}

@MainActor
private func documentKitSavePolicy() {
    typealias P = SavePolicy
    check(P.step(origin: .createdHere, hasFile: false, choice: nil, wasRepaired: false, setting: .ask) == .savePanel, "made here: save panel")
    check(P.step(origin: .createdHere, hasFile: true, choice: nil, wasRepaired: false, setting: .ask) == .save, "made here, saved once: save")
    check(P.step(origin: .opened, hasFile: true, choice: nil, wasRepaired: false, setting: .ask) == .ask, "first ⌘S asks")
    check(P.step(origin: .opened, hasFile: true, choice: nil, wasRepaired: false, setting: .alwaysSaveCopy) == .saveCopy, "setting: copy")
    check(P.step(origin: .opened, hasFile: true, choice: nil, wasRepaired: false, setting: .replaceOriginal) == .replaceOriginal, "setting: replace")
    check(P.step(origin: .opened, hasFile: true, choice: nil, wasRepaired: true, setting: .replaceOriginal) == .ask,
          "a repaired file is never replaced without asking")
    check(P.step(origin: .opened, hasFile: true, choice: nil, wasRepaired: true, setting: .alwaysSaveCopy) == .saveCopy, "repaired + copy setting")
    check(P.step(origin: .opened, hasFile: true, choice: .replaceOriginal, wasRepaired: false, setting: .ask) == .save, "after Replace: save")
    check(P.step(origin: .opened, hasFile: true, choice: .alwaysSaveCopy, wasRepaired: false, setting: .ask) == .save, "after a copy: save to it")
    check(!P.mayWriteInPlace(origin: .opened, hasFile: true, choice: nil), "no in-place writes before the first choice")
    check(P.mayWriteInPlace(origin: .opened, hasFile: true, choice: .replaceOriginal), "in place after Replace")
    check(!P.mayWriteInPlace(origin: .createdHere, hasFile: false, choice: nil), "untitled autosaves elsewhere")
    check(P.resolve(.saveCopy, always: false) == (.saveCopy, nil), "copy once")
    check(P.resolve(.saveCopy, always: true) == (.saveCopy, .alwaysSaveCopy), "copy always")
    check(P.resolve(.replaceOriginal, always: true) == (.replaceOriginal, .replaceOriginal), "replace always")
}

@MainActor
private func documentKitPasswordFlow() {
    let folder = tempFolder("password")
    let prompter = ScriptedPrompter()
    let manager = makeManager(folder, prompter: prompter)
    let url = folder.appendingPathComponent("Secret.pdf")
    try? makeEncryptedPDF(pages: 2, password: "open sesame").write(to: url)

    prompter.passwords = ["wrong", "open sesame"]
    guard case .success(let handle)? = complete(300, { try await manager.open(url) }) else { check(false, "opens with the right password"); return }
    check(prompter.passwordAsks == [false, true], "asks, then says “Invalid password” once")
    check(handle.password == "open sesame" && handle.state.isEncrypted && !handle.pdf.isLocked && handle.pageCount == 2, "unlocked")
    check(!handle.state.isEdited && handle.state.origin == .opened, "fresh and unedited")
    check(handle.snapshot() == .file(url, password: "open sesame"), "engines get the file and the password")

    prompter.passwordAsks = []
    let again = complete(300, { try await manager.open(url) })
    check((try? again?.get()) === handle && prompter.passwordAsks.isEmpty, "an open file is brought forward, not opened twice")
    closeAll(manager)

    prompter.passwords = [nil]
    let cancelled = complete(300, { try await manager.open(url) })
    if case .failure(let error)? = cancelled {
        check((error as? CocoaError)?.code == .userCancelled, "Cancel cancels quietly")
    } else { check(false, "Cancel doesn’t open") }
    check(manager.openDocuments.isEmpty, "nothing is left open after Cancel")
}

@MainActor
private func documentKitRepairFlow() {
    let folder = tempFolder("repair")
    let url = folder.appendingPathComponent("Report.pdf")
    let damaged = makeDamagedPDF()
    try? damaged.write(to: url)
    check(PDFDocument(url: url) == nil, "the fixture is damaged")

    // No repairer installed: only OK, nothing opens.
    let bare = ScriptedPrompter()
    let bareManager = makeManager(folder, prompter: bare, repairer: nil)
    if case .failure? = complete(300, { try await bareManager.open(url) }) {} else { check(false, "can’t open without repair") }
    check(bare.repairAsks == [false], "the damaged message offers no Repair without a repairer")

    // Cancel at the repair question.
    let prompter = ScriptedPrompter()
    let repairer = StubRepairer()
    let manager = makeManager(folder, prompter: prompter, repairer: repairer)
    prompter.repairAnswer = false
    if case .failure(let error)? = complete(300, { try await manager.open(url) }) {
        check((error as? CocoaError)?.code == .userCancelled && repairer.repaired.isEmpty, "Cancel doesn’t repair")
    } else { check(false, "Cancel doesn’t open") }

    // Repair.
    prompter.repairAnswer = true
    guard case .success(let handle)? = complete(300, { try await manager.open(url) }) else { check(false, "repaired file opens"); return }
    check(prompter.repairAsks == [true, true], "asked each time")
    check(repairer.repaired == [.file(url)], "QPDF recovery ran on the file")
    check(handle.state.wasRepaired && handle.state.isEdited && handle.pageCount == 3, "opened repaired, as unsaved changes")
    check((try? Data(contentsOf: url)) == damaged, "the damaged original is untouched")
    let banners = (Services.viewer as? FakeViewer)?.banners.map(\.text) ?? []
    check(banners == [Strings.Errors.repaired("Report.pdf")], "says it was repaired and to save a copy")
    Defaults[.saveBehaviour] = .replaceOriginal
    check(manager.document(for: handle)?.saveStep == .ask, "even “Always replace” asks for a repaired file")
    Defaults.reset(.saveBehaviour)
    closeAll(manager)
}

@MainActor
private func documentKitUndo() {
    let folder = tempFolder("undo")
    let manager = makeManager(folder, prompter: ScriptedPrompter())
    let url = folder.appendingPathComponent("Report.pdf")
    let diskBytes = makePDF(pages: 4)
    try? diskBytes.write(to: url)
    guard case .success(let handle)? = complete(300, { try await manager.open(url) }), let undo = handle.undoManager else {
        check(false, "opens with an undo manager"); return
    }
    var changes = 0
    let watcher = manager.events.sink { if case .changed(handle.id) = $0 { changes += 1 } }

    // Rotate page 1 and delete page 3 as one step, the way PagesKit hands them over.
    let page1 = handle.pdf.page(at: 0)!, page3 = handle.pdf.page(at: 2)!
    page1.rotation = 90
    handle.pdf.removePage(at: 2)
    let rotate = UndoGroup("Rotate", undo: { page1.rotation = 0 }, redo: { page1.rotation = 90 })
    let delete = UndoGroup("Delete", undo: { handle.pdf.insert(page3, at: 2) }, redo: { handle.pdf.removePage(at: 2) })
    let request = ToolRequest(tool: .rotatePages, document: handle, workFolder: SuperPDFPaths.work)
    _ = complete(300, { try await manager.apply(.inPlace(undoable: .combined("Rotate and Delete Pages", [rotate, delete]), banner: nil), of: request) })
    check(undo.canUndo && undo.undoActionName == "Rotate and Delete Pages", "one named undo step")
    check(handle.state.isEdited && changes >= 1, "edited, and announced")
    undo.undo()
    check(handle.pageCount == 4 && handle.pdf.page(at: 0)?.rotation == 0 && handle.pdf.page(at: 2) === page3, "undo restores both")
    check(!handle.state.isEdited, "back to clean after undo")
    undo.redo()
    check(handle.pageCount == 3 && handle.pdf.page(at: 0)?.rotation == 90, "redo applies both again")
    undo.undo()

    // An engine edit: bytes before and after (Recognise text).
    let before = handle.pdf.dataRepresentation()!, after = makePDF(pages: 7)
    _ = complete(300, { try await manager.apply(.inPlace(undoable: UndoGroup("Recognise Text", .contents(before: before, after: after)), banner: nil),
                                           of: request) })
    check(handle.pageCount == 7 && undo.undoActionName == "Recognise Text", "the new bytes are shown")
    undo.undo()
    check(handle.pageCount == 4, "undo swaps the old bytes back")
    undo.redo()
    check(handle.pageCount == 7, "redo swaps the new bytes in")
    undo.undo()
    watcher.cancel()
    check((try? Data(contentsOf: url)) == diskBytes, "nothing was written to the file")
    closeAll(manager)
}

@MainActor
private func documentKitSaveFlow() {
    let folder = tempFolder("save")
    let prompter = ScriptedPrompter()
    let manager = makeManager(folder, prompter: prompter)
    let url = folder.appendingPathComponent("Report.pdf")
    let originalBytes = makePDF(pages: 3)
    try? originalBytes.write(to: url)

    guard case .success(let handle)? = complete(300, { try await manager.open(url) }), let document = manager.document(for: handle) else {
        check(false, "opens"); return
    }

    // Unedited Save a copy is byte for byte.
    prompter.saveLocation = folder.appendingPathComponent("Untouched copy.pdf")
    if case .success(let saved)? = complete(300, { await document.saveCopy(proposing: manager.copyProposal(for: handle)) }) {
        check(saved && (try? Data(contentsOf: folder.appendingPathComponent("Untouched copy.pdf"))) == originalBytes,
              "an unedited copy is the same bytes")
    }
    check(prompter.proposals.last?.lastPathComponent == "Report (edited).pdf", "proposes “Report (edited).pdf”")
    closeAll(manager)

    // Edit, autosave before any choice: the original stays as it was.
    guard case .success(let handle2)? = complete(300, { try await manager.open(url) }), let document2 = manager.document(for: handle2) else {
        check(false, "reopens"); return
    }
    let removed = handle2.pdf.page(at: 1)!
    handle2.pdf.removePage(at: 1)
    _ = complete(300, { try await manager.apply(.inPlace(undoable: UndoGroup("Delete Page", undo: { handle2.pdf.insert(removed, at: 1) },
                                                                      redo: { handle2.pdf.removePage(at: 1) }), banner: nil),
                                           of: ToolRequest(tool: .deletePages, document: handle2, workFolder: SuperPDFPaths.work)) })
    check(document2.isDocumentEdited, "edited")
    _ = complete(300, { await withCheckedContinuation { c in document2.autosave(withImplicitCancellability: false) { c.resume(returning: $0 == nil) } } })
    check((try? Data(contentsOf: url)) == originalBytes, "autosave before the first choice doesn’t touch the original")
    let autosaved = document2.autosavedContentsFileURL
    check(autosaved.map { PDFDocument(url: $0)?.pageCount == 2 } == true, "the changes are kept in an autosave file")
    check(autosaved?.path.hasPrefix(folder.appendingPathComponent("Autosave").path) == true, "…elsewhere, not beside the original")

    // ⌘S asks; Cancel writes nothing.
    prompter.firstSaveAnswer = nil
    check(document2.saveStep == .ask, "first ⌘S asks")
    if case .success(let saved)? = complete(300, { await document2.runSave() }) { check(!saved, "Cancel saves nothing") }
    check(prompter.firstSaveAsks == 1 && (try? Data(contentsOf: url)) == originalBytes, "original untouched after Cancel")

    // Save a copy.
    prompter.saveLocation = nil
    prompter.firstSaveAnswer = (.saveCopy, false)
    if case .success(let saved)? = complete(300, { await document2.runSave() }) { check(saved, "copy saved") }
    let copy = folder.appendingPathComponent("Report (edited).pdf")
    check(PDFDocument(url: copy)?.pageCount == 2, "the copy has the edit")
    check((try? Data(contentsOf: url)) == originalBytes, "the original stays exactly as it was")
    check(document2.fileURL?.lastPathComponent == copy.lastPathComponent && handle2.url?.lastPathComponent == copy.lastPathComponent &&
          handle2.displayName == "Report (edited)", "the document now lives in the copy")
    check(handle2.state.saveChoice == .alwaysSaveCopy && document2.saveStep == .save, "later saves go to the copy")
    check(!handle2.state.isEdited && !document2.isDocumentEdited, "saved means not edited")
    check(autosaved.map { !FileManager.default.fileExists(atPath: $0.path) } == true, "the autosave file is gone once saved")
    check(Defaults[.saveBehaviour] == .ask, "without “Always do this” the setting stays")
    closeAll(manager)

    // Replace original, always: the setting changes and the original is written (atomically, read back first).
    guard case .success(let handle3)? = complete(300, { try await manager.open(url) }), let document3 = manager.document(for: handle3) else {
        check(false, "reopens"); return
    }
    let page = handle3.pdf.page(at: 0)!
    handle3.pdf.removePage(at: 0)
    _ = complete(300, { try await manager.apply(.inPlace(undoable: UndoGroup("Delete Page", undo: { handle3.pdf.insert(page, at: 0) },
                                                                      redo: { handle3.pdf.removePage(at: 0) }), banner: nil),
                                           of: ToolRequest(tool: .deletePages, document: handle3, workFolder: SuperPDFPaths.work)) })
    prompter.firstSaveAnswer = (.replaceOriginal, true)
    if case .success(let saved)? = complete(300, { await document3.runSave() }) { check(saved, "replaced") }
    check(PDFDocument(url: url)?.pageCount == 2, "the original now has the edit")
    check(Defaults[.saveBehaviour] == .replaceOriginal && handle3.state.saveChoice == .replaceOriginal, "“Always do this” remembered")
    Defaults.reset(.saveBehaviour)
    closeAll(manager)

    // Closing an untitled document: Discard Changes throws the edits and the autosave away.
    guard let untitled = try? manager.openUntitled(makePDF(pages: 1), name: "Combined"), let document4 = manager.document(for: untitled) else {
        check(false, "untitled opens"); return
    }
    check(document4.isDocumentEdited && document4.saveStep == .savePanel, "a new document is unsaved and saves through the panel")
    _ = complete(300, { await withCheckedContinuation { c in document4.autosave(withImplicitCancellability: false) { c.resume(returning: $0 == nil) } } })
    let untitledAutosave = document4.autosavedContentsFileURL
    check(untitledAutosave != nil, "untitled changes are autosaved")
    prompter.closeAnswer = .cancel
    if case .success(let closes)? = complete(300, { await document4.closeFlow() }) { check(!closes, "Cancel keeps it open") }
    prompter.closeAnswer = .discard
    if case .success(let closes)? = complete(300, { await document4.closeFlow() }) { check(closes, "Discard closes") }
    check(untitledAutosave.map { !FileManager.default.fileExists(atPath: $0.path) } == true && !document4.isDocumentEdited, "and discards")
    closeAll(manager)
}

@MainActor
private func documentKitApplyResults() {
    let folder = tempFolder("apply")
    let manager = makeManager(folder, prompter: ScriptedPrompter())
    let url = folder.appendingPathComponent("Report.pdf")
    try? makePDF(pages: 2).write(to: url)
    guard case .success(let handle)? = complete(300, { try await manager.open(url) }) else { check(false, "opens"); return }

    // A new file: moved to its destination; something that appeared there meanwhile is kept.
    let destination = manager.destination(for: .sibling(.smaller, ext: "pdf"), of: handle, source: nil)!
    try? Data("someone else’s".utf8).write(to: destination)
    let work = SuperPDFPaths.ensure(SuperPDFPaths.work.appendingPathComponent(UUID().uuidString, isDirectory: true))
    let output = work.appendingPathComponent("out.pdf")
    try? makePDF(pages: 1).write(to: output)
    let banner = ResultBanner("Saved \(Strings.quoted(destination.lastPathComponent)).", actions: [.showInFinder])
    let request = ToolRequest(tool: .makeSmaller, document: handle, destination: destination, workFolder: work)
    if case .failure(let error)? = complete(300, { try await manager.apply(.newFile(output, banner: banner), of: request) }) {
        check(false, "applies a new file: \(error)")
    }
    let placed = folder.appendingPathComponent("Report (smaller) 2.pdf")
    check((try? Data(contentsOf: destination)) == Data("someone else’s".utf8), "the file already there is untouched")
    check(PDFDocument(url: placed)?.pageCount == 1, "the output took the next name")
    check(manager.openDocuments.contains { $0.url?.lastPathComponent == placed.lastPathComponent }, "the new PDF opens")
    let shown = (Services.viewer as? FakeViewer)?.banners.last
    check(shown?.file?.lastPathComponent == placed.lastPathComponent && shown?.text.contains("Report (smaller) 2.pdf") == true,
          "the banner names the real file")
    check(!FileManager.default.fileExists(atPath: work.path), "the run folder is cleaned up")

    // Several files into a folder.
    let work2 = SuperPDFPaths.ensure(SuperPDFPaths.work.appendingPathComponent(UUID().uuidString, isDirectory: true))
    let parts = (1...3).map { work2.appendingPathComponent("Report – part \($0).pdf") }
    parts.forEach { try? makePDF(pages: 1).write(to: $0) }
    let partsFolder = manager.destination(for: .folder(.parts), of: handle, source: nil)!
    _ = complete(300, { try await manager.apply(.newFiles(parts, banner: Strings.Banner.savedFiles(3, folder: "Report parts")),
                                           of: ToolRequest(tool: .split, document: handle, destination: partsFolder, workFolder: work2)) })
    let listed = (try? FileManager.default.contentsOfDirectory(atPath: partsFolder.path))?.sorted() ?? []
    check(listed == parts.map(\.lastPathComponent).sorted(), "parts land in “Report parts”")

    // A new unsaved document.
    let before = manager.openDocuments.count
    _ = complete(300, { try await manager.apply(.newDocument(makePDF(pages: 5), name: "Combined", banner: Strings.Banner.combined(files: 2, pages: 5)),
                                           of: ToolRequest(tool: .combineFiles, workFolder: SuperPDFPaths.work.appendingPathComponent("none"))) })
    let combined = manager.openDocuments.last
    check(manager.openDocuments.count == before + 1 && combined?.displayName == "Combined" && combined?.state.origin == .createdHere &&
          combined?.url == nil && combined?.pageCount == 5, "Combine opens an unsaved “Combined”")
    closeAll(manager)
}

@MainActor
private func documentKitRecentsAndViewState() {
    let folder = tempFolder("recents")
    let manager = makeManager(folder, prompter: ScriptedPrompter())
    Defaults.store.removeObject(forKey: "documentKit.recents")   // earlier cases opened files too
    let a = folder.appendingPathComponent("A.pdf"), b = folder.appendingPathComponent("B.pdf")
    let bytes = makePDF(pages: 6)
    try? bytes.write(to: a)
    try? makePDF(pages: 1).write(to: b)

    let state = DocumentViewState(pageIndex: 4, scale: 1.5, displayMode: .twoPages, sidebarMode: .bookmarks, sidebarVisible: false, sidebarWidth: 240)
    manager.saveViewState(state, for: a)
    check(manager.viewState(for: a) == state, "view state round-trips through the extended attribute")
    check((try? Data(contentsOf: a)) == bytes, "the PDF bytes are unchanged")
    check(manager.viewState(for: b) == nil, "no state, no answer")

    _ = complete(300, { try await manager.open(a) })
    _ = complete(300, { try await manager.open(b) })
    check(manager.recentDocuments.map(\.name) == ["B.pdf", "A.pdf"], "newest first")
    check(manager.recentDocuments.last?.pageCount == 6 && (manager.recentDocuments.last?.fileSize ?? 0) > 0, "page count and size")
    manager.removeRecent(b)
    check(manager.recentDocuments.map(\.name) == ["A.pdf"], "Remove from list")
    closeAll(manager)
    try? FileManager.default.removeItem(at: a)
    check(manager.recentDocuments.isEmpty, "files that are gone drop out")
    Defaults.store.removeObject(forKey: "documentKit.recents")
}

// MARK: - Save fidelity

private let fidelityAttachment = Data("name,amount\nAda,42\n".utf8)

/// Three pages carrying what PDFKit drops when it writes: a structure tree with tagged content (and a tagged link),
/// optional content, a page transition, named destinations, document and page JavaScript, XMP, an attached file and a
/// paper-clip note, a reply thread, a form field with a format script and calculation order, an app-private catalog
/// key and EditKit's marked header.
private func fidelityFixture() -> Data {
    let model = try! PDFModel(data: makePDF(pages: 3))
    let root = model.root
    let pages = model.pages
    let first = pages[0], second = pages[1]
    model.addEmbeddedFile(fidelityAttachment, name: "data.csv", mimeType: "text/csv")
    model.setInfo("Title", "Fidelity")

    // Tagged, layered content and EditKit's marked header on page 1.
    let layer = model.makeIndirect(.dictionary(["Type": .name("OCG"), "Name": .text("Layer A")]))
    first.ownResources().dictionary("Properties").set("oc1", layer)
    first.addContent(Data("""
    /P <</MCID 0>> BDC 0 g 72 600 50 10 re f EMC
    /Artifact <</Type /Pagination /Subtype /Header /SPKind (header)>> BDC 0 g 72 760 80 8 re f EMC
    /OC /oc1 BDC 0 0 1 rg 72 500 100 20 re f EMC
    """.utf8))
    root.set("OCProperties", .dictionary(["OCGs": .array([layer.reference!]),
                                          "D": .dictionary(["ON": .array([layer.reference!]), "Order": .array([layer.reference!])])]))
    root.set(privateCatalogKey, .name("Rfixture"))

    // Annotations: a tagged link to a named destination, a note with its popup and a reply, a paper clip, a field.
    let link = model.makeIndirect(.dictionary(["Type": .name("Annot"), "Subtype": .name("Link"), "Rect": .rect(CGRect(x: 72, y: 400, width: 120, height: 14)),
                                                "Dest": .ascii("chapter2"), "StructParent": .integer(1), "Border": .array([.integer(0), .integer(0), .integer(0)])]))
    let note = model.makeIndirect(.dictionary(["Type": .name("Annot"), "Subtype": .name("Text"), "Rect": .rect(CGRect(x: 300, y: 700, width: 20, height: 20)),
                                                "Contents": .text("Parent note"), "NM": .text("parent"), "T": .text("Ada"), "Custom": .text("keep me")]))
    let popup = model.makeIndirect(.dictionary(["Type": .name("Annot"), "Subtype": .name("Popup"), "Rect": .rect(CGRect(x: 330, y: 600, width: 180, height: 100)),
                                                 "Parent": note.reference!]))
    note.set("Popup", popup)
    let reply = model.makeIndirect(.dictionary(["Type": .name("Annot"), "Subtype": .name("Text"), "Rect": .rect(CGRect(x: 300, y: 670, width: 20, height: 20)),
                                                 "Contents": .text("A reply"), "NM": .text("reply"), "T": .text("Grace"), "IRT": note.reference!,
                                                 "RT": .name("R")]))
    let fileStream = model.makeStream(["Type": .name("EmbeddedFile")], data: Data("Minutes".utf8))
    let clip = model.makeIndirect(.dictionary(["Type": .name("Annot"), "Subtype": .name("FileAttachment"), "Rect": .rect(CGRect(x: 500, y: 700, width: 14, height: 20)),
                                                "Name": .name("Paperclip"), "NM": .text("clip"),
                                                "FS": .dictionary(["Type": .name("Filespec"), "F": .text("minutes.txt"), "UF": .text("minutes.txt"),
                                                                   "EF": .dictionary(["F": fileStream.reference!])])]))
    let field = model.makeIndirect(.dictionary(["Type": .name("Annot"), "Subtype": .name("Widget"), "FT": .name("Tx"), "T": .text("amount"),
                                                 "Rect": .rect(CGRect(x: 72, y: 300, width: 200, height: 20)), "V": .text("7"), "F": .integer(4),
                                                 "DA": .ascii("/Helv 12 Tf 0 g"),
                                                 "AA": .dictionary(["F": .dictionary(["S": .name("JavaScript"), "JS": .text("AFNumber_Format(2, 0, 0, 0, \"$\", true);")])])]))
    for annotation in [link, note, popup, reply, clip, field] { first.addAnnotation(annotation) }
    let helvetica = model.makeIndirect(.dictionary(["Type": .name("Font"), "Subtype": .name("Type1"), "BaseFont": .name("Helvetica")]))
    root.set("AcroForm", .dictionary(["Fields": .array([field.reference!]), "CO": .array([field.reference!]), "DA": .ascii("/Helv 0 Tf 0 g"),
                                      "DR": .dictionary(["Font": .dictionary(["Helv": helvetica.reference!])])]))

    // The structure tree: a paragraph (marked content 0 on page 1) and the link (object reference).
    first.object.set("StructParents", .integer(0))
    let structRoot = model.makeIndirect(.dictionary(["Type": .name("StructTreeRoot")]))
    let documentElement = model.makeIndirect(.dictionary(["Type": .name("StructElem"), "S": .name("Document"), "P": structRoot.reference!]))
    let paragraph = model.makeIndirect(.dictionary(["Type": .name("StructElem"), "S": .name("P"), "P": documentElement.reference!,
                                                     "Pg": first.object.reference!, "K": .integer(0), "Alt": .text("Tagged paragraph")]))
    let linkElement = model.makeIndirect(.dictionary(["Type": .name("StructElem"), "S": .name("Link"), "P": documentElement.reference!,
                                                       "K": .dictionary(["Type": .name("OBJR"), "Obj": link.reference!, "Pg": first.object.reference!])]))
    documentElement.set("K", .array([paragraph.reference!, linkElement.reference!]))
    structRoot.set("K", documentElement)
    structRoot.set("ParentTree", .dictionary(["Nums": .array([.integer(0), .array([paragraph.reference!]), .integer(1), linkElement.reference!])]))
    structRoot.set("ParentTreeNextKey", .integer(2))
    root.set("StructTreeRoot", structRoot)
    root.set("MarkInfo", .dictionary(["Marked": .bool(true)]))
    root.set("Lang", .text("en-GB"))

    // A transition and page script on page 2, named destinations and document scripts.
    second.object.set("Trans", .dictionary(["Type": .name("Trans"), "S": .name("Dissolve"), "D": .real(1.5)]))
    second.object.set("Dur", .integer(4))
    second.object.set("AA", .dictionary(["O": .dictionary(["S": .name("JavaScript"), "JS": .text("console.println('page two');")])]))
    let names = root.dictionary("Names")
    names.set("Dests", PDFNameTree.make(in: model, entries: [(Data("chapter2".utf8), model.makeIndirect(.array([second.object.reference!, .name("Fit")])))]))
    let script = model.makeIndirect(.dictionary(["S": .name("JavaScript"), "JS": .text("var fixture = true;")]))
    names.set("JavaScript", PDFNameTree.make(in: model, entries: [(Data("init".utf8), script)]))
    root.set("OpenAction", .dictionary(["S": .name("JavaScript"), "JS": .text("app.alert('opened');")]))

    let xmp = "<?xpacket begin=\"\" id=\"W5M0MpCehiHzreSzNTczkc9d\"?><x:xmpmeta xmlns:x=\"adobe:ns:meta/\"><rdf:RDF xmlns:rdf=\"http://www.w3.org/1999/02/22-rdf-syntax-ns#\">"
        + "<rdf:Description rdf:about=\"\" xmlns:superpdf=\"https://superpdf.app/ns/\"><superpdf:fixture>kept</superpdf:fixture></rdf:Description>"
        + "</rdf:RDF></x:xmpmeta><?xpacket end=\"w\"?>"
    root.set("Metadata", model.makeStream(["Type": .name("Metadata"), "Subtype": .name("XML")], data: Data(xmp.utf8)))
    return try! model.data(options: PDFWriteOptions(objectStreams: .disable))
}

/// A catalog key only the app reads (EditKit named its saves' revisions there).
private let privateCatalogKey = "SPRevision"

/// Every structure of `fidelityFixture()` is in `data`; `firstPage` is where the fixture's first page is now.
@MainActor
private func checkFidelityStructures(_ data: Data, firstPage: Int, secondPage: Int?, _ label: String) {
    guard let model = try? PDFModel(data: data) else { return check(false, "\(label): QPDF opens the save") }
    let root = model.root
    check(model.check().isEmpty, "\(label): QPDF finds nothing wrong: \(model.check())")
    check(root["MarkInfo"]?["Marked"]?.bool == true && root["Lang"]?.text == "en-GB", "\(label): marked, with its language")
    let tree = root["StructTreeRoot"]
    let elements = tree?["K"]?["K"]?.items ?? []
    check(elements.count == 2 && elements[0]["Alt"]?.text == "Tagged paragraph" && elements[1]["K"]?["Obj"]?["Subtype"]?.name == "Link",
          "\(label): the structure tree and its tags")
    check(tree?["ParentTree"]?["Nums"]?.count == 4, "\(label): the parent tree")
    guard let page = model.page(at: firstPage) else { return check(false, "\(label): the first page is there") }
    check(elements.first?["Pg"].map { $0.isSameObject(as: page.object) } == true, "\(label): tags point at the page")
    let content = (try? page.contentData()).map { String(decoding: $0, as: UTF8.self) } ?? ""
    check(content.contains("/P <</MCID 0>> BDC") && content.contains("/SPKind (header)") && content.contains("/OC /oc1 BDC"),
          "\(label): tagged, marked and layered content is the file's")
    check(page.object["StructParents"]?.int == 0, "\(label): the page keeps its structure key")
    check(root["OCProperties"]?["OCGs"]?.items.map { $0["Name"]?.text } == ["Layer A"], "\(label): the layer")
    check(root[privateCatalogKey]?.name != nil, "\(label): the app's catalog key")
    if let secondPage {
        let second = model.page(at: secondPage)
        check(second?.object["Trans"]?["S"]?.name == "Dissolve" && second?.object["Dur"]?.int == 4, "\(label): the transition")
        check(second?.object["AA"]?["O"]?["S"]?.name == "JavaScript", "\(label): the page script")
        check(model.destination(from: model.make(.ascii("chapter2")))?.page == secondPage, "\(label): the named destination follows its page")
    }
    let scripts = root["Names"]?["JavaScript"].map { PDFNameTree.entries(of: $0) } ?? []
    check(scripts.count == 1 && root["OpenAction"]?["S"]?.name == "JavaScript", "\(label): document scripts")
    let xmp = (try? root["Metadata"]?.streamData()).map { String(decoding: $0!, as: UTF8.self) } ?? ""
    check(xmp.contains("<superpdf:fixture>kept</superpdf:fixture>"), "\(label): the XMP")
    check((try? model.embeddedFileData(named: "data.csv")) == fidelityAttachment, "\(label): the attached file")
    let annotations = page.annotations
    let link = annotations.first { $0["Subtype"]?.name == "Link" }
    check(link?["Dest"]?.stringData == Data("chapter2".utf8) && link?["StructParent"]?.int == 1, "\(label): the tagged link to its named destination")
    let note = annotations.first { $0["NM"]?.text == "parent" }
    let reply = annotations.first { $0["NM"]?.text == "reply" }
    check(note?["Custom"]?.text == "keep me" && note?["Popup"]?["Parent"].map { $0.isSameObject(as: note!) } == true, "\(label): the note keeps its keys and popup")
    check(reply?["IRT"].map { $0.isSameObject(as: note!) } == true && reply?["RT"]?.name == "R", "\(label): the reply thread")
    let clip = annotations.first { $0["Subtype"]?.name == "FileAttachment" }
    check((try? clip?["FS"]?["EF"]?["F"]?.streamData()) == Data("Minutes".utf8) && clip?["Name"]?.name == "Paperclip", "\(label): the paper clip's file")
    let form = model.formFields().first { $0.name == "amount" }
    check(form?.object["AA"]?["F"]?["JS"]?.text?.hasPrefix("AFNumber_Format") == true, "\(label): the field's format script")
    check(root["AcroForm"]?["CO"]?.items.first.map { $0.isSameObject(as: form!.object) } == true, "\(label): the calculation order")
    check(model.info("Title") == "Fidelity", "\(label): the document information")
    check(data.range(of: Data("SuperPDFSave".utf8)) == nil && data.range(of: Data("SuperPDFID".utf8)) == nil, "\(label): no private keys written")
}

/// Typical edits through PDFKit (a highlight, an edited note, a filled field, a rotated page, a page moved, a
/// bookmark), saved through NSDocument: every structure of the file survives, the edits are there, and the save is an
/// update appended to the file.
@MainActor
private func documentKitSaveFidelity() {
    let folder = tempFolder("fidelity")
    let manager = makeManager(folder, prompter: ScriptedPrompter())
    let url = folder.appendingPathComponent("Fidelity.pdf")
    let original = fidelityFixture()
    try? original.write(to: url)
    guard case .success(let handle)? = complete(300, { try await manager.open(url) }), let document = manager.document(for: handle) else {
        return check(false, "opens")
    }
    check(handle.contents is DocumentBaseline, "the file's bytes are the document's contents")
    check(DocumentBaseline.saveOutcome(of: handle).method == .unchanged, "nothing changed, nothing to write")

    let pdf = handle.pdf
    guard let first = pdf.page(at: 0), let second = pdf.page(at: 1), let third = pdf.page(at: 2) else { return check(false, "three pages") }
    let highlight = PDFAnnotation(bounds: CGRect(x: 72, y: 598, width: 50, height: 14), forType: .highlight, withProperties: nil)
    highlight.quadrilateralPoints = [NSValue(point: CGPoint(x: 0, y: 14)), NSValue(point: CGPoint(x: 50, y: 14)),
                                     NSValue(point: .zero), NSValue(point: CGPoint(x: 50, y: 0))]
    highlight.color = .systemYellow
    first.addAnnotation(highlight)
    first.annotations.first { $0.type == "Text" && $0.contents == "Parent note" }?.contents = "Parent note, edited"
    first.annotations.first { $0.fieldName == "amount" }?.widgetStringValue = "42"
    second.rotation = 90
    pdf.removePage(at: 2)
    pdf.insert(third, at: 0)
    let outline = PDFOutline()
    pdf.outlineRoot = outline
    let bookmark = PDFOutline()
    bookmark.label = "Chapter 2"
    bookmark.destination = PDFKit.PDFDestination(page: second, at: CGPoint(x: 0, y: 792))
    outline.insertChild(bookmark, at: 0)
    document.updateChangeCount(.changeDone)

    let outcome = DocumentBaseline.saveOutcome(of: handle)
    check(outcome.method == .appended && outcome.notes.isEmpty, "the edits are appended to the file: \(outcome.method) \(outcome.notes)")
    let saved = folder.appendingPathComponent("Fidelity (saved).pdf")
    let started = Date()
    let error: Error?? = complete(300, {
        await withCheckedContinuation { c in document.save(to: saved, ofType: UTType.pdf.identifier, for: .saveToOperation) { c.resume(returning: $0) } }
    }).flatMap { try? $0.get() }
    check(error != nil && error! == nil, "NSDocument saves")
    Log.documents.debug("fidelity save took \(Date().timeIntervalSince(started))")
    guard let data = try? Data(contentsOf: saved) else { return check(false, "the save is on disk") }
    check(data.count > original.count && data.prefix(original.count) == original, "the original bytes are untouched: the save appends")
    checkFidelityStructures(data, firstPage: 1, secondPage: 2, "after edits")

    // The edits.
    guard let model = try? PDFModel(data: data), let base = try? PDFModel(data: original) else { return check(false, "QPDF opens both") }
    check(model.pages.map(\.object.objectID) == [2, 0, 1].map { base.page(at: $0)?.object.objectID }, "the pages in their new order, as the file's own pages")
    check(model.page(at: 2)?.rotation == 90, "the rotated page")
    let annotations = model.page(at: 1)?.annotations ?? []
    let marked = annotations.first { $0["Subtype"]?.name == "Highlight" }
    check(marked?["QuadPoints"]?.count == 8 && marked?["P"].map { $0.isSameObject(as: model.page(at: 1)!.object) } == true, "the new highlight, on its page")
    check(annotations.first { $0["NM"]?.text == "parent" }?["Contents"]?.text == "Parent note, edited", "the edited note")
    check(model.formFields().first { $0.name == "amount" }?.value?.textValue == "42", "the filled field")
    let bookmarks = model.outlines()
    check(bookmarks.map(\.title) == ["Chapter 2"] && bookmarks.first?.destination?.page == 2, "the bookmark: \(bookmarks)")

    // PDFKit reads it all back.
    guard let reopened = PDFDocument(data: data) else { return check(false, "PDFKit opens the save") }
    check(reopened.pageCount == 3 && reopened.page(at: 2)?.rotation == 90, "PDFKit: pages and rotation")
    let page = reopened.page(at: 1)
    check(page?.annotations.contains { $0.type == "Highlight" } == true, "PDFKit: the highlight")
    check(page?.annotations.first { $0.fieldName == "amount" }?.widgetStringValue == "42", "PDFKit: the field value")
    check(reopened.outlineRoot?.child(at: 0)?.label == "Chapter 2", "PDFKit: the bookmark")
    closeAll(manager)
}

/// A removed page rewrites the file (nothing of the page lingers in an older revision); everything else stays.
@MainActor
private func documentKitSaveFidelityPagesRemoved() {
    let folder = tempFolder("fidelity-removed")
    let url = folder.appendingPathComponent("Fidelity.pdf")
    try? fidelityFixture().write(to: url)
    let handle = openedHandle(url)
    handle.pdf.removePage(at: 2)
    let outcome = DocumentBaseline.saveOutcome(of: handle)
    check(outcome.method == .rewritten, "removing a page rewrites the file: \(outcome.method) \(outcome.notes)")
    checkFidelityStructures(outcome.data, firstPage: 0, secondPage: 1, "a page removed")
    check((try? PDFModel(data: outcome.data))?.pageCount == 2 && PDFDocument(data: outcome.data)?.pageCount == 2, "two pages left")
}

/// An engine's edit (new bytes, as EditKit's) becomes the contents; a PDFKit change on top keeps what the engine wrote.
@MainActor
private func documentKitSaveFidelityEngineEdit() {
    let folder = tempFolder("fidelity-engine")
    let manager = makeManager(folder, prompter: ScriptedPrompter())
    let url = folder.appendingPathComponent("Fidelity.pdf")
    let original = fidelityFixture()
    try? original.write(to: url)
    guard case .success(let handle)? = complete(300, { try await manager.open(url) }) else { return check(false, "opens") }
    guard let model = try? PDFModel(data: original) else { return check(false, "QPDF opens the fixture") }
    model.root.set(privateCatalogKey, .name("Rengine"))
    model.page(at: 1)?.addContent(Data("/Artifact <</SPKind (watermark)>> BDC 0.5 g 100 100 50 50 re f EMC".utf8))
    guard let edited = try? model.incrementalData() else { return check(false, "the engine writes") }
    _ = complete(60, { try await manager.apply(.inPlace(undoable: UndoGroup("Add Watermark", .contents(before: original, after: edited)), banner: nil),
                                               of: ToolRequest(tool: .watermark, document: handle, workFolder: SuperPDFPaths.work)) })
    check((handle.contents as? DocumentBaseline)?.bytes == edited, "the engine's bytes are the contents")
    check(DocumentBaseline.saveOutcome(of: handle).data == edited, "a save (and engines) read the engine's bytes back as they are")
    let note = PDFAnnotation(bounds: CGRect(x: 100, y: 200, width: 20, height: 20), forType: .text, withProperties: nil)
    note.contents = "After the watermark"
    handle.pdf.page(at: 1)?.addAnnotation(note)
    let outcome = DocumentBaseline.saveOutcome(of: handle)
    check(outcome.method == .appended && outcome.data.prefix(edited.count) == edited, "appended to the engine's bytes: \(outcome.method)")
    checkFidelityStructures(outcome.data, firstPage: 0, secondPage: 1, "after an engine edit")
    let saved = try? PDFModel(data: outcome.data)
    check(saved?.root[privateCatalogKey]?.name == "Rengine", "the engine's catalog change")
    let content = (try? saved?.page(at: 1)?.contentData()).map { String(decoding: $0!, as: UTF8.self) } ?? ""
    check(content.contains("/SPKind (watermark)"), "the engine's marked content")
    check(saved?.page(at: 1)?.annotations.contains { $0["Contents"]?.text == "After the watermark" } == true, "the note added after it")

    // Undo swaps the old bytes back in as the contents.
    handle.undoManager?.undo()
    check((handle.contents as? DocumentBaseline)?.bytes == original, "undo brings the file's bytes back as the contents")
    closeAll(manager)
}

/// An encrypted file can't take an appended update: it is rewritten with its own encryption kept.
@MainActor
private func documentKitSaveFidelityEncrypted() {
    let folder = tempFolder("fidelity-encrypted")
    let url = folder.appendingPathComponent("Locked.pdf")
    try? makeEncryptedPDF(pages: 2, password: "open sesame").write(to: url)
    guard let pdf = PDFDocument(url: url), pdf.unlock(withPassword: "open sesame") else { return check(false, "the fixture unlocks") }
    let handle = DocumentHandle(url: url, pdf: pdf, password: "open sesame", undoManager: makeUndoManager())
    DocumentBaseline.attach(try! Data(contentsOf: url), to: handle)
    let note = PDFAnnotation(bounds: CGRect(x: 100, y: 100, width: 20, height: 20), forType: .text, withProperties: nil)
    note.contents = "Still locked"
    pdf.page(at: 1)?.addAnnotation(note)
    let outcome = DocumentBaseline.saveOutcome(of: handle)
    check(outcome.method == .rewritten, "an encrypted file is rewritten: \(outcome.method) \(outcome.notes)")
    let model = try? PDFModel(data: outcome.data, password: "open sesame")
    check(model?.isEncrypted == true && (try? PDFModel(data: outcome.data)) == nil, "it keeps its password")
    check(model?.page(at: 1)?.annotations.contains { $0["Contents"]?.text == "Still locked" } == true, "with the new note")
    let reopened = PDFDocument(data: outcome.data)
    check(reopened?.isLocked == true && reopened?.unlock(withPassword: "open sesame") == true && reopened?.pageCount == 2, "PDFKit opens it with the password")
}

/// A page brought in from another document (with a note on it) is written from PDFKit's copy; the file's own pages
/// and structures stay as they were.
@MainActor
private func documentKitSaveFidelityPageInserted() {
    let folder = tempFolder("fidelity-inserted")
    let url = folder.appendingPathComponent("Fidelity.pdf")
    let original = fidelityFixture()
    try? original.write(to: url)
    let handle = openedHandle(url)
    guard let other = PDFDocument(data: makePDF(pages: 2, size: CGSize(width: 400, height: 300))), let page = other.page(at: 1) else {
        return check(false, "the other document")
    }
    let note = PDFAnnotation(bounds: CGRect(x: 20, y: 20, width: 20, height: 20), forType: .text, withProperties: nil)
    note.contents = "From elsewhere"
    page.addAnnotation(note)
    other.removePage(at: 1)
    handle.pdf.insert(page, at: 1)
    let outcome = DocumentBaseline.saveOutcome(of: handle)
    check(outcome.method == .appended && outcome.data.prefix(original.count) == original, "appended: \(outcome.method) \(outcome.notes)")
    checkFidelityStructures(outcome.data, firstPage: 0, secondPage: 2, "a page inserted")
    guard let model = try? PDFModel(data: outcome.data) else { return check(false, "QPDF opens it") }
    let inserted = model.page(at: 1)
    check(model.pageCount == 4 && inserted?.box(.media).size == CGSize(width: 400, height: 300), "the inserted page, at its size")
    check(inserted?.annotations.first { $0["Subtype"]?.name == "Text" }?["Contents"]?.text == "From elsewhere", "with its note")
    check(inserted?.annotations.allSatisfy { $0["P"].map { $0.isSameObject(as: inserted!.object) } ?? true } == true, "the note points at its page")
    check(PDFDocument(data: outcome.data)?.page(at: 1)?.annotations.contains { $0.contents == "From elsewhere" } == true, "PDFKit reads it")
}

// MARK: - Removed pages leave the file

/// Unique bytes of what only the removed page has.
private let removedPageSecrets = ["TOPSECRET-PAGE-TWO", "IMGSECRET0123456", "SECRET-ALT-FIGURE", "SECRET-NOTE", "SECRET-FIELD-VALUE",
                                  "Secret chapter", "secretDest", "oldSecret", "secretField", "fig-secret"]

/// Three tagged pages; the second has unique text, an image, its own structure subtree, a tagged note, a form field
/// and an article bead, and bookmarks, named destinations, links, the open action and an ID tree entry point at it.
private func removedPageFixture() -> Data {
    let model = try! PDFModel(data: makePDF(pages: 3))
    let root = model.root
    let pages = model.pages
    let (one, two, three) = (pages[0], pages[1], pages[2])
    let refs = pages.map { $0.object.reference! }
    let font = model.makeIndirect(.dictionary(["Type": .name("Font"), "Subtype": .name("Type1"), "BaseFont": .name("Helvetica")]))
    for page in pages { page.ownResources().dictionary("Font").set("FH", font) }
    one.addContent(Data("/P <</MCID 0>> BDC BT /FH 12 Tf 72 700 Td (Keep one) Tj ET EMC /Span <</MCID 1>> BDC BT /FH 12 Tf 72 680 Td (Shared) Tj ET EMC".utf8))
    three.addContent(Data("/P <</MCID 0>> BDC BT /FH 12 Tf 72 700 Td (Keep three) Tj ET EMC".utf8))
    let image = model.makeStream(["Type": .name("XObject"), "Subtype": .name("Image"), "Width": .integer(4), "Height": .integer(4),
                                  "ColorSpace": .name("DeviceGray"), "BitsPerComponent": .integer(8)], data: Data("IMGSECRET0123456".utf8))
    two.ownResources().dictionary("XObject").set("Im1", image)
    two.addContent(Data("""
    /P <</MCID 0>> BDC BT /FH 12 Tf 72 700 Td (TOPSECRET-PAGE-TWO) Tj ET EMC
    /Figure <</MCID 1>> BDC q 100 0 0 100 72 500 cm /Im1 Do Q EMC
    /Span <</MCID 2>> BDC BT /FH 12 Tf 72 480 Td (Shared too) Tj ET EMC
    """.utf8))

    // Annotations: links on page 1 to page 2 (explicit, named) and to page 3; a tagged note and a field on page 2.
    func link(_ y: CGFloat, _ dest: PDFValue) -> PDFObject {
        model.makeIndirect(.dictionary(["Type": .name("Annot"), "Subtype": .name("Link"), "Rect": .rect(CGRect(x: 72, y: y, width: 100, height: 12)), "Dest": dest]))
    }
    let toTwo = link(600, .array([refs[1], .name("Fit")])), toSecret = link(580, .ascii("secretDest")), toThree = link(560, .array([refs[2], .name("Fit")]))
    let viaAction = model.makeIndirect(.dictionary(["Type": .name("Annot"), "Subtype": .name("Link"), "Rect": .rect(CGRect(x: 72, y: 540, width: 100, height: 12)),
                                                     "A": .dictionary(["S": .name("GoTo"), "D": .name("oldSecret")])]))
    for annotation in [toTwo, toSecret, toThree, viaAction] { one.addAnnotation(annotation) }
    let note = model.makeIndirect(.dictionary(["Type": .name("Annot"), "Subtype": .name("Text"), "Rect": .rect(CGRect(x: 300, y: 700, width: 20, height: 20)),
                                                "Contents": .text("SECRET-NOTE"), "StructParent": .integer(2)]))
    let field = model.makeIndirect(.dictionary(["Type": .name("Annot"), "Subtype": .name("Widget"), "FT": .name("Tx"), "T": .text("secretField"),
                                                 "Rect": .rect(CGRect(x: 72, y: 300, width: 200, height: 20)), "V": .text("SECRET-FIELD-VALUE"), "F": .integer(4),
                                                 "DA": .ascii("/Helv 12 Tf 0 g")]))
    let keptField = model.makeIndirect(.dictionary(["Type": .name("Annot"), "Subtype": .name("Widget"), "FT": .name("Tx"), "T": .text("keptField"),
                                                     "Rect": .rect(CGRect(x: 72, y: 300, width: 200, height: 20)), "V": .text("kept value"), "F": .integer(4),
                                                     "DA": .ascii("/Helv 12 Tf 0 g")]))
    two.addAnnotation(note); two.addAnnotation(field); three.addAnnotation(keptField)
    root.set("AcroForm", .dictionary(["Fields": .array([field.reference!, keptField.reference!]), "CO": .array([field.reference!, keptField.reference!]),
                                      "DA": .ascii("/Helv 0 Tf 0 g"), "DR": .dictionary(["Font": .dictionary(["Helv": font.reference!])])]))

    // The structure tree: page 1 and 3 paragraphs, a section only on page 2 (paragraph, figure, the note), and a span
    // over pages 1 and 2.
    let structRoot = model.makeIndirect(.dictionary(["Type": .name("StructTreeRoot")]))
    let document = model.makeIndirect(.dictionary(["Type": .name("StructElem"), "S": .name("Document"), "P": structRoot.reference!]))
    func element(_ type: String, parent: PDFObject, _ extra: [String: PDFValue]) -> PDFObject {
        var dictionary: [String: PDFValue] = ["Type": .name("StructElem"), "S": .name(type), "P": parent.reference!]
        dictionary.merge(extra) { $1 }
        return model.makeIndirect(.dictionary(dictionary))
    }
    let keepOne = element("P", parent: document, ["Pg": refs[0], "K": .integer(0), "Alt": .text("Keep-one")])
    let section = element("Sect", parent: document, ["Pg": refs[1], "T": .text("Secret section")])
    let secretParagraph = element("P", parent: section, ["Pg": refs[1], "K": .integer(0)])
    let figure = element("Figure", parent: section, ["Pg": refs[1], "K": .integer(1), "Alt": .text("SECRET-ALT-FIGURE"), "ID": .ascii("fig-secret")])
    let noteElement = element("Annot", parent: section, ["K": .dictionary(["Type": .name("OBJR"), "Obj": note.reference!, "Pg": refs[1]])])
    section.set("K", .array([secretParagraph.reference!, figure.reference!, noteElement.reference!]))
    let span = element("Span", parent: document, ["Pg": refs[0], "K": .array([.integer(1), .dictionary(["Type": .name("MCR"), "Pg": refs[1], "MCID": .integer(2)])])])
    let keepThree = element("P", parent: document, ["Pg": refs[2], "K": .integer(0), "Alt": .text("Keep-three")])
    document.set("K", .array([keepOne.reference!, section.reference!, span.reference!, keepThree.reference!]))
    structRoot.set("K", document)
    one.object.set("StructParents", .integer(0))
    two.object.set("StructParents", .integer(1))
    three.object.set("StructParents", .integer(3))
    structRoot.set("ParentTree", .dictionary(["Nums": .array([
        .integer(0), .array([keepOne.reference!, span.reference!]),
        .integer(1), .array([secretParagraph.reference!, figure.reference!, span.reference!]),
        .integer(2), noteElement.reference!,
        .integer(3), .array([keepThree.reference!]),
    ])]))
    structRoot.set("ParentTreeNextKey", .integer(4))
    structRoot.set("IDTree", PDFNameTree.make(in: model, entries: [(Data("fig-secret".utf8), figure), (Data("p-one".utf8), keepOne)]))
    keepOne.set("ID", .ascii("p-one"))
    root.set("StructTreeRoot", structRoot)
    root.set("MarkInfo", .dictionary(["Marked": .bool(true)]))

    // Bookmarks (one to page 2 with a child to page 3), named destinations, the open action, labels and a thread.
    let outlines = model.makeIndirect(.dictionary(["Type": .name("Outlines")]))
    let intro = model.makeIndirect(.dictionary(["Title": .text("Intro"), "Parent": outlines.reference!, "Dest": .array([refs[0], .name("Fit")])]))
    let secret = model.makeIndirect(.dictionary(["Title": .text("Secret chapter"), "Parent": outlines.reference!, "Dest": .array([refs[1], .name("Fit")]),
                                                  "SE": section.reference!]))
    let child = model.makeIndirect(.dictionary(["Title": .text("Child of secret"), "Parent": secret.reference!, "Dest": .array([refs[2], .name("Fit")])]))
    let end = model.makeIndirect(.dictionary(["Title": .text("End"), "Parent": outlines.reference!, "A": .dictionary(["S": .name("GoTo"), "D": .ascii("endDest")])]))
    intro.set("Next", secret); secret.set("Prev", intro); secret.set("Next", end); end.set("Prev", secret)
    secret.set("First", child); secret.set("Last", child); secret.set("Count", .integer(1))
    outlines.set("First", intro); outlines.set("Last", end); outlines.set("Count", .integer(4))
    root.set("Outlines", outlines)
    root.dictionary("Names").set("Dests", PDFNameTree.make(in: model, entries: [
        (Data("secretDest".utf8), model.makeIndirect(.array([refs[1], .name("XYZ"), .integer(0), .integer(792), .null]))),
        (Data("endDest".utf8), model.makeIndirect(.array([refs[2], .name("Fit")]))),
    ]))
    root.set("Dests", .dictionary(["oldSecret": .array([refs[1], .name("Fit")]), "oldEnd": .array([refs[2], .name("Fit")])]))
    root.set("OpenAction", .array([refs[1], .name("FitH"), .integer(700)]))
    model.setPageLabels([PDFPageLabelRange(startPage: 0, style: .lowerRoman)])
    let thread = model.makeIndirect(.dictionary(["Type": .name("Thread"), "I": .dictionary(["Title": .text("Story")])]))
    let beadTwo = model.makeIndirect(.dictionary(["Type": .name("Bead"), "T": thread.reference!, "P": refs[1], "R": .rect(CGRect(x: 72, y: 72, width: 200, height: 600))]))
    let beadThree = model.makeIndirect(.dictionary(["Type": .name("Bead"), "P": refs[2], "R": .rect(CGRect(x: 72, y: 72, width: 200, height: 600))]))
    beadTwo.set("N", beadThree); beadTwo.set("V", beadThree); beadThree.set("N", beadTwo); beadThree.set("V", beadTwo)
    thread.set("F", beadTwo)
    two.object.set("B", .array([beadTwo.reference!])); three.object.set("B", .array([beadThree.reference!]))
    root.set("Threads", .array([thread.reference!]))
    // A key only some app reads, pointing at the page: the save can't know it, and must still not keep the page.
    root.set("SPPrivate", .dictionary(["Pages": .array([refs[1], refs[2]]), "Last": refs[1]]))
    return try! model.data(options: PDFWriteOptions(objectStreams: .disable, compressStreams: false))
}

/// The file's bytes with every stream decoded and no object streams, as QPDF writes them.
private func decodedBytes(_ data: Data) -> Data? {
    try? PDFModel(data: data).data(options: PDFWriteOptions(objectStreams: .disable, compressStreams: false, decodeLevel: .generalized))
}

/// Removing a page through PDFKit and saving leaves nothing of it in the file: no object with its text, image, tags,
/// note, field, bookmark or named destination is written, while the other pages keep their tags, links and the rest.
@MainActor
private func documentKitSaveRemovedPagePrivacy() {
    let folder = tempFolder("removed-privacy")
    let url = folder.appendingPathComponent("Secret.pdf")
    let original = removedPageFixture()
    try? original.write(to: url)
    let before = decodedBytes(original) ?? Data()
    check(removedPageSecrets.allSatisfy { before.range(of: Data($0.utf8)) != nil }, "the fixture has every secret")
    let handle = openedHandle(url)
    handle.pdf.removePage(at: 1)
    let outcome = DocumentBaseline.saveOutcome(of: handle)
    check(outcome.method == .rewritten && outcome.notes.isEmpty, "removing a page rewrites the file: \(outcome.method) \(outcome.notes)")
    guard let model = try? PDFModel(data: outcome.data), let decoded = decodedBytes(outcome.data) else { return check(false, "QPDF opens the save") }
    check(model.check().isEmpty, "QPDF finds nothing wrong: \(model.check())")
    for secret in removedPageSecrets { check(decoded.range(of: Data(secret.utf8)) == nil, "nothing of the removed page is written: \(secret)") }
    check(decoded.range(of: Data("/Subtype /Image".utf8)) == nil, "no image is written")

    // What stays.
    check(model.pageCount == 2, "two pages")
    let (one, three) = (model.page(at: 0)!, model.page(at: 1)!)
    for (page, text) in [(one, "(Keep one)"), (three, "(Keep three)")] {
        let content = (try? page.contentData()).map { String(decoding: $0, as: UTF8.self) } ?? ""
        check(content.contains(text), "the page's own content: \(text)")
    }
    let document = model.root["StructTreeRoot"]?["K"]
    let elements = document?["K"]?.items ?? []
    check(elements.map { $0["S"]?.name } == ["P", "Span", "P"], "the other pages' tags stay, the section goes: \(elements.map { $0["S"]?.name })")
    check(elements.first?["Alt"]?.text == "Keep-one" && elements.last?["Alt"]?.text == "Keep-three", "with their text")
    check(elements.first?["Pg"].map { $0.isSameObject(as: one.object) } == true && elements.last?["Pg"].map { $0.isSameObject(as: three.object) } == true,
          "tags point at their pages")
    let spanKids = elements.count > 1 ? (elements[1]["K"]?.items ?? []) : []
    check(spanKids.count == 1 && spanKids.first?.int == 1, "the span keeps its content on page 1 only")
    let parentTree = (model.root["StructTreeRoot"]?["ParentTree"]).map(PDFNumberTree.entries) ?? []
    check(parentTree.map(\.key) == [0, 3] && one.object["StructParents"]?.int == 0 && three.object["StructParents"]?.int == 3, "the parent tree keeps the pages left")
    check(parentTree.first?.value.items.count == 2 && parentTree.last?.value.items.first?["Alt"]?.text == "Keep-three", "with their elements")
    let ids = (model.root["StructTreeRoot"]?["IDTree"]).map(PDFNameTree.entries) ?? []
    check(ids.map { String(decoding: $0.key, as: UTF8.self) } == ["p-one"], "the ID tree keeps the element left")
    check(model.root["MarkInfo"]?["Marked"]?.bool == true, "still marked")

    let bookmarks = model.outlines()
    check(bookmarks.map(\.title) == ["Intro", "Child of secret", "End"], "the bookmark to the page goes, its child takes its place: \(bookmarks.map(\.title))")
    check(bookmarks.map { $0.destination?.page } == [0, 1, 1], "the others go where they went: \(bookmarks.map { $0.destination?.page })")
    check(model.root["Outlines"]?["Count"]?.int == 3, "the bookmark count")
    check(model.destination(from: model.make(.ascii("endDest")))?.page == 1 && model.destination(from: model.make(.name("oldEnd")))?.page == 1,
          "the other named destinations stay")
    check(model.root["Dests"]?["oldSecret"] == nil, "the removed page's named destinations go")
    let links = one.annotations.filter { $0["Subtype"]?.name == "Link" }
    check(links.count == 4, "the links stay on their page")
    check(links.filter { $0["Dest"] == nil && $0["A"] == nil }.count == 3, "links to the removed page lose their destination")
    check(links.contains { model.destination(from: $0["Dest"])?.page == 1 }, "the link to the last page still goes there")
    check(model.root["OpenAction"]?[0].map { $0.isSameObject(as: one.object) } == true && model.root["OpenAction"]?[1]?.name == "FitH",
          "the file opens on the first page now")
    check(model.pageLabels().map(\.startPage) == [0, 1] && model.pageLabel(at: 0) == "i" && model.pageLabel(at: 1) == "iii", "the pages keep their labels")
    let thread = model.root["Threads"]?[0]
    let bead = thread?["F"]
    check(bead?["P"].map { $0.isSameObject(as: three.object) } == true && bead?["N"].map { $0.isSameObject(as: bead!) } == true
          && bead?["T"].map { $0.isSameObject(as: thread!) } == true, "the thread keeps the bead on the page left")
    let private_ = model.root["SPPrivate"]
    check(private_?["Last"] == nil && private_?["Pages"]?.count == 2 && private_?["Pages"]?[0]?.isNull == true
          && private_?["Pages"]?[1].map { $0.isSameObject(as: three.object) } == true, "any other reference to the page is cleared")
    check(model.formFields().map(\.name) == ["keptField"] && model.root["AcroForm"]?["CO"]?.items.map { $0["T"]?.text } == ["keptField"],
          "the removed page's field leaves the form")

    guard let reopened = PDFDocument(data: outcome.data) else { return check(false, "PDFKit opens the save") }
    check(reopened.pageCount == 2 && reopened.page(at: 1)?.string?.contains("Keep three") == true, "PDFKit reads it")
    check(reopened.outlineRoot?.numberOfChildren == 3, "PDFKit reads the bookmarks")
}

/// Changing the title, author, subject and keywords changes the XMP packet to match and keeps everything else in it.
@MainActor
private func documentKitSaveXMP() {
    let folder = tempFolder("xmp")
    let url = folder.appendingPathComponent("Metadata.pdf")
    let model = try! PDFModel(data: makePDF(pages: 1))
    model.setInfo("Title", "Old title")
    model.setInfo("Keywords", "old")
    let xmp = """
    <?xpacket begin="\u{FEFF}" id="W5M0MpCehiHzreSzNTczkc9d"?>
    <x:xmpmeta xmlns:x="adobe:ns:meta/"><rdf:RDF xmlns:rdf="http://www.w3.org/1999/02/22-rdf-syntax-ns#">
    <rdf:Description rdf:about="" xmlns:dc="http://purl.org/dc/elements/1.1/" xmlns:xmp="http://ns.adobe.com/xap/1.0/">
    <dc:title><rdf:Alt><rdf:li xml:lang="x-default">Old title</rdf:li><rdf:li xml:lang="de">Alter Titel</rdf:li></rdf:Alt></dc:title>
    <dc:creator><rdf:Seq><rdf:li>Old author</rdf:li></rdf:Seq></dc:creator>
    <dc:format>application/pdf</dc:format>
    <xmp:ModifyDate>2001-01-01T00:00:00Z</xmp:ModifyDate><xmp:MetadataDate>2001-01-01T00:00:00Z</xmp:MetadataDate>
    <xmp:CreateDate>2001-01-01T00:00:00Z</xmp:CreateDate>
    </rdf:Description>
    <rdf:Description rdf:about="" xmlns:pdf="http://ns.adobe.com/pdf/1.3/" pdf:Keywords="old" pdf:Producer="Fixture"/>
    <rdf:Description rdf:about="" xmlns:superpdf="https://superpdf.app/ns/"><superpdf:fixture>kept</superpdf:fixture></rdf:Description>
    </rdf:RDF></x:xmpmeta>
    <?xpacket end="w"?>
    """
    model.root.set("Metadata", model.makeStream(["Type": .name("Metadata"), "Subtype": .name("XML")], data: Data(xmp.utf8)))
    try? model.data(options: PDFWriteOptions(objectStreams: .disable)).write(to: url)

    let handle = openedHandle(url)
    var attributes = handle.pdf.documentAttributes ?? [:]
    attributes[PDFDocumentAttribute.titleAttribute] = "New <title> & more"
    attributes[PDFDocumentAttribute.authorAttribute] = "Ada Lovelace"
    attributes[PDFDocumentAttribute.subjectAttribute] = "Engines"
    attributes[PDFDocumentAttribute.keywordsAttribute] = ["alpha", "beta"]
    handle.pdf.documentAttributes = attributes
    let outcome = DocumentBaseline.saveOutcome(of: handle)
    check(outcome.method == .appended, "properties are appended: \(outcome.method) \(outcome.notes)")
    func packet(_ data: Data) -> (PDFModel?, String) {
        let saved = try? PDFModel(data: data)
        let stream = saved?.root["Metadata"]
        return (saved, (try? stream?.streamData(decode: .all)).flatMap { $0.map { String(decoding: $0, as: UTF8.self) } } ?? "")
    }
    let (saved, text) = packet(outcome.data)
    check(saved?.info("Title") == "New <title> & more" && saved?.info("Keywords") == "alpha, beta", "the information dictionary")
    check(text.contains("<rdf:li xml:lang=\"x-default\">New &lt;title&gt; &amp; more</rdf:li><rdf:li xml:lang=\"de\">Alter Titel</rdf:li>"),
          "dc:title, other languages kept: \(text)")
    check(text.contains("<dc:creator><rdf:Seq><rdf:li>Ada Lovelace</rdf:li></rdf:Seq></dc:creator>") && !text.contains("Old author"), "dc:creator")
    check(text.contains("<dc:description><rdf:Alt><rdf:li xml:lang=\"x-default\">Engines</rdf:li></rdf:Alt></dc:description>"), "dc:description added")
    check(text.contains("pdf:Keywords=\"alpha, beta\"") && !text.contains("<pdf:Keywords>"), "pdf:Keywords in place")
    check(!text.contains("<xmp:ModifyDate>2001") && !text.contains("<xmp:MetadataDate>2001") && text.contains("<xmp:CreateDate>2001-01-01T00:00:00Z</xmp:CreateDate>"),
          "the modification dates change, the creation date doesn't")
    let modified = text.range(of: "<xmp:ModifyDate>([^<]*)</xmp:ModifyDate>", options: .regularExpression).map { String(text[$0]).dropFirst(16).dropLast(17) }
    let infoDate = saved?.info("ModDate").flatMap(PDFDate.date)
    let xmpDate = modified.flatMap { ISO8601DateFormatter().date(from: String($0)) }
    check(infoDate != nil && xmpDate != nil && abs(infoDate!.timeIntervalSince(xmpDate!)) < 1, "xmp:ModifyDate matches /ModDate: \(String(describing: modified))")
    check(text.contains("<dc:format>application/pdf</dc:format>") && text.contains("pdf:Producer=\"Fixture\"")
          && text.contains("<superpdf:fixture>kept</superpdf:fixture>") && text.hasSuffix("<?xpacket end=\"w\"?>"), "the rest of the packet stays")
    check(saved?.root["Metadata"]?["Filter"] == nil, "the packet stays readable as it is")
    check(PDFDocument(data: outcome.data)?.documentAttributes?[PDFDocumentAttribute.titleAttribute] as? String == "New <title> & more", "PDFKit reads it")

    // Removing a property removes it from the packet; a packet without the namespace gets a description for it.
    let cleared = folder.appendingPathComponent("Cleared.pdf")
    try? outcome.data.write(to: cleared)
    let second = openedHandle(cleared)
    var fewer = second.pdf.documentAttributes ?? [:]
    fewer.removeValue(forKey: PDFDocumentAttribute.keywordsAttribute)
    fewer.removeValue(forKey: PDFDocumentAttribute.subjectAttribute)
    second.pdf.documentAttributes = fewer
    let (_, after) = packet(DocumentBaseline.saveOutcome(of: second).data)
    check(!after.contains("pdf:Keywords") && !after.contains("dc:description") && after.contains("pdf:Producer=\"Fixture\"")
          && after.contains("Ada Lovelace"), "removed properties leave the packet: \(after)")

    let fidelity = folder.appendingPathComponent("Fidelity.pdf")
    try? fidelityFixture().write(to: fidelity)
    let third = openedHandle(fidelity)
    var titled = third.pdf.documentAttributes ?? [:]
    titled[PDFDocumentAttribute.titleAttribute] = "Retitled"
    third.pdf.documentAttributes = titled
    let (_, added) = packet(DocumentBaseline.saveOutcome(of: third).data)
    check(added.contains("xmlns:dc=\"http://purl.org/dc/elements/1.1/\"><dc:title><rdf:Alt><rdf:li xml:lang=\"x-default\">Retitled</rdf:li></rdf:Alt></dc:title>")
          && added.contains("<superpdf:fixture>kept</superpdf:fixture>"), "a packet without the property gets it: \(added)")
}

// MARK: - Performance

/// A long document with markup on every page (2000 pages; a note with its popup, a highlight and an ink drawing on
/// each, so 8000 PDFKit annotations) and a hundred bookmarks, as PDFKit writes one.
func performanceFixture(pages: Int) -> Data {
    let data = NSMutableData()
    var box = CGRect(x: 0, y: 0, width: 612, height: 792)
    guard let consumer = CGDataConsumer(data: data as CFMutableData), let context = CGContext(consumer: consumer, mediaBox: &box, nil) else { return Data() }
    for index in 0..<pages {
        context.beginPDFPage(nil)
        NSGraphicsContext.current = NSGraphicsContext(cgContext: context, flipped: false)
        ("Page \(index + 1): the quick brown fox jumps over the lazy dog" as NSString).draw(at: CGPoint(x: 72, y: 700), withAttributes: [.font: NSFont.systemFont(ofSize: 12)])
        NSGraphicsContext.current = nil
        context.endPDFPage()
    }
    context.closePDF()
    guard let pdf = PDFDocument(data: data as Data) else { return Data() }
    for index in 0..<pdf.pageCount {
        guard let page = pdf.page(at: index) else { continue }
        let note = PDFAnnotation(bounds: CGRect(x: 72, y: 600, width: 20, height: 20), forType: .text, withProperties: nil)
        note.contents = "Note \(index + 1)"
        note.color = .systemYellow
        page.addAnnotation(note)
        let highlight = PDFAnnotation(bounds: CGRect(x: 72, y: 698, width: 120, height: 14), forType: .highlight, withProperties: nil)
        highlight.quadrilateralPoints = [NSValue(point: CGPoint(x: 0, y: 14)), NSValue(point: CGPoint(x: 120, y: 14)), NSValue(point: .zero), NSValue(point: CGPoint(x: 120, y: 0))]
        highlight.color = .systemYellow
        page.addAnnotation(highlight)
        let ink = PDFAnnotation(bounds: CGRect(x: 100, y: 100, width: 200, height: 200), forType: .ink, withProperties: nil)
        let path = NSBezierPath()
        path.move(to: CGPoint(x: 10, y: 10)); path.line(to: CGPoint(x: 150, y: 120)); path.line(to: CGPoint(x: 60, y: 180))
        ink.add(path)
        ink.color = .systemBlue
        page.addAnnotation(ink)
    }
    let outline = PDFOutline()
    for index in 0..<100 {
        let item = PDFOutline()
        item.label = "Chapter \(index + 1)"
        if let page = pdf.page(at: index * pages / 100) { item.destination = PDFKit.PDFDestination(page: page, at: CGPoint(x: 0, y: 792)) }
        outline.insertChild(item, at: index)
    }
    pdf.outlineRoot = outline
    return pdf.dataRepresentation() ?? Data()
}

/// The highlight the performance case adds (at y 500), if `page` has it.
private func performanceHighlight(on page: PDFModelKit.PDFPage?) -> PDFObject? {
    page?.annotations.first { annotation in
        let rect: PDFObject? = annotation["Rect"]
        return annotation["Subtype"]?.name == "Highlight" && rect?[1]?.number == 500
    }
}

/// The text of the note on `page`.
private func performanceNote(on page: PDFModelKit.PDFPage?) -> String? {
    let note: PDFObject? = page?.annotations.first { $0["Subtype"]?.name == "Text" }
    return note?["Contents"]?.text
}

/// Saves see every kind of change through PDFKit although they look only at the pages something could have changed:
/// looking at pages changes nothing, and each edit (made the ways modules and PDFView make them, in place included)
/// reaches the file, with the pages nobody touched kept object for object.
@MainActor
private func documentKitSaveTracking() {
    let folder = tempFolder("tracking")
    let url = folder.appendingPathComponent("Tracked.pdf")
    let original = performanceFixture(pages: 12)
    guard (try? original.write(to: url)) != nil else { return check(false, "the fixture is written") }
    let handle = openedHandle(url)
    let pdf = handle.pdf

    // Reading, drawing and clicking are not changes.
    for index in 0..<4 { _ = pdf.page(at: index)?.annotations.map { ($0.contents, $0.border?.lineWidth, $0.bounds) } }
    if let page = pdf.page(at: 1), let context = CGContext(data: nil, width: 612, height: 792, bitsPerComponent: 8, bytesPerRow: 0,
                                                           space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) {
        page.draw(with: .mediaBox, to: context)
    }
    _ = pdf.page(at: 2)?.annotation(at: CGPoint(x: 80, y: 608))
    _ = pdf.page(at: 5)?.rotation
    check(DocumentBaseline.saveOutcome(of: handle).method == .unchanged, "looking at pages changes nothing")

    func annotation(_ page: Int, _ type: String) -> PDFAnnotation? { pdf.page(at: page)?.annotations.first { $0.type == type } }
    annotation(0, "Text")?.bounds = CGRect(x: 90, y: 610, width: 20, height: 20)
    annotation(1, "Highlight")?.color = .systemPink
    annotation(11, "Ink")?.border?.lineWidth = 4   // in place, on a page nothing else touched: PDFKit writes it back
    if let page = pdf.page(at: 3), let highlight = annotation(3, "Highlight") { page.removeAnnotation(highlight) }
    pdf.page(at: 4)?.rotation = 180
    pdf.page(at: 5)?.setBounds(CGRect(x: 36, y: 36, width: 540, height: 720), for: .cropBox)
    if let page = pdf.page(at: 6), let target = pdf.page(at: 9) {
        let link = PDFAnnotation(bounds: CGRect(x: 72, y: 72, width: 100, height: 20), forType: .link, withProperties: nil)
        link.destination = PDFKit.PDFDestination(page: target, at: CGPoint(x: 0, y: 792))
        page.addAnnotation(link)
    }
    _ = annotation(7, "Text")?.setValue("Set through its key", forAnnotationKey: .contents)

    let outcome = DocumentBaseline.saveOutcome(of: handle)
    check(outcome.method == .appended && outcome.notes.isEmpty, "the edits are appended: \(outcome.method) \(outcome.notes)")
    guard let model = try? PDFModel(data: outcome.data), let base = try? PDFModel(data: original) else { return check(false, "QPDF reads the save") }
    func saved(_ page: Int, _ subtype: String) -> PDFObject? { model.page(at: page)?.annotations.first { $0["Subtype"]?.name == subtype } }
    check(saved(0, "Text")?["Rect"]?[0]?.number == 90, "the moved note")
    check(saved(1, "Highlight")?["C"] != nil && saved(1, "Highlight")?["C"]?.value != base.page(at: 1)?.annotations.first { $0["Subtype"]?.name == "Highlight" }?["C"]?.value,
          "the recoloured highlight")
    let ink = saved(11, "Ink")
    check(ink?["BS"]?["W"]?.number == 4 || ink?["Border"]?[2]?.number == 4, "the border changed in place")
    check(saved(3, "Highlight") == nil && saved(3, "Text") != nil, "the removed highlight, the rest of its page kept")
    check(model.page(at: 4)?.rotation == 90 + 90, "the rotated page")
    check(model.page(at: 5)?.object["CropBox"]?[0]?.number == 36, "the cropped page")
    let link = saved(6, "Link")
    let destination = link?["Dest"] ?? link?["A"]?["D"]
    check(destination?[0].map { $0.isSameObject(as: model.page(at: 9)!.object) } == true, "the new link leads to the file's own page 10")
    check(saved(7, "Text")?["Contents"]?.text == "Set through its key", "the note set through its key")
    for index in 8..<11 {
        check(model.page(at: index)?.annotations.map(\.objectID) == base.page(at: index)?.annotations.map(\.objectID), "page \(index + 1) is the file's own")
    }

    // A snapshot is kept until something changes.
    handle.state.isEdited = true
    let first = handle.snapshot(), again = handle.snapshot()
    if case .data(let a, _) = first, case .data(let b, _) = again { check(a == b, "an unchanged document snapshots the same bytes") }
    annotation(10, "Text")?.contents = "Later"
    if case .data(let later, _) = handle.snapshot(), let reread = try? PDFModel(data: later) {
        check(reread.page(at: 10)?.annotations.first { $0["Subtype"]?.name == "Text" }?["Contents"]?.text == "Later", "a later change is in the next snapshot")
    } else {
        check(false, "the snapshot after a change")
    }
}

/// Main-thread time of `body` in milliseconds, the best of `runs` (a loaded machine adds noise, never removes it).
@MainActor
func mainThreadTime(runs: Int = 1, _ body: () -> Void) -> Double {
    var best = Double.infinity
    for _ in 0..<runs {
        let start = DispatchTime.now().uptimeNanoseconds
        body()
        best = min(best, Double(DispatchTime.now().uptimeNanoseconds - start) / 1_000_000)
    }
    return best
}

/// "Light as Preview" on a long file: opening attaches the bytes without reading every annotation, the first edit
/// costs only its page, and a save takes on the main thread only what changed (the merge runs off it). Budgets are
/// checked in release builds; a debug build prints the times and skips them (unoptimised code isn't what people run).
@MainActor
private func documentKitPerformance() {
    let folder = tempFolder("performance")
    let url = folder.appendingPathComponent("Long.pdf")
    let original = performanceFixture(pages: 2000)
    guard (try? original.write(to: url)) != nil, original.count > 0 else { return check(false, "the fixture is written") }

    // Open: the window's PDFKit document and its authoritative bytes.
    var handle: DocumentHandle!
    let open = mainThreadTime(runs: 3) {
        guard let pdf = DocumentBaseline.document(url: url), let bytes = try? Data(contentsOf: url, options: .mappedIfSafe) else { return }
        handle = DocumentHandle(url: url, pdf: pdf, state: DocumentState(), undoManager: makeUndoManager())
        DocumentBaseline.attach(bytes, to: handle)
    }
    guard handle != nil, handle.pageCount == 2000 else { return check(false, "the long file opens") }
    let pdf = handle.pdf
    // The window shows the first pages (PDFKit reads their annotations to draw them).
    for index in 0..<3 { _ = pdf.page(at: index)?.annotations }

    // A first edit: a highlight on page 1000 and an edited note on page 1500.
    let edit = mainThreadTime {
        let highlight = PDFAnnotation(bounds: CGRect(x: 72, y: 500, width: 80, height: 14), forType: .highlight, withProperties: nil)
        highlight.quadrilateralPoints = [NSValue(point: CGPoint(x: 0, y: 14)), NSValue(point: CGPoint(x: 80, y: 14)), NSValue(point: .zero), NSValue(point: CGPoint(x: 80, y: 0))]
        highlight.color = .systemGreen
        pdf.page(at: 999)?.addAnnotation(highlight)
        pdf.page(at: 1499)?.annotations.first { $0.type == "Text" }?.contents = "Edited note"
    }
    handle.state.isEdited = true

    // Save: what runs on the main thread before NSDocument writes in the background.
    var prepared: DocumentBaseline.PreparedSave?
    let save = mainThreadTime(runs: 3) { prepared = DocumentBaseline.prepareSave(of: handle) }
    var outcome: SaveOutcome?
    let merge = mainThreadTime { outcome = prepared?.run() }
    check(outcome?.method == .appended && outcome?.notes.isEmpty == true, "the edits are appended: \(String(describing: outcome?.method)) \(outcome?.notes ?? [])")
    if let data = outcome?.data, let model = try? PDFModel(data: data) {
        check(data.prefix(original.count) == original, "the original bytes are untouched")
        check(performanceHighlight(on: model.page(at: 999)) != nil, "the new highlight on page 1000")
        check(performanceNote(on: model.page(at: 1499)) == "Edited note", "the edited note on page 1500")
        check(performanceNote(on: model.page(at: 1498)) == "Note 1499", "the page before is as it was")
        check(model.outlines().count == 100, "the bookmarks are kept")
    } else {
        check(false, "QPDF reads the save")
    }

    // Page operations: a rotated page and a removed one (the file is rewritten without it).
    let pageEdit = mainThreadTime {
        pdf.page(at: 10)?.rotation = 90
        pdf.removePage(at: 20)
    }
    var pagesSaved: DocumentBaseline.PreparedSave?
    let pageSave = mainThreadTime(runs: 3) { pagesSaved = DocumentBaseline.prepareSave(of: handle) }
    let pagesOutcome = pagesSaved?.run()
    check(pagesOutcome?.method == .rewritten, "removing a page rewrites the file: \(String(describing: pagesOutcome?.method)) \(pagesOutcome?.notes ?? [])")
    if let data = pagesOutcome?.data, let model = try? PDFModel(data: data) {
        check(model.pageCount == 1999 && model.page(at: 10)?.rotation == 90, "the rotated page, one page fewer")
        check(performanceHighlight(on: model.page(at: 998)) != nil, "the earlier edit is still there (page 999 now)")
        check(performanceNote(on: model.page(at: 20)) == "Note 22", "the page after the removed one moved up")
    } else {
        check(false, "QPDF reads the save with pages changed")
    }

    let times = String(format: "open %.1f ms, first edit %.1f ms, save %.1f ms on the main thread (merge %.0f ms off it), page edit %.1f ms, save after page edits %.1f ms",
                       open, edit, save, merge, pageEdit, pageSave)
    #if DEBUG
    print("  DocumentKit.performance (debug build, budgets not checked): \(times)")
    #else
    print("  DocumentKit.performance: \(times)")
    check(open < 16, "opening attaches the bytes without a stall: \(times)")
    check(edit < 16, "a first edit costs only its pages: \(times)")
    check(save < 16, "a save takes under a frame on the main thread: \(times)")
    // Removing a page is mostly PDFKit's own work; it and the save after it stay under the worst-case budget.
    check(pageEdit < 50 && pageSave < 50, "page operations and their save stay under the worst-case budget: \(times)")
    #endif
}
