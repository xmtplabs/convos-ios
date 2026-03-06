import ConvosCore
import Foundation
import XMTPiOS

enum DebugLogExporter {
    static func exportAllLogs(
        environment: AppEnvironment,
        conversationDebugInfo: URL? = nil
    ) throws -> URL {
        let stagingDir = try createStagingDirectory()
        defer { try? FileManager.default.removeItem(at: stagingDir) }

        stageAppLog(to: stagingDir, environment: environment)
        stageXMTPLogs(to: stagingDir, environment: environment)

        if let conversationDebugInfo {
            let dest = stagingDir.appendingPathComponent(conversationDebugInfo.lastPathComponent)
            if (try? FileManager.default.copyItem(at: conversationDebugInfo, to: dest)) == nil {
                Log.warning("Failed to stage conversation debug info")
            }
        }

        return try zipDirectory(stagingDir)
    }

    private static func stageAppLog(to directory: URL, environment: AppEnvironment) {
        guard let containerURL = FileManager.default.containerURL(
            forSecurityApplicationGroupIdentifier: environment.appGroupIdentifier
        ) else { return }

        let logURL = containerURL
            .appendingPathComponent("Logs")
            .appendingPathComponent("convos.log")

        if FileManager.default.fileExists(atPath: logURL.path) {
            let dest = directory.appendingPathComponent("convos-app.log")
            if (try? FileManager.default.copyItem(at: logURL, to: dest)) == nil {
                Log.warning("Failed to stage app log")
            }
        }

        let info = """
        Convos Debug Information

        Bundle ID: \(Bundle.main.bundleIdentifier ?? "Unknown")
        Version: \(Bundle.appVersion)
        Build: \(Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? "Unknown")
        Environment: \(environment)
        Date: \(Date())
        """
        let infoURL = directory.appendingPathComponent("convos-info.txt")
        try? info.write(to: infoURL, atomically: true, encoding: .utf8)
    }

    private static func stageXMTPLogs(to directory: URL, environment: AppEnvironment) {
        let logDir = environment.defaultXMTPLogsDirectoryURL
        let filePaths = Client.getXMTPLogFilePaths(customLogDirectory: logDir)
        guard !filePaths.isEmpty else { return }

        let xmtpDir = directory.appendingPathComponent("xmtp")
        try? FileManager.default.createDirectory(at: xmtpDir, withIntermediateDirectories: true)

        for path in filePaths {
            let url = URL(fileURLWithPath: path)
            guard FileManager.default.fileExists(atPath: path) else { continue }
            let dest = xmtpDir.appendingPathComponent(url.lastPathComponent)
            if (try? FileManager.default.copyItem(at: url, to: dest)) == nil {
                Log.warning("Failed to stage XMTP log: \(url.lastPathComponent)")
            }
        }
    }

    private static func zipDirectory(_ directory: URL) throws -> URL {
        let timestamp = DateFormatter.logTimestamp.string(from: Date())
        let outputURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("convos-logs-\(timestamp).zip")
        try? FileManager.default.removeItem(at: outputURL)

        var coordinatorError: NSError?
        var resultURL: URL?
        var innerError: Error?

        let coordinator = NSFileCoordinator()
        coordinator.coordinate(
            readingItemAt: directory,
            options: .forUploading,
            error: &coordinatorError
        ) { zipURL in
            do {
                try FileManager.default.moveItem(at: zipURL, to: outputURL)
                resultURL = outputURL
            } catch {
                innerError = error
            }
        }

        if let coordinatorError { throw coordinatorError }
        if let innerError { throw innerError }
        guard let resultURL else { throw CocoaError(.fileNoSuchFile) }
        return resultURL
    }

    private static func createStagingDirectory() throws -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("convos-logs-\(UUID().uuidString.prefix(8))")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }
}

private extension DateFormatter {
    static let logTimestamp: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd-HHmmss"
        return f
    }()
}
