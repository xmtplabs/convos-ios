import Foundation
import GRDB
import XMTPiOS

public protocol ReplyMessageWriterProtocol: Sendable {
    func sendReply(text: String, to parentMessageId: String, in conversationId: String) async throws
}

enum ReplyWriterError: Error {
    case parentMessageNotFound(messageId: String)
    case conversationNotFound(conversationId: String)
}

final class ReplyMessageWriter: ReplyMessageWriterProtocol, Sendable {
    private let inboxStateManager: any InboxStateManagerProtocol
    private let databaseWriter: any DatabaseWriter

    init(
        inboxStateManager: any InboxStateManagerProtocol,
        databaseWriter: any DatabaseWriter
    ) {
        self.inboxStateManager = inboxStateManager
        self.databaseWriter = databaseWriter
    }

    func sendReply(text: String, to parentMessageId: String, in conversationId: String) async throws {
        let inboxReady = try await inboxStateManager.waitForInboxReadyResult()
        let client = inboxReady.client
        let date = Date()
        let inboxId = client.inboxId

        let parentMessage = try await databaseWriter.read { db in
            try DBMessage.fetchOne(db, key: parentMessageId)
        }

        guard let parentMessage, parentMessage.status == .published else {
            throw ReplyWriterError.parentMessageNotFound(messageId: parentMessageId)
        }

        guard let conversation = try await client.conversation(with: conversationId) else {
            throw ReplyWriterError.conversationNotFound(conversationId: conversationId)
        }

        let clientMessageId = UUID().uuidString

        try await databaseWriter.write { db in
            let localReply = DBMessage(
                id: clientMessageId,
                clientMessageId: clientMessageId,
                conversationId: conversationId,
                senderId: inboxId,
                dateNs: date.nanosecondsSince1970,
                date: date,
                status: .unpublished,
                messageType: .reply,
                contentType: .text,
                text: text,
                emoji: nil,
                invite: nil,
                sourceMessageId: parentMessageId,
                attachmentUrls: [],
                update: nil
            )
            try localReply.save(db)
            Log.info("Saved local reply with id: \(clientMessageId)")
        }

        let reply = Reply(
            reference: parentMessage.id,
            content: text,
            contentType: ContentTypeText
        )

        var currentDbId = clientMessageId

        do {
            let preparedMessageId = try await conversation.prepareMessage(
                content: reply,
                options: .init(contentType: ContentTypeReply)
            )

            if preparedMessageId != clientMessageId {
                try await databaseWriter.write { db in
                    guard let localReply = try DBMessage.fetchOne(db, key: clientMessageId) else { return }
                    try localReply.delete(db)
                    try localReply.with(id: preparedMessageId).save(db)
                }
                currentDbId = preparedMessageId
            }

            try await conversation.publishMessages()
            Log.info("Published reply to message \(parentMessageId)")
        } catch {
            Log.error("Failed publishing reply: \(error.localizedDescription)")
            try? await markReplyFailed(clientMessageId: currentDbId)
            throw error
        }
    }

    private func markReplyFailed(clientMessageId: String) async throws {
        try await databaseWriter.write { db in
            guard let localReply = try DBMessage.fetchOne(db, key: clientMessageId) else {
                Log.warning("Local reply not found when marking as failed")
                return
            }
            try localReply.with(status: .failed).save(db)
        }
    }
}
