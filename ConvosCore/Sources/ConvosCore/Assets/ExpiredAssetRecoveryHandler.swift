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
                case let .profileAvatar(url, conversationId, inboxId):
                    if var profile = try DBMemberProfile.fetchOne(db, conversationId: conversationId, inboxId: inboxId),
                       profile.avatar == url {
                        profile = profile.with(avatar: nil, salt: nil, nonce: nil)
                        try profile.save(db)
                        Log.info("Cleared expired profile avatar URL for conversation \(conversationId)")
                    }

                case let .groupImage(url, conversationId):
                    if var conv = try DBConversation.fetchOne(db, key: conversationId),
                       conv.imageURLString == url {
                        conv = conv.with(imageURLString: nil)
                        try conv.save(db)
                        Log.info("Cleared expired group image URL for conversation \(conversationId)")
                    }
                }
            }
        } catch {
            Log.error("Failed to clear asset URL: \(error.localizedDescription)")
        }
    }
}
