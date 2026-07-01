import ConvosCore
import Foundation

extension Contact {
    /// Builds a contact-shaped override that takes only the live per-conversation
    /// member profile's current avatar image, passing every other field through
    /// from the stored contact unchanged. System-message and read-receipt rows
    /// resolve avatars through the contact override, but the stored contacts table
    /// lags a live avatar change (it is mirrored from member profiles
    /// asynchronously). Preferring the member profile's avatar - the same source
    /// the message bubble renders - keeps those rows in sync with the bubble after
    /// a participant changes their photo.
    ///
    /// The avatar image (url + its crypto) is taken wholesale from the member
    /// profile - never field-by-field merged with the stored contact - so a
    /// change-photo shows the new image, and a partial/malformed member avatar
    /// renders the same monogram as the bubble (copying the fields verbatim keeps
    /// `Profile.isEncryptedImage`'s all-or-nothing crypto check identical).
    ///
    /// The display name is deliberately left as the stored contact's, so
    /// contact-authoritative name resolution (and any future local nickname) is
    /// unaffected - only the avatar is freshened.
    ///
    /// Known limitation (deferred): this does not handle a member who *clears*
    /// their avatar (nil url) or switches to emoji-only. The caller renders via
    /// `Profile.overlaying(contact:)`, which falls back to the frozen per-message
    /// snapshot's avatar/metadata when the override carries no avatar url, so the
    /// row would resurface the stale snapshot photo/emoji rather than the member's
    /// cleared state. There is no UI to clear an avatar today, so this is
    /// unreachable in practice; it is fully resolved by member-authoritative
    /// rendering (`displayAvatar(for:)`) in the ProfilesRepository refactor, when
    /// this whole stopgap is removed.
    ///
    /// Interim stopgap: remove once identity resolves from ProfilesRepository
    /// (see docs/plans/2026-06-29-profile-table-implementation.md, section 10.1).
    static func liveOverride(member: Profile, stored: Contact?) -> Contact {
        Contact(
            inboxId: member.inboxId,
            displayName: stored?.displayName,
            avatarURL: member.avatar,
            avatarSalt: member.avatarSalt,
            avatarNonce: member.avatarNonce,
            avatarKey: member.avatarKey,
            addedAt: stored?.addedAt ?? Date(),
            addedViaConversationId: stored?.addedViaConversationId,
            isBlocked: stored?.isBlocked ?? false,
            agentVerification: stored?.agentVerification,
            agentTemplateId: stored?.agentTemplateId,
            agentTemplatePublishedURL: stored?.agentTemplatePublishedURL,
            profileEmoji: member.profileEmoji
        )
    }

    /// Builds a member-aware contact resolver: freshens the current conversation
    /// member's avatar image (the source the message bubble uses) over the lagging
    /// stored contact, falling back to the stored contact for non-members. Name
    /// and other identity fields are left as the stored contact's. See
    /// `liveOverride`. Interim stopgap; see
    /// docs/plans/2026-06-29-profile-table-implementation.md, section 10.1.
    static func memberAwareResolver(
        members: [ConversationMember],
        contactLookup: @escaping @Sendable (String) -> Contact?
    ) -> @Sendable (String) -> Contact? {
        let memberProfiles: [String: Profile] = Dictionary(
            members.map { ($0.profile.inboxId, $0.profile) },
            uniquingKeysWith: { current, _ in current }
        )
        return { inboxId in
            let stored = contactLookup(inboxId)
            guard let member = memberProfiles[inboxId] else { return stored }
            return Contact.liveOverride(member: member, stored: stored)
        }
    }
}

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
