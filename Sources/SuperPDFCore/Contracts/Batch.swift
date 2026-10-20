import Foundation

// "Do this to many files" (BatchKit: `Services.batch`; features #75): pipelines of file-level tools over the tool
// registry, saved as routines; Finder Quick Actions and App Intents run the same pipelines.

/// One tool with its panel values.
public struct BatchStep: Codable, Hashable, Sendable {
    public var tool: ToolID
    public var values: ToolValues

    public init(tool: ToolID, values: ToolValues = ToolValues()) { self.tool = tool; self.values = values }
}

/// Tools run in order on each file; each step's output feeds the next.
public struct BatchPipeline: Codable, Hashable, Sendable {
    public var steps: [BatchStep]
    /// Where results go; nil writes next to each original.
    public var outputFolder: URL?

    public init(steps: [BatchStep], outputFolder: URL? = nil) { self.steps = steps; self.outputFolder = outputFolder }
}

/// A saved pipeline ("OCR, compress, PDF/A"), `Routines/<id>.json`.
public struct Routine: Codable, Hashable, Identifiable, Sendable {
    public var id: UUID
    public var name: String
    public var pipeline: BatchPipeline
    public var created: Date

    public init(id: UUID = UUID(), name: String, pipeline: BatchPipeline, created: Date = Date()) {
        self.id = id; self.name = name; self.pipeline = pipeline; self.created = created
    }
}

/// Progress of a batch, per file (the progress list).
public enum BatchEvent: Hashable, Sendable {
    case started(URL)
    case step(URL, tool: ToolID, ToolProgress.Update)
    case finished(URL, outputs: [URL])
    case failed(URL, message: String)
}

@MainActor
public protocol BatchRunning: AnyObject {
    var routines: [Routine] { get }
    func save(_ routine: Routine) throws
    func delete(_ routineID: UUID) throws
    /// Runs the pipeline on every PDF in `files` (folders expanded; other types converted first).
    func run(_ pipeline: BatchPipeline, on files: [URL]) -> AsyncThrowingStream<BatchEvent, Error>
}
