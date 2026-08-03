#if canImport(UIKit)
import SwiftUI

/// What the composer needs to show the participation control: the level the
/// conversation is in, and what to do when someone picks another one.
///
/// The composer owns none of this. The host resolves the level for the
/// conversation and performs the change; the bubble is only the affordance.
/// The bubble itself leads the composer row, outside the input field — see
/// `MessagesBottomBar.participationBubble`.
public struct AgentParticipationContext {
    public let level: AgentParticipationLevel
    /// True while the conversation's real level is still being read. `level` is
    /// only a placeholder until then, so the bubble shows a resting dot instead
    /// of an icon that might be about to change under the member's eyes.
    public let isLoading: Bool
    public let onSelect: (AgentParticipationLevel) -> Void

    public init(level: AgentParticipationLevel, isLoading: Bool = false, onSelect: @escaping (AgentParticipationLevel) -> Void) {
        self.level = level
        self.isLoading = isLoading
        self.onSelect = onSelect
    }
}

private struct AgentParticipationEnvironmentKey: EnvironmentKey {
    static let defaultValue: AgentParticipationContext?
    = nil
}

public extension EnvironmentValues {
    /// Set by the host on conversations that have at least one agent. `nil`
    /// means there is nothing to govern, and the composer shows no bubble —
    /// a control for agents has no business in a conversation without one.
    var agentParticipation: AgentParticipationContext? {
        get { self[AgentParticipationEnvironmentKey.self] }
        set { self[AgentParticipationEnvironmentKey.self] = newValue }
    }
}
#endif
