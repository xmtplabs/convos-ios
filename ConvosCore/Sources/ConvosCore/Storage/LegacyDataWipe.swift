import Foundation
import Security
@preconcurrency import XMTPiOS

/// One-shot removal of incompatible on-disk state at app launch.
///
/// A persistent schema-generation marker in the app-group UserDefaults records
/// whether the current install has already been wiped, so the routine runs at
/// most once per install generation. Bump `currentGeneration` to force a
/// re-wipe on next launch when the on-disk format changes incompatibly.
///
/// On a generation bump the wipe sweeps **everything** the app persists across
/// launches: GRDB DB files, libxmtp SQLCipher DBs, every historical keychain
/// identity slot (including `kSecAttrSynchronizable: true` copies that survive
/// in iCloud Keychain on every paired device), the JWT keychain service, and
/// the per-device UserDefaults markers used by push registration / IDFV
/// fallback. The intent is that after a generation bump every user starts in
/// a totally fresh state — no carry-over of identity, conversation, or device
/// registration state from any prior build.
enum LegacyDataWipe {
    /// Current schema generation. Bump when a schema change requires a wipe.
    /// Historical values: "single-inbox-v1", "single-inbox-v2", "v1-single-inbox".
    static let currentGeneration: String = "convos-v2"

    private static let schemaGenerationKey: String = "convos.schemaGeneration"

    /// Active GRDB DB filename produced by `DatabaseManager`. The legacy
    /// `convos.sqlite` family is also swept below for installs that pre-date
    /// the rename.
    private static let activeGRDBFilenames: [String] = [
        "convos-single-inbox.sqlite",
        "convos-single-inbox.sqlite-shm",
        "convos-single-inbox.sqlite-wal"
    ]

    /// Pre-rename GRDB filename family.
    private static let legacyGRDBFilenames: [String] = [
        "convos.sqlite",
        "convos.sqlite-shm",
        "convos.sqlite-wal"
    ]

    /// Every keychain `service` value the app has ever used for the identity
    /// slot. Swept on a generation bump with `kSecAttrSynchronizableAny` so
    /// both the local and the iCloud-synced copies of each get removed.
    private static let identityKeychainServices: [String] = [
        "org.convos.ios.KeychainIdentityStore.v3",
        "org.convos.ios.KeychainIdentityStore.v4-local",
        "org.convos.ios.KeychainIdentityStore.v2",
        "org.convos.ios.KeychainIdentityStore.v1"
    ]

    /// Keychain `service` for the JWT/API-token store (`KeychainService`).
    private static let jwtKeychainService: String = "org.convos.ios.KeychainService.v2"

    /// `UserDefaults.standard` keys (or key prefixes) the app persists across
    /// launches and that we want gone on a generation bump.
    private static let standardDefaultsKeyPrefixes: [String] = [
        "hasRegisteredDevice_",
        "lastRegisteredDevicePushToken_"
    ]
    private static let standardDefaultsKeys: [String] = [
        "convos_fallback_device_id",
        "GACAppCheckDebugToken"
    ]

    /// Checks whether a wipe is needed for the current install and runs it before
    /// the GRDB database is opened. Writes the new generation marker when the
    /// on-disk state is clean after the wipe attempt.
    static func runIfNeeded(environment: AppEnvironment) {
        runIfNeeded(
            defaults: UserDefaults(suiteName: environment.appGroupIdentifier) ?? .standard,
            standardDefaults: .standard,
            databasesDirectory: environment.defaultDatabasesDirectoryURL,
            legacyKeychainAccessGroup: environment.appGroupIdentifier
        )
    }

    /// Testable core with all environment lookups lifted to parameters. Tests
    /// pass private UserDefaults suites + a temp directory so they don't
    /// collide with the app-group defaults or the real database directory.
    static func runIfNeeded(
        defaults: UserDefaults,
        standardDefaults: UserDefaults,
        databasesDirectory: URL,
        legacyKeychainAccessGroup: String
    ) {
        let stored = defaults.string(forKey: schemaGenerationKey)

        if stored == currentGeneration {
            return
        }

        Log.info("LegacyDataWipe: bumping to \(currentGeneration) (storedGeneration=\(stored ?? "nil")), wiping all persistent state")

        // Severity tiers:
        //
        // 1. Keychain items + UserDefaults markers — best-effort.
        //    Failures are logged but do not gate the generation marker:
        //    keychain can be transiently locked at first-unlock, and
        //    UserDefaults removeObject doesn't surface errors. Re-running
        //    next launch only happens if the DB wipe also failed.
        //
        // 2. DB files (GRDB + xmtp-*) — fatal if leftover.
        //    The new schema can't open them. If they remain after the
        //    wipe attempt we withhold the generation marker so the next
        //    launch retries the whole routine.
        wipeIdentityKeychainItems(accessGroup: legacyKeychainAccessGroup)
        wipeJWTKeychainItems(accessGroup: legacyKeychainAccessGroup)
        wipeStandardDefaultsMarkers(defaults: standardDefaults)
        wipeDatabases(at: databasesDirectory)

        let artifactsRemaining = detectLegacyArtifacts(databasesDirectory: databasesDirectory)
        if artifactsRemaining {
            Log.error("LegacyDataWipe: database artifacts still present after wipe attempt. " +
                      "Generation marker NOT set; will retry on next launch.")
        } else {
            defaults.set(currentGeneration, forKey: schemaGenerationKey)
        }
    }

    /// Removes keychain identity items across every historical `service`
    /// value, including the current one. Uses `kSecAttrSynchronizableAny`
    /// so it sweeps both the local and the iCloud-synced copies of each
    /// slot — important because the app shipped with `synchronizable: true`
    /// for many builds, leaving stranded copies on every paired device.
    /// Cosmetic — failures are logged but don't gate the generation marker.
    private static func wipeIdentityKeychainItems(accessGroup: String) {
        for service in identityKeychainServices {
            deleteKeychainItems(service: service, accessGroup: accessGroup)
        }
    }

    /// Removes JWT/API-token keychain items written by `KeychainService`.
    /// Same access group as the identity store; different service value.
    private static func wipeJWTKeychainItems(accessGroup: String) {
        deleteKeychainItems(service: jwtKeychainService, accessGroup: accessGroup)
    }

    private static func deleteKeychainItems(service: String, accessGroup: String) {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccessGroup as String: accessGroup,
            kSecAttrSynchronizable as String: kSecAttrSynchronizableAny
        ]
        let status = SecItemDelete(query as CFDictionary)
        switch status {
        case errSecSuccess:
            Log.debug("LegacyDataWipe: removed keychain items for service \(service)")
        case errSecItemNotFound:
            // Nothing to clean up — expected for fresh installs and for
            // services this device never wrote.
            break
        case errSecAuthFailed:
            // Keychain locked (not yet unlocked post-boot). Transient — will retry next launch.
            Log.warning("LegacyDataWipe: keychain locked while removing \(service); will retry next launch (cosmetic — not blocking)")
        default:
            Log.error("LegacyDataWipe: failed to remove keychain items for service \(service), status=\(status) (cosmetic — not blocking)")
        }
    }

    /// Removes per-device push-registration markers and the IDFV fallback
    /// UUID from `UserDefaults.standard`. Iterates the dictionary
    /// representation because the app uses dynamic per-device-id keys.
    private static func wipeStandardDefaultsMarkers(defaults: UserDefaults) {
        let allKeys = Array(defaults.dictionaryRepresentation().keys)
        for key in allKeys {
            let matchesPrefix = standardDefaultsKeyPrefixes.contains { key.hasPrefix($0) }
            let matchesExact = standardDefaultsKeys.contains(key)
            if matchesPrefix || matchesExact {
                defaults.removeObject(forKey: key)
                Log.debug("LegacyDataWipe: cleared UserDefaults key \(key)")
            }
        }
    }

    /// Returns `true` if the install has on-disk DB state that the new
    /// schema can't open. Used after the wipe to decide whether to set the
    /// generation marker. Matches the active GRDB filename, the legacy
    /// GRDB filename, and any `xmtp-*` file XMTPiOS produces
    /// (`xmtp-<gRPC-host>-<hash>.db3` and sidecars).
    private static func detectLegacyArtifacts(databasesDirectory: URL) -> Bool {
        let fileManager = FileManager.default

        for filename in activeGRDBFilenames + legacyGRDBFilenames {
            let url = databasesDirectory.appendingPathComponent(filename)
            if fileManager.fileExists(atPath: url.path) {
                return true
            }
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

    /// Best-effort deletion of GRDB + XMTP database files. Success is
    /// measured after the fact via `detectLegacyArtifacts`, so we don't
    /// thread a boolean result back through. Removes both the active and
    /// legacy GRDB filename families plus every `xmtp-*` file (the SDK
    /// writes `.db3`, `.db3-shm`, `.db3-wal`, and `.db3.sqlcipher_salt`
    /// alongside the main database).
    private static func wipeDatabases(at directory: URL) {
        let fileManager = FileManager.default

        for filename in activeGRDBFilenames + legacyGRDBFilenames {
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
