import Foundation

/// Mock keychain service for testing
///
/// Provides an in-memory implementation of KeychainServiceProtocol for unit tests.
/// All data is stored in memory and cleared when the instance is deallocated.
final class MockKeychainService: KeychainServiceProtocol, @unchecked Sendable {
    private var storage: [String: Data] = [:]
    private let queue: DispatchQueue = DispatchQueue(label: "com.convos.mockKeychainService", qos: .userInitiated)

    func saveData(_ data: Data, account: String) throws {
        queue.sync {
            storage[account] = data
        }
    }

    func retrieveData(account: String) throws -> Data? {
        return queue.sync {
            storage[account]
        }
    }

    func delete(account: String) throws {
        queue.sync {
            _ = storage.removeValue(forKey: account)
        }
    }

    // Test helpers

    func clear() {
        queue.sync {
            storage.removeAll()
        }
    }

    func contains(account: String) -> Bool {
        return queue.sync {
            storage[account] != nil
        }
    }
}
