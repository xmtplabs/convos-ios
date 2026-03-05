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

    public init(privateKeyData: Data, databaseKey: Data) throws {
        self.privateKey = try PrivateKey(privateKeyData)
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
    let clientId: String?

    init(
        account: String,
        service: String,
        accessGroup: String,
        accessible: CFString = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly,
        clientId: String? = nil
    ) {
        self.account = account
        self.service = service
        self.accessGroup = accessGroup
        self.accessible = accessible
        self.clientId = clientId
    }

    func toDictionary() -> [String: Any] {
        var query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrAccount as String: account,
            kSecAttrService as String: service,
            kSecAttrAccessGroup as String: accessGroup,
            kSecAttrAccessible as String: accessible
        ]

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
    func save(inboxId: String, clientId: String, keys: KeychainIdentityKeys) async throws -> KeychainIdentity
    func identity(for inboxId: String) async throws -> KeychainIdentity
    func loadAll() async throws -> [KeychainIdentity]
    func delete(inboxId: String) async throws
    func delete(clientId: String) async throws -> KeychainIdentity
    func deleteAll() async throws
}

/// Secure storage for XMTP identity keys in device keychain
///
/// KeychainIdentityStore manages XMTP signing keys and database encryption keys
/// in the device's secure keychain. Each identity is stored with:
/// - inboxId: XMTP inbox identifier (account key in keychain)
/// - clientId: Privacy-preserving client identifier (generic attribute)
/// - Private key for XMTP message signing
/// - Database encryption key for local XMTP database
///
/// Keys are stored in the app group keychain with configurable protection level.
/// Enforces clientId uniqueness to prevent duplicate identities.
public final actor KeychainIdentityStore: KeychainIdentityStoreProtocol {
    // MARK: - Properties

    private let keychainService: String
    private let keychainAccessGroup: String
    private let accessibility: CFString

    public static let defaultService: String = "org.convos.ios.KeychainIdentityStore.v2"
    public static let icloudService: String = "org.convos.ios.KeychainIdentityStore.v2.icloud"
    private static let localFormatMigrationKey: String = "KeychainIdentityStore.localFormatMigrationComplete"

    // MARK: - Initialization

    public init(
        accessGroup: String,
        service: String = KeychainIdentityStore.defaultService,
        accessibility: CFString = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
    ) {
        self.keychainAccessGroup = accessGroup
        self.keychainService = service
        self.accessibility = accessibility
    }

    /// Migrates existing keychain items from `SecAccessControl` to plain `kSecAttrAccessible`.
    ///
    /// Call once at app launch before creating the store. Items stored with `SecAccessControl`
    /// (empty flags) are functionally identical to plain `kSecAttrAccessible` but cannot have
    /// their accessibility updated in-place via `SecItemUpdate`. This migration deletes and
    /// re-adds each item with plain `kSecAttrAccessible` to enable future in-place updates.
    ///
    /// This is `nonisolated` and `static` so it can be called synchronously at app launch.
    public nonisolated static func migrateToPlainAccessibilityIfNeeded(
        accessGroup: String,
        service: String = defaultService,
        accessibility: CFString = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
    ) {
        guard !UserDefaults.standard.bool(forKey: localFormatMigrationKey) else { return }

        let loadQuery: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccessGroup as String: accessGroup,
            kSecMatchLimit as String: kSecMatchLimitAll,
            kSecReturnData as String: true,
            kSecReturnAttributes as String: true
        ]

        var result: CFTypeRef?
        let loadStatus = SecItemCopyMatching(loadQuery as CFDictionary, &result)

        guard loadStatus == errSecSuccess, let items = result as? [[String: Any]] else {
            if loadStatus == errSecItemNotFound {
                UserDefaults.standard.set(true, forKey: localFormatMigrationKey)
                Log.info("Keychain format migration: no items to migrate")
            } else {
                Log.error("Keychain format migration: failed to load items, status: \(loadStatus)")
            }
            return
        }

        Log.info("Keychain format migration: migrating \(items.count) item(s)")

        var migratedCount = 0
        for item in items {
            guard let account = item[kSecAttrAccount as String] as? String,
                  let data = item[kSecValueData as String] as? Data else {
                Log.warning("Keychain format migration: skipping item with missing account or data")
                continue
            }

            let deleteQuery: [String: Any] = [
                kSecClass as String: kSecClassGenericPassword,
                kSecAttrService as String: service,
                kSecAttrAccessGroup as String: accessGroup,
                kSecAttrAccount as String: account
            ]

            let deleteStatus = SecItemDelete(deleteQuery as CFDictionary)
            guard deleteStatus == errSecSuccess else {
                Log.error("Keychain format migration: failed to delete item \(account), status: \(deleteStatus)")
                continue
            }

            var addQuery: [String: Any] = [
                kSecClass as String: kSecClassGenericPassword,
                kSecAttrService as String: service,
                kSecAttrAccessGroup as String: accessGroup,
                kSecAttrAccount as String: account,
                kSecAttrAccessible as String: accessibility,
                kSecValueData as String: data
            ]

            if let genericData = item[kSecAttrGeneric as String] as? Data {
                addQuery[kSecAttrGeneric as String] = genericData
            }

            let addStatus = SecItemAdd(addQuery as CFDictionary, nil)
            if addStatus == errSecSuccess {
                migratedCount += 1
            } else {
                Log.error("Keychain format migration: failed to re-add item \(account), status: \(addStatus)")
            }
        }

        UserDefaults.standard.set(true, forKey: localFormatMigrationKey)
        Log.info("Keychain format migration: completed, migrated \(migratedCount)/\(items.count) item(s)")
    }

    // MARK: - Public Interface

    public func generateKeys() throws -> KeychainIdentityKeys {
        try KeychainIdentityKeys.generate()
    }

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
            accessGroup: keychainAccessGroup,
            accessible: accessibility
        )
        let data = try loadData(with: query)
        return try JSONDecoder().decode(KeychainIdentity.self, from: data)
    }

    // MARK: - Private lookup by clientId

    private func identity(forClientId clientId: String) throws -> KeychainIdentity {
        guard let clientIdData = clientId.data(using: .utf8) else {
            throw KeychainIdentityStoreError.identityNotFound("Invalid clientId encoding: \(clientId)")
        }

        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: keychainService,
            kSecAttrAccessGroup as String: keychainAccessGroup,
            kSecAttrGeneric as String: clientIdData,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitAll
        ]

        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)

        guard status != errSecItemNotFound else {
            throw KeychainIdentityStoreError.identityNotFound("No identity found with clientId: \(clientId)")
        }

        guard status == errSecSuccess else {
            throw KeychainIdentityStoreError.keychainOperationFailed(status, "identity(forClientId:)")
        }

        let items: [Data]
        if let singleItem = result as? Data {
            items = [singleItem]
        } else if let multipleItems = result as? [Data] {
            items = multipleItems
        } else {
            throw KeychainIdentityStoreError.keychainOperationFailed(errSecUnknownFormat, "identity(forClientId:)")
        }

        guard items.count == 1 else {
            throw KeychainIdentityStoreError.duplicateClientId(clientId, items.count)
        }

        return try JSONDecoder().decode(KeychainIdentity.self, from: items[0])
    }

    public func loadAll() throws -> [KeychainIdentity] {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: keychainService,
            kSecAttrAccessGroup as String: keychainAccessGroup,
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
            accessGroup: keychainAccessGroup,
            accessible: accessibility
        )

        try deleteData(with: query)
    }

    public func delete(clientId: String) throws -> KeychainIdentity {
        let identity = try identity(forClientId: clientId)
        try delete(inboxId: identity.inboxId)
        return identity
    }

    public func deleteAll() throws {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: keychainService,
            kSecAttrAccessGroup as String: keychainAccessGroup
        ]

        let status = SecItemDelete(query as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else {
            throw KeychainIdentityStoreError.keychainOperationFailed(status, "deleteAll")
        }
    }

    // MARK: - Private Methods

    private func save(identity: KeychainIdentity) throws {
        do {
            let existingIdentity = try self.identity(forClientId: identity.clientId)

            if existingIdentity.inboxId != identity.inboxId {
                throw KeychainIdentityStoreError.duplicateClientId(
                    identity.clientId,
                    2
                )
            }
        } catch KeychainIdentityStoreError.identityNotFound {
            // no existing identity with this clientId, proceed
        }

        let data = try JSONEncoder().encode(identity)

        let query = KeychainQuery(
            account: identity.inboxId,
            service: keychainService,
            accessGroup: keychainAccessGroup,
            accessible: accessibility,
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
