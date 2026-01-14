import Combine
import Foundation
import GRDB
import XMTPiOS

public protocol ReactionWriterProtocol: Sendable {
    func addReaction(emoji: String, to messageId: String, in conversationId: String) async throws
    func removeReaction(emoji: String, from messageId: String, in conversationId: String) async throws
    func toggleReaction(emoji: String, to messageId: String, in conversationId: String) async throws
}

enum ReactionWriterError: Error {
    case missingClientProvider
    case conversationNotFound(conversationId: String)
    case messageNotFound(messageId: String)
    case unknownReactionAction
}

final class ReactionWriter: ReactionWriterProtocol {
    private let inboxStateManager: any InboxStateManagerProtocol
    private let databaseWriter: any DatabaseWriter

    init(
        inboxStateManager: any InboxStateManagerProtocol,
        databaseWriter: any DatabaseWriter
    ) {
        self.inboxStateManager = inboxStateManager
        self.databaseWriter = databaseWriter
    }

    func addReaction(emoji: String, to messageId: String, in conversationId: String) async throws {
        try await sendReaction(emoji: emoji, to: messageId, in: conversationId, action: .added)
    }

    func removeReaction(emoji: String, from messageId: String, in conversationId: String) async throws {
        try await sendReaction(emoji: emoji, to: messageId, in: conversationId, action: .removed)
    }

    func toggleReaction(emoji: String, to messageId: String, in conversationId: String) async throws {
        let inboxReady = try await inboxStateManager.waitForInboxReadyResult()
        let currentInboxId = inboxReady.client.inboxId

        let existingReaction = try await databaseWriter.read { db in
            try DBMessage
                .filter(DBMessage.Columns.sourceMessageId == messageId)
                .filter(DBMessage.Columns.senderId == currentInboxId)
                .filter(DBMessage.Columns.emoji == emoji)
                .filter(DBMessage.Columns.messageType == DBMessageType.reaction.rawValue)
                .fetchOne(db)
        }

        if existingReaction != nil {
            try await sendReaction(emoji: emoji, to: messageId, in: conversationId, action: .removed)
        } else {
            try await sendReaction(emoji: emoji, to: messageId, in: conversationId, action: .added)
        }
    }

    private func sendReaction(
        emoji: String,
        to messageId: String,
        in conversationId: String,
        action: ReactionAction
    ) async throws {
        let inboxReady = try await inboxStateManager.waitForInboxReadyResult()
        let client = inboxReady.client

        guard let conversation = try await client.conversation(with: conversationId) else {
            throw ReactionWriterError.conversationNotFound(conversationId: conversationId)
        }

        let sourceMessage = try await databaseWriter.read { db in
            try DBMessage.fetchOne(db, key: messageId)
        }

        guard let sourceMessage else {
            throw ReactionWriterError.messageNotFound(messageId: messageId)
        }

        let reaction = Reaction(
            reference: messageId,
            action: action,
            content: emoji,
            schema: .unicode,
            referenceInboxId: sourceMessage.senderId
        )

        switch action {
        case .added:
            let date = Date()
            let clientMessageId = UUID().uuidString

            let existingReaction = try await databaseWriter.read { db in
                try DBMessage
                    .filter(DBMessage.Columns.sourceMessageId == messageId)
                    .filter(DBMessage.Columns.senderId == client.inboxId)
                    .filter(DBMessage.Columns.emoji == emoji)
                    .filter(DBMessage.Columns.messageType == DBMessageType.reaction.rawValue)
                    .fetchOne(db)
            }

            if existingReaction != nil {
                Log.info("Reaction already exists locally, skipping duplicate")
                return
            }

            try await databaseWriter.write { db in
                let localReaction = DBMessage(
                    id: clientMessageId,
                    clientMessageId: clientMessageId,
                    conversationId: conversationId,
                    senderId: client.inboxId,
                    dateNs: date.nanosecondsSince1970,
                    date: date,
                    status: .unpublished,
                    messageType: .reaction,
                    contentType: .emoji,
                    text: nil,
                    emoji: emoji,
                    invite: nil,
                    sourceMessageId: messageId,
                    attachmentUrls: [],
                    update: nil
                )
                try localReaction.save(db)
                Log.info("Saved local reaction with id: \(clientMessageId)")
            }

            do {
                try await conversation.send(
                    content: reaction,
                    options: .init(contentType: ContentTypeReaction)
                )
                Log.info("Sent reaction \(emoji) to message \(messageId)")

                try await databaseWriter.write { db in
                    guard let localReaction = try DBMessage.fetchOne(db, key: clientMessageId) else {
                        Log.warning("Local reaction not found after send")
                        return
                    }
                    try localReaction.with(status: .published).save(db)
                }
            } catch {
                Log.error("Failed sending reaction: \(error.localizedDescription)")
                try await databaseWriter.write { db in
                    guard let localReaction = try DBMessage.fetchOne(db, key: clientMessageId) else {
                        Log.warning("Local reaction not found after failing to send")
                        return
                    }
                    try localReaction.with(status: .failed).save(db)
                }
                throw error
            }

        case .removed:
            try await databaseWriter.write { db in
                try DBMessage
                    .filter(DBMessage.Columns.sourceMessageId == messageId)
                    .filter(DBMessage.Columns.senderId == client.inboxId)
                    .filter(DBMessage.Columns.emoji == emoji)
                    .filter(DBMessage.Columns.messageType == DBMessageType.reaction.rawValue)
                    .deleteAll(db)
                Log.info("Deleted local reaction for message \(messageId)")
            }

            do {
                try await conversation.send(
                    content: reaction,
                    options: .init(contentType: ContentTypeReaction)
                )
                Log.info("Sent remove reaction \(emoji) for message \(messageId)")
            } catch {
                Log.error("Failed sending remove reaction: \(error.localizedDescription)")
                throw error
            }

        case .unknown:
            Log.error("Attempted to send unknown reaction action")
            throw ReactionWriterError.unknownReactionAction
        }
    }
}
