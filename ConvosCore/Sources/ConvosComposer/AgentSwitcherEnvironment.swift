#if canImport(UIKit)
import ConvosCore
import SwiftUI

/// One agent the switcher can move to: enough to draw a menu row (name plus
/// avatar) and to report which agent was picked.
public struct AgentSwitcherOption: Identifiable, Equatable {
    public let inboxId: String
    public let profile: Profile
    public let displayName: String

    public var id: String { inboxId }

    public init(inboxId: String, profile: Profile, displayName: String) {
        self.inboxId = inboxId
        self.profile = profile
        self.displayName = displayName
    }
}

/// What the composer needs to show the agent switcher: the currently selected
/// agent (for the bubble avatar), the other agents in the conversation (the
/// menu's rows), and what to do when one is picked.
///
/// The composer owns none of this. The host resolves the agents and performs
/// the switch; the bubble is only the affordance. It leads the composer row on
/// the agent tab, taking the slot the participation bubble holds on the group
/// tab -- see `MessagesBottomBar.agentSwitcherBubble`.
public struct AgentSwitcherContext {
    public let selectedProfile: Profile
    public let selectedVerification: AgentVerification
    /// The agents other than the selected one; empty when the conversation has
    /// a single agent, which hides the bubble.
    public let otherAgents: [AgentSwitcherOption]
    public let onSelect: (String) -> Void

    public init(
        selectedProfile: Profile,
        selectedVerification: AgentVerification,
        otherAgents: [AgentSwitcherOption],
        onSelect: @escaping (String) -> Void
    ) {
        self.selectedProfile = selectedProfile
        self.selectedVerification = selectedVerification
        self.otherAgents = otherAgents
        self.onSelect = onSelect
    }
}

private struct AgentSwitcherEnvironmentKey: EnvironmentKey {
    static let defaultValue: AgentSwitcherContext?
    = nil
}

public extension EnvironmentValues {
    /// Set by the host on the agent tab of a conversation with more than one
    /// agent. `nil` means there is nothing to switch between, and the composer
    /// shows no bubble.
    var agentSwitcher: AgentSwitcherContext? {
        get { self[AgentSwitcherEnvironmentKey.self] }
        set { self[AgentSwitcherEnvironmentKey.self] = newValue }
    }
}
#endif
