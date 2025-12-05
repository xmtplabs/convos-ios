import Foundation
import Security

enum KeychainError: Error {
    case duplicateEntry
    case unknown(OSStatus)
    case itemNotFound
}

/// Protocol for keychain service operations
///
/// Defines the interface for storing and retrieving items from the keychain.
/// Implementations can be real (using Security framework) or mocks for testing.
public protocol KeychainServiceProtocol: Sendable {
    func saveString(_ value: String, account: String) throws
    func saveData(_ data: Data, account: String) throws
    func retrieveString(account: String) throws -> String?
    func retrieveData(account: String) throws -> Data?
    func delete(account: String) throws
}

extension KeychainServiceProtocol {
	public func saveString(_ value: String, account: String) throws {
		guard let valueData = value.data(using: .utf8) else {
			throw KeychainError.unknown(errSecParam)
		}
		try saveData(valueData, account: account)
	}

	public func retrieveString(account: String) throws -> String? {
		guard let data = try retrieveData(account: account) else {
			return nil
		}
		return String(data: data, encoding: .utf8)
	}
}

/// Keychain service for storing and retrieving items
///
/// Provides keychain operations for storing string and data values.
/// Items are identified by a fixed service identifier and account identifiers.
/// Automatic updates for duplicate entries. Used internally by higher-level stores.
///
/// Thread-safe: Uses explicit synchronization via DispatchQueue to ensure
/// safe concurrent access to Security framework APIs.
public final class KeychainService: KeychainServiceProtocol {
    private let queue: DispatchQueue = DispatchQueue(label: "com.convos.keychainService", qos: .userInitiated)

    /// Internal service identifier used for all keychain items
    private let serviceIdentifier: String = "org.convos.ios.KeychainService.v2"

    public init() {}

    public func saveData(_ data: Data, account: String) throws {
        try queue.sync {
            let query: [String: Any] = [
                kSecClass as String: kSecClassGenericPassword,
                kSecAttrService as String: serviceIdentifier,
                kSecAttrAccount as String: account,
                kSecValueData as String: data,
                kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
            ]

            let status = SecItemAdd(query as CFDictionary, nil)

            if status == errSecDuplicateItem {
                // Item already exists, update it
                let updateQuery: [String: Any] = [
                    kSecClass as String: kSecClassGenericPassword,
                    kSecAttrService as String: serviceIdentifier,
                    kSecAttrAccount as String: account
                ]

                let attributes: [String: Any] = [
                    kSecValueData as String: data
                ]

                let updateStatus = SecItemUpdate(updateQuery as CFDictionary, attributes as CFDictionary)
                guard updateStatus == errSecSuccess else {
                    throw KeychainError.unknown(updateStatus)
                }
            } else if status != errSecSuccess {
                throw KeychainError.unknown(status)
            }
        }
    }

    public func retrieveData(account: String) throws -> Data? {
        return try queue.sync {
            let query: [String: Any] = [
                kSecClass as String: kSecClassGenericPassword,
                kSecAttrService as String: serviceIdentifier,
                kSecAttrAccount as String: account,
                kSecReturnData as String: true
            ]

            var result: AnyObject?
            let status = SecItemCopyMatching(query as CFDictionary, &result)

            guard status == errSecSuccess else {
                if status == errSecItemNotFound {
                    return nil
                }
                throw KeychainError.unknown(status)
            }

            return result as? Data
        }
    }

    public func delete(account: String) throws {
        try queue.sync {
            let query: [String: Any] = [
                kSecClass as String: kSecClassGenericPassword,
                kSecAttrService as String: serviceIdentifier,
                kSecAttrAccount as String: account
            ]

            let status = SecItemDelete(query as CFDictionary)

            guard status == errSecSuccess || status == errSecItemNotFound else {
                throw KeychainError.unknown(status)
            }
        }
    }
}
