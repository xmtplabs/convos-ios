import Foundation

public actor MockKeychainKeyStore: KeychainKeyStoreProtocol {
    private var store: [String: (keys: KeychainIdentityKeys, accessibility: KeychainAccessibility)] = [:]

    public init() {}

    public func save(keys: KeychainIdentityKeys, identifier: String, accessibility: KeychainAccessibility) throws {
        store[identifier] = (keys, accessibility)
    }

    public func load(identifier: String) throws -> KeychainIdentityKeys {
        guard let entry = store[identifier] else {
            throw KeychainIdentityStoreError.identityNotFound("No key found for identifier: \(identifier)")
        }
        return entry.keys
    }

    public func delete(identifier: String) throws {
        store.removeValue(forKey: identifier)
    }

    public func exists(identifier: String) throws -> Bool {
        store[identifier] != nil
    }

    public func accessibility(for identifier: String) -> KeychainAccessibility? {
        store[identifier]?.accessibility
    }

    public func reset() {
        store.removeAll()
    }
}
