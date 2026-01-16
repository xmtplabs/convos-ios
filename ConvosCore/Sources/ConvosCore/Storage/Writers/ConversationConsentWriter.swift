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

    private let inboxStateManager: any InboxStateManagerProtocol
    private let databaseWriter: any DatabaseWriter

    init(inboxStateManager: any InboxStateManagerProtocol,
         databaseWriter: any DatabaseWriter) {
        self.inboxStateManager = inboxStateManager
        self.databaseWriter = databaseWriter
    }

    func join(conversation: Conversation) async throws {
        let client = try await inboxStateManager.waitForInboxReadyResult().client
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
        let client = try await inboxStateManager.waitForInboxReadyResult().client
        try await client.update(consent: .denied, for: conversation.id)
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
