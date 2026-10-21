import Foundation
import PDFModelKit
import RenderKit
import SuperPDFCore

/// `Services.fix` (features #91–#100, #13, #120): every call opens its own copy of the bytes off the main actor and
/// hands back values or writes the destination. Accessibility and Compare first ask `Services.layout` for the text
/// layout (LayoutKit works off the main actor and caches per document).
@MainActor
public final class FixService: Fixing {
    public init() {}

    private static func detached<T: Sendable>(_ work: @escaping @Sendable () throws -> T) async throws -> T {
        try await Task.detached(priority: .userInitiated, operation: work).value
    }

    // MARK: Optimizing

    public func estimate(_ source: PDFSource, options: OptimizeOptions) async throws -> Int64 {
        try await estimates(source, options: [options])[0]
    }

    /// Several presets at once on the same sample, side by side.
    func estimates(_ source: PDFSource, options: [OptimizeOptions]) async throws -> [Int64] {
        try await Self.detached { try Optimizer.estimate(source, options: options) }
    }

    public func optimize(_ source: PDFSource, options: OptimizeOptions, to destination: URL, progress: ToolProgress) async throws {
        let data = try await Self.detached {
            try Optimizer.optimize(source, options: options) { done, total in progress.report(completed: done, of: total, page: done - 1) }
        }
        try data.write(to: destination, options: .atomic)
    }

    public func audit(_ source: PDFSource) async throws -> SpaceAudit {
        try await Self.detached { try Optimizer.audit(source) }
    }

    // MARK: OCRing

    public func pagesWithoutText(in document: DocumentHandle) -> [Int] {
        (0..<document.pageCount).filter { index in
            (document.pdf.page(at: index)?.string ?? "").trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        }
    }

    public func recognize(_ source: PDFSource, pages: [Int], options: OCROptions, progress: ToolProgress) async throws -> OCRReport {
        let result = try await Self.detached {
            try Recognizer.recognize(source, pages: pages, options: options) { done, total, page in
                progress.report(completed: done, of: total, page: page)
            }
        }
        return OCRReport(data: result.data, recognizedPages: result.recognizedPages, emptyPages: result.emptyPages)
    }

    // MARK: Checking

    public func check(_ source: PDFSource, profile: CheckProfile, progress: ToolProgress) async throws -> [CheckIssue] {
        switch profile {
        case .accessibility:
            return try await accessibilityReport(source, progress: progress).issues
        case .printing:
            return try await Self.detached {
                let data = try source.bytes()
                return Checker.printing(try PDFModel(data: data, password: source.password), data: data, password: source.password)
            }
        case .pdfA(let level):
            return try await Self.detached { Checker.pdfA(try PDFModel(source), level: level) }
        }
    }

    /// The accessibility checks with the pictures that can take a description and the language a fix would set.
    func accessibilityReport(_ source: PDFSource, progress: ToolProgress = .ignored) async throws -> Checker.AccessibilityReport {
        let layout = try await self.layout(source, pageLimit: 200)
        return try await Self.detached { Checker.accessibility(try PDFModel(source), layout: layout) }
    }

    public func fix(_ issueIDs: [String], in source: PDFSource, profile: CheckProfile, to destination: URL) async throws {
        switch profile {
        case .accessibility:
            try await fixAccessibility(Set(issueIDs), in: source, descriptions: [:], to: destination)
        case .printing:
            try await fixPrinting(Set(issueIDs), in: source, printerMarks: false, title: Repairer.fileName(of: source) ?? "", to: destination)
        case .pdfA(let level):
            // "Fix" runs the conversion (features #93 → #56).
            try await Services.render.writePDFA(source, level: level, to: destination)
        }
    }

    /// Accessibility fixes plus picture descriptions (by `FigureRef.key`) into `destination`.
    func fixAccessibility(_ ids: Set<String>, in source: PDFSource, descriptions: [String: String], to destination: URL) async throws {
        let layout = try await self.layout(source, pageLimit: nil) ?? LayoutDocument(pages: [])
        let name = Repairer.fileName(of: source)
        let data = try await Self.detached {
            let model = try PDFModel(source)
            try Checker.fixAccessibility(ids, model: model, layout: layout, fileName: name, descriptions: descriptions)
            return try model.data()
        }
        try data.write(to: destination, options: .atomic)
    }

    /// Print fixes (fonts, hairlines, printer marks; colours and transparency through RenderKit last) into `destination`.
    func fixPrinting(_ ids: Set<String>, in source: PDFSource, printerMarks: Bool, title: String, to destination: URL) async throws {
        let data = try await Self.detached {
            let model = try PDFModel(source)
            if ids.contains("fonts") { _ = Fonts.embedMissing(in: model) }
            if ids.contains("hairlines") { PrintProduction.thickenHairlines(in: model) }
            if printerMarks { PrintProduction.addPrinterMarks(to: model, title: title) }
            return try model.data()
        }
        let convert = ids.contains("rgb"), flatten = ids.contains("transparency")
        guard convert || flatten, let render = Services.render else {
            try data.write(to: destination, options: .atomic)
            return
        }
        try await render.convertColors(.data(data, password: source.password), to: convert ? .cmyk : .sRGB, profile: nil,
                                       flattenTransparencyAt: 300, to: destination)
    }

    // MARK: Repairing

    public func diagnose(_ url: URL) async -> RepairDiagnosis? {
        try? await Self.detached {
            guard let data = try? Data(contentsOf: url, options: .mappedIfSafe) else { return nil }
            return Repairer.diagnose(data)
        }
    }

    public func repair(_ source: PDFSource, embedFonts: Bool, to destination: URL) async throws -> RepairDiagnosis {
        let (data, diagnosis) = try await Self.detached { try Repairer.repair(source, embedFonts: embedFonts) }
        try data.write(to: destination, options: .atomic)
        return diagnosis
    }

    public func linearize(_ source: PDFSource, to destination: URL) async throws {
        let data = try await Self.detached { try Repairer.linearize(source) }
        try data.write(to: destination, options: .atomic)
    }

    // MARK: Compare

    public func compare(_ old: PDFSource, with new: PDFSource, textOnly: Bool, progress: ToolProgress) async throws -> [ComparisonChange] {
        try await locatedChanges(old, new, textOnly: textOnly, progress: progress).map(\.change)
    }

    /// The changes with their places on both versions.
    func locatedChanges(_ old: PDFSource, _ new: PDFSource, textOnly: Bool, progress: ToolProgress = .ignored) async throws -> [LocatedChange] {
        progress.report(completed: 0, of: 3)
        let oldLayout = try await layout(old, pageLimit: nil) ?? LayoutDocument(pages: [])
        progress.report(completed: 1, of: 3)
        let newLayout = try await layout(new, pageLimit: nil) ?? LayoutDocument(pages: [])
        progress.report(completed: 2, of: 3)
        let changes = try await Self.detached { () -> [LocatedChange] in
            let oldWords = Comparer.words(oldLayout), newWords = Comparer.words(newLayout)
            var changes = Comparer.textChanges(old: oldWords, new: newWords)
            if !textOnly { changes += try Comparer.visualChanges(old: old, new: new, oldWords: oldWords, newWords: newWords) }
            return changes.sorted { ($0.change.newPage ?? 0, $0.newBoxes.first.map { -$0.maxY } ?? 0) < ($1.change.newPage ?? 0, $1.newBoxes.first.map { -$0.maxY } ?? 0) }
        }
        progress.report(completed: 3, of: 3)
        return changes
    }

    // MARK: Layout

    /// LayoutKit's analysis of the first `pageLimit` pages (all when nil), without OCR; nil when no layout service is
    /// installed.
    private func layout(_ source: PDFSource, pageLimit: Int?) async throws -> LayoutDocument? {
        guard let layout = Services.layout else { return nil }
        var pages: [Int]?
        if let pageLimit {
            let count = try await Self.detached { try PDFModel(source).pageCount }
            pages = Array(0..<min(count, pageLimit))
        }
        return try await layout.analyze(source, pages: pages, options: LayoutOptions(recognition: .never))
    }
}
