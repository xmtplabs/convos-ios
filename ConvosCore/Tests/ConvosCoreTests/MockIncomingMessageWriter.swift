@testable import ConvosCore
import Foundation
import XMTPiOS

/// No-op incoming message writer for tests that only need the protocol
/// surface. Counterpart of the definition in
/// ConvosCoreIntegrationTests/LockConversationTests.swift.
final class MockIncomingMessageWriter: IncomingMessageWriterProtocol, @unchecked Sendable {
    func store(
        message: XMTPiOS.DecodedMessage,
        for conversation: DBConversation
    ) async throws -> IncomingMessageWriterResult {
        IncomingMessageWriterResult(
            contentType: .text,
            wasRemovedFromConversation: false,
            messageAlreadyExists: false
        )
    }

    func decodeExplodeSettings(from message: XMTPiOS.DecodedMessage) -> ExplodeSettings? {
        nil
    }

    func processExplodeSettings(
        _ settings: ExplodeSettings,
        conversationId: String,
        senderInboxId: String,
        currentInboxId: String
    ) async -> ExplodeSettingsResult {
        .fromSelf
    }
}
