import Foundation
import Security

/// One-shot migration from the pre-refactor single-synced-identity
/// keychain layout (v3) to the two-key layout (v4) — see
/// `docs/plans/single-inbox-two-key-model.md` for the full rationale.
///
/// Layout shift:
///
/// - **Before**: identity (signing + databaseKey) stored at service
///   `…v3`, account `convos-identity`, `synchronizable: true`.
/// - **After**: identity moved to service `…v4-local`,
///   `synchronizable: false`. New synced backup key generated at
///   service `…v4-backup`, account `convos-backup-key`.
///
/// The migration is idempotent — keyed on
/// `convos.keychain.layoutGeneration` in app-group UserDefaults so
/// re-runs short-circuit. Mid-run crashes are recoverable: any of
/// the four steps can be re-attempted independently and converge to
/// the same end state.
///
/// **Staged-rollout caveat**: deleting the v3 synced item propagates
/// via iCloud Keychain to every paired device. Devices on the
/// pre-migration build that next try to load the v3 slot will find
/// it gone and fall through to fresh registration, minting a new
/// identity that conflicts with the migrated layout on this device.
/// Run the migration only after every paired device the user owns
/// is on the post-refactor build. The `enabled` flag below gates
/// the destructive step (v3 deletion) behind that constraint.
public enum KeychainLayoutMigrator {
    /// Layout generation written to app-group UserDefaults once the
    /// migration has run end-to-end. Bump this string if a future
    /// migration needs to force a re-run.
    public static let layoutGenerationCurrent: String = "v4-two-key"

    /// UserDefaults key recording the layout generation this device
    /// has already migrated to.
    public static let layoutGenerationKey: String = "convos.keychain.layoutGeneration"

    /// Outcome returned to the caller for telemetry / debug surfaces.
    public enum Outcome: Equatable {
        /// Marker already at the current generation — nothing to do.
        case alreadyMigrated
        /// No legacy v3 slot found, no work needed; fresh-on-new-code
        /// path. Marker advanced.
        case freshInstall
        /// Migration ran end-to-end. Caller may want to log telemetry.
        case migrated
        /// Caller asked to skip the destructive step — partial-state.
        /// Caller should NOT proceed to the runtime store yet.
        case skippedDeletion(reason: String)
        /// A keychain read or write failed. Caller treats this as
        /// non-fatal but loud (the runtime falls back to whatever the
        /// new-layout `KeychainIdentityStore` finds, typically nil).
        case failed(reason: String)
    }

    /// Runs the migration if needed for this app-group container.
    /// Call from the app/app-clip/NSE entry point before constructing
    /// `KeychainIdentityStore` — once this returns, the runtime store's
    /// `loadSync()` is guaranteed to look at the right slot.
    @discardableResult
    public static func migrateIfNeeded(
        environment: AppEnvironment,
        enabled: Bool = true
    ) -> Outcome {
        let defaults = UserDefaults(suiteName: environment.appGroupIdentifier) ?? .standard
        return migrate(
            defaults: defaults,
            accessGroup: environment.keychainAccessGroup,
            enabled: enabled
        )
    }

    /// Testable seam — tests pass a private suite + temp-only access
    /// group so state doesn't leak across runs.
    static func migrate(
        defaults: UserDefaults,
        accessGroup: String,
        enabled: Bool
    ) -> Outcome {
        if defaults.string(forKey: layoutGenerationKey) == layoutGenerationCurrent {
            return .alreadyMigrated
        }

        let legacyData: Data?
        do {
            legacyData = try readLegacyIdentity(accessGroup: accessGroup)
        } catch {
            Log.warning("KeychainLayoutMigrator: read v3 identity failed — \(error)")
            return .failed(reason: "read v3 identity: \(error)")
        }

        guard let legacyData else {
            // Fresh install. Generate a backup key and mark migrated.
            do {
                try ensureBackupKey(accessGroup: accessGroup)
            } catch {
                Log.warning("KeychainLayoutMigrator: ensureBackupKey on fresh install failed — \(error)")
                return .failed(reason: "generate backup key on fresh install: \(error)")
            }
            defaults.set(layoutGenerationCurrent, forKey: layoutGenerationKey)
            Log.info("KeychainLayoutMigrator: fresh install — backup key generated, marker set")
            return .freshInstall
        }

        // Existing install with v3 synced identity present. Copy to
        // v4-local, generate v4-backup, then delete v3.
        do {
            try writeLocalIdentityIfMissing(legacyData, accessGroup: accessGroup)
        } catch {
            Log.warning("KeychainLayoutMigrator: writeLocalIdentityIfMissing failed — \(error)")
            return .failed(reason: "write v4-local identity: \(error)")
        }
        do {
            try ensureBackupKey(accessGroup: accessGroup)
        } catch {
            Log.warning("KeychainLayoutMigrator: ensureBackupKey during migration failed — \(error)")
            return .failed(reason: "generate backup key during migration: \(error)")
        }
        // The non-destructive half (v4-local copy + backup-key
        // generation) has now run regardless of `enabled`. The runtime
        // store can read v4-local on its first call, so the user is
        // never locked out if a caller disables the migration mid-way.
        // `enabled` only gates the destructive v3 deletion — that's
        // the step that propagates via iCloud Keychain to every paired
        // device on the Apple ID and would brick a pre-migration peer
        // that hasn't been updated yet.
        guard enabled else {
            Log.info(
                "KeychainLayoutMigrator: v4-local + backup key in place; "
                + "v3 deletion deferred (caller disabled). Marker not set; "
                + "next launch with enabled=true will finish the migration."
            )
            return .skippedDeletion(reason: "v3 deletion gated off by caller")
        }
        do {
            try deleteLegacyIdentity(accessGroup: accessGroup)
        } catch {
            Log.warning("KeychainLayoutMigrator: deleteLegacyIdentity failed — \(error)")
            return .failed(reason: "delete v3 identity: \(error)")
        }

        defaults.set(layoutGenerationCurrent, forKey: layoutGenerationKey)
        Log.info("KeychainLayoutMigrator: migrated v3 → v4 (local identity + synced backup key)")
        QAEvent.emit(.app, "keychain.migrated_to_v4_two_key")
        return .migrated
    }

    // MARK: - Legacy v3 access (synced identity)

    private static func readLegacyIdentity(accessGroup: String) throws -> Data? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrAccount as String: KeychainIdentityStore.identityAccount,
            kSecAttrService as String: KeychainIdentityStore.legacySyncedIdentityService,
            kSecAttrAccessGroup as String: accessGroup,
            kSecAttrSynchronizable as String: true,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne
        ]
        var item: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &item)
        switch status {
        case errSecSuccess:
            return item as? Data
        case errSecItemNotFound:
            return nil
        default:
            throw KeychainIdentityStoreError.keychainOperationFailed(status, "readLegacyIdentity")
        }
    }

    private static func deleteLegacyIdentity(accessGroup: String) throws {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrAccount as String: KeychainIdentityStore.identityAccount,
            kSecAttrService as String: KeychainIdentityStore.legacySyncedIdentityService,
            kSecAttrAccessGroup as String: accessGroup,
            kSecAttrSynchronizable as String: true
        ]
        let status = SecItemDelete(query as CFDictionary)
        switch status {
        case errSecSuccess, errSecItemNotFound:
            return
        default:
            throw KeychainIdentityStoreError.keychainOperationFailed(status, "deleteLegacyIdentity")
        }
    }

    // MARK: - v4-local identity (per-device)

    private static func writeLocalIdentityIfMissing(_ data: Data, accessGroup: String) throws {
        if try readLocalIdentity(accessGroup: accessGroup) != nil {
            // Already populated — leave it alone. Either a prior
            // migration attempt completed step 3 before crashing, or
            // a test hook pre-seeded it. Re-writing would be safe but
            // pointless.
            return
        }
        try writeLocalIdentity(data, accessGroup: accessGroup)
    }

    private static func readLocalIdentity(accessGroup: String) throws -> Data? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrAccount as String: KeychainIdentityStore.identityAccount,
            kSecAttrService as String: KeychainIdentityStore.localIdentityService,
            kSecAttrAccessGroup as String: accessGroup,
            kSecAttrSynchronizable as String: false,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne
        ]
        var item: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &item)
        switch status {
        case errSecSuccess:
            return item as? Data
        case errSecItemNotFound:
            return nil
        default:
            throw KeychainIdentityStoreError.keychainOperationFailed(status, "readLocalIdentity")
        }
    }

    private static func writeLocalIdentity(_ data: Data, accessGroup: String) throws {
        var attrs: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrAccount as String: KeychainIdentityStore.identityAccount,
            kSecAttrService as String: KeychainIdentityStore.localIdentityService,
            kSecAttrAccessGroup as String: accessGroup,
            kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlock,
            kSecAttrSynchronizable as String: false,
            kSecValueData as String: data
        ]
        let status = SecItemAdd(attrs as CFDictionary, nil)
        if status == errSecDuplicateItem {
            // Race: someone else wrote between our existence-check and
            // our add. Treat as success — the contents should be
            // identical (it's the same payload from v3).
            return
        }
        guard status == errSecSuccess else {
            // Drop the value before throwing so secrets don't leak
            // into the error description.
            attrs[kSecValueData as String] = nil
            throw KeychainIdentityStoreError.keychainOperationFailed(status, "writeLocalIdentity")
        }
    }

    // MARK: - v4-backup synced backup key

    private static func ensureBackupKey(accessGroup: String) throws {
        if try readBackupKey(accessGroup: accessGroup) != nil {
            return
        }
        let key = try Self.generateBackupKey()
        try writeBackupKey(key, accessGroup: accessGroup)
    }

    private static func readBackupKey(accessGroup: String) throws -> Data? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrAccount as String: KeychainIdentityStore.backupKeyAccount,
            kSecAttrService as String: KeychainIdentityStore.backupKeyService,
            kSecAttrAccessGroup as String: accessGroup,
            kSecAttrSynchronizable as String: true,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne
        ]
        var item: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &item)
        switch status {
        case errSecSuccess:
            return item as? Data
        case errSecItemNotFound:
            return nil
        default:
            throw KeychainIdentityStoreError.keychainOperationFailed(status, "readBackupKey")
        }
    }

    private static func writeBackupKey(_ key: Data, accessGroup: String) throws {
        var attrs: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrAccount as String: KeychainIdentityStore.backupKeyAccount,
            kSecAttrService as String: KeychainIdentityStore.backupKeyService,
            kSecAttrAccessGroup as String: accessGroup,
            kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlock,
            kSecAttrSynchronizable as String: true,
            kSecValueData as String: key
        ]
        let status = SecItemAdd(attrs as CFDictionary, nil)
        if status == errSecDuplicateItem {
            return
        }
        guard status == errSecSuccess else {
            attrs[kSecValueData as String] = nil
            throw KeychainIdentityStoreError.keychainOperationFailed(status, "writeBackupKey")
        }
    }

    private static func generateBackupKey() throws -> Data {
        var bytes = Data(count: 32)
        let result = bytes.withUnsafeMutableBytes { raw -> Int32 in
            guard let base = raw.baseAddress else { return errSecAllocate }
            return SecRandomCopyBytes(kSecRandomDefault, 32, base)
        }
        guard result == errSecSuccess else {
            throw KeychainIdentityStoreError.keychainOperationFailed(result, "generateBackupKey")
        }
        return bytes
    }
}
