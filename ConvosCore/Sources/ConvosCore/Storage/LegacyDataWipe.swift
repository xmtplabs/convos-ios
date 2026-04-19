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
    /// the GRDB database is opened. Writes the new generation marker when the
    /// on-disk state is clean after the wipe attempt. No-ops for fresh installs
    /// (no legacy markers present) and for installs already on the current
    /// generation.
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

        // Two classes of legacy state with different severity:
        //
        // 1. Legacy keychain items (v1/v2 service names) — cosmetic.
        //    The current KeychainIdentityStore (v3) ignores them; stray
        //    entries don't affect behavior. Failures here are logged but
        //    never gate the generation marker.
        //
        // 2. Legacy DB artifacts (convos.sqlite + xmtp-*) — fatal.
        //    The new schema can't open them. If they remain after the
        //    wipe attempt the app will crash trying to open the DB, so
        //    we withhold the generation marker and let the next launch
        //    retry. Verification is done by re-running
        //    `detectLegacyArtifacts` against the on-disk state — bool
        //    return values from the wipe helpers would just be a cache
        //    of that same check.
        wipeLegacyKeychainItems(accessGroup: environment.appGroupIdentifier)
        wipeDatabases(at: databasesDirectory, environment: environment)

        let artifactsRemaining = detectLegacyArtifacts(
            databasesDirectory: databasesDirectory,
            environment: environment
        )
        if artifactsRemaining {
            Log.error("LegacyDataWipe: database artifacts still present after wipe attempt. " +
                      "Generation marker NOT set; will retry on next launch.")
        } else {
            defaults.set(currentGeneration, forKey: schemaGenerationKey)
        }
    }

    /// Removes keychain items registered under earlier service names. The
    /// current store (`KeychainIdentityStore.defaultService`) ignores these,
    /// so residual items are harmless cruft — logged on failure but not
    /// treated as a blocker.
    private static func wipeLegacyKeychainItems(accessGroup: String) {
        let legacyServices = [
            "org.convos.ios.KeychainIdentityStore.v2",
            "org.convos.ios.KeychainIdentityStore.v1"
        ]
        for service in legacyServices {
            let query: [String: Any] = [
                kSecClass as String: kSecClassGenericPassword,
                kSecAttrService as String: service,
                kSecAttrAccessGroup as String: accessGroup,
                kSecAttrSynchronizable as String: kSecAttrSynchronizableAny
            ]
            let status = SecItemDelete(query as CFDictionary)
            switch status {
            case errSecSuccess:
                Log.debug("LegacyDataWipe: removed legacy keychain items for service \(service)")
            case errSecItemNotFound:
                // Nothing to clean up — expected for anyone installing fresh on this generation.
                break
            case errSecAuthFailed:
                // Keychain is locked (not yet unlocked post-boot). Transient — will retry next launch.
                Log.warning("LegacyDataWipe: keychain locked while removing \(service); will retry next launch (cosmetic — not blocking)")
            default:
                Log.error("LegacyDataWipe: failed to remove legacy keychain items for service \(service), status=\(status) (cosmetic — not blocking)")
            }
        }
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

    /// Best-effort deletion of legacy GRDB + XMTP database files. Success
    /// is measured after the fact via `detectLegacyArtifacts` on the same
    /// directory, so we don't thread a boolean result back through.
    private static func wipeDatabases(at directory: URL, environment: AppEnvironment) {
        let fileManager = FileManager.default

        let grdbFiles = [
            "convos.sqlite",
            "convos.sqlite-shm",
            "convos.sqlite-wal"
        ]
        for filename in grdbFiles {
            removeItem(at: directory.appendingPathComponent(filename), fileManager: fileManager)
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
