import Foundation
import Logging

/// Simple file-based log handler that writes to a shared app group container
///
/// Features:
/// - Writes to shared app group for access from main app and extensions
/// - Automatic log rotation at 50MB (increased from 10MB for better debugging)
/// - Thread-safe file operations
/// - Cross-process safe using NSFileCoordinator (prevents corruption between main app and extensions)
/// - No duplicate console logging (relies on swift-log's built-in console output)
public struct FileLogHandler: LogHandler {
    // thread-safe state storage
    private final class State {
        private let lock: NSLock = NSLock()
        private var _logLevel: Logging.Logger.Level = .info
        private var _metadata: Logging.Logger.Metadata = [:]

        var logLevel: Logging.Logger.Level {
            get { lock.withLock { _logLevel } }
            set { lock.withLock { _logLevel = newValue } }
        }

        var metadata: Logging.Logger.Metadata {
            get { lock.withLock { _metadata } }
            set { lock.withLock { _metadata = newValue } }
        }

        subscript(metadataKey key: String) -> Logging.Logger.Metadata.Value? {
            get { lock.withLock { _metadata[key] } }
            set { lock.withLock { _metadata[key] = newValue } }
        }
    }

    private let state: State = State()

    public var logLevel: Logging.Logger.Level {
        get { state.logLevel }
        set { state.logLevel = newValue }
    }

    public var metadata: Logging.Logger.Metadata {
        get { state.metadata }
        set { state.metadata = newValue }
    }

    private let label: String
    private let fileURL: URL?
    private static let queue: DispatchQueue = DispatchQueue(label: "com.convos.logging.file", qos: .utility)
    private static let maxFileSize: Int64 = 10 * 1024 * 1024 // 10MB

    public init(label: String, appGroupIdentifier: String) {
        self.label = label

        // get shared container
        guard let containerURL = FileManager.default.containerURL(
            forSecurityApplicationGroupIdentifier: appGroupIdentifier
        ) else {
            print("❌ FileLogHandler: Failed to access app group container: \(appGroupIdentifier)")
            self.fileURL = nil
            return
        }

        let logsDirectory = containerURL.appendingPathComponent("Logs")

        // create logs directory
        do {
            try FileManager.default.createDirectory(
                at: logsDirectory,
                withIntermediateDirectories: true
            )
        } catch {
            print("❌ FileLogHandler: Failed to create logs directory: \(error)")
        }

        self.fileURL = logsDirectory.appendingPathComponent("convos.log")
        print("✅ FileLogHandler initialized for label '\(label)' at: \(self.fileURL?.path ?? "nil")")
    }

    public subscript(metadataKey key: String) -> Logging.Logger.Metadata.Value? {
        get { state[metadataKey: key] }
        set { state[metadataKey: key] = newValue }
    }

    // swiftlint:disable:next function_parameter_count
    public func log(
        level: Logging.Logger.Level,
        message: Logging.Logger.Message,
        metadata: Logging.Logger.Metadata?,
        source: String,
        file: String,
        function: String,
        line: UInt
    ) {
        let timestamp = ISO8601DateFormatter().string(from: Date())
        let fileName = (file as NSString).lastPathComponent

        // combine metadata
        var effectiveMetadata = self.metadata
        if let metadata = metadata {
            effectiveMetadata.merge(metadata) { _, new in new }
        }

        // format message (no label since namespace is in the message)
        var logMessage = "[\(timestamp)] [\(level)] [\(fileName):\(line)] \(message)"

        if !effectiveMetadata.isEmpty {
            let metadataString = effectiveMetadata
                .map { "\($0.key)=\($0.value)" }
                .joined(separator: " ")
            logMessage += " [\(metadataString)]"
        }

        writeToFile(logMessage)
    }

    private func writeToFile(_ message: String) {
        guard let fileURL = fileURL else { return }

        Self.queue.async {
            do {
                let logEntry = message + "\n"
                guard let data = logEntry.data(using: .utf8) else { return }

                // use NSFileCoordinator for cross-process coordination
                let coordinator = NSFileCoordinator()
                var coordinationError: NSError?

                coordinator.coordinate(writingItemAt: fileURL, options: [], error: &coordinationError) { coordinatedURL in
                    do {
                        // check file size and rotate if needed
                        if FileManager.default.fileExists(atPath: coordinatedURL.path) {
                            let attributes = try FileManager.default.attributesOfItem(atPath: coordinatedURL.path)
                            let fileSize = (attributes[.size] as? NSNumber)?.int64Value ?? 0

                            if fileSize > Self.maxFileSize {
                                // rotate: keep last 25% of file
                                let keepSize = Self.maxFileSize / 4
                                let handle = try FileHandle(forReadingFrom: coordinatedURL)
                                defer { try? handle.close() }

                                let endOffset = try handle.seekToEnd()
                                let startOffset = max(0, endOffset - UInt64(keepSize))
                                try handle.seek(toOffset: startOffset)

                                let truncatedData = try handle.readToEnd() ?? Data()

                                // write atomically to temporary file, then replace
                                let tempURL = coordinatedURL.deletingLastPathComponent()
                                    .appendingPathComponent(".\(coordinatedURL.lastPathComponent).tmp")
                                try truncatedData.write(to: tempURL, options: .atomic)
                                try FileManager.default.replaceItemAt(
                                    coordinatedURL,
                                    withItemAt: tempURL,
                                    backupItemName: nil,
                                    options: []
                                )
                            }
                        }

                        // append log message
                        if let handle = try? FileHandle(forWritingTo: coordinatedURL) {
                            defer { try? handle.close() }
                            try handle.seekToEnd()
                            try handle.write(contentsOf: data)
                        } else {
                            // file doesn't exist, create it
                            try data.write(to: coordinatedURL, options: .atomic)
                        }
                    } catch {
                        print("Failed to write log during coordination: \(error)")
                    }
                }

                if let error = coordinationError {
                    print("Failed to coordinate file access: \(error)")
                }
            } catch {
                // fallback to print if file writing fails
                print("Failed to write log: \(error)")
            }
        }
    }
}

// MARK: - Factory methods

public extension FileLogHandler {
    /// Create a log handler for the main app or extensions
    static func makeHandler(
        label: String,
        appGroupIdentifier: String = "group.org.convos.app"
    ) -> FileLogHandler {
        FileLogHandler(label: label, appGroupIdentifier: appGroupIdentifier)
    }
}

// MARK: - Log retrieval

public extension FileLogHandler {
    /// Read all logs from the shared log file
    static func getLogs(
        appGroupIdentifier: String = "group.org.convos.app",
        maxLines: Int = 5000  // increased from 1000 for better debugging
    ) async -> String {
        // clamp maxLines to prevent crashes with invalid values
        let safeMaxLines = max(1, maxLines)

        guard let containerURL = FileManager.default.containerURL(
            forSecurityApplicationGroupIdentifier: appGroupIdentifier
        ) else {
            return "Failed to access app group container"
        }

        let logURL = containerURL
            .appendingPathComponent("Logs")
            .appendingPathComponent("convos.log")

        guard FileManager.default.fileExists(atPath: logURL.path) else {
            return "No logs available"
        }

        return await withCheckedContinuation { continuation in
            DispatchQueue.global(qos: .utility).async {
                // use NSFileCoordinator for cross-process safe reading
                let coordinator = NSFileCoordinator()
                var coordinationError: NSError?

                coordinator.coordinate(readingItemAt: logURL, options: [], error: &coordinationError) { coordinatedURL in
                    do {
                        let handle = try FileHandle(forReadingFrom: coordinatedURL)
                        defer { try? handle.close() }

                        // read from end to get most recent logs
                        let endOffset = try handle.seekToEnd()

                        // if file is empty, return early
                        if endOffset == 0 {
                            continuation.resume(returning: "No logs yet")
                            return
                        }

                        // read in chunks from end
                        let chunkSize = 64 * 1024
                        var chunks: [Data] = []
                        var newlineCount = 0
                        var position = endOffset

                        while position > 0 && newlineCount < safeMaxLines {
                            let readSize = min(chunkSize, Int(position))
                            position -= UInt64(readSize)

                            try handle.seek(toOffset: position)
                            if let chunk = try handle.read(upToCount: readSize) {
                                chunks.append(chunk)
                                newlineCount += chunk.filter { $0 == 0x0A }.count
                            }
                        }

                        // combine chunks in correct order
                        var combined = Data()
                        for chunk in chunks.reversed() {
                            combined.append(chunk)
                        }

                        // extract last maxLines if we read too much
                        if newlineCount > safeMaxLines {
                            let bytes = [UInt8](combined)
                            var needed = safeMaxLines
                            var idx = bytes.count - 1

                            while idx >= 0 && needed > 0 {
                                if bytes[idx] == 0x0A {
                                    needed -= 1
                                }
                                idx -= 1
                            }

                            let start = max(0, idx + 2)
                            combined = combined.subdata(in: start..<combined.count)
                        }

                        let logs = String(data: combined, encoding: .utf8) ?? "Failed to decode logs"
                        continuation.resume(returning: logs.isEmpty ? "No logs yet" : logs)
                    } catch {
                        continuation.resume(returning: "Failed to read logs: \(error.localizedDescription)")
                    }
                }

                if let error = coordinationError {
                    continuation.resume(returning: "Failed to coordinate file access: \(error)")
                }
            }
        }
    }

    /// Clear all logs
    ///
    /// - Note: This operation is asynchronous and will complete on a background queue.
    ///   It is safe to call from any thread, including the logging queue itself.
    static func clearLogs(appGroupIdentifier: String = "group.org.convos.app") {
        guard let containerURL = FileManager.default.containerURL(
            forSecurityApplicationGroupIdentifier: appGroupIdentifier
        ) else {
            return
        }

        let logURL = containerURL
            .appendingPathComponent("Logs")
            .appendingPathComponent("convos.log")

        Self.queue.async {
            // use NSFileCoordinator for cross-process safe clearing
            let coordinator = NSFileCoordinator()
            var coordinationError: NSError?

            coordinator.coordinate(writingItemAt: logURL, options: [], error: &coordinationError) { coordinatedURL in
                do {
                    if FileManager.default.fileExists(atPath: coordinatedURL.path) {
                        let handle = try FileHandle(forWritingTo: coordinatedURL)
                        defer { try? handle.close() }
                        try handle.truncate(atOffset: 0)
                    }
                } catch {
                    print("Failed to clear logs during coordination: \(error)")
                }
            }

            if let error = coordinationError {
                print("Failed to coordinate file access for clearing: \(error)")
            }
        }
    }
}
