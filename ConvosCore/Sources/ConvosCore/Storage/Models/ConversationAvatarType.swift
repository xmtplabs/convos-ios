import Foundation

public enum ConversationAvatarType: Sendable, Equatable {
    case customImage
    case profile(Profile, AgentVerification)
    case clustered([Profile])
    case emoji(String)
    case monogram(String)
    /// An Agent-Builder conversation whose verified agent hasn't joined
    /// yet. Rendered as the add-agent glyph (see `PendingAgentAvatarView`),
    /// mirroring the builder bar / indicator.
    case pendingAgent
}
