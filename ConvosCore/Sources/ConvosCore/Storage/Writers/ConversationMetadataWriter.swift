import Combine
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
    func promoteToAdmin(_ memberInboxId: String, in conversationId: String) async throws
    func demoteFromAdmin(_ memberInboxId: String, in conversationId: String) async throws
    func promoteToSuperAdmin(_ memberInboxId: String, in conversationId: String) async throws
    func demoteFromSuperAdmin(_ memberInboxId: String, in conversationId: String) async throws
    func updateImage(_ image: ImageType, for conversation: Conversation) async throws
    func updateExpiresAt(_ expiresAt: Date, for conversationId: String) async throws
    func updateIncludeInfoInPublicPreview(_ enabled: Bool, for conversationId: String) async throws
    func lockConversation(for conversationId: String) async throws
    func unlockConversation(for conversationId: String) async throws
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
    private let inboxStateManager: any InboxStateManagerProtocol
    private let databaseWriter: any DatabaseWriter
    private let inviteWriter: any InviteWriterProtocol

    init(inboxStateManager: any InboxStateManagerProtocol,
         inviteWriter: any InviteWriterProtocol,
         databaseWriter: any DatabaseWriter) {
        self.inboxStateManager = inboxStateManager
        self.inviteWriter = inviteWriter
        self.databaseWriter = databaseWriter
    }

    // MARK: - Invite Preview Sync

    private func syncInvitePreview(for conversation: DBConversation) async throws {
        _ = try await inviteWriter.update(
            for: conversation.id,
            name: conversation.includeInfoInPublicPreview ? conversation.name : nil,
            description: conversation.includeInfoInPublicPreview ? conversation.description : nil,
            imageURL: conversation.includeInfoInPublicPreview ? conversation.publicImageURLString : nil
        )
    }

    // MARK: - Conversation Metadata Updates

    func updateName(_ name: String, for conversationId: String) async throws {
        let inboxReady = try await inboxStateManager.waitForInboxReadyResult()

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
        let inboxReady = try await inboxStateManager.waitForInboxReadyResult()

        guard let conversation = try await inboxReady.client.conversation(with: conversationId),
              case .group(let group) = conversation else {
            throw ConversationMetadataError.conversationNotFound(conversationId: conversationId)
        }

        try await group.updateExpiresAt(date: expiresAt)

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

    func updateDescription(_ description: String, for conversationId: String) async throws {
        let inboxReady = try await inboxStateManager.waitForInboxReadyResult()

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
        let inboxReady = try await inboxStateManager.waitForInboxReadyResult()

        guard let xmtpConversation = try await inboxReady.client.conversation(with: conversation.id),
              case .group(let group) = xmtpConversation else {
            throw ConversationMetadataError.conversationNotFound(conversationId: conversation.id)
        }

        guard let compressedImageData = ImageCacheContainer.shared.prepareForUpload(
            image,
            for: conversation
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

        let groupKey = try await group.ensureImageEncryptionKey()
        let encryptedPayload = try ImageEncryption.encrypt(
            imageData: compressedImageData,
            groupKey: groupKey
        )

        let encryptedFilename = "eg-\(UUID().uuidString).enc"

        if includePublicPreview {
            Log.debug("Uploading group image (encrypted + public preview)")
        } else {
            Log.debug("Uploading group image (encrypted only, public preview disabled)")
        }

        let encryptedAssetUrl = try await inboxReady.apiClient.uploadAttachment(
            data: encryptedPayload.ciphertext,
            filename: encryptedFilename,
            contentType: "application/octet-stream",
            acl: "public-read"
        )
        Log.debug("Encrypted image uploaded: \(encryptedAssetUrl)")

        let publicImageUrl: String?
        if includePublicPreview {
            let publicFilename = "pg-\(UUID().uuidString).jpg"
            let uploadedUrl = try await inboxReady.apiClient.uploadAttachment(
                data: compressedImageData,
                filename: publicFilename,
                contentType: "image/jpeg",
                acl: "public-read"
            )
            Log.debug("Public preview image uploaded: \(uploadedUrl)")
            publicImageUrl = uploadedUrl
        } else {
            publicImageUrl = nil
            Log.debug("Public preview URL: none")
        }

        var encryptedRef = EncryptedImageRef()
        encryptedRef.url = encryptedAssetUrl
        encryptedRef.salt = encryptedPayload.salt
        encryptedRef.nonce = encryptedPayload.nonce

        try await group.updateEncryptedGroupImage(encryptedRef)
        try await group.updateImageUrl(imageUrl: encryptedAssetUrl)

        let updatedConversation = try await databaseWriter.write { db in
            guard let localConversation = try DBConversation
                .fetchOne(db, key: conversation.id) else {
                throw ConversationMetadataError.conversationNotFound(conversationId: conversation.id)
            }
            let updatedConversation = localConversation
                .with(imageURLString: encryptedAssetUrl)
                .with(publicImageURLString: localConversation.includeInfoInPublicPreview ? publicImageUrl : nil)
            try updatedConversation.save(db)
            return updatedConversation
        }

        // Invalidate old cache entries only after all operations succeed
        if let oldImageURL, oldImageURL != encryptedAssetUrl {
            ImageCacheContainer.shared.removeImage(for: oldImageURL)
        }
        if let oldPublicImageURL, oldPublicImageURL != publicImageUrl {
            ImageCacheContainer.shared.removeImage(for: oldPublicImageURL)
        }

        // Cache the uploaded image using the new URL-tracking API
        // Uses prepareForUpload + cacheAfterUpload to avoid double-caching
        if let cachedImage = ImageType(data: compressedImageData) {
            ImageCacheContainer.shared.cacheAfterUpload(cachedImage, for: conversation, url: encryptedAssetUrl)
        }

        try await syncInvitePreview(for: updatedConversation)

        if includePublicPreview {
            Log.debug("Public preview URL set for invites")
        }
        Log.debug("Updated encrypted conversation image for \(conversation.id): \(encryptedAssetUrl)")
    }

    func updateIncludeInfoInPublicPreview(_ enabled: Bool, for conversationId: String) async throws {
        let inboxReady = try await inboxStateManager.waitForInboxReadyResult()

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
        guard localConversation.imageURLString != nil else {
            Log.debug("No group image to make public")
            return nil
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
        let inboxReady = try await inboxStateManager.waitForInboxReadyResult()

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

    func addMembers(_ memberInboxIds: [String], to conversationId: String) async throws {
        let inboxReady = try await inboxStateManager.waitForInboxReadyResult()

        guard let conversation = try await inboxReady.client.conversation(with: conversationId),
              case .group(let group) = conversation else {
            throw ConversationMetadataError.conversationNotFound(conversationId: conversationId)
        }

        _ = try await group.addMembers(inboxIds: memberInboxIds)

        try await databaseWriter.write { db in
            for memberInboxId in memberInboxIds {
                let conversationMember = DBConversationMember(
                    conversationId: conversationId,
                    inboxId: memberInboxId,
                    role: .member,
                    consent: .allowed,
                    createdAt: Date()
                )
                try conversationMember.save(db)
                Log.debug("Added local conversation member \(memberInboxId) to \(conversationId)")
            }
        }

        Log.info("Added members to conversation \(conversationId): \(memberInboxIds)")
        QAEvent.emit(.member, "added", ["conversation": conversationId, "count": String(memberInboxIds.count)])
    }

    func removeMembers(_ memberInboxIds: [String], from conversationId: String) async throws {
        let inboxReady = try await inboxStateManager.waitForInboxReadyResult()

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
        let inboxReady = try await inboxStateManager.waitForInboxReadyResult()

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
        let inboxReady = try await inboxStateManager.waitForInboxReadyResult()

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
        let inboxReady = try await inboxStateManager.waitForInboxReadyResult()

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
        let inboxReady = try await inboxStateManager.waitForInboxReadyResult()

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
        let inboxReady = try await inboxStateManager.waitForInboxReadyResult()

        guard let conversation = try await inboxReady.client.conversation(with: conversationId),
              case .group(let group) = conversation else {
            throw ConversationMetadataError.conversationNotFound(conversationId: conversationId)
        }

        try await group.updateAddMemberPermission(newPermissionOption: .deny)
        try await group.rotateInviteTag()

        try await databaseWriter.write { db in
            guard let localConversation = try DBConversation.fetchOne(db, key: conversationId) else {
                throw ConversationMetadataError.conversationNotFound(conversationId: conversationId)
            }
            let updatedConversation = localConversation
                .with(isLocked: true)
                .with(inviteTag: try group.inviteTag)
            try updatedConversation.save(db)
            Log.debug("Locked conversation \(conversationId) in local database")
        }

        _ = try await inviteWriter.regenerate(for: conversationId)

        Log.info("Locked conversation \(conversationId)")
        QAEvent.emit(.conversation, "locked", ["id": conversationId])
    }

    func unlockConversation(for conversationId: String) async throws {
        let inboxReady = try await inboxStateManager.waitForInboxReadyResult()

        guard let conversation = try await inboxReady.client.conversation(with: conversationId),
              case .group(let group) = conversation else {
            throw ConversationMetadataError.conversationNotFound(conversationId: conversationId)
        }

        // Rotate invite tag first so the new invite is ready before members can add others.
        // This ensures the invite works immediately when permissions are updated.
        try await group.rotateInviteTag()

        try await group.updateAddMemberPermission(newPermissionOption: .allow)

        try await databaseWriter.write { db in
            guard let localConversation = try DBConversation.fetchOne(db, key: conversationId) else {
                throw ConversationMetadataError.conversationNotFound(conversationId: conversationId)
            }
            let updatedConversation = localConversation
                .with(isLocked: false)
                .with(inviteTag: try group.inviteTag)
            try updatedConversation.save(db)
            Log.debug("Unlocked conversation \(conversationId) in local database")
        }

        _ = try await inviteWriter.regenerate(for: conversationId)

        Log.info("Unlocked conversation \(conversationId)")
        QAEvent.emit(.conversation, "unlocked", ["id": conversationId])
    }
}
