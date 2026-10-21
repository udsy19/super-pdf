import AppKit
import Combine
import CryptoKit
import Foundation
import Security
import SuperPDFCore
import UpdateKit

// UpdateKit's checks (WP0a). Adapted from super-granola Sources/SuperGranolaSelfTest/UpdateKitTests.swift (commit
// ca1a3e1), itself from super-flow Sources/SuperFlowSelfTest/UpdateKitTests.swift (commit 6715dbe): versions, the
// release feed, the schedule, the swap's failure paths, the off switch and the status, and the whole download → verify → stage → swap
// against a local server when build/Super PDF.app (or `SUPERPDF_UPDATE_TEST_APP`) is a signed build. Nothing touches
// the installed app or GitHub.

/// Super PDF as the updater knows it (the app target passes the same values).
let updateIdentity = UpdateIdentity(bundleID: SuperPDFPaths.bundleID, appName: "Super PDF.app", displayName: "Super PDF",
                                    repository: "udsy19/super-pdf", assetBase: "SuperPDF")

func registerUpdateKitTests() {
    SelfTest.cases.append(("UpdateKit.versionCompare", {
        func v(_ s: String) -> AppVersion { AppVersion(s)! }
        check(v("1.2.0") < v("1.3.0") && v("1.10.0") > v("1.9.9") && v("2.0.0") > v("1.99.99"), "numeric parts compare as numbers")
        check(v("v1.3") == v("1.3.0") && v("1.3.0+7") == v("1.3.0"), "leading v, missing parts and build metadata")
        check(v("v1.3").description == "1.3" && v("1.3.0-beta.2").description == "1.3.0-beta.2", "description")
        // SemVer 2.0's own precedence example.
        let ordered = ["1.0.0-alpha", "1.0.0-alpha.1", "1.0.0-alpha.beta", "1.0.0-beta", "1.0.0-beta.2", "1.0.0-beta.11",
                       "1.0.0-rc.1", "1.0.0"].map(v)
        check(zip(ordered, ordered.dropFirst()).allSatisfy { $0 < $1 }, "pre-releases sort before the release, in SemVer order")
        check(!(v("1.3.0") < v("1.3.0")) && !(v("1.3.0") > v("1.3")), "equal versions are neither newer nor older")
        check(["", "v", "1..2", "1.2.x", "abc", "1.2.3-", "1.2.3-a..b", "+1.2", "1.2.3.4.5"].allSatisfy { AppVersion($0) == nil },
              "malformed versions are rejected")
    }))

    SelfTest.cases.append(("UpdateKit.releaseFeed", {
        let sha = String(repeating: "0123456789abcdef", count: 4)
        let base = "https://github.com/udsy19/super-pdf/releases/download/v1.3.0/"
        let feed = ReleaseFeed(updateIdentity)
        let release = try? feed.parse(releaseJSON(tag: "v1.3.0", sha: sha, assets: [
            ("SuperPDF-1.3.0.dmg", base + "SuperPDF-1.3.0.dmg"), ("SuperPDF.dmg", base + "SuperPDF.dmg")]))
        check(release?.version == AppVersion("1.3.0"), "tag_name without the v")
        check(release?.diskImage?.absoluteString == base + "SuperPDF.dmg", "the stable asset wins")
        check(release?.sha256 == sha, "SHA-256 from release.sh's notes line")

        func image(_ names: [String]) -> String? {
            feed.diskImage(in: names.map { ($0, URL(string: base + $0)!) }, version: "1.3.0")?.lastPathComponent
        }
        check(image(["Source.zip", "SuperPDF-1.3.0.dmg"]) == "SuperPDF-1.3.0.dmg", "falls back to the versioned asset")
        check(image(["SuperPDF-1.2.0.dmg", "SuperPDF.zip", "Super PDF.dmg"]) == nil, "no matching asset")
        let noImage = try? feed.parse(releaseJSON(tag: "v1.3.0", sha: sha, assets: []))
        check(noImage != nil && noImage?.diskImage == nil, "a release without assets still parses")

        check(feed.checksum(in: "notes\n\nSHA-256 (SuperPDF.dmg): `\(sha)`\n") == sha, "checksum line")
        check(feed.checksum(in: "SHA-256 (SuperPDF.dmg): `\(sha.uppercased())`") == nil, "upper-case hex is not release.sh's")
        check(feed.checksum(in: "SHA-256 (SuperPDF.dmg): `\(sha.dropLast())`") == nil, "63 digits")
        check(feed.checksum(in: "SHA-256 (SuperPDF-1.3.0.dmg): `\(sha)`") == nil, "another file's checksum")
        check(feed.checksum(in: "no checksum here") == nil, "missing line")
        check((try? feed.parse(releaseJSON(tag: "v1.3.0", sha: nil, assets: [])))?.sha256 == nil, "notes without the line")

        func parseError(_ data: Data) -> UpdateError? {
            do { _ = try feed.parse(data); return nil } catch { return error as? UpdateError }
        }
        check(parseError(Data("{\"message\":\"Not Found\"}".utf8)) == .badFeed, "GitHub's error payload")
        check(parseError(releaseJSON(tag: "nightly", sha: sha, assets: [])) == .badFeed, "a tag that isn't a version")
        check(parseError(Data("not json".utf8)) == .badFeed, "not JSON")

        check(feed.url.absoluteString == "https://api.github.com/repos/udsy19/super-pdf/releases/latest", "the latest release, never a pre-release")
    }))

    SelfTest.cases.append(("UpdateKit.schedule", {
        let now = Date(timeIntervalSinceReferenceDate: 800_000_000)
        func due(_ hoursAgo: Double?) -> Bool {
            UpdateSchedule.isCheckDue(lastAttempt: hoursAgo.map { now.addingTimeInterval(-$0 * 3600) }, now: now)
        }
        check(due(nil), "never checked")
        check(!due(1) && !due(3.9), "less than four hours since the last check")
        check(due(4) && due(6) && due(30), "four hours or more")
        check(due(-2), "a clock set back doesn't block checks")
        check(UpdateSchedule.firstCheckDelay == 60 && UpdateSchedule.checkInterval == 6 * 3600, "a minute after launch, then every six hours")
    }))

    SelfTest.cases.append(("UpdateKit.switchAndStatus", { updateSwitchAndStatus() }))
    SelfTest.cases.append(("UpdateKit.failedSwapKeepsOldApp", { updateFailedSwap() }))
    SelfTest.cases.append(("UpdateKit.endToEnd", { endToEndUpdate() }))
}

/// A `releases/latest` payload as GitHub returns it for a release made by scripts/release.sh.
private func releaseJSON(tag: String, sha: String?, assets: [(name: String, url: String)]) -> Data {
    var body = "### Added\n- Automatic updates.\n\nDownload the DMG below."
    if let sha { body += "\n\nSHA-256 (SuperPDF.dmg): `\(sha)`" }
    let object: [String: Any] = [
        "url": "https://api.github.com/repos/udsy19/super-pdf/releases/1",
        "html_url": "https://github.com/udsy19/super-pdf/releases/tag/\(tag)",
        "tag_name": tag, "name": "Super PDF \(tag)", "draft": false, "prerelease": false, "body": body,
        "assets": assets.map { ["name": $0.name, "browser_download_url": $0.url, "content_type": "application/x-apple-diskimage"] },
    ]
    return try! JSONSerialization.data(withJSONObject: object)
}

/// Download fractions reported from the installer's download task.
private final class Fractions: @unchecked Sendable {
    private let lock = NSLock()
    private var values: [Double] = []
    func add(_ value: Double) { lock.withLock { values.append(value) } }
    var all: [Double] { lock.withLock { values } }
}

private func failure<T>(_ result: Result<T, Error>?) -> UpdateError? {
    if case .failure(let error)? = result { return error as? UpdateError }
    return nil
}

@discardableResult
private func tool(_ path: String, _ arguments: String...) -> (status: Int32, output: String) {
    let process = Process()
    process.executableURL = URL(fileURLWithPath: path)
    process.arguments = arguments
    let pipe = Pipe()
    process.standardOutput = pipe
    process.standardError = pipe
    guard (try? process.run()) != nil else { return (-1, "") }
    let data = pipe.fileHandleForReading.readDataToEndOfFile()
    process.waitUntilExit()
    return (process.terminationStatus, String(decoding: data, as: UTF8.self))
}

/// A TCP port nothing is listening on right now.
private func freePort() -> UInt16? {
    let fd = socket(AF_INET, SOCK_STREAM, 0)
    guard fd >= 0 else { return nil }
    defer { close(fd) }
    var address = sockaddr_in()
    address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
    address.sin_family = sa_family_t(AF_INET)
    address.sin_addr.s_addr = inet_addr("127.0.0.1")
    var length = socklen_t(MemoryLayout<sockaddr_in>.size)
    let bound = withUnsafeMutablePointer(to: &address) { pointer in
        pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { bind(fd, $0, length) == 0 && getsockname(fd, $0, &length) == 0 }
    }
    return bound ? UInt16(bigEndian: address.sin_port) : nil
}

private func shortVersion(_ app: URL) -> String {
    (NSDictionary(contentsOf: app.appendingPathComponent("Contents/Info.plist"))?["CFBundleShortVersionString"] as? String) ?? ""
}

/// Download → checksum → mount → signature → stage → swap, against the real build/Super PDF.app served from a
/// local web server, in temporary folders, with an already-exited process standing in for the running app and no
/// relaunch.
@MainActor
private func endToEndUpdate() {
    let fm = FileManager.default
    let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
    // `SUPERPDF_UPDATE_TEST_APP` may name another signed build (a sister app's) to exercise the same path.
    let built = ProcessInfo.processInfo.environment["SUPERPDF_UPDATE_TEST_APP"].map { URL(fileURLWithPath: $0, isDirectory: true) }
        ?? root.appendingPathComponent("build/Super PDF.app", isDirectory: true)
    let info = NSDictionary(contentsOf: built.appendingPathComponent("Contents/Info.plist")) as? [String: Any] ?? [:]
    let updateIdentity = UpdateIdentity(bundleID: info["CFBundleIdentifier"] as? String ?? updateIdentity.bundleID,
                                        appName: built.lastPathComponent, displayName: built.deletingPathExtension().lastPathComponent,
                                        repository: updateIdentity.repository, assetBase: updateIdentity.assetBase)
    guard fm.fileExists(atPath: built.appendingPathComponent("Contents/Info.plist").path) else {
        print("  (skipped: \(built.lastPathComponent) not found; run scripts/build-app.sh first)"); return
    }
    guard let requirement = UpdateInstaller.designatedRequirement(of: built) else {
        print("  (skipped: \(built.lastPathComponent) is ad-hoc signed; run scripts/signing-setup.sh, then scripts/build-app.sh)"); return
    }
    guard let version = AppVersion(shortVersion(built)) else { check(false, "\(built.lastPathComponent) has a version"); return }
    guard fm.fileExists(atPath: "/usr/bin/python3"), let port = freePort() else {
        print("  (skipped: python3 or a free local port is unavailable)"); return
    }

    let temp = fm.temporaryDirectory
    let tempBefore = Set((try? fm.contentsOfDirectory(atPath: temp.path)) ?? [])
    let work = temp.appendingPathComponent("superpdf-selftest-update-\(UUID().uuidString)", isDirectory: true)
    let serve = work.appendingPathComponent("serve"), image = work.appendingPathComponent("image")
    let apps = work.appendingPathComponent("Applications"), trash = work.appendingPathComponent("Trash")
    for folder in [serve, image, apps, trash] { try? fm.createDirectory(at: folder, withIntermediateDirectories: true) }
    defer { try? fm.removeItem(at: work) }

    // The disk image release.sh would publish, holding this build.
    tool("/usr/bin/ditto", built.path, image.appendingPathComponent(updateIdentity.appName).path)
    let dmg = serve.appendingPathComponent("SuperPDF.dmg")
    let created = tool("/usr/bin/hdiutil", "create", "-volname", "Super PDF \(version)", "-srcfolder", image.path,
                       "-fs", "HFS+", "-format", "UDZO", "-ov", dmg.path)
    guard created.status == 0, let dmgData = try? Data(contentsOf: dmg) else { check(false, "hdiutil create: \(created.output)"); return }
    let sha = SHA256.hash(data: dmgData).map { String(format: "%02x", $0) }.joined()

    // A local web server for the feed and the disk image; only this process is stopped afterwards.
    let server = Process()
    server.executableURL = URL(fileURLWithPath: "/usr/bin/python3")
    server.arguments = ["-I", "-m", "http.server", String(port), "--bind", "127.0.0.1", "--directory", serve.path]
    server.currentDirectoryURL = work
    server.standardOutput = FileHandle.nullDevice
    server.standardError = FileHandle.nullDevice
    guard (try? server.run()) != nil else { check(false, "python3 http.server starts"); return }
    defer {
        server.terminate()
        server.waitUntilExit()
    }
    let base = "http://127.0.0.1:\(port)/"
    try? releaseJSON(tag: "v\(version)", sha: sha, assets: [("SuperPDF-\(version).dmg", base + "nothing-here.dmg"),
                                                            ("SuperPDF.dmg", base + "SuperPDF.dmg")])
        .write(to: serve.appendingPathComponent("latest.json"))

    // The installed copy the update replaces: a stand-in that reports version 0.0.1.
    let target = apps.appendingPathComponent(updateIdentity.appName, isDirectory: true)
    try? fm.createDirectory(at: target.appendingPathComponent("Contents"), withIntermediateDirectories: true)
    (["CFBundleIdentifier": updateIdentity.bundleID, "CFBundleShortVersionString": "0.0.1"] as NSDictionary)
        .write(to: target.appendingPathComponent("Contents/Info.plist"), atomically: true)

    let installer = UpdateInstaller(app: updateIdentity, requirement: requirement, userAgent: "SuperPDF/self-test")
    var feed: ReleaseInfo?
    for _ in 0..<50 where feed == nil {   // the server needs a moment to start listening
        if case .success(let release)? = complete(5, { try await ReleaseFeed(updateIdentity).fetch(from: URL(string: base + "latest.json")!,
                                                                                                 userAgent: installer.userAgent) }) {
            feed = release
        } else {
            RunLoop.main.run(until: Date().addingTimeInterval(0.1))
        }
    }
    guard let release = feed else { check(false, "the feed is served over HTTP"); return }
    check(release.version == version && release.sha256 == sha && release.diskImage?.absoluteString == base + "SuperPDF.dmg",
          "feed read over HTTP")
    let staged = installer.stagingURL(replacing: target, version: version)

    // Refusals: nothing is staged and the download is deleted.
    var wrongSum = release
    wrongSum.sha256 = String(repeating: "0", count: 64)
    check(failure(complete { try await installer.stage(wrongSum, replacing: target) }) == .checksumMismatch, "checksum mismatch refused")
    var noSum = release
    noSum.sha256 = nil
    check(failure(complete { try await installer.stage(noSum, replacing: target) }) == .noChecksum, "missing checksum refused")
    var missing = release
    missing.diskImage = URL(string: base + "nothing-here.dmg")
    check(failure(complete { try await installer.stage(missing, replacing: target) }) == .http(404), "missing download refused")
    check(!fm.fileExists(atPath: staged.path), "nothing staged after a refusal")

    // Signature, bundle and version checks on their own.
    func refusal(_ body: () throws -> Void) -> UpdateError? {
        do { try body(); return nil } catch { return error as? UpdateError }
    }
    check(refusal { try installer.verify(app: built, version: version) } == nil, "the build passes its own checks")
    check(refusal { try installer.verify(app: built, version: AppVersion("99.0")!) } == .wrongVersion(version.description),
          "advertised version must match the bundle")
    var other: SecRequirement?
    SecRequirementCreateWithString(#"identifier "com.example.other""# as CFString, [], &other)
    if let other {
        let stranger = UpdateInstaller(app: updateIdentity, requirement: other, userAgent: "")
        check(refusal { try stranger.verify(app: built, version: version) } == .otherDeveloper, "another signer's requirement")
    }
    let tampered = work.appendingPathComponent("tampered/\(updateIdentity.appName)")
    tool("/usr/bin/ditto", built.path, tampered.path)
    if let handle = try? FileHandle(forWritingTo: tampered.appendingPathComponent("Contents/Info.plist")) {
        _ = try? handle.seekToEnd()
        try? handle.write(contentsOf: Data("\n".utf8))
        try? handle.close()
    }
    check(refusal { try installer.verify(app: tampered, version: version) } == .badSignature, "a modified bundle is refused")

    // The real thing.
    let fractions = Fractions()
    let staging = complete { try await installer.stage(release, replacing: target) { fractions.add($0) } }
    switch staging {
    case .success(let url)?:
        check(url == staged && fm.fileExists(atPath: staged.path), "staged next to the app")
        check(fractions.all.last == 1 && fractions.all == fractions.all.sorted(), "the download reports rising progress to 1 (\(fractions.all.count))")
    case .failure(let error)?: check(false, "staging failed: \(error.localizedDescription)"); return
    case nil: check(false, "staging timed out"); return
    }
    check(!tool("/usr/bin/hdiutil", "info").output.contains("/superpdf-update-"), "disk image unmounted")
    let tempAfter = Set((try? fm.contentsOfDirectory(atPath: temp.path)) ?? [])
    check(tempAfter.subtracting(tempBefore).allSatisfy { !$0.hasPrefix("superpdf-update-") }, "download folder removed")

    // Swap, standing in an already-exited process for Super PDF.
    let exited = Process()
    exited.executableURL = URL(fileURLWithPath: "/usr/bin/true")
    try? exited.run()
    exited.waitUntilExit()
    let log = work.appendingPathComponent("update.log")
    guard let helper = try? UpdateInstaller.startSwap(app: updateIdentity, waitingFor: exited.processIdentifier, staged: staged, target: target,
                                                      trash: trash, relaunch: false, log: log) else {
        check(false, "swap helper starts"); return
    }
    helper.waitUntilExit()
    check(helper.terminationStatus == 0, "swap helper succeeded")
    check(shortVersion(target) == shortVersion(built) && refusal { try installer.verify(app: target, version: version) } == nil,
          "the update is in place, signature intact")
    check(!fm.fileExists(atPath: staged.path), "staged copy moved")
    let trashed = (try? fm.contentsOfDirectory(at: trash, includingPropertiesForKeys: nil)) ?? []
    check(trashed.count == 1 && shortVersion(trashed[0]) == "0.0.1", "previous version in the Trash")
    let lines = (try? String(contentsOf: log, encoding: .utf8))?.split(separator: "\n") ?? []
    for line in lines { print("  helper: \(line.replacingOccurrences(of: work.path, with: "<tmp>"))") }
}

/// A swap that can't finish leaves the installed app exactly where and as it was: the update going missing before the
/// move, and the Trash refusing the old copy.
private func updateFailedSwap() {
    let fm = FileManager.default
    let work = scratch.appendingPathComponent("swap-\(UUID().uuidString)", isDirectory: true)
    let target = work.appendingPathComponent(updateIdentity.appName, isDirectory: true)
    let marker = target.appendingPathComponent("Contents/Info.plist")
    try? fm.createDirectory(at: marker.deletingLastPathComponent(), withIntermediateDirectories: true)
    try? Data("the installed version".utf8).write(to: marker)
    let trash = work.appendingPathComponent("Trash", isDirectory: true)
    try? fm.createDirectory(at: trash, withIntermediateDirectories: true)
    let exited = Process()
    exited.executableURL = URL(fileURLWithPath: "/usr/bin/true")
    try? exited.run()
    exited.waitUntilExit()
    func swap(staged: URL, trash: URL) -> Int32? {
        guard let helper = try? UpdateInstaller.startSwap(app: updateIdentity, waitingFor: exited.processIdentifier, staged: staged, target: target, trash: trash,
                                                          relaunch: false, log: work.appendingPathComponent("update.log")) else { return nil }
        helper.waitUntilExit()
        return helper.terminationStatus
    }
    func intact() -> Bool { (try? String(contentsOf: marker, encoding: .utf8)) == "the installed version" }

    // The staged copy vanished (cleaned up, or the disk was ejected) between staging and quitting.
    let vanished = work.appendingPathComponent(".SuperPDF-update-9.9.9.app", isDirectory: true)
    check(swap(staged: vanished, trash: trash) == 1 && intact(), "the old app is put back when the update can't move in")
    check(((try? fm.contentsOfDirectory(atPath: trash.path)) ?? ["?"]).isEmpty, "nothing is left in the Trash")

    // The old copy can't be moved to the Trash: nothing changes and the staged copy goes.
    let staged = work.appendingPathComponent(".SuperPDF-update-9.9.9.app/Contents", isDirectory: true)
    try? fm.createDirectory(at: staged, withIntermediateDirectories: true)
    check(swap(staged: staged.deletingLastPathComponent(), trash: work.appendingPathComponent("No Trash")) == 1 && intact(),
          "a Trash that refuses the old copy leaves it installed")
    check(!fm.fileExists(atPath: staged.path), "and the update is dropped")
    try? fm.removeItem(at: work)
}

/// The "Check for updates" switch turns the automatic checks off and the status says so, while "Check for Updates…"
/// still checks when asked; a copy that isn't the signed app bundle (this self-test) never checks and says why when asked
/// to. Nothing is written or opened.
@MainActor private func updateSwitchAndStatus() {
    let folder = scratch.appendingPathComponent("updates-\(UUID().uuidString)", isDirectory: true)
    var enabled = false
    let changes = PassthroughSubject<Void, Never>()
    var gateAsked = false
    let updater = Updater(app: updateIdentity, stateFile: folder.appendingPathComponent("state.json"), enabled: { enabled },
                          enabledChanges: changes.eraseToAnyPublisher(), canInstallNow: { gateAsked = true; return false })
    var statuses: [UpdateStatus] = []
    let subscription = updater.statusChanges.sink { statuses.append($0) }
    check(updater.status == .disabled, "switched off from the start: disabled")
    updater.start()
    enabled = true
    changes.send()
    RunLoop.main.run(until: Date().addingTimeInterval(0.05))
    check(updater.status == .idle, "switched on: idle until something happens (\(updater.status))")
    updater.checkNow()
    if case .failed(let why) = updater.status { check(why.contains("Super PDF"), "a copy outside the app bundle says why: \(why)") }
    else { check(false, "a copy outside the app bundle can't check: \(updater.status)") }
    enabled = false
    changes.send()
    RunLoop.main.run(until: Date().addingTimeInterval(0.05))
    check(updater.status == .disabled, "switched off again: disabled")
    updater.checkNow()
    if case .failed(let why) = updater.status { check(why.contains("Super PDF"), "switched off, “Check for Updates…” still asks: \(why)") }
    else { check(false, "switched off, a manual check still runs: \(updater.status)") }
    updater.installNow()   // nothing staged: nothing happens
    check(statuses.first == .disabled && statuses.contains(.idle), "the status changes are published (\(statuses))")
    check(!FileManager.default.fileExists(atPath: folder.path), "no check ran, so no bookkeeping was written")
    check(!gateAsked, "nothing staged, so the idle gate is never asked")
    subscription.cancel()
}
