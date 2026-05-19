import ConvosCore
import SwiftUI

/// Full-height sheet that renders the per-session thinking history for one
/// `convos.org/thinking:1.0` descriptor. Reuses `MessagesViewController`
/// via `MessagesViewRepresentable` so each moment lands as a regular
/// text-message cell — bubbles, sender resolution, scroll anchoring,
/// insertion animation — without forking the rendering path.
///
/// Each agent `start` event is its own moment and renders as its own
/// one-message `MessagesGroup`. The groups carry `hidesAvatar = true`
/// except the most recent one, so the visual reading is "one grouped run
/// from the assistant with a single avatar at the bottom". DifferenceKit
/// treats the new groups as item insertions on the underlying
/// `UICollectionView`, so each moment animates in.
///
/// While the session is still active (no `resultMessageId` yet), the
/// `MessagesGroup` carries `showsThinkingIndicator = true` so the group's
/// trailing pulsing-dot bubble takes over the leading-avatar slot — the
/// avatar attaches to the bubble instead of the last text moment.
///
/// The view watches `viewModel.thinkingSessions` so it stays live as new
/// moments arrive — the descriptor stored on `presentingThinkingDetail` is
/// only the initial anchor (target message id + sender). The view resolves
/// the matching session on every render.
struct ThinkingDetailView: View {
    let descriptor: ThinkingSessionDescriptor
    let conversation: Conversation
    let viewModel: ConversationViewModel
    /// Invoked when the user taps the bottom-bar Stop button. The button
    /// is gated on `liveDescriptor.isActive`, so by the time this fires
    /// the session is still in progress. Hosts decide what to do (e.g.
    /// signal the agent, post a system message). Defaults to a no-op so
    /// the view stays usable in previews or contexts that don't wire it.
    var onStop: () -> Void = {}
    /// Factory for the assistant's profile sheet — same shape used by
    /// `MessagesView` so callers can reuse their existing builder.
    /// Tapping the top indicator capsule presents the result.
    var profileSheetForMember: (ConversationMember) -> AnyView = { _ in AnyView(EmptyView()) }

    @Environment(\.dismiss) private var dismiss: DismissAction
    @State private var focusCoordinator: FocusCoordinator = FocusCoordinator(horizontalSizeClass: .compact)
    @State private var bottomBarHeight: CGFloat = 0.0
    @State private var topBarHeight: CGFloat = 0.0
    @State private var presentingAssistantProfile: Bool = false

    /// Resolved descriptor for this render: prefers the matching session in
    /// the VM's live `thinkingSessions` feed so new moments propagate, falls
    /// back to the initial descriptor if the repository hasn't surfaced the
    /// session yet.
    private var liveDescriptor: ThinkingSessionDescriptor {
        let match = viewModel.thinkingSessions.first { session in
            session.senderInboxId == descriptor.sender.profile.inboxId
                && session.targetMessageId == descriptor.targetMessageId
        }
        guard let match else { return descriptor }
        return ThinkingSessionDescriptor(
            id: match.id,
            sender: descriptor.sender,
            targetMessageId: match.targetMessageId,
            moments: match.moments,
            resultMessageId: match.resultMessageId,
            isActive: match.isActive
        )
    }

    private var subtitle: String {
        liveDescriptor.isActive ? "Thinking" : "Done thinking"
    }

    private var thinkingMessages: [MessagesListItemType] {
        ThinkingDetailListProcessor.process(liveDescriptor)
    }

    var body: some View {
        ZStack {
            messagesBody
            VStack(spacing: 0.0) {
                topBar
                    .onGeometryChange(for: CGFloat.self) { proxy in
                        proxy.size.height
                    } action: { newHeight in
                        topBarHeight = newHeight
                    }
                Spacer()
                bottomBar
                    .onGeometryChange(for: CGFloat.self) { proxy in
                        proxy.size.height
                    } action: { newHeight in
                        bottomBarHeight = newHeight
                    }
            }
        }
        .presentationDetents([.large])
        .presentationDragIndicator(.hidden)
        .presentationBackground(.colorBackgroundRaisedSecondary)
        .sheet(isPresented: $presentingAssistantProfile) {
            profileSheetForMember(descriptor.sender)
        }
    }

    private var topBar: some View {
        ZStack {
            ThinkingDetailIndicator(
                descriptor: liveDescriptor,
                subtitle: subtitle,
                onTap: { presentingAssistantProfile = true }
            )
            HStack {
                Spacer()
                dismissButton
            }
        }
        .padding(.horizontal, DesignConstants.Spacing.step4x)
        .padding(.vertical, DesignConstants.Spacing.step3x)
    }

    private var dismissButton: some View {
        Button(action: { dismiss() }) {
            Image(systemName: "checkmark")
                .font(.body.weight(.semibold))
                .foregroundStyle(.colorTextPrimaryInverted)
                .frame(width: Constant.dismissButtonSize, height: Constant.dismissButtonSize)
                .background(.colorFillPrimary, in: .circle)
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Dismiss")
    }

    private var bottomBar: some View {
        HStack {
            Spacer()
            stopButton
        }
        .padding(.horizontal, DesignConstants.Spacing.step4x)
        .padding(.vertical, DesignConstants.Spacing.step3x)
    }

    private var stopButton: some View {
        let isEnabled: Bool = liveDescriptor.isActive
        let iconColor: Color = isEnabled ? .colorCaution : .colorTextTertiary
        return Button(action: onStop) {
            Image(systemName: "octagon.fill")
                .font(.body.weight(.semibold))
                .foregroundStyle(iconColor)
                .frame(width: Constant.stopButtonSize, height: Constant.stopButtonSize)
                .glassEffect(.regular, in: .circle)
        }
        .buttonStyle(.plain)
        .disabled(!isEnabled)
        .accessibilityLabel("Stop thinking")
    }

    private var messagesBody: some View {
        MessagesViewRepresentable(
            conversation: conversation,
            messages: thinkingMessages,
            invite: .empty,
            onUserInteraction: {},
            hasLoadedAllMessages: false,
            shouldBlurPhotos: true,
            focusCoordinator: focusCoordinator,
            onTapAvatar: { _ in },
            onLoadPreviousMessages: {},
            onTapInvite: { _ in },
            onReaction: { _, _ in },
            onToggleReaction: { _, _ in },
            onTapReactions: { _ in },
            onTapReadReceipts: { _ in },
            onTapThinkingIndicator: { _ in },
            onReply: { _ in },
            contextMenuState: .init(),
            onPhotoRevealed: { _ in },
            onPhotoHidden: { _ in },
            onPhotoDimensionsLoaded: { _, _, _ in },
            onAgentOutOfCredits: {},
            onTapUpdateMember: { _ in },
            onRetryMessage: { _ in },
            onDeleteMessage: { _ in },
            onRetryAssistantJoin: {},
            onCopyInviteLink: {},
            onConvoCode: {},
            onInviteAssistant: {},
            onRetryTranscript: { _ in },
            profileSheetForMember: { _ in AnyView(EmptyView()) },
            hasAssistant: conversation.hasAgent,
            isAssistantJoinPending: false,
            isAssistantEnabled: false,
            bottomBarHeight: bottomBarHeight,
            hasBottomBar: true,
            topContentInset: topBarHeight,
            onBottomOverscrollChanged: { _ in },
            onBottomOverscrollReleased: { _ in },
            scrollToBottomTrigger: { _ in },
            messageInputFocusTrigger: { _ in }
        )
        .ignoresSafeArea()
    }

    private enum Constant {
        static let dismissButtonSize: CGFloat = 44.0
        static let stopButtonSize: CGFloat = 44.0
    }
}

/// Capsule indicator at the top of `ThinkingDetailView`. Parallel to
/// `ConversationIndicator` but keyed off a `ThinkingSessionDescriptor` — the
/// conversation indicator's editable name / members shape doesn't fit a
/// thinking session (always one assistant, fixed "Thinking"/"Done thinking"
/// subtitle), so this is a sibling component rather than a configuration of
/// the same one.
///
/// Tapping the capsule fires `onTap`, which the parent wires to present
/// the assistant's profile sheet — same affordance as
/// `ConversationIndicator`. The pill uses an interactive glass effect so
/// the press state matches the rest of the floating chrome.
struct ThinkingDetailIndicator: View {
    let descriptor: ThinkingSessionDescriptor
    let subtitle: String
    var onTap: () -> Void = {}

    var body: some View {
        Button(action: onTap) {
            HStack(spacing: 0.0) {
                MessageAvatarView(
                    profile: descriptor.sender.profile,
                    size: Constant.avatarSize,
                    agentVerification: descriptor.sender.agentVerification
                )
                VStack(alignment: .leading, spacing: 0.0) {
                    Text(descriptor.sender.profile.displayName)
                        .lineLimit(1)
                        .font(.callout.weight(.medium))
                        .foregroundStyle(.colorTextPrimary)
                    Text(subtitle)
                        .lineLimit(1)
                        .font(.caption)
                        .foregroundStyle(.colorTextSecondary)
                }
                .padding(.horizontal, DesignConstants.Spacing.step2x)
            }
            .padding(DesignConstants.Spacing.step2x)
            .fixedSize(horizontal: true, vertical: true)
            .clipShape(.capsule)
            .glassEffect(.regular.interactive(), in: .capsule)
        }
        .buttonStyle(.plain)
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(descriptor.sender.profile.displayName), \(subtitle)")
        .accessibilityHint("Tap to see assistant profile")
    }

    private enum Constant {
        static let avatarSize: CGFloat = 36.0
    }
}
