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
    let updatedAt: Date

    init(
        inboxId: String,
        name: String?,
        memberKind: DBMemberKind?,
        metadata: ProfileMetadata?,
        avatars: [String: Avatar],
        updatedAt: Date
    ) {
        self.inboxId = inboxId
        self.name = name
        self.memberKind = memberKind
        self.metadata = metadata
        self.avatars = avatars
        self.updatedAt = updatedAt
    }

    public var isAgent: Bool {
        memberKind?.isAgent ?? false
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
            updatedAt: identity.updatedAt
        )
    }
}
