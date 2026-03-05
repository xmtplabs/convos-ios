import Foundation
import Security

public enum KeychainAccessibility: Sendable {
    case afterFirstUnlockThisDeviceOnly
    case afterFirstUnlock
}

public protocol KeychainKeyStoreProtocol: Actor {
    func save(keys: KeychainIdentityKeys, identifier: String, accessibility: KeychainAccessibility) throws
    func load(identifier: String) throws -> KeychainIdentityKeys
    func delete(identifier: String) throws
    func exists(identifier: String) throws -> Bool
}

public final actor KeychainKeyStore: KeychainKeyStoreProtocol {
    private let service: String
    private let accessGroup: String

    public init(service: String, accessGroup: String) {
        self.service = service
        self.accessGroup = accessGroup
    }

    public func save(keys: KeychainIdentityKeys, identifier: String, accessibility: KeychainAccessibility) throws {
        let data = try JSONEncoder().encode(keys)

        let cfAccessibility: CFString = switch accessibility {
        case .afterFirstUnlockThisDeviceOnly:
            kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        case .afterFirstUnlock:
            kSecAttrAccessibleAfterFirstUnlock
        }

        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: identifier,
            kSecAttrAccessGroup as String: accessGroup,
            kSecAttrAccessible as String: cfAccessibility,
            kSecValueData as String: data,
        ]

        let status = SecItemAdd(query as CFDictionary, nil)

        if status == errSecDuplicateItem {
            let updateQuery: [String: Any] = [
                kSecClass as String: kSecClassGenericPassword,
                kSecAttrService as String: service,
                kSecAttrAccount as String: identifier,
                kSecAttrAccessGroup as String: accessGroup,
            ]
            let attributes: [String: Any] = [
                kSecValueData as String: data,
                kSecAttrAccessible as String: cfAccessibility,
            ]
            let updateStatus = SecItemUpdate(updateQuery as CFDictionary, attributes as CFDictionary)
            guard updateStatus == errSecSuccess else {
                throw KeychainIdentityStoreError.keychainOperationFailed(updateStatus, "KeychainKeyStore.save update")
            }
        } else if status != errSecSuccess {
            throw KeychainIdentityStoreError.keychainOperationFailed(status, "KeychainKeyStore.save")
        }
    }

    public func load(identifier: String) throws -> KeychainIdentityKeys {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: identifier,
            kSecAttrAccessGroup as String: accessGroup,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]

        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)

        guard status != errSecItemNotFound else {
            throw KeychainIdentityStoreError.identityNotFound("No key found for identifier: \(identifier)")
        }
        guard status == errSecSuccess, let data = result as? Data else {
            throw KeychainIdentityStoreError.keychainOperationFailed(status, "KeychainKeyStore.load")
        }

        return try JSONDecoder().decode(KeychainIdentityKeys.self, from: data)
    }

    public func delete(identifier: String) throws {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: identifier,
            kSecAttrAccessGroup as String: accessGroup,
        ]

        let status = SecItemDelete(query as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else {
            throw KeychainIdentityStoreError.keychainOperationFailed(status, "KeychainKeyStore.delete")
        }
    }

    public func exists(identifier: String) throws -> Bool {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: identifier,
            kSecAttrAccessGroup as String: accessGroup,
            kSecReturnData as String: false,
        ]

        let status = SecItemCopyMatching(query as CFDictionary, nil)

        if status == errSecSuccess {
            return true
        } else if status == errSecItemNotFound {
            return false
        } else {
            throw KeychainIdentityStoreError.keychainOperationFailed(status, "KeychainKeyStore.exists")
        }
    }
}
