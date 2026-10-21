import AppKit
import Foundation
import PDFKit
import PDFModelKit
import SuperPDFCore

/// `Services.edit`: decorations, find & replace and scripts on open documents (features §1.5). Every call opens a
/// private PDFModelKit model of the document's bytes off the main actor, edits it, saves, and hands back a `.contents`
/// undo group that DocumentKit swaps in (ARCHITECTURE "Rules": engines see bytes, PDFKit stays on the main actor).
@MainActor
public final class EditService: ContentEditing {
    public init() {}

    // MARK: Decorations

    public func apply(_ decoration: Decoration, to pages: [Int], in document: DocumentHandle, replacing: Bool) async throws -> UndoGroup {
        let context = Self.context(for: document, bates: { if case .bates(let b) = decoration { b } else { nil } }())
        return try await EditEngine.edit(document, name: EditKitStrings.Undo.add(decoration.kind)) { model in
            if replacing {
                try DecorationWriter.remove(decoration.kind, from: model)
                if decoration.kind == .watermark { try DecorationWriter.remove(.background, from: model) }
                if decoration.kind == .background { try DecorationWriter.remove(.watermark, from: model) }
            }
            try DecorationWriter.apply(decoration, to: pages, in: model, context: context)
        }
    }

    public func decorations(in document: DocumentHandle) -> [DecorationKind] {
        let (source, fingerprint) = EditSource.current(for: document)
        if let cached = kindsCache[document.id], cached.fingerprint == fingerprint { return cached.kinds }
        let kinds = (try? PDFModel(source)).map(DecorationWriter.kinds) ?? []
        kindsCache[document.id] = (fingerprint, kinds)
        return kinds
    }

    private var kindsCache: [UUID: (fingerprint: String, kinds: [DecorationKind])] = [:]

    public func remove(_ kind: DecorationKind, from document: DocumentHandle) async throws -> UndoGroup {
        try await EditEngine.edit(document, name: EditKitStrings.Undo.remove(kind)) { model in
            try DecorationWriter.remove(kind, from: model)
        }
    }

    /// What fills the header tokens: the file's title and author, its name, the page count and today.
    static func context(for document: DocumentHandle, bates: BatesNumbering? = nil) -> DecorationContext {
        let attributes = document.pdf.documentAttributes ?? [:]
        let title = (attributes[PDFDocumentAttribute.titleAttribute] as? String) ?? ""
        let author = (attributes[PDFDocumentAttribute.authorAttribute] as? String) ?? Defaults[.authorName]
        let fileName = document.url?.lastPathComponent ?? document.displayName + ".pdf"
        return DecorationContext(title: title, fileName: fileName, author: author, pageCount: document.pageCount, date: Date(), bates: bates)
    }

    // MARK: Find & replace (features #72)

    public func replaceText(_ find: String, with replacement: String, options: FindReplaceOptions, pages: [Int],
                            in document: DocumentHandle) async throws -> (report: ReplaceReport, undo: UndoGroup) {
        let box = ReportBox()
        let undo = try await EditEngine.edit(document, name: EditKitStrings.Undo.replaceText) { model in
            for index in pages {
                guard let page = model.page(at: index) else { continue }
                let outcome = try TextRewriter.replaceAll(find, with: replacement, options: options, page: page)
                box.report.replaced += outcome.replaced
                box.report.notFitting += outcome.notFitting
                box.report.substitutedFonts.merge(outcome.substitutions) { a, _ in a }
            }
        }
        return (box.report, undo)
    }

    private final class ReportBox: @unchecked Sendable { var report = ReplaceReport(replaced: 0) }

    // MARK: Scripts (features #74)

    public func scripts(in document: DocumentHandle) async throws -> [String] {
        let source = EditSource.source(for: document)
        return try await Task.detached(priority: .userInitiated) {
            try ScriptScanner.scripts(in: PDFModel(source)).map(\.description)
        }.value
    }

    public func removeScripts(from document: DocumentHandle) async throws -> UndoGroup {
        try await EditEngine.edit(document, name: EditKitStrings.Undo.removeScripts) { model in ScriptScanner.removeScripts(from: model) }
    }
}

/// Opening, editing and saving a document's bytes for an in-place result.
enum EditEngine {
    /// Runs `body` on a private model of the document's bytes off the main actor and returns the `.contents` undo group
    /// (before → after). An appended save keeps earlier bytes (and signatures) intact; when the file can't take one
    /// (encrypted, rebuilt by recovery, made here) the whole file is written. The save is stamped and kept by
    /// `EditSource`, so the next edit starts from these bytes rather than PDFKit's redraw of them.
    @MainActor
    static func edit(_ document: DocumentHandle, name: String, _ body: @escaping @Sendable (PDFModel) throws -> Void) async throws -> UndoGroup {
        let source = EditSource.source(for: document)
        let (before, after, revision) = try await Task.detached(priority: .userInitiated) { () throws -> (Data, Data, String) in
            let before = try source.bytes()
            let model = try PDFModel(data: before, password: source.password)
            try body(model)
            let revision = EditSource.stamp(model)
            return (before, try save(model), revision)
        }.value
        EditSource.remember(after, revision: revision, password: source.password)
        return UndoGroup(name, .contents(before: before, after: after))
    }

    /// The model's bytes: appended when possible, else rewritten whole.
    static func save(_ model: PDFModel) throws -> Data {
        if model.canSaveIncrementally, let data = try? model.incrementalData() { return data }
        return try model.data()
    }
}
