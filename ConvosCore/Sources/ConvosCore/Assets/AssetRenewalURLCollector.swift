import Foundation
import GRDB

public enum RenewableAsset: Sendable {
    case profileAvatar(url: String, conversationId: String, inboxId: String, lastRenewed: Date?)
    case groupImage(url: String, conversationId: String, lastRenewed: Date?)

    public var url: String {
        switch self {
        case let .profileAvatar(url, _, _, _): return url
        case let .groupImage(url, _, _): return url
        }
    }

    public var key: String? {
        guard let parsed = URL(string: url), parsed.path.count > 1 else { return nil }
        return String(parsed.path.dropFirst())
    }

    public var lastRenewed: Date? {
        switch self {
        case let .profileAvatar(_, _, _, lastRenewed): return lastRenewed
        case let .groupImage(_, _, lastRenewed): return lastRenewed
        }
    }
}

public struct AssetRenewalURLCollector {
    private let databaseReader: any DatabaseReader

    public init(databaseReader: any DatabaseReader) {
        self.databaseReader = databaseReader
    }

    public func collectRenewableAssets() throws -> [RenewableAsset] {
        try databaseReader.read { db in
            let allInboxIds = try DBInbox.fetchAll(db).map { $0.inboxId }
            guard !allInboxIds.isEmpty else { return [] }

            var assets: [RenewableAsset] = []
            var seenURLs: Set<String> = []

            // 1. My profile avatars (with conversationId for re-upload)
            let avatars = try DBProfileAvatar
                .filter(allInboxIds.contains(DBProfileAvatar.Columns.inboxId))
                .filter(DBProfileAvatar.Columns.url != nil)
                .fetchAll(db)

            for avatar in avatars {
                guard let url = avatar.url,
                      !seenURLs.contains(url),
                      Self.isValidAssetURL(url) else { continue }
                seenURLs.insert(url)
                assets.append(.profileAvatar(
                    url: url,
                    conversationId: avatar.conversationId,
                    inboxId: avatar.inboxId,
                    lastRenewed: avatar.lastRenewed
                ))
            }

            // 2. Group images (with conversationId for re-upload)
            let conversations = try DBConversation
                .filter(DBConversation.Columns.kind == ConversationKind.group.rawValue)
                .filter(DBConversation.Columns.imageURLString != nil)
                .fetchAll(db)

            for conv in conversations {
                guard let imageURL = conv.imageURLString,
                      !seenURLs.contains(imageURL),
                      Self.isValidAssetURL(imageURL) else { continue }
                seenURLs.insert(imageURL)
                assets.append(.groupImage(url: imageURL, conversationId: conv.id, lastRenewed: conv.imageLastRenewed))
            }

            return assets
        }
    }

    public func collectStaleAssets(olderThan staleThreshold: Date) throws -> [RenewableAsset] {
        try databaseReader.read { db in
            let allInboxIds = try DBInbox.fetchAll(db).map { $0.inboxId }
            guard !allInboxIds.isEmpty else { return [] }

            var assets: [RenewableAsset] = []
            var seenURLs: Set<String> = []

            // 1. My profile avatars that are stale (never renewed or renewed before threshold)
            let avatars = try DBProfileAvatar
                .filter(allInboxIds.contains(DBProfileAvatar.Columns.inboxId))
                .filter(DBProfileAvatar.Columns.url != nil)
                .filter(
                    DBProfileAvatar.Columns.lastRenewed == nil ||
                    DBProfileAvatar.Columns.lastRenewed < staleThreshold
                )
                .fetchAll(db)

            for avatar in avatars {
                guard let url = avatar.url,
                      !seenURLs.contains(url),
                      Self.isValidAssetURL(url) else { continue }
                seenURLs.insert(url)
                assets.append(.profileAvatar(
                    url: url,
                    conversationId: avatar.conversationId,
                    inboxId: avatar.inboxId,
                    lastRenewed: avatar.lastRenewed
                ))
            }

            // 2. Group images that are stale (never renewed or renewed before threshold)
            let conversations = try DBConversation
                .filter(DBConversation.Columns.kind == ConversationKind.group.rawValue)
                .filter(DBConversation.Columns.imageURLString != nil)
                .filter(
                    DBConversation.Columns.imageLastRenewed == nil ||
                    DBConversation.Columns.imageLastRenewed < staleThreshold
                )
                .fetchAll(db)

            for conv in conversations {
                guard let imageURL = conv.imageURLString,
                      !seenURLs.contains(imageURL),
                      Self.isValidAssetURL(imageURL) else { continue }
                seenURLs.insert(imageURL)
                assets.append(.groupImage(url: imageURL, conversationId: conv.id, lastRenewed: conv.imageLastRenewed))
            }

            return assets
        }
    }

    private static func isValidAssetURL(_ urlString: String) -> Bool {
        guard let url = URL(string: urlString),
              let scheme = url.scheme,
              scheme == "http" || scheme == "https",
              url.path.count > 1 else {
            return false
        }
        return true
    }
}
