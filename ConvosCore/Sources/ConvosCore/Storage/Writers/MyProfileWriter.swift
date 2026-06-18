import CryptoKit
import Foundation
import GRDB
@preconcurrency import XMTPiOS

public protocol MyProfileWriterProtocol: Sendable {
    func update(displayName: String, conversationId: String) async throws
    func update(avatar: ImageType?, imageSourceContentDigest: String?, conversationId: String) async throws
    func update(metadata: ProfileMetadata?, conversationId: String) async throws
    /// Like `update(metadata:conversationId:)` but propagates ProfileUpdate publish failures.
    /// Use this when the caller needs to know whether the ProfileUpdate reached the network
    /// (e.g. to roll back a dependent local write).
    func updateAndPublish(metadata: ProfileMetadata?, conversationId: String) async throws
    /// Reads `DBMyProfile` and writes/publishes any fields that differ from this group's
    /// `DBMemberProfile`. No-op when nothing is set yet or the group already matches.
    func syncFromGlobalProfile(conversationId: String) async throws
}

public extension MyProfileWriterProtocol {
    func update(avatar: ImageType?, conversationId: String) async throws {
        try await update(avatar: avatar, imageSourceContentDigest: nil, conversationId: conversationId)
    }
}

enum MyProfileWriterError: Error {
    case imageCompressionFailed
    case profileUpdatePublishFailed(underlying: any Error)
}

final class MyProfileWriter: MyProfileWriterProtocol, @unchecked Sendable {
    /// Resolves the live XMTP client + API client + inbox id. Default path
    /// awaits `SessionStateManager`; the background `ProfileSyncReconciler`
    /// injects a static context built from the session's already-live client
    /// (it has no `SessionStateManager`).
    private let resolveInboxReady: @Sendable () async throws -> InboxReadyResult
    private let databaseWriter: any DatabaseWriter

    init(
        sessionStateManager: any SessionStateManagerProtocol,
        databaseWriter: any DatabaseWriter
    ) {
        self.resolveInboxReady = { try await sessionStateManager.waitForInboxReadyResult() }
        self.databaseWriter = databaseWriter
    }

    init(
        databaseWriter: any DatabaseWriter,
        resolveInboxReady: @escaping @Sendable () async throws -> InboxReadyResult
    ) {
        self.resolveInboxReady = resolveInboxReady
        self.databaseWriter = databaseWriter
    }

    func update(displayName: String, conversationId: String) async throws {
        let inboxReady = try await resolveInboxReady()
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
            )).with(name: name).with(profileUpdatedAt: Date())
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
        let inboxReady = try await resolveInboxReady()
        guard let conversation = try await inboxReady.client.conversation(with: conversationId),
              case .group(let group) = conversation else {
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
            )).with(metadata: metadata?.isEmpty == true ? nil : metadata).with(profileUpdatedAt: Date())
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

    func update(avatar: ImageType?, imageSourceContentDigest: String?, conversationId: String) async throws {
        let inboxReady = try await resolveInboxReady()
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
            let updatedProfile = profile
                .with(avatar: nil, salt: nil, nonce: nil, key: nil)
                .with(imageSourceContentDigest: nil)
                .with(profileUpdatedAt: Date())
            try await databaseWriter.write { db in
                try updatedProfile.save(db)
            }
            do {
                // updateProfile merges (it preserves image fields absent on
                // the incoming side), so removal goes through the explicit
                // clearing API.
                try await group.clearProfileAvatar(inboxId: updatedProfile.inboxId)
            } catch {
                Log.warning("Failed to clear avatar in appData (best-effort): \(error.localizedDescription)")
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

        let updatedProfile = profile
            .with(
                avatar: uploadedAssetUrl,
                salt: encryptedPayload.salt,
                nonce: encryptedPayload.nonce,
                key: groupKey
            )
            .with(imageSourceContentDigest: imageSourceContentDigest)
            .with(profileUpdatedAt: Date())

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

    func syncFromGlobalProfile(conversationId: String) async throws {
        let inboxReady = try await resolveInboxReady()
        let inboxId = inboxReady.client.inboxId

        let global = try await databaseWriter.read { db in
            try DBMyProfile
                .filter(DBMyProfile.Columns.inboxId == inboxId)
                .fetchOne(db)
        }
        guard let global else { return }

        let member = try await databaseWriter.read { db in
            try DBMemberProfile.fetchOne(db, conversationId: conversationId, inboxId: inboxId)
        }

        // Gate on the confirmed-published markers, not the local row. The local
        // row is written optimistically before the network publish, so comparing
        // it would treat a failed publish as done and never retry. The markers
        // are stamped only after a successful send (see sendProfileUpdateThrowing),
        // so a dropped publish leaves them stale and the next sync re-publishes.
        // global.name is already trim/clamp/nil-if-empty normalized by MyGlobalProfileWriter.
        let targetNameDigest = Self.nameDigest(global.name)
        if member?.publishedNameDigest != targetNameDigest {
            try await update(displayName: global.name ?? "", conversationId: conversationId)
        }

        if global.imageData == nil {
            // Global avatar was cleared vs merely not rehydrated yet (fresh
            // pairing keeps the digest without the bytes). Only propagate a
            // genuine removal, and only if we previously published an avatar.
            if global.imageContentDigest == nil, member?.publishedAvatarDigest != nil {
                try await update(
                    avatar: nil,
                    imageSourceContentDigest: nil,
                    conversationId: conversationId
                )
            }
        } else if member?.publishedAvatarDigest != global.imageContentDigest,
                  let imageData = global.imageData,
                  let image = ImageType(data: imageData) {
            try await update(
                avatar: image,
                imageSourceContentDigest: global.imageContentDigest,
                conversationId: conversationId
            )
        }
    }

    /// Base64 SHA-256 of the display name, or nil for an empty/absent name.
    /// Used as the published-name marker so activate-sync can compare what was
    /// published against the global profile without storing the raw name twice.
    /// Internal so `ProfileSyncReconciler` computes the same target digest.
    static func nameDigest(_ name: String?) -> String? {
        guard let name, !name.isEmpty else { return nil }
        return Data(SHA256.hash(data: Data(name.utf8))).base64EncodedString()
    }

    private func sendProfileUpdate(profile: DBMemberProfile, group: XMTPiOS.Group) async {
        do {
            try await sendProfileUpdateThrowing(profile: profile, group: group)
        } catch MyProfileWriterError.profileUpdatePublishFailed(let underlying) {
            Log.warning("Failed to send ProfileUpdate message: \(underlying.localizedDescription)")
        } catch {
            Log.warning("Failed to send ProfileUpdate message: \(error.localizedDescription)")
        }
    }

    private func sendProfileUpdateThrowing(profile: DBMemberProfile, group: XMTPiOS.Group) async throws {
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

        let codec = ProfileUpdateCodec()
        let encoded: EncodedContent
        do {
            encoded = try codec.encode(content: update)
        } catch {
            throw MyProfileWriterError.profileUpdatePublishFailed(underlying: error)
        }

        do {
            try await withExponentialBackoffRetry {
                _ = try await group.send(encodedContent: encoded)
            }
            Log.debug("Sent ProfileUpdate message for \(profile.inboxId) in \(profile.conversationId)")
        } catch {
            throw MyProfileWriterError.profileUpdatePublishFailed(underlying: error)
        }

        // Confirmed published: stamp the markers for the local user's own row so
        // activate-sync's gate stops re-publishing this state, while a future
        // failed publish (markers left stale) is retried. The send carried the
        // full current profile, so both name and avatar markers reflect exactly
        // what reached the network.
        let publishedName = Self.nameDigest(profile.name)
        let publishedAvatar = profile.imageSourceContentDigest
        try await databaseWriter.write { db in
            guard let row = try DBMemberProfile.fetchOne(
                db,
                conversationId: profile.conversationId,
                inboxId: profile.inboxId
            ) else {
                return
            }
            try row.with(
                publishedNameDigest: publishedName,
                publishedAvatarDigest: publishedAvatar
            ).save(db)
        }
    }
}
