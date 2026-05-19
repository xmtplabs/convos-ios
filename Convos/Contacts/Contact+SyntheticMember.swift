import ConvosCore
import Foundation

extension Contact {
    /// Builds a presentation-only `ConversationMember` from this contact,
    /// scoped to the supplied draft `conversationId`. Used by
    /// `NewConversationViewModel` to seed a draft `Conversation` with
    /// members that already carry the contact's name and avatar before
    /// the state machine reaches `.ready`. The resulting member is
    /// `isCurrentUser = false`, `role = .member`; agent verification is
    /// preserved from the contact so verified-agent affordances render
    /// correctly during the placeholder phase.
    func syntheticMember(conversationId: String) -> ConversationMember {
        let profile = Profile(
            inboxId: inboxId,
            conversationId: conversationId,
            name: displayName,
            avatar: avatarURL,
            avatarSalt: avatarSalt,
            avatarNonce: avatarNonce,
            avatarKey: avatarKey
        )
        return ConversationMember(
            profile: profile,
            role: .member,
            isCurrentUser: false,
            isAgent: false,
            agentVerification: agentVerification ?? .unverified
        )
    }
}
