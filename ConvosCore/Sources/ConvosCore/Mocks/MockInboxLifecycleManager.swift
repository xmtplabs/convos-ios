import Foundation

public actor MockInboxLifecycleManager: InboxLifecycleManagerProtocol {
    public let maxAwakeInboxes: Int = 50
    public var _awakeClientIds: Set<String> = []
    public var _sleepingClientIds: Set<String> = []
    public var _pendingInviteClientIds: Set<String> = []
    public var _activeClientId: String?
    public var mockServices: [String: any MessagingServiceProtocol] = [:]

    public var awakeClientIds: Set<String> { _awakeClientIds }
    public var sleepingClientIds: Set<String> { _sleepingClientIds }
    public var pendingInviteClientIds: Set<String> { _pendingInviteClientIds }
    public var activeClientId: String? { _activeClientId }
    public var _sleepTimes: [String: Date] = [:]

    public func sleepTime(for clientId: String) -> Date? {
        _sleepTimes[clientId]
    }

    public var mockNewInboxService: (any MessagingServiceProtocol)?
    public var mockNewInboxConversationId: String?

    public init() {}

    public func setActiveClientId(_ clientId: String?) {
        _activeClientId = clientId
    }

    public func createNewInbox() async -> (service: any MessagingServiceProtocol, conversationId: String?) {
        if let service = mockNewInboxService {
            _awakeClientIds.insert(service.clientId)
            return (service: service, conversationId: mockNewInboxConversationId)
        }
        fatalError("MockInboxLifecycleManager.createNewInbox called without setting mockNewInboxService")
    }

    public func createNewInboxOnly() async -> any MessagingServiceProtocol {
        if let service = mockNewInboxService {
            _awakeClientIds.insert(service.clientId)
            return service
        }
        fatalError("MockInboxLifecycleManager.createNewInboxOnly called without setting mockNewInboxService")
    }

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
        _sleepTimes[clientId] = Date()
    }

    public func forceRemove(clientId: String) async {
        _awakeClientIds.remove(clientId)
        _sleepingClientIds.remove(clientId)
    }

    public func getOrCreateService(clientId: String, inboxId: String) -> any MessagingServiceProtocol {
        if let existing = mockServices[clientId] {
            return existing
        }
        // Return a mock service for testing
        return MockMessagingService()
    }

    public func getOrWake(clientId: String, inboxId: String) async throws -> any MessagingServiceProtocol {
        if _awakeClientIds.contains(clientId), let service = mockServices[clientId] {
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

    public func rebalance() async {}

    public func initializeOnAppLaunch() async {}

    public func stopAll() async {
        _awakeClientIds.removeAll()
        _sleepingClientIds.removeAll()
    }

    public func prepareUnusedConversationIfNeeded() async {}

    public func clearUnusedConversation() async {}
}
