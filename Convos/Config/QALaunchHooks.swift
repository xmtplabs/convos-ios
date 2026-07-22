import ConvosCore
import Foundation
import Security

/// Launch-time hooks for QA automation. Every hook is double-gated: it
/// only runs in non-production environments and only when its environment
/// variable is set (pass to a simulator app by exporting the
/// SIMCTL_CHILD_-prefixed name before `xcrun simctl launch`).
enum QALaunchHooks {
    static func run(environment: AppEnvironment) {
        guard !environment.isProduction else { return }
        wipePrimaryIdentityIfRequested(environment: environment)
        restampForeignBackupsIfRequested(environment: environment)
        renameForeignBackupsIfRequested(environment: environment)
        purgeForeignBackupsIfRequested(environment: environment)
        dumpBackupInventoryIfRequested(environment: environment)
    }

    /// CONVOS_QA_PURGE_FOREIGN_BACKUPS=1 deletes every synced backup that
    /// doesn't belong to the current primary identity. Cleans up the
    /// orphaned identities that the wipe/restamp hooks accumulate on a
    /// long-lived QA simulator - debris that production flows (delete
    /// all data, pairing adoption) would have removed - so the
    /// found-device prompt and the Devices screen return to a clean
    /// baseline.
    private static func purgeForeignBackupsIfRequested(environment: AppEnvironment) {
        guard ProcessInfo.processInfo.environment["CONVOS_QA_PURGE_FOREIGN_BACKUPS"] == "1" else { return }
        let primaryInboxId = loadPrimaryInboxId(environment: environment)
        var query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: KeychainIdentityStore.syncedBackupService,
            kSecAttrAccessGroup as String: environment.keychainAccessGroup,
            kSecAttrSynchronizable as String: true,
            kSecReturnAttributes as String: true,
            kSecMatchLimit as String: kSecMatchLimitAll
        ]
        var found: CFTypeRef?
        let readStatus = SecItemCopyMatching(query as CFDictionary, &found)
        query.removeValue(forKey: kSecReturnAttributes as String)
        query.removeValue(forKey: kSecMatchLimit as String)
        guard readStatus == errSecSuccess, let items = found as? [[String: Any]] else {
            QAEvent.emit(.app, "qa_purged_foreign_backups", ["status": "\(readStatus)", "count": "0"])
            return
        }
        var purged = 0
        for item in items {
            guard let account = item[kSecAttrAccount as String] as? String,
                  account != primaryInboxId else { continue }
            var deleteQuery = query
            deleteQuery[kSecAttrAccount as String] = account
            if SecItemDelete(deleteQuery as CFDictionary) == errSecSuccess { purged += 1 }
        }
        Log.info("QALaunchHooks: purged \(purged) foreign backup(s)")
        QAEvent.emit(.app, "qa_purged_foreign_backups", ["count": "\(purged)"])
    }

    /// CONVOS_QA_DUMP_BACKUP_INVENTORY=1 logs every synced backup's
    /// inboxId, deviceName, and backedUpAt plus the current primary
    /// identity, so QA and debugging can see exactly which keys the
    /// prompt and the Devices screen are working from - the keychain
    /// isn't otherwise inspectable from outside the app.
    private static func dumpBackupInventoryIfRequested(environment: AppEnvironment) {
        guard ProcessInfo.processInfo.environment["CONVOS_QA_DUMP_BACKUP_INVENTORY"] == "1" else { return }
        let primaryInboxId = loadPrimaryInboxId(environment: environment) ?? "<none>"
        Log.info("QALaunchHooks: backup inventory dump - primary inboxId=\(primaryInboxId)")
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: KeychainIdentityStore.syncedBackupService,
            kSecAttrAccessGroup as String: environment.keychainAccessGroup,
            kSecAttrSynchronizable as String: true,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitAll
        ]
        var found: CFTypeRef?
        let readStatus = SecItemCopyMatching(query as CFDictionary, &found)
        guard readStatus == errSecSuccess, let blobs = found as? [Data] else {
            Log.info("QALaunchHooks: backup inventory read failed (status=\(readStatus))")
            QAEvent.emit(.app, "qa_backup_inventory", ["status": "\(readStatus)", "count": "0"])
            return
        }
        for (index, data) in blobs.enumerated() {
            guard let json = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else { continue }
            let inboxId = json["inboxId"] as? String ?? "<?>"
            let name = json["deviceName"] as? String ?? "<unnamed>"
            let stamp = (json["backedUpAt"] as? Double).map {
                "\(Date(timeIntervalSinceReferenceDate: $0))"
            } ?? "<undated>"
            let ownership = inboxId == primaryInboxId ? "own" : "foreign"
            Log.info("QALaunchHooks: backup[\(index)] (\(ownership)) inboxId=\(inboxId) deviceName=\(name) backedUpAt=\(stamp)")
        }
        QAEvent.emit(.app, "qa_backup_inventory", ["count": "\(blobs.count)", "primary": primaryInboxId])
    }

    /// CONVOS_QA_WIPE_PRIMARY_IDENTITY=1 deletes the device-local identity
    /// slot while leaving the iCloud-synced backup slot intact. iCloud
    /// Keychain doesn't sync between simulators, so two-simulator QA seeds
    /// the "brand-new device on the same iCloud account" state by cloning
    /// the onboarded simulator (clones copy the whole keychain) and wiping
    /// the cloned primary slot with this hook on first launch. The app then
    /// registers a fresh placeholder identity and finds the original
    /// device's synced backup, which drives the first-install
    /// "Pair <device>?" prompt. See qa/tests/44-icloud-pairing-prompt.md.
    private static func wipePrimaryIdentityIfRequested(environment: AppEnvironment) {
        guard ProcessInfo.processInfo.environment["CONVOS_QA_WIPE_PRIMARY_IDENTITY"] == "1" else { return }
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: KeychainIdentityStore.defaultService,
            kSecAttrAccount as String: KeychainIdentityStore.identityAccount,
            kSecAttrAccessGroup as String: environment.keychainAccessGroup,
            kSecAttrSynchronizable as String: false
        ]
        let status = SecItemDelete(query as CFDictionary)
        Log.info("QALaunchHooks: wiped primary identity slot (status=\(status))")
        QAEvent.emit(.app, "qa_wiped_primary_identity", ["status": "\(status)"])
    }

    /// CONVOS_QA_RESTAMP_FOREIGN_BACKUPS=<seconds> rewrites the
    /// `backedUpAt` of every synced backup that doesn't belong to the
    /// current primary identity to now+<seconds>. Lets QA place a foreign
    /// backup before or after this install's own key to exercise the
    /// pairable-backup ordering rule (backups newer than the device's own
    /// key are never offered) without waiting out real clock time.
    private static func restampForeignBackupsIfRequested(environment: AppEnvironment) {
        guard let rawOffset = ProcessInfo.processInfo.environment["CONVOS_QA_RESTAMP_FOREIGN_BACKUPS"],
              let offset = TimeInterval(rawOffset) else { return }
        let newDate = Date().addingTimeInterval(offset)
        let count = mutateForeignBackups(environment: environment, eventName: "qa_restamped_foreign_backups") { json in
            json["backedUpAt"] = newDate.timeIntervalSinceReferenceDate
        }
        Log.info("QALaunchHooks: restamped \(count) foreign backup(s) to \(newDate)")
        QAEvent.emit(.app, "qa_restamped_foreign_backups", ["count": "\(count)", "offset": rawOffset])
    }

    /// CONVOS_QA_RENAME_FOREIGN_BACKUPS=<name> rewrites the deviceName of
    /// every synced backup that doesn't belong to the current primary
    /// identity. The Devices screen hides iCloud keys whose device name
    /// matches a device already listed in the paired section (an
    /// abandoned old identity of the same device); this hook gives a QA
    /// clone's foreign key a distinct name so the section's visible path
    /// can be exercised, and leaving it unset exercises the filter.
    private static func renameForeignBackupsIfRequested(environment: AppEnvironment) {
        guard let newName = ProcessInfo.processInfo.environment["CONVOS_QA_RENAME_FOREIGN_BACKUPS"],
              !newName.isEmpty else { return }
        let count = mutateForeignBackups(environment: environment, eventName: "qa_renamed_foreign_backups") { json in
            json["deviceName"] = newName
        }
        Log.info("QALaunchHooks: renamed \(count) foreign backup(s) to \(newName)")
        QAEvent.emit(.app, "qa_renamed_foreign_backups", ["count": "\(count)", "name": newName])
    }

    /// Shared enumerate-mutate-write for the foreign-backup hooks. Date
    /// fields encode as timeIntervalSinceReferenceDate doubles (JSONEncoder
    /// default, matching KeychainIdentityStore); the raw JSON is mutated so
    /// the backup's internal initializers stay internal. Returns the number
    /// of items written; a failed slot read emits the event with count=0.
    private static func mutateForeignBackups(
        environment: AppEnvironment,
        eventName: String,
        transform: (inout [String: Any]) -> Void
    ) -> Int {
        let primaryInboxId = loadPrimaryInboxId(environment: environment)
        var query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: KeychainIdentityStore.syncedBackupService,
            kSecAttrAccessGroup as String: environment.keychainAccessGroup,
            kSecAttrSynchronizable as String: true,
            kSecReturnData as String: true,
            kSecReturnAttributes as String: true,
            kSecMatchLimit as String: kSecMatchLimitAll
        ]
        var found: CFTypeRef?
        let readStatus = SecItemCopyMatching(query as CFDictionary, &found)
        query.removeValue(forKey: kSecReturnData as String)
        query.removeValue(forKey: kSecReturnAttributes as String)
        query.removeValue(forKey: kSecMatchLimit as String)
        guard readStatus == errSecSuccess, let items = found as? [[String: Any]] else {
            QAEvent.emit(.app, eventName, ["status": "\(readStatus)", "count": "0"])
            return 0
        }
        var mutated = 0
        for item in items {
            guard let account = item[kSecAttrAccount as String] as? String,
                  account != primaryInboxId,
                  let data = item[kSecValueData as String] as? Data,
                  var json = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else { continue }
            transform(&json)
            guard let updatedData = try? JSONSerialization.data(withJSONObject: json) else { continue }
            var updateQuery = query
            updateQuery[kSecAttrAccount as String] = account
            let updateStatus = SecItemUpdate(
                updateQuery as CFDictionary,
                [kSecValueData as String: updatedData] as CFDictionary
            )
            if updateStatus == errSecSuccess { mutated += 1 }
        }
        return mutated
    }

    private static func loadPrimaryInboxId(environment: AppEnvironment) -> String? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: KeychainIdentityStore.defaultService,
            kSecAttrAccount as String: KeychainIdentityStore.identityAccount,
            kSecAttrAccessGroup as String: environment.keychainAccessGroup,
            kSecAttrSynchronizable as String: false,
            kSecReturnData as String: true
        ]
        var found: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &found) == errSecSuccess,
              let data = found as? Data,
              let identity = try? JSONDecoder().decode(KeychainIdentity.self, from: data) else {
            return nil
        }
        return identity.inboxId
    }
}
