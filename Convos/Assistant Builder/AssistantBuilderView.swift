import ConvosCore
import SwiftUI

struct AssistantBuilderView: View {
    @Bindable var viewModel: AssistantBuilderViewModel

    @Environment(\.dismiss) private var dismiss: DismissAction
    @Environment(\.horizontalSizeClass) private var horizontalSizeClass: UserInterfaceSizeClass?
    @Environment(\.safeAreaInsets) private var safeAreaInsets: EdgeInsets
    @Namespace private var indicatorNamespace

    var body: some View {
        // Structure mirrors ConversationPresenter exactly: the indicator
        // overlay lives at the *outer* ZStack level so it can float above
        // the NavigationStack's bar, not below it.
        ZStack {
            NavigationStack {
                canvas
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .background(.colorBackgroundSurfaceless)
                    .toolbar {
                        ToolbarItem(placement: .topBarLeading) {
                            Button(role: .close) {
                                dismiss()
                            }
                            .accessibilityIdentifier("close-assistant-builder")
                        }

                        ToolbarItem(placement: .topBarTrailing) {
                            addToConversationMenu
                        }
                    }
            }

            VStack {
                indicator
                    .padding(.top, indicatorTopPadding)
                Spacer()
            }
            .ignoresSafeArea()
            .zIndex(1000)
        }
        .overlay {
            if viewModel.presentingShareView,
               let conversation = viewModel.conversation,
               let invite = viewModel.invite {
                ConversationShareOverlay(
                    conversation: conversation,
                    invite: invite,
                    isPresented: $viewModel.presentingShareView,
                    topSafeAreaInset: 0
                )
            }
        }
        .interactiveDismissDisabled()
        .onAppear {
            viewModel.setDismissAction(dismiss)
        }
    }

    /// Match ConversationPresenter when called from NewConversationView, which
    /// passes `insetsTopSafeArea: false` — so the gating expression collapses
    /// to a small fixed offset regardless of horizontal size class.
    private var indicatorTopPadding: CGFloat {
        DesignConstants.Spacing.step3x
    }

    /// Mirrors the conversation view's `+` menu but omits the "Instant
    /// assistant" item — the assistant is what we're building, so it
    /// has no place inviting another. Disabled until the invite is
    /// available (it streams in shortly after bootstrap).
    private var addToConversationMenu: some View {
        Menu {
            let copyLink = { viewModel.copyInviteLink() }
            Button(action: copyLink) {
                Text("Invite link")
                Text("Copy to clipboard")
                Image(systemName: "link")
            }
            .accessibilityIdentifier("assistant-builder-menu-copy-link")

            let showCode = { viewModel.presentingShareView = true }
            Button(action: showCode) {
                Text("Convo code")
                Text("Show, share or AirDrop it")
                Image(systemName: "qrcode")
            }
            .accessibilityIdentifier("assistant-builder-menu-convo-code")
        } label: {
            Image(systemName: "plus")
        }
        .disabled(viewModel.invite == nil)
        .accessibilityLabel("Add to conversation")
        .accessibilityIdentifier("assistant-builder-add-to-conversation")
    }

    @ViewBuilder
    private var indicator: some View {
        GlassEffectContainer {
            AssistantBuilderToolbarButton(
                assistantProfile: viewModel.assistantProfile,
                assistantVerification: viewModel.assistantVerification,
                assistantName: viewModel.assistantName,
                placeholderName: "New assistant",
                subtitle: "Draft"
            )
            .fixedSize(horizontal: false, vertical: true)
            .clipShape(.capsule)
            .glassEffect(.regular.interactive(), in: .capsule)
            .glassEffectID("assistantBuilderIndicator", in: indicatorNamespace)
            .glassEffectTransition(.matchedGeometry)
            // Indicator is non-interactive while focus is live.
            .allowsHitTesting(viewModel.phase != .focus)
        }
    }

    @ViewBuilder
    private var canvas: some View {
        Group {
            switch viewModel.phase {
            case .bootstrap, .focus:
                // Bootstrap and focus share the same layout — the focused
                // bubble shows "Waiting for assistant…" until the agent
                // joins and is promoted, then crossfades to its live text.
                FocusModeView(viewModel: viewModel)
                    .transition(.opacity)
            case .stopped:
                if viewModel.didTransitionToConversation {
                    fullConversationCanvas
                        .transition(.opacity.combined(with: .scale(scale: 1.02)))
                } else {
                    sessionEndedCanvas
                        .transition(.opacity)
                }
            }
        }
        .animation(.spring(response: 0.5, dampingFraction: 0.85), value: viewModel.phase)
        .animation(.spring(response: 0.5, dampingFraction: 0.85), value: viewModel.didTransitionToConversation)
    }

    // MARK: - Per-phase canvases

    @ViewBuilder
    private var sessionEndedCanvas: some View {
        let endedText: String = viewModel.focusedMemberLiveText.isEmpty
            ? "Your assistant is ready."
            : viewModel.focusedMemberLiveText
        VStack(spacing: DesignConstants.Spacing.step4x) {
            LiveBubble(
                text: endedText,
                style: .focusedMember,
                tailCorner: .topTrailing,
                agentVerification: viewModel.assistantVerification
            )
            .frame(maxWidth: .infinity, maxHeight: .infinity)

            let startChattingAction = { viewModel.startChattingTapped() }
            Button(action: startChattingAction) {
                Text("Start chatting")
                    .frame(maxWidth: .infinity)
            }
            .convosButtonStyle(.rounded(fullWidth: true))
            .frame(maxHeight: 80)
            .accessibilityIdentifier("start-chatting-button")
        }
        .padding(DesignConstants.Spacing.step3x)
    }

    @ViewBuilder
    private var fullConversationCanvas: some View {
        VStack(spacing: DesignConstants.Spacing.step4x) {
            Image(systemName: "bubble.left.and.bubble.right.fill")
                .font(.system(size: 48, weight: .semibold))
                .foregroundStyle(.colorTextPrimary)
            Text("Conversation started")
                .font(.system(.title2, weight: .bold))
                .foregroundStyle(.colorTextPrimary)
            Text("(ConversationView would render here)")
                .font(.caption)
                .foregroundStyle(.colorTextSecondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

#Preview {
    @Previewable @State var presented: Bool = true
    let viewModel = AssistantBuilderViewModel(session: ConvosClient.mock().session)
    VStack {}
        .sheet(isPresented: $presented) {
            AssistantBuilderView(viewModel: viewModel)
        }
}
