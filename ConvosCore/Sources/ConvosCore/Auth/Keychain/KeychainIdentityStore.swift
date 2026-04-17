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

protocol KeychainIdentityType {
    var inboxId: String { get }
    var clientId: String { get }
    var clientKeys: any XMTPClientKeys { get }
}

public struct KeychainIdentity: Codable, KeychainIdentityType, Sendable {
    public let inboxId: String
    public let clientId: String
    public let keys: KeychainIdentityKeys
    var clientKeys: any XMTPClientKeys {
        keys
    }

    init(inboxId: String, clientId: String, keys: KeychainIdentityKeys) {
        self.inboxId = inboxId
        self.clientId = clientId
        self.keys = keys
    }
}

// MARK: - Errors

public enum KeychainIdentityStoreError: Error, LocalizedError {
    case keychainOperationFailed(OSStatus, String)
    case dataEncodingFailed(String)
    case dataDecodingFailed(String)
    case privateKeyGenerationFailed
    case privateKeyLoadingFailed
    case identityNotFound(String)
    case rollbackFailed(String)
    case invalidAccessGroup
    case duplicateClientId(String, Int)

    public var errorDescription: String? {
        switch self {
        case let .keychainOperationFailed(status, operation):
            return "Keychain \(operation) failed with status: \(status)"
        case let .dataEncodingFailed(context):
            return "Failed to encode data for \(context)"
        case let .dataDecodingFailed(context):
            return "Failed to decode data for \(context)"
        case .privateKeyGenerationFailed:
            return "Failed to generate private key"
        case .privateKeyLoadingFailed:
            return "Failed to load private key"
        case let .identityNotFound(context):
            return "Identity not found: \(context)"
        case let .rollbackFailed(context):
            return "Rollback failed for \(context)"
        case .invalidAccessGroup:
            return "Invalid or missing keychain access group"
        case let .duplicateClientId(clientId, count):
            return "Duplicate clientId detected: '\(clientId)' found \(count) times in keychain"
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
    let clientId: String?

    init(
        account: String,
        service: String,
        accessGroup: String,
        accessible: CFString = kSecAttrAccessibleAfterFirstUnlock,
        synchronizable: Bool = true,
        clientId: String? = nil
    ) {
        self.account = account
        self.service = service
        self.accessGroup = accessGroup
        self.accessible = accessible
        self.synchronizable = synchronizable
        self.clientId = clientId
    }

    func toDictionary() -> [String: Any] {
        var query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrAccount as String: account,
            kSecAttrService as String: service,
            kSecAttrAccessGroup as String: accessGroup,
            kSecAttrAccessible as String: accessible,
            kSecAttrSynchronizable as String: synchronizable
        ]

        // Add clientId as generic attribute for direct lookup
        if let clientId = clientId, let clientIdData = clientId.data(using: .utf8) {
            query[kSecAttrGeneric as String] = clientIdData
        }

        return query
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

    // Singleton API (single-inbox identity model, C3+)
    //
    // The user has exactly one identity. `saveSingleton` writes (or overwrites)
    // it; `loadSingleton` reads it or returns nil on fresh installs; `deleteSingleton`
    // removes it. All three operate on a fixed account key — callers never need
    // to track inboxId/clientId for keychain lookups anymore.
    func saveSingleton(inboxId: String, clientId: String, keys: KeychainIdentityKeys) throws -> KeychainIdentity
    func loadSingleton() throws -> KeychainIdentity?
    func deleteSingleton() throws

    // Multi-identity API (legacy, retired in C4 along with the multi-inbox stack)
    //
    // Still functional during the intermediate state between C3 and C4 so the
    // multi-inbox callers (InboxLifecycleManager, SessionManager, etc.) keep
    // compiling. Do not add new call sites.
    func save(inboxId: String, clientId: String, keys: KeychainIdentityKeys) throws -> KeychainIdentity
    func identity(for inboxId: String) throws -> KeychainIdentity
    func loadAll() throws -> [KeychainIdentity]
    func delete(inboxId: String) throws
    func delete(clientId: String) throws -> KeychainIdentity
    func deleteAll() throws
}

/// Secure storage for XMTP identity keys in device keychain.
///
/// Single-inbox model (C3+): the user has exactly one identity, stored under a fixed
/// account key (`singletonAccount`). iCloud Keychain sync is enabled via
/// `kSecAttrSynchronizable = true` + `kSecAttrAccessibleAfterFirstUnlock` so the
/// identity follows the user across devices on the same Apple ID. The item is still
/// stored in the app-group keychain (`accessGroup`) so the Notification Service
/// Extension can read it.
///
/// The multi-identity API (`save(inboxId:clientId:keys:)`, `identity(for:)`,
/// `loadAll`, `delete(inboxId:)`, `delete(clientId:)`, `deleteAll`) is retained as-is
/// for legacy callers compiling during the C3→C4 intermediate state. It is retired
/// in C4 when the multi-inbox Swift stack is deleted.
///
/// Service name bumps from `.v2` to `.v3` so legacy entries (with
/// `AfterFirstUnlockThisDeviceOnly` + no sync) do not collide with the new schema.
public final actor KeychainIdentityStore: KeychainIdentityStoreProtocol {
    // MARK: - Properties

    private let keychainService: String
    private let keychainAccessGroup: String

    static let defaultService: String = "org.convos.ios.KeychainIdentityStore.v3"

    /// Fixed account key used for the singleton identity. All singleton reads,
    /// writes, and deletes target this account.
    static let singletonAccount: String = "single-inbox-identity"

    // MARK: - Initialization

    public init(accessGroup: String) {
        self.keychainAccessGroup = accessGroup
        self.keychainService = Self.defaultService
    }

    // MARK: - Public Interface

    public func generateKeys() throws -> KeychainIdentityKeys {
        try KeychainIdentityKeys.generate()
    }

    // MARK: - Singleton API (C3+)

    public func saveSingleton(inboxId: String, clientId: String, keys: KeychainIdentityKeys) throws -> KeychainIdentity {
        let identity = KeychainIdentity(inboxId: inboxId, clientId: clientId, keys: keys)
        let data = try JSONEncoder().encode(identity)
        let query = KeychainQuery(
            account: Self.singletonAccount,
            service: keychainService,
            accessGroup: keychainAccessGroup,
            clientId: clientId
        )
        try saveData(data, with: query)
        return identity
    }

    public func loadSingleton() throws -> KeychainIdentity? {
        let query = KeychainQuery(
            account: Self.singletonAccount,
            service: keychainService,
            accessGroup: keychainAccessGroup
        )
        do {
            let data = try loadData(with: query)
            return try JSONDecoder().decode(KeychainIdentity.self, from: data)
        } catch KeychainIdentityStoreError.identityNotFound {
            return nil
        }
    }

    public func deleteSingleton() throws {
        let query = KeychainQuery(
            account: Self.singletonAccount,
            service: keychainService,
            accessGroup: keychainAccessGroup
        )
        try deleteData(with: query)
    }

    // MARK: - Multi-identity API (legacy, retired in C4)

    public func save(inboxId: String, clientId: String, keys: KeychainIdentityKeys) throws -> KeychainIdentity {
        let identity = KeychainIdentity(
            inboxId: inboxId,
            clientId: clientId,
            keys: keys
        )
        try save(identity: identity)
        return identity
    }

    public func identity(for inboxId: String) throws -> KeychainIdentity {
        let query = KeychainQuery(
            account: inboxId,
            service: keychainService,
            accessGroup: keychainAccessGroup
        )
        let data = try loadData(with: query)
        return try JSONDecoder().decode(KeychainIdentity.self, from: data)
    }

    public func loadAll() throws -> [KeychainIdentity] {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: keychainService,
            kSecAttrAccessGroup as String: keychainAccessGroup,
            kSecAttrSynchronizable as String: kSecAttrSynchronizableAny,
            kSecMatchLimit as String: kSecMatchLimitAll,
            kSecReturnData as String: true
        ]

        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)

        guard status == errSecSuccess, let items = result as? [Data] else {
            if status == errSecItemNotFound {
                return []
            }
            throw KeychainIdentityStoreError.keychainOperationFailed(status, "loadAll")
        }

        var identities: [KeychainIdentity] = []
        for data in items {
            do {
                let identity = try JSONDecoder().decode(KeychainIdentity.self, from: data)
                identities.append(identity)
            } catch {
                Log.error("Failed decoding identity: \(error)")
            }
        }

        return identities
    }

    public func delete(inboxId: String) throws {
        let query = KeychainQuery(
            account: inboxId,
            service: keychainService,
            accessGroup: keychainAccessGroup
        )

        try deleteData(with: query)
    }

    public func delete(clientId: String) throws -> KeychainIdentity {
        // Scan all stored identities to find the match. The old
        // `identity(forClientId:)` polymorphism was dropped in C3; with the
        // single-inbox model the only remaining callers are legacy multi-inbox
        // paths scheduled for deletion in C4, so an O(N) scan is acceptable.
        let all = try loadAll()
        guard let identity = all.first(where: { $0.clientId == clientId }) else {
            throw KeychainIdentityStoreError.identityNotFound("No identity found with clientId: \(clientId)")
        }
        try delete(inboxId: identity.inboxId)
        return identity
    }

    public func deleteAll() throws {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: keychainService,
            kSecAttrAccessGroup as String: keychainAccessGroup,
            kSecAttrSynchronizable as String: kSecAttrSynchronizableAny
        ]

        let status = SecItemDelete(query as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else {
            throw KeychainIdentityStoreError.keychainOperationFailed(status, "deleteAll")
        }
    }

    // MARK: - Private Methods

    private func save(identity: KeychainIdentity) throws {
        // Uniqueness enforcement (formerly done by looking up `identity(forClientId:)`)
        // is removed — the singleton write path is the canonical path in the single-inbox
        // model, and the legacy multi-identity callers are retired in C4.
        let data = try JSONEncoder().encode(identity)

        let query = KeychainQuery(
            account: identity.inboxId,
            service: keychainService,
            accessGroup: keychainAccessGroup,
            clientId: identity.clientId
        )

        try saveData(data, with: query)
    }

    // MARK: - Generic Keychain Operations

    private func saveData(_ data: Data, with query: KeychainQuery) throws {
        var queryDict = query.toDictionary()
        queryDict[kSecValueData as String] = data

        let status = SecItemAdd(queryDict as CFDictionary, nil)

        if status == errSecDuplicateItem {
            // Item exists, update it
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
        return try loadData(with: query.toReadDictionary())
    }

    private func loadData(with query: [String: Any]) throws -> Data {
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
