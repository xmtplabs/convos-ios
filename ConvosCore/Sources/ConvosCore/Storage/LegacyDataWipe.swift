import Foundation
@preconcurrency import XMTPiOS

/// One-shot detection and removal of pre-single-inbox data at app launch.
///
/// The single-inbox identity refactor intentionally ships without a migration path:
/// any install carrying per-conversation identities, the old GRDB schema, or XMTP
/// databases from a prior version needs to be wiped clean before the app can boot
/// into the new model. A persistent schema-generation marker in the app-group
/// UserDefaults records whether the current install has already been wiped, so the
/// routine runs at most once per install generation.
enum LegacyDataWipe {
    /// Current schema generation. Bump when a future refactor needs another wipe.
    static let currentGeneration: String = "single-inbox-v1"

    private static let schemaGenerationKey: String = "convos.schemaGeneration"

    /// Checks whether a wipe is needed for the current install and runs it before
    /// the GRDB database is opened. Writes the new generation marker on success.
    /// No-ops for fresh installs (no legacy markers present) and for installs
    /// already on the current generation.
    static func runIfNeeded(environment: AppEnvironment) {
        let defaults = UserDefaults(suiteName: environment.appGroupIdentifier) ?? .standard
        let stored = defaults.string(forKey: schemaGenerationKey)

        if stored == currentGeneration {
            return
        }

        let databasesDirectory = environment.defaultDatabasesDirectoryURL
        let hasLegacyArtifacts = detectLegacyArtifacts(
            databasesDirectory: databasesDirectory,
            environment: environment
        )

        if stored == nil && !hasLegacyArtifacts {
            // Fresh install: nothing to wipe. Record the marker and move on.
            defaults.set(currentGeneration, forKey: schemaGenerationKey)
            return
        }

        Log.info("LegacyDataWipe: detected legacy data (storedGeneration=\(stored ?? "nil")), wiping before migration")
        wipeDatabases(at: databasesDirectory, environment: environment)
        defaults.set(currentGeneration, forKey: schemaGenerationKey)
    }

    /// Returns `true` if the install appears to carry pre-single-inbox state.
    /// Used on first launch when the schema-generation marker is absent to
    /// distinguish a fresh install (no legacy, just mark) from an upgrade
    /// (legacy present, wipe).
    private static func detectLegacyArtifacts(
        databasesDirectory: URL,
        environment: AppEnvironment
    ) -> Bool {
        let fileManager = FileManager.default
        let grdbURL = databasesDirectory.appendingPathComponent("convos.sqlite")
        if fileManager.fileExists(atPath: grdbURL.path) {
            return true
        }

        let envPrefix = xmtpEnvPrefix(for: environment)
        guard let entries = try? fileManager.contentsOfDirectory(
            at: databasesDirectory,
            includingPropertiesForKeys: nil
        ) else {
            return false
        }

        let xmtpPrefix = "xmtp-\(envPrefix)-"
        return entries.contains { url in
            url.lastPathComponent.hasPrefix(xmtpPrefix)
        }
    }

    private static func wipeDatabases(at directory: URL, environment: AppEnvironment) {
        let fileManager = FileManager.default

        let grdbFiles = [
            "convos.sqlite",
            "convos.sqlite-shm",
            "convos.sqlite-wal"
        ]
        for filename in grdbFiles {
            let url = directory.appendingPathComponent(filename)
            removeItem(at: url, fileManager: fileManager)
        }

        let envPrefix = xmtpEnvPrefix(for: environment)
        let xmtpPrefix = "xmtp-\(envPrefix)-"
        if let entries = try? fileManager.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: nil
        ) {
            for url in entries where url.lastPathComponent.hasPrefix(xmtpPrefix) {
                removeItem(at: url, fileManager: fileManager)
            }
        }
    }

    private static func removeItem(at url: URL, fileManager: FileManager) {
        guard fileManager.fileExists(atPath: url.path) else { return }
        do {
            try fileManager.removeItem(at: url)
            Log.debug("LegacyDataWipe: removed \(url.lastPathComponent)")
        } catch {
            Log.error("LegacyDataWipe: failed to remove \(url.lastPathComponent): \(error)")
        }
    }

    private static func xmtpEnvPrefix(for environment: AppEnvironment) -> String {
        switch environment.xmtpEnv {
        case .local:
            return "localhost"
        case .dev:
            return "dev"
        case .production:
            return "production"
        @unknown default:
            return "unknown"
        }
    }
}
