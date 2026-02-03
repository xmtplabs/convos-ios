import Foundation

/// Manages the CLI's data directory following XDG Base Directory Specification
public struct DataDirectory: Sendable {
    public let basePath: URL

    /// Resolves the data directory, preferring custom override, then XDG, then default
    public static func resolve(override: String?) -> DataDirectory {
        if let override = override {
            return DataDirectory(basePath: URL(fileURLWithPath: override, isDirectory: true))
        }

        // XDG Base Directory Specification
        if let xdgDataHome = ProcessInfo.processInfo.environment["XDG_DATA_HOME"] {
            return DataDirectory(
                basePath: URL(fileURLWithPath: xdgDataHome, isDirectory: true)
                    .appendingPathComponent("convos", isDirectory: true)
            )
        }

        // Default to ~/.local/share/convos
        let homeDir = FileManager.default.homeDirectoryForCurrentUser
        return DataDirectory(
            basePath: homeDir
                .appendingPathComponent(".local", isDirectory: true)
                .appendingPathComponent("share", isDirectory: true)
                .appendingPathComponent("convos", isDirectory: true)
        )
    }

    /// Path to the SQLite database
    public var databaseDirectoryURL: URL {
        basePath
    }

    /// Ensures the data directory exists
    public func ensureExists() throws {
        try FileManager.default.createDirectory(
            at: basePath,
            withIntermediateDirectories: true,
            attributes: nil
        )
    }
}
