import Foundation

public actor MockReactionWriter: ReactionWriterProtocol {
    public struct ReactionRecord: Equatable, Sendable {
        public let emoji: String
        public let messageId: String
        public let conversationId: String
        public let action: ReactionRecordAction

        public enum ReactionRecordAction: Sendable {
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
        let net = reactions.reduce(0) { acc, record in
            guard record.messageId == messageId && record.emoji == emoji else { return acc }
            switch record.action {
            case .added: return acc + 1
            case .removed: return acc - 1
            }
        }
        if net > 0 {
            reactions.append(.init(emoji: emoji, messageId: messageId, conversationId: conversationId, action: .removed))
        } else {
            reactions.append(.init(emoji: emoji, messageId: messageId, conversationId: conversationId, action: .added))
        }
    }
}
