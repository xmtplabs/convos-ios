#if canImport(UIKit)
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
    /// Interim stopgap: remove once identity resolves from ProfilesRepository.
    public static func liveOverride(member: Profile, stored: Contact?) -> Contact {
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

    /// Deprecated no-op. Identity (name and image) is now sourced authoritatively
    /// from the `Profile` database; contact data never overrides it. Returns a
    /// resolver that yields `nil` for every inbox so callers fall through to the
    /// member `Profile`. Retained (ignoring its arguments) so call sites compile
    /// until the contact-override plumbing is fully removed.
    public static func memberAwareResolver(
        members: [ConversationMember],
        contactLookup: @escaping @Sendable (String) -> Contact?
    ) -> @Sendable (String) -> Contact? {
        { _ in nil }
    }
}

public extension Profile {
    /// Deprecated no-op. Identity (name and image) is sourced authoritatively
    /// from the `Profile` database; contact data never overrides it, so this
    /// returns the profile unchanged. Retained so call sites compile until the
    /// contact-override plumbing is removed.
    func overlaying(contact: Contact) -> Profile {
        self
    }
}
#endif
