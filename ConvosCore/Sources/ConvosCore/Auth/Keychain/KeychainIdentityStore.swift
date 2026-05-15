import CryptoKit
import Foundation
import LocalAuthentication
import Security
@preconcurrency import XMTPiOS

// MARK: - Models

protocol XMTPClientKeys {
    var signingKey: any XMTPiOS.SigningKey { get }
    var databaseKey: Data { get }
}

public struct KeychainIdentityKeys: Codable, XMTPClientKeys, Sendable {
    public let privateKey: PrivateKey
    public let databaseKey: Data

    public var signingKey: any SigningKey {
        privateKey
    }

    private enum CodingKeys: String, CodingKey {
        case privateKeyData
        case databaseKey
    }

    static func generate() throws -> KeychainIdentityKeys {
        let privateKey = try generatePrivateKey()
        let databaseKey = try generateDatabaseKey()
        return .init(privateKey: privateKey, databaseKey: databaseKey)
    }

    init(privateKey: PrivateKey, databaseKey: Data) {
        self.privateKey = privateKey
        self.databaseKey = databaseKey
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        databaseKey = try container.decode(Data.self, forKey: .databaseKey)
        let privateKeyData = try container.decode(Data.self, forKey: .privateKeyData)
        privateKey = try PrivateKey(privateKeyData)
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(databaseKey, forKey: .databaseKey)
        try container.encode(privateKey.secp256K1.bytes, forKey: .privateKeyData)
    }

    private static func generatePrivateKey() throws -> PrivateKey {
        do {
            return try PrivateKey.generate()
        } catch {
            throw KeychainIdentityStoreError.privateKeyGenerationFailed
        }
    }

    private static func generateDatabaseKey() throws -> Data {
        var key = Data(count: 32) // 256-bit key
        let status: OSStatus = try key.withUnsafeMutableBytes { bytes in
            guard let baseAddress = bytes.baseAddress else {
                throw KeychainIdentityStoreError.keychainOperationFailed(errSecUnknownFormat, "generateDatabaseKey")
            }
            return SecRandomCopyBytes(kSecRandomDefault, 32, baseAddress)
        }

        guard status == errSecSuccess else {
            throw KeychainIdentityStoreError.keychainOperationFailed(status, "generateDatabaseKey")
        }

        return key
    }
}

public struct KeychainIdentity: Codable, Sendable {
    public let inboxId: String
    public let clientId: String
    public let keys: KeychainIdentityKeys
}

// MARK: - Errors

public enum KeychainIdentityStoreError: Error, LocalizedError {
    case keychainOperationFailed(OSStatus, String)
    case dataDecodingFailed(String)
    case privateKeyGenerationFailed
    case identityNotFound(String)

    public var errorDescription: String? {
        switch self {
        case let .keychainOperationFailed(status, operation):
            return "Keychain \(operation) failed with status: \(status)"
        case let .dataDecodingFailed(context):
            return "Failed to decode data for \(context)"
        case .privateKeyGenerationFailed:
            return "Failed to generate private key"
        case let .identityNotFound(context):
            return "Identity not found: \(context)"
        }
    }
}

// MARK: - Storage Location

/// Where the on-device XMTP identity currently lives. Surfaces in the
/// debug UI so testers can verify which slot the identity is in and
/// whether iCloud-Keychain propagation has happened.
public enum IdentityStorageLocation: String, Sendable {
    /// Synchronizable slot — iCloud Keychain pushes this to every
    /// device signed in to the same Apple ID. Same wallet → same SIWE
    /// address → same backend `Account`.
    case synced
    /// Legacy device-local slot from before the sync rollout. Still
    /// readable; gets migrated to `.synced` on the next save.
    case legacy
    /// No identity stored on this device.
    case missing

    public var description: String {
        switch self {
        case .synced: return "Synced (iCloud Keychain)"
        case .legacy: return "Local-only (legacy v3)"
        case .missing: return "Not stored"
        }
    }
}

// MARK: - Keychain Operations

private struct KeychainQuery {
    let account: String
    let service: String
    let accessGroup: String
    let accessible: CFString
    let synchronizable: Bool

    init(
        account: String,
        service: String,
        accessGroup: String,
        accessible: CFString = kSecAttrAccessibleAfterFirstUnlock,
        synchronizable: Bool = false
    ) {
        self.account = account
        self.service = service
        self.accessGroup = accessGroup
        self.accessible = accessible
        self.synchronizable = synchronizable
    }

    func toDictionary() -> [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrAccount as String: account,
            kSecAttrService as String: service,
            kSecAttrAccessGroup as String: accessGroup,
            kSecAttrAccessible as String: accessible,
            kSecAttrSynchronizable as String: synchronizable
        ]
    }

    func toReadDictionary() -> [String: Any] {
        var query = toDictionary()
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        return query
    }
}

// MARK: - Keychain Identity Store

public protocol KeychainIdentityStoreProtocol: Actor {
    func generateKeys() throws -> KeychainIdentityKeys

    /// Writes (or overwrites) the identity.
    func save(inboxId: String, clientId: String, keys: KeychainIdentityKeys) throws -> KeychainIdentity

    /// Returns the identity if one exists, `nil` otherwise.
    func load() throws -> KeychainIdentity?

    /// Synchronous read of the identity slot. Safe because the keychain
    /// daemon owns all concurrency; `SecItemCopyMatching` + JSON decode
    /// touch no actor-isolated state on this type. Callers that need
    /// the identity from a synchronous context (e.g. SessionManager's
    /// service-construction path, which runs under a lock) use this
    /// directly instead of paying an actor hop.
    nonisolated func loadSync() throws -> KeychainIdentity?

    /// Removes the identity. Idempotent.
    func delete() throws
}

/// Secure storage for the user's XMTP identity keys in the app-group
/// keychain.
///
/// The identity now lives in a **synced** slot
/// (`kSecAttrSynchronizable = true`) so it follows the user across
/// every device signed in to the same Apple ID. Same key → same
/// Ethereum address → same backend `Account` via SIWE, no per-device
/// onboarding. The accessibility flag stays at
/// `kSecAttrAccessibleAfterFirstUnlock` (already sync-compatible),
/// which is also required so the Notification Service Extension can
/// read the identity post-first-unlock.
///
/// Two service identifiers exist:
///
/// - `legacyIdentityService` (`…v3`, `synchronizable: false`) — the
///   pre-sync slot. Existing installs find their identity here on the
///   first launch with this code.
/// - `syncedIdentityService` (`…v4-synced`, `synchronizable: true`) —
///   the new slot. All future writes land here; `load()` migrates
///   from legacy to synced on first read after upgrade.
///
/// Migration is lazy and idempotent: every `load()` checks the synced
/// slot first; if empty, it reads the legacy slot and (best-effort)
/// re-writes the data to the synced slot before returning it. If the
/// sync write fails (e.g. iCloud Keychain disabled), the legacy slot
/// is preserved so the user doesn't lose their identity.
///
/// See `docs/plans/icloud-keychain-identity-sync.md`.
public final actor KeychainIdentityStore: KeychainIdentityStoreProtocol {
    // MARK: - Properties

    private let keychainAccessGroup: String

    /// Pre-sync identity slot. Read-only after migration; new code
    /// must not write here.
    public static let legacyIdentityService: String = "org.convos.ios.KeychainIdentityStore.v3"

    /// Synced (iCloud Keychain) identity slot. Where every new write
    /// goes; where `load()` reads from first.
    public static let syncedIdentityService: String = "org.convos.ios.KeychainIdentityStore.v4-synced"

    /// Source-compat alias for callers that historically referenced
    /// `defaultService` to identify the live slot. Points at the
    /// synced slot now.
    public static let defaultService: String = syncedIdentityService

    /// Fixed account key shared by both slots.
    public static let identityAccount: String = "convos-identity"

    // MARK: - Initialization

    public init(accessGroup: String) {
        self.keychainAccessGroup = accessGroup
    }

    // MARK: - Public Interface

    public func generateKeys() throws -> KeychainIdentityKeys {
        try KeychainIdentityKeys.generate()
    }

    public func save(inboxId: String, clientId: String, keys: KeychainIdentityKeys) throws -> KeychainIdentity {
        let identity = KeychainIdentity(inboxId: inboxId, clientId: clientId, keys: keys)
        let data = try JSONEncoder().encode(identity)
        try saveData(data, with: syncedQuery())
        // One-shot migration: drop the legacy slot once the synced
        // write has succeeded. `?` because "no legacy item" is a
        // perfectly normal outcome on fresh installs.
        try? deleteData(with: legacyQuery())
        return identity
    }

    public func load() throws -> KeychainIdentity? {
        if let identity = try loadIdentity(from: syncedQuery()) {
            return identity
        }
        // Synced slot is empty. Check legacy and migrate inline.
        guard let pair = try loadIdentityWithBytes(from: legacyQuery()) else {
            return nil
        }
        do {
            try saveData(pair.data, with: syncedQuery())
            // Only delete the legacy slot after a successful synced
            // write — otherwise we'd risk losing the identity if
            // iCloud Keychain refused the write.
            try? deleteData(with: legacyQuery())
        } catch {
            // Sync write failed (e.g. iCloud Keychain disabled). Keep
            // the legacy slot intact so subsequent loads keep
            // returning the user's identity.
        }
        return pair.identity
    }

    public nonisolated func loadSync() throws -> KeychainIdentity? {
        // Read-only path used from contexts where actor hops aren't
        // possible (NSE, sync construction). Prefers the synced
        // slot, falls back to legacy. Does NOT migrate — the
        // actor-isolated `load()` is the one place that performs
        // the legacy→synced copy.
        if let identity = try loadIdentity(from: syncedQuery()) {
            return identity
        }
        return try loadIdentityWithBytes(from: legacyQuery())?.identity
    }

    public func delete() throws {
        // Wipe both slots so a sign-out is total — leaving the
        // legacy slot populated would resurrect the identity on the
        // next load().
        try deleteData(with: syncedQuery())
        try? deleteData(with: legacyQuery())
    }

    /// Reports where the identity (if any) currently lives. Used by
    /// debug UI to verify the iCloud Keychain rollout per device.
    /// Nonisolated + synchronous so the debug screen doesn't need to
    /// pay an actor hop just to render a status row.
    public nonisolated func currentStorageLocation() -> IdentityStorageLocation {
        if (try? loadIdentity(from: syncedQuery())) != nil {
            return .synced
        }
        if (try? loadIdentity(from: legacyQuery())) != nil {
            return .legacy
        }
        return .missing
    }

    // MARK: - Slot Helpers

    private nonisolated func syncedQuery() -> KeychainQuery {
        KeychainQuery(
            account: Self.identityAccount,
            service: Self.syncedIdentityService,
            accessGroup: keychainAccessGroup,
            accessible: kSecAttrAccessibleAfterFirstUnlock,
            synchronizable: true
        )
    }

    private nonisolated func legacyQuery() -> KeychainQuery {
        KeychainQuery(
            account: Self.identityAccount,
            service: Self.legacyIdentityService,
            accessGroup: keychainAccessGroup,
            accessible: kSecAttrAccessibleAfterFirstUnlock,
            synchronizable: false
        )
    }

    private nonisolated func loadIdentity(from query: KeychainQuery) throws -> KeychainIdentity? {
        try loadIdentityWithBytes(from: query)?.identity
    }

    private nonisolated func loadIdentityWithBytes(
        from query: KeychainQuery
    ) throws -> (identity: KeychainIdentity, data: Data)? {
        do {
            let data = try Self.loadKeychainData(with: query.toReadDictionary())
            return (try JSONDecoder().decode(KeychainIdentity.self, from: data), data)
        } catch KeychainIdentityStoreError.identityNotFound {
            return nil
        }
    }

    // MARK: - Generic Keychain Operations

    private func saveData(_ data: Data, with query: KeychainQuery) throws {
        var queryDict = query.toDictionary()
        queryDict[kSecValueData as String] = data

        let status = SecItemAdd(queryDict as CFDictionary, nil)

        if status == errSecDuplicateItem {
            let updateQuery = query.toDictionary()
            let attributesToUpdate: [String: Any] = [kSecValueData as String: data]

            let updateStatus = SecItemUpdate(updateQuery as CFDictionary, attributesToUpdate as CFDictionary)
            guard updateStatus == errSecSuccess else {
                throw KeychainIdentityStoreError.keychainOperationFailed(updateStatus, "update")
            }
        } else if status != errSecSuccess {
            throw KeychainIdentityStoreError.keychainOperationFailed(status, "add")
        }
    }

    private func loadData(with query: KeychainQuery) throws -> Data {
        try Self.loadKeychainData(with: query.toReadDictionary())
    }

    /// Static so `nonisolated` entry points can call it without an actor hop.
    private static func loadKeychainData(with query: [String: Any]) throws -> Data {
        var item: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &item)

        guard status != errSecItemNotFound else {
            throw KeychainIdentityStoreError.identityNotFound("Data not found in keychain")
        }

        guard status == errSecSuccess, let data = item as? Data else {
            throw KeychainIdentityStoreError.keychainOperationFailed(status, "load")
        }

        return data
    }

    private func deleteData(with query: KeychainQuery) throws {
        let status = SecItemDelete(query.toDictionary() as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else {
            throw KeychainIdentityStoreError.keychainOperationFailed(status, "delete")
        }
    }
}
