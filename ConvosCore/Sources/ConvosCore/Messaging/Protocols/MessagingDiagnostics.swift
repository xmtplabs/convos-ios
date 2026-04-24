import Foundation

// MARK: - Log level

/// Convos-owned mirror of `XMTPiOS.Client.LogLevel`.
///
/// Enumerates the severities the persistent libxmtp log writer can be
/// asked to capture. Kept wire-compatible with the XMTPiOS enum so the
/// adapter's translation is a trivial switch.
public enum MessagingDiagnosticsLogLevel: String, Hashable, Sendable, Codable {
    case error
    case warn
    case info
    case debug
}

// MARK: - Rotation schedule

/// Convos-owned mirror of `FfiLogRotation`.
///
/// Rotation cadence for the persistent log writer. Cases match the
/// underlying libxmtp FFI so the DTU adapter can reuse the same
/// contract without a new mapping.
public enum MessagingDiagnosticsRotation: String, Hashable, Sendable, Codable {
    case minutely
    case hourly
    case daily
    case never
}

// MARK: - Process type

/// Convos-owned mirror of `FfiProcessType`.
///
/// Tells the log writer whether it is running in the main app process
/// or inside the notification service extension. The XMTPiOS adapter
/// forwards this onto `FfiProcessType`; a future DTU adapter can use
/// it to segment writer state per-process.
public enum MessagingDiagnosticsProcessType: String, Hashable, Sendable, Codable {
    case main
    case notificationExtension
}

// MARK: - Protocol

/// Convos-owned replacement for the static `XMTPiOS.Client`
/// diagnostics surface.
///
/// Replaces these direct XMTPiOS calls at the app / NotificationService
/// / Debug boundary:
///
/// * `XMTPiOS.Client.activatePersistentLibXMTPLogWriter(...)`
///   (formerly `Convos/ConvosApp.swift:25`,
///   `NotificationService/NotificationService.swift:21`).
/// * `XMTPiOS.Client.getXMTPLogFilePaths(customLogDirectory:)`
///   (formerly `Convos/Debug View/DebugLogExporter.swift:52,67,120`).
///
/// The surface is intentionally static-like: the callers (app startup,
/// NSE startup, debug export) run *before* any `MessagingClient`
/// instance exists, so there is nowhere else to hang these operations.
/// An adapter exposes the active implementation as
/// `MessagingDiagnostics.shared` (extension defined alongside the
/// concrete adapter in `Messaging/Adapters/`), letting the three call
/// sites reach it without threading a DI container or a messaging
/// client through app startup.
///
/// DTU adapter implication: DTU does not produce libxmtp logs, so a
/// DTU-backed implementation will either no-op both methods or expose
/// its own event log. Tracks audit open question #6.
public protocol MessagingDiagnostics: Sendable {
    /// Starts the persistent libxmtp log writer.
    ///
    /// Mirrors the parameter shape of
    /// `XMTPiOS.Client.activatePersistentLibXMTPLogWriter` so the
    /// XMTPiOS adapter is a straight forward.
    func activatePersistentLogWriter(
        logLevel: MessagingDiagnosticsLogLevel,
        rotationSchedule: MessagingDiagnosticsRotation,
        maxFiles: Int,
        customLogDirectory: URL?,
        processType: MessagingDiagnosticsProcessType
    )

    /// Returns absolute paths to every file the log writer has emitted
    /// inside `customLogDirectory` (or the SDK default if `nil`).
    ///
    /// Used by the debug-export flow to stage logs into the shared
    /// staging directory.
    func logFilePaths(customLogDirectory: URL?) -> [String]
}
