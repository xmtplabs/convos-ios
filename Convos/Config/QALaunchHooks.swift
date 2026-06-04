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
}
