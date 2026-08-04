import Foundation

/// A single member rendered inside a clustered group avatar. Pairs the
/// profile with its `agentVerification` so each sub-avatar can show the
/// verified agent background color, mirroring the single-member
/// `.profile(Profile, AgentVerification)` case.
public struct ClusteredAvatarMember: Sendable, Equatable {
    public let profile: Profile
    public let agentVerification: AgentVerification

    public init(profile: Profile, agentVerification: AgentVerification = .unverified) {
        self.profile = profile
        self.agentVerification = agentVerification
    }
}

public enum ConversationAvatarType: Sendable, Equatable {
    case customImage
    case profile(Profile, AgentVerification)
    case clustered([ClusteredAvatarMember])
    case emoji(String)
    case monogram(String)
    /// An Agent-Builder conversation whose verified agent hasn't joined
    /// yet. Rendered as the add-agent glyph (see `PendingAgentAvatarView`),
    /// mirroring the builder bar / indicator.
    case pendingAgent
}
