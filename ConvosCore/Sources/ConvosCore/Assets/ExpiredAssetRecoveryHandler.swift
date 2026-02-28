import Foundation
import GRDB

public struct ExpiredAssetRecoveryHandler: Sendable {
    private let databaseWriter: any DatabaseWriter
    private let imageCache: (any ImageCacheProtocol)?
    private let myProfileWriter: (any MyProfileWriterProtocol)?
    private let conversationMetadataWriter: (any ConversationMetadataWriterProtocol)?
    private let onRecoveryDeferred: (@Sendable (RenewableAsset) async -> Void)?

    public init(
        databaseWriter: any DatabaseWriter,
        imageCache: (any ImageCacheProtocol)? = nil,
        myProfileWriter: (any MyProfileWriterProtocol)? = nil,
        conversationMetadataWriter: (any ConversationMetadataWriterProtocol)? = nil,
        onRecoveryDeferred: (@Sendable (RenewableAsset) async -> Void)? = nil
    ) {
        self.databaseWriter = databaseWriter
        self.imageCache = imageCache
        self.myProfileWriter = myProfileWriter
        self.conversationMetadataWriter = conversationMetadataWriter
        self.onRecoveryDeferred = onRecoveryDeferred
    }

    public func handleExpiredAsset(
        _ asset: RenewableAsset,
        cachedImage: ImageType? = nil
    ) async -> RecoveryResult {
        let outcome = await attemptRecoveryFromCache(asset, cachedImage: cachedImage)

        switch outcome {
        case .recovered:
            return .recovered
        case .deferred:
            guard let onRecoveryDeferred else {
                Log.warning("Asset recovery deferred but no deferred handler configured: \(asset.url)")
                return await clearExpiredAsset(asset)
            }
            await onRecoveryDeferred(asset)
            return .deferred
        case .notRecoverable:
            return await clearExpiredAsset(asset)
        }
    }

    private func clearExpiredAsset(_ asset: RenewableAsset) async -> RecoveryResult {
        Log.warning("Asset expired and cannot be recovered: \(asset.url) - clearing URL")
        let didClear = await clearAssetUrl(asset)
        return didClear ? .cleared : .clearFailed
    }

    private func attemptRecoveryFromCache(
        _ asset: RenewableAsset,
        cachedImage: ImageType?
    ) async -> RecoveryOutcome {
        let cachedImageToUse: ImageType

        if let cachedImage {
            cachedImageToUse = cachedImage
        } else {
            guard let imageCache else {
                Log.info("No image cache available for recovery")
                return .notRecoverable
            }

            guard let cachedImage = imageCache.image(for: asset.url) else {
                Log.info("Image not found in cache for \(asset.url)")
                return .notRecoverable
            }
            cachedImageToUse = cachedImage
        }

        do {
            switch asset {
            case let .profileAvatar(_, conversationId, _, _):
                guard let myProfileWriter else {
                    Log.info("Deferring profile avatar recovery until writer is available")
                    return .deferred
                }

                try await myProfileWriter.update(avatar: cachedImageToUse, conversationId: conversationId)
                Log.info("Auto-recovered profile avatar for conversation \(conversationId)")
                return .recovered

            case let .groupImage(_, conversationId, _):
                guard let conversationMetadataWriter else {
                    Log.info("Deferring group image recovery until writer is available")
                    return .deferred
                }

                guard let conversation = try await fetchConversation(id: conversationId) else {
                    Log.warning("Cannot recover group image - conversation not found: \(conversationId)")
                    return .notRecoverable
                }

                try await conversationMetadataWriter.updateImage(cachedImageToUse, for: conversation)
                Log.info("Auto-recovered group image for conversation \(conversationId)")
                return .recovered
            }
        } catch {
            Log.error("Failed to recover asset from cache: \(error.localizedDescription)")
            return .notRecoverable
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

    private func clearAssetUrl(_ asset: RenewableAsset) async -> Bool {
        do {
            try await databaseWriter.write { db in
                switch asset {
                case let .profileAvatar(url, _, _, _):
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
            return true
        } catch {
            Log.error("Failed to clear asset URL: \(error.localizedDescription)")
            return false
        }
    }

    public enum RecoveryResult: Sendable {
        case recovered
        case deferred
        case cleared
        case clearFailed
    }

    private enum RecoveryOutcome {
        case recovered
        case deferred
        case notRecoverable
    }
}
