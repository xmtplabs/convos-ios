import ConvosCore
import Foundation

extension Profile {
    /// Returns a new `Profile` with `name` and `avatar*` substituted
    /// from the supplied contact when - and only when - the contact
    /// actually carries the corresponding data. A name-only contact
    /// does NOT clobber the per-conversation avatar, and a contact
    /// with neither field does not clobber a perfectly good per-
    /// conversation profile. `conversationId`, `isAgent`,
    /// `imageSourceContentDigest`, and `metadata` are always preserved
    /// from the original.
    ///
    /// The chat layer uses this so a system-message or avatar row
    /// shows the contact's name and photo when the inbox is a known
    /// contact whose per-conversation profile has not landed yet,
    /// without regressing rows where the per-conversation profile is
    /// already richer than the contact entry.
    func overlaying(contact: Contact) -> Profile {
        let resolvedName: String?
        if let contactName = contact.displayName, !contactName.isEmpty {
            resolvedName = contactName
        } else {
            resolvedName = name
        }
        // Avatar fields move as a set: a contact without an avatar URL
        // has no usable encryption material either, so substituting
        // any one of them in isolation would leave the cache key
        // pointing at an inaccessible blob.
        let resolvedAvatar: String?
        let resolvedAvatarSalt: Data?
        let resolvedAvatarNonce: Data?
        let resolvedAvatarKey: Data?
        if contact.avatarURL != nil {
            resolvedAvatar = contact.avatarURL
            resolvedAvatarSalt = contact.avatarSalt
            resolvedAvatarNonce = contact.avatarNonce
            resolvedAvatarKey = contact.avatarKey
        } else {
            resolvedAvatar = avatar
            resolvedAvatarSalt = avatarSalt
            resolvedAvatarNonce = avatarNonce
            resolvedAvatarKey = avatarKey
        }
        return Profile(
            inboxId: inboxId,
            conversationId: conversationId,
            name: resolvedName,
            avatar: resolvedAvatar,
            avatarSalt: resolvedAvatarSalt,
            avatarNonce: resolvedAvatarNonce,
            avatarKey: resolvedAvatarKey,
            isAgent: isAgent,
            imageSourceContentDigest: imageSourceContentDigest,
            metadata: metadata
        )
    }
}
