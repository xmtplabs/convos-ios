import Foundation
import Security
@preconcurrency import XMTPiOS

/// One-shot removal of incompatible on-disk state at app launch.
///
/// A persistent schema-generation marker in the app-group UserDefaults records
/// whether the current install has already been wiped, so the routine runs at
/// most once per install generation. Bump `currentGeneration` to force a
/// re-wipe on next launch when the on-disk format changes incompatibly.
enum LegacyDataWipe {
    /// Current schema generation. Bump when a schema change requires a wipe.
    static let currentGeneration: String = "single-inbox-v2"

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
        let dbWipeOK = wipeDatabases(at: databasesDirectory, environment: environment)
        let keychainWipeOK = wipeLegacyKeychainItems(accessGroup: environment.appGroupIdentifier)

        // Only mark the install as upgraded when both wipe phases succeeded.
        // A partial wipe that claimed success would prevent retry on the next
        // launch and leave the migrator opening a database in an
        // incompatible shape.
        if dbWipeOK && keychainWipeOK {
            defaults.set(currentGeneration, forKey: schemaGenerationKey)
        } else {
            Log.error("LegacyDataWipe: one or more wipe phases failed (db=\(dbWipeOK), keychain=\(keychainWipeOK)). " +
                      "Generation marker NOT set; will retry on next launch.")
        }
    }

    /// Removes keychain items registered under earlier service names. The
    /// current store (`KeychainIdentityStore.defaultService`) ignores these,
    /// but they linger in the keychain otherwise. Returns `false` if any
    /// delete failed for a reason other than "not found" so the caller can
    /// withhold the generation marker.
    private static func wipeLegacyKeychainItems(accessGroup: String) -> Bool {
        let legacyServices = [
            "org.convos.ios.KeychainIdentityStore.v2",
            "org.convos.ios.KeychainIdentityStore.v1"
        ]
        var allOK = true
        for service in legacyServices {
            let query: [String: Any] = [
                kSecClass as String: kSecClassGenericPassword,
                kSecAttrService as String: service,
                kSecAttrAccessGroup as String: accessGroup,
                kSecAttrSynchronizable as String: kSecAttrSynchronizableAny
            ]
            let status = SecItemDelete(query as CFDictionary)
            if status == errSecSuccess {
                Log.debug("LegacyDataWipe: removed legacy keychain items for service \(service)")
            } else if status != errSecItemNotFound {
                Log.error("LegacyDataWipe: failed to remove legacy keychain items for service \(service), status=\(status)")
                allOK = false
            }
        }
        return allOK
    }

    /// Returns `true` if the install has on-disk state from an earlier
    /// schema. Used on first launch when the generation marker is absent to
    /// distinguish a fresh install (nothing to wipe) from an upgrade.
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

    /// Returns `false` if any file's delete attempt failed (file existed and
    /// removeItem threw). Missing files are not failures.
    private static func wipeDatabases(at directory: URL, environment: AppEnvironment) -> Bool {
        let fileManager = FileManager.default
        var allOK = true

        let grdbFiles = [
            "convos.sqlite",
            "convos.sqlite-shm",
            "convos.sqlite-wal"
        ]
        for filename in grdbFiles {
            let url = directory.appendingPathComponent(filename)
            if !removeItem(at: url, fileManager: fileManager) {
                allOK = false
            }
        }

        let envPrefix = xmtpEnvPrefix(for: environment)
        let xmtpPrefix = "xmtp-\(envPrefix)-"
        if let entries = try? fileManager.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: nil
        ) {
            for url in entries where url.lastPathComponent.hasPrefix(xmtpPrefix) {
                if !removeItem(at: url, fileManager: fileManager) {
                    allOK = false
                }
            }
        }

        return allOK
    }

    /// Returns `true` if the file was removed successfully or did not exist.
    /// Returns `false` only when the file existed and removal threw.
    private static func removeItem(at url: URL, fileManager: FileManager) -> Bool {
        guard fileManager.fileExists(atPath: url.path) else { return true }
        do {
            try fileManager.removeItem(at: url)
            Log.debug("LegacyDataWipe: removed \(url.lastPathComponent)")
            return true
        } catch {
            Log.error("LegacyDataWipe: failed to remove \(url.lastPathComponent): \(error)")
            return false
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
