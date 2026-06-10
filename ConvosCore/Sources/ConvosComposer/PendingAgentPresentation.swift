import SwiftUI

/// Identity-aware description of the optimistic "pending agent" rendering a
/// conversation should show before its verified agent has actually joined.
///
/// Two flows produce one of these and every indicator render site consumes
/// it (see `ConversationViewModel.pendingAgentPresentation`):
///
/// - Agent Builder: the "no identity" case. The builder has no real agent
///   identity at Make time, so it emits a generic presentation (`name` /
///   `emoji` nil -> "New Agent" + the add-agent glyph) and shows its own
///   summary card rather than a contact card (`showsContactCard == false`).
/// - Agent template (chat-on-a-contact or `convos://template/<id>` deep
///   link): the "with identity" case. The template name + emoji/photo are
///   painted immediately with verified styling, and the agent contact card is
///   shown in the messages list (`showsContactCard == true`).
public struct PendingAgentPresentation: Equatable, Sendable {
    /// `nil` falls back to the generic "New Agent" / "Agent" placeholder.
    public var name: String?
    /// `nil` falls back to the add-agent glyph (`PendingAgentAvatarView`).
    public var emoji: String?
    public var avatarURL: String?
    public var agentDescription: String?
    /// The builder uses its own summary card, so it sets this `false`; the
    /// template paths show the agent contact card once an identity exists.
    public var showsContactCard: Bool

    public init(
        name: String? = nil,
        emoji: String? = nil,
        avatarURL: String? = nil,
        agentDescription: String? = nil,
        showsContactCard: Bool
    ) {
        self.name = name
        self.emoji = emoji
        self.avatarURL = avatarURL
        self.agentDescription = agentDescription
        self.showsContactCard = showsContactCard
    }
}

/// Avatar-only slice of a `PendingAgentPresentation`, injected into the
/// SwiftUI environment so `ConversationAvatarView` can paint the upcoming
/// agent's emoji/photo (with verified styling) before any real member data
/// exists. `nil` (or a content-less value) means fall back to the add-agent
/// glyph driven by `forcedAgentVerification`.
public struct PendingAgentAvatarIdentity: Equatable, Sendable {
    public let emoji: String?
    public let avatarURL: String?

    public init(emoji: String?, avatarURL: String?) {
        self.emoji = emoji
        self.avatarURL = avatarURL
    }

    public var hasContent: Bool {
        (emoji?.isEmpty == false) || (avatarURL?.isEmpty == false)
    }
}

private struct PendingAgentAvatarIdentityKey: EnvironmentKey {
    static let defaultValue: PendingAgentAvatarIdentity? = nil
}

public extension EnvironmentValues {
    var pendingAgentIdentity: PendingAgentAvatarIdentity? {
        get { self[PendingAgentAvatarIdentityKey.self] }
        set { self[PendingAgentAvatarIdentityKey.self] = newValue }
    }
}

public extension PendingAgentPresentation {
    /// The avatar-environment value for this presentation, or `nil` when the
    /// presentation carries no emoji/photo (builder generic case + neutral
    /// deep-link placeholder) so the add-agent glyph shows instead.
    var avatarIdentity: PendingAgentAvatarIdentity? {
        let identity = PendingAgentAvatarIdentity(emoji: emoji, avatarURL: avatarURL)
        return identity.hasContent ? identity : nil
    }
}
