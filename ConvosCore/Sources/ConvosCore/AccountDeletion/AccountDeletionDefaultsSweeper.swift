import Foundation

/// Sweeps UserDefaults keys carrying inbox, device, or account identifiers
/// that no store clears on its own: the app-group pairing and agent stores
/// (nonce ledger bindings, pending pair requests, paired device names,
/// agent-timezone bookkeeping) and the standard-suite push catch-up
/// cursors keyed by inboxId. Prefix-based so newly added per-key entries
/// under the same namespaces are covered without a manifest change.
/// Idempotent.
enum AccountDeletionDefaultsSweeper {
    static func sweepAppGroupStores(appGroupIdentifier: String) {
        if let appGroupDefaults = UserDefaults(suiteName: appGroupIdentifier) {
            removeKeys(withPrefixes: Constant.appGroupPrefixes, from: appGroupDefaults)
        } else {
            Log.warning("AccountDeletionDefaultsSweeper: app-group suite unavailable; skipping app-group sweep")
        }
        removeKeys(withPrefixes: Constant.standardPrefixes, from: UserDefaults.standard)
    }

    private static func removeKeys(withPrefixes prefixes: [String], from defaults: UserDefaults) {
        let keys = defaults.dictionaryRepresentation().keys
        for key in keys where prefixes.contains(where: { key.hasPrefix($0) }) {
            defaults.removeObject(forKey: key)
        }
    }

    private enum Constant {
        /// Pairing stores (`convos.pairing.*`: nonce ledger v1/v2, pending
        /// join request, device names) and agent-timezone bookkeeping.
        static let appGroupPrefixes: [String] = [
            "convos.pairing.",
            "convos.agentTimezone.",
        ]
        /// Push catch-up cursors are keyed
        /// `convos.pushNotifications.lastWelcomeProcessed.<inboxId>` in the
        /// standard suite.
        static let standardPrefixes: [String] = [
            "convos.pushNotifications.",
        ]
    }
}
