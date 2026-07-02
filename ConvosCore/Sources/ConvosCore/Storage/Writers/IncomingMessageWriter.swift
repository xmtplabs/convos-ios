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

    /// A `DBMessage` row plus the source metadata, prepared from a
    /// `DecodedMessage` but not yet written. The `dbRepresentation()`
    /// transform runs in `prepare(...)` so the upcoming batch catch-up
    /// can build N prepared messages in parallel and persist them all
    /// in one transaction.
    ///
    /// Only the regular-message path uses this — reactions still flow
    /// through `handleReactionAddition` / `handleReactionRemoval`, each
    /// of which has its own small transaction. A backlog of mostly
    /// text messages with a few reactions still collapses 90%+ of the
    /// observer fires via the batched persist; the reaction overhead
    /// is bounded and was already neutralized by the no-op diff
    /// short-circuit + image-prefetch dedup from #857.
    struct PreparedIncomingMessage {
        let source: DecodedMessage
        let encodedContentType: ContentTypeID
        let dbMessage: DBMessage
    }

    /// Async, transaction-free. Decodes the content type and builds the
    /// `DBMessage` representation. Safe to call concurrently across
    /// many messages.
    func prepare(message: DecodedMessage) async throws -> PreparedIncomingMessage {
        let encodedContentType = try message.encodedContent.type
        let dbMessage = try message.dbRepresentation()
        return PreparedIncomingMessage(
            source: message,
            encodedContentType: encodedContentType,
            dbMessage: dbMessage
        )
    }

    /// Synchronous, transaction-scoped. Returns `nil` when the message
    /// is dropped intentionally (e.g. unverified-sender
    /// ConnectionGrantRequest); the caller turns that into the
    /// canonical "no-op" result.
    func persist(
        _ prepared: PreparedIncomingMessage,
        conversation: DBConversation,
        in db: Database
    ) throws -> IncomingMessageWriterResult? {
        let source = prepared.source
        let encodedContentType = prepared.encodedContentType
        let senderVerified = try Self.bootstrapSenderProfile(
            db: db,
            senderInboxId: source.senderInboxId
        )

        // Defense against unverified or spoofed CloudConnectionGrantRequest senders:
        // only persist grant requests whose sender is a verified Convos agent
        // in this conversation. Anything else gets dropped silently with a warning
        // so the UI never has a chance to render the deep-link card.
        if encodedContentType == ContentTypeCloudConnectionGrantRequest, !senderVerified {
            Log.warning("Dropping CloudConnectionGrantRequest from unverified sender \(source.senderInboxId) in \(conversation.id)")
            return nil
        }

        let message = prepared.dbMessage

        let messageExistsInDB = try DBMessage.exists(db, key: message.id)
        let localInboxId = try DBInbox.currentInboxId(db)
        let wasRemovedFromConversation: Bool = {
            guard let localInboxId, let update = message.update else { return false }
            // A self-leave echo (leave-request the local user sent) names the
            // local inbox as both initiator and removed member; it must not
            // set the removed-by-someone-else marker -- the leave flow already
            // hid the conversation via the consent path.
            guard update.initiatedByInboxId != localInboxId else { return false }
            return update.removedInboxIds.contains(localInboxId)
        }()

        Log.debug("Storing incoming message \(message.id) localId \(message.clientMessageId) echoDateNs=\(message.dateNs)")
        if !message.attachmentUrls.isEmpty {
            Log.debug("[IncomingMessageWriter] Incoming attachmentUrls: \(message.attachmentUrls.map { $0.prefix(80) })")
        }
        // see if this message has a local version
        if let localMessage = try DBMessage
            .filter(DBMessage.Columns.id == message.id)
            .filter(DBMessage.Columns.clientMessageId != message.id)
            .fetchOne(db) {
            // Keep using the same local clientMessageId, sortId, and attachmentUrls
            // Preserving attachmentUrls is critical for maintaining AttachmentLocalState lookup
            Log.debug("BRANCH 1: Found local message \(localMessage.clientMessageId) for incoming message \(message.id)")
            let updatedMessage = message
                .with(clientMessageId: localMessage.clientMessageId)
                .with(sortId: localMessage.sortId)
                .with(attachmentUrls: localMessage.attachmentUrls)
            try updatedMessage.save(db)
            Log.debug("BRANCH 1: Updated with clientMessageId=\(localMessage.clientMessageId), sortId=\(localMessage.sortId ?? -1)")
        } else if let existingMessage = try DBMessage.fetchOne(db, key: message.id),
                  existingMessage.hasLocalAttachments {
            // Message exists with local attachment URLs (outgoing photo) - preserve them and sortId
            Log.debug("BRANCH 2: Preserving local attachments for message \(message.id)")
            let updatedMessage = message
                .with(attachmentUrls: existingMessage.attachmentUrls)
                .with(sortId: existingMessage.sortId)
            try updatedMessage.save(db)
            Log.debug("BRANCH 2: Saved with local attachments, sortId=\(existingMessage.sortId ?? -1)")
        } else if let existingMessage = try DBMessage.fetchOne(db, key: message.id) {
            // Message exists but BRANCH 1 and BRANCH 2 didn't match
            // Keep clientMessageId, sortId, and attachmentUrls for stable UI identity
            // Preserving attachmentUrls is critical: we've migrated AttachmentLocalState
            // to match our local key, so using the incoming key would break the lookup
            Log.debug("BRANCH 3: Found existing message \(message.id)")
            if !existingMessage.attachmentUrls.isEmpty || !message.attachmentUrls.isEmpty {
                Log.debug("[BRANCH 3] Existing attachmentUrls: \(existingMessage.attachmentUrls.map { $0.prefix(80) })")
                Log.debug("[BRANCH 3] Incoming attachmentUrls: \(message.attachmentUrls.map { $0.prefix(80) })")
                let keysMatch = existingMessage.attachmentUrls == message.attachmentUrls
                Log.debug("[BRANCH 3] Keys match: \(keysMatch), preserving existing")
            }
            let updatedMessage = message
                .with(clientMessageId: existingMessage.clientMessageId)
                .with(sortId: existingMessage.sortId)
                .with(attachmentUrls: existingMessage.attachmentUrls)
            try updatedMessage.save(db)
            Log.debug("BRANCH 3: Saved with clientMessageId=\(existingMessage.clientMessageId), sortId=\(existingMessage.sortId ?? -1)")
        } else {
            // Truly new incoming message - assign sortId based on chronological position.
            // Find the correct insertion point by dateNs so messages from the NSE
            // and main app always end up in chronological order regardless of
            // which process writes first.
            let newSortId = try Self.chronologicalSortId(
                for: message.dateNs,
                messageId: message.id,
                conversationId: conversation.id,
                in: db
            )
            let messageWithSortId = message.with(sortId: newSortId)

            do {
                try messageWithSortId.save(db)
                Log.debug("BRANCH 4 (new): Saved incoming message: \(message.id) with sortId=\(newSortId)")
            } catch {
                Log.error("Failed saving incoming message \(message.id): \(error)")
                throw error
            }
        }

        if let update = message.update, !update.addedInboxIds.isEmpty {
            for addedInboxId in update.addedInboxIds {
                try DBConversationMember
                    .filter(DBConversationMember.Columns.conversationId == conversation.id)
                    .filter(DBConversationMember.Columns.inboxId == addedInboxId)
                    .filter(DBConversationMember.Columns.invitedByInboxId == nil)
                    .updateAll(db, DBConversationMember.Columns.invitedByInboxId.set(to: update.initiatedByInboxId))
            }
            // A membership add supersedes any pending-leave marker the same
            // inbox announced before it (rejoin after an earlier departure
            // finalized). Bounded by the add's timestamp because backlog
            // catch-up processes newest-first: an older add ingested late
            // must not clear the marker of a leave that happened after it.
            try Self.clearMemberDepartures(
                conversationId: conversation.id,
                inboxIds: update.addedInboxIds,
                beforeNs: message.dateNs,
                in: db
            )
        }

        // Gated on first ingest: the message row and the departure write
        // commit in the same transaction, so a re-encounter (NSE and main
        // app share the database) means the departure was already applied.
        // Re-applying would wrongly re-mark a member who has since rejoined.
        if encodedContentType == ContentTypeLeaveRequest, !messageExistsInDB {
            try Self.applyMemberDeparture(
                conversationId: conversation.id,
                inboxId: source.senderInboxId,
                dateNs: message.dateNs,
                in: db
            )
        }

        if wasRemovedFromConversation {
            try Self.persistRemovedMarker(conversationId: conversation.id, in: db)
        }

        return IncomingMessageWriterResult(
            contentType: message.contentType,
            wasRemovedFromConversation: wasRemovedFromConversation,
            messageAlreadyExists: messageExistsInDB
        )
    }

    /// Marks the conversation as removed-for-the-local-user. Idempotent and
    /// deliberately independent of `messageAlreadyExists`: when the NSE saves
    /// the removal `GroupUpdated` message first, the main app re-encounters it
    /// as an existing row and must still converge on the persisted marker.
    /// Cleared by `ConversationWriter.persist` when a synced member list
    /// includes the local inbox again (re-add or rejoin).
    static func persistRemovedMarker(conversationId: String, in db: Database) throws {
        let current = try ConversationLocalState
            .filter(ConversationLocalState.Columns.conversationId == conversationId)
            .fetchOne(db)
            ?? ConversationLocalState(
                conversationId: conversationId,
                isPinned: false,
                isUnread: false,
                isUnreadUpdatedAt: Date.distantPast,
                isMuted: false,
                pinnedOrder: nil,
                hidesInviteCard: false,
                leftHostedInviteSession: false,
                wasRemoved: false,
                hasHadOtherMembers: false,
                hasSharedInvite: false
            )
        guard !current.wasRemoved else { return }
        // Unpinning here frees the pin slot a hidden conversation would
        // otherwise occupy invisibly (the pin limit and pinned count both
        // read isPinned rows).
        try current
            .with(wasRemoved: true)
            .with(isPinned: false)
            .with(pinnedOrder: nil)
            .save(db)
    }

    /// Records a member's announced departure and drops their member row so
    /// every member-list surface loses the leaver promptly. The departure
    /// marker keeps `ConversationWriter.persist` from re-adding the row while
    /// the MLS roster still lists the leaver (the remove-commit is finalized
    /// asynchronously by an authorized client). Idempotent: re-ingesting the
    /// same leave-request (NSE + main app) upserts the same marker.
    ///
    /// Order-aware: backlog catch-up processes messages newest-first, so a
    /// rejoin-add can already be stored when an older leave-request is first
    /// ingested. Applying that stale leave would hide a current member behind
    /// a marker no later event clears, so it is skipped when a newer
    /// membership add for the same inbox exists.
    static func applyMemberDeparture(
        conversationId: String,
        inboxId: String,
        dateNs: Int64,
        in db: Database
    ) throws {
        guard try !hasNewerMembershipAdd(
            conversationId: conversationId,
            inboxId: inboxId,
            afterNs: dateNs,
            in: db
        ) else {
            Log.info("Skipping stale leave-request for \(inboxId) in \(conversationId): a newer membership add exists")
            return
        }
        try DBMemberDeparture(
            conversationId: conversationId,
            inboxId: inboxId,
            dateNs: dateNs
        ).save(db)
        try DBConversationMember
            .filter(DBConversationMember.Columns.conversationId == conversationId)
            .filter(DBConversationMember.Columns.inboxId == inboxId)
            .deleteAll(db)
    }

    /// Clears pending-leave markers for inboxes a membership change re-added.
    /// Without this a member who left and later rejoined would stay filtered
    /// out of the member list by their stale departure marker. Only markers
    /// older than the add event (`beforeNs`) are cleared: with newest-first
    /// backlog processing an older add can be ingested after a newer leave,
    /// and it must not erase that leave's marker.
    static func clearMemberDepartures(
        conversationId: String,
        inboxIds: [String],
        beforeNs: Int64,
        in db: Database
    ) throws {
        try DBMemberDeparture
            .filter(DBMemberDeparture.Columns.conversationId == conversationId)
            .filter(inboxIds.contains(DBMemberDeparture.Columns.inboxId))
            .filter(DBMemberDeparture.Columns.dateNs < beforeNs)
            .deleteAll(db)
    }

    /// True when a stored membership update newer than `afterNs` added the
    /// inbox to the conversation -- the signal that a leave-request being
    /// ingested is stale (the member has since rejoined). Scans stored
    /// update-type messages because the `update` payload lives in a JSON
    /// column; updates newer than a given message are rare, and the cost is
    /// only paid on leave-request ingest.
    private static func hasNewerMembershipAdd(
        conversationId: String,
        inboxId: String,
        afterNs: Int64,
        in db: Database
    ) throws -> Bool {
        let newerUpdates = try DBMessage
            .filter(DBMessage.Columns.conversationId == conversationId)
            .filter(DBMessage.Columns.contentType == MessageContentType.update.rawValue)
            .filter(DBMessage.Columns.dateNs > afterNs)
            .fetchAll(db)
        return newerUpdates.contains { $0.update?.addedInboxIds.contains(inboxId) == true }
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

        let prepared = try await prepare(message: message)
        let result = try await databaseWriter.write { [self] db in
            try persist(prepared, conversation: conversation, in: db)
        }

        // Dropped messages (e.g. unverified-sender ConnectionGrantRequests) return
        // nil from persist so the rest of the ingest pipeline treats them
        // as a no-op rather than a new message.
        guard let result else {
            return IncomingMessageWriterResult(
                contentType: .connectionGrantRequest,
                wasRemovedFromConversation: false,
                messageAlreadyExists: true
            )
        }

        if !result.messageAlreadyExists {
            QAEvent.emit(.message, "received", [
                "id": message.id,
                "conversation": conversation.id,
                "sender": message.senderInboxId,
                "type": result.contentType.rawValue
            ])
        }

        // Post notification after transaction commits. Not gated on
        // messageAlreadyExists: when the NSE saved the removal message first,
        // the main app still needs the live-hide. The persisted wasRemoved
        // marker (set in persist) is the restart-safe source of truth; this
        // notification is the in-session UX fast path.
        if result.wasRemovedFromConversation {
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
                Log.debug("Updated existing reaction \(existingReaction.id) status to published")
                return true
            } else {
                let dbMessage = try message.dbRepresentation()
                try dbMessage.save(db)
                Log.debug("Saved new incoming reaction \(message.id)")
                return false
            }
        }
        if !reactionAlreadyExists {
            QAEvent.emit(.reaction, "received", [
                "message": reaction.reference,
                "emoji": reaction.emoji,
                "sender": message.senderInboxId,
                "conversation": conversation.id
            ])
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
            Log.debug("Deleted \(deletedCount) reaction(s) for message \(reaction.reference) from \(message.senderInboxId)")
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

    /// Ensures the sender has a row in `DBMember`. Returns true when the sender's
    /// canonical profile is already marked as a verified Convos agent - used to
    /// gate persisting sensitive content types whose rendering assumes the sender
    /// is trusted. Verification is read from the per-inbox `profile` table, where
    /// the inbound seam stores the resolved (attested) member kind.
    static func bootstrapSenderProfile(
        db: Database,
        senderInboxId: String
    ) throws -> Bool {
        let sender = DBMember(inboxId: senderInboxId)
        try sender.save(db)
        let identity = try DBProfile.fetchOne(db, inboxId: senderInboxId)
        return identity?.memberKind?.agentVerification.isConvosAgent ?? false
    }

    /// Computes a sortId that places the message in chronological order within the conversation.
    ///
    /// Instead of always appending (`MAX(sortId) + 1`), this finds the correct position
    /// based on `dateNs` and shifts later messages to make room. This ensures messages
    /// processed out of order (e.g., by the NSE vs main app) still display chronologically.
    ///
    /// Tiebreaker: when two messages share the same `dateNs`, the message with the
    /// lexicographically smaller `id` (XMTP hex-encoded message IDs) is placed first
    /// for deterministic ordering.
    ///
    /// Performance: the shift operation is O(n) where n is the number of messages after
    /// the insertion point. This is acceptable because (a) most incoming messages append
    /// to the end (no shift needed), and (b) the out-of-order case from NSE catch-up
    /// typically involves only a few messages near the tail. The existing
    /// `(conversationId, sortId)` index keeps the UPDATE efficient.
    static func chronologicalSortId(
        for dateNs: Int64,
        messageId: String,
        conversationId: String,
        in db: Database
    ) throws -> Int64 {
        // Find the sortId of the message that should come immediately before this one.
        // "Before" means: smaller dateNs, or same dateNs with smaller id (tiebreaker).
        // Reactions have nil sortId and are excluded via the IS NOT NULL filter.
        let predecessorSortId = try Int64.fetchOne(db, sql: """
            SELECT sortId FROM message
            WHERE conversationId = ?
              AND sortId IS NOT NULL
              AND (dateNs < ? OR (dateNs = ? AND id < ?))
            ORDER BY dateNs DESC, id DESC
            LIMIT 1
        """, arguments: [conversationId, dateNs, dateNs, messageId])

        // 0 means no predecessor found — this message is the oldest in the conversation
        let insertAfter = predecessorSortId ?? 0

        // Shift all messages with sortId > insertAfter up by 1 to make room
        try db.execute(sql: """
            UPDATE message SET sortId = sortId + 1
            WHERE conversationId = ? AND sortId > ?
        """, arguments: [conversationId, insertAfter])

        return insertAfter + 1
    }

    func processExplodeSettings(
        _ settings: ExplodeSettings,
        conversationId: String,
        senderInboxId: String,
        currentInboxId: String
    ) async -> ExplodeSettingsResult {
        if senderInboxId == currentInboxId {
            Log.debug("ExplodeSettings: from self, skipping")
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
                Log.debug("ExplodeSettings: conversation not found or already has expiresAt, skipping")
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
