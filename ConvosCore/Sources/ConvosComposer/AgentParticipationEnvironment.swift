#if canImport(UIKit)
import SwiftUI

/// What the composer needs to show the participation control: the level the
/// conversation is in, and what to do when someone taps it.
///
/// The composer owns none of this. The host resolves the level for the
/// conversation and performs the change; the accessory is only the affordance.
/// The accessory itself lives inside the input field — see
/// `MessagesInputView.participationAccessory`.
public struct AgentParticipationContext {
    public let level: AgentParticipationLevel
    public let onTap: () -> Void

    public init(level: AgentParticipationLevel, onTap: @escaping () -> Void) {
        self.level = level
        self.onTap = onTap
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
