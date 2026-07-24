import Foundation

/// One entry of the local-wipe manifest. Every entry's executor must be
/// idempotent: resume after a crash re-runs the whole manifest, and a second
/// full run must be a no-op.
public enum WipeManifestEntry: String, CaseIterable, Codable, Sendable {
    /// XMTP local SQLCipher database (SDK delete + file-sweep fallback).
    case xmtpLocalDatabase = "xmtp_local_database"
    /// Primary identity keychain family: primary slot, iCloud-synced backup
    /// (verified and retried), installation marker, consent backup.
    case keychainIdentityFamily = "keychain_identity_family"
    /// Address-scoped SIWE JWT keychain slot.
    case siweJwtSlot = "siwe_jwt_slot"
    /// Address-scoped cached backend account-id keychain slot.
    case siweAccountIdSlot = "siwe_account_id_slot"
    /// Legacy device-only JWT keychain slot.
    case legacyJwtSlot = "legacy_jwt_slot"
    /// Account-scoped GRDB rows.
    case databaseRows = "database_rows"
    /// StoreKit `appAccountToken` and cached subscription state in
    /// UserDefaults.
    case storeKitDefaults = "store_kit_defaults"
    /// Analytics identity reset (app-injected hook; the identity is derived
    /// from the inbox id and must not survive onto a later identity).
    case analyticsIdentity = "analytics_identity"
    /// Device-registration bookkeeping in UserDefaults.
    case deviceRegistrationDefaults = "device_registration_defaults"
    /// App-target UserDefaults carrying account/inbox-derived UI state
    /// (app-injected hook).
    case userInterfaceDefaults = "user_interface_defaults"
    /// Persistent image and attachment caches.
    case imageCaches = "image_caches"
    /// App-group pairing and agent stores (nonce ledger, pending pair
    /// requests, paired device names, agent timezone bookkeeping).
    case appGroupPairingStores = "app_group_pairing_stores"
}

/// Versioned, exhaustive inventory of local state torn down by account
/// deletion. The version is pinned into the deletion record at request time;
/// entries are additive across versions and individually idempotent.
public enum WipeManifest {
    public static let currentVersion: Int = 1

    /// Entries for a manifest version, in execution order. Unknown (older
    /// app reading a newer record) or future versions fall back to the
    /// current inventory: entries are additive and idempotent, so running a
    /// newer manifest than the record pinned is safe, while running fewer
    /// entries than the record expects is not.
    public static func entries(forVersion version: Int) -> [WipeManifestEntry] {
        switch version {
        default:
            return [
                .xmtpLocalDatabase,
                .keychainIdentityFamily,
                .siweJwtSlot,
                .siweAccountIdSlot,
                .legacyJwtSlot,
                .databaseRows,
                .storeKitDefaults,
                .analyticsIdentity,
                .deviceRegistrationDefaults,
                .userInterfaceDefaults,
                .imageCaches,
                .appGroupPairingStores,
            ]
        }
    }
}
