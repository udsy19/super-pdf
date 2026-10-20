import Combine
import Foundation

// The engine-facing value types and contracts that are not about PDFs: updates (UpdateKit) and download progress
// (UpdateKit's staging, ConvertKit's LibreOffice helper). The engines implement or consume these; they never touch
// `Services` or `Defaults`.
//
// Adapted from super-granola Sources/SuperGranolaCore/Contracts/Engines.swift (commit fd1f08b), itself from Super
// Flow's SuperFlowCore (Contracts.swift): only the updater part, since Super PDF has no AI, audio or speech. WP0a
// extends this file with what the copied updater needs, in the same change.

/// Progress of a download.
public struct DownloadProgress: Hashable, Sendable {
    public var bytesReceived: Int64
    public var bytesExpected: Int64
    /// Bytes per second over the last few seconds.
    public var rate: Double

    public init(bytesReceived: Int64, bytesExpected: Int64, rate: Double = 0) {
        self.bytesReceived = bytesReceived; self.bytesExpected = bytesExpected; self.rate = rate
    }

    public var fraction: Double { bytesExpected > 0 ? Double(bytesReceived) / Double(bytesExpected) : 0 }
    public var estimatedTimeRemaining: TimeInterval? { rate > 0 ? Double(bytesExpected - bytesReceived) / rate : nil }
}

// MARK: - Updates (UpdateKit, registered by the app target as `Services.updates`; features §3.5)

public enum UpdateStatus: Equatable, Sendable {
    case idle
    case checking
    case upToDate(checkedAt: Date)
    case downloading(version: String, fraction: Double)
    /// Staged; installs on quit or when idle, or now from "Install Latest Version".
    case readyToInstall(version: String)
    case failed(String)
    /// "Check for updates" is off (Settings › Privacy).
    case disabled
}

@MainActor
public protocol UpdateChecking: AnyObject {
    /// Begins the background schedule (soon after launch, then every few hours) unless updates are off.
    func start()
    func checkNow()
    /// Installs a staged update now (relaunching the app).
    func installNow()
    var status: UpdateStatus { get }
    var statusChanges: AnyPublisher<UpdateStatus, Never> { get }
}
