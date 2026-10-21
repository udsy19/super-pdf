import Foundation
import SuperPDFCore

/// BatchKit: "Do this to many files" (features #75; docs/ARCHITECTURE.md, WP16): pipelines of file-level tools over
/// files and folders, saved routines, and the tile's panel. It registers `Services.batch` (`BatchRunning`) and appends
/// its `ToolProviding` for `ToolCatalog.tiles(ownedBy: .batchKit)` to `Services.toolProviders`. Finder's Quick Actions
/// reach it through the app's `superpdf://` routes (`AppRoute`).
@MainActor
public enum BatchKitModule {
    private static var provider: BatchTools?

    /// `environment` replaces the panel's menus, prompts and Finder (the self-test's).
    public static func install(environment: BatchEnvironment? = nil) {
        let runner = BatchRunner(folder: SuperPDFPaths.routines)
        let tools = BatchTools(runner: runner)
        if let environment { tools.environment = environment }
        provider = tools
        Services.batch = runner
        Services.toolProviders.append(tools)
    }

    /// "Do this to many files" with `steps` and `files` already in it: a Quick Action or link that asks a document tool
    /// of several files.
    public static func openManyFiles(steps: [ToolID], files: [URL]) {
        provider?.open(steps: steps, files: files)
    }

    /// Whether a pipeline can run `tool` (file-level and fine with its panel's defaults).
    public static func canRun(_ tool: ToolID) -> Bool { BatchTools.runnable.contains(tool) }
}
