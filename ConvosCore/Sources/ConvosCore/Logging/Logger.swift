import ConvosLogging
import Foundation
import Logging

/// Unified logger that accepts a namespace parameter
///
/// This is the public API that both ConvosCore and Convos app use.
/// Each module provides a convenience wrapper with its own namespace.
public enum ConvosLog {
    nonisolated(unsafe) private static var _logger: Logging.Logger?
    private static let queue: DispatchQueue = DispatchQueue(label: "com.convos.log")

    private static var logger: Logging.Logger? {
        queue.sync {
            _logger
        }
    }

    public static func debug(_ message: String, namespace: String, file: String = #file, function: String = #function, line: Int = #line) {
        logger?.debug("[\(namespace)] \(message)", source: makeSource(file: file, function: function, line: line))
    }

    public static func info(_ message: String, namespace: String, file: String = #file, function: String = #function, line: Int = #line) {
        logger?.info("[\(namespace)] \(message)", source: makeSource(file: file, function: function, line: line))
    }

    public static func warning(_ message: String, namespace: String, file: String = #file, function: String = #function, line: Int = #line) {
        logger?.warning("[\(namespace)] \(message)", source: makeSource(file: file, function: function, line: line))
    }

    public static func error(_ message: String, namespace: String, file: String = #file, function: String = #function, line: Int = #line) {
        logger?.error("[\(namespace)] \(message)", source: makeSource(file: file, function: function, line: line))
    }

    private static func makeSource(file: String, function: String, line: Int) -> String {
        let fileName = (file as NSString).lastPathComponent
        return "\(fileName):\(line) \(function)"
    }

    // MARK: - Configuration

    /// Configure the logging system with file-based handler.
    /// Call this once at app startup before using any loggers.
    ///
    /// File logging is enabled in every environment, including production.
    /// Logs stay local in the shared app group container, rotate at 10MB
    /// (see `FileLogHandler.maxFileSize`), and are only emitted off-device
    /// when the user explicitly taps the in-app "Share logs" affordance
    /// in Settings -> Send feedback / Share logs. The combination is
    /// privacy-respecting (no automatic telemetry) and unblocks support
    /// triage for App Store users who can't run a Debug build.
    public static func configure(environment: AppEnvironment) {
        queue.sync {
            guard _logger == nil else { return }

            // First, bootstrap the logging system factory
            LoggingSystem.bootstrap { label in
                // Use MultiplexLogHandler to send logs to both file and console
                MultiplexLogHandler([
                    FileLogHandler.makeHandler(label: label, appGroupIdentifier: environment.appGroupIdentifier),
                    StreamLogHandler.standardOutput(label: label)
                ])
            }

            // Then create the logger (it will now use the FileLogHandler)
            _logger = Logging.Logger(label: "convos")
        }
    }

    /// Get all logs from the shared log file
    public static func getLogs(appGroupIdentifier: String = "group.org.convos.app") async -> String {
        await FileLogHandler.getLogs(appGroupIdentifier: appGroupIdentifier)
    }

    /// Clear all logs
    public static func clearLogs(appGroupIdentifier: String = "group.org.convos.app") {
        FileLogHandler.clearLogs(appGroupIdentifier: appGroupIdentifier)
    }
}

// MARK: - ConvosCore convenience wrapper

/// ConvosCore logging wrapper - uses "ConvosCore" namespace
public enum Log {
    public static func debug(_ message: String, file: String = #file, function: String = #function, line: Int = #line) {
        ConvosLog.debug(message, namespace: "ConvosCore", file: file, function: function, line: line)
    }

    public static func info(_ message: String, file: String = #file, function: String = #function, line: Int = #line) {
        ConvosLog.info(message, namespace: "ConvosCore", file: file, function: function, line: line)
    }

    public static func warning(_ message: String, file: String = #file, function: String = #function, line: Int = #line) {
        ConvosLog.warning(message, namespace: "ConvosCore", file: file, function: function, line: line)
    }

    public static func error(_ message: String, file: String = #file, function: String = #function, line: Int = #line) {
        ConvosLog.error(message, namespace: "ConvosCore", file: file, function: function, line: line)
    }
}
