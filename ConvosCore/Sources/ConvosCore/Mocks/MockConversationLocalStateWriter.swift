import Foundation

/// Mock implementation of ConversationLocalStateWriterProtocol for testing
public final class MockConversationLocalStateWriter: ConversationLocalStateWriterProtocol, @unchecked Sendable {
    public var unreadStates: [String: Bool] = [:]
    public var pinnedStates: [String: Bool] = [:]
    public var mutedStates: [String: Bool] = [:]
    public var activeStates: [String: Bool] = [:]
    public var markAllInactiveCallCount: Int = 0

    public init() {}

    public func setUnread(_ isUnread: Bool, for conversationId: String) async throws {
        unreadStates[conversationId] = isUnread
    }

    public func setPinned(_ isPinned: Bool, for conversationId: String) async throws {
        pinnedStates[conversationId] = isPinned
    }

    public func setMuted(_ isMuted: Bool, for conversationId: String) async throws {
        mutedStates[conversationId] = isMuted
    }

    public func setActive(_ isActive: Bool, for conversationId: String) async throws {
        activeStates[conversationId] = isActive
    }

    public func markAllConversationsInactive() async throws {
        markAllInactiveCallCount += 1
        for key in activeStates.keys {
            activeStates[key] = false
        }
    }
}
