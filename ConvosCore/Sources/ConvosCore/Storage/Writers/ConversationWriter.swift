import ConvosInvites
import ConvosProfiles
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
        try await storeWithLatestMessages(conversation: conversation, inboxId: inboxId, clientConversationId: nil)
    }
}

/// Writer for persisting conversations and their members to the database
///
/// ConversationWriter handles converting XMTP conversations to database representations
/// and managing all related data including members, profiles, invites, and messages.
/// Handles both initial storage and updates, with special logic for matching
/// placeholder conversations created during invite flows.
///
/// Marked @unchecked Sendable because GRDB's DatabaseWriter provides its own
/// concurrency safety via write{}/read{} closures - all database access is
/// externally synchronized by GRDB's serialized database queue.
class ConversationWriter: ConversationWriterProtocol, @unchecked Sendable {
    private let databaseWriter: any DatabaseWriter
    private let inviteWriter: any InviteWriterProtocol
    private let messageWriter: any IncomingMessageWriterProtocol
    private let localStateWriter: any ConversationLocalStateWriterProtocol

    init(identityStore: any KeychainIdentityStoreProtocol,
         databaseWriter: any DatabaseWriter,
         messageWriter: any IncomingMessageWriterProtocol) {
        self.databaseWriter = databaseWriter
        self.inviteWriter = InviteWriter(
            identityStore: identityStore,
            databaseWriter: databaseWriter
        )
        self.messageWriter = messageWriter
        self.localStateWriter = ConversationLocalStateWriter(databaseWriter: databaseWriter)
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
            // Look up clientId from inbox
            guard let inbox = try DBInbox.fetchOne(db, id: inboxId) else {
                throw ConversationWriterError.inboxNotFound(inboxId)
            }

            let conversation = DBConversation(
                id: draftConversationId,
                inboxId: inboxId,
                clientId: inbox.clientId,
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
                includeInfoInPublicPreview: false,
                expiresAt: signedInvite.conversationExpiresAt,
                debugInfo: .empty,
                isLocked: false,
                imageSalt: nil,
                imageNonce: nil,
                imageEncryptionKey: nil,
                imageLastRenewed: nil,
                isUnused: false
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
                isActive: true
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

    private func _store(
        conversation: XMTPiOS.Group,
        inboxId: String,
        withLatestMessages: Bool = false,
        clientConversationId: String? = nil
    ) async throws -> DBConversation {
        // Sync group to get latest state including member permission levels
        try await conversation.sync()

        // Extract conversation metadata
        let metadata = try await extractConversationMetadata(from: conversation)
        let members = try await conversation.members
        let dbMembers = members.map { $0.dbRepresentation(conversationId: conversation.id) }
        let memberProfiles = try conversation.memberProfiles

        // Create database representation (imageLastRenewed will be determined inside the write transaction
        // to avoid race conditions with concurrent asset renewal)
        let dbConversation = try await createDBConversation(
            from: conversation,
            metadata: metadata,
            inboxId: inboxId,
            clientConversationId: clientConversationId,
            imageLastRenewed: nil
        )

        // Save to database. Capture the actual clientConversationId used (may be a draft ID
        // like "draft-XXX" instead of the XMTP group ID) so cache notifications match
        // the ID that ViewModels subscribe to.
        // Also returns the old image URL for cache invalidation.
        let saveResult = try await saveConversationToDatabase(
            dbConversation: dbConversation,
            dbMembers: dbMembers,
            memberProfiles: memberProfiles
        )

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
        prefetchEncryptedImages(profiles: memberProfiles, group: conversation)

        // Prefetch encrypted group image in background (invalidate old URL if changed)
        // Use actualClientConversationId to match the ID that ViewModels subscribe to
        prefetchEncryptedGroupImage(
            cacheId: saveResult.clientConversationId,
            group: conversation,
            oldImageURL: saveResult.oldImageURL != metadata.imageURLString ? saveResult.oldImageURL : nil
        )

        do {
            _ = try await inviteWriter.generate(
                for: dbConversation,
                expiresAt: nil,
                expiresAfterUse: false
            )
        } catch {
            Log.error("Invite generation skipped for conversation \(dbConversation.id): \(error)")
        }

        // Fetch and store latest messages if requested
        if withLatestMessages {
            try await fetchAndStoreLatestMessages(for: conversation, dbConversation: dbConversation)
        }

        // Store last message (skip profile messages which aren't stored as DB messages)
        let lastMessage = try await conversation.lastMessage()
        if let lastMessage, !lastMessage.isProfileMessage, !lastMessage.isTypingIndicator {
            let result = try await messageWriter.store(
                message: lastMessage,
                for: dbConversation
            )
            Log.debug("Saved last message: \(result)")
        }

        // Process profile messages from history to populate member profiles
        await processProfileMessagesFromHistory(conversation: conversation)

        return dbConversation
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
        let expiresAt: Date?
        let debugInfo: ConversationDebugInfo
        let isLocked: Bool
    }

    private func extractConversationMetadata(from conversation: XMTPiOS.Group) async throws -> ConversationMetadata {
        let debugInfo = try await conversation.getDebugInformation().toDBDebugInfo()
        let permissionPolicy = try conversation.permissionPolicySet()
        let isLocked = permissionPolicy.addMemberPolicy == .deny

        let encryptedRef = try? conversation.encryptedGroupImage
        let imageEncryptionKey = try? conversation.imageEncryptionKey

        return ConversationMetadata(
            kind: .group,
            name: try conversation.name(),
            description: try conversation.description(),
            imageURLString: try conversation.imageUrl(),
            imageSalt: encryptedRef?.salt,
            imageNonce: encryptedRef?.nonce,
            imageEncryptionKey: imageEncryptionKey,
            expiresAt: try conversation.expiresAt,
            debugInfo: debugInfo,
            isLocked: isLocked
        )
    }

    private func createDBConversation(
        from conversation: XMTPiOS.Group,
        metadata: ConversationMetadata,
        inboxId: String,
        clientConversationId: String? = nil,
        imageLastRenewed: Date? = nil
    ) async throws -> DBConversation {
        // Look up clientId from inbox
        let clientId = try await databaseWriter.read { db in
            guard let inbox = try DBInbox.fetchOne(db, id: inboxId) else {
                throw ConversationWriterError.inboxNotFound(inboxId)
            }
            return inbox.clientId
        }

        return DBConversation(
            id: conversation.id,
            inboxId: inboxId,
            clientId: clientId,
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
            includeInfoInPublicPreview: false,
            expiresAt: metadata.expiresAt,
            debugInfo: metadata.debugInfo,
            isLocked: metadata.isLocked,
            imageSalt: metadata.imageSalt,
            imageNonce: metadata.imageNonce,
            imageEncryptionKey: metadata.imageEncryptionKey,
            imageLastRenewed: imageLastRenewed,
            isUnused: false
        )
    }

    private struct ConversationSaveResult {
        let clientConversationId: String
        let oldImageURL: String?
        let preservedInviteTag: String?
    }

    /// Returns the actual clientConversationId used (may differ from input if a local draft exists),
    /// and the old image URL for cache invalidation purposes.
    private func saveConversationToDatabase(
        dbConversation: DBConversation,
        dbMembers: [DBConversationMember],
        memberProfiles: [DBMemberProfile]
    ) async throws -> ConversationSaveResult {
        try await databaseWriter.write { [self] db in
            let creator = DBMember(inboxId: dbConversation.creatorId)
            try creator.save(db)

            // Save conversation (handle local conversation updates)
            // This also handles imageLastRenewed preservation inside the transaction
            let saveResult = try self.saveConversation(dbConversation, in: db)

            // Save local state
            let localState = ConversationLocalState(
                conversationId: dbConversation.id,
                isPinned: false,
                isUnread: false,
                isUnreadUpdatedAt: Date.distantPast,
                isMuted: false,
                pinnedOrder: nil,
                isActive: true
            )
            try localState.insert(db, onConflict: .ignore)

            // Remove conversation_members rows for members no longer in the group
            let currentMemberInboxIds = Set(dbMembers.map(\.inboxId))
            if !currentMemberInboxIds.isEmpty {
                try DBConversationMember
                    .filter(DBConversationMember.Columns.conversationId == dbConversation.id)
                    .filter(!currentMemberInboxIds.contains(DBConversationMember.Columns.inboxId))
                    .deleteAll(db)
            }

            // Save members (upserts conversation_members + stub memberProfile rows)
            try self.saveMembers(dbMembers, in: db)

            // Fill gaps: write appData profiles for members without message-sourced data.
            // After restore (isActive == false), force-apply metadata profiles to re-adopt
            // names and avatars from XMTP group metadata.
            let isInactive = try ConversationLocalState
                .filter(ConversationLocalState.Columns.conversationId == dbConversation.id)
                .filter(ConversationLocalState.Columns.isActive == false)
                .fetchOne(db) != nil

            try memberProfiles.forEach { profile in
                let existing = try DBMemberProfile.fetchOne(
                    db,
                    conversationId: dbConversation.id,
                    inboxId: profile.inboxId
                )
                if !isInactive, existing?.name != nil || existing?.avatar != nil || existing?.memberKind != nil {
                    return
                }
                let member = DBMember(inboxId: profile.inboxId)
                try member.save(db)
                try profile.save(db)
            }

            return saveResult
        }
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

        let existingConversationByTag: DBConversation?
        if !dbConversation.inviteTag.isEmpty {
            existingConversationByTag = try DBConversation
                .filter(DBConversation.Columns.inviteTag == dbConversation.inviteTag)
                .filter(DBConversation.Columns.id != dbConversation.id)
                .fetchOne(db)
        } else {
            existingConversationByTag = nil
        }

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
            try conversationToSave.save(db, onConflict: .replace)
            firstTimeSeeingConversationExpired = conversationToSave.isExpired && conversationToSave.expiresAt != localConversation.expiresAt
            actualClientConversationId = preferredClientConversationId
        } else if let existingConversation {
            let preferredClientConversationId: String
            if dbConversation.clientConversationId != existingConversation.clientConversationId {
                if DBConversation.isDraft(id: dbConversation.clientConversationId) {
                    preferredClientConversationId = dbConversation.clientConversationId
                } else {
                    preferredClientConversationId = existingConversation.clientConversationId
                }
            } else {
                preferredClientConversationId = dbConversation.clientConversationId
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
            if !updatedConversation.inviteTag.isEmpty,
               let conflictingConversation = try DBConversation
                .filter(DBConversation.Columns.inviteTag == updatedConversation.inviteTag)
                .filter(DBConversation.Columns.id != updatedConversation.id)
                .fetchOne(db) {
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
            try updatedConversation.save(db)
            firstTimeSeeingConversationExpired = updatedConversation.isExpired && updatedConversation.expiresAt != existingConversation.expiresAt
            actualClientConversationId = preferredClientConversationId
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
        dbConversation: DBConversation
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
        let myInboxId = dbConversation.inboxId
        for message in messages {
            guard !message.isProfileMessage, !message.isTypingIndicator else { continue }
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

        if let memberKind {
            profile = profile.with(memberKind: memberKind)

            if memberKind == .agent {
                let verification = profile.hydrateProfile().verifyCachedAgentAttestation()
                if verification.isVerified {
                    profile = profile.with(memberKind: DBMemberKind.from(agentVerification: verification))
                }
            }
        }
        try profile.save(db)
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

            let prefetcher = EncryptedImagePrefetcher()
            await prefetcher.prefetchProfileImages(
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
