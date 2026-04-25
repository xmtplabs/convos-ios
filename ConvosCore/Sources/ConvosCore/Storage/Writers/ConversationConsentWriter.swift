import Foundation
import GRDB

public protocol ConversationConsentWriterProtocol {
    func join(conversation: Conversation) async throws
    func delete(conversation: Conversation) async throws
    func deleteAll() async throws
}

/// Marked @unchecked Sendable because GRDB's DatabaseWriter provides its own
/// concurrency safety via write{}/read{} closures - all database access is
/// externally synchronized by GRDB's serialized database queue.
class ConversationConsentWriter: ConversationConsentWriterProtocol, @unchecked Sendable {
    enum ConversationConsentWriterError: Error {
        case deleteAllFailedWithErrors([Error])
        case conversationNotFound(conversationId: String)
    }

    private let inboxStateManager: any InboxStateManagerProtocol
    private let databaseWriter: any DatabaseWriter

    init(inboxStateManager: any InboxStateManagerProtocol,
         databaseWriter: any DatabaseWriter) {
        self.inboxStateManager = inboxStateManager
        self.databaseWriter = databaseWriter
    }

    func join(conversation: Conversation) async throws {
        // Stage 6e Phase B: route through the `MessagingClient`
        // abstraction. `messagingConversation(with:)` looks up the
        // `MessagingConversation`; the `.core.updateConsentState(_:)`
        // call replaces the legacy `client.update(consent:for:)`
        // helper that XMTPClientProvider exposed.
        let client = try await inboxStateManager.waitForInboxReadyResult().client
        try await updateMessagingConsent(
            using: client,
            conversationId: conversation.id,
            to: .allowed
        )
        try await databaseWriter.write { db in
            guard let localConversation = try DBConversation
                .filter(DBConversation.Columns.id == conversation.id)
                .fetchOne(db) else {
                return
            }
            try localConversation.with(consent: .allowed).save(db)
            Log.info("Updated conversation consent state to allowed")
        }
    }

    func delete(conversation: Conversation) async throws {
        // Stage 6e Phase B: route through the `MessagingClient`
        // abstraction (see `join(...)` above for rationale).
        let client = try await inboxStateManager.waitForInboxReadyResult().client
        try await updateMessagingConsent(
            using: client,
            conversationId: conversation.id,
            to: .denied
        )
        try await databaseWriter.write { db in
            guard let localConversation = try DBConversation
                .filter(DBConversation.Columns.id == conversation.id)
                .fetchOne(db) else {
                return
            }
            try localConversation.with(consent: .denied).save(db)
            Log.info("Updated conversation consent state to denied")
        }
    }

    func deleteAll() async throws {
        // Stage 6e Phase B: route through the `MessagingClient`
        // abstraction.
        let client = try await inboxStateManager.waitForInboxReadyResult().client
        let inboxId = client.inboxId
        let conversationsToDeny = try await databaseWriter.read { db in
            try DBConversation
                .filter(DBConversation.Columns.inboxId == inboxId)
                .filter(DBConversation.Columns.consent == Consent.unknown)
                .fetchAll(db)
        }

        var errors: [Error] = []
        for dbConversation in conversationsToDeny {
            do {
                try await updateMessagingConsent(
                    using: client,
                    conversationId: dbConversation.id,
                    to: .denied
                )
                try await databaseWriter.write { db in
                    try dbConversation.with(consent: .denied).save(db)
                    Log.info("Updated conversation \(dbConversation.id) consent state to denied")
                }
            } catch {
                errors.append(error)
            }
        }

        if !errors.isEmpty {
            throw ConversationConsentWriterError.deleteAllFailedWithErrors(errors)
        }
    }

    /// Looks up the conversation through the `MessagingClient`
    /// abstraction and updates its consent state via
    /// `MessagingConversationCore.updateConsentState(_:)`. Mirrors
    /// the prior `XMTPClientProvider.update(consent:for:)` semantics
    /// (throws if the conversation is not found).
    private func updateMessagingConsent(
        using client: any MessagingClient,
        conversationId: String,
        to consent: Consent
    ) async throws {
        guard let conversation = try await client.messagingConversation(
            with: conversationId
        ) else {
            throw ConversationConsentWriterError.conversationNotFound(
                conversationId: conversationId
            )
        }
        try await conversation.core.updateConsentState(consent.messagingConsentState)
    }
}
