import CoreGraphics
import Foundation
import PDFKit
import SuperPDFCore

public enum LayoutError: Error, Equatable {
    case cannotOpen
    case locked
    case noSuchPage(Int)
}

/// `Services.layout`. Lazy and cheap: nothing runs at install; `analyze` touches only the pages asked for, reads
/// PDFKit's words on the main actor page by page (yielding between pages), then does the content-stream scan, OCR and
/// analysis off the main actor. Results are cached per document fingerprint, page and options, so a second tool on the
/// same file gets its pages back without work.
@MainActor
public final class LayoutService: LayoutAnalyzing {
    private let cache = LayoutCache()

    public func analyze(_ source: PDFSource, pages: [Int]?, options: LayoutOptions) async throws -> LayoutDocument {
        let data = try source.bytes()
        let fingerprint = await Task.detached(priority: .userInitiated) { source.fingerprint() }.value
        guard let pdf = PDFDocument(data: data) else { throw LayoutError.cannotOpen }
        if pdf.isLocked {
            guard let password = source.password, pdf.unlock(withPassword: password) else { throw LayoutError.locked }
        }
        let indices = pages ?? Array(0..<pdf.pageCount)
        var cached: [Int: LayoutPage] = [:]
        var inputs: [PageInput] = []
        for index in indices {
            if let hit = cache.page(fingerprint, index: index, options: options) { cached[index] = hit; continue }
            guard let page = pdf.page(at: index) else { throw LayoutError.noSuchPage(index) }
            let words = options.recognition == .always ? [] : TextExtractor.words(on: page)
            inputs.append(PageInput(index: index, size: page.bounds(for: .cropBox).size, rotation: page.rotation, words: words))
            await Task.yield()
        }
        if !inputs.isEmpty {
            let password = source.password
            let analysed = try await Task.detached(priority: .userInitiated) {
                try Self.analyze(inputs, data: data, password: password, options: options)
            }.value
            for page in analysed { cache.store(page, fingerprint: fingerprint, options: options); cached[page.index] = page }
        }
        return LayoutDocument(pages: indices.compactMap { cached[$0] })
    }

    public func analyze(recognized lines: [RecognizedLine], pageIndex: Int, pageSize: CGSize, options: LayoutOptions) async -> LayoutPage {
        let input = PageInput(index: pageIndex, size: pageSize, origin: .recognized, words: TextRecognizer.words(from: lines))
        return await Task.detached(priority: .userInitiated) { LayoutAnalyzer.analyze(input, options: options) }.value
    }

    /// Off the main actor: page graphics, OCR where the policy asks, then the analysis.
    nonisolated static func analyze(_ inputs: [PageInput], data: Data, password: String?, options: LayoutOptions) throws -> [LayoutPage] {
        var inputs = inputs
        guard let provider = CGDataProvider(data: data as CFData), let document = CGPDFDocument(provider) else { throw LayoutError.cannotOpen }
        if document.isEncrypted, !document.isUnlocked {
            guard let password, document.unlockWithPassword(password) else { throw LayoutError.locked }
        }
        let customWords = options.recognition == .always ? [] : Array(Set(inputs.flatMap { $0.words.map(\.text) }.filter { $0.count >= 4 && $0.allSatisfy(\.isLetter) }).prefix(2000))
        for index in inputs.indices {
            guard let page = document.page(at: inputs[index].index + 1) else { throw LayoutError.noSuchPage(inputs[index].index) }
            inputs[index].graphics = PageGraphicsScanner.scan(page)
            let needsOCR: Bool
            switch options.recognition {
            case .never: needsOCR = false
            case .always: needsOCR = true
            case .whenPageHasNoText: needsOCR = !inputs[index].words.contains { !$0.text.trimmingCharacters(in: .whitespaces).isEmpty }
            }
            if needsOCR, let image = TextRecognizer.image(for: page) {
                let lines = try TextRecognizer.recognize(image, pageSize: inputs[index].size, rotation: inputs[index].rotation, languages: options.languages, customWords: customWords)
                inputs[index].words = TextRecognizer.words(from: lines)
                inputs[index].origin = .recognized
                inputs[index].graphics = .empty   // the scan's own image is the page, not a figure
            }
        }
        return LayoutAnalyzer.analyze(inputs, options: options)
    }
}

/// Analysed pages by document fingerprint, page index and options; bounded by page count (an analysed page is a few
/// kilobytes).
@MainActor
final class LayoutCache {
    private final class Box { let page: LayoutPage; init(_ page: LayoutPage) { self.page = page } }
    private let store = NSCache<NSString, Box>()

    init(pageLimit: Int = 600) { store.countLimit = pageLimit }

    private func key(_ fingerprint: String, _ index: Int, _ options: LayoutOptions) -> NSString {
        "\(fingerprint)/\(index)/\(options.recognition.rawValue)/\(options.languages.joined(separator: ","))/\(options.detectTables)/\(options.excludeHeadersAndFooters)" as NSString
    }

    func page(_ fingerprint: String, index: Int, options: LayoutOptions) -> LayoutPage? { store.object(forKey: key(fingerprint, index, options))?.page }

    func store(_ page: LayoutPage, fingerprint: String, options: LayoutOptions) { store.setObject(Box(page), forKey: key(fingerprint, page.index, options)) }
}
