import SuperPDFCore

/// RenderKit: Quartz rendering and writing (shared analysis module, no app policy; docs/ARCHITECTURE.md, features §1.4,
/// #32–33, #53, #56–58, #95–96). `install()` registers `Services.render` and nothing else. Every job opens its own
/// `CGPDFDocument` from the source bytes off the main actor and hands back values or files; thumbnails and view tiles
/// go through `PageImageCache`, which renders off the main actor with bounded concurrency and a byte-limited cache.
public enum RenderKitModule {
    @MainActor public static func install() {
        Services.render = RenderService()
    }
}
