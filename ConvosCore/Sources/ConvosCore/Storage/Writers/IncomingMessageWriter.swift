import Foundation
import GRDB
@preconcurrency import XMTPiOS

struct IncomingMessageWriterResult: Sendable {
    let contentType: MessageContentType
    let wasRemovedFromConversation: Bool
    let messageAlreadyExists: Bool
}

enum ExplodeSettingsResult: Sendable {
    case fromSelf
    case alreadyExpired
    case unauthorized
    case applied(expiresAt: Date)
    case scheduled(expiresAt: Date)
}

protocol IncomingMessageWriterProtocol: Sendable {
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

/// @unchecked Sendable: GRDB's DatabaseWriter provides thread-safe access via write{}
/// closures with an internal serial queue. The only property is an immutable reference.
class IncomingMessageWriter: IncomingMessageWriterProtocol, @unchecked Sendable {
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
                switch reaction.action {
                case .removed:
                    return try await handleReactionRemoval(
                        message: message,
                        reaction: reaction,
                        conversation: conversation
                    )
                case .added:
                    return try await handleReactionAddition(
                        message: message,
                        reaction: reaction,
                        conversation: conversation
                    )
                case .unknown:
                    Log.warning("Received unknown reaction action, ignoring")
                    return IncomingMessageWriterResult(
                        contentType: .emoji,
                        wasRemovedFromConversation: false,
                        messageAlreadyExists: false
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

            Log.info("Storing incoming message \(message.id) localId \(message.clientMessageId) echoDateNs=\(message.dateNs)")
            if !message.attachmentUrls.isEmpty {
                Log.info("[IncomingMessageWriter] Incoming attachmentUrls: \(message.attachmentUrls.map { $0.prefix(80) })")
            }
            // see if this message has a local version
            if let localMessage = try DBMessage
                .filter(DBMessage.Columns.id == message.id)
                .filter(DBMessage.Columns.clientMessageId != message.id)
                .fetchOne(db) {
                // Keep using the same local clientMessageId, sortId, and attachmentUrls
                // Preserving attachmentUrls is critical for maintaining AttachmentLocalState lookup
                Log.info("BRANCH 1: Found local message \(localMessage.clientMessageId) for incoming message \(message.id)")
                let updatedMessage = message
                    .with(clientMessageId: localMessage.clientMessageId)
                    .with(sortId: localMessage.sortId)
                    .with(attachmentUrls: localMessage.attachmentUrls)
                try updatedMessage.save(db)
                Log.info("BRANCH 1: Updated with clientMessageId=\(localMessage.clientMessageId), sortId=\(localMessage.sortId ?? -1)")
            } else if let existingMessage = try DBMessage.fetchOne(db, key: message.id),
                      existingMessage.hasLocalAttachments {
                // Message exists with local attachment URLs (outgoing photo) - preserve them and sortId
                Log.info("BRANCH 2: Preserving local attachments for message \(message.id)")
                let updatedMessage = message
                    .with(attachmentUrls: existingMessage.attachmentUrls)
                    .with(sortId: existingMessage.sortId)
                try updatedMessage.save(db)
                Log.info("BRANCH 2: Saved with local attachments, sortId=\(existingMessage.sortId ?? -1)")
            } else if let existingMessage = try DBMessage.fetchOne(db, key: message.id) {
                // Message exists but BRANCH 1 and BRANCH 2 didn't match
                // Keep clientMessageId, sortId, and attachmentUrls for stable UI identity
                // Preserving attachmentUrls is critical: we've migrated AttachmentLocalState
                // to match our local key, so using the incoming key would break the lookup
                Log.info("BRANCH 3: Found existing message \(message.id)")
                if !existingMessage.attachmentUrls.isEmpty || !message.attachmentUrls.isEmpty {
                    Log.info("[BRANCH 3] Existing attachmentUrls: \(existingMessage.attachmentUrls.map { $0.prefix(80) })")
                    Log.info("[BRANCH 3] Incoming attachmentUrls: \(message.attachmentUrls.map { $0.prefix(80) })")
                    let keysMatch = existingMessage.attachmentUrls == message.attachmentUrls
                    Log.info("[BRANCH 3] Keys match: \(keysMatch), preserving existing")
                }
                let updatedMessage = message
                    .with(clientMessageId: existingMessage.clientMessageId)
                    .with(sortId: existingMessage.sortId)
                    .with(attachmentUrls: existingMessage.attachmentUrls)
                try updatedMessage.save(db)
                Log.info("BRANCH 3: Saved with clientMessageId=\(existingMessage.clientMessageId), sortId=\(existingMessage.sortId ?? -1)")
            } else {
                // Truly new incoming message from another user - assign a new sortId
                let maxSortId = try Int64.fetchOne(db, sql: """
                    SELECT COALESCE(MAX(sortId), 0) FROM message WHERE conversationId = ?
                """, arguments: [conversation.id]) ?? 0
                let newSortId = maxSortId + 1
                let messageWithSortId = message.with(sortId: newSortId)

                do {
                    try messageWithSortId.save(db)
                    Log.info("BRANCH 4 (new): Saved incoming message: \(message.id) with sortId=\(newSortId)")
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
        let reactionAlreadyExists = try await databaseWriter.write { db -> Bool in
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
                let updatedReaction = existingReaction.with(status: .published)
                try updatedReaction.save(db)
                Log.info("Updated existing reaction \(existingReaction.id) status to published")
                return true
            } else {
                let dbMessage = try message.dbRepresentation()
                try dbMessage.save(db)
                Log.info("Saved new incoming reaction \(message.id)")
                return false
            }
        }
        return IncomingMessageWriterResult(
            contentType: .emoji,
            wasRemovedFromConversation: false,
            messageAlreadyExists: reactionAlreadyExists
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

        enum WriteResult {
            case updated
            case alreadyExpired
            case unauthorized
            case notFound
        }

        do {
            let writeResult = try await databaseWriter.write { db -> WriteResult in
                guard let dbConversation = try DBConversation.fetchOne(db, key: conversationId) else {
                    return .notFound
                }

                // Permission check: only creator or admin/superAdmin can explode
                let isCreator = senderInboxId == dbConversation.creatorId
                var hasAdminRole = false
                if !isCreator {
                    if let senderMember = try DBConversationMember.fetchOne(
                        db,
                        key: ["conversationId": conversationId, "inboxId": senderInboxId]
                    ) {
                        hasAdminRole = senderMember.role == .admin || senderMember.role == .superAdmin
                    }
                }

                guard isCreator || hasAdminRole else {
                    return .unauthorized
                }

                if let existingExpiresAt = dbConversation.expiresAt {
                    if settings.expiresAt < existingExpiresAt {
                        let updated = dbConversation.with(expiresAt: settings.expiresAt)
                        try updated.save(db)
                        return .updated
                    }
                    return .alreadyExpired
                }
                let updated = dbConversation.with(expiresAt: settings.expiresAt)
                try updated.save(db)
                return .updated
            }

            switch writeResult {
            case .notFound, .alreadyExpired:
                Log.info("ExplodeSettings: conversation not found or already has expiresAt, skipping")
                return .alreadyExpired
            case .unauthorized:
                Log.warning("ExplodeSettings: sender \(senderInboxId) is not authorized to explode conversation \(conversationId)")
                return .unauthorized
            case .updated:
                break
            }

            // Check if scheduled AFTER DB write to avoid time drift during async operation
            let isScheduled = settings.expiresAt.timeIntervalSinceNow > 0
            if isScheduled {
                Log.info("ExplodeSettings: scheduled for \(settings.expiresAt), posting conversationScheduledExplosion for \(conversationId)")
                await MainActor.run {
                    NotificationCenter.default.post(
                        name: .conversationScheduledExplosion,
                        object: nil,
                        userInfo: [
                            "conversationId": conversationId,
                            "expiresAt": settings.expiresAt
                        ]
                    )
                }
                return .scheduled(expiresAt: settings.expiresAt)
            } else {
                Log.info("ExplodeSettings: immediate, posting conversationExpired for \(conversationId)")
                await MainActor.run {
                    NotificationCenter.default.post(
                        name: .conversationExpired,
                        object: nil,
                        userInfo: ["conversationId": conversationId]
                    )
                }
                return .applied(expiresAt: settings.expiresAt)
            }
        } catch {
            Log.error("Failed to write expiresAt for conversation \(conversationId): \(error.localizedDescription)")
            return .alreadyExpired
        }
    }
}
