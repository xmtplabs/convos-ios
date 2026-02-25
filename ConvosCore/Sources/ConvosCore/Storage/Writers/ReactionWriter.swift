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

final class ReactionWriter: ReactionWriterProtocol, Sendable {
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

        // messageId from UI is clientMessageId - look up the actual DB id
        let sourceMessage = try await databaseWriter.read { db in
            try DBMessage
                .filter(DBMessage.Columns.clientMessageId == messageId)
                .fetchOne(db)
        }

        guard let sourceMessage else {
            throw ReactionWriterError.messageNotFound(messageId: messageId)
        }

        let dbMessageId = sourceMessage.id

        let existingReaction = try await databaseWriter.read { db in
            try DBMessage
                .filter(DBMessage.Columns.sourceMessageId == dbMessageId)
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

        switch action {
        case .added:
            try await addReactionOptimistically(
                emoji: emoji,
                to: messageId,
                in: conversationId,
                client: client
            )

        case .removed:
            try await removeReactionOptimistically(
                emoji: emoji,
                from: messageId,
                in: conversationId,
                client: client
            )

        case .unknown:
            Log.error("Attempted to send unknown reaction action")
            throw ReactionWriterError.unknownReactionAction
        }
    }

    private func addReactionOptimistically(
        emoji: String,
        to messageId: String,
        in conversationId: String,
        client: any XMTPClientProvider
    ) async throws {
        let date = Date()
        let reactionClientMessageId = UUID().uuidString
        let inboxId = client.inboxId

        let sourceMessage = try await databaseWriter.read { db in
            try DBMessage
                .filter(DBMessage.Columns.clientMessageId == messageId)
                .fetchOne(db)
        }

        guard let sourceMessage else {
            throw ReactionWriterError.messageNotFound(messageId: messageId)
        }

        let dbMessageId = sourceMessage.id

        let existingReaction = try await databaseWriter.read { db in
            try DBMessage
                .filter(DBMessage.Columns.sourceMessageId == dbMessageId)
                .filter(DBMessage.Columns.senderId == inboxId)
                .filter(DBMessage.Columns.emoji == emoji)
                .filter(DBMessage.Columns.messageType == DBMessageType.reaction.rawValue)
                .fetchOne(db)
        }

        if existingReaction != nil {
            Log.debug("Reaction already exists locally, skipping duplicate")
            return
        }

        try await databaseWriter.write { db in
            let localReaction = DBMessage(
                id: reactionClientMessageId,
                clientMessageId: reactionClientMessageId,
                conversationId: conversationId,
                senderId: inboxId,
                dateNs: date.nanosecondsSince1970,
                date: date,
                sortId: nil,
                status: .unpublished,
                messageType: .reaction,
                contentType: .emoji,
                text: nil,
                emoji: emoji,
                invite: nil,
                sourceMessageId: dbMessageId,
                attachmentUrls: [],
                update: nil
            )
            try localReaction.save(db)
            Log.debug("Saved local reaction with id: \(reactionClientMessageId)")
        }

        guard let conversation = try await client.conversation(with: conversationId) else {
            try await markReactionFailed(clientMessageId: reactionClientMessageId)
            throw ReactionWriterError.conversationNotFound(conversationId: conversationId)
        }

        let reaction = Reaction(
            reference: dbMessageId,
            action: .added,
            content: emoji,
            schema: .unicode,
            referenceInboxId: sourceMessage.senderId
        )

        do {
            let encodedContent = try ReactionV2Codec().encode(content: reaction)
            try await conversation.send(
                encodedContent: encodedContent,
                visibilityOptions: MessageVisibilityOptions(shouldPush: true)
            )
            Log.info("Sent reaction \(emoji) to message \(dbMessageId)")
            QAEvent.emit(.reaction, "sent", ["message": dbMessageId, "emoji": emoji])
        } catch {
            Log.error("Failed sending reaction: \(error.localizedDescription)")
            try await markReactionFailed(clientMessageId: reactionClientMessageId)
            throw error
        }

        do {
            try await databaseWriter.write { db in
                guard let localReaction = try DBMessage.fetchOne(db, key: reactionClientMessageId) else {
                    Log.warning("Local reaction not found after send")
                    return
                }
                try localReaction.with(status: .published).save(db)
            }
        } catch {
            Log.error("Failed updating reaction status to published: \(error.localizedDescription)")
        }
    }

    private func markReactionFailed(clientMessageId: String) async throws {
        try await databaseWriter.write { db in
            guard let localReaction = try DBMessage.fetchOne(db, key: clientMessageId) else {
                Log.warning("Local reaction not found when marking as failed")
                return
            }
            try localReaction.with(status: .failed).save(db)
        }
    }

    private func removeReactionOptimistically(
        emoji: String,
        from messageId: String,
        in conversationId: String,
        client: any XMTPClientProvider
    ) async throws {
        let inboxId = client.inboxId

        // messageId from UI is clientMessageId - look up the actual DB id
        let sourceMessage = try await databaseWriter.read { db in
            try DBMessage
                .filter(DBMessage.Columns.clientMessageId == messageId)
                .fetchOne(db)
        }

        guard let sourceMessage else {
            throw ReactionWriterError.messageNotFound(messageId: messageId)
        }

        let dbMessageId = sourceMessage.id

        let deletedReaction = try await databaseWriter.write { db -> DBMessage? in
            let reaction = try DBMessage
                .filter(DBMessage.Columns.sourceMessageId == dbMessageId)
                .filter(DBMessage.Columns.senderId == inboxId)
                .filter(DBMessage.Columns.emoji == emoji)
                .filter(DBMessage.Columns.messageType == DBMessageType.reaction.rawValue)
                .fetchOne(db)

            if let reaction {
                try reaction.delete(db)
                Log.debug("Optimistically deleted local reaction for message \(dbMessageId)")
            }
            return reaction
        }

        guard let deletedReaction else {
            Log.debug("No local reaction to remove; skipping network call")
            return
        }

        do {
            guard let conversation = try await client.conversation(with: conversationId) else {
                throw ReactionWriterError.conversationNotFound(conversationId: conversationId)
            }

            let reaction = Reaction(
                reference: dbMessageId,
                action: .removed,
                content: emoji,
                schema: .unicode,
                referenceInboxId: sourceMessage.senderId
            )

            let encodedContent = try ReactionV2Codec().encode(content: reaction)
            try await conversation.send(encodedContent: encodedContent)
            Log.info("Sent remove reaction \(emoji) for message \(dbMessageId)")
            QAEvent.emit(.reaction, "removed", ["message": dbMessageId, "emoji": emoji])
        } catch {
            Log.error("Failed sending remove reaction: \(error.localizedDescription)")
            try await databaseWriter.write { db in
                try deletedReaction.save(db)
                Log.debug("Restored local reaction after failed removal")
            }
            throw error
        }
    }
}
