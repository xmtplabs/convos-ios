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
        synchronizable: Bool = true
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

    /// Re-writes the existing identity in place. The data does not change
    /// — the call's purpose is to nudge iCloud Keychain (CKKS) into
    /// scheduling a fresh sync push. Used after a successful backup write
    /// so other Apple-ID-paired devices receive the identity at the same
    /// time as the bundle. No-op when the slot is empty.
    func nudgeICloudSync() throws

    // MARK: - Two-key model (synced backup-only key)
    //
    // See docs/plans/single-inbox-two-key-model.md. The backup key is the
    // ONLY synced keychain slot in the new layout. It exists independently
    // of the identity — paired devices can have a backup key (for unsealing
    // bundles) without having an identity (those land via Restore).
    //
    // The accessors below are additive; existing callers (`save`, `load`,
    // `delete`, `nudgeICloudSync`) keep operating on the identity slot
    // until the migration flips storage modes per Step 2 of the plan.

    /// Reads the synced backup key. Returns `nil` when no backup key has
    /// been generated for this Apple ID yet (fresh device, never opened
    /// the app on any paired device, or pre-migration build).
    func loadBackupKeySync() throws -> Data?

    /// Writes the backup key to the synced slot. Overwrites any prior
    /// value — callers should not rotate this without going through the
    /// "Start fresh" path because rotating invalidates every existing
    /// bundle on iCloud.
    func saveBackupKey(_ key: Data) throws

    /// Removes the synced backup key. Use with care — this propagates
    /// via iCloud Keychain to every paired device and renders every
    /// existing bundle on iCloud unreadable.
    func deleteBackupKey() throws
}

/// Secure storage for the user's XMTP identity keys in the device keychain.
///
/// Two-key layout (see `docs/plans/single-inbox-two-key-model.md`):
///
/// - **Identity slot** (signing key + databaseKey) at service
///   `…v4-local`, account `convos-identity`, **synchronizable: false**.
///   Per-device. Encrypts the local SQLCipher XMTP DB and signs MLS
///   commits. Cannot leak to paired devices via iCloud Keychain.
///
/// - **Backup-key slot** at service `…v4-backup`, account
///   `convos-backup-key`, **synchronizable: true**. The ONLY synced
///   slot. Wraps backup bundles. Lets a paired device unseal a
///   bundle and adopt the bundled identity through Restore.
///
/// `KeychainLayoutMigrator` handles the one-shot copy from the
/// pre-refactor v3 synced-identity slot into this layout on first
/// launch with the new code path.
///
/// The slots live in the app-group keychain so the Notification
/// Service Extension can read the local identity to decrypt
/// notifications.
public final actor KeychainIdentityStore: KeychainIdentityStoreProtocol {
    // MARK: - Properties

    private let keychainAccessGroup: String

    /// Pre-refactor synced identity service — used only by
    /// `KeychainLayoutMigrator` for the v3 → v4 transition. Live code
    /// must not write here.
    static let legacySyncedIdentityService: String = "org.convos.ios.KeychainIdentityStore.v3"

    /// Per-device identity slot (synchronizable: false).
    static let localIdentityService: String = "org.convos.ios.KeychainIdentityStore.v4-local"

    /// Service name for the synced backup-key slot — distinct from the
    /// identity service so the two slots never collide in keychain
    /// queries.
    static let backupKeyService: String = "org.convos.ios.KeychainIdentityStore.v4-backup"

    /// Aliased for backwards-source-compat with prior call sites that
    /// referenced `KeychainIdentityStore.defaultService`.
    static let defaultService: String = localIdentityService

    /// Fixed account key for the stored identity.
    static let identityAccount: String = "convos-identity"

    /// Fixed account key for the synced backup-key slot.
    static let backupKeyAccount: String = "convos-backup-key"

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
        try saveData(data, with: localIdentityQuery())
        return identity
    }

    public func load() throws -> KeychainIdentity? {
        try loadSync()
    }

    public nonisolated func loadSync() throws -> KeychainIdentity? {
        do {
            let data = try Self.loadKeychainData(with: localIdentityQuery().toReadDictionary())
            return try JSONDecoder().decode(KeychainIdentity.self, from: data)
        } catch KeychainIdentityStoreError.identityNotFound {
            return nil
        }
    }

    public func delete() throws {
        try deleteData(with: localIdentityQuery())
    }

    private nonisolated func localIdentityQuery() -> KeychainQuery {
        KeychainQuery(
            account: Self.identityAccount,
            service: Self.localIdentityService,
            accessGroup: keychainAccessGroup,
            // Same accessibility as the legacy v3 slot so NSE can read
            // the identity post-first-unlock without requiring the user
            // to unlock the device first.
            accessible: kSecAttrAccessibleAfterFirstUnlock,
            // Per-device. The whole point of the two-key model.
            synchronizable: false
        )
    }

    public func nudgeICloudSync() throws {
        // Two-key model: the only synced slot is the backup key. The
        // identity slot is per-device (synchronizable: false), so
        // re-saving it does nothing for iCloud propagation. Re-write
        // the backup key instead — `saveData`'s update path is enough
        // to make CKKS schedule a sync push so paired devices receive
        // the key alongside (or before) the bundle that needs it.
        guard let key = try loadBackupKeySync() else {
            return
        }
        try saveBackupKey(key)
    }

    // MARK: - Two-key model (synced backup-only key)

    public func loadBackupKeySync() throws -> Data? {
        let query = backupKeyQuery()
        do {
            return try Self.loadKeychainData(with: query.toReadDictionary())
        } catch KeychainIdentityStoreError.identityNotFound {
            return nil
        }
    }

    public func saveBackupKey(_ key: Data) throws {
        let query = backupKeyQuery()
        try saveData(key, with: query)
    }

    public func deleteBackupKey() throws {
        let query = backupKeyQuery()
        try deleteData(with: query)
    }

    private func backupKeyQuery() -> KeychainQuery {
        KeychainQuery(
            account: Self.backupKeyAccount,
            service: Self.backupKeyService,
            accessGroup: keychainAccessGroup,
            // Same as the identity slot — needs to be readable post-
            // first-unlock so the NSE can decrypt notifications without
            // requiring the user to unlock the device first.
            accessible: kSecAttrAccessibleAfterFirstUnlock,
            synchronizable: true
        )
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
