import Foundation
import GRDB
import XMTPiOS

struct IncomingMessageWriterResult {
    let contentType: MessageContentType
    let wasRemovedFromConversation: Bool
    let messageAlreadyExists: Bool
}

enum ExplodeSettingsResult {
    case fromSelf
    case alreadyExpired
    case applied(expiresAt: Date)
}

protocol IncomingMessageWriterProtocol {
    func store(message: XMTPiOS.DecodedMessage,
               for conversation: DBConversation) async throws -> IncomingMessageWriterResult

    func decodeExplodeSettings(from message: XMTPiOS.DecodedMessage) -> ExplodeSettings?

    func processExplodeSettings(
        _ settings: ExplodeSettings,
        conversationId: String,
        senderInboxId: String,
        currentInboxId: String
    ) async -> ExplodeSettingsResult
}

class IncomingMessageWriter: IncomingMessageWriterProtocol {
    private let databaseWriter: any DatabaseWriter

    init(databaseWriter: any DatabaseWriter) {
        self.databaseWriter = databaseWriter
    }

    func store(message: DecodedMessage,
               for conversation: DBConversation) async throws -> IncomingMessageWriterResult {
        let encodedContentType = try message.encodedContent.type

        if encodedContentType == ContentTypeReaction || encodedContentType == ContentTypeReactionV2 {
            let content = try message.content() as Any
            if let reaction = content as? Reaction {
                if reaction.action == .removed {
                    return try await handleReactionRemoval(
                        message: message,
                        reaction: reaction,
                        conversation: conversation
                    )
                } else if reaction.action == .added {
                    return try await handleReactionAddition(
                        message: message,
                        reaction: reaction,
                        conversation: conversation
                    )
                }
            }
        }

        let result = try await databaseWriter.write { db in
            let sender = DBMember(inboxId: message.senderInboxId)
            try sender.save(db)
            let senderProfile = DBMemberProfile(
                conversationId: conversation.id,
                inboxId: message.senderInboxId,
                name: nil,
                avatar: nil
            )
            try? senderProfile.insert(db)
            let message = try message.dbRepresentation()

            let messageExistsInDB = try DBMessage.exists(db, key: message.id)
            // @jarodl temporary, this should happen somewhere else more explicitly
            let wasRemovedFromConversation = message.update?.removedInboxIds.contains(conversation.inboxId) ?? false

            Log.info("Storing incoming message \(message.id) localId \(message.clientMessageId)")
            // see if this message has a local version
            if let localMessage = try DBMessage
                .filter(DBMessage.Columns.id == message.id)
                .filter(DBMessage.Columns.clientMessageId != message.id)
                .fetchOne(db) {
                // keep using the same local id
                Log.info("Found local message \(localMessage.clientMessageId) for incoming message \(message.id)")
                let updatedMessage = message.with(
                    clientMessageId: localMessage.clientMessageId
                )
                try updatedMessage.save(db)
                Log.info(
                    "Updated incoming message with local message \(localMessage.clientMessageId)"
                )
            } else {
                do {
                    try message.save(db)
                    Log.info("Saved incoming message: \(message.id)")
                } catch {
                    Log.error("Failed saving incoming message \(message.id): \(error)")
                    throw error
                }
            }

            return IncomingMessageWriterResult(
                contentType: message.contentType,
                wasRemovedFromConversation: wasRemovedFromConversation,
                messageAlreadyExists: messageExistsInDB
            )
        }

        // Post notification after transaction commits
        if result.wasRemovedFromConversation && !result.messageAlreadyExists {
            conversation.postLeftConversationNotification()
        }

        return result
    }

    private func handleReactionAddition(
        message: DecodedMessage,
        reaction: Reaction,
        conversation: DBConversation
    ) async throws -> IncomingMessageWriterResult {
        try await databaseWriter.write { db in
            let sender = DBMember(inboxId: message.senderInboxId)
            try sender.save(db)
            let senderProfile = DBMemberProfile(
                conversationId: conversation.id,
                inboxId: message.senderInboxId,
                name: nil,
                avatar: nil
            )
            try? senderProfile.insert(db)

            let existingReaction = try DBMessage
                .filter(DBMessage.Columns.sourceMessageId == reaction.reference)
                .filter(DBMessage.Columns.senderId == message.senderInboxId)
                .filter(DBMessage.Columns.emoji == reaction.emoji)
                .filter(DBMessage.Columns.messageType == DBMessageType.reaction.rawValue)
                .fetchOne(db)

            if let existingReaction {
                let updatedReaction = existingReaction
                    .with(id: message.id)
                    .with(status: .published)
                try updatedReaction.save(db)
                Log.info("Updated existing reaction \(existingReaction.id) with network id \(message.id)")
            } else {
                let dbMessage = try message.dbRepresentation()
                try dbMessage.save(db)
                Log.info("Saved new incoming reaction \(message.id)")
            }
        }
        return IncomingMessageWriterResult(
            contentType: .emoji,
            wasRemovedFromConversation: false,
            messageAlreadyExists: false
        )
    }

    private func handleReactionRemoval(
        message: DecodedMessage,
        reaction: Reaction,
        conversation: DBConversation
    ) async throws -> IncomingMessageWriterResult {
        try await databaseWriter.write { db in
            let deletedCount = try DBMessage
                .filter(DBMessage.Columns.sourceMessageId == reaction.reference)
                .filter(DBMessage.Columns.senderId == message.senderInboxId)
                .filter(DBMessage.Columns.emoji == reaction.emoji)
                .filter(DBMessage.Columns.messageType == DBMessageType.reaction.rawValue)
                .deleteAll(db)
            Log.info("Deleted \(deletedCount) reaction(s) for message \(reaction.reference) from \(message.senderInboxId)")
        }
        return IncomingMessageWriterResult(
            contentType: .emoji,
            wasRemovedFromConversation: false,
            messageAlreadyExists: false
        )
    }

    func decodeExplodeSettings(from message: DecodedMessage) -> ExplodeSettings? {
        guard let encodedContentType = try? message.encodedContent.type,
              encodedContentType == ContentTypeExplodeSettings else {
            return nil
        }

        guard let content = try? message.content() as Any,
              let explodeSettings = content as? ExplodeSettings else {
            Log.error("Failed to extract ExplodeSettings content")
            return nil
        }

        return explodeSettings
    }

    func processExplodeSettings(
        _ settings: ExplodeSettings,
        conversationId: String,
        senderInboxId: String,
        currentInboxId: String
    ) async -> ExplodeSettingsResult {
        if senderInboxId == currentInboxId {
            Log.info("ExplodeSettings: from self, skipping")
            return .fromSelf
        }

        // When scheduled explosions are added, compare settings.expiresAt
        // against messageSentAt to determine if this is immediate or scheduled.

        do {
            let didUpdate = try await databaseWriter.write { db -> Bool in
                guard let dbConversation = try DBConversation.fetchOne(db, key: conversationId) else {
                    return false
                }
                // Skip if already expired (idempotency)
                if dbConversation.expiresAt != nil {
                    return false
                }
                let updated = dbConversation.with(expiresAt: settings.expiresAt)
                try updated.save(db)
                return true
            }

            guard didUpdate else {
                Log.info("ExplodeSettings: conversation already expired, skipping")
                return .alreadyExpired
            }

            Log.info("ExplodeSettings: applied, posting conversationExpired notification for \(conversationId)")
            DispatchQueue.main.async {
                NotificationCenter.default.post(
                    name: .conversationExpired,
                    object: nil,
                    userInfo: ["conversationId": conversationId]
                )
            }

            return .applied(expiresAt: settings.expiresAt)
        } catch {
            Log.error("Failed to write expiresAt for conversation \(conversationId): \(error.localizedDescription)")
            return .alreadyExpired
        }
    }
}
