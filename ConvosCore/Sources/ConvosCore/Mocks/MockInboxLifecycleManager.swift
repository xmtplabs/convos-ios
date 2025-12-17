import Foundation

public actor MockInboxLifecycleManager: InboxLifecycleManagerProtocol {
    public let maxAwakeInboxes: Int = 50
    public var _awakeClientIds: Set<String> = []
    public var _sleepingClientIds: Set<String> = []
    public var _pendingInviteClientIds: Set<String> = []
    public var mockServices: [String: any MessagingServiceProtocol] = [:]

    public var awakeClientIds: Set<String> { _awakeClientIds }
    public var sleepingClientIds: Set<String> { _sleepingClientIds }
    public var pendingInviteClientIds: Set<String> { _pendingInviteClientIds }

    public init() {}

    public func wake(clientId: String, inboxId: String, reason: WakeReason) async throws -> any MessagingServiceProtocol {
        _awakeClientIds.insert(clientId)
        _sleepingClientIds.remove(clientId)
        guard let service = mockServices[clientId] else {
            throw InboxLifecycleError.inboxNotFound(clientId: clientId)
        }
        return service
    }

    public func sleep(clientId: String) async {
        _awakeClientIds.remove(clientId)
        _sleepingClientIds.insert(clientId)
    }

    public func getService(for clientId: String) -> (any MessagingServiceProtocol)? {
        if _awakeClientIds.contains(clientId) {
            return mockServices[clientId]
        }
        return nil
    }

    public func getOrWake(clientId: String, inboxId: String) async throws -> any MessagingServiceProtocol {
        if let service = getService(for: clientId) {
            return service
        }
        return try await wake(clientId: clientId, inboxId: inboxId, reason: .userInteraction)
    }

    public func isAwake(clientId: String) -> Bool {
        _awakeClientIds.contains(clientId)
    }

    public func isSleeping(clientId: String) -> Bool {
        _sleepingClientIds.contains(clientId)
    }

    public func rebalance(activeClientId: String?) async {}

    public func initializeOnAppLaunch() async {}

    public func stopAll() async {
        _awakeClientIds.removeAll()
        _sleepingClientIds.removeAll()
    }
}
