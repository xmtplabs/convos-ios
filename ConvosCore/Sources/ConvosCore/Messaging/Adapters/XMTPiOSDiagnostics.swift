import ConvosMessagingProtocols
import Foundation
@preconcurrency import XMTPiOS

/// XMTPiOS-backed implementation of `MessagingDiagnostics`.
///
/// Boundary file for the logging / diagnostics surface — every call
/// forwards into a static `XMTPiOS.Client` method, and this is the
/// only place those statics are referenced. Exposed through
/// `MessagingDiagnosticsProvider.shared` (see below) so call sites
/// (`Convos/ConvosApp.swift`, `NotificationService/NotificationService.swift`,
/// `Convos/Debug View/DebugLogExporter.swift`) reach the adapter
/// without importing XMTPiOS themselves.
public struct XMTPiOSDiagnostics: MessagingDiagnostics {
    public static let shared: XMTPiOSDiagnostics = XMTPiOSDiagnostics()

    public init() {}

    public func activatePersistentLogWriter(
        logLevel: MessagingDiagnosticsLogLevel,
        rotationSchedule: MessagingDiagnosticsRotation,
        maxFiles: Int,
        customLogDirectory: URL?,
        processType: MessagingDiagnosticsProcessType
    ) {
        XMTPiOS.Client.activatePersistentLibXMTPLogWriter(
            logLevel: logLevel.xmtpLogLevel,
            rotationSchedule: rotationSchedule.ffiLogRotation,
            maxFiles: maxFiles,
            customLogDirectory: customLogDirectory,
            processType: processType.ffiProcessType
        )
    }

    public func logFilePaths(customLogDirectory: URL?) -> [String] {
        XMTPiOS.Client.getXMTPLogFilePaths(customLogDirectory: customLogDirectory)
    }
}

// MARK: - Singleton accessor

/// Static entry point callers use: `MessagingDiagnosticsProvider.shared`.
///
/// Returning the XMTPiOS-backed adapter unconditionally is correct
/// today because Convos ships a single backend. Once a second adapter
/// (DTU) lands, flip this accessor to read from a registration table
/// instead — the three call sites will not change.
public enum MessagingDiagnosticsProvider {
    public static var shared: any MessagingDiagnostics { XMTPiOSDiagnostics.shared }
}

// MARK: - Enum translations

private extension MessagingDiagnosticsLogLevel {
    var xmtpLogLevel: XMTPiOS.Client.LogLevel {
        switch self {
        case .error: return .error
        case .warn: return .warn
        case .info: return .info
        case .debug: return .debug
        }
    }
}

private extension MessagingDiagnosticsRotation {
    var ffiLogRotation: FfiLogRotation {
        switch self {
        case .minutely: return .minutely
        case .hourly: return .hourly
        case .daily: return .daily
        case .never: return .never
        }
    }
}

private extension MessagingDiagnosticsProcessType {
    var ffiProcessType: FfiProcessType {
        switch self {
        case .main: return .main
        case .notificationExtension: return .notificationExtension
        }
    }
}
