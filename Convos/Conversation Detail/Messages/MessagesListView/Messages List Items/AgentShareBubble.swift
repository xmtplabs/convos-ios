import ConvosCore
import SwiftUI

/// Renders a received/sent agent-share message as a contact card. The message
/// body carries only the share link; the agent's name / emoji / description
/// are resolved on appear via the `AgentShareResolving` injected through the
/// environment (mocked today, API-backed later). While resolving, the card's
/// own pulsing "Learning more about my job" placeholder stands in. Tapping the
/// card opens the shared agent's template flow.
///
/// The resolver and tap handler are injected via the environment rather than
/// threaded through the (deep) messages-view hierarchy, matching how
/// `messageContextMenuState` is delivered to cells.
struct AgentShareBubble: View {
    let agentShare: MessageAgentShare

    @Environment(\.agentShareResolver) private var resolver: any AgentShareResolving
    @Environment(\.onTapAgentShare) private var onTapAgentShare: @MainActor @Sendable (MessageAgentShare) -> Void

    @State private var resolved: AgentShareInfo?
    @State private var didResolve: Bool = false

    var body: some View {
        let action = { onTapAgentShare(agentShare) }
        Button(action: action) {
            AgentContactCardView(
                profile: cardProfile,
                agentDescription: resolved?.descriptionText
            )
        }
        .buttonStyle(.plain)
        .task(id: agentShare.identifier) {
            guard !didResolve else { return }
            let info = await resolver.resolve(identifier: agentShare.identifier)
            await MainActor.run {
                resolved = info
                didResolve = true
            }
        }
        .accessibilityIdentifier("agent-share-card")
    }

    /// Synthesizes a `Profile` from the resolved info so the existing
    /// `AgentContactCardView` renders unchanged (the emoji rides in profile
    /// metadata exactly as a real agent profile carries it). Before the
    /// resolve completes, the profile is name-less so the card shows its
    /// pulsing placeholder.
    private var cardProfile: Profile {
        Profile(
            inboxId: "agent-share-\(agentShare.identifier)",
            conversationId: "agent-share",
            name: resolved?.displayName,
            avatar: resolved?.avatarURL,
            isAgent: true,
            metadata: resolved?.emoji.map { ["emoji": .string($0)] }
        )
    }
}
