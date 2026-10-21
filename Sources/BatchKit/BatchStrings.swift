import SuperPDFCore

// BatchKit's copy (ux §1.1 tone; ux §5.3 "Do this to many files").
enum BatchStrings {
    static let stepsNote = "Add the tools to run, in order. Each one works on what the one before made."
    static let addTool = "Add a tool…"
    static let filesLabel = "Drop files or a folder here"
    static let useRoutine = "Use a routine…"
    static let saveRoutine = "Save as routine…"
    static let chooseFolder = "Save results in a folder…"
    static let nextToOriginals = "Save results next to each file"
    static let resultsNextToOriginals = "Results are saved next to each file. The files themselves aren’t changed."
    static func resultsIn(_ folder: String) -> String { "Results are saved in \(Strings.quoted(folder)). The files themselves aren’t changed." }
    static let needsSteps = "Add a tool to run."
    static let needsFiles = "Add the files to run it on."
    static func mustBeLast(_ tool: String) -> String { "\(Strings.quoted(tool)) makes other kinds of files, so it has to be the last step." }
    static func run(_ count: Int) -> String { count == 1 ? "Run on 1 file" : "Run on \(count) files" }
    static let run = "Run"
    static func progress(file: String, tool: String) -> String { "\(tool): \(file)" }
    static let routineNamePrompt = "Name this routine"
    static let routineNameInfo = "It shows up under “Use a routine…” the next time."
    static let routineNamePlaceholder = "Archive scans"
    static let save = "Save"
    static let cancel = "Cancel"
    static let deleteRoutine = "Delete Routine"
    static func step(_ number: Int, _ tool: String) -> String { "\(number). \(tool)" }
    static func cantRun(_ tool: String, reason: String?) -> String {
        reason.map { "\(Strings.quoted(tool)) couldn’t run: \($0)" } ?? "\(Strings.quoted(tool)) can’t run on its own here."
    }
    static func locked(_ file: String) -> String { "\(Strings.quoted(file)) needs a password. Remove it first, then try again." }
    static let somethingWentWrong = "Something went wrong. The file wasn’t changed."
    static func someFailed(done: Int, total: Int, first: String, reason: String) -> String {
        "Done \(done) of \(total) files. \(Strings.quoted(first)): \(reason)"
    }
}
