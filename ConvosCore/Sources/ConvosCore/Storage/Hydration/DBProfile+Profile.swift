import Foundation

extension DBMemberProfile {
    func hydrateProfile() -> Profile {
        Profile(
            inboxId: inboxId,
            conversationId: conversationId,
            name: name,
            avatar: avatar,
            avatarSalt: avatarSalt,
            avatarNonce: avatarNonce,
            avatarKey: avatarKey,
            isAgent: isAgent,
            imageSourceContentDigest: imageSourceContentDigest,
            metadata: metadata
        )
    }
}

extension Profile {
    /// Builds a conversation-scoped `Profile` from the canonical per-inbox
    /// `DBProfile` row and the per-(inbox, conversation) `DBProfileAvatar`
    /// slot. `imageSourceContentDigest` is always nil here because the new
    /// tables do not persist it (see ADR 014 for the deferred digest work).
    static func from(
        profile: DBProfile?,
        avatar: DBProfileAvatar?,
        inboxId: String,
        conversationId: String
    ) -> Profile {
        Profile(
            inboxId: inboxId,
            conversationId: conversationId,
            name: profile?.name,
            avatar: avatar?.url,
            avatarSalt: avatar?.salt,
            avatarNonce: avatar?.nonce,
            avatarKey: avatar?.encryptionKey,
            isAgent: profile?.memberKind?.isAgent ?? false,
            imageSourceContentDigest: nil,
            metadata: profile?.metadata
        )
    }

    /// Builds a conversation-scoped `Profile` from the current user's locally
    /// authored `DBMyProfile` row plus a conversation avatar slot. Used when the
    /// canonical `DBProfile` join is nil because the member (or inviter) is the
    /// current user, who is excluded from `DBProfile`. Self is never an agent.
    static func from(
        myProfile: DBMyProfile?,
        avatar: DBProfileAvatar?,
        inboxId: String,
        conversationId: String
    ) -> Profile {
        Profile(
            inboxId: inboxId,
            conversationId: conversationId,
            name: myProfile?.name,
            avatar: avatar?.url,
            avatarSalt: avatar?.salt,
            avatarNonce: avatar?.nonce,
            avatarKey: avatar?.encryptionKey,
            isAgent: false,
            imageSourceContentDigest: nil,
            metadata: myProfile?.metadata
        )
    }
}
