import ConvosInvites
import Foundation
import GRDB
@preconcurrency import XMTPiOS

extension DecodedMessage {
    var isProfileMessage: Bool {
        guard let contentType = try? encodedContent.type else { return false }
        return contentType == ContentTypeProfileUpdate || contentType == ContentTypeProfileSnapshot
    }

    var isTypingIndicator: Bool {
        guard let contentType = try? encodedContent.type else { return false }
        return contentType.authorityID == ContentTypeTypingIndicator.authorityID
            && contentType.typeID == ContentTypeTypingIndicator.typeID
    }

    var isReadReceipt: Bool {
        guard let contentType = try? encodedContent.type else { return false }
        return contentType.authorityID == ContentTypeReadReceipt.authorityID
            && contentType.typeID == ContentTypeReadReceipt.typeID
    }

    var isThinking: Bool {
        guard let contentType = try? encodedContent.type else { return false }
        return contentType.authorityID == ContentTypeThinking.authorityID
            && contentType.typeID == ContentTypeThinking.typeID
    }
}

enum ConversationWriterError: Error {
    case inboxNotFound(String)
    case expectedGroup
    case invalidInvite(String)
}

protocol ConversationWriterProtocol: Sendable {
    @discardableResult
    func store(
        conversation: XMTPiOS.Group,
        inboxId: String,
        clientConversationId: String?
    ) async throws -> DBConversation
    @discardableResult
    func storeWithLatestMessages(
        conversation: XMTPiOS.Group,
        inboxId: String,
        clientConversationId: String?
    ) async throws -> DBConversation
    func createPlaceholderConversation(
        draftConversationId: String?,
        for signedInvite: SignedInvite,
        inboxId: String
    ) async throws -> String
}

extension ConversationWriterProtocol {
    @discardableResult
    func store(
        conversation: XMTPiOS.Group,
        inboxId: String
    ) async throws -> DBConversation {
        try await store(conversation: conversation, inboxId: inboxId, clientConversationId: nil)
    }

    @discardableResult
    func storeWithLatestMessages(
        conversation: XMTPiOS.Group,
        inboxId: String
    ) async throws -> DBConversation {
        try await storeWithLatestMessages(
            conversation: conversation,
            inboxId: inboxId,
            clientConversationId: nil
        )
    }
}

// swiftlint:disable type_body_length
class ConversationWriter: ConversationWriterProtocol, @unchecked Sendable {
    private let databaseWriter: any DatabaseWriter
    private let inviteWriter: any InviteWriterProtocol
    private let messageWriter: any IncomingMessageWriterProtocol
    private let localStateWriter: any ConversationLocalStateWriterProtocol
    private let thinkingSessionWriter: any ThinkingSessionWriterProtocol
    private let contactSyncCoordinator: (any ContactSyncCoordinatorProtocol)?

    init(identityStore: any KeychainIdentityStoreProtocol,
         databaseWriter: any DatabaseWriter,
         messageWriter: any IncomingMessageWriterProtocol,
         contactSyncCoordinator: (any ContactSyncCoordinatorProtocol)? = nil) {
        self.databaseWriter = databaseWriter
        self.inviteWriter = InviteWriter(
            identityStore: identityStore,
            databaseWriter: databaseWriter
        )
        self.messageWriter = messageWriter
        self.localStateWriter = ConversationLocalStateWriter(databaseWriter: databaseWriter)
        self.thinkingSessionWriter = ThinkingSessionWriter(databaseWriter: databaseWriter)
        self.contactSyncCoordinator = contactSyncCoordinator
    }

    /// Fires the contact-sync coordinator with `force: true` after a
    /// network-driven conversation/member commit. The coordinator's
    /// action-gated check skips never-synced conversations, so this only
    /// surfaces new members in groups the local user has already acted in.
    /// Fire-and-forget; errors are logged.
    private func enqueueContactSyncForNetworkChange(conversationId: String) {
        guard let coordinator = contactSyncCoordinator else { return }
        Task.detached {
            do {
                try await coordinator.syncContactsAfterMembershipChange(for: conversationId)
            } catch {
                Log.error("Contact sync after network member change failed for \(conversationId): \(error)")
            }
        }
    }

    func store(
        conversation: XMTPiOS.Group,
        inboxId: String,
        clientConversationId: String? = nil
    ) async throws -> DBConversation {
        return try await _store(
            conversation: conversation,
            inboxId: inboxId,
            clientConversationId: clientConversationId
        )
    }

    func storeWithLatestMessages(
        conversation: XMTPiOS.Group,
        inboxId: String,
        clientConversationId: String? = nil
    ) async throws -> DBConversation {
        return try await _store(
            conversation: conversation,
            inboxId: inboxId,
            withLatestMessages: true,
            clientConversationId: clientConversationId
        )
    }

    func createPlaceholderConversation(
        draftConversationId: String? = nil,
        for signedInvite: SignedInvite,
        inboxId: String
    ) async throws -> String {
        let draftConversationId = draftConversationId ?? DBConversation.generateDraftConversationId()

        // Create the draft conversation and necessary records
        let creatorInboxId = signedInvite.invitePayload.creatorInboxIdString

        // validate that the invite contains a non-empty creator inbox ID
        guard !creatorInboxId.isEmpty else {
            throw ConversationWriterError.invalidInvite("Empty creator inbox ID")
        }

        let conversation = try await databaseWriter.write { db in
            // Downstream foreign-key lookups (push topic subscriptions,
            // etc.) expect the inbox row to exist.
            guard (try DBInbox.fetchOne(db, id: inboxId)) != nil else {
                throw ConversationWriterError.inboxNotFound(inboxId)
            }

            let conversation = DBConversation(
                id: draftConversationId,
                clientConversationId: draftConversationId,
                inviteTag: signedInvite.invitePayload.tag,
                creatorId: creatorInboxId,
                kind: .group,
                consent: .allowed,
                createdAt: Date(),
                name: signedInvite.name,
                description: signedInvite.description_p,
                imageURLString: signedInvite.imageURL,
                publicImageURLString: nil,
                includeInfoInPublicPreview: true,
                expiresAt: signedInvite.conversationExpiresAt,
                debugInfo: .empty,
                isLocked: false,
                imageSalt: nil,
                imageNonce: nil,
                imageEncryptionKey: nil,
                conversationEmoji: signedInvite.emoji,
                imageLastRenewed: nil,
                isUnused: false,
                hasHadVerifiedAgent: false
            )
            try conversation.save(db)
            let memberProfile = DBMemberProfile(
                conversationId: draftConversationId,
                inboxId: creatorInboxId,
                name: nil,
                avatar: nil
            )
            let member = DBMember(inboxId: creatorInboxId)
            try member.save(db)
            try memberProfile.save(db)

            let localState = ConversationLocalState(
                conversationId: conversation.id,
                isPinned: false,
                isUnread: false,
                isUnreadUpdatedAt: Date(),
                isMuted: false,
                pinnedOrder: nil,
                hidesInviteCard: false
            )
            try localState.save(db)

            let conversationMember = DBConversationMember(
                conversationId: conversation.id,
                inboxId: creatorInboxId,
                role: .member,
                consent: .allowed,
                createdAt: Date(),
                invitedByInboxId: nil
            )
            try conversationMember.save(db)

            Log.debug("Created placeholder conversation for invite")
            return conversation
        }

        return conversation.id
    }

    /// A `DBConversation` row + its members and profiles, fully resolved from
    /// XMTP but not yet written to the local DB. Built by `prepare(...)`,
    /// consumed by `persist(_:in:)`.
    ///
    /// The split lets the batch catch-up path fan out N parallel `prepare`
    /// calls (each does XMTP network work) and then collapse the N
    /// `persist` calls into a single GRDB transaction — one observer fire
    /// for the whole backlog instead of N. The stream path threads them
    /// sequentially via `_store` and is byte-equivalent to the old shape.
    struct PreparedConversation {
        let dbConversation: DBConversation
        let dbMembers: [DBConversationMember]
        let memberProfiles: [DBMemberProfile]
    }

    /// Async, network-bound, transaction-free. Safe to call concurrently for
    /// many conversations.
    func prepare(
        conversation: XMTPiOS.Group,
        inboxId: String,
        clientConversationId: String? = nil
    ) async throws -> PreparedConversation {
        try await conversation.sync()
        let metadata = try await extractConversationMetadata(from: conversation)
        let members = try await conversation.members
        let dbMembers = members.map { $0.dbRepresentation(conversationId: conversation.id) }
        let memberProfiles = try conversation.memberProfiles
        let dbConversation = try await createDBConversation(
            from: conversation,
            metadata: metadata,
            inboxId: inboxId,
            clientConversationId: clientConversationId,
            imageLastRenewed: nil
        )
        return PreparedConversation(
            dbConversation: dbConversation,
            dbMembers: dbMembers,
            memberProfiles: memberProfiles
        )
    }

    /// Synchronous, transaction-scoped. Call inside `databaseWriter.write { db in ... }`.
    /// Idempotent: replay-safe thanks to `saveConversation`'s no-op diff
    /// short-circuit + the `onConflict: .ignore` localState insert.
    func persist(_ prepared: PreparedConversation, in db: Database) throws -> ConversationSaveResult {
        let creator = DBMember(inboxId: prepared.dbConversation.creatorId)
        try creator.save(db)

        // Save conversation (handle local conversation updates).
        // Also handles imageLastRenewed preservation inside the transaction.
        let saveResult = try saveConversation(prepared.dbConversation, in: db)

        // Save local state
        let localState = ConversationLocalState(
            conversationId: prepared.dbConversation.id,
            isPinned: false,
            isUnread: false,
            isUnreadUpdatedAt: Date.distantPast,
            isMuted: false,
            pinnedOrder: nil,
            hidesInviteCard: false
        )
        try localState.insert(db, onConflict: .ignore)

        // Remove conversation_members rows for members no longer in the group
        let currentMemberInboxIds = Set(prepared.dbMembers.map(\.inboxId))
        if !currentMemberInboxIds.isEmpty {
            try DBConversationMember
                .filter(DBConversationMember.Columns.conversationId == prepared.dbConversation.id)
                .filter(!currentMemberInboxIds.contains(DBConversationMember.Columns.inboxId))
                .deleteAll(db)
        }

        try saveMembers(prepared.dbMembers, in: db)

        // Fill gaps: only write appData profiles for members without message-sourced data
        try prepared.memberProfiles.forEach { profile in
            let existing = try DBMemberProfile.fetchOne(
                db,
                conversationId: prepared.dbConversation.id,
                inboxId: profile.inboxId
            )
            if existing?.name != nil || existing?.avatar != nil || existing?.memberKind != nil {
                return
            }
            let member = DBMember(inboxId: profile.inboxId)
            try member.save(db)
            try profile.save(db)
        }

        return saveResult
    }

    /// Post-persist side effects the stream path runs after each individual
    /// save. The batch catch-up path runs them per-conversation off the
    /// foreground critical path after its single transaction commits, so
    /// the user-visible foreground latency only includes prepare + persist.
    ///
    /// `saveResult` is required because `saveConversation` may resolve a
    /// different `clientConversationId` than the one on the incoming
    /// `PreparedConversation` (e.g. a sticky draft id wins over the XMTP
    /// group id — see ClientConversationIdPriorityTests). The image cache
    /// has to key off the *actual* persisted id so the UI lookups find it.
    /// Passing nil for `oldImageURL` is acceptable here because the batch
    /// persists multiple rows in one transaction and doesn't track per-row
    /// old URLs; the prefetcher then fetches unconditionally, the right
    /// default for a freshly-synced conversation.
    func runPostPersistSideEffects(
        prepared: PreparedConversation,
        saveResult: ConversationSaveResult,
        group: XMTPiOS.Group
    ) async {
        enqueueContactSyncForNetworkChange(conversationId: prepared.dbConversation.id)
        prefetchEncryptedImages(profiles: prepared.memberProfiles, group: group)
        prefetchEncryptedGroupImage(
            cacheId: saveResult.clientConversationId,
            group: group,
            oldImageURL: nil
        )
        do {
            _ = try await inviteWriter.generate(
                for: prepared.dbConversation,
                expiresAt: nil,
                expiresAfterUse: false
            )
        } catch {
            Log.error("Invite generation skipped for conversation \(prepared.dbConversation.id): \(error)")
        }
        await processProfileMessagesFromHistory(conversation: group)
    }

    /// Apply the supplemental messages (reactions, read receipts) the batch
    /// catch-up filter excluded from the main transaction. Each gets its
    /// own small transaction via the existing per-type handlers — same
    /// loop body as `fetchAndStoreLatestMessages:704-721`. Without this,
    /// reactions and read receipts that arrived while the device was
    /// offline are filtered out by `isStorableForBatch` and never picked
    /// up: libxmtp's `streamAllMessages` only delivers events from the
    /// connection time forward, it does not replay historical backlog.
    func applyBacklogSupplementals(
        _ messages: [XMTPiOS.DecodedMessage],
        for conversation: DBConversation,
        currentInboxId: String
    ) async {
        for message in messages {
            guard !message.isProfileMessage, !message.isTypingIndicator else {
                continue
            }
            if message.isReadReceipt {
                await storeReadReceipt(message, conversationId: conversation.id)
                continue
            }
            if message.isThinking {
                await storeThinking(message, conversationId: conversation.id, currentInboxId: currentInboxId)
                continue
            }
            do {
                _ = try await messageWriter.store(message: message, for: conversation)
            } catch {
                Log.error("Failed to apply backlog supplemental message \(message.id) in \(conversation.id): \(error)")
            }
        }
    }

    /// Mark a conversation unread. Exposed so `BatchCatchUp` can mirror
    /// the stream path's `fetchAndStoreLatestMessages` tail without
    /// reaching into `localStateWriter` directly.
    func markUnread(_ unread: Bool, for conversationId: String) async throws {
        try await localStateWriter.setUnread(unread, for: conversationId)
    }

    private func _store(
        conversation: XMTPiOS.Group,
        inboxId: String,
        withLatestMessages: Bool = false,
        clientConversationId: String? = nil
    ) async throws -> DBConversation {
        let prepared = try await prepare(
            conversation: conversation,
            inboxId: inboxId,
            clientConversationId: clientConversationId
        )

        // Persist in a single transaction. Capture the actual clientConversationId
        // used (may be a draft ID like "draft-XXX" instead of the XMTP group ID)
        // so cache notifications match the ID that ViewModels subscribe to.
        let saveResult = try await databaseWriter.write { [self] db in
            try persist(prepared, in: db)
        }

        // Network-driven member commit just landed (initial conversation
        // arrival or refresh-with-new-members). Fire the contact-sync
        // coordinator with `force: true`; the coordinator will skip if the
        // local user has not acted in this conversation yet (action-gated).
        enqueueContactSyncForNetworkChange(conversationId: prepared.dbConversation.id)

        if let preservedInviteTag = saveResult.preservedInviteTag,
           (try conversation.inviteTag).isEmpty {
            Log.warning("[MetadataDebug] preserving local invite tag and attempting self-heal for groupId=\(conversation.id) tag=\(preservedInviteTag)")
            do {
                try await conversation.restoreInviteTagIfMissing(preservedInviteTag)
            } catch {
                Log.error("[MetadataDebug] failed self-heal for groupId=\(conversation.id): \(error.localizedDescription)")
            }
        }

        // Prefetch encrypted profile images in background
        prefetchEncryptedImages(profiles: prepared.memberProfiles, group: conversation)

        // Prefetch encrypted group image in background (invalidate old URL if changed).
        // The incoming image URL lives on the prepared DBConversation (createDBConversation
        // builds it from metadata.imageURLString verbatim).
        prefetchEncryptedGroupImage(
            cacheId: saveResult.clientConversationId,
            group: conversation,
            oldImageURL: saveResult.oldImageURL != prepared.dbConversation.imageURLString ? saveResult.oldImageURL : nil
        )

        do {
            _ = try await inviteWriter.generate(
                for: prepared.dbConversation,
                expiresAt: nil,
                expiresAfterUse: false
            )
        } catch {
            Log.error("Invite generation skipped for conversation \(prepared.dbConversation.id): \(error)")
        }

        // Fetch and store latest messages if requested
        if withLatestMessages {
            try await fetchAndStoreLatestMessages(
                for: conversation,
                dbConversation: prepared.dbConversation,
                currentInboxId: inboxId
            )
        }

        // Store last message (skip profile messages and read receipts which aren't stored as DB messages)
        let lastMessage = try await conversation.lastMessage()
        if let lastMessage, !lastMessage.isProfileMessage, !lastMessage.isTypingIndicator, !lastMessage.isReadReceipt, !lastMessage.isThinking {
            let result = try await messageWriter.store(
                message: lastMessage,
                for: prepared.dbConversation
            )
            Log.debug("Saved last message: \(result)")
        }

        // Process profile messages from history to populate member profiles
        await processProfileMessagesFromHistory(conversation: conversation)

        return prepared.dbConversation
    }

    // MARK: - Helper Methods

    private struct ConversationMetadata {
        let kind: ConversationKind
        let name: String?
        let description: String?
        let imageURLString: String?
        let imageSalt: Data?
        let imageNonce: Data?
        let imageEncryptionKey: Data?
        let conversationEmoji: String?
        let expiresAt: Date?
        let debugInfo: ConversationDebugInfo
        let isLocked: Bool
        let hasHadVerifiedAgent: Bool
    }

    private func extractConversationMetadata(from conversation: XMTPiOS.Group) async throws -> ConversationMetadata {
        let debugInfo = try await conversation.getDebugInformation().toDBDebugInfo()
        let permissionPolicy = try conversation.permissionPolicySet()
        let isLocked = permissionPolicy.addMemberPolicy == .deny

        let encryptedRef = try? conversation.encryptedGroupImage
        let imageEncryptionKey = try? conversation.imageEncryptionKey
        let conversationEmoji = try? conversation.conversationEmoji
        Log.info("extractConversationMetadata: emoji=\(conversationEmoji ?? "nil") for convo: \(conversation.id)")

        return ConversationMetadata(
            kind: .group,
            name: try conversation.name(),
            description: try conversation.description(),
            imageURLString: try conversation.imageUrl(),
            imageSalt: encryptedRef?.salt,
            imageNonce: encryptedRef?.nonce,
            imageEncryptionKey: imageEncryptionKey,
            conversationEmoji: conversationEmoji,
            expiresAt: try conversation.expiresAt,
            debugInfo: debugInfo,
            isLocked: isLocked,
            hasHadVerifiedAgent: false
        )
    }

    private func createDBConversation(
        from conversation: XMTPiOS.Group,
        metadata: ConversationMetadata,
        inboxId: String,
        clientConversationId: String? = nil,
        imageLastRenewed: Date? = nil
    ) async throws -> DBConversation {
        // Assert the inbox exists locally even though the column no longer
        // lives on the conversation row — readers expect an inbox row for the
        // identity and downstream foreign keys still reference it.
        _ = try await databaseWriter.read { db in
            guard let inbox = try DBInbox.fetchOne(db, id: inboxId) else {
                throw ConversationWriterError.inboxNotFound(inboxId)
            }
            return inbox.clientId
        }

        return DBConversation(
            id: conversation.id,
            clientConversationId: clientConversationId ?? conversation.id,
            inviteTag: try conversation.inviteTag,
            creatorId: try await conversation.creatorInboxId(),
            kind: metadata.kind,
            consent: try conversation.consentState().consent,
            createdAt: conversation.createdAt,
            name: metadata.name,
            description: metadata.description,
            imageURLString: metadata.imageURLString,
            publicImageURLString: nil,
            includeInfoInPublicPreview: true,
            expiresAt: metadata.expiresAt,
            debugInfo: metadata.debugInfo,
            isLocked: metadata.isLocked,
            imageSalt: metadata.imageSalt,
            imageNonce: metadata.imageNonce,
            imageEncryptionKey: metadata.imageEncryptionKey,
            conversationEmoji: metadata.conversationEmoji,
            imageLastRenewed: imageLastRenewed,
            isUnused: false,
            hasHadVerifiedAgent: metadata.hasHadVerifiedAgent
        )
    }

    struct ConversationSaveResult {
        let clientConversationId: String
        let oldImageURL: String?
        let preservedInviteTag: String?
    }

    /// Returns the actual clientConversationId used (may differ from input if a local draft exists),
    /// and the old image URL for cache invalidation purposes.
    /// Also handles preserving imageLastRenewed inside the transaction (GRDB's serialized write queue
    /// ensures atomic read-modify-write, preventing concurrent asset renewal from losing timestamps).
    private func saveConversation(
        _ dbConversation: DBConversation,
        in db: Database
    ) throws -> ConversationSaveResult {
        let firstTimeSeeingConversationExpired: Bool
        let actualClientConversationId: String
        let oldImageURL: String?
        let preservedInviteTag: String?

        // Fetch current conversation state inside the transaction to avoid race conditions
        // with concurrent asset renewal that might update imageLastRenewed
        let existingConversation = try DBConversation.fetchOne(db, key: dbConversation.id)
        oldImageURL = existingConversation?.imageURLString

        // Preserve imageLastRenewed if the image URL hasn't changed
        let imageLastRenewed: Date?
        if oldImageURL == dbConversation.imageURLString {
            imageLastRenewed = existingConversation?.imageLastRenewed
        } else {
            imageLastRenewed = nil
        }

        // Apply the preserved timestamp
        var conversationToSave = dbConversation.with(imageLastRenewed: imageLastRenewed)

        if dbConversation.inviteTag.isEmpty,
           let existingConversation,
           !existingConversation.inviteTag.isEmpty {
            conversationToSave = conversationToSave.with(inviteTag: existingConversation.inviteTag)
            Log.warning(
                "[MetadataDebug] preserving existing local invite tag for conversationId=\(dbConversation.id) preservedTag=\(existingConversation.inviteTag)"
            )
            preservedInviteTag = existingConversation.inviteTag
        } else {
            preservedInviteTag = nil
        }

        // Preserve fields from the existing row that the caller did not
        // explicitly carry forward: `hasHadVerifiedAgent` is sticky-on
        // (once true, stays true).
        if let existingConversation {
            let mergedHasAgent: Bool = existingConversation.hasHadVerifiedAgent || conversationToSave.hasHadVerifiedAgent
            conversationToSave = conversationToSave.with(hasHadVerifiedAgent: mergedHasAgent)
        }

        let existingConversationByTag = try existingConversationMatchingInviteTag(
            inviteTag: dbConversation.inviteTag,
            excludingConversationId: dbConversation.id,
            in: db
        )

        let conversationSaveLog: String = "Conversation save attempt. " +
            "incomingId=\(dbConversation.id) " +
            "incomingClientConversationId=\(dbConversation.clientConversationId) " +
            "incomingInviteTag=\(dbConversation.inviteTag) " +
            "hasExistingById=\(existingConversation != nil) " +
            "existingByIdClientConversationId=\(existingConversation?.clientConversationId ?? "nil") " +
            "existingByIdInviteTag=\(existingConversation?.inviteTag ?? "nil") " +
            "existingByTagId=\(existingConversationByTag?.id ?? "nil") " +
            "existingByTagClientConversationId=\(existingConversationByTag?.clientConversationId ?? "nil")"
        Log.info(conversationSaveLog)

        if let localConversation = existingConversationByTag {
            // Prefer draft IDs for stability (image caching, default emoji)
            let preferredClientConversationId: String
            if DBConversation.isDraft(id: dbConversation.clientConversationId) {
                preferredClientConversationId = dbConversation.clientConversationId
                Log.debug("Using incoming draft ID \(dbConversation.clientConversationId)")
            } else {
                preferredClientConversationId = localConversation.clientConversationId
                Log.debug("Keeping existing ID \(localConversation.clientConversationId)")
            }

            conversationToSave = conversationToSave
                .with(clientConversationId: preferredClientConversationId)
            if !localConversation.isUnused {
                conversationToSave = conversationToSave.with(createdAt: localConversation.createdAt)
            }
            // This row is replacing `localConversation`, so its sticky-on
            // agent flag must carry forward.
            let mergedHasAgentByTag: Bool = localConversation.hasHadVerifiedAgent || conversationToSave.hasHadVerifiedAgent
            conversationToSave = conversationToSave.with(hasHadVerifiedAgent: mergedHasAgentByTag)
            try conversationToSave.save(db, onConflict: .replace)
            firstTimeSeeingConversationExpired = conversationToSave.isExpired && conversationToSave.expiresAt != localConversation.expiresAt
            actualClientConversationId = preferredClientConversationId
        } else if let existingConversation {
            let updateOutcome = try updateExistingConversation(
                incoming: conversationToSave,
                existing: existingConversation,
                originalIncomingId: dbConversation.clientConversationId,
                in: db
            )
            firstTimeSeeingConversationExpired = updateOutcome.firstTimeSeeingConversationExpired
            actualClientConversationId = updateOutcome.actualClientConversationId
        } else {
            try conversationToSave.save(db)
            firstTimeSeeingConversationExpired = conversationToSave.isExpired
            actualClientConversationId = conversationToSave.clientConversationId
        }

        if firstTimeSeeingConversationExpired {
            Log.debug("Encountered expired conversation for the first time.")
        }

        return ConversationSaveResult(
            clientConversationId: actualClientConversationId,
            oldImageURL: oldImageURL,
            preservedInviteTag: preservedInviteTag
        )
    }

    private struct ExistingConversationUpdateOutcome {
        let firstTimeSeeingConversationExpired: Bool
        let actualClientConversationId: String
    }

    private func updateExistingConversation(
        incoming conversationToSave: DBConversation,
        existing existingConversation: DBConversation,
        originalIncomingId: String,
        in db: Database
    ) throws -> ExistingConversationUpdateOutcome {
        let preferredClientConversationId: String
        if originalIncomingId != existingConversation.clientConversationId {
            if DBConversation.isDraft(id: originalIncomingId) {
                preferredClientConversationId = originalIncomingId
            } else {
                preferredClientConversationId = existingConversation.clientConversationId
            }
        } else {
            preferredClientConversationId = originalIncomingId
        }

        var updatedConversation = conversationToSave.with(clientConversationId: preferredClientConversationId)
        if existingConversation.isUnused {
            updatedConversation = updatedConversation.with(isUnused: true)
        }
        if !existingConversation.isUnused {
            updatedConversation = updatedConversation.with(createdAt: existingConversation.createdAt)
        }
        if let existingExpiresAt = existingConversation.expiresAt, updatedConversation.expiresAt == nil {
            updatedConversation = updatedConversation.with(expiresAt: existingExpiresAt)
        }
        if let conflictingConversation = try existingConversationMatchingInviteTag(
            inviteTag: updatedConversation.inviteTag,
            excludingConversationId: updatedConversation.id,
            in: db
        ) {
            Log.error(
                "Invite tag collision before save. " +
                    "incomingId=\(updatedConversation.id) " +
                    "incomingClientConversationId=\(updatedConversation.clientConversationId) " +
                    "incomingInviteTag=\(updatedConversation.inviteTag) " +
                    "existingId=\(existingConversation.id) " +
                    "existingClientConversationId=\(existingConversation.clientConversationId) " +
                    "conflictingId=\(conflictingConversation.id) " +
                    "conflictingClientConversationId=\(conflictingConversation.clientConversationId) " +
                    "conflictingIsUnused=\(conflictingConversation.isUnused)"
            )
        }
        if updatedConversation == existingConversation {
            // Row would be byte-identical — skip the write so GRDB observers
            // don't fire and re-render the conversations list for no state
            // change. Common during catch-up bursts where the same row is
            // re-saved across many consecutive stream events. The
            // existing-by-tag and brand-new branches still write because
            // they're either replacing a different row or creating one.
            Log.debug("Skipped no-op conversation save for id=\(updatedConversation.id)")
        } else {
            try updatedConversation.save(db)
        }
        return ExistingConversationUpdateOutcome(
            firstTimeSeeingConversationExpired: updatedConversation.isExpired
                && updatedConversation.expiresAt != existingConversation.expiresAt,
            actualClientConversationId: preferredClientConversationId
        )
    }

    private func existingConversationMatchingInviteTag(
        inviteTag: String,
        excludingConversationId: String,
        in db: Database
    ) throws -> DBConversation? {
        guard !inviteTag.isEmpty else { return nil }
        return try DBConversation
            .filter(DBConversation.Columns.inviteTag == inviteTag)
            .filter(DBConversation.Columns.id != excludingConversationId)
            .fetchOne(db)
    }

    private func saveMembers(_ dbMembers: [DBConversationMember], in db: Database) throws {
        for member in dbMembers {
            try DBMember(inboxId: member.inboxId).save(db)
            let existing = try DBConversationMember
                .filter(DBConversationMember.Columns.conversationId == member.conversationId)
                .filter(DBConversationMember.Columns.inboxId == member.inboxId)
                .fetchOne(db)
            let memberToSave = DBConversationMember(
                conversationId: member.conversationId,
                inboxId: member.inboxId,
                role: member.role,
                consent: member.consent,
                createdAt: existing?.createdAt ?? member.createdAt,
                invitedByInboxId: existing?.invitedByInboxId ?? member.invitedByInboxId
            )
            try memberToSave.save(db)
            let memberProfile = DBMemberProfile(
                conversationId: member.conversationId,
                inboxId: member.inboxId,
                name: nil,
                avatar: nil
            )
            try? memberProfile.insert(db, onConflict: .ignore)
        }
    }

    private func fetchAndStoreLatestMessages(
        for conversation: XMTPiOS.Group,
        dbConversation: DBConversation,
        currentInboxId: String
    ) async throws {
        Log.debug("Attempting to fetch latest messages...")

        // Get the timestamp of the last stored message
        let lastMessageNs = try await getLastMessageTimestamp(for: conversation.id)

        // Fetch new messages
        let messages = try await conversation.messages(afterNs: lastMessageNs)
        guard !messages.isEmpty else { return }

        Log.debug("Found \(messages.count) new messages, catching up...")

        // Store messages and track if conversation should be marked unread
        var marksConversationAsUnread = false
        let myInboxId = currentInboxId
        for message in messages {
            guard !message.isProfileMessage, !message.isTypingIndicator else { continue }
            if message.isReadReceipt {
                await storeReadReceipt(message, conversationId: conversation.id)
                continue
            }
            if message.isThinking {
                await storeThinking(message, conversationId: conversation.id, currentInboxId: myInboxId)
                continue
            }
            Log.debug("Catching up with message sent at: \(message.sentAt.nanosecondsSince1970)")
            let result = try await messageWriter.store(message: message, for: dbConversation)
            if result.contentType.marksConversationAsUnread,
               message.senderInboxId != myInboxId {
                marksConversationAsUnread = true
            }
            Log.debug("Saved caught up message sent at: \(message.sentAt.nanosecondsSince1970)")
        }

        if marksConversationAsUnread {
            try await localStateWriter.setUnread(true, for: conversation.id)
        }
    }

    private func storeThinking(_ message: DecodedMessage, conversationId: String, currentInboxId: String) async {
        guard message.senderInboxId != currentInboxId else { return }
        guard let content = try? ThinkingCodec().decode(content: message.encodedContent) else {
            Log.warning("Failed to decode Thinking from caught-up message \(message.id)")
            return
        }
        await thinkingSessionWriter.apply(
            event: content,
            momentId: message.id,
            conversationId: conversationId,
            senderInboxId: message.senderInboxId,
            sentAtNs: message.sentAtNs
        )
    }

    private func storeReadReceipt(_ message: DecodedMessage, conversationId: String) async {
        do {
            try await databaseWriter.write { db in
                let senderInboxId = message.senderInboxId
                let sentAtNs = message.sentAtNs
                let existing = try DBConversationReadReceipt
                    .filter(Column("conversationId") == conversationId && Column("inboxId") == senderInboxId)
                    .fetchOne(db)
                if let existing, existing.readAtNs >= sentAtNs {
                    // Newer (or equal) read receipt already stored; skip so an
                    // out-of-order catch-up can't roll the timestamp backwards.
                    return
                }
                let receipt = DBConversationReadReceipt(
                    conversationId: conversationId,
                    inboxId: senderInboxId,
                    readAtNs: sentAtNs
                )
                try receipt.save(db, onConflict: .replace)
            }
        } catch {
            Log.warning("Failed to store read receipt during catch-up: \(error.localizedDescription)")
        }
    }

    private func processProfileMessagesFromHistory(conversation: XMTPiOS.Group) async {
        do {
            let messages = try await conversation.messages(limit: 500)
            let conversationId = conversation.id
            let encryptionKey = try? conversation.imageEncryptionKey

            var latestUpdates: [String: ProfileUpdate] = [:]
            var latestSnapshot: ProfileSnapshot?

            for message in messages {
                guard let contentType = try? message.encodedContent.type else { continue }

                if contentType == ContentTypeProfileUpdate {
                    guard let update = try? ProfileUpdateCodec().decode(content: message.encodedContent) else { continue }
                    let inboxId = message.senderInboxId
                    guard !inboxId.isEmpty, latestUpdates[inboxId] == nil else { continue }
                    latestUpdates[inboxId] = update
                } else if contentType == ContentTypeProfileSnapshot, latestSnapshot == nil {
                    latestSnapshot = try? ProfileSnapshotCodec().decode(content: message.encodedContent)
                }
            }

            let resolvedUpdates = latestUpdates
            let resolvedSnapshot = latestSnapshot

            try await databaseWriter.write { db in
                for (inboxId, update) in resolvedUpdates {
                    let profileMetadata = update.profileMetadata
                    try Self.applyProfileData(
                        db: db, conversationId: conversationId, inboxId: inboxId,
                        name: update.hasName ? update.name : nil,
                        encryptedImage: update.hasEncryptedImage ? update.encryptedImage : nil,
                        memberKind: update.memberKind.dbMemberKind,
                        metadata: profileMetadata.isEmpty ? nil : profileMetadata,
                        fallbackEncryptionKey: encryptionKey
                    )
                }

                if let snapshot = resolvedSnapshot {
                    for memberProfile in snapshot.profiles {
                        let inboxId = memberProfile.inboxIdString
                        guard !inboxId.isEmpty, resolvedUpdates[inboxId] == nil else { continue }

                        let existing = try DBMemberProfile.fetchOne(db, conversationId: conversationId, inboxId: inboxId)
                        guard existing?.name == nil, existing?.avatar == nil else { continue }

                        let snapshotMetadata = memberProfile.profileMetadata
                        try Self.applyProfileData(
                            db: db, conversationId: conversationId, inboxId: inboxId,
                            name: memberProfile.hasName ? memberProfile.name : nil,
                            encryptedImage: memberProfile.hasEncryptedImage ? memberProfile.encryptedImage : nil,
                            memberKind: memberProfile.memberKind.dbMemberKind,
                            metadata: snapshotMetadata.isEmpty ? nil : snapshotMetadata,
                            fallbackEncryptionKey: encryptionKey
                        )
                    }
                }
            }

            let profileCount = latestUpdates.count + (latestSnapshot?.profiles.count ?? 0)
            if profileCount > 0 {
                Log.debug("Processed \(profileCount) profile messages from history for \(conversationId)")
            }
        } catch {
            Log.warning("Failed to process profile messages from history: \(error.localizedDescription)")
        }
    }

    private static func applyProfileData( // swiftlint:disable:this function_parameter_count
        db: Database,
        conversationId: String,
        inboxId: String,
        name: String?,
        encryptedImage: EncryptedProfileImageRef?,
        memberKind: DBMemberKind?,
        metadata: ProfileMetadata? = nil,
        fallbackEncryptionKey: Data?
    ) throws {
        let member = DBMember(inboxId: inboxId)
        try member.save(db)

        var profile = try DBMemberProfile.fetchOne(
            db, conversationId: conversationId, inboxId: inboxId
        ) ?? DBMemberProfile(conversationId: conversationId, inboxId: inboxId, name: nil, avatar: nil)

        profile = profile.with(name: name)

        if let image = encryptedImage, image.isValid {
            profile = profile.with(
                avatar: image.url, salt: image.salt, nonce: image.nonce,
                key: profile.avatarKey ?? fallbackEncryptionKey
            )
        }

        if let metadata, !metadata.isEmpty {
            profile = profile.with(metadata: metadata)
        }

        let priorMemberKind = profile.memberKind
        if let memberKind {
            profile = profile.with(memberKind: memberKind)

            if memberKind == .agent {
                let verification = profile.hydrateProfile().verifyCachedAgentAttestation()
                if verification.isVerified {
                    profile = profile.with(memberKind: DBMemberKind.from(agentVerification: verification))
                }
            }
        }

        if let priorMemberKind, priorMemberKind.agentVerification.isVerified,
           !profile.agentVerification.isVerified {
            profile = profile.with(memberKind: priorMemberKind)
        }

        try profile.save(db)

        if profile.agentVerification.isConvosAgent,
           let conversation = try DBConversation.fetchOne(db, id: conversationId),
           !conversation.hasHadVerifiedAgent {
            try conversation.with(hasHadVerifiedAgent: true).save(db)
        }
    }

    private func getLastMessageTimestamp(for conversationId: String) async throws -> Int64? {
        try await databaseWriter.read { db in
            let lastMessage = DBConversation.association(
                to: DBConversation.lastMessageCTE,
                on: { conversation, lastMessage in
                    conversation.id == lastMessage.conversationId
                }
            ).forKey("latestMessage")
            let result = try DBConversation
                .filter(DBConversation.Columns.id == conversationId)
                .with(DBConversation.lastMessageCTE)
                .including(optional: lastMessage)
                .asRequest(of: DBConversationLatestMessage.self)
                .fetchOne(db)
            return result?.latestMessage?.dateNs
        }
    }

    private func prefetchEncryptedImages(profiles: [DBMemberProfile], group: XMTPiOS.Group) {
        let encryptedProfiles = profiles.filter { $0.avatarSalt != nil && $0.avatarNonce != nil }
        guard !encryptedProfiles.isEmpty else { return }

        let groupKey: Data? = try? group.imageEncryptionKey

        Task.detached(priority: .background) {
            guard let groupKey else {
                Log.debug("No image encryption key for group, skipping prefetch")
                return
            }

            await EncryptedImagePrefetcher.shared.prefetchProfileImages(
                profiles: encryptedProfiles,
                groupKey: groupKey
            )
        }
    }

    private func prefetchEncryptedGroupImage(cacheId: String, group: XMTPiOS.Group, oldImageURL: String? = nil) {
        guard let encryptedRef = try? group.encryptedGroupImage,
              let groupKey = try? group.imageEncryptionKey,
              let params = EncryptedImageParams(encryptedRef: encryptedRef, groupKey: groupKey) else {
            return
        }

        let urlString = encryptedRef.url

        Task.detached(priority: .background) {
            // If URL didn't change and we already have a cached image, skip
            if oldImageURL == nil, await ImageCacheContainer.shared.imageAsync(for: cacheId) != nil {
                return
            }

            // Fetch new image (either first time, or URL changed)
            // cacheAfterUpload will replace old image when new one is cached
            do {
                let decryptedData = try await EncryptedImageLoader.loadAndDecrypt(params: params)

                // Use data-based overload to avoid re-compression quality loss
                ImageCacheContainer.shared.cacheAfterUpload(decryptedData, for: cacheId, url: urlString)
                Log.debug("Prefetched encrypted group image for conversation: \(cacheId)")
            } catch {
                Log.error("Failed to prefetch encrypted group image: \(error)")
            }
        }
    }
}

// MARK: - Helper Extensions

extension Attachment {
    func saveToTmpFile() throws -> URL {
        let tempDir = FileManager.default.temporaryDirectory
        let fileName = UUID().uuidString + filename
        let fileURL = tempDir.appendingPathComponent(fileName)
        try data.write(to: fileURL)
        return fileURL
    }
}

fileprivate extension XMTPiOS.Member {
    func dbRepresentation(conversationId: String) -> DBConversationMember {
        .init(conversationId: conversationId,
              inboxId: inboxId,
              role: permissionLevel.role,
              consent: consentState.memberConsent,
              createdAt: Date(),
              invitedByInboxId: nil)
    }
}

fileprivate extension XMTPiOS.PermissionLevel {
    var role: MemberRole {
        switch self {
        case .SuperAdmin: return .superAdmin
        case .Admin: return .admin
        case .Member: return .member
        }
    }
}

enum ConversationInviteTagError: Error {
    case attemptedFetchingInviteTagForDM
}

extension XMTPiOS.Conversation {
    var creatorInboxId: String {
        get async throws {
            switch self {
            case .group(let group):
                return try await group.creatorInboxId()
            case .dm(let dm):
                return try await dm.creatorInboxId()
            }
        }
    }

    var inviteTag: String {
        get throws {
            switch self {
            case .group(let group):
                return try group.inviteTag
            case .dm:
                throw ConversationInviteTagError.attemptedFetchingInviteTagForDM
            }
        }
    }
}
// swiftlint:enable type_body_length

fileprivate extension XMTPiOS.ConsentState {
    var memberConsent: Consent {
        switch self {
        case .allowed: return .allowed
        case .denied: return .denied
        case .unknown: return .unknown
        }
    }

    var consent: Consent {
        switch self {
        case .allowed: return .allowed
        case .denied: return .denied
        case .unknown: return .unknown
        }
    }
}

fileprivate extension XMTPiOS.ConversationDebugInfo {
    func toDBDebugInfo() -> ConversationDebugInfo {
        ConversationDebugInfo(
            epoch: epoch,
            maybeForked: maybeForked,
            forkDetails: forkDetails,
            localCommitLog: localCommitLog,
            remoteCommitLog: remoteCommitLog,
            commitLogForkStatus: commitLogForkStatus.toDBStatus()
        )
    }
}

fileprivate extension XMTPiOS.CommitLogForkStatus {
    func toDBStatus() -> CommitLogForkStatus {
        switch self {
        case .forked: return .forked
        case .notForked: return .notForked
        case .unknown: return .unknown
        }
    }
}
