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

    /// Writes (or overwrites) the user's singleton identity.
    func saveSingleton(inboxId: String, clientId: String, keys: KeychainIdentityKeys) throws -> KeychainIdentity

    /// Returns the singleton identity if one exists, `nil` on a fresh install.
    func loadSingleton() throws -> KeychainIdentity?

    /// Removes the singleton identity. Idempotent — silently succeeds if none exists.
    func deleteSingleton() throws
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
/// The legacy multi-identity API (`save(inboxId:clientId:keys:)`, `identity(for:)`,
/// `loadAll`, `delete(inboxId:)`, `delete(clientId:)`, `deleteAll`) was retired in C4b
/// along with the multi-inbox Swift stack. All callers now route through
/// `saveSingleton` / `loadSingleton` / `deleteSingleton`.
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
