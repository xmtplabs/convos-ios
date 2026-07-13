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
            QAEvent.emit(.app, "qa_restamped_foreign_backups", ["status": "\(readStatus)", "count": "0"])
            return
        }
        // Date fields encode as timeIntervalSinceReferenceDate doubles
        // (JSONEncoder default, matching KeychainIdentityStore); mutate the
        // raw JSON so the backup's internal initializers stay internal.
        let newDate = Date().addingTimeInterval(offset)
        var restamped = 0
        for item in items {
            guard let account = item[kSecAttrAccount as String] as? String,
                  account != primaryInboxId,
                  let data = item[kSecValueData as String] as? Data,
                  var json = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else { continue }
            json["backedUpAt"] = newDate.timeIntervalSinceReferenceDate
            guard let updatedData = try? JSONSerialization.data(withJSONObject: json) else { continue }
            var updateQuery = query
            updateQuery[kSecAttrAccount as String] = account
            let updateStatus = SecItemUpdate(
                updateQuery as CFDictionary,
                [kSecValueData as String: updatedData] as CFDictionary
            )
            if updateStatus == errSecSuccess { restamped += 1 }
        }
        Log.info("QALaunchHooks: restamped \(restamped) foreign backup(s) to \(newDate)")
        QAEvent.emit(.app, "qa_restamped_foreign_backups", ["count": "\(restamped)", "offset": rawOffset])
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
