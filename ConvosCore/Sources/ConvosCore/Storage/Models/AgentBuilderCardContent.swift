import Foundation

/// Render model for the agent-builder summary cell, reconstructed by
/// `MessagesListProcessor` from the "build" messages every member receives
/// (the prompt text + the attachment bundle the builder sent on the user's
/// behalf, referenced by the networked `BuilderBundleManifest`). Because it is
/// rebuilt from those messages rather than a local-only `AgentBuilderSummary`,
/// the card is visible to every member and sits in chronological order at the
/// point the user tapped Make -- not pinned to the top of the list.
///
/// `attachments` are the hydrated attachments from the bundle message, so the
/// card renders the same thumbnails the chat already loaded (no thumbnail bytes
/// travel in the manifest). `connectionIdentifiers` come from the creator's
/// local summary and are therefore empty on other members' clients -- cloud /
/// device connections are not messages and can't be reconstructed remotely.
public struct AgentBuilderCardContent: Sendable, Equatable, Hashable, Identifiable {
    /// Stable id derived from the anchor (earliest) build-message id, so the
    /// cell identity is the same on the creator and every recipient and does
    /// not churn across re-renders.
    public let id: String
    public let prompt: String
    public let attachments: [HydratedAttachment]
    /// Whether the build was created by the current user. Drives the footer copy
    /// ("You created an agent" vs "<name> created an agent") now that the card is
    /// visible to every member.
    public let creatorIsCurrentUser: Bool
    /// Display name of the member who created the agent (the build messages'
    /// sender). Used for the footer copy when `creatorIsCurrentUser` is false.
    public let creatorDisplayName: String
    /// Profile of the member who created the agent, used to render their avatar
    /// next to the footer attribution. Resolved from the build messages' sender
    /// (or the current user for the creator's own card); nil during the brief
    /// pending window before any message is available to resolve it.
    public let creatorProfile: Profile?
    /// Raw values of the iOS-side `AgentBuilderConnection`s enabled at Make.
    /// Populated only on the creator's client (from the local summary); empty
    /// elsewhere.
    public let connectionIdentifiers: [String]
    /// True when the builder targeted a conversation the user was already in.
    /// Drives invite-affordance behavior and the morph gate below.
    public let existingConversation: Bool
    /// Whether this card should pair with the composer's glass rect via the
    /// matched-geometry morph. Only meaningful for the creator's own freshly
    /// committed home-flow build (where the card sits at the top and the
    /// composer is on screen); false otherwise.
    public let transitionEligible: Bool

    public init(
        id: String,
        prompt: String,
        attachments: [HydratedAttachment] = [],
        creatorIsCurrentUser: Bool = true,
        creatorDisplayName: String = "",
        creatorProfile: Profile? = nil,
        connectionIdentifiers: [String] = [],
        existingConversation: Bool = false,
        transitionEligible: Bool = false
    ) {
        self.id = id
        self.prompt = prompt
        self.attachments = attachments
        self.creatorIsCurrentUser = creatorIsCurrentUser
        self.creatorDisplayName = creatorDisplayName
        self.creatorProfile = creatorProfile
        self.connectionIdentifiers = connectionIdentifiers
        self.existingConversation = existingConversation
        self.transitionEligible = transitionEligible
    }
}
