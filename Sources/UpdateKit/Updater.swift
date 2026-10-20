// Adapted from super-granola Sources/UpdateKit/Updater.swift (commit ca1a3e1), itself from super-flow
// Sources/UpdateKit/Updater.swift (commit 6715dbe) by way of super-kit Sources/SuperUpdate/Updater.swift. Kept from
// Super Granola: `UpdateChecking` with a status, "check now" and "install now"; the identity, the bookkeeping file and
// the idle gate come from the app. Changed here: one channel and no managed preferences; the app's "Check for updates"
// switch (Settings › Privacy, features §3.5) turns everything off, as Super Flow's setting does (no check at all,
// "check now" included, and a staged update is dropped); the first launch of an update only logs that it went in.
import AppKit
import Combine
import SuperPDFCore

/// What the updater remembers between launches, in the JSON file the app names.
struct UpdateState: Codable, Equatable {
    /// When the last automatic check started (seconds since 1970, 0 = never); checks stay `UpdateSchedule.minimumGap`
    /// apart.
    var lastAttempt: TimeInterval = 0
    /// When the feed was last read successfully.
    var lastCheck: TimeInterval = 0
    /// The version handed to the swap helper; the next launch checks that it went in.
    var installedVersion = ""
}

/// Keeps the app up to date without asking: a minute after launch and every six hours (at least four hours apart) it
/// reads the latest GitHub release; a newer version is downloaded, verified and staged next to the app. The staged copy
/// goes in when the app quits, sooner when the app's idle gate allows it (the app quits and reopens itself in the
/// background), or at once from "Install now". Failures are logged, shown as the status and retried next cycle. The
/// app's switch turns all of it off.
@MainActor
public final class Updater: UpdateChecking {
    private let app: UpdateIdentity
    private let stateFile: URL
    private let enabled: @MainActor () -> Bool
    private let enabledChanges: AnyPublisher<Void, Never>
    /// Whether the app may quit and reopen into the staged update now.
    private let canInstallNow: @MainActor () -> Bool

    private let target = Bundle.main.bundleURL
    private let current = AppVersion(Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "")
    private var installer: UpdateInstaller?
    /// Why this copy can't update itself (not the signed app bundle); nil when it can.
    private var unavailable: String?
    private var staged: (url: URL, version: AppVersion)?
    private var checking = false
    private var swapStarted = false
    private var checkTimer: Timer?
    private var idleTimer: Timer?
    private var cancellables: Set<AnyCancellable> = []
    private var state: UpdateState { didSet { if state != oldValue { saveState() } } }
    private let statusSubject = CurrentValueSubject<UpdateStatus, Never>(.idle)

    /// - Parameters:
    ///   - stateFile: where the updater keeps its bookkeeping (a JSON file in the app's support folder).
    ///   - enabled: the "Check for updates" setting, read at every step; `enabledChanges` fires when it changes.
    ///   - canInstallNow: the app's idle gate.
    public init(app: UpdateIdentity, stateFile: URL, enabled: @escaping @MainActor () -> Bool, enabledChanges: AnyPublisher<Void, Never>,
                canInstallNow: @escaping @MainActor () -> Bool) {
        self.app = app
        self.stateFile = stateFile
        self.enabled = enabled
        self.enabledChanges = enabledChanges
        self.canInstallNow = canInstallNow
        state = (try? Data(contentsOf: stateFile)).flatMap { try? JSONDecoder().decode(UpdateState.self, from: $0) } ?? UpdateState()
        if !enabled() { statusSubject.send(.disabled) }
        // Watched from the start, so the status follows the switch even in a copy that can't update itself.
        enabledChanges
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in MainActor.assumeIsolated { self?.settingChanged() } }
            .store(in: &cancellables)
    }

    public var status: UpdateStatus { statusSubject.value }
    public var statusChanges: AnyPublisher<UpdateStatus, Never> { statusSubject.removeDuplicates().eraseToAnyPublisher() }

    private var logName: String { "\(app.assetBase)-update.log" }

    public func start() {
        guard installer == nil, unavailable == nil else { return }
        guard let current, Bundle.main.bundleIdentifier == app.bundleID, target.pathExtension == "app" else {
            unavailable = "Updates work in the installed \(app.displayName) app."
            Log.updates.info("Not running from the \(self.app.displayName, privacy: .public) app bundle; automatic updates are off")
            return
        }
        guard let requirement = UpdateInstaller.ownRequirement() else {
            unavailable = "This copy of \(app.displayName) isn't signed, so no update could be verified."
            Log.updates.info("This copy isn't signed with a stable identity, so no update could be verified; automatic updates are off")
            return
        }
        installer = UpdateInstaller(app: app, requirement: requirement, userAgent: "\(app.assetBase)/\(current)")
        removeLeftovers()
        confirmInstalled(current)
        NotificationCenter.default.addObserver(forName: NSApplication.willTerminateNotification, object: nil,
                                               queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.installOnQuit() }
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + UpdateSchedule.firstCheckDelay) { [weak self] in
            MainActor.assumeIsolated {
                guard let self else { return }
                self.check(manual: false)
                self.checkTimer = Timer.scheduledTimer(withTimeInterval: UpdateSchedule.checkInterval, repeats: true) { [weak self] _ in
                    MainActor.assumeIsolated { self?.check(manual: false) }
                }
            }
        }
    }

    public func checkNow() {
        check(manual: true)
    }

    public func installNow() {
        guard let staged, !swapStarted, enabled(), startSwap(staged, relaunch: true) else { return }
        Log.updates.info("Installing \(staged.version, privacy: .public) now and reopening")
        NSApp.terminate(nil)
    }

    // MARK: - Checking

    /// Automatic checks keep the schedule's gap; "Check now" doesn't. Nothing runs while the switch is off.
    private func check(manual: Bool) {
        guard enabled() else { statusSubject.send(.disabled); return }
        if manual, let unavailable { statusSubject.send(.failed(unavailable)); return }
        guard !checking, !swapStarted, let installer else { return }
        let last = state.lastAttempt
        guard manual || UpdateSchedule.isCheckDue(lastAttempt: last > 0 ? Date(timeIntervalSince1970: last) : nil, now: Date()) else { return }
        checking = true
        if !manual { state.lastAttempt = Date().timeIntervalSince1970 }
        if staged == nil { statusSubject.send(.checking) }
        Task {
            defer { checking = false }
            do {
                try await check(with: installer)
            } catch {
                Log.updates.error("Update stopped: \(error.localizedDescription, privacy: .public) Trying again next time.")
                if staged == nil, enabled() { statusSubject.send(.failed(error.localizedDescription)) }
            }
        }
    }

    private func check(with installer: UpdateInstaller) async throws {
        Log.updates.info("Checking GitHub for a newer version")
        let feed = ReleaseFeed(app)
        let release = try await feed.fetch(from: feed.url, userAgent: installer.userAgent)
        state.lastCheck = Date().timeIntervalSince1970
        guard let current, release.version > current else {
            Log.updates.info("Up to date (\(self.current?.description ?? "?", privacy: .public))")
            if staged == nil, enabled() { statusSubject.send(.upToDate(checkedAt: Date(timeIntervalSince1970: state.lastCheck))) }
            return
        }
        if staged?.version == release.version { return }
        Log.updates.info("Version \(release.version, privacy: .public) is available")
        let version = release.version.description
        statusSubject.send(.downloading(version: version, fraction: 0))
        let subject = statusSubject
        let url = try await installer.stage(release, replacing: target) { fraction in
            DispatchQueue.main.async { subject.send(.downloading(version: version, fraction: fraction)) }
        }
        guard enabled(), !swapStarted else {
            try? FileManager.default.removeItem(at: url)
            return
        }
        if let previous = staged, previous.url != url { try? FileManager.default.removeItem(at: previous.url) }
        staged = (url, release.version)
        // Progress updates still queued on the main queue go first.
        DispatchQueue.main.async { subject.send(.readyToInstall(version: version)) }
        Log.updates.info("Version \(release.version, privacy: .public) is ready; it installs when \(self.app.displayName, privacy: .public) quits or sits idle")
        idleTimer = idleTimer ?? Timer.scheduledTimer(withTimeInterval: UpdateSchedule.idlePoll, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.installIfIdle() }
        }
    }

    /// Turned on: idle, then a check if one is due. Turned off: disabled, no waiting for idle, the staged update dropped.
    private func settingChanged() {
        if enabled() {
            if status == .disabled { statusSubject.send(.idle) }
            check(manual: false)
            return
        }
        statusSubject.send(.disabled)
        idleTimer?.invalidate()
        idleTimer = nil
        guard let staged, !swapStarted else { return }
        try? FileManager.default.removeItem(at: staged.url)
        self.staged = nil
        Log.updates.info("Update checks turned off; removed the staged update")
    }

    /// Removes staged copies an earlier run left behind (it crashed, or quit before installing).
    private func removeLeftovers() {
        let folder = target.deletingLastPathComponent()
        let items = (try? FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil)) ?? []
        for item in items where item.lastPathComponent.hasPrefix(app.stagingPrefix) && item.pathExtension == "app" {
            try? FileManager.default.removeItem(at: item)
            Log.updates.info("Removed a leftover staged update: \(item.path, privacy: .public)")
        }
    }

    // MARK: - Installing

    private func installOnQuit() {
        guard let staged, !swapStarted, enabled() else { return }
        startSwap(staged, relaunch: false)
    }

    private func installIfIdle() {
        guard let staged, !swapStarted, enabled(), canInstallNow(), startSwap(staged, relaunch: true) else { return }
        Log.updates.info("Idle: quitting to install \(staged.version, privacy: .public) and reopening in the background")
        NSApp.terminate(nil)
    }

    @discardableResult
    private func startSwap(_ staged: (url: URL, version: AppVersion), relaunch: Bool) -> Bool {
        do {
            let fm = FileManager.default
            let trash = try fm.url(for: .trashDirectory, in: .userDomainMask, appropriateFor: target, create: true)
            let log = fm.temporaryDirectory.appendingPathComponent(logName)
            try UpdateInstaller.startSwap(app: app, waitingFor: ProcessInfo.processInfo.processIdentifier, staged: staged.url,
                                          target: target, trash: trash, relaunch: relaunch, log: log)
            swapStarted = true
            state.installedVersion = staged.version.description
            Log.updates.info("Handed \(staged.version, privacy: .public) to the installer; its log is \(log.path, privacy: .public)")
            return true
        } catch {
            Log.updates.error("Couldn't start the installer: \(error.localizedDescription, privacy: .public)")
            statusSubject.send(.failed(error.localizedDescription))
            return false
        }
    }

    // MARK: - After an update

    /// The first launch after a swap logs whether the update went in.
    private func confirmInstalled(_ current: AppVersion) {
        let installed = state.installedVersion
        guard !installed.isEmpty else { return }
        state.installedVersion = ""
        if AppVersion(installed) == current {
            Log.updates.info("Now running \(installed, privacy: .public)")
        } else {
            Log.updates.error("The update to \(installed, privacy: .public) didn't go in; see \(self.logName, privacy: .public) in the temporary folder")
        }
    }

    private func saveState() {
        do {
            try FileManager.default.createDirectory(at: stateFile.deletingLastPathComponent(), withIntermediateDirectories: true)
            try JSONEncoder().encode(state).write(to: stateFile, options: .atomic)
        } catch {
            Log.updates.error("Couldn't save the update state: \(error.localizedDescription, privacy: .public)")
        }
    }
}
