import AppKit
import CoreGraphics
import Foundation
import PDFKit
import PDFModelKit
import SuperPDFCore

/// Edit text & images for one open document (ux §5.3 D, features #60–#62): what is selected, what a click does, and
/// every edit as one undo step. It is headless: the interaction view feeds it clicks and drags, the panel reads its
/// state, and the self-test drives it the same way. Each edit opens the document's bytes, rewrites one page and hands
/// DocumentKit a `.contents` undo group through `apply`.
@MainActor
final class EditModeSession {
    enum Tool: String { case select, addText, addImage, find }

    enum Selection: Equatable {
        case block(page: Int, id: Int)
        case image(page: Int, id: Int)

        var page: Int {
            switch self { case .block(let page, _), .image(let page, _): page }
        }
    }

    /// Style changes from the properties strip, applied to the selected block when it is committed.
    struct Style: Equatable {
        var fontFamily: String?
        var size: Double?
        var bold: Bool?
        var italic: Bool?
        var color: String?
        var alignment: TextAlignment?

        var isEmpty: Bool { fontFamily == nil && size == nil && bold == nil && italic == nil && color == nil && alignment == nil }
    }

    let document: DocumentHandle
    var tool: Tool = .select
    private(set) var selection: Selection?
    /// A picture chosen for "Add picture", placed by the next click.
    var pendingImage: URL?
    /// The last font stand-in, for the status line.
    private(set) var lastSubstitution: (from: String, to: String)?
    /// Applies an edit (DocumentKit swaps the bytes and registers undo); the self-test replaces it.
    var apply: @MainActor (UndoGroup) async throws -> Void
    /// Called after every edit and selection change (the interaction view redraws, the panel is refreshed).
    var onChange: (@MainActor () -> Void)?
    /// Pending style from the panel, applied to the next commit (and shown live by the inline editor).
    var pendingStyle = Style() {
        didSet { if pendingStyle != oldValue { onStyleChange?() } }
    }
    var onStyleChange: (@MainActor () -> Void)?

    private var cache: (fingerprint: String, model: PDFModel, pages: [Int: PageText])?

    init(document: DocumentHandle) {
        self.document = document
        apply = { group in
            let work = SuperPDFPaths.ensure(SuperPDFPaths.work.appendingPathComponent(UUID().uuidString, isDirectory: true))
            let request = ToolRequest(tool: .editTextAndImages, document: document, source: EditSource.source(for: document), workFolder: work)
            try await Services.documents.apply(.inPlace(undoable: group, banner: nil), of: request)
        }
    }

    // MARK: Reading

    /// The blocks and pictures of a page, from the document's current bytes.
    func pageText(_ index: Int) -> PageText? {
        let (source, fingerprint) = EditSource.current(for: document)
        if cache?.fingerprint != fingerprint {
            guard let model = try? PDFModel(source) else { return nil }
            cache = (fingerprint, model, [:])
        }
        if let hit = cache?.pages[index] { return hit }
        guard let model = cache?.model, let page = model.page(at: index), let content = try? ContentInterpreter.read(page, hiddenLayers: OptionalContent.hiddenLayers(in: model)) else { return nil }
        let text = PageText.analyze(page, content: content)
        cache?.pages[index] = text
        return text
    }

    func block(_ selection: Selection? = nil) -> TextBlock? {
        guard case .block(let page, let id)? = selection ?? self.selection else { return nil }
        return pageText(page)?.blocks.first { $0.id == id }
    }

    func image(_ selection: Selection? = nil) -> ImagePlacement? {
        guard case .image(let page, let id)? = selection ?? self.selection else { return nil }
        return pageText(page)?.content.images.first { $0.id == id }
    }

    /// Whether the selected block's font would be replaced when retyped (the status line).
    var selectedBlockNeedsSubstitute: Bool {
        guard let block = block() else { return false }
        return !block.style.font.canShow(block.text) || FontMatcher.match(block.style.font.facts, size: 12).substituted
    }

    // MARK: Clicks

    /// What a click on page `index` at `point` selects (or places), by the current tool.
    @discardableResult
    func click(page index: Int, at point: CGPoint) async -> Selection? {
        switch tool {
        case .select, .find:
            guard let text = pageText(index) else { return select(nil) }
            if let image = text.content.images.last(where: { !$0.inForm && $0.opIndex != nil && $0.bounds.contains(point) }),
               text.block(at: point).map({ !$0.bounds.contains(point) || image.bounds.width * image.bounds.height < $0.bounds.width * $0.bounds.height }) ?? true {
                return select(.image(page: index, id: image.id))
            }
            if let block = text.block(at: point) { return select(.block(page: index, id: block.id)) }
            return select(nil)
        case .addText:
            do {
                let selection = try await addText(at: point, page: index)
                tool = .select
                return select(selection)
            } catch {
                return select(nil)
            }
        case .addImage:
            guard let file = pendingImage else { return select(nil) }
            do {
                try await addImage(file, at: point, page: index)
                tool = .select
                pendingImage = nil
            } catch {}
            return select(nil)
        }
    }

    @discardableResult
    func select(_ selection: Selection?) -> Selection? {
        guard self.selection != selection else { return selection }
        self.selection = selection
        pendingStyle = Style()
        onChange?()
        return selection
    }

    // MARK: Text

    /// Retypes the selected block with `text` (and the pending style); an empty text deletes the block.
    func commitText(_ text: String) async throws {
        guard case .block(let index, let id)? = selection, let block = block() else { return }
        let style = pendingStyle
        let anchor = block.bounds
        let unchanged = text == block.text && style.isEmpty
        guard !unchanged else { return }
        let box = Box()
        let edit = Self.textEdit(text, style: style, block: block)
        let group = try await EditEngine.edit(document, name: text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? EditKitStrings.Undo.deleteText : EditKitStrings.Undo.editText) { model in
            guard let page = model.page(at: index) else { return }
            let content = try ContentInterpreter.read(page, hiddenLayers: OptionalContent.hiddenLayers(in: model))
            let pageText = PageText.analyze(page, content: content)
            guard let target = pageText.blocks.first(where: { $0.id == id }) else { throw TextRewriteError.notEditable }
            let outcome = try TextRewriter.replace(block: target, with: edit, in: pageText, page: page)
            box.substitution = outcome.substitution
            box.bounds = outcome.bounds
        }
        try await apply(group)
        if let s = box.substitution { lastSubstitution = s }
        pendingStyle = Style()
        selection = nil
        if !box.bounds.isNull, let reselected = pageText(index)?.block(at: CGPoint(x: box.bounds.minX + 2, y: box.bounds.maxY - 2)) {
            selection = .block(page: index, id: reselected.id)
        } else if let reselected = pageText(index)?.block(at: CGPoint(x: anchor.minX + 2, y: anchor.maxY - 2)), text.trimmingCharacters(in: .whitespaces).isEmpty == false {
            selection = .block(page: index, id: reselected.id)
        }
        onChange?()
    }

    private final class Box: @unchecked Sendable {
        var substitution: (from: String, to: String)?
        var bounds = CGRect.null
    }

    /// The edit for `text` with the style: a font on this Mac when the family, bold or italic changed.
    static func textEdit(_ text: String, style: Style, block: TextBlock) -> TextEdit {
        var edit = TextEdit(text: text, size: style.size, color: style.color, alignment: style.alignment)
        if style.fontFamily != nil || style.bold != nil || style.italic != nil {
            let facts = block.style.font.facts
            let family = style.fontFamily ?? FontMatcher.match(facts, size: 12).font.familyName ?? "Helvetica"
            edit.font = FontMatcher.installedFont(family: family, bold: style.bold ?? facts.isBold, italic: style.italic ?? facts.isItalic,
                                                  size: CGFloat(style.size ?? block.style.pageFontSize))
                ?? NSFont.systemFont(ofSize: CGFloat(style.size ?? block.style.pageFontSize))
        }
        return edit
    }

    /// Deletes the selected block or picture.
    func deleteSelection() async throws {
        switch selection {
        case .block: try await commitText("")
        case .image: try await editImage(name: EditKitStrings.Undo.deleteImage) { image, page, content in try ImageEditor.delete(image, page: page, content: content) }
        case nil: break
        }
    }

    /// A new block saying "Type here" at `point` (its top-left), selected for retyping.
    func addText(at point: CGPoint, page index: Int) async throws -> Selection? {
        let size = 12.0
        let width = max(120, min(300, (pageText(index)?.cropBox.maxX ?? 612) - point.x - 36))
        let origin = CGPoint(x: point.x, y: point.y - size)
        let box = Box()
        let group = try await EditEngine.edit(document, name: EditKitStrings.Undo.addText) { model in
            guard let page = model.page(at: index) else { return }
            let font = NSFont(name: "Helvetica", size: size) ?? NSFont.systemFont(ofSize: size)
            box.bounds = try TextRewriter.addTextBox(EditKitStrings.Edit.placeholderText, at: origin, width: width, font: font, size: size, color: "#000000", page: page)
        }
        try await apply(group)
        guard let block = pageText(index)?.block(at: CGPoint(x: box.bounds.minX + 2, y: box.bounds.midY)) else { return nil }
        return .block(page: index, id: block.id)
    }

    // MARK: Pictures

    func addImage(_ file: URL, at point: CGPoint, page index: Int) async throws {
        let crop = pageText(index)?.cropBox ?? CGRect(x: 0, y: 0, width: 612, height: 792)
        let width = crop.width * 0.4
        let rect = CGRect(x: min(point.x, crop.maxX - width), y: max(point.y - width, crop.minY), width: width, height: width)
        let group = try await EditEngine.edit(document, name: EditKitStrings.Undo.addImage) { model in
            guard let page = model.page(at: index) else { return }
            try ImageEditor.add(file, in: rect, page: page)
        }
        try await apply(group)
        onChange?()
    }

    func moveImage(to rect: CGRect) async throws {
        guard let image = image() else { return }
        let name = abs(rect.width - image.bounds.width) < 0.01 && abs(rect.height - image.bounds.height) < 0.01 ? EditKitStrings.Undo.moveImage : EditKitStrings.Undo.resizeImage
        try await editImage(name: name) { image, page, content in try ImageEditor.place(image, in: rect, page: page, content: content) }
    }

    func rotateImage(by degrees: Double) async throws {
        try await editImage(name: EditKitStrings.Undo.rotateImage) { image, page, content in try ImageEditor.rotate(image, by: degrees, page: page, content: content) }
    }

    func flipImage(horizontally: Bool = true) async throws {
        try await editImage(name: EditKitStrings.Undo.flipImage) { image, page, content in try ImageEditor.flip(image, horizontally: horizontally, page: page, content: content) }
    }

    func replaceImage(with file: URL) async throws {
        try await editImage(name: EditKitStrings.Undo.replaceImage) { image, page, content in try ImageEditor.replace(image, with: file, keepAspect: true, page: page, content: content) }
    }

    /// The selected picture's pixels as a file (PNG or JPEG) for editing elsewhere.
    func exportImage(to folder: URL) throws -> URL? {
        guard case .image(let index, let id)? = selection, let model = cache?.model, let page = model.page(at: index),
              let image = pageText(index)?.content.images.first(where: { $0.id == id }) else { return nil }
        let (data, type) = try ImageEditor.export(image, page: page)
        let url = folder.appendingPathComponent("Picture \(id + 1).\(type.preferredFilenameExtension ?? "png")")
        try data.write(to: url)
        return url
    }

    /// One picture edit, keeping the picture selected afterwards (found again by its centre).
    private func editImage(name: String, _ body: @escaping @Sendable (ImagePlacement, PDFModelKit.PDFPage, PageContent) throws -> Void) async throws {
        guard case .image(let index, let id)? = selection, let before = image() else { return }
        let centre = CGPoint(x: before.bounds.midX, y: before.bounds.midY)
        let group = try await EditEngine.edit(document, name: name) { model in
            guard let page = model.page(at: index) else { return }
            let content = try ContentInterpreter.read(page, hiddenLayers: OptionalContent.hiddenLayers(in: model))
            guard let image = content.images.first(where: { $0.id == id }) else { throw ImageEditError.notEditable }
            try body(image, page, content)
        }
        try await apply(group)
        selection = nil
        if name != EditKitStrings.Undo.deleteImage, let again = pageText(index)?.content.images.last(where: { $0.bounds.insetBy(dx: -4, dy: -4).contains(centre) || $0.id == id }) {
            selection = .image(page: index, id: again.id)
        }
        onChange?()
    }

    // MARK: Find & replace

    func replaceAll(_ find: String, with replacement: String, options: FindReplaceOptions, pages: [Int]) async throws -> ReplaceReport {
        guard let service = Services.edit else { return ReplaceReport(replaced: 0) }
        let (report, undo) = try await service.replaceText(find, with: replacement, options: options, pages: pages, in: document)
        if report.replaced > 0 { try await apply(undo) }
        if let first = report.substitutedFonts.first { lastSubstitution = (first.key, first.value) }
        selection = nil
        onChange?()
        return report
    }

    // MARK: Scripts (features #74)

    func removeScripts() async throws {
        guard let service = Services.edit else { return }
        try await apply(try await service.removeScripts(from: document))
        onChange?()
    }
}
