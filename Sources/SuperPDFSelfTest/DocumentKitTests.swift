import AppKit
import Combine
import DocumentKit
import PDFKit
import SuperPDFCore

// DocumentKit's checks (WP3): naming collisions, the save-policy state machine, the password and repair flows, undo and
// redo of page operations and engine edits, the save flow (autosave never touches the original before the first
// choice; Save a copy / Replace), applying tool results, recents and view state. Every file lives in a fresh temporary
// folder; no window, panel or alert is shown (a scripted prompter answers).
func registerDocumentKitTests() {
    SelfTest.cases.append(("DocumentKit.naming", { documentKitNaming() }))
    SelfTest.cases.append(("DocumentKit.savePolicy", { documentKitSavePolicy() }))
    SelfTest.cases.append(("DocumentKit.passwordFlow", { documentKitPasswordFlow() }))
    SelfTest.cases.append(("DocumentKit.repairFlow", { documentKitRepairFlow() }))
    SelfTest.cases.append(("DocumentKit.undoPageOperations", { documentKitUndo() }))
    SelfTest.cases.append(("DocumentKit.saveFlow", { documentKitSaveFlow() }))
    SelfTest.cases.append(("DocumentKit.applyResults", { documentKitApplyResults() }))
    SelfTest.cases.append(("DocumentKit.recentsAndViewState", { documentKitRecentsAndViewState() }))
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
