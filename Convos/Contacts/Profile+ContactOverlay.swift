import ConvosCore
import Foundation

extension Profile {
    /// Returns a new `Profile` with this profile's `name` and `avatar*`
    /// fields replaced by the supplied contact's. The
    /// `conversationId`, `isAgent`, `imageSourceContentDigest`, and
    /// `metadata` are preserved from the original.
    ///
    /// The chat layer uses this to render system-message and avatar
    /// rows with the user's contact-list data instead of the
    /// per-conversation profile when the inbox is a known contact —
    /// e.g. a member added via the contacts picker shows the contact's
    /// real name and avatar in "joined" rows even before they have
    /// published their per-conversation profile.
    func overlaying(contact: Contact) -> Profile {
        Profile(
            inboxId: inboxId,
            conversationId: conversationId,
            name: contact.displayName,
            avatar: contact.avatarURL,
            avatarSalt: contact.avatarSalt,
            avatarNonce: contact.avatarNonce,
            avatarKey: contact.avatarKey,
            isAgent: isAgent,
            imageSourceContentDigest: imageSourceContentDigest,
            metadata: metadata
        )
    }
}
