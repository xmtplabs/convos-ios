import ConvosMessagingProtocols
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
    }

    private let sessionStateManager: any SessionStateManagerProtocol
    private let databaseWriter: any DatabaseWriter

    init(sessionStateManager: any SessionStateManagerProtocol,
         databaseWriter: any DatabaseWriter) {
        self.sessionStateManager = sessionStateManager
        self.databaseWriter = databaseWriter
    }

    func join(conversation: Conversation) async throws {
        let client = try await sessionStateManager.waitForInboxReadyResult().client
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
        let client = try await sessionStateManager.waitForInboxReadyResult().client
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
        let client = try await sessionStateManager.waitForInboxReadyResult().client
        let conversationsToDeny = try await databaseWriter.read { db in
            try DBConversation
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
    /// abstraction and updates its consent state. Logs and skips the
    /// network-side update if the conversation is not in the local
    /// MLS store yet — a soft "delete" / "join" should still flip the
    /// DB row so the user-facing list reflects the action immediately.
    private func updateMessagingConsent(
        using client: any MessagingClient,
        conversationId: String,
        to consent: Consent
    ) async throws {
        guard let conversation = try await client.messagingConversation(
            with: conversationId
        ) else {
            Log.warning(
                "ConversationConsentWriter: no messaging-side conversation for \(conversationId); skipping network consent update"
            )
            return
        }
        try await conversation.core.updateConsentState(consent.messagingConsentState)
    }
}
