import Foundation
import GRDB

public struct ExpiredAssetRecoveryHandler: @unchecked Sendable {
    private let databaseWriter: any DatabaseWriter
    private let imageCache: (any ImageCacheProtocol)?
    private let myProfileWriter: (any MyProfileWriterProtocol)?
    private let conversationMetadataWriter: (any ConversationMetadataWriterProtocol)?

    public init(
        databaseWriter: any DatabaseWriter,
        imageCache: (any ImageCacheProtocol)? = nil,
        myProfileWriter: (any MyProfileWriterProtocol)? = nil,
        conversationMetadataWriter: (any ConversationMetadataWriterProtocol)? = nil
    ) {
        self.databaseWriter = databaseWriter
        self.imageCache = imageCache
        self.myProfileWriter = myProfileWriter
        self.conversationMetadataWriter = conversationMetadataWriter
    }

    public func handleExpiredAsset(_ asset: RenewableAsset) async {
        // Try to recover from cache first
        if await attemptRecoveryFromCache(asset) {
            return
        }

        // Fall back to clearing the URL
        Log.warning("Asset expired and cannot be recovered: \(asset.url) - clearing URL")
        await clearAssetUrl(asset)
    }

    private func attemptRecoveryFromCache(_ asset: RenewableAsset) async -> Bool {
        guard let imageCache else {
            Log.info("No image cache available for recovery")
            return false
        }

        // Try to get image from cache using the URL
        guard let url = URL(string: asset.url),
              let cachedImage = imageCache.image(for: url) else {
            Log.info("Image not found in cache for \(asset.url)")
            return false
        }

        do {
            switch asset {
            case let .profileAvatar(_, conversationId, _):
                guard let myProfileWriter else {
                    Log.info("No profile writer available for recovery")
                    return false
                }

                try await myProfileWriter.update(avatar: cachedImage, conversationId: conversationId)
                Log.info("Auto-recovered profile avatar for conversation \(conversationId)")
                return true

            case let .groupImage(_, conversationId):
                guard let conversationMetadataWriter else {
                    Log.info("No conversation metadata writer available for recovery")
                    return false
                }

                guard let conversation = try await fetchConversation(id: conversationId) else {
                    Log.warning("Cannot recover group image - conversation not found: \(conversationId)")
                    return false
                }

                try await conversationMetadataWriter.updateImage(cachedImage, for: conversation)
                Log.info("Auto-recovered group image for conversation \(conversationId)")
                return true
            }
        } catch {
            Log.error("Failed to recover asset from cache: \(error.localizedDescription)")
            return false
        }
    }

    private func fetchConversation(id: String) async throws -> Conversation? {
        try await databaseWriter.read { db in
            try DBConversation
                .filter(DBConversation.Columns.id == id)
                .detailedConversationQuery()
                .fetchOne(db)?
                .hydrateConversation()
        }
    }

    private func clearAssetUrl(_ asset: RenewableAsset) async {
        do {
            try await databaseWriter.write { db in
                switch asset {
                case let .profileAvatar(url, _, _, _):
                    // Clear ALL profiles with this avatar URL (same person may appear in multiple conversations)
                    let profiles = try DBMemberProfile
                        .filter(DBMemberProfile.Columns.avatar == url)
                        .fetchAll(db)
                    for var profile in profiles {
                        profile = profile
                            .with(avatar: nil, salt: nil, nonce: nil, key: nil)
                            .with(avatarLastRenewed: nil)
                        try profile.save(db)
                    }
                    if !profiles.isEmpty {
                        Log.info("Cleared expired profile avatar URL from \(profiles.count) record(s)")
                    }

                case let .groupImage(url, _, _):
                    // Clear ALL conversations with this image URL (unlikely to have duplicates, but for consistency)
                    let conversations = try DBConversation
                        .filter(DBConversation.Columns.imageURLString == url)
                        .fetchAll(db)
                    for var conv in conversations {
                        conv = conv
                            .with(imageURLString: nil, imageSalt: nil, imageNonce: nil, imageEncryptionKey: nil)
                            .with(imageLastRenewed: nil)
                        try conv.save(db)
                    }
                    if !conversations.isEmpty {
                        Log.info("Cleared expired group image URL from \(conversations.count) record(s)")
                    }
                }
            }
        } catch {
            Log.error("Failed to clear asset URL: \(error.localizedDescription)")
        }
    }
}
