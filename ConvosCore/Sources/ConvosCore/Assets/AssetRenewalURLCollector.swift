import Foundation
import GRDB

public enum RenewableAsset: Sendable {
    case profileAvatar(url: String, conversationId: String, inboxId: String)
    case groupImage(url: String, conversationId: String)

    public var url: String {
        switch self {
        case let .profileAvatar(url, _, _): return url
        case let .groupImage(url, _): return url
        }
    }

    public var key: String? {
        guard let parsed = URL(string: url), parsed.path.count > 1 else { return nil }
        return String(parsed.path.dropFirst())
    }
}

struct AssetRenewalURLCollector {
    private let databaseReader: any DatabaseReader

    init(databaseReader: any DatabaseReader) {
        self.databaseReader = databaseReader
    }

    func collectRenewableAssets() throws -> [RenewableAsset] {
        try databaseReader.read { db in
            let allInboxIds = try DBInbox.fetchAll(db).map { $0.inboxId }
            guard !allInboxIds.isEmpty else { return [] }

            var assets: [RenewableAsset] = []
            var seenURLs: Set<String> = []

            // 1. My profile avatars (with conversationId for re-upload)
            let profiles = try DBMemberProfile
                .filter(allInboxIds.contains(DBMemberProfile.Columns.inboxId))
                .filter(DBMemberProfile.Columns.avatar != nil)
                .fetchAll(db)

            for profile in profiles {
                guard let avatar = profile.avatar, !seenURLs.contains(avatar) else { continue }
                seenURLs.insert(avatar)
                assets.append(.profileAvatar(
                    url: avatar,
                    conversationId: profile.conversationId,
                    inboxId: profile.inboxId
                ))
            }

            // 2. Group images (with conversationId for re-upload)
            let conversations = try DBConversation
                .filter(DBConversation.Columns.kind == ConversationKind.group.rawValue)
                .filter(allInboxIds.contains(DBConversation.Columns.inboxId))
                .filter(DBConversation.Columns.imageURLString != nil)
                .fetchAll(db)

            for conv in conversations {
                guard let imageURL = conv.imageURLString, !seenURLs.contains(imageURL) else { continue }
                seenURLs.insert(imageURL)
                assets.append(.groupImage(url: imageURL, conversationId: conv.id))
            }

            return assets
        }
    }
}
