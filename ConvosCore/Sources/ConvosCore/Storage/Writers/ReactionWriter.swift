import Combine
import Foundation
import GRDB

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

// Stage 3 migration (audit §5.3): the writer no longer imports
// XMTPiOS. The XIP `Reaction` codec still lives on the XMTPiOS side
// so reactions flow through the Stage-6 codec bridge
// (`MessagingWriterBridge.sendReaction`). Once the codec migrates to
// the abstraction this can reduce to
// `conversation.core.sendOptimistic(encodedContent:options:)`.
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

    private enum Action {
        case added, removed
    }

    private func sendReaction(
        emoji: String,
        to messageId: String,
        in conversationId: String,
        action: Action
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
                linkPreview: nil,
                sourceMessageId: dbMessageId,
                attachmentUrls: [],
                update: nil
            )
            try localReaction.save(db)
            Log.debug("Saved local reaction with id: \(reactionClientMessageId)")
        }

        guard let conversation = try await client.messagingConversation(with: conversationId) else {
            try await markReactionFailed(clientMessageId: reactionClientMessageId)
            throw ReactionWriterError.conversationNotFound(conversationId: conversationId)
        }

        do {
            try await sendReactionViaBridge(
                conversation: conversation,
                reference: dbMessageId,
                action: .added,
                emoji: emoji,
                referenceInboxId: sourceMessage.senderId,
                shouldPush: true
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
            guard let conversation = try await client.messagingConversation(with: conversationId) else {
                throw ReactionWriterError.conversationNotFound(conversationId: conversationId)
            }

            try await sendReactionViaBridge(
                conversation: conversation,
                reference: dbMessageId,
                action: .removed,
                emoji: emoji,
                referenceInboxId: sourceMessage.senderId,
                shouldPush: true
            )
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
