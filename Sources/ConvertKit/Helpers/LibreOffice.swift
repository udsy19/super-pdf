import Darwin
import Foundation

// The LibreOffice helper (features §3.2): never bundled, downloaded or installed by Super PDF. An installed copy is found
// (Settings override, /Applications, ~/Applications, Homebrew) and run headless with a private profile, no restore, no
// logo, a time limit and one job at a time. It converts only what the built-in converters can't (.xls, .ppt, .ods, .odp,
// .hwp) or what a person asks it to ("Try with LibreOffice").

/// How a helper process (LibreOffice, an app's export script) failed.
enum HelperFailure: Error, Equatable {
    case timedOut
    case failed(status: Int32, output: String)
    /// It finished but wrote nothing.
    case noOutput
}

enum LibreOffice {
    /// The page "Get LibreOffice" opens.
    static let downloadPage = URL(string: "https://www.libreoffice.org/download/download-libreoffice/")!
    /// features §3.2: a 120 s limit per file.
    static let timeout: TimeInterval = 120

    struct Installation: Hashable, Sendable {
        /// The executable that runs headless (`…/LibreOffice.app/Contents/MacOS/soffice` or a Homebrew `soffice`).
        var soffice: URL
        var version: String?
    }

    /// Where LibreOffice is usually installed, in the order looked at after the Settings override.
    static func candidates(home: URL = FileManager.default.homeDirectoryForCurrentUser) -> [URL] {
        [URL(fileURLWithPath: "/Applications/LibreOffice.app"),
         home.appendingPathComponent("Applications/LibreOffice.app"),
         URL(fileURLWithPath: "/opt/homebrew/bin/soffice"),
         URL(fileURLWithPath: "/usr/local/bin/soffice")]
    }

    /// The first usable installation: `override` (an app bundle or an `soffice` executable) when set, else the usual
    /// places. Only looks at the file system; nothing is launched.
    static func detect(override: URL?, candidates: [URL] = candidates()) -> Installation? {
        for candidate in (override.map { [$0] } ?? []) + candidates {
            if let installation = installation(at: candidate) { return installation }
        }
        return nil
    }

    static func installation(at url: URL) -> Installation? {
        let fm = FileManager.default
        if url.pathExtension == "app" {
            let soffice = url.appendingPathComponent("Contents/MacOS/soffice")
            guard fm.isExecutableFile(atPath: soffice.path) else { return nil }
            let info = NSDictionary(contentsOf: url.appendingPathComponent("Contents/Info.plist"))
            return Installation(soffice: soffice, version: info?["CFBundleShortVersionString"] as? String)
        }
        guard fm.isExecutableFile(atPath: url.path) else { return nil }
        // A Homebrew wrapper or link: report the app's version when it leads into one.
        let resolved = url.resolvingSymlinksInPath()
        var version: String?
        if let range = resolved.path.range(of: ".app/") {
            let app = URL(fileURLWithPath: String(resolved.path[..<range.upperBound].dropLast()))
            version = (NSDictionary(contentsOf: app.appendingPathComponent("Contents/Info.plist"))?["CFBundleShortVersionString"] as? String)
        } else if let script = try? String(contentsOf: resolved, encoding: .utf8), script.hasPrefix("#!"),
                  let match = script.range(of: #"/[^"\s]*LibreOffice[^"\s]*\.app"#, options: .regularExpression) {
            let app = URL(fileURLWithPath: String(script[match]))
            version = (NSDictionary(contentsOf: app.appendingPathComponent("Contents/Info.plist"))?["CFBundleShortVersionString"] as? String)
        }
        return Installation(soffice: url, version: version)
    }

    /// The command line of one conversion (features §3.2): headless, private profile, no restore, no logo.
    static func arguments(input: URL, format: String, outputFolder: URL, profile: URL) -> [String] {
        ["-env:UserInstallation=\(profile.absoluteURL.absoluteString)", "--headless", "--invisible", "--nocrashreport", "--nodefault",
         "--nofirststartwizard", "--nolockcheck", "--nologo", "--norestore", "--convert-to", format, "--outdir", outputFolder.path, input.path]
    }

    /// Converts `input` to PDF with `installation`, writing into `outputFolder`; returns the file LibreOffice wrote.
    static func convert(_ input: URL, with installation: Installation, profile: URL, outputFolder: URL,
                        timeout: TimeInterval = timeout) async throws -> URL {
        prepareProfile(profile)
        try FileManager.default.createDirectory(at: outputFolder, withIntermediateDirectories: true)
        let args = arguments(input: input, format: "pdf", outputFolder: outputFolder, profile: profile)
        try await Queue.shared.run(installation.soffice, arguments: args, timeout: timeout)
        let expected = outputFolder.appendingPathComponent(input.deletingPathExtension().lastPathComponent + ".pdf")
        if FileManager.default.fileExists(atPath: expected.path) { return expected }
        let any = (try? FileManager.default.contentsOfDirectory(at: outputFolder, includingPropertiesForKeys: nil))?.first { $0.pathExtension == "pdf" }
        guard let any else { throw HelperFailure.noOutput }
        return any
    }

    /// A fresh profile turns off the update check and first-start tasks, so a run never reaches the network.
    static func prepareProfile(_ profile: URL) {
        let user = profile.appendingPathComponent("user", isDirectory: true)
        let file = user.appendingPathComponent("registrymodifications.xcu")
        guard !FileManager.default.fileExists(atPath: file.path) else { return }
        try? FileManager.default.createDirectory(at: user, withIntermediateDirectories: true)
        let items = [
            #"<item oor:path="/org.openoffice.Office.Jobs/Jobs/org.openoffice.Office.Jobs:Job['UpdateCheck']/Arguments"><prop oor:name="AutoCheckEnabled" oor:op="fuse"><value>false</value></prop></item>"#,
            #"<item oor:path="/org.openoffice.Office.Common/Misc"><prop oor:name="FirstRun" oor:op="fuse"><value>false</value></prop></item>"#,
            #"<item oor:path="/org.openoffice.Office.Common/Misc"><prop oor:name="ShowTipOfTheDay" oor:op="fuse"><value>false</value></prop></item>"#,
            #"<item oor:path="/org.openoffice.Office.Common/Security/Scripting"><prop oor:name="MacroSecurityLevel" oor:op="fuse"><value>3</value></prop></item>"#,
        ]
        let xml = #"<?xml version="1.0" encoding="UTF-8"?>"# + "\n"
            + #"<oor:items xmlns:oor="http://openoffice.org/2001/registry" xmlns:xs="http://www.w3.org/2001/XMLSchema" xmlns:xsi="http://www.w3.org/2001/XMLSchema-instance">"#
            + "\n" + items.joined(separator: "\n") + "\n</oor:items>\n"
        try? xml.write(to: file, atomically: true, encoding: .utf8)
    }

    /// One LibreOffice process at a time (features §3.2). A run past its time limit, or a cancelled one, is ended by its
    /// own process id — never by name.
    actor Queue {
        static let shared = Queue()
        private var busy = false
        private var waiting: [CheckedContinuation<Void, Never>] = []

        func run(_ executable: URL, arguments: [String], timeout: TimeInterval) async throws {
            await acquire()
            defer { release() }
            try Task.checkCancellation()
            try await ProcessRunner.run(executable, arguments: arguments, timeout: timeout)
        }

        private func acquire() async {
            if !busy { busy = true; return }
            await withCheckedContinuation { waiting.append($0) }
        }

        private func release() {
            if waiting.isEmpty { busy = false } else { waiting.removeFirst().resume() }
        }
    }
}

/// Runs a child process with a time limit; stops exactly that process (SIGTERM, then SIGKILL) when the limit passes or
/// the task is cancelled. Output is kept for "Show details".
enum ProcessRunner {
    /// Returns what the process printed (kept to 64 KB).
    @discardableResult
    static func run(_ executable: URL, arguments: [String], timeout: TimeInterval) async throws -> String {
        let process = Process()
        process.executableURL = executable
        process.arguments = arguments
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = pipe
        process.standardInput = FileHandle.nullDevice
        let collector = OutputCollector()
        pipe.fileHandleForReading.readabilityHandler = { handle in collector.append(handle.availableData) }

        let finished = Flag()
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
                process.terminationHandler = { _ in
                    finished.set()
                    continuation.resume()
                }
                do { try process.run() } catch {
                    process.terminationHandler = nil
                    continuation.resume(throwing: error)
                    return
                }
                let pid = process.processIdentifier
                DispatchQueue.global().asyncAfter(deadline: .now() + timeout) {
                    guard !finished.isSet else { return }
                    collector.timedOut = true
                    stop(pid, finished: finished)
                }
            }
        } onCancel: {
            if process.isRunning { stop(process.processIdentifier, finished: finished) }
        }
        pipe.fileHandleForReading.readabilityHandler = nil
        try Task.checkCancellation()
        if collector.timedOut { throw HelperFailure.timedOut }
        guard process.terminationStatus == 0 else {
            throw HelperFailure.failed(status: process.terminationStatus, output: collector.text)
        }
        return collector.text
    }

    /// SIGTERM to `pid`, then SIGKILL after two seconds if it is still running. Only ever the process we started.
    private static func stop(_ pid: pid_t, finished: Flag) {
        guard pid > 0 else { return }
        kill(pid, SIGTERM)
        DispatchQueue.global().asyncAfter(deadline: .now() + 2) {
            if !finished.isSet { kill(pid, SIGKILL) }
        }
    }

    private final class Flag: @unchecked Sendable {
        private let lock = NSLock()
        private var value = false
        var isSet: Bool { lock.withLock { value } }
        func set() { lock.withLock { value = true } }
    }

    private final class OutputCollector: @unchecked Sendable {
        private let lock = NSLock()
        private var data = Data()
        private var _timedOut = false
        var timedOut: Bool {
            get { lock.withLock { _timedOut } }
            set { lock.withLock { _timedOut = newValue } }
        }
        func append(_ chunk: Data) { lock.withLock { if data.count < 64_000 { data.append(chunk) } } }
        var text: String { lock.withLock { String(decoding: data, as: UTF8.self) } }
    }
}
