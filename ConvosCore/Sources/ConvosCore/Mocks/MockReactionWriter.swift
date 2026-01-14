import Foundation

public final class MockReactionWriter: ReactionWriterProtocol, @unchecked Sendable {
    public struct ReactionRecord: Equatable {
        public let emoji: String
        public let messageId: String
        public let conversationId: String
        public let action: ReactionRecordAction

        public enum ReactionRecordAction {
            case added, removed
        }
    }

    public var reactions: [ReactionRecord] = []

    public init() {}

    public func addReaction(emoji: String, to messageId: String, in conversationId: String) async throws {
        reactions.append(.init(emoji: emoji, messageId: messageId, conversationId: conversationId, action: .added))
    }

    public func removeReaction(emoji: String, from messageId: String, in conversationId: String) async throws {
        reactions.append(.init(emoji: emoji, messageId: messageId, conversationId: conversationId, action: .removed))
    }

    public func toggleReaction(emoji: String, to messageId: String, in conversationId: String) async throws {
        let hasExisting = reactions.contains { $0.messageId == messageId && $0.emoji == emoji && $0.action == .added }
        if hasExisting {
            reactions.append(.init(emoji: emoji, messageId: messageId, conversationId: conversationId, action: .removed))
        } else {
            reactions.append(.init(emoji: emoji, messageId: messageId, conversationId: conversationId, action: .added))
        }
    }
}
