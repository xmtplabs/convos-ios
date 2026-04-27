import Foundation
import Security
@preconcurrency import XMTPiOS

/// One-shot removal of incompatible on-disk state at app launch.
///
/// A persistent schema-generation marker in the app-group UserDefaults records
/// whether the current install has already been wiped, so the routine runs at
/// most once per install generation. Bump `currentGeneration` to force a
/// re-wipe on next launch when the on-disk format changes incompatibly.
public enum LegacyDataWipe {
    /// Current schema generation. Bump when a schema change requires a wipe.
    public static let currentGeneration: String = "v1-single-inbox"

    /// Generation strings that are functionally equivalent to
    /// `currentGeneration` and must NOT trigger a wipe. Bumping the
    /// canonical name (e.g. for cosmetic alignment with the GRDB
    /// migration identifier) would otherwise wipe every install whose
    /// stored marker is one of these — and on the single-inbox file
    /// layout the wipe deletes the active `xmtp-*.db3` files, which is
    /// catastrophic. Add the previous canonical name here when renaming.
    private static let compatibleGenerations: Set<String> = [
        currentGeneration,
        "single-inbox-v2"
    ]

    private static let schemaGenerationKey: String = "convos.schemaGeneration"

    /// Checks whether a wipe is needed for the current install and runs it before
    /// the GRDB database is opened. Writes the new generation marker when the
    /// on-disk state is clean after the wipe attempt. No-ops for fresh installs
    /// (no legacy markers present) and for installs already on the current
    /// generation.
    static func runIfNeeded(environment: AppEnvironment) {
        runIfNeeded(
            defaults: UserDefaults(suiteName: environment.appGroupIdentifier) ?? .standard,
            databasesDirectory: environment.defaultDatabasesDirectoryURL,
            legacyKeychainAccessGroup: environment.appGroupIdentifier
        )
    }

    /// Testable core with all environment lookups lifted to parameters. Tests
    /// pass a private UserDefaults suite + a temp directory so they don't
    /// collide with the app-group defaults or the real database directory.
    static func runIfNeeded(
        defaults: UserDefaults,
        databasesDirectory: URL,
        legacyKeychainAccessGroup: String
    ) {
        let stored = defaults.string(forKey: schemaGenerationKey)

        if let stored, compatibleGenerations.contains(stored) {
            // Bring the marker forward to the current canonical name so
            // future launches short-circuit on the cheap equality check.
            if stored != currentGeneration {
                defaults.set(currentGeneration, forKey: schemaGenerationKey)
            }
            return
        }

        let hasLegacyArtifacts = detectLegacyArtifacts(databasesDirectory: databasesDirectory)

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
        wipeLegacyKeychainItems(accessGroup: legacyKeychainAccessGroup)
        wipeDatabases(at: databasesDirectory)

        let artifactsRemaining = detectLegacyArtifacts(databasesDirectory: databasesDirectory)
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
    ///
    /// Matches any `xmtp-*` file in the databases directory. XMTPiOS names
    /// its SQLite files `xmtp-<gRPC-host>-<hash>.db3` (e.g.
    /// `xmtp-grpc.dev.xmtp.network-abc123.db3`); the previous check looked
    /// for `xmtp-{env}-` (e.g. `xmtp-dev-`), which the SDK never produces,
    /// so upgrade-wipe silently no-opped and orphaned db3 files
    /// accumulated forever. The broad `xmtp-` match is safe because the
    /// schema-generation marker gates this routine — on fresh installs the
    /// directory is empty and the xmtp-prefix check returns false; on the
    /// first upgrade launch any pre-existing xmtp-* files get swept; on
    /// every subsequent launch the marker short-circuits before the scan.
    private static func detectLegacyArtifacts(databasesDirectory: URL) -> Bool {
        let fileManager = FileManager.default
        let grdbURL = databasesDirectory.appendingPathComponent("convos.sqlite")
        if fileManager.fileExists(atPath: grdbURL.path) {
            return true
        }

        guard let entries = try? fileManager.contentsOfDirectory(
            at: databasesDirectory,
            includingPropertiesForKeys: nil
        ) else {
            return false
        }

        return entries.contains { url in
            url.lastPathComponent.hasPrefix("xmtp-")
        }
    }

    /// Best-effort deletion of legacy GRDB + XMTP database files. Success
    /// is measured after the fact via `detectLegacyArtifacts` on the same
    /// directory, so we don't thread a boolean result back through.
    ///
    /// Removes every `xmtp-*` file — see `detectLegacyArtifacts` for why
    /// the env-specific prefix the SDK doesn't produce was wrong. Includes
    /// the `.db3`, `.db3-shm`, `.db3-wal`, and `.db3.sqlcipher_salt`
    /// sidecars XMTPiOS writes alongside the main database.
    private static func wipeDatabases(at directory: URL) {
        let fileManager = FileManager.default

        let grdbFiles = [
            "convos.sqlite",
            "convos.sqlite-shm",
            "convos.sqlite-wal"
        ]
        for filename in grdbFiles {
            removeItem(at: directory.appendingPathComponent(filename), fileManager: fileManager)
        }

        if let entries = try? fileManager.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: nil
        ) {
            for url in entries where url.lastPathComponent.hasPrefix("xmtp-") {
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
}
