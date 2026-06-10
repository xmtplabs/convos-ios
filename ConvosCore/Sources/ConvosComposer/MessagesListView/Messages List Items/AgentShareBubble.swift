#if canImport(UIKit)
import ConvosCore
import SwiftUI

/// Renders a received/sent agent-share message as a contact card. The message
/// body carries only the share link; the agent's name / emoji / description
/// are resolved on appear via the `AgentShareResolving` injected through the
/// environment (matching how `messageContextMenuState` is delivered to cells).
/// While resolving, the card's own pulsing "Learning more about my job"
/// placeholder stands in.
///
/// This view is display-only: the tap that opens the shared agent's contact
/// detail is owned by the enclosing `messageGesture` (`onSingleTap`), so the
/// same gesture pipeline as other message bubbles handles it -- and the
/// context-menu preview, which renders this view without that gesture, stays
/// correctly non-interactive.
struct AgentShareBubble: View {
    let agentShare: MessageAgentShare

    @Environment(\.agentShareResolver) private var resolver: any AgentShareResolving

    @State private var resolved: AgentShareInfo?
    @State private var didResolve: Bool = false

    var body: some View {
        AgentContactCardView(
            profile: cardProfile,
            agentDescription: resolved?.descriptionText
        )
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
#endif
