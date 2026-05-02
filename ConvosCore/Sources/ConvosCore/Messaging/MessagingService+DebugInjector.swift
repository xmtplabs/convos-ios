import ConvosConnections
import ConvosConnectionsXMTP
import Foundation
@preconcurrency import XMTPiOS

extension MessagingService {
    /// Sends a synthesized `ConnectionPayload` to a conversation as if a real
    /// `HealthBackgroundObserverRoutine` (or similar source) had emitted it. The in-app
    /// debug sheet uses this to exercise the agent's incoming-payload path without waiting
    /// for HealthKit to fire.
    ///
    /// The protocol requirement is unconditional because Xcode's SwiftPM build doesn't
    /// reliably propagate `#if DEBUG` into ConvosCore. To prevent the call from doing
    /// anything in production builds we gate at runtime against `AppEnvironment`.
    func sendDebugConnectionPayload(_ payload: ConnectionPayload, to conversationId: String) async throws {
        guard !environment.isProduction else {
            Log.error("[DebugInjector] sendDebugConnectionPayload called in production; refusing")
            throw DebugInjectorError.disabledInProduction
        }
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
        case disabledInProduction

        var errorDescription: String? {
            switch self {
            case .conversationNotFound(let id):
                return "XMTP conversation not found for id '\(id)'."
            case .disabledInProduction:
                return "Debug payload injection is disabled in production builds."
            }
        }
    }
}
