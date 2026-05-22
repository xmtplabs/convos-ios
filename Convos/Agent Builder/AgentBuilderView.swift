import ConvosCore
import SwiftUI

/// Where the [[AgentBuilderView]] is being rendered. Drives whether it
/// shows a close button (`.sheet` — the default presentation from the
/// bottom builder bar) and whether the post-Make morph stays in-tree
/// (`.sheet`) or fires `onCommitted` so a parent can present the
/// resulting conversation in a fresh sheet (`.inline` — used as the
/// chats-list empty state).
enum AgentBuilderMode {
    case sheet
    case inline
}

struct AgentBuilderView: View {
    @Bindable var viewModel: AgentBuilderViewModel
    @Bindable var profileSettingsViewModel: ProfileSettingsViewModel
    var mode: AgentBuilderMode = .sheet
    /// Fires once when the builder commits in `.inline` mode, passing the
    /// just-created conversation view-model so the parent can present it
    /// (typically as a sheet over the chats tab). Ignored in `.sheet`
    /// mode — the existing in-place morph still owns that flow.
    var onCommitted: ((ConversationViewModel) -> Void)?

    @Environment(\.dismiss) private var dismiss: DismissAction
    @Environment(\.horizontalSizeClass) private var horizontalSizeClass: UserInterfaceSizeClass?
    @State private var focusCoordinator: FocusCoordinator = FocusCoordinator(horizontalSizeClass: nil)
    @State private var sidebarWidth: CGFloat = 0
    @State private var presentingDiscardConfirmation: Bool = false
    @State private var didFireInlineCommit: Bool = false
    /// Local focus state for `.inline` mode. Sheet mode reads its focus
    /// state from [[ConversationPresenter]]'s content closure (which owns
    /// the focus chain across the conversation + the composer); inline
    /// mode renders only the composer, so it manages its own.
    @FocusState private var inlineFocusState: MessagesViewInputFocus?
    /// Shared SwiftUI namespace used to morph the draft composer's rounded-
    /// rect card into the post-commit summary cell. Threaded down to the
    /// composer (same SwiftUI tree) and into the messages collection view's
    /// summary cell via `CellConfig.agentBuilderTransitionNamespace`.
    /// Both ends apply `glassEffectID("agentBuilderCard", in:) +
    /// glassEffectTransition(.matchedGeometry)`, letting the OS-level glass
    /// compositor handle the cross-tree geometry match.
    @Namespace private var transitionNamespace: Namespace.ID

    private var indicatorPlaceholder: String? {
        viewModel.hasCommitted ? nil : "New Agent"
    }

    private var indicatorSubtitle: String? {
        viewModel.hasCommitted ? nil : "Draft"
    }

    /// Force the indicator/avatar to render with the Convos-verified
    /// agent style from the first frame — the conversation itself
    /// is still a draft with no members, so without this override the
    /// avatar would default to the unverified grey style.
    private var forcedVerification: AgentVerification? {
        viewModel.hasCommitted ? nil : .verified(.convos)
    }

    private var composerHintText: String {
        let hasText: Bool = !viewModel.composerText.isEmpty
        let hasAttachment: Bool = !viewModel.pendingMediaAttachments.isEmpty || viewModel.recordedVoiceMemo != nil
        if hasText && hasAttachment {
            return "The more info, the better"
        }
        return "Start with a pic, screenshot, voice note or connection"
    }

    var body: some View {
        modeBody
        .environment(\.forcedAgentVerification, forcedVerification)
        .interactiveDismissDisabled(!viewModel.hasCommitted && viewModel.hasContent)
        .onAppear {
            focusCoordinator.horizontalSizeClass = horizontalSizeClass
            // Flag the wrapper (which propagates onto the current inner
            // conversation VM and across any inbox-acquisition VM swap) as
            // "in builder flow". The flag drives two things:
            //   - thinking-indicator routing pushes agent sessions
            //     under the contact card instead of the inline footer
            //   - the messages-list processor suppresses the legacy
            //     "Agent joined" update row for the duration of the
            //     builder UX, so it doesn't flash through the morph
            // Cleared when the builder dismisses (whether via Make morph
            // or X cancel) so ordinary post-Make agent chatter anchors
            // inline like a normal agent convo.
            viewModel.newConversationViewModel.isInAgentBuilderFlow = true
        }
        .onDisappear {
            viewModel.newConversationViewModel.isInAgentBuilderFlow = false
            if !viewModel.hasCommitted && !viewModel.isCommitting {
                viewModel.discard()
            }
        }
        .onChange(of: horizontalSizeClass) { _, newSizeClass in
            focusCoordinator.horizontalSizeClass = newSizeClass
        }
        .onChange(of: viewModel.hasCommitted) { _, committed in
            guard mode == .inline, committed, !didFireInlineCommit else { return }
            guard let convoVM = viewModel.newConversationViewModel.conversationViewModel else { return }
            didFireInlineCommit = true
            onCommitted?(convoVM)
        }
    }

    @ViewBuilder
    private var modeBody: some View {
        switch mode {
        case .sheet:
            ConversationPresenter(
                viewModel: viewModel.newConversationViewModel.conversationViewModel,
                focusCoordinator: focusCoordinator,
                insetsTopSafeArea: false,
                sidebarColumnWidth: $sidebarWidth,
                indicatorPlaceholderOverride: indicatorPlaceholder,
                indicatorSubtitleOverride: indicatorSubtitle,
                allowsIndicatorEditing: viewModel.hasCommitted,
                defaultFocusOverride: viewModel.hasCommitted ? nil : .agentBuilder
            ) { focusState, coordinator in
                content(focusState: focusState, coordinator: coordinator)
            }
        case .inline:
            inlineBody
        }
    }

    /// Composer-only rendering used when the builder is hosted directly
    /// inside another view (e.g. the chats list's empty state). No top
    /// bar, no conversation indicator, no underlying conversation morph
    /// — those are owned by the host. Once `viewModel.hasCommitted`
    /// flips true the `onCommitted` callback fires and the host unmounts
    /// this view in favor of its own committed-conversation presentation
    /// (typically a sheet over the chats tab).
    @ViewBuilder
    private var inlineBody: some View {
        Group {
            if viewModel.hasCommitted {
                Color.clear
            } else {
                composerRect(focusState: $inlineFocusState)
            }
        }
        .onAppear {
            focusCoordinator.moveFocus(to: .agentBuilder)
        }
        .onChange(of: focusCoordinator.currentFocus) { _, newFocus in
            inlineFocusState = newFocus
        }
        .onChange(of: inlineFocusState) { _, newFocus in
            focusCoordinator.syncFocusState(newFocus)
        }
    }

    @ViewBuilder
    private func content(
        focusState: FocusState<MessagesViewInputFocus?>.Binding,
        coordinator: FocusCoordinator
    ) -> some View {
            NavigationStack {
                ZStack(alignment: .top) {
                    underlyingConversationView(focusState: focusState, coordinator: coordinator)

                    if !viewModel.hasCommitted {
                        Color.colorBackgroundRaisedSecondary
                            .ignoresSafeArea()
                            .transition(.opacity)
                            .zIndex(1)
                    }

                    if !viewModel.hasCommitted {
                        composerRect(focusState: focusState)
                            .transition(.asymmetric(
                                insertion: .opacity,
                                removal: .move(edge: .bottom)
                                    .combined(with: .opacity)
                                    .combined(with: .scale(scale: 0.85, anchor: .bottom))
                            ))
                            .zIndex(2)
                    }
                }
                .animation(.spring(response: 0.42, dampingFraction: 0.85), value: viewModel.hasCommitted)
                .toolbar {
                    if mode == .sheet {
                        closeToolbarItem
                    }
                }
                .toolbarTitleDisplayMode(.inline)
                .onAppear {
                    coordinator.moveFocus(to: .agentBuilder)
                }
        }
    }

    @ViewBuilder
    private func underlyingConversationView(
        focusState: FocusState<MessagesViewInputFocus?>.Binding,
        coordinator: FocusCoordinator
    ) -> some View {
        if let convoVM = viewModel.newConversationViewModel.conversationViewModel {
            ConversationView(
                viewModel: convoVM,
                profileSettingsViewModel: profileSettingsViewModel,
                focusState: focusState,
                focusCoordinator: coordinator,
                onScanInviteCode: {},
                onDeleteConversation: {
                    viewModel.discard()
                    dismiss()
                },
                messagesTopBarTrailingItem: viewModel.newConversationViewModel.messagesTopBarTrailingItem,
                messagesTopBarTrailingItemEnabled: viewModel.newConversationViewModel.messagesTopBarTrailingItemEnabled,
                messagesTextFieldEnabled: viewModel.newConversationViewModel.messagesTextFieldEnabled,
                topBarTrailingHidden: !viewModel.hasCommitted,
                headerMode: .hidden,
                agentBuilderTransitionNamespace: transitionNamespace,
                bottomBarContent: { EmptyView() }
            )
        } else {
            Color.colorBackgroundRaisedSecondary
        }
    }

    private func composerRect(
        focusState: FocusState<MessagesViewInputFocus?>.Binding
    ) -> some View {
        VStack(spacing: 0) {
            AgentDraftComposer(
                viewModel: viewModel,
                focusState: focusState,
                transitionNamespace: transitionNamespace,
                onMakeTap: {
                    // Hand focus over to the chat's text field BEFORE
                    // collapsing the composer, so the keyboard stays up
                    // and MessagesBottomBar's expanded state animates in
                    // on the next focus-change tick.
                    if focusState.wrappedValue == .agentBuilder {
                        focusCoordinator.moveFocus(to: .message)
                    }
                    withAnimation(.easeInOut(duration: 0.35)) {
                        viewModel.commit(focusCoordinator: focusCoordinator)
                    }
                }
            )
            .frame(maxHeight: Constant.composerHeight)
            .padding(.horizontal, DesignConstants.Spacing.step4x)
            .padding(.top, DesignConstants.Spacing.step4x)

            if !viewModel.isRecordingVoiceMemo {
                Text(composerHintText)
                    .font(.caption)
                    .foregroundStyle(.colorTextSecondary)
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: .infinity)
                    .padding(.horizontal, DesignConstants.Spacing.step4x)
                    .padding(.top, DesignConstants.Spacing.step2x)
                    .padding(.bottom, DesignConstants.Spacing.step3x)
            }

            if viewModel.isRecordingVoiceMemo {
                Spacer(minLength: 0)
                recordingControls(focusState: focusState)
                    .transition(.blurReplace)
                Spacer(minLength: 0)
            } else {
                Spacer(minLength: 0)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .animation(.easeInOut(duration: 0.25), value: viewModel.isRecordingVoiceMemo)
    }

    @ViewBuilder
    private func recordingControls(
        focusState: FocusState<MessagesViewInputFocus?>.Binding
    ) -> some View {
        VStack(spacing: DesignConstants.Spacing.step4x) {
            Button {
                let shouldRestore = viewModel.stopVoiceMemoRecording()
                if shouldRestore {
                    // SwiftUI's `@FocusState` ignores a focus assignment
                    // landed on the same runloop tick the controlling
                    // view tree is mid-animation through (the recording-
                    // controls `.blurReplace` collapse). Dispatching one
                    // tick out lets the composer text field finish its
                    // own state settle, then accept focus.
                    Task { @MainActor in
                        try? await Task.sleep(for: .milliseconds(80))
                        focusState.wrappedValue = .agentBuilder
                    }
                }
            } label: {
                ZStack {
                    Circle()
                        .fill(Color.colorCaution)
                    RoundedRectangle(cornerRadius: 5)
                        .fill(.white)
                        .frame(width: 26, height: 26)
                }
                .frame(width: 120, height: 120)
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Stop voice memo recording")
            .accessibilityIdentifier("agent-builder-stop-recording-button")

            VStack(spacing: DesignConstants.Spacing.step2x) {
                Text("What should this little agent do?")
                    .font(.body)
                    .foregroundStyle(.colorTextPrimary)
                Text("Tip: Rambling is fine!")
                    .font(.footnote)
                    .foregroundStyle(.colorTextSecondary)
            }
            .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity)
    }

    @ToolbarContentBuilder
    private var closeToolbarItem: some ToolbarContent {
        ToolbarItem(placement: .topBarLeading) {
            Button(role: .close) {
                handleCloseTapped()
            }
            .confirmationDialog(
                "",
                isPresented: $presentingDiscardConfirmation
            ) {
                Button("Discard", role: .destructive) {
                    viewModel.discard()
                    dismiss()
                }
                Button("Continue") {}
            }
            .accessibilityIdentifier("close-agent-builder")
        }
    }

    private func handleCloseTapped() {
        if viewModel.hasCommitted {
            dismiss()
        } else if viewModel.hasContent {
            presentingDiscardConfirmation = true
        } else {
            viewModel.discard()
            dismiss()
        }
    }

    private enum Constant {
        static let composerHeight: CGFloat = 375.0
    }
}

#Preview {
    @Previewable @State var viewModel: AgentBuilderViewModel = .init(
        session: ConvosClient.mock().session
    )
    @Previewable @State var profileSettingsViewModel: ProfileSettingsViewModel = .shared
    @Previewable @State var presented: Bool = true
    VStack {}
        .sheet(isPresented: $presented) {
            AgentBuilderView(
                viewModel: viewModel,
                profileSettingsViewModel: profileSettingsViewModel
            )
        }
}
