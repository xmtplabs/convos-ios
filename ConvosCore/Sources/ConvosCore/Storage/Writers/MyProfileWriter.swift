import Foundation
import GRDB

public protocol MyProfileWriterProtocol {
    func update(displayName: String, conversationId: String) async throws
    func update(avatar: ImageType?, conversationId: String) async throws
}

enum MyProfileWriterError: Error {
    case imageCompressionFailed
}

class MyProfileWriter: MyProfileWriterProtocol {
    private let inboxStateManager: any InboxStateManagerProtocol
    private let databaseWriter: any DatabaseWriter

    init(
        inboxStateManager: any InboxStateManagerProtocol,
        databaseWriter: any DatabaseWriter
    ) {
        self.inboxStateManager = inboxStateManager
        self.databaseWriter = databaseWriter
    }

    func update(displayName: String, conversationId: String) async throws {
        let inboxReady = try await inboxStateManager.waitForInboxReadyResult()
        guard let conversation = try await inboxReady.client.conversation(with: conversationId),
              case .group(let group) = conversation else {
            throw ConversationMetadataError.conversationNotFound(conversationId: conversationId)
        }
        let trimmedDisplayName = {
            var name = displayName.trimmingCharacters(in: .whitespacesAndNewlines)
            if name.count > NameLimits.maxDisplayNameLength {
                name = String(name.prefix(NameLimits.maxDisplayNameLength))
            }
            return name
        }()
        let inboxId = inboxReady.client.inboxId
        let name = trimmedDisplayName.isEmpty ? nil : trimmedDisplayName
        let profile = try await databaseWriter.write { db in
            let member = DBMember(inboxId: inboxId)
            try member.save(db)
            let profile = (try DBMemberProfile.fetchOne(db, conversationId: conversationId, inboxId: inboxId) ?? .init(
                conversationId: conversationId,
                inboxId: inboxId,
                name: name,
                avatar: nil
            )).with(name: name)
            try profile.save(db)
            return profile
        }

        try await group.updateProfile(profile)
    }

    func update(avatar: ImageType?, conversationId: String) async throws {
        let inboxReady = try await inboxStateManager.waitForInboxReadyResult()
        guard let conversation = try await inboxReady.client.conversation(with: conversationId),
              case .group(let group) = conversation else {
            throw ConversationMetadataError.conversationNotFound(conversationId: conversationId)
        }
        let inboxId = inboxReady.client.inboxId
        let profile = try await databaseWriter.write { db in
            let member = DBMember(inboxId: inboxId)
            try member.save(db)
            if let foundProfile = try DBMemberProfile.fetchOne(db, conversationId: conversationId, inboxId: inboxId) {
                Log.info("Found profile: \(foundProfile)")
                return foundProfile
            } else {
                let profile = DBMemberProfile(
                    conversationId: conversationId,
                    inboxId: inboxId,
                    name: nil,
                    avatar: nil
                )
                try profile.save(db)
                return profile
            }
        }

        guard let avatarImage = avatar else {
            ImageCacheContainer.shared.removeImage(for: profile.hydrateProfile())
            let updatedProfile = profile.with(avatar: nil, salt: nil, nonce: nil, key: nil)
            try await databaseWriter.write { db in
                try updatedProfile.save(db)
            }
            try await group.updateProfile(updatedProfile)
            return
        }

        let hydratedProfile = profile.hydrateProfile()
        guard let compressedImageData = ImageCacheContainer.shared.prepareForUpload(
            avatarImage,
            for: hydratedProfile
        ) else {
            throw MyProfileWriterError.imageCompressionFailed
        }

        let groupKey = try await group.ensureImageEncryptionKey()
        let encryptedPayload = try ImageEncryption.encrypt(
            imageData: compressedImageData,
            groupKey: groupKey
        )

        let uploadedAssetUrl = try await inboxReady.apiClient.uploadAttachment(
            data: encryptedPayload.ciphertext,
            filename: "ep-\(UUID().uuidString).enc",
            contentType: "application/octet-stream",
            acl: "public-read"
        )

        let updatedProfile = profile.with(
            avatar: uploadedAssetUrl,
            salt: encryptedPayload.salt,
            nonce: encryptedPayload.nonce,
            key: groupKey
        )

        try await group.updateProfile(updatedProfile)

        // Cache the uploaded image using the new URL-tracking API
        if let image = ImageType(data: compressedImageData) {
            ImageCacheContainer.shared.cacheAfterUpload(image, for: hydratedProfile, url: uploadedAssetUrl)
        }

        try await databaseWriter.write { db in
            Log.info("Updated encrypted avatar for profile: \(updatedProfile)")
            try updatedProfile.save(db)
        }
    }
}
