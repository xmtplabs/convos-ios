import ConvosConnections
import ConvosConnectionsXMTP
import Foundation
@preconcurrency import XMTPiOS

extension MessagingService {
    /// Debug-only injection: synthesize a `ConnectionPayload` and send it to a conversation
    /// as if `HealthBackgroundObserverRoutine` had emitted it. Used by the in-app debug
    /// sheet to exercise the agent's incoming-payload path without waiting for HealthKit
    /// to fire. No-ops in Release.
    func sendDebugConnectionPayload(_ payload: ConnectionPayload, to conversationId: String) async throws {
        #if DEBUG
        let inboxReady = try await sessionStateManager.waitForInboxReadyResult()
        guard let conversation = try await inboxReady.client.conversationsProvider.findConversation(conversationId: conversationId) else {
            throw DebugInjectorError.conversationNotFound(conversationId)
        }
        let codec = ConnectionPayloadCodec()
        try await conversation.send(
            content: payload,
            options: .init(contentType: codec.contentType)
        )
        #endif
    }

    enum DebugInjectorError: Error, LocalizedError {
        case conversationNotFound(String)

        var errorDescription: String? {
            switch self {
            case .conversationNotFound(let id):
                return "XMTP conversation not found for id '\(id)'."
            }
        }
    }
}
