import Foundation
@preconcurrency import UserNotifications

public final class MockUserNotificationCenter: UserNotificationCenterProtocol, @unchecked Sendable {
    private var _addedRequests: [UNNotificationRequest] = []
    private var _removedIdentifiers: [String] = []
    private var _shouldThrowOnAdd: Bool = false
    private let queue: DispatchQueue = DispatchQueue(label: "MockUserNotificationCenter")

    public var addedRequests: [UNNotificationRequest] {
        queue.sync { _addedRequests }
    }

    public var removedIdentifiers: [String] {
        queue.sync { _removedIdentifiers }
    }

    public var shouldThrowOnAdd: Bool {
        get { queue.sync { _shouldThrowOnAdd } }
        set { queue.sync { _shouldThrowOnAdd = newValue } }
    }

    public init() {}

    public func add(_ request: UNNotificationRequest) async throws {
        let shouldThrow = queue.sync { _shouldThrowOnAdd }
        if shouldThrow {
            throw MockNotificationError.addFailed
        }
        queue.sync { _addedRequests.append(request) }
    }

    public func removePendingNotificationRequests(withIdentifiers identifiers: [String]) {
        queue.sync {
            _removedIdentifiers.append(contentsOf: identifiers)
            _addedRequests.removeAll { identifiers.contains($0.identifier) }
        }
    }

    public func reset() {
        queue.sync {
            _addedRequests.removeAll()
            _removedIdentifiers.removeAll()
            _shouldThrowOnAdd = false
        }
    }

    public func hasRequest(withIdentifier identifier: String) -> Bool {
        queue.sync { _addedRequests.contains { $0.identifier == identifier } }
    }

    public func getRequest(withIdentifier identifier: String) -> UNNotificationRequest? {
        queue.sync { _addedRequests.first { $0.identifier == identifier } }
    }
}

public enum MockNotificationError: Error {
    case addFailed
}
