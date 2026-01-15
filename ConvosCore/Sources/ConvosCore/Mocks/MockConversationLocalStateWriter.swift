import Foundation

/// Mock implementation of ConversationLocalStateWriterProtocol for testing
public final class MockConversationLocalStateWriter: ConversationLocalStateWriterProtocol, @unchecked Sendable {
    public var unreadStates: [String: Bool] = [:]
    public var pinnedStates: [String: Bool] = [:]
    public var mutedStates: [String: Bool] = [:]

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

    public func getPinnedCount() async throws -> Int {
        pinnedStates.values.filter { $0 }.count
    }
}
