import Foundation
import GRDB

public protocol ReplyMessageWriterProtocol: Sendable {
    func sendReply(text: String, to parentMessageId: String, in conversationId: String) async throws
}

enum ReplyWriterError: Error {
    case parentMessageNotFound(messageId: String)
    case conversationNotFound(conversationId: String)
}

// The reply-send flow reaches the XMTPiOS XIP `Reply` codec through the
// `MessagingWriterBridge.sendTextReply` bridge (the codec still lives
// in the XMTPiOS layer). Conversation lookup flows through
// `messagingConversation(with:)`, keeping this file XMTPiOS-free.
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
            try DBMessage
                .filter(DBMessage.Columns.clientMessageId == parentMessageId)
                .fetchOne(db)
        }

        guard let parentMessage, parentMessage.status == .published else {
            throw ReplyWriterError.parentMessageNotFound(messageId: parentMessageId)
        }

        guard let conversation = try await client.messagingConversation(with: conversationId) else {
            throw ReplyWriterError.conversationNotFound(conversationId: conversationId)
        }

        let clientMessageId = UUID().uuidString

        let isContentEmoji = text.allCharactersEmoji
        let trimmedText = text.trimmingCharacters(in: .whitespacesAndNewlines)
        let linkPreview = !isContentEmoji ? LinkPreview.from(text: text) : nil

        let contentType: MessageContentType
        if isContentEmoji {
            contentType = .emoji
        } else if linkPreview != nil {
            contentType = .linkPreview
        } else {
            contentType = .text
        }

        try await databaseWriter.write { db in
            let maxSortId: Int64 = try DBMessage
                .filter(DBMessage.Columns.conversationId == conversationId)
                .select(max(DBMessage.Columns.sortId))
                .fetchOne(db) ?? 0
            let localReply = DBMessage(
                id: clientMessageId,
                clientMessageId: clientMessageId,
                conversationId: conversationId,
                senderId: inboxId,
                dateNs: date.nanosecondsSince1970,
                date: date,
                sortId: maxSortId + 1,
                status: .unpublished,
                messageType: .reply,
                contentType: contentType,
                text: isContentEmoji ? nil : text,
                emoji: isContentEmoji ? trimmedText : nil,
                invite: nil,
                linkPreview: linkPreview,
                sourceMessageId: parentMessage.id,
                attachmentUrls: [],
                update: nil
            )
            try localReply.save(db)
            Log.info("Saved local reply with id: \(clientMessageId)")
        }

        var currentDbId = clientMessageId

        do {
            // FIXME: `Reply(...) / ContentTypeText / ContentTypeReply`
            // are XMTPiOS XIP codec values. Until the codecs migrate to
            // the abstraction layer, bridge through the XMTPiOS adapter.
            let preparedMessageId = try await sendTextReplyViaBridge(
                conversation: conversation,
                replyText: text,
                parentMessageId: parentMessage.id
            )

            if preparedMessageId != clientMessageId {
                try await databaseWriter.write { db in
                    guard let localReply = try DBMessage.fetchOne(db, key: clientMessageId) else { return }
                    try localReply.delete(db)
                    try localReply.with(id: preparedMessageId).save(db)
                }
                currentDbId = preparedMessageId
            }

            try await publishPreparedMessagesViaBridge(conversation: conversation)
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
