import Foundation
import GRDB

public protocol ConversationConsentWriterProtocol: Sendable {
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
    /// Unsubscribes the conversation's push topic on leave so the backend
    /// stops pushing it immediately, instead of waiting for the next full
    /// reconcile. Best-effort: failures are swallowed by the manager and
    /// the next reconcile re-converges. Nil in unit tests that don't
    /// exercise the push path.
    private let pushTopicSubscriptionManager: (any PushTopicSubscriptionManaging)?

    init(sessionStateManager: any SessionStateManagerProtocol,
         databaseWriter: any DatabaseWriter,
         pushTopicSubscriptionManager: (any PushTopicSubscriptionManaging)? = nil) {
        self.sessionStateManager = sessionStateManager
        self.databaseWriter = databaseWriter
        self.pushTopicSubscriptionManager = pushTopicSubscriptionManager
    }

    func join(conversation: Conversation) async throws {
        let client = try await sessionStateManager.waitForInboxReadyResult().client
        try await client.update(consent: .allowed, for: conversation.id)
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
        let targetId = try await resolveDeletionTarget(for: conversation.id)

        // A pending-invite draft ("verifying") has no XMTP group yet, so a
        // network consent update would throw conversationNotFound before the
        // local denial was written and the conversation would pop back into
        // the list. Persist the denial locally only; ConversationWriter
        // carries it onto the real group if the invite is later approved.
        guard !DBConversation.isDraft(id: targetId) else {
            try await persistDeniedConsent(conversationId: targetId)
            return
        }

        let inboxReady = try await sessionStateManager.waitForInboxReadyResult()
        try await inboxReady.client.update(consent: .denied, for: targetId)
        try await persistDeniedConsent(conversationId: targetId)

        // Drop the conversation's push topic now that the user has left, so the
        // backend stops pushing it immediately. The full reconcile would also
        // diff a denied conversation out of the desired set, but only on the
        // next resume / cold start / token change; this closes that window.
        await pushTopicSubscriptionManager?.unsubscribeFromGroupTopic(
            conversationId: targetId,
            params: SyncClientParams(client: inboxReady.client, apiClient: inboxReady.apiClient),
            context: "leave conversation"
        )
    }

    /// A pending invite can resolve while the delete is in flight: the real
    /// group's row replaces the draft row but keeps the draft id as its
    /// clientConversationId. Re-target the delete at the real row in that
    /// case, otherwise the denial would silently hit a row that no longer
    /// exists and the conversation would stay visible.
    private func resolveDeletionTarget(for conversationId: String) async throws -> String {
        guard DBConversation.isDraft(id: conversationId) else { return conversationId }
        let resolvedId = try await databaseWriter.read { db in
            try DBConversation
                .filter(DBConversation.Columns.clientConversationId == conversationId)
                .select(DBConversation.Columns.id, as: String.self)
                .fetchOne(db)
        }
        return resolvedId ?? conversationId
    }

    private func persistDeniedConsent(conversationId: String) async throws {
        try await databaseWriter.write { db in
            guard let localConversation = try DBConversation
                .filter(DBConversation.Columns.id == conversationId)
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
                try await client.update(consent: .denied, for: dbConversation.id)
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
}
