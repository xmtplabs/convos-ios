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
        let clientMessageId = UUID().uuidString
        let inboxId = client.inboxId

        // Atomic check-and-save to prevent duplicate reactions from concurrent calls
        let isNewReaction = try await databaseWriter.write { db -> Bool in
            let existingReaction = try DBMessage
                .filter(DBMessage.Columns.sourceMessageId == messageId)
                .filter(DBMessage.Columns.senderId == inboxId)
                .filter(DBMessage.Columns.emoji == emoji)
                .filter(DBMessage.Columns.messageType == DBMessageType.reaction.rawValue)
                .fetchOne(db)

            if existingReaction != nil {
                Log.info("Reaction already exists locally, skipping duplicate")
                return false
            }

            let localReaction = DBMessage(
                id: clientMessageId,
                clientMessageId: clientMessageId,
                conversationId: conversationId,
                senderId: inboxId,
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
            return true
        }

        guard isNewReaction else { return }

        // Now do network operations (can be slow, but UI already updated)
        guard let conversation = try await client.conversation(with: conversationId) else {
            try await markReactionFailed(clientMessageId: clientMessageId)
            throw ReactionWriterError.conversationNotFound(conversationId: conversationId)
        }

        let sourceMessage = try await databaseWriter.read { db in
            try DBMessage.fetchOne(db, key: messageId)
        }

        guard let sourceMessage else {
            try await markReactionFailed(clientMessageId: clientMessageId)
            throw ReactionWriterError.messageNotFound(messageId: messageId)
        }

        let reaction = Reaction(
            reference: messageId,
            action: .added,
            content: emoji,
            schema: .unicode,
            referenceInboxId: sourceMessage.senderId
        )

        // Send to network - only mark as failed if THIS fails
        do {
            let encodedContent = try ReactionCodec().encode(content: reaction)
            try await conversation.send(
                encodedContent: encodedContent,
                visibilityOptions: MessageVisibilityOptions(shouldPush: true)
            )
            Log.info("Sent reaction \(emoji) to message \(messageId)")
        } catch {
            Log.error("Failed sending reaction: \(error.localizedDescription)")
            try await markReactionFailed(clientMessageId: clientMessageId)
            throw error
        }

        // Update to published - if this fails, the reaction was still sent successfully
        do {
            try await databaseWriter.write { db in
                guard let localReaction = try DBMessage.fetchOne(db, key: clientMessageId) else {
                    Log.warning("Local reaction not found after send")
                    return
                }
                try localReaction.with(status: .published).save(db)
            }
        } catch {
            Log.error("Failed updating reaction status to published: \(error.localizedDescription)")
            // Don't throw - the reaction was sent successfully
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

        // For removal, delete locally FIRST for optimistic UI
        let deletedReaction = try await databaseWriter.write { db -> DBMessage? in
            let reaction = try DBMessage
                .filter(DBMessage.Columns.sourceMessageId == messageId)
                .filter(DBMessage.Columns.senderId == inboxId)
                .filter(DBMessage.Columns.emoji == emoji)
                .filter(DBMessage.Columns.messageType == DBMessageType.reaction.rawValue)
                .fetchOne(db)

            if let reaction {
                try reaction.delete(db)
                Log.info("Optimistically deleted local reaction for message \(messageId)")
            }
            return reaction
        }

        guard let deletedReaction else {
            Log.info("No local reaction to remove; skipping network call")
            return
        }

        // Now send to network
        do {
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
                action: .removed,
                content: emoji,
                schema: .unicode,
                referenceInboxId: sourceMessage.senderId
            )

            let encodedContent = try ReactionCodec().encode(content: reaction)
            try await conversation.send(encodedContent: encodedContent)
            Log.info("Sent remove reaction \(emoji) for message \(messageId)")
        } catch {
            // Restore the reaction if network failed
            Log.error("Failed sending remove reaction: \(error.localizedDescription)")
            try await databaseWriter.write { db in
                try deletedReaction.save(db)
                Log.info("Restored local reaction after failed removal")
            }
            throw error
        }
    }
}
