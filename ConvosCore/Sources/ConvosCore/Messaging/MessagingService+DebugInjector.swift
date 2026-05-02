import ConvosConnections
import ConvosConnectionsXMTP
import Foundation
@preconcurrency import XMTPiOS

extension MessagingService {
    /// Sends a synthesized `ConnectionPayload` to a conversation as if a real
    /// `HealthBackgroundObserverRoutine` (or similar source) had emitted it. The in-app
    /// debug sheet uses this to exercise the agent's incoming-payload path without waiting
    /// for HealthKit to fire. The UI entry point is gated behind `#if DEBUG`; the
    /// underlying send is unconditionally available so the call works regardless of how
    /// SwiftPM resolved the package's compilation conditions.
    func sendDebugConnectionPayload(_ payload: ConnectionPayload, to conversationId: String) async throws {
        let inboxReady = try await sessionStateManager.waitForInboxReadyResult()
        guard let conversation = try await inboxReady.client.conversationsProvider.findConversation(conversationId: conversationId) else {
            throw DebugInjectorError.conversationNotFound(conversationId)
        }
        let codec = ConnectionPayloadCodec()
        try await conversation.send(
            content: payload,
            options: .init(contentType: codec.contentType)
        )
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
