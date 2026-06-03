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

/// Identity material mirrored into the iCloud-synced backup slot.
/// Deliberately excludes the SQLCipher database key: it only decrypts
/// this device's local database, which never leaves the device, so
/// escrowing it in iCloud would add exposure without recovery value.
/// A recovering device generates a fresh database key.
public struct KeychainIdentityBackup: Codable, Sendable {
    public let inboxId: String
    public let clientId: String
    public let privateKey: PrivateKey

    private enum CodingKeys: String, CodingKey {
        case inboxId
        case clientId
        case privateKeyData
    }

    init(identity: KeychainIdentity) {
        inboxId = identity.inboxId
        clientId = identity.clientId
        privateKey = identity.keys.privateKey
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        inboxId = try container.decode(String.self, forKey: .inboxId)
        clientId = try container.decode(String.self, forKey: .clientId)
        let privateKeyData = try container.decode(Data.self, forKey: .privateKeyData)
        privateKey = try PrivateKey(privateKeyData)
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(inboxId, forKey: .inboxId)
        try container.encode(clientId, forKey: .clientId)
        try container.encode(privateKey.secp256K1.bytes, forKey: .privateKeyData)
    }
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

    /// Returns every identity present in the iCloud-synced backup slot.
    /// Each identity is backed up under its own account (keyed by
    /// inboxId), so unpaired identities on devices sharing an iCloud
    /// account coexist instead of overwriting each other. Nothing reads
    /// this during normal operation; it exists for an explicit recovery
    /// flow after the user loses their device.
    func loadSyncedBackups() throws -> [KeychainIdentityBackup]

    /// Mirrors the primary identity into the synced backup slot when its
    /// backup is missing. Installs that registered before the backup
    /// slot existed only ever wrote the primary slot; calling this on
    /// authorize makes them recoverable too. Best-effort: failures are
    /// logged, never thrown.
    func backfillSyncedBackupIfNeeded()

    /// Removes the identity from the primary slot and its mirror from
    /// the synced backup slot. Backups belonging to other identities are
    /// left untouched. Idempotent.
    func delete() throws
}

/// Secure storage for the user's XMTP identity keys in the device keychain.
///
/// The app holds one identity per install, kept in two keychain slots:
///
/// - The primary slot is device-local (`kSecAttrSynchronizable = false` +
///   `kSecAttrAccessibleAfterFirstUnlock`) and is the only slot the app
///   reads at runtime. Device sync stays an explicit user action: another
///   device never picks up the identity just by sharing an iCloud account.
/// - The synced backup slot (`kSecAttrSynchronizable = true`, separate
///   service) mirrors the identity (minus the database key, see
///   `KeychainIdentityBackup`) into iCloud Keychain so the user can
///   recover after losing the device. Each identity is backed up under its
///   own account (keyed by inboxId), so unpaired identities on devices
///   sharing an iCloud account back up side by side instead of overwriting
///   each other. Only an explicit recovery flow reads it.
///
/// When a save displaces a different identity (e.g. pairing overwrites the
/// fresh-install placeholder), the displaced identity's backup is removed:
/// its key material would otherwise sit in iCloud forever with no owner.
///
/// Surfaces that must not escrow keys (the App Clip, whose auto-registered
/// identity the user never opted to back up) construct the store with
/// `syncedBackupEnabled: false`, which disables the mirror and backfill
/// write paths; the full app backfills the identity on first authorize.
///
/// Both slots live in the app-group keychain so the Notification Service
/// Extension can read the primary slot.
public final actor KeychainIdentityStore: KeychainIdentityStoreProtocol {
    // MARK: - Properties

    private let keychainService: String
    private let keychainAccessGroup: String
    private let syncedBackupEnabled: Bool

    public static let defaultService: String = "org.convos.ios.KeychainIdentityStore.v3"

    /// Service for the iCloud-synced backup slot. Distinct from
    /// `defaultService` so queries can never confuse the two slots, and
    /// listed in `LegacyDataWipe.identityKeychainServices` so generation
    /// bumps sweep the iCloud copy as well. Items in this service use the
    /// identity's inboxId as the account, one item per backed-up identity.
    public static let syncedBackupService: String = "org.convos.ios.KeychainIdentityStore.v3-synced-backup"

    /// Fixed account key for the identity in the primary slot.
    public static let identityAccount: String = "convos-identity"

    // MARK: - Initialization

    /// - Parameter syncedBackupEnabled: pass `false` from surfaces whose
    ///   identities must not be escrowed to iCloud (the App Clip). Gates
    ///   only the backup write paths (mirror + backfill); reads and the
    ///   scoped backup delete stay active so cleanup still works.
    public init(accessGroup: String, syncedBackupEnabled: Bool = true) {
        self.keychainAccessGroup = accessGroup
        self.keychainService = Self.defaultService
        self.syncedBackupEnabled = syncedBackupEnabled
    }

    // MARK: - Public Interface

    public func generateKeys() throws -> KeychainIdentityKeys {
        try KeychainIdentityKeys.generate()
    }

    public func save(inboxId: String, clientId: String, keys: KeychainIdentityKeys) throws -> KeychainIdentity {
        let identity = KeychainIdentity(inboxId: inboxId, clientId: clientId, keys: keys)
        let data = try JSONEncoder().encode(identity)
        // When this save displaces a different identity (pairing over the
        // fresh-install placeholder), remove the displaced identity's
        // backup before overwriting the primary: once the primary is gone
        // its inboxId can't be recovered to scope the deletion. If the
        // primary write below then fails, the old identity is still in
        // place and the next authorize's backfill restores its backup.
        if let displacedInboxId = (try? loadSync())?.inboxId, displacedInboxId != inboxId {
            removeSyncedBackup(inboxId: displacedInboxId)
        }
        try saveData(data, with: identityQuery)
        mirrorToSyncedBackup(identity)
        return identity
    }

    public func load() throws -> KeychainIdentity? {
        try loadSync()
    }

    public nonisolated func loadSync() throws -> KeychainIdentity? {
        try Self.loadIdentity(with: identityQuery)
    }

    public func loadSyncedBackups() throws -> [KeychainIdentityBackup] {
        var query = syncedBackupServiceQuery()
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitAll

        var item: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &item)
        guard status != errSecItemNotFound else { return [] }
        guard status == errSecSuccess, let blobs = item as? [Data] else {
            throw KeychainIdentityStoreError.keychainOperationFailed(status, "loadBackups")
        }
        return blobs.compactMap { (data: Data) -> KeychainIdentityBackup? in
            do {
                return try JSONDecoder().decode(KeychainIdentityBackup.self, from: data)
            } catch {
                Log.error("Skipping undecodable synced backup item: \(error)")
                return nil
            }
        }
    }

    public func backfillSyncedBackupIfNeeded() {
        guard syncedBackupEnabled else { return }
        do {
            guard let identity = try loadSync() else { return }
            let readQuery = syncedBackupQuery(inboxId: identity.inboxId).toReadDictionary()
            do {
                _ = try Self.loadKeychainData(with: readQuery)
            } catch KeychainIdentityStoreError.identityNotFound {
                mirrorToSyncedBackup(identity)
            }
        } catch {
            Log.error("Failed to backfill synced backup slot: \(error)")
        }
    }

    public func delete() throws {
        // Remove the backup first: if the backup delete fails the primary
        // is still intact, so a retry can locate the backup again. The
        // deletion is scoped to this identity's account so backups from
        // other (unpaired) identities on the same iCloud account survive.
        // If the primary can't be read the backup can't be located; the
        // primary is still deleted and the backup is left as an orphan
        // (reclaimable via LegacyDataWipe on a generation bump).
        let primary: KeychainIdentity?
        do {
            primary = try loadSync()
        } catch {
            primary = nil
            Log.warning("Could not read primary slot during delete; any synced backup is left orphaned: \(error)")
        }
        if let inboxId = primary?.inboxId {
            try deleteData(with: syncedBackupQuery(inboxId: inboxId))
        }
        try deleteData(with: identityQuery)
    }

    // MARK: - Slot Queries

    private nonisolated var identityQuery: KeychainQuery {
        KeychainQuery(
            account: Self.identityAccount,
            service: keychainService,
            accessGroup: keychainAccessGroup
        )
    }

    private nonisolated func syncedBackupQuery(inboxId: String) -> KeychainQuery {
        KeychainQuery(
            account: inboxId,
            service: Self.syncedBackupService,
            accessGroup: keychainAccessGroup,
            synchronizable: true
        )
    }

    /// Service-wide query matching every item in the synced backup slot,
    /// regardless of account. Used to enumerate backups for recovery.
    private func syncedBackupServiceQuery() -> [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: Self.syncedBackupService,
            kSecAttrAccessGroup as String: keychainAccessGroup,
            kSecAttrSynchronizable as String: true
        ]
    }

    /// Best-effort write of the identity (as a `KeychainIdentityBackup`)
    /// into the synced backup slot. Failures are logged, never thrown:
    /// the primary slot is the source of truth and a failed backup write
    /// must not block registration or pairing.
    private func mirrorToSyncedBackup(_ identity: KeychainIdentity) {
        guard syncedBackupEnabled else { return }
        do {
            let data = try JSONEncoder().encode(KeychainIdentityBackup(identity: identity))
            try saveData(data, with: syncedBackupQuery(inboxId: identity.inboxId))
        } catch {
            Log.error("Failed to write identity to synced backup slot: \(error)")
        }
    }

    /// Best-effort removal of one identity's backup item. Used when a
    /// save displaces a different identity; a failure here only leaves
    /// the displaced backup as a logged orphan, it must not block the
    /// incoming save.
    private func removeSyncedBackup(inboxId: String) {
        do {
            try deleteData(with: syncedBackupQuery(inboxId: inboxId))
        } catch {
            Log.error("Failed to remove displaced identity's synced backup: \(error)")
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

    /// Static so `nonisolated` entry points can call it without an actor hop.
    private static func loadIdentity(with query: KeychainQuery) throws -> KeychainIdentity? {
        do {
            let data = try loadKeychainData(with: query.toReadDictionary())
            return try JSONDecoder().decode(KeychainIdentity.self, from: data)
        } catch KeychainIdentityStoreError.identityNotFound {
            return nil
        }
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
