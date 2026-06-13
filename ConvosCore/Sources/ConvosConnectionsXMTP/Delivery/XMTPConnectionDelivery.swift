import ConvosConnections
import Foundation
@preconcurrency import XMTPiOS

public enum XMTPConnectionDeliveryError: Error, LocalizedError, Equatable {
    case conversationNotFound(String)

    public var errorDescription: String? {
        switch self {
        case .conversationNotFound(let id): return "XMTP conversation not found for id '\(id)'."
        }
    }
}

/// XMTP-backed `ConnectionDelivering`.
///
/// Holds a closure that maps a conversation id to an `XMTPiOS.Conversation`. Convos
/// supplies this with its GRDB-backed resolver so the adapter doesn't need to know about
/// ConvosCore's conversation storage. Delivery is a two-step: look up → send with the
/// right codec's contentType.
///
/// `XMTPiOS.Conversation` isn't Sendable, so we hold the closure rather than a conversation
/// reference. Each delivery call resolves the conversation fresh.
public final class XMTPConnectionDelivery: ConnectionDelivering, @unchecked Sendable {
    public typealias ConversationLookup = @Sendable (String) async throws -> XMTPiOS.Conversation?

    private let lookup: ConversationLookup

    public init(conversationLookup: @escaping ConversationLookup) {
        self.lookup = conversationLookup
    }

    public func deliver(_ payload: ConnectionPayload, to conversationId: String) async throws {
        guard let conversation = try await lookup(conversationId) else {
            throw XMTPConnectionDeliveryError.conversationNotFound(conversationId)
        }
        let codec = ConnectionPayloadCodec()
        try await conversation.send(
            content: payload,
            options: .init(contentType: codec.contentType)
        )
    }

    public func deliver(_ result: ConnectionInvocationResult, to conversationId: String) async throws {
        guard let conversation = try await lookup(conversationId) else {
            throw XMTPConnectionDeliveryError.conversationNotFound(conversationId)
        }
        let codec = ConnectionInvocationResultCodec()
        try await conversation.send(
            content: result,
            options: .init(contentType: codec.contentType)
        )
    }
}
