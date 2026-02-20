import Foundation

public final class MockConversationExplosionWriter: ConversationExplosionWriterProtocol, @unchecked Sendable {
    public var explodedConversationIds: [String] = []
    public var scheduledExplosions: [(conversationId: String, expiresAt: Date)] = []

    public init() {}

    public func explodeConversation(conversationId: String, memberInboxIds: [String]) async throws {
        explodedConversationIds.append(conversationId)
    }

    public func scheduleExplosion(conversationId: String, expiresAt: Date) async throws {
        scheduledExplosions.append((conversationId: conversationId, expiresAt: expiresAt))
    }
}
