import SuperPDFCore

/// LayoutKit: text and layout analysis (shared analysis module, no app policy; docs/ARCHITECTURE.md, features §2.4).
/// `install()` registers `Services.layout` and nothing else: analysis happens only when a tool asks for it, page by
/// page, and the results are cached per document fingerprint so a second tool on the same file pays nothing.
///
/// Pipeline (`LayoutAnalyzer`): words (PDFKit character bounds or Vision OCR) → lines → tables (ruling lines and
/// alignment grids) → figures (image XObjects, vector clusters) → paragraphs → headers, footers, page numbers,
/// headings, lists, captions → column-aware reading order (recursive XY cut).
public enum LayoutKitModule {
    @MainActor public static func install() {
        Services.layout = LayoutService()
    }
}
