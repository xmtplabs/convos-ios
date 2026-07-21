import ConvosComposer
import ConvosCore
import SwiftUI

/// One agent's brainstorm page inside `ConversationPager`. Renders the
/// agent's full thinking history (each session preceded by the message it
/// was attached to) interleaved with the brainstorm reply thread, plus a
/// composer whose sends stay out of the main chat (see
/// `ConversationViewModel+Brainstorm`).
struct BrainstormPageView: View {
    @Bindable var viewModel: ConversationViewModel
    let agentInboxId: String

    /// Local focus state, deliberately not shared with the chat composer:
    /// every pager page stays mounted in the paging HStack, so a shared
    /// `.message` focus value would fight with the chat page's text field.
    @FocusState private var focusState: MessagesViewInputFocus?
    @State private var focusCoordinator: FocusCoordinator = FocusCoordinator(horizontalSizeClass: .compact)
    @State private var messageText: String = ""
    @State private var bottomBarHeight: CGFloat = 0.0
    @State private var presentingMomentDetail: AnyMessage?

    private var agent: ConversationMember? {
        viewModel.brainstormAgent(inboxId: agentInboxId)
    }

    private var agentName: String {
        agent?.displayName ?? "Agent"
    }

    private var items: [MessagesListItemType] {
        viewModel.brainstormItems(for: agentInboxId)
    }

    private var hasContent: Bool {
        viewModel.hasBrainstormContent(for: agentInboxId)
    }

    private var sendButtonEnabled: Bool {
        !messageText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    var body: some View {
        ZStack {
            if hasContent {
                messagesBody
            } else {
                BrainstormEmptyStateView(agentName: agentName, onStart: handleStartBrainstorming)
            }
        }
        // Same canvas as ThinkingDetailView's presentation background: the
        // thought bubbles fill with colorBackgroundRaised, which disappears
        // against the default page background.
        .background(Color.colorBackgroundRaisedSecondary)
        .safeAreaInset(edge: .bottom, spacing: 0) {
            composer
        }
        .sheet(item: $presentingMomentDetail) { moment in
            MessageDetailView(
                message: moment,
                onCopy: { text in UIPasteboard.general.string = text },
                onReply: { _ in presentingMomentDetail = nil }
            )
        }
    }

    private func handleStartBrainstorming() {
        focusState = .message
    }

    private func handleSendMessage() {
        let text = messageText
        messageText = ""
        viewModel.sendBrainstormMessage(text: text, toAgentInboxId: agentInboxId)
    }

    private var composer: some View {
        MessagesInputView(
            displayName: .constant(""),
            emptyDisplayNamePlaceholder: "",
            messageText: $messageText,
            messagePlaceholder: "Chat with \(agentName)",
            pendingInviteConvoName: .constant(""),
            pendingInviteImage: .constant(nil),
            sendButtonEnabled: sendButtonEnabled,
            focusState: $focusState,
            messagesTextFieldEnabled: true,
            onSendMessage: handleSendMessage,
            onClearInvite: {},
            fileAttachmentPreview: { _ in EmptyView() },
            agentShareChip: { EmptyView() }
        )
        .fixedSize(horizontal: false, vertical: true)
        .clipShape(.rect(cornerRadius: 26.0))
        .glassEffect(.regular.interactive(), in: .rect(cornerRadius: 26.0))
        .padding(.horizontal, DesignConstants.Spacing.step4x)
        .padding(.bottom, DesignConstants.Spacing.step3x)
        .onGeometryChange(for: CGFloat.self) { proxy in
            proxy.size.height
        } action: { newHeight in
            bottomBarHeight = newHeight
        }
    }

    private var messagesBody: some View {
        MessagesViewRepresentable(
            conversation: viewModel.conversation,
            messages: items,
            invite: .empty,
            onUserInteraction: {},
            hasLoadedAllMessages: false,
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
            onOpenMessageDetail: { presentingMomentDetail = $0 },
            contextMenuState: .init(),
            onPhotoDimensionsLoaded: { _, _, _ in },
            onAgentOutOfCredits: {},
            creditsDepleted: false,
            onTapUpdateMember: { _ in },
            onRetryMessage: { _ in },
            onDeleteMessage: { _ in },
            onRetryAgentJoin: {},
            onCopyInviteLink: {},
            onConvoCode: {},
            onInviteAgent: {},
            onRetryTranscript: { _ in },
            profileSheetForMember: { _ in AnyView(EmptyView()) },
            memberContactOverride: { _ in nil },
            isAgentJoinPending: false,
            bottomBarHeight: bottomBarHeight,
            hasBottomBar: true,
            topContentInset: 0.0,
            scrollToBottomTrigger: { _ in },
            messageInputFocusTrigger: { _ in }
        )
        .ignoresSafeArea()
    }
}

/// Empty-state CTA for a brainstorm page with no thinking history and no
/// thread yet. Mirrors the `EmptyStateCTAView` layout (fixed headline slot,
/// subtitle, rounded CTA) without the mock carousel.
private struct BrainstormEmptyStateView: View {
    let agentName: String
    let onStart: () -> Void

    var body: some View {
        VStack(spacing: 0) {
            Spacer(minLength: 0)
            TightLineHeightText(
                text: "Brainstorm with \(agentName)",
                fontSize: Constant.headlineFontSize,
                lineHeight: Constant.headlineLineHeight,
                weight: .regular,
                textAlignment: .center
            )
            Text("Without notifying the group")
                .font(.body)
                .multilineTextAlignment(.center)
                .foregroundStyle(.colorTextSecondary)
                .padding(.top, DesignConstants.Spacing.step2x)
            startButton
                .padding(.top, DesignConstants.Spacing.step5x)
            Spacer(minLength: 0)
        }
        .offset(y: -DesignConstants.Spacing.step6x)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(.horizontal, DesignConstants.Spacing.step6x)
        .background(.colorBackgroundSurfaceless)
    }

    private var startButton: some View {
        Button(action: onStart) {
            HStack(spacing: DesignConstants.Spacing.step2x) {
                Image(systemName: "bubbles.and.sparkles")
                Text("Start brainstorming")
                    .font(.callout)
            }
        }
        .convosButtonStyle(.rounded(fullWidth: false, backgroundColor: .colorLava))
        .accessibilityIdentifier("brainstorm-empty-state-start-button")
    }

    private enum Constant {
        static let headlineFontSize: CGFloat = 40.0
        static let headlineLineHeight: CGFloat = 40.0
    }
}
