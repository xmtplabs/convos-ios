#if canImport(UIKit)
import SwiftUI

/// What the composer needs to show the participation control: the level the
/// conversation is in, and what to do when someone taps it.
///
/// The composer owns none of this. The host resolves the level for the
/// conversation and performs the change; the bubble is only the affordance.
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

/// The participation bubble that sits in the input bar next to the attachment
/// control, wearing the icon of the level the conversation is in.
///
/// It is in the composer, not buried in the agent's profile, because every
/// member may change the level and the moment they want to is while they are
/// typing — and because the icon doubles as the answer to "is the agent
/// listening right now".
public struct AgentParticipationBubble: View {
    let level: AgentParticipationLevel
    let action: () -> Void

    public init(level: AgentParticipationLevel, action: @escaping () -> Void) {
        self.level = level
        self.action = action
    }

    public var body: some View {
        Button(action: action) {
            Image(systemName: level.iconSystemName)
                .font(.system(size: 18.0, weight: .medium))
                .foregroundStyle(Color.colorTextPrimary)
                .frame(width: 32, height: 32)
                .contentShape(.circle)
        }
        .buttonStyle(.plain)
        .frame(
            width: DesignConstants.Spacing.step12x,
            height: DesignConstants.Spacing.step12x
        )
        .clipShape(.circle)
        .glassEffect(.regular.interactive(), in: .circle)
        .accessibilityLabel("Agent participation: \(level.title)")
        .accessibilityHint("Change how much the agents speak here")
        .accessibilityIdentifier("agent-participation-button")
    }
}
#endif
