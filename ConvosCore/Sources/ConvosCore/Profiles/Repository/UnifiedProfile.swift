import Foundation

/// A person's resolved identity for rendering: name + agent kind + the avatars
/// they've published, keyed by conversation. Hydrated by `ProfilesRepository`
/// from `DBProfile` + `DBProfileAvatar`.
///
/// Temporary name: `Profile` is still the conversation-scoped presentation type
/// in use until the cutover. This type replaces it then (renamed to `Profile`
/// or kept), so `UnifiedProfile` is intentionally transitional.
public struct UnifiedProfile: Identifiable, Hashable, Sendable {
    public var id: String { inboxId }
    public let inboxId: String
    public let name: String?
    let memberKind: DBMemberKind?
    public let metadata: ProfileMetadata?
    let avatars: [String: Avatar]
    /// The backend-served avatar: one URL for the person, not one per
    /// conversation. Once views read this, `avatars` and `displayAvatar(for:)`
    /// go with the rest of the per-conversation model.
    public let avatarUrl: URL?
    let updatedAt: Date

    init(
        inboxId: String,
        name: String?,
        memberKind: DBMemberKind?,
        metadata: ProfileMetadata?,
        avatars: [String: Avatar],
        avatarUrl: URL? = nil,
        updatedAt: Date
    ) {
        self.inboxId = inboxId
        self.name = name
        self.memberKind = memberKind
        self.metadata = metadata
        self.avatars = avatars
        self.avatarUrl = avatarUrl
        self.updatedAt = updatedAt
    }

    public var isAgent: Bool {
        memberKind?.isAgent ?? false
    }

    /// Same fallbacks as the conversation-scoped `Profile`, so a member reads
    /// identically whichever type a view happens to hold during the cutover.
    public var displayName: String {
        if let name, !name.isEmpty { return name }
        return isAgent ? "Agent" : "Somebody"
    }

    /// An agent may publish an emoji in place of a picture; it arrives in the
    /// conversation-scoped metadata the ProfileUpdate already carries.
    public var profileEmoji: String? {
        metadata?[Constant.emojiMetadataKey]?.stringValue.flatMap { value in
            let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
            return trimmed.isEmpty ? nil : trimmed
        }
    }

    /// The avatar to show for a conversation: that conversation's slot if
    /// present, otherwise the most recently updated slot across all
    /// conversations. nil when the person has no (non-cleared) avatar anywhere.
    public func displayAvatar(for conversationId: String?) -> Avatar? {
        if let conversationId, let slot = avatars[conversationId] {
            return slot
        }
        return avatars.values.max { $0.updatedAt < $1.updatedAt }
    }

    static func empty(inboxId: String) -> UnifiedProfile {
        UnifiedProfile(inboxId: inboxId, name: nil, memberKind: nil, metadata: nil, avatars: [:], updatedAt: .distantPast)
    }

    /// Builds the conversation -> Avatar map from slot rows, dropping cleared
    /// (url == nil) slots via `Avatar.from`.
    static func avatarMap(from rows: [DBProfileAvatar]) -> [String: Avatar] {
        var map: [String: Avatar] = [:]
        for row in rows {
            if let avatar = Avatar.from(url: row.url, salt: row.salt, nonce: row.nonce, key: row.encryptionKey, updatedAt: row.updatedAt) {
                map[row.conversationId] = avatar
            }
        }
        return map
    }

    static func hydrate(identity: DBProfile?, avatarRows: [DBProfileAvatar], inboxId: String) -> UnifiedProfile {
        let avatars = avatarMap(from: avatarRows)
        guard let identity else {
            return UnifiedProfile(inboxId: inboxId, name: nil, memberKind: nil, metadata: nil, avatars: avatars, updatedAt: .distantPast)
        }
        return UnifiedProfile(
            inboxId: identity.inboxId,
            name: identity.name,
            memberKind: identity.memberKind,
            metadata: identity.metadata,
            avatars: avatars,
            avatarUrl: identity.avatarUrl.flatMap(URL.init(string:)),
            updatedAt: identity.updatedAt
        )
    }
}

extension UnifiedProfile: ImageCacheable {
    public var imageCacheIdentifier: String {
        inboxId
    }

    public var imageCacheURL: URL? {
        avatarUrl
    }

    /// Backend-served avatars are plain bytes behind an unguessable key, so
    /// there is nothing to decrypt. This is what lets the whole per-group
    /// encryption path (salt, nonce, per-conversation key) fall away: the cache
    /// treats a profile like any other URL image.
    public var isEncryptedImage: Bool {
        false
    }

    public var encryptionKey: Data? {
        nil
    }

    public var encryptionSalt: Data? {
        nil
    }

    public var encryptionNonce: Data? {
        nil
    }
}

private enum Constant {
    static let emojiMetadataKey: String = "emoji"
}

extension UnifiedProfile: AvatarRenderable {}
