import ConvosMessagingProtocols
import Foundation

/// Convenience accessors for callers that want to look up a conversation
/// by id and get back the abstraction-typed value directly. Thin wrappers
/// over `MessagingClient.conversations.find(conversationId:)`.
public extension MessagingClient {
    func messagingConversation(
        with conversationId: String
    ) async throws -> MessagingConversation? {
        try await conversations.find(conversationId: conversationId)
    }

    func messagingGroup(
        with conversationId: String
    ) async throws -> (any MessagingGroup)? {
        guard let conversation = try await messagingConversation(with: conversationId) else {
            return nil
        }
        if case .group(let group) = conversation {
            return group
        }
        return nil
    }
}
