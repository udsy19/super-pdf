import AppKit
import PDFKit
import SuperPDFCore
import UniformTypeIdentifiers

/// One open PDF as an NSDocument (ux §7.1): autosave and versions, the "Save a copy / Replace original" first save,
/// Preview's close question, undo through the document's undo manager. The `DocumentHandle` is what other modules see.
///
/// The original is never written before the first choice: until then autosave keeps the changes in an autosave file
/// elsewhere, and closing asks. Writes happen off the main thread from a private copy of the PDFKit document, into a
/// temporary file that is checked by reading it back before NSDocument swaps it into place.
@objc(SuperPDFDocument)
public final class PDFFileDocument: NSDocument, MenuCommandResponding {
    static let pdfType = UTType.pdf.identifier

    /// Nil only between NSDocument's own `init()` and the first read (versions browser, restoration).
    public private(set) var handle: DocumentHandle!
    weak var manager: DocumentManager?

    /// The bytes and facts captured on the main thread at the start of a save, written by `write(to:…)` off it.
    nonisolated(unsafe) private var pendingWrite: PendingWrite?

    init(handle: DocumentHandle, manager: DocumentManager?) {
        super.init()
        self.manager = manager
        attach(handle)
    }

    override init() { super.init() }

    private func attach(_ handle: DocumentHandle) {
        self.handle = handle
        handle.undoManager = undoManager
        hasUndoManager = true
    }

    // MARK: Types

    override public nonisolated class var autosavesInPlace: Bool { true }
    override public class var readableTypes: [String] { [pdfType] }
    override public class var writableTypes: [String] { [pdfType] }
    override public class func isNativeType(_ type: String) -> Bool { type == pdfType }
    override public nonisolated func writableTypes(for saveOperation: NSDocument.SaveOperationType) -> [String] { [Self.pdfType] }
    override public nonisolated func fileNameExtension(forType typeName: String, saveOperation: NSDocument.SaveOperationType) -> String? { "pdf" }
    override public func canAsynchronouslyWrite(to url: URL, ofType typeName: String, for saveOperation: NSDocument.SaveOperationType) -> Bool {
        true
    }

    override public var displayName: String! {
        get { fileURL == nil ? handle?.displayName ?? super.displayName : super.displayName }
        set { super.displayName = newValue }
    }

    override public nonisolated var fileURL: URL? {
        didSet {
            let url = fileURL
            let sync = { @MainActor [weak self] in
                guard let self, let handle = self.handle, let url, handle.url != url else { return }
                handle.url = url
                handle.displayName = url.deletingPathExtension().lastPathComponent
            }
            if Thread.isMainThread { MainActor.assumeIsolated(sync) } else { DispatchQueue.main.async(execute: sync) }
        }
    }

    // MARK: Windows

    override public func makeWindowControllers() {
        guard let viewer = Services.viewer, let handle else { return }
        let controller = viewer.makeWindowController(for: handle)
        controller.window?.tabbingIdentifier = "SuperPDFDocument"
        controller.window?.tabbingMode = Defaults[.openFilesInTabs] ? .preferred : .automatic
        addWindowController(controller)
    }

    var window: NSWindow? { windowControllers.first?.window }

    // MARK: Reading (versions browser, Revert, restoration)

    override public nonisolated func read(from url: URL, ofType typeName: String) throws {
        try MainActor.assumeIsolated {
            guard let pdf = PDFDocument(url: url) else { throw DocumentError.damaged(url.lastPathComponent) }
            if pdf.isLocked {
                guard let password = handle?.password ?? manager?.knownPassword(for: fileURL ?? url),
                      pdf.unlock(withPassword: password) else { throw CocoaError(.userCancelled) }
            }
            if let handle {
                manager?.replaceContents(of: handle, with: pdf)   // Revert To
            } else {
                attach(DocumentHandle(url: fileURL ?? url, pdf: pdf, state: Self.state(for: pdf, origin: .opened, repaired: false)))
                manager = DocumentManager.current
            }
        }
    }

    static func state(for pdf: PDFDocument, origin: DocumentOrigin, repaired: Bool) -> DocumentState {
        let forms = FormScan.scan(pdf)
        return DocumentState(origin: origin, isEdited: repaired, wasRepaired: repaired, isEncrypted: pdf.isEncrypted, isLocked: pdf.isLocked,
                             permissions: DocumentPermissions(pdf), hasFormFields: forms.hasFields, hasSignatures: forms.hasSignatures)
    }

    // MARK: Writing

    /// Every save, autosave included, comes through here on the main thread: take the snapshot now, so what is written
    /// is exactly the state NSDocument counts as saved, then let NSDocument write it in the background.
    override public func save(to url: URL, ofType typeName: String, for saveOperation: NSDocument.SaveOperationType,
                              completionHandler: @escaping (Error?) -> Void) {
        pendingWrite = handle.map { PendingWrite(handle: $0, isEdited: isDocumentEdited, file: fileURL) }
        super.save(to: url, ofType: typeName, for: saveOperation) { [weak self] error in
            self?.pendingWrite = nil
            if error == nil, let self, let handle = self.handle, saveOperation != .autosaveElsewhereOperation, saveOperation != .saveToOperation {
                self.manager?.eventSubject.send(.saved(handle.id))
            }
            completionHandler(error)
        }
    }

    override public nonisolated func write(to url: URL, ofType typeName: String, for saveOperation: NSDocument.SaveOperationType,
                                           originalContentsURL: URL?) throws {
        let pending = pendingWrite
        unblockUserInteraction()
        guard let pending else { throw CocoaError(.fileWriteUnknown) }
        try pending.write(to: url)
    }

    // MARK: Change tracking

    override public func updateChangeCount(_ change: NSDocument.ChangeType) {
        super.updateChangeCount(change)
        guard let handle else { return }
        handle.state.isEdited = isDocumentEdited
        switch change {
        case .changeDone, .changeUndone, .changeRedone: manager?.eventSubject.send(.changed(handle.id))
        default: break
        }
    }

    /// Saves clear the change count through their token.
    override public func updateChangeCount(withToken changeCountToken: Any, for saveOperation: NSDocument.SaveOperationType) {
        super.updateChangeCount(withToken: changeCountToken, for: saveOperation)
        handle?.state.isEdited = isDocumentEdited
    }

    // MARK: Save policy (ux §7.1)

    public var saveStep: SaveStep {
        SavePolicy.step(origin: handle.state.origin, hasFile: fileURL != nil, choice: handle.state.saveChoice,
                        wasRepaired: handle.state.wasRepaired, setting: Defaults[.saveBehaviour])
    }

    var mayWriteInPlace: Bool {
        SavePolicy.mayWriteInPlace(origin: handle.state.origin, hasFile: fileURL != nil, choice: handle.state.saveChoice)
    }

    /// File › Save (⌘S).
    override public func save(_ sender: Any?) {
        Task { await runSave() }
    }

    /// Runs ⌘S to the end; true when the document was written.
    @discardableResult
    public func runSave() async -> Bool {
        guard let manager else { return false }
        switch saveStep {
        case .save:
            guard let url = fileURL else { return false }
            return await write(to: url, .saveOperation)
        case .savePanel:
            return await saveCopy(proposing: manager.untitledProposal(for: handle))
        case .saveCopy:
            return await saveCopy(proposing: manager.copyProposal(for: handle))
        case .replaceOriginal:
            return await replaceOriginal()
        case .ask:
            guard let reply = await manager.prompter.firstSave(of: fileURL?.lastPathComponent ?? displayName, window: window) else {
                return false
            }
            let (step, newSetting) = SavePolicy.resolve(reply.answer, always: reply.always)
            if let newSetting { Defaults[.saveBehaviour] = newSetting }
            return step == .replaceOriginal ? await replaceOriginal() : await saveCopy(proposing: manager.copyProposal(for: handle))
        }
    }

    /// "Save a copy…": the save panel proposes the name; the document then lives in the copy and the original is left
    /// exactly as it was.
    @discardableResult
    public func saveCopy(proposing proposal: URL) async -> Bool {
        guard let manager, let url = await manager.prompter.saveLocation(proposing: proposal, window: window) else { return false }
        guard await write(to: url, .saveAsOperation) else { return false }
        if handle.state.origin == .opened { handle.state.saveChoice = .alwaysSaveCopy }
        manager.recents.note(url, pageCount: handle.pageCount)
        return true
    }

    /// "Replace original": NSDocument keeps the old contents as a version (Revert To › Browse All Versions).
    private func replaceOriginal() async -> Bool {
        guard let url = fileURL, await write(to: url, .saveOperation) else { return false }
        handle.state.saveChoice = .replaceOriginal
        return true
    }

    private func write(to url: URL, _ operation: NSDocument.SaveOperationType) async -> Bool {
        let error: Error? = await withCheckedContinuation { continuation in
            save(to: url, ofType: Self.pdfType, for: operation) { continuation.resume(returning: $0) }
        }
        if let error {
            if !((error as? CocoaError)?.code == .userCancelled) { presentError(error) }
            return false
        }
        discardAutosave()
        handle.state.wasRepaired = false   // what is on disk now is what the person checked and saved
        return true
    }

    // MARK: Autosave

    override public func autosave(withImplicitCancellability autosavingIsImplicitlyCancellable: Bool,
                                  completionHandler: @escaping (Error?) -> Void) {
        guard let manager, handle != nil, !mayWriteInPlace else {
            super.autosave(withImplicitCancellability: autosavingIsImplicitlyCancellable, completionHandler: completionHandler)
            return
        }
        // Before the first choice the original is not touched: changes go to an autosave file of our own.
        guard hasUnautosavedChanges else { completionHandler(nil); return }
        let url = autosavedContentsFileURL ?? manager.autosaveURL(for: handle)
        save(to: url, ofType: Self.pdfType, for: .autosaveElsewhereOperation) { [weak self] error in
            if error == nil { self?.autosavedContentsFileURL = url }
            completionHandler(error)
        }
    }

    /// Removes the autosave file once its changes are saved or discarded.
    func discardAutosave() {
        guard let url = autosavedContentsFileURL, url != fileURL else { return }
        try? FileManager.default.removeItem(at: url)
        autosavedContentsFileURL = nil
    }

    // MARK: Closing (ux §7.1)

    override public func canClose(withDelegate delegate: Any, shouldClose shouldCloseSelector: Selector?,
                                  contextInfo: UnsafeMutableRawPointer?) {
        guard handle != nil, isDocumentEdited, !mayWriteInPlace else {
            super.canClose(withDelegate: delegate, shouldClose: shouldCloseSelector, contextInfo: contextInfo)
            return
        }
        let context = UncheckedPointer(pointer: contextInfo)
        Task {
            let shouldClose = await closeFlow()
            Self.reply(to: delegate as AnyObject, shouldCloseSelector, document: self, shouldClose, context.pointer)
        }
    }

    /// Review Changes… runs the save; Discard Changes throws the edits and the autosave away; Cancel keeps the window.
    public func closeFlow() async -> Bool {
        guard let manager else { return false }
        switch await manager.prompter.closeWithUnsavedChanges(window: window) {
        case .review:
            return await runSave()
        case .discard:
            discardAutosave()
            updateChangeCount(.changeCleared)
            return true
        case .cancel:
            return false
        }
    }

    private static func reply(to delegate: AnyObject, _ selector: Selector?, document: NSDocument, _ shouldClose: Bool,
                              _ context: UnsafeMutableRawPointer?) {
        guard let selector, let method = delegate.method(for: selector) else { return }
        typealias Callback = @convention(c) (AnyObject, Selector, NSDocument, Bool, UnsafeMutableRawPointer?) -> Void
        unsafeBitCast(method, to: Callback.self)(delegate, selector, document, shouldClose, context)
    }

    override public func close() {
        if let handle { manager?.documentWillClose(handle) }
        super.close()
    }

    // MARK: Menu commands: Save a Copy… (⌘⇧S), Enter Password…

    public func performMenuCommand(_ sender: NSMenuItem) {
        guard let manager, let handle else { return }
        switch sender.menuCommand {
        case .saveACopy?: Task { await saveCopy(proposing: fileURL == nil ? manager.untitledProposal(for: handle) : manager.copyProposal(for: handle)) }
        case .enterPassword?: Task { await manager.enterOwnerPassword(for: handle) }
        default: break
        }
    }

    override public func validateMenuItem(_ menuItem: NSMenuItem) -> Bool {
        switch menuItem.menuCommand {
        case .saveACopy?: return handle != nil
        case .enterPassword?: return handle?.state.permissions.isRestricted == true
        default: return super.validateMenuItem(menuItem)
        }
    }
}

/// A `contextInfo` pointer carried across the close question (NSDocument hands it back unchanged).
private struct UncheckedPointer: @unchecked Sendable { var pointer: UnsafeMutableRawPointer? }

/// What a save writes, captured on the main thread: a private copy of the PDFKit document (cheap, and independent of
/// later edits), or — when nothing changed since it was read — the file itself, copied byte for byte (a clone on APFS)
/// so signatures and incremental updates survive.
struct PendingWrite: @unchecked Sendable {
    let pdf: PDFDocument
    let unchangedFile: URL?
    let password: String?
    let pageCount: Int

    @MainActor
    init(handle: DocumentHandle, isEdited: Bool, file: URL?) {
        pdf = handle.pdf.copy() as! PDFDocument
        unchangedFile = !isEdited && !handle.state.wasRepaired ? file : nil
        password = handle.password
        pageCount = handle.pdf.pageCount
    }

    /// Writes to `url` (NSDocument's temporary file for safe saves) and reads it back before NSDocument replaces
    /// anything: a write that doesn't reopen as the same document fails the save and the old file stays.
    func write(to url: URL) throws {
        if let unchangedFile, FileManager.default.fileExists(atPath: unchangedFile.path) {
            guard unchangedFile.standardizedFileURL != url.standardizedFileURL else { return }
            try FileManager.default.copyItem(at: unchangedFile, to: url)   // fails rather than replace anything
        } else {
            guard pdf.write(to: url) else { throw DocumentError.writeCheckFailed }
        }
        guard let check = PDFDocument(url: url) else { throw DocumentError.writeCheckFailed }
        if check.isLocked, !(password.map(check.unlock(withPassword:)) ?? false) { throw DocumentError.writeCheckFailed }
        guard check.pageCount == pageCount else { throw DocumentError.writeCheckFailed }
    }
}
