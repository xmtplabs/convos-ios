import Combine
import ConvosAppData
import Foundation
import GRDB
@preconcurrency import XMTPiOS

// MARK: - Conversation Metadata Writer Protocol

public protocol ConversationMetadataWriterProtocol: Sendable {
    func updateName(_ name: String, for conversationId: String) async throws
    func updateDescription(_ description: String, for conversationId: String) async throws
    func updateImageUrl(_ imageURL: String, for conversationId: String) async throws
    func addMembers(_ memberInboxIds: [String], to conversationId: String) async throws
    func removeMembers(_ memberInboxIds: [String], from conversationId: String) async throws
    func markAsAgentDm(_ conversationId: String, originConversationId: String?) async throws
    func promoteToAdmin(_ memberInboxId: String, in conversationId: String) async throws
    func demoteFromAdmin(_ memberInboxId: String, in conversationId: String) async throws
    func promoteToSuperAdmin(_ memberInboxId: String, in conversationId: String) async throws
    func demoteFromSuperAdmin(_ memberInboxId: String, in conversationId: String) async throws
    func updateImage(_ image: ImageType, for conversation: Conversation) async throws
    func updateExpiresAt(_ expiresAt: Date, for conversationId: String) async throws
    func updateParticipationMode(_ mode: ConversationParticipationMode, for conversationId: String) async throws
    func updateIncludeInfoInPublicPreview(_ enabled: Bool, for conversationId: String) async throws
    func lockConversation(for conversationId: String) async throws
    func unlockConversation(for conversationId: String) async throws
    func refreshInvite(for conversationId: String) async throws -> Invite?
}

// MARK: - Conversation Metadata Errors

enum ConversationMetadataWriterError: Error {
    case failedImageCompression
}

enum ConversationMetadataError: LocalizedError {
    case clientNotAvailable
    case conversationNotFound(conversationId: String)
    case memberNotFound(memberInboxId: String)
    case insufficientPermissions

    var errorDescription: String? {
        switch self {
        case .clientNotAvailable:
            return "XMTP client is not available"
        case .conversationNotFound(let conversationId):
            return "Conversation not found: \(conversationId)"
        case .memberNotFound(let memberInboxId):
            return "Member not found: \(memberInboxId)"
        case .insufficientPermissions:
            return "Insufficient permissions to perform this action"
        }
    }
}

// MARK: - Conversation Metadata Writer Implementation

/// @unchecked Sendable: All stored properties are immutable references (`let`).
/// DatabaseWriter is thread-safe (internal serial queue). InboxStateManager and
/// InviteWriter protocols are Sendable. All methods are async with no shared mutable state.
final class ConversationMetadataWriter: ConversationMetadataWriterProtocol, @unchecked Sendable {
    private let sessionStateManager: any SessionStateManagerProtocol
    private let databaseWriter: any DatabaseWriter
    private let inviteWriter: any InviteWriterProtocol
    private let contactSyncCoordinator: (any ContactSyncCoordinatorProtocol)?

    init(sessionStateManager: any SessionStateManagerProtocol,
         inviteWriter: any InviteWriterProtocol,
         databaseWriter: any DatabaseWriter,
         contactSyncCoordinator: (any ContactSyncCoordinatorProtocol)? = nil) {
        self.sessionStateManager = sessionStateManager
        self.inviteWriter = inviteWriter
        self.databaseWriter = databaseWriter
        self.contactSyncCoordinator = contactSyncCoordinator
    }

    // MARK: - Invite Preview Sync

    private func syncInvitePreview(for conversation: DBConversation) async throws {
        _ = try await inviteWriter.update(for: conversation.id)
    }

    // MARK: - Conversation Metadata Updates

    func updateName(_ name: String, for conversationId: String) async throws {
        let inboxReady = try await sessionStateManager.waitForInboxReadyResult()

        let truncatedName = name.count > NameLimits.maxConversationNameLength ? String(name.prefix(NameLimits.maxConversationNameLength)) : name

        guard let conversation = try await inboxReady.client.conversation(with: conversationId),
              case .group(let group) = conversation else {
            throw ConversationMetadataError.conversationNotFound(conversationId: conversationId)
        }

        try await group.updateName(name: truncatedName)

        let updatedConversation = try await databaseWriter.write { db in
            guard let localConversation = try DBConversation
                .fetchOne(db, key: conversationId) else {
                throw ConversationMetadataError.conversationNotFound(conversationId: conversationId)
            }
            let updatedConversation = localConversation.with(name: truncatedName)
            try updatedConversation.save(db)
            Log.debug("Updated local conversation name for \(conversationId): \(truncatedName)")
            return updatedConversation
        }

        try await syncInvitePreview(for: updatedConversation)

        Log.info("Updated conversation name for \(conversationId): \(truncatedName)")
        QAEvent.emit(.profile, "name_updated", ["conversation": conversationId, "name": truncatedName])
    }

    func updateExpiresAt(_ expiresAt: Date, for conversationId: String) async throws {
        let expiresAtUnix = Int64(expiresAt.timeIntervalSince1970)
        // Durable-eventual: enqueue the appData change and return; the local
        // mirror below is the immediate truth for the setter's UI, and the
        // coordinator guarantees delivery across offline/restart.
        try await sessionStateManager.appDataCoordinator.enqueueChange(
            conversationId: conversationId,
            domain: .expiry
        ) { metadata in
            metadata.expiresAtUnix = expiresAtUnix
        }

        let updatedConversation = try await databaseWriter.write { db in
            guard let localConversation = try DBConversation
                .fetchOne(db, key: conversationId) else {
                throw ConversationMetadataError.conversationNotFound(conversationId: conversationId)
            }
            let updatedConversation = localConversation.with(expiresAt: expiresAt)
            try updatedConversation.save(db)
            return updatedConversation
        }

        try await syncInvitePreview(for: updatedConversation)

        Log.info("Updated conversation expiresAt for \(conversationId): \(expiresAt)")
    }

    /// Writes the conversation's participation mode to the group's appData, the
    /// same rail `updateName` / `updateExpiresAt` ride. The commit is what other
    /// members receive: their `ConversationWriter` re-reads appData on the
    /// resulting update message and their composer follows. The local row is
    /// written here too so the setter's own control does not wait a round trip
    /// for state their device already knows.
    func updateParticipationMode(_ mode: ConversationParticipationMode, for conversationId: String) async throws {
        // Durable-eventual, like `updateExpiresAt`: the local mirror is the
        // immediate truth for the setter's own control and the coordinator
        // delivers the commit other members receive.
        try await sessionStateManager.appDataCoordinator.enqueueChange(
            conversationId: conversationId,
            domain: .participation
        ) { metadata in
            metadata.participationMode = mode.proto
        }

        try await databaseWriter.write { db in
            guard let localConversation = try DBConversation.fetchOne(db, key: conversationId) else {
                throw ConversationMetadataError.conversationNotFound(conversationId: conversationId)
            }
            try localConversation.with(participationMode: mode).save(db)
        }

        Log.info("Updated conversation participation mode for \(conversationId): \(mode.rawValue)")
        QAEvent.emit(.conversation, "participation_mode_updated", ["id": conversationId, "mode": mode.rawValue])
    }

    func updateDescription(_ description: String, for conversationId: String) async throws {
        let inboxReady = try await sessionStateManager.waitForInboxReadyResult()

        guard let conversation = try await inboxReady.client.conversation(with: conversationId),
              case .group(let group) = conversation else {
            throw ConversationMetadataError.conversationNotFound(conversationId: conversationId)
        }

        try await group.updateDescription(description: description)

        let updatedConversation = try await databaseWriter.write { db in
            guard let localConversation = try DBConversation
                .fetchOne(db, key: conversationId) else {
                throw ConversationMetadataError.conversationNotFound(conversationId: conversationId)
            }
            let updatedConversation = localConversation.with(description: description)
            try updatedConversation.save(db)
            Log.debug("Updated local conversation description for \(conversationId): \(description)")
            return updatedConversation
        }

        try await syncInvitePreview(for: updatedConversation)

        Log.info("Updated conversation description for \(conversationId): \(description)")
    }

    func updateImage(_ image: ImageType, for conversation: Conversation) async throws {
        let inboxReady = try await sessionStateManager.waitForInboxReadyResult()

        guard let xmtpConversation = try await inboxReady.client.conversation(with: conversation.id),
              case .group(let group) = xmtpConversation else {
            throw ConversationMetadataError.conversationNotFound(conversationId: conversation.id)
        }

        // Key by the conversation id, not `conversation.imageCacheIdentifier`:
        // until `imageURL` is persisted that identifier resolves to the other
        // member's inbox id, which would cache the conversation image as that
        // member's profile avatar everywhere.
        guard let compressedImageData = ImageCacheContainer.shared.prepareForUpload(
            image,
            forIdentifier: conversation.clientConversationId
        ) else {
            throw ConversationMetadataWriterError.failedImageCompression
        }

        let localConversation = try await databaseWriter.read { db in
            try DBConversation.fetchOne(db, key: conversation.id)
        }
        guard let localConversation else {
            throw ConversationMetadataError.conversationNotFound(conversationId: conversation.id)
        }

        let oldImageURL = localConversation.imageURLString
        let oldPublicImageURL = localConversation.publicImageURLString
        let includePublicPreview = localConversation.includeInfoInPublicPreview

        // Upload the raw image (no encryption). The plain URL rides the native
        // XMTP group-image metadata; peers render it directly. A legacy peer or
        // group that still carries a key continues to decrypt via the read path.
        let filename = "eg-\(UUID().uuidString).jpg"
        let imageUrl = try await inboxReady.apiClient.uploadAttachment(
            data: compressedImageData,
            filename: filename,
            contentType: "image/jpeg",
            acl: "public-read"
        )
        Log.debug("Group image uploaded (plain): \(imageUrl)")

        // A plain image needs no separate public-preview object: the bytes are
        // identical and the asset is already public-read, so the invite reuses
        // the same URL. The toggle still governs whether the invite exposes it.
        let publicImageUrl: String? = includePublicPreview ? imageUrl : nil

        // Clear any stale `encryptedGroupImage` appData ref left by a prior
        // encrypted upload. Peers that pair the native URL with appData crypto
        // unconditionally would otherwise tag this plain URL with a key it can't
        // be decrypted with. Fire-and-forget durable: the read-side URL-match
        // guard also protects against this, so a failure here only logs.
        do {
            try await sessionStateManager.appDataCoordinator.enqueueChange(
                conversationId: conversation.id,
                domain: .legacyImageCleanup
            ) { metadata in
                metadata.clearEncryptedGroupImage()
            }
        } catch {
            Log.error("Failed to enqueue encryptedGroupImage cleanup for \(conversation.id): \(error.localizedDescription)")
        }
        try await group.updateImageUrl(imageUrl: imageUrl)

        let updatedConversation = try await databaseWriter.write { db in
            guard let localConversation = try DBConversation
                .fetchOne(db, key: conversation.id) else {
                throw ConversationMetadataError.conversationNotFound(conversationId: conversation.id)
            }
            // Null the image salt/nonce (this image is plain); keep the group
            // encryption key, which is also the profile-avatar fallback decrypt
            // key for legacy peers.
            let updatedConversation = localConversation
                .with(
                    imageURLString: imageUrl,
                    imageSalt: nil,
                    imageNonce: nil,
                    imageEncryptionKey: localConversation.imageEncryptionKey
                )
                .with(publicImageURLString: localConversation.includeInfoInPublicPreview ? publicImageUrl : nil)
            try updatedConversation.save(db)
            return updatedConversation
        }

        // Invalidate old cache entries only after all operations succeed
        if let oldImageURL, oldImageURL != imageUrl {
            ImageCacheContainer.shared.removeImage(for: oldImageURL)
        }
        if let oldPublicImageURL, oldPublicImageURL != publicImageUrl {
            ImageCacheContainer.shared.removeImage(for: oldPublicImageURL)
        }

        // Cache under the conversation id, matching the prepareForUpload key
        // above. The `conversation` parameter still has a nil `imageURL`, so
        // its `imageCacheIdentifier` would resolve to the other member's
        // inbox id and record the conversation image as their avatar.
        ImageCacheContainer.shared.cacheAfterUpload(
            compressedImageData,
            for: conversation.clientConversationId,
            url: imageUrl
        )

        try await syncInvitePreview(for: updatedConversation)

        if includePublicPreview {
            Log.debug("Public preview URL set for invites")
        }
        Log.debug("Updated conversation image (plain) for \(conversation.id): \(imageUrl)")
    }

    func updateIncludeInfoInPublicPreview(_ enabled: Bool, for conversationId: String) async throws {
        let inboxReady = try await sessionStateManager.waitForInboxReadyResult()

        guard let localConversation = try await databaseWriter.read({ db in
            try DBConversation.fetchOne(db, key: conversationId)
        }) else {
            throw ConversationMetadataError.conversationNotFound(conversationId: conversationId)
        }

        let originalImageURL = localConversation.imageURLString
        let publicImageUrl: String?

        if enabled {
            if localConversation.imageURLString != nil {
                publicImageUrl = await generatePublicPreviewUrl(
                    for: conversationId,
                    localConversation: localConversation,
                    inboxReady: inboxReady
                )
                if publicImageUrl == nil {
                    Log.warning("Public preview image generation failed, proceeding without image")
                }
            } else {
                publicImageUrl = nil
            }
        } else {
            publicImageUrl = nil
            Log.debug("Public preview disabled, clearing public image URL")
        }

        let updatedConversation: DBConversation? = try await databaseWriter.write { db in
            guard let localConversation = try DBConversation
                .fetchOne(db, key: conversationId) else {
                throw ConversationMetadataError.conversationNotFound(conversationId: conversationId)
            }
            if localConversation.imageURLString != originalImageURL {
                Log.warning("Image changed during public preview update, skipping update")
                return nil
            }
            let updatedConversation = localConversation
                .with(includeInfoInPublicPreview: enabled)
                .with(publicImageURLString: publicImageUrl)
            try updatedConversation.save(db)
            return updatedConversation
        }

        guard let updatedConversation else { return }

        try await syncInvitePreview(for: updatedConversation)

        Log.debug("Updated includeInfoInPublicPreview for \(conversationId): \(enabled)")
    }

    private func generatePublicPreviewUrl(
        for conversationId: String,
        localConversation: DBConversation,
        inboxReady: InboxReadyResult
    ) async -> String? {
        guard let imageURLString = localConversation.imageURLString else {
            Log.debug("No group image to make public")
            return nil
        }

        // A plain (cleartext) group image is already a public-read object, so
        // the invite reuses its URL directly - no decrypt-and-re-upload. Only a
        // legacy encrypted image needs the round trip below.
        if localConversation.imageSalt == nil, localConversation.imageNonce == nil {
            Log.debug("Group image is plain; reusing its URL for public preview")
            return imageURLString
        }

        guard let xmtpConversation = try? await inboxReady.client.conversation(with: conversationId),
              case .group(let group) = xmtpConversation else {
            Log.warning("Could not find XMTP conversation for public preview")
            return nil
        }

        guard let encryptedRef = try? group.encryptedGroupImage,
              let groupKey = try? group.imageEncryptionKey,
              let encryptedURL = URL(string: encryptedRef.url) else {
            Log.warning("No encrypted group image available for public preview")
            return nil
        }

        do {
            let decryptedData = try await EncryptedImageLoader.loadAndDecrypt(
                url: encryptedURL,
                salt: encryptedRef.salt,
                nonce: encryptedRef.nonce,
                groupKey: groupKey
            )

            let publicFilename = "pg-\(UUID().uuidString).jpg"
            let publicImageUrl = try await inboxReady.apiClient.uploadAttachment(
                data: decryptedData,
                filename: publicFilename,
                contentType: "image/jpeg",
                acl: "public-read"
            )
            Log.debug("Public preview image uploaded: \(publicImageUrl)")
            return publicImageUrl
        } catch {
            Log.warning("Failed to generate public preview: \(error.localizedDescription)")
            return nil
        }
    }

    func updateImageUrl(_ imageURL: String, for conversationId: String) async throws {
        let inboxReady = try await sessionStateManager.waitForInboxReadyResult()

        guard let conversation = try await inboxReady.client.conversation(with: conversationId),
              case .group(let group) = conversation else {
            throw ConversationMetadataError.conversationNotFound(conversationId: conversationId)
        }

        try await group.updateImageUrl(imageUrl: imageURL)

        guard let localConversation = try await databaseWriter.read({ db in
            try DBConversation.fetchOne(db, key: conversationId)
        }) else {
            throw ConversationMetadataError.conversationNotFound(conversationId: conversationId)
        }

        let publicImageUrl: String? = if localConversation.includeInfoInPublicPreview {
            await generatePublicPreviewUrl(
                for: conversationId,
                localConversation: localConversation.with(imageURLString: imageURL),
                inboxReady: inboxReady
            )
        } else {
            nil
        }

        let updatedConversation = try await databaseWriter.write { [publicImageUrl] db in
            guard let currentConversation = try DBConversation.fetchOne(db, key: conversationId) else {
                throw ConversationMetadataError.conversationNotFound(conversationId: conversationId)
            }
            let updated = currentConversation.with(imageURLString: imageURL).with(publicImageURLString: publicImageUrl)
            try updated.save(db)
            Log.debug("Updated local conversation image for \(conversationId): \(imageURL)")
            return updated
        }

        try await syncInvitePreview(for: updatedConversation)

        Log.info("Updated conversation image for \(conversationId): \(imageURL)")
        QAEvent.emit(.conversation, "image_updated", ["id": conversationId])
    }

    // MARK: - Member Management

    func markAsAgentDm(_ conversationId: String, originConversationId: String?) async throws {
        let originIdData = originConversationId.flatMap { Self.hexDecoded($0) }
        try await sessionStateManager.appDataCoordinator.enqueueChange(
            conversationId: conversationId,
            domain: .agentDm
        ) { metadata in
            metadata.markAgentDm(originConversationId: originIdData)
        }

        try await databaseWriter.write { db in
            let updated = try DBConversation
                .filter(key: conversationId)
                .updateAll(db, DBConversation.Columns.isAgentDm.set(to: true))
            guard updated > 0 else {
                // The local row may not exist yet (marker written before the
                // first store). Not fatal -- extraction re-derives the flag and
                // the DM -> parent link from the on-wire marker on the next save.
                // Recording the link now would violate agent_dm_origin's foreign
                // key to conversation, so defer it and just log the miss.
                Log.warning("markAsAgentDm updated no local rows for \(conversationId)")
                return
            }
            // Mirror the DM -> parent link locally on the creating device too, so
            // a tap routes correctly before the next full save re-extracts it.
            // Safe only now that the conversation row is known to exist.
            try DBAgentDmOrigin.record(
                conversationId: conversationId,
                originConversationId: originConversationId,
                in: db
            )
        }
    }

    private static func hexDecoded(_ hex: String) -> Data? {
        guard hex.count.isMultiple(of: 2) else { return nil }
        var data = Data(capacity: hex.count / 2)
        var index = hex.startIndex
        while index < hex.endIndex {
            let next = hex.index(index, offsetBy: 2)
            guard let byte = UInt8(hex[index..<next], radix: 16) else { return nil }
            data.append(byte)
            index = next
        }
        return data
    }

    func addMembers(_ memberInboxIds: [String], to conversationId: String) async throws {
        let inboxReady = try await sessionStateManager.waitForInboxReadyResult()

        guard let conversation = try await inboxReady.client.conversation(with: conversationId),
              case .group(let group) = conversation else {
            throw ConversationMetadataError.conversationNotFound(conversationId: conversationId)
        }

        _ = try await group.addMembers(inboxIds: memberInboxIds)

        let currentInboxId = inboxReady.client.inboxId
        try await databaseWriter.write { db in
            for memberInboxId in memberInboxIds {
                // A directly-added inbox (e.g. a freshly provisioned agent) may
                // never have been seen locally, so the member parent row the
                // membership row references doesn't exist yet — create it
                // first. Members arriving via the stream get theirs from the
                // welcome/profile path instead.
                try DBMember(inboxId: memberInboxId).save(db, onConflict: .ignore)
                let conversationMember = DBConversationMember(
                    conversationId: conversationId,
                    inboxId: memberInboxId,
                    role: .member,
                    consent: .allowed,
                    createdAt: Date(),
                    invitedByInboxId: currentInboxId
                )
                try conversationMember.save(db)

                // Seed a per-conversation profile name from the adder's contact
                // record so the ProfileSnapshot sent below advertises the
                // directly-added member's name to every other member (agents
                // especially) instead of "Somebody", until the member
                // self-attests via their own ProfileUpdate 
                // Names only. Fill-only: never overwrite an existing profile,
                // and skip contacts with no stored name. A later ProfileUpdate
                // from the member wins via the normal inbound name-preservation.
                let existingProfile = try DBMemberProfile.fetchOne(db, conversationId: conversationId, inboxId: memberInboxId)
                if existingProfile?.name == nil,
                   let contactName = try ContactsRepository.contactNameInTransaction(db: db, inboxId: memberInboxId) {
                    let seededProfile = (existingProfile ?? DBMemberProfile(
                        conversationId: conversationId,
                        inboxId: memberInboxId,
                        name: nil,
                        avatar: nil
                    )).with(name: contactName)
                    try seededProfile.save(db)
                }

                Log.debug("Added local conversation member \(memberInboxId) to \(conversationId)")
            }
            try ConversationWriter.markHasHadOtherMembersIfNeeded(
                conversationId: conversationId,
                currentMemberInboxIds: Set(memberInboxIds),
                in: db
            )
        }

        Log.info("Added members to conversation \(conversationId): \(memberInboxIds)")
        QAEvent.emit(.member, "added", ["conversation": conversationId, "count": String(memberInboxIds.count)])

        if let coordinator = contactSyncCoordinator {
            // Force-rerun to pick up the newly added members. The coordinator
            // short-circuits when the conversation has not yet been synced
            // (i.e. the local user has not acted there), preserving the
            // action-gated semantic.
            Task.detached {
                do {
                    try await coordinator.syncContactsAfterMembershipChange(for: conversationId)
                } catch {
                    Log.error("Contact sync after addMembers failed for \(conversationId): \(error)")
                }
            }
        }

        do {
            try await ProfileSnapshotBuilder.sendSnapshot(
                group: group,
                databaseReader: databaseWriter
            )
            Log.debug("Sent ProfileSnapshot after adding members to \(conversationId)")
        } catch {
            Log.warning("Failed to send ProfileSnapshot after adding members: \(error.localizedDescription)")
        }
    }

    func removeMembers(_ memberInboxIds: [String], from conversationId: String) async throws {
        let inboxReady = try await sessionStateManager.waitForInboxReadyResult()

        guard let conversation = try await inboxReady.client.conversation(with: conversationId),
              case .group(let group) = conversation else {
            throw ConversationMetadataError.conversationNotFound(conversationId: conversationId)
        }

        try await group.removeMembers(inboxIds: memberInboxIds)

        try await databaseWriter.write { db in
            for memberInboxId in memberInboxIds {
                try DBConversationMember
                    .filter(DBConversationMember.Columns.conversationId == conversationId)
                    .filter(DBConversationMember.Columns.inboxId == memberInboxId)
                    .deleteAll(db)
                Log.debug("Removed local conversation member \(memberInboxId) from \(conversationId)")
            }
        }

        Log.info("Removed members from conversation \(conversationId): \(memberInboxIds)")
        QAEvent.emit(.member, "removed", ["conversation": conversationId, "count": String(memberInboxIds.count)])
    }

    // MARK: - Admin Management

    func promoteToAdmin(_ memberInboxId: String, in conversationId: String) async throws {
        let inboxReady = try await sessionStateManager.waitForInboxReadyResult()

        guard let conversation = try await inboxReady.client.conversation(with: conversationId),
              case .group(let group) = conversation else {
            throw ConversationMetadataError.conversationNotFound(conversationId: conversationId)
        }

        try await group.addAdmin(inboxId: memberInboxId)

        try await databaseWriter.write { db in
            if let member = try DBConversationMember
                .filter(DBConversationMember.Columns.conversationId == conversationId)
                .filter(DBConversationMember.Columns.inboxId == memberInboxId)
                .fetchOne(db) {
                let updatedMember = member.with(role: .admin)
                try updatedMember.save(db)
                Log.debug("Updated local member \(memberInboxId) role to admin in \(conversationId)")
            }
        }

        Log.info("Promoted \(memberInboxId) to admin in conversation \(conversationId)")
    }

    func demoteFromAdmin(_ memberInboxId: String, in conversationId: String) async throws {
        let inboxReady = try await sessionStateManager.waitForInboxReadyResult()

        guard let conversation = try await inboxReady.client.conversation(with: conversationId),
              case .group(let group) = conversation else {
            throw ConversationMetadataError.conversationNotFound(conversationId: conversationId)
        }

        try await group.removeAdmin(inboxId: memberInboxId)
        try await databaseWriter.write { db in
            if let member = try DBConversationMember
                .filter(DBConversationMember.Columns.conversationId == conversationId)
                .filter(DBConversationMember.Columns.inboxId == memberInboxId)
                .fetchOne(db) {
                let updatedMember = member.with(role: .member)
                try updatedMember.save(db)
                Log.debug("Updated local member \(memberInboxId) role to member in \(conversationId)")
            }
        }

        Log.info("Demoted \(memberInboxId) from admin in conversation \(conversationId)")
    }

    func promoteToSuperAdmin(_ memberInboxId: String, in conversationId: String) async throws {
        let inboxReady = try await sessionStateManager.waitForInboxReadyResult()

        guard let conversation = try await inboxReady.client.conversation(with: conversationId),
              case .group(let group) = conversation else {
            throw ConversationMetadataError.conversationNotFound(conversationId: conversationId)
        }

        try await group.addSuperAdmin(inboxId: memberInboxId)
        try await databaseWriter.write { db in
            if let member = try DBConversationMember
                .filter(DBConversationMember.Columns.conversationId == conversationId)
                .filter(DBConversationMember.Columns.inboxId == memberInboxId)
                .fetchOne(db) {
                let updatedMember = member.with(role: .superAdmin)
                try updatedMember.save(db)
                Log.debug("Updated local member \(memberInboxId) role to superAdmin in \(conversationId)")
            }
        }

        Log.info("Promoted \(memberInboxId) to super admin in conversation \(conversationId)")
    }

    func demoteFromSuperAdmin(_ memberInboxId: String, in conversationId: String) async throws {
        let inboxReady = try await sessionStateManager.waitForInboxReadyResult()

        guard let conversation = try await inboxReady.client.conversation(with: conversationId),
              case .group(let group) = conversation else {
            throw ConversationMetadataError.conversationNotFound(conversationId: conversationId)
        }

        try await group.removeSuperAdmin(inboxId: memberInboxId)
        try await databaseWriter.write { db in
            if let member = try DBConversationMember
                .filter(DBConversationMember.Columns.conversationId == conversationId)
                .filter(DBConversationMember.Columns.inboxId == memberInboxId)
                .fetchOne(db) {
                let updatedMember = member.with(role: .admin)
                try updatedMember.save(db)
                Log.debug("Updated local member \(memberInboxId) role to admin in \(conversationId)")
            }
        }

        Log.info("Demoted \(memberInboxId) from super admin in conversation \(conversationId)")
    }

    // MARK: - Lock/Unlock Conversation

    func lockConversation(for conversationId: String) async throws {
        let inboxReady = try await sessionStateManager.waitForInboxReadyResult()

        guard let conversation = try await inboxReady.client.conversation(with: conversationId),
              case .group(let group) = conversation else {
            throw ConversationMetadataError.conversationNotFound(conversationId: conversationId)
        }

        try await group.updateAddMemberPermission(newPermissionOption: .deny)
        // Rotate the invite tag through the coordinator, then wait for the
        // commit to land before generating the invite so it never references
        // an unpublished tag.
        let newTag = try InviteTag.generate()
        let rotation = try await sessionStateManager.appDataCoordinator.enqueueChange(
            conversationId: conversationId,
            domain: .inviteTag
        ) { metadata in
            metadata.tag = newTag
        }
        let rotatedTag = rotation.localMerged.tag
        // Bounded so an offline lock/unlock fails fast (and the caller can
        // retry) instead of parking on the never-give-up reconcile loop. The
        // rotation stays durable and still publishes once connectivity returns.
        try await rotation.awaitPublished(timeout: Constant.invitePublishTimeout)

        let updatedConversation: DBConversation = try await databaseWriter.write { db in
            guard let localConversation = try DBConversation.fetchOne(db, key: conversationId) else {
                throw ConversationMetadataError.conversationNotFound(conversationId: conversationId)
            }
            let updated = localConversation
                .with(isLocked: true)
                .with(inviteTag: rotatedTag)
            try updated.save(db)
            Log.debug("Locked conversation \(conversationId) in local database")
            return updated
        }

        _ = try await inviteWriter.generate(for: updatedConversation, expiresAt: nil, expiresAfterUse: false)

        Log.info("Locked conversation \(conversationId)")
        QAEvent.emit(.conversation, "locked", ["id": conversationId])
    }

    func unlockConversation(for conversationId: String) async throws {
        let inboxReady = try await sessionStateManager.waitForInboxReadyResult()

        guard let conversation = try await inboxReady.client.conversation(with: conversationId),
              case .group(let group) = conversation else {
            throw ConversationMetadataError.conversationNotFound(conversationId: conversationId)
        }

        // Rotate the invite tag first and wait for the commit to land, so the
        // new invite is live before members regain the right to add others.
        let newTag = try InviteTag.generate()
        let rotation = try await sessionStateManager.appDataCoordinator.enqueueChange(
            conversationId: conversationId,
            domain: .inviteTag
        ) { metadata in
            metadata.tag = newTag
        }
        let rotatedTag = rotation.localMerged.tag
        // Bounded so an offline lock/unlock fails fast (and the caller can
        // retry) instead of parking on the never-give-up reconcile loop. The
        // rotation stays durable and still publishes once connectivity returns.
        try await rotation.awaitPublished(timeout: Constant.invitePublishTimeout)

        try await group.updateAddMemberPermission(newPermissionOption: .allow)

        let updatedConversation: DBConversation = try await databaseWriter.write { db in
            guard let localConversation = try DBConversation.fetchOne(db, key: conversationId) else {
                throw ConversationMetadataError.conversationNotFound(conversationId: conversationId)
            }
            let updated = localConversation
                .with(isLocked: false)
                .with(inviteTag: rotatedTag)
            try updated.save(db)
            Log.debug("Unlocked conversation \(conversationId) in local database")
            return updated
        }

        _ = try await inviteWriter.generate(for: updatedConversation, expiresAt: nil, expiresAfterUse: false)

        Log.info("Unlocked conversation \(conversationId)")
        QAEvent.emit(.conversation, "unlocked", ["id": conversationId])
    }

    func refreshInvite(for conversationId: String) async throws -> Invite? {
        guard try await databaseWriter.read({ db in
            try DBConversation.fetchOne(db, key: conversationId) != nil
        }) else { return nil }

        return try await inviteWriter.update(for: conversationId)
    }

    private enum Constant {
        /// How long lock/unlock waits for the invite-tag rotation to reach the
        /// network before failing fast. Covers a normal write plus verify
        /// re-read; offline it trips and the user retries.
        static let invitePublishTimeout: TimeInterval = 20
    }
}
