#if canImport(UIKit)
import ConvosCore
import SwiftUI

/// Environment delivery for the agent-share message card's two cross-cutting
/// dependencies -- the resolver that turns a share link into displayable agent
/// info, and the tap handler that opens the shared agent's contact detail.
/// Injected once at the cell (like `messageContextMenuState`) so they don't
/// have to thread through the deep messages-view hierarchy.

private struct AgentShareResolverKey: EnvironmentKey {
    static let defaultValue: any AgentShareResolving = MockAgentShareResolver()
}

private struct OnTapAgentShareKey: EnvironmentKey {
    static let defaultValue: @MainActor @Sendable (MessageAgentShare) -> Void = { _ in }
}

public extension EnvironmentValues {
    var agentShareResolver: any AgentShareResolving {
        get { self[AgentShareResolverKey.self] }
        set { self[AgentShareResolverKey.self] = newValue }
    }

    var onTapAgentShare: @MainActor @Sendable (MessageAgentShare) -> Void {
        get { self[OnTapAgentShareKey.self] }
        set { self[OnTapAgentShareKey.self] = newValue }
    }
}
#endif
