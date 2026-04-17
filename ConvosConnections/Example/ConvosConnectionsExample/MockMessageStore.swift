import ConvosConnections
import Foundation

/// A `ConnectionDelivering` that records every delivered payload into an in-memory list,
/// keyed by conversation id. Stands in for XMTP in the example app so the detail view has
/// something concrete to render.
///
/// The actor is the message "database" for the example — treat it like a very small local
/// equivalent of the XMTP message store. Messages have a stable id derived from the
/// payload, so the same payload never appears twice.
actor MockMessageStore: ConnectionDelivering {
    struct Message: Identifiable, Sendable, Equatable {
        let id: UUID
        let payload: ConnectionPayload
        let receivedAt: Date
    }

    private var messagesByConversation: [String: [Message]] = [:]

    func deliver(_ payload: ConnectionPayload, to conversationId: String) async throws {
        let message = Message(id: payload.id, payload: payload, receivedAt: Date())
        messagesByConversation[conversationId, default: []].append(message)
    }

    func messages(for conversationId: String) -> [Message] {
        messagesByConversation[conversationId] ?? []
    }

    func clearMessages(for conversationId: String) {
        messagesByConversation[conversationId] = []
    }
}
