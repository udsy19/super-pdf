import CoreGraphics
import Foundation
import PDFModelKit
import SuperPDFCore

// Repair (features #98) and Fast web view (#99): QPDF reads the file with recovery (cross-reference rebuilt, objects
// found by scanning), every page's content is read and content that can't be decoded is dropped, missing fonts are
// embedded on request (#100), and the whole file is written again. The result must open strictly (no recovery) and in
// Quartz with its pages, or the repair fails with a plain message.

enum Repairer {
    /// Problems found, in the words the Repair panel and DocumentKit show ("The file’s index is damaged.").
    enum Problem: String, CaseIterable {
        case index, content, truncated

        var sentence: String {
            switch self {
            case .index: FixStrings.Repair.indexDamaged
            case .content: FixStrings.Repair.contentDamaged
            case .truncated: FixStrings.Repair.truncated
            }
        }
    }

    /// What's wrong with a file, without changing it; nil when it isn't a PDF that can be read at all.
    static func diagnose(_ data: Data, password: String? = nil) -> RepairDiagnosis? {
        guard data.prefix(1024).range(of: Data("%PDF-".utf8)) != nil else { return nil }
        var problems: Set<Problem> = []
        if !endsWithEOF(data) { problems.insert(.truncated) }
        let model: PDFModel
        do {
            let strict = try PDFModel(data: data, password: password, attemptRecovery: false)
            problems.formUnion(classify(strict.check()))
            model = strict
        } catch PDFModelError.passwordRequired {
            return RepairDiagnosis(problems: problems.isEmpty ? [] : order(problems))
        } catch PDFModelError.wrongPassword {
            return RepairDiagnosis(problems: problems.isEmpty ? [] : order(problems))
        } catch {
            problems.insert(.index)
            guard let recovered = try? PDFModel(data: data, password: password, attemptRecovery: true) else { return nil }
            problems.formUnion(classify(recovered.warnings))
            model = recovered
        }
        return RepairDiagnosis(problems: order(problems), missingFonts: Fonts.notEmbedded(in: model).map(\.name))
    }

    /// The repaired file's bytes and what was fixed; throws `ToolError` with the plain message when the file can't be
    /// recovered.
    static func repair(_ source: PDFSource, embedFonts: Bool) throws -> (data: Data, diagnosis: RepairDiagnosis) {
        let name = fileName(of: source)
        let data: Data
        do { data = try source.bytes() } catch { throw ToolError(FixStrings.Repair.failed(name)) }
        let model: PDFModel
        do {
            model = try PDFModel(data: data, password: source.password, attemptRecovery: true)
        } catch PDFModelError.passwordRequired {
            throw ToolError(FixStrings.Repair.needsPassword(name))
        } catch {
            throw ToolError(FixStrings.Repair.failed(name), details: String(describing: error))
        }
        guard model.pageCount > 0 else { throw ToolError(FixStrings.Repair.failed(name), details: "no pages") }
        var problems = classify(model.warnings)
        if !endsWithEOF(data) { problems.insert(.truncated) }
        if model.wasRepaired { problems.insert(.index) }
        // Content that can't be decoded is dropped, so the page opens (blank where it was lost).
        for page in model.pages {
            do { _ = try page.contentData() } catch {
                page.setContentData(Data())
                problems.insert(.content)
            }
        }
        problems.formUnion(classify(model.check()))
        // A file cut short has no trailer: recovery's stand-in lacks /Size, which the writer copies (it fills the value).
        if model.trailer["Size"] == nil { model.trailer.set("Size", .integer(1)) }
        var missing = Fonts.notEmbedded(in: model).map(\.name)
        if embedFonts { missing = Fonts.embedMissing(in: model).missing }
        let out: Data
        do { out = try model.data(options: PDFWriteOptions(objectStreams: .preserve, compressStreams: true)) } catch {
            throw ToolError(FixStrings.Repair.failed(name), details: String(describing: error))
        }
        guard opensCleanly(out, password: source.password, pages: model.pageCount) else {
            throw ToolError(FixStrings.Repair.failed(name), details: "the rewritten file doesn’t open")
        }
        return (out, RepairDiagnosis(problems: order(problems), missingFonts: missing))
    }

    /// Fast web view (features #99): the same file, linearized.
    static func linearize(_ source: PDFSource) throws -> Data {
        let model = try PDFModel(source)
        return try model.data(options: PDFWriteOptions(linearize: true))
    }

    // MARK: Helpers

    /// Opens without recovery, with all its pages, and in Quartz.
    static func opensCleanly(_ data: Data, password: String?, pages: Int) -> Bool {
        guard let strict = try? PDFModel(data: data, password: password, attemptRecovery: false), strict.pageCount == pages,
              let provider = CGDataProvider(data: data as CFData), let document = CGPDFDocument(provider) else { return false }
        if document.isEncrypted, !document.isUnlocked, !document.unlockWithPassword(password ?? "") { return false }
        return document.numberOfPages == pages
    }

    static func fileName(of source: PDFSource) -> String? {
        if case .file(let url, _) = source { return url.lastPathComponent }
        return nil
    }

    private static func endsWithEOF(_ data: Data) -> Bool {
        data.suffix(1024).range(of: Data("%%EOF".utf8)) != nil
    }

    private static func classify(_ warnings: [String]) -> Set<Problem> {
        var problems: Set<Problem> = []
        for warning in warnings.map({ $0.lowercased() }) {
            if ["xref", "trailer", "reconstruct", "startxref", "object stream", "expected n n obj", "offset"].contains(where: warning.contains) {
                problems.insert(.index)
            } else if ["stream", "inflate", "decod", "content", "zlib", "eof"].contains(where: warning.contains) {
                problems.insert(.content)
            } else {
                problems.insert(.index)
            }
        }
        return problems
    }

    private static func order(_ problems: Set<Problem>) -> [String] {
        Problem.allCases.filter(problems.contains).map(\.sentence)
    }
}
