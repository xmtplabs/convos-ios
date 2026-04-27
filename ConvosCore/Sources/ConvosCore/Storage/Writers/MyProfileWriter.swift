import ConvosMessagingProtocols
import Foundation
import GRDB

public protocol MyProfileWriterProtocol {
    func update(displayName: String, conversationId: String) async throws
    func update(avatar: ImageType?, conversationId: String) async throws
    func update(metadata: ProfileMetadata?, conversationId: String) async throws
    /// Like `update(metadata:conversationId:)` but propagates ProfileUpdate publish failures.
    /// Use this when the caller needs to know whether the ProfileUpdate reached the network
    /// (e.g. to roll back a dependent local write).
    func updateAndPublish(metadata: ProfileMetadata?, conversationId: String) async throws
}

enum MyProfileWriterError: Error {
    case imageCompressionFailed
    case profileUpdatePublishFailed(underlying: any Error)
}

// Conversation lookup uses `messagingGroup(with:)`, and the
// `group.updateProfile(_:)` / `group.ensureImageEncryptionKey()` calls
// dispatch onto the `MessagingGroup+CustomMetadata` extension. Sending
// the `ProfileUpdate` codec payload goes through the
// `ProfileSnapshotBridge.sendProfileUpdate` bridge because the codec
// still lives in the XMTPiOS layer.
class MyProfileWriter: MyProfileWriterProtocol {
    private let sessionStateManager: any SessionStateManagerProtocol
    private let databaseWriter: any DatabaseWriter

    init(
        sessionStateManager: any SessionStateManagerProtocol,
        databaseWriter: any DatabaseWriter
    ) {
        self.sessionStateManager = sessionStateManager
        self.databaseWriter = databaseWriter
    }

    func update(displayName: String, conversationId: String) async throws {
        let inboxReady = try await sessionStateManager.waitForInboxReadyResult()
        guard let group = try await inboxReady.client.messagingGroup(with: conversationId) else {
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

        do {
            try await group.updateProfile(profile)
        } catch {
            Log.warning("Failed to write profile to appData (best-effort): \(error.localizedDescription)")
        }
        await sendProfileUpdate(profile: profile, group: group)
    }

    func update(metadata: ProfileMetadata?, conversationId: String) async throws {
        do {
            try await updateAndPublish(metadata: metadata, conversationId: conversationId)
        } catch MyProfileWriterError.profileUpdatePublishFailed(let underlying) {
            Log.warning("Failed to send ProfileUpdate message: \(underlying.localizedDescription)")
        }
    }

    func updateAndPublish(metadata: ProfileMetadata?, conversationId: String) async throws {
        let inboxReady = try await sessionStateManager.waitForInboxReadyResult()
        guard let group = try await inboxReady.client.messagingGroup(with: conversationId) else {
            throw ConversationMetadataError.conversationNotFound(conversationId: conversationId)
        }
        let inboxId = inboxReady.client.inboxId
        let profile = try await databaseWriter.write { db in
            let member = DBMember(inboxId: inboxId)
            try member.save(db)
            let profile = (try DBMemberProfile.fetchOne(db, conversationId: conversationId, inboxId: inboxId) ?? .init(
                conversationId: conversationId,
                inboxId: inboxId,
                name: nil,
                avatar: nil
            )).with(metadata: metadata?.isEmpty == true ? nil : metadata)
            try profile.save(db)
            return profile
        }
        try await sendProfileUpdateThrowing(profile: profile, group: group)
        do {
            try await group.updateProfile(profile)
        } catch {
            Log.warning("Failed to write profile to appData (best-effort): \(error.localizedDescription)")
        }
    }

    func update(avatar: ImageType?, conversationId: String) async throws {
        let inboxReady = try await sessionStateManager.waitForInboxReadyResult()
        guard let group = try await inboxReady.client.messagingGroup(with: conversationId) else {
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
            do {
                try await group.updateProfile(updatedProfile)
            } catch {
                Log.warning("Failed to write profile to appData (best-effort): \(error.localizedDescription)")
            }
            await sendProfileUpdate(profile: updatedProfile, group: group)
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

        do {
            try await group.updateProfile(updatedProfile)
        } catch {
            Log.warning("Failed to write profile to appData (best-effort): \(error.localizedDescription)")
        }

        if let image = ImageType(data: compressedImageData) {
            ImageCacheContainer.shared.cacheAfterUpload(image, for: hydratedProfile, url: uploadedAssetUrl)
        }

        try await databaseWriter.write { db in
            Log.info("Updated encrypted avatar for profile: \(updatedProfile)")
            try updatedProfile.save(db)
        }

        await sendProfileUpdate(profile: updatedProfile, group: group)
    }

    private func sendProfileUpdate(profile: DBMemberProfile, group: any MessagingGroup) async {
        do {
            try await sendProfileUpdateThrowing(profile: profile, group: group)
        } catch MyProfileWriterError.profileUpdatePublishFailed(let underlying) {
            Log.warning("Failed to send ProfileUpdate message: \(underlying.localizedDescription)")
        } catch {
            Log.warning("Failed to send ProfileUpdate message: \(error.localizedDescription)")
        }
    }

    private func sendProfileUpdateThrowing(profile: DBMemberProfile, group: any MessagingGroup) async throws {
        var update = ProfileUpdate()
        if let name = profile.name {
            update.name = name
        }
        if let encryptedRef = profile.encryptedImageRef {
            update.encryptedImage = EncryptedProfileImageRef(encryptedRef)
        }
        if let kind = profile.memberKind {
            update.memberKind = kind.protoMemberKind
        }
        if let metadata = profile.metadata, !metadata.isEmpty {
            update.metadata = metadata.asProtoMap
        }

        // Codec encoding is performed inside `ProfileSnapshotBridge.sendProfileUpdate`
        // along with the actual XMTPiOS-side group send.
        do {
            // FIXME: see docs/outstanding-messaging-abstraction-work.md#codec-migration
            try await ProfileSnapshotBridge.sendProfileUpdate(update, on: group)
            Log.debug("Sent ProfileUpdate message for \(profile.inboxId) in \(profile.conversationId)")
        } catch {
            throw MyProfileWriterError.profileUpdatePublishFailed(underlying: error)
        }
    }
}
