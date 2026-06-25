import ConvosCore
import SwiftUI
import UIKit

@MainActor
struct CellConfig {
    let conversationId: String
    let onTapInvite: (MessageInvite) -> Void
    /// Resolves whether the current user already joined the conversation an
    /// invite card points to, so it can show the member count instead of
    /// "Tap to join".
    let inviteMembershipResolver: any InviteMembershipResolving
    /// Resolves a received/sent agent-share link to the shared agent's public
    /// profile so its message card can render name / emoji / description.
    let agentShareResolver: any AgentShareResolving
    /// Fired when an agent-share message card is tapped -- opens the shared
    /// agent's template flow.
    let onTapAgentShare: @MainActor @Sendable (MessageAgentShare) -> Void
    let onTapAvatar: (AnyMessage) -> Void
    /// Fired when an avatar / sender label is tapped on a group that has no
    /// concrete `AnyMessage` to attach (e.g. the synthesized agent
    /// contact-card group). Routes to the same profile sheet
    /// `onTapAvatar` resolves to, just without needing a message.
    let onTapSender: (ConversationMember) -> Void
    let onTapReactions: (AnyMessage) -> Void
    let onTapReadReceipts: (MessagesGroup) -> Void
    let onTapThinkingIndicator: (ThinkingSessionDescriptor) -> Void
    let onReaction: (String, String) -> Void
    let onToggleReaction: (String, String) -> Void
    let onReply: (AnyMessage) -> Void
    /// Surfaces a pathological text bubble's "Read More" tap so the host can
    /// present `MessageDetailView`. Nil when no host handler is wired, which
    /// suppresses the button (nil-handler => no button contract).
    let onOpenMessageDetail: ((AnyMessage) -> Void)?
    /// Message ids with long-body inline expansion on (owned by the VM, so it
    /// survives `UICollectionView` cell reuse).
    let expandedMessageIds: Set<String>
    /// Toggles a message id's long-body inline expansion on the host.
    let onToggleMessageExpanded: (String) -> Void
    let contextMenuState: MessageContextMenuState
    let onAgentOutOfCredits: () -> Void
    let creditsDepleted: Bool
    let onRetryAgentJoin: () -> Void
    let onPhotoDimensionsLoaded: (String, Int, Int) -> Void
    let onTapUpdateMember: (ConversationMember) -> Void
    /// Fired when a pending capability connect pill is tapped — opens the
    /// approval sheet for the request it carries.
    let onTapCapabilityConnect: (CapabilityConnectPrompt) -> Void
    let onOpenFile: ((HydratedAttachment, AnyMessage) -> Void)?
    let onRetryMessage: (AnyMessage) -> Void
    let onDeleteMessage: (AnyMessage) -> Void
    let onCopyInviteLink: () -> Void
    let onConvoCode: () -> Void
    let onInviteAgent: () -> Void
    let onRetryTranscript: (VoiceMemoTranscriptListItem) -> Void
    let allVoiceMemoTranscripts: [String: VoiceMemoTranscriptListItem]
    let isAgentJoinPending: Bool
    let headerMode: MessagesHeaderMode
    /// Mirrors `Conversation.hidesInviteCard`. When true the `.invite`
    /// cell renders the invite menu without the QR card above it.
    let hidesInviteCard: Bool
    /// Shared SwiftUI namespace used to morph the Agent Builder's
    /// composer card into the summary cell on Make via
    /// `glassEffectID("agentBuilderCard", in:) +
    /// glassEffectTransition(.matchedGeometry)`. Nil when the messages list
    /// isn't part of a builder commit (regular chats).
    let agentBuilderTransitionNamespace: Namespace.ID?
    /// Shared SwiftUI namespace used to zoom-transition an
    /// `HTMLAttachmentBubble` into the post-tap `AttachmentPreviewSheet`.
    /// `MessagesView` owns the namespace and the matching `.sheet(item:)`.
    let htmlAttachmentTransitionNamespace: Namespace.ID?
    /// Maps an inbox to the user's full `Contact` when the inbox is a
    /// known contact. Cells use it for both the display-name override
    /// (via `?.displayName`) and avatar substitution (so a system-
    /// message row reads "Alice joined" with Alice's actual avatar
    /// rather than the per-conversation placeholder profile + S
    /// monogram). Returns nil for non-contacts, in which case the
    /// renderer falls back to the per-conversation profile.
    let memberContactOverride: (String) -> Contact?
}

// swiftlint:disable force_cast

@MainActor
final class CellFactory {
    static func createCell(
        in collectionView: UICollectionView,
        for indexPath: IndexPath,
        with item: MessagesListItemType,
        config: CellConfig
    ) -> UICollectionViewCell {
        if case .typingIndicator(let typers) = item {
            let cell = collectionView.dequeueReusableCell(
                withReuseIdentifier: TypingIndicatorCollectionCell.reuseIdentifier,
                for: indexPath
            ) as! TypingIndicatorCollectionCell
            cell.prepare(with: typers)
            return cell
        }

        let cell = collectionView.dequeueReusableCell(
            withReuseIdentifier: MessagesListItemTypeCell.reuseIdentifier,
            for: indexPath
        ) as! MessagesListItemTypeCell
        cell.setup(item: item, config: config)
        return cell
    }
}

// swiftlint:enable force_cast
