import Foundation
import GRDB

public struct ExpiredAssetRecoveryHandler: Sendable {
    private let databaseWriter: any DatabaseWriter

    public init(databaseWriter: any DatabaseWriter) {
        self.databaseWriter = databaseWriter
    }

    public func handleExpiredAsset(_ asset: RenewableAsset) async {
        Log.warning("Asset expired and cannot be renewed: \(asset.url) - clearing URL")
        await clearAssetUrl(asset)
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
