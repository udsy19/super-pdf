import AppKit
import SuperPDFCore

// Headless checks (the Command Line Tools have no XCTest). Run: swift run SuperPDFSelfTest
//
// Rules for every module's cases: files and settings live in the throwaway places set up below, never the real
// Application Support folder or preferences; nothing touches the network unless a case says so and skips cleanly when
// offline; and no case ever opens, launches or activates another app or a URL (NSWorkspace.open, Apple Events,
// LaunchServices) — inject a fake opener instead.
setvbuf(stdout, nil, _IOLBF, 0)   // results stay in order with the engines' stderr logs, and survive a crash
nonisolated(unsafe) var failures = 0
func check(_ cond: @autoclosure () -> Bool, _ msg: String, file: String = #fileID, line: Int = #line) {
    if !cond() { failures += 1; print("✗ \(file):\(line) \(msg)") }
}
enum SelfTest { nonisolated(unsafe) static var cases: [(String, @MainActor () -> Void)] = [] }

/// Runs async work to completion while the main run loop keeps turning.
@MainActor
func complete<T>(_ seconds: TimeInterval = 300, _ work: @escaping @MainActor () async throws -> T) -> Result<T, Error>? {
    var result: Result<T, Error>?
    Task { @MainActor in
        do { result = .success(try await work()) } catch { result = .failure(error) }
    }
    let deadline = Date().addingTimeInterval(seconds)
    while result == nil && Date() < deadline { RunLoop.main.run(until: Date().addingTimeInterval(0.01)) }
    return result
}

let scratch = FileManager.default.temporaryDirectory.appendingPathComponent("superpdf-selftest-\(UUID().uuidString)")
SuperPDFPaths.base = scratch.appendingPathComponent("Application Support")
let defaultsSuite = "superpdf-selftest-\(UUID().uuidString)"
Defaults.store = UserDefaults(suiteName: defaultsSuite)!

// Each module owns Sources/SuperPDFSelfTest/<Module>Tests.swift and its register function.
registerCoreTests()
registerDocumentKitTests()
registerLayoutKitTests()
registerRenderKitTests()
registerPagesKitTests()
registerConvertKitTests()
registerEditKitTests()
registerMarkupKitTests()
registerFormsKitTests()
registerSignKitTests()
registerProtectKitTests()
registerFixKitTests()
registerScanKitTests()
registerBatchKitTests()
registerToolsKitTests()
registerViewerKitTests()
registerSettingsKitTests()
registerPDFModelKitTests()
registerUpdateKitTests()
registerAppTests()

// `SUPERPDF_SELFTEST_ONLY=Core.,PagesKit.split` runs only the cases whose names start with one of the prefixes.
let only = ProcessInfo.processInfo.environment["SUPERPDF_SELFTEST_ONLY"]?.split(separator: ",").map(String.init) ?? []
MainActor.assumeIsolated {
    for (name, run) in SelfTest.cases where only.isEmpty || only.contains(where: name.hasPrefix) {
        let before = failures; run()
        print(failures == before ? "✓ \(name)" : "✗ \(name)")
    }
}
try? FileManager.default.removeItem(at: scratch)
UserDefaults.standard.removePersistentDomain(forName: defaultsSuite)
// cfprefsd leaves the emptied domain behind as a plist named after this run's suite; remove exactly that file.
CFPreferencesAppSynchronize(defaultsSuite as CFString)
try? FileManager.default.removeItem(at: FileManager.default.urls(for: .libraryDirectory, in: .userDomainMask)[0]
    .appendingPathComponent("Preferences/\(defaultsSuite).plist"))
print(failures == 0 ? "All self-tests passed." : "\(failures) failure(s).")
exit(failures == 0 ? 0 : 1)
