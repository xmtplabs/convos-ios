import Foundation

/// A person's identity for rendering: name, agent kind, and one avatar.
///
/// One row per person, keyed by inbox id - not per conversation. Hydrated from
/// `DBProfile`, whose avatar is a plain CDN URL served by the backend.
///
/// The name is transitional: `Profile` still belongs to the conversation-scoped
/// type this replaces. When that type goes, this one takes the plain name.
public struct UnifiedProfile: Identifiable, Hashable, Sendable, Codable {
    public var id: String { inboxId }
    public let inboxId: String
    public let name: String?
    let memberKind: DBMemberKind?
    public let metadata: ProfileMetadata?
    /// One URL for the person, not one per conversation.
    public let avatarUrl: URL?
    let updatedAt: Date

    init(
        inboxId: String,
        name: String?,
        memberKind: DBMemberKind?,
        metadata: ProfileMetadata?,
        avatarUrl: URL? = nil,
        updatedAt: Date
    ) {
        self.inboxId = inboxId
        self.name = name
        self.memberKind = memberKind
        self.metadata = metadata
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

    static func empty(inboxId: String) -> UnifiedProfile {
        UnifiedProfile(inboxId: inboxId, name: nil, memberKind: nil, metadata: nil, updatedAt: .distantPast)
    }

    static func hydrate(identity: DBProfile?, inboxId: String) -> UnifiedProfile {
        guard let identity else { return .empty(inboxId: inboxId) }
        return UnifiedProfile(
            inboxId: identity.inboxId,
            name: identity.name,
            memberKind: identity.memberKind,
            metadata: identity.metadata,
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
