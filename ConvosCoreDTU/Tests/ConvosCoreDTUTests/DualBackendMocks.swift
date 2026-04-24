@testable import ConvosCore
import Foundation

/// Shared mocks for Phase 2 ConvosCoreDTU migrations. Centralising these
/// avoids each writer-integration test re-declaring the same stub, and
/// matches the pattern in the batch-2 migration brief ("create a
/// `MessagingMessage`-typed fresh mock in DualBackendMocks.swift (single
/// file, reusable across migrations)").
///
/// The legacy `MockIncomingMessageWriter` in `LockConversationTests.swift`
/// still speaks in `XMTPiOS.DecodedMessage` (Stage 2 writer); we cannot
/// reuse it. ConsumedConversationCreatedAtTests declared a file-local
/// `StubIncomingMessageWriter` earlier in batch 1 — this file promotes
/// that implementation to a reusable fixture.

/// Minimal stand-in for `IncomingMessageWriter` that short-circuits
/// `store(...)` without touching the database. Used by writer-
/// integration tests whose goal is to verify `ConversationWriter`
/// behaviour (not the downstream message-write path).
///
/// Matches the current `MessagingMessage`-typed
/// `IncomingMessageWriterProtocol` in ConvosCore.
final class DualBackendMockIncomingMessageWriter: IncomingMessageWriterProtocol,
                                                  @unchecked Sendable {
    func store(
        message: MessagingMessage,
        for conversation: DBConversation
    ) async throws -> IncomingMessageWriterResult {
        IncomingMessageWriterResult(
            contentType: .text,
            wasRemovedFromConversation: false,
            messageAlreadyExists: false
        )
    }

    func decodeExplodeSettings(from message: MessagingMessage) -> ExplodeSettings? {
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
