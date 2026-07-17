import Foundation

/// Mock implementation of ConversationLocalStateWriterProtocol for testing
public final class MockConversationLocalStateWriter: ConversationLocalStateWriterProtocol, @unchecked Sendable {
    public var unreadStates: [String: Bool] = [:]
    public var pinnedStates: [String: Bool] = [:]
    public var mutedStates: [String: Bool] = [:]
    public var hidesInviteCardStates: [String: Bool] = [:]
    public var leftHostedInviteSessionStates: [String: Bool] = [:]
    public var hasSharedInviteStates: [String: Bool] = [:]
    public var publishedProfileUpdatedAtStates: [String: Date?] = [:]

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

    public func setHidesInviteCard(_ hidesInviteCard: Bool, for conversationId: String) async throws {
        hidesInviteCardStates[conversationId] = hidesInviteCard
    }

    public func setLeftHostedInviteSession(_ leftHostedInviteSession: Bool, for conversationId: String) async throws {
        leftHostedInviteSessionStates[conversationId] = leftHostedInviteSession
    }

    public func setHasSharedInvite(_ hasSharedInvite: Bool, for conversationId: String) async throws {
        hasSharedInviteStates[conversationId] = hasSharedInvite
    }

    public func setPublishedProfileUpdatedAt(_ publishedProfileUpdatedAt: Date?, for conversationId: String) async throws {
        publishedProfileUpdatedAtStates[conversationId] = publishedProfileUpdatedAt
    }
}
