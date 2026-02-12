import Foundation
import GRDB
@preconcurrency import XMTPiOS

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
                pinnedOrder: nil
            )
            try localState.save(db)

            let conversationMember = DBConversationMember(
                conversationId: conversation.id,
                inboxId: creatorInboxId,
                role: .member,
                consent: .allowed,
                createdAt: Date()
            )
            try conversationMember.save(db)

            Log.info("Created placeholder conversation for invite")
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
        let (actualClientConversationId, oldImageURL) = try await saveConversationToDatabase(
            dbConversation: dbConversation,
            dbMembers: dbMembers,
            memberProfiles: memberProfiles
        )

        // Prefetch encrypted profile images in background
        prefetchEncryptedImages(profiles: memberProfiles, group: conversation)

        // Prefetch encrypted group image in background (invalidate old URL if changed)
        // Use actualClientConversationId to match the ID that ViewModels subscribe to
        prefetchEncryptedGroupImage(
            cacheId: actualClientConversationId,
            group: conversation,
            oldImageURL: oldImageURL != metadata.imageURLString ? oldImageURL : nil
        )

        // Create invite
        _ = try await inviteWriter.generate(
            for: dbConversation,
            expiresAt: nil,
            expiresAfterUse: false
        )

        // Fetch and store latest messages if requested
        if withLatestMessages {
            try await fetchAndStoreLatestMessages(for: conversation, dbConversation: dbConversation)
        }

        // Store last message
        let lastMessage = try await conversation.lastMessage()
        if let lastMessage {
            let result = try await messageWriter.store(
                message: lastMessage,
                for: dbConversation
            )
            Log.info("Saved last message: \(result)")
        }

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

    /// Returns the actual clientConversationId used (may differ from input if a local draft exists),
    /// and the old image URL for cache invalidation purposes.
    private func saveConversationToDatabase(
        dbConversation: DBConversation,
        dbMembers: [DBConversationMember],
        memberProfiles: [DBMemberProfile]
    ) async throws -> (clientConversationId: String, oldImageURL: String?) {
        try await databaseWriter.write { [self] db in
            let creator = DBMember(inboxId: dbConversation.creatorId)
            try creator.save(db)

            // Save conversation (handle local conversation updates)
            // This also handles imageLastRenewed preservation inside the transaction
            let (actualClientConversationId, oldImageURL) = try self.saveConversation(dbConversation, in: db)

            // Save local state
            let localState = ConversationLocalState(
                conversationId: dbConversation.id,
                isPinned: false,
                isUnread: false,
                isUnreadUpdatedAt: Date.distantPast,
                isMuted: false,
                pinnedOrder: nil
            )
            try localState.insert(db, onConflict: .ignore)

            // Delete old members
            try DBMemberProfile
                .filter(DBMemberProfile.Columns.conversationId == dbConversation.id)
                .deleteAll(db)
            // Save members
            try self.saveMembers(dbMembers, in: db)
            // Update profiles - ensure Member exists first
            try memberProfiles.forEach { profile in
                let member = DBMember(inboxId: profile.inboxId)
                try member.save(db)
                try profile.save(db)
            }

            return (actualClientConversationId, oldImageURL)
        }
    }

    /// Returns the actual clientConversationId used (may differ from input if a local draft exists),
    /// and the old image URL for cache invalidation purposes.
    /// Also handles preserving imageLastRenewed inside the transaction (GRDB's serialized write queue
    /// ensures atomic read-modify-write, preventing concurrent asset renewal from losing timestamps).
    private func saveConversation(
        _ dbConversation: DBConversation,
        in db: Database
    ) throws -> (clientConversationId: String, oldImageURL: String?) {
        let firstTimeSeeingConversationExpired: Bool
        let actualClientConversationId: String
        let oldImageURL: String?

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

        if let localConversation = try DBConversation
            .filter(DBConversation.Columns.inviteTag == dbConversation.inviteTag)
            .filter(DBConversation.Columns.clientConversationId != dbConversation.clientConversationId)
            .fetchOne(db) {
            // Prefer draft IDs for stability (image caching, default emoji)
            let preferredClientConversationId: String
            if DBConversation.isDraft(id: dbConversation.clientConversationId) {
                preferredClientConversationId = dbConversation.clientConversationId
                Log.info("Using incoming draft ID \(dbConversation.clientConversationId)")
            } else {
                preferredClientConversationId = localConversation.clientConversationId
                Log.info("Keeping existing ID \(localConversation.clientConversationId)")
            }

            conversationToSave = conversationToSave
                .with(clientConversationId: preferredClientConversationId)
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
            try updatedConversation.save(db)
            firstTimeSeeingConversationExpired = updatedConversation.isExpired && updatedConversation.expiresAt != existingConversation.expiresAt
            actualClientConversationId = preferredClientConversationId
        } else {
            try conversationToSave.save(db)
            firstTimeSeeingConversationExpired = conversationToSave.isExpired
            actualClientConversationId = conversationToSave.clientConversationId
        }

        if firstTimeSeeingConversationExpired {
            Log.info("Encountered expired conversation for the first time.")
        }

        return (actualClientConversationId, oldImageURL)
    }

    private func saveMembers(_ dbMembers: [DBConversationMember], in db: Database) throws {
        for member in dbMembers {
            try DBMember(inboxId: member.inboxId).save(db)
            try member.save(db)
            // fetch from description
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
        Log.info("Attempting to fetch latest messages...")

        // Get the timestamp of the last stored message
        let lastMessageNs = try await getLastMessageTimestamp(for: conversation.id)

        // Fetch new messages
        let messages = try await conversation.messages(afterNs: lastMessageNs)
        guard !messages.isEmpty else { return }

        Log.info("Found \(messages.count) new messages, catching up...")

        // Store messages and track if conversation should be marked unread
        var marksConversationAsUnread = false
        for message in messages {
            Log.info("Catching up with message sent at: \(message.sentAt.nanosecondsSince1970)")
            let result = try await messageWriter.store(message: message, for: dbConversation)
            if result.contentType.marksConversationAsUnread {
                marksConversationAsUnread = true
            }
            Log.info("Saved caught up message sent at: \(message.sentAt.nanosecondsSince1970)")
        }

        // Update unread status if needed
        if marksConversationAsUnread {
            try await localStateWriter.setUnread(true, for: conversation.id)
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
                Log.info("No image encryption key for group, skipping prefetch")
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
                Log.info("Prefetched encrypted group image for conversation: \(cacheId)")
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
              createdAt: Date())
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
