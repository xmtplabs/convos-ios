import ConvosCore
import ConvosCoreiOS
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
    @Environment(\.openURL) private var openURL: OpenURLAction
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

    /// The existing-conversation builder dismisses on Make and lands the user
    /// back on the chat they triggered it from, rather than morphing to reveal
    /// the conversation inside the sheet (the home/draft flow's behavior, where
    /// there is no underlying chat to return to).
    private var dismissesOnCommit: Bool {
        viewModel.existingConversationId != nil
    }

    private var indicatorPlaceholder: String? {
        if viewModel.hasCommitted { return nil }
        if viewModel.isInRemixMode { return "Remix" }
        return "New Agent"
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
        // When the user has already picked a remix agent, they're
        // adding customizations on top of an existing template --
        // not starting fresh -- so swap the verb.
        if viewModel.pickedRemixAgent != nil {
            return "Add a pic, screenshot, voice note or connection"
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
            startVoiceMemoIfNeeded()
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
        .onChange(of: viewModel.pickedRemixAgent) { _, newPicked in
            // After the user picks a card off the carousel, jump focus
            // straight into the prompt field so they can start
            // customizing without an extra tap.
            guard newPicked != nil else { return }
            focusCoordinator.moveFocus(to: .agentBuilder)
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
                defaultFocusOverride: initialFocusOverride
            ) { focusState, coordinator in
                content(focusState: focusState, coordinator: coordinator)
            }
        case .inline:
            inlineBody
        }
    }

    /// Initial focus the sheet path requests from `ConversationPresenter`.
    /// `nil` for post-commit (no input focus needed) and for voice-memo
    /// entry (keep the keyboard down while we kick off the recording -
    /// `stopVoiceMemoRecording`'s `restoreComposerFocusAfter: true` path
    /// brings the keyboard back up when the user finishes the take).
    /// `.agentBuilder` for the default composer entry.
    private var initialFocusOverride: MessagesViewInputFocus? {
        if viewModel.hasCommitted { return nil }
        if viewModel.entryMode == .voiceMemo { return nil }
        return .agentBuilder
    }

    /// On first appear, if the user opened the builder via the
    /// `AgentBuilderBar`'s waveform button, resolve mic permission and
    /// then start the recording. The recorder lives directly on
    /// `AgentBuilderViewModel` (not proxied through the inner conversation
    /// VM), so it's stable across the placeholder-to-real inner-VM swap
    /// and the only timing constraint is the permission prompt: a
    /// `record()` call before
    /// `AVAudioApplication.requestRecordPermission` resolves fires
    /// `audioRecorderDidFinishRecording(successfully: false)` and the
    /// recording UI flashes.
    private func startVoiceMemoIfNeeded() {
        guard viewModel.entryMode == .voiceMemo else { return }
        Task { @MainActor in
            let granted = await VoiceMemoRecorder.ensureRecordPermission()
            guard granted else { return }
            viewModel.startVoiceMemoRecording(restoreComposerFocusAfter: true)
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
        VStack(spacing: 0) {
            Group {
                if viewModel.hasCommitted {
                    Color.clear
                } else {
                    composerOrRemixCarousel(focusState: $inlineFocusState)
                }
            }
            // Hide the legal footer while Remix mode owns the screen --
            // the carousel + exit X already fill the bottom region, and
            // the Terms link doesn't make sense layered under the picker.
            if !viewModel.hasCommitted && !viewModel.isInRemixMode {
                inlineTermsFooter
            }
        }
        .onAppear {
            // Voice-memo entry skips the composer focus so the keyboard
            // doesn't pop up alongside the mic-permission prompt; the
            // body's main `.onAppear` kicks off the recording itself.
            guard viewModel.entryMode != .voiceMemo else { return }
            focusCoordinator.moveFocus(to: .agentBuilder)
        }
        .onChange(of: focusCoordinator.currentFocus) { _, newFocus in
            inlineFocusState = newFocus
        }
        .onChange(of: inlineFocusState) { _, newFocus in
            focusCoordinator.syncFocusState(newFocus)
        }
    }

    /// "Terms & Privacy Policy" link rendered under the inline composer
    /// so first-run users on the chats-list empty state still have an
    /// entry point to the legal page.
    private var inlineTermsFooter: some View {
        HStack(spacing: DesignConstants.Spacing.step4x) {
            Button {
                if let url = URL(string: "https://convos.org/terms-and-privacy") {
                    openURL(url, prefersInApp: true)
                }
            } label: {
                HStack(spacing: DesignConstants.Spacing.stepX) {
                    Text("Terms & Privacy Policy")
                    Image(systemName: "chevron.right")
                        .foregroundStyle(.colorTextTertiary)
                }
                .font(.caption)
                .foregroundStyle(.colorTextSecondary)
            }
        }
        .padding(.vertical, DesignConstants.Spacing.step4x)
        .padding(.horizontal, DesignConstants.Spacing.step6x)
        .dynamicTypeSize(...DynamicTypeSize.xLarge)
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
                        composerOrRemixCarousel(focusState: focusState)
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
                    // Voice-memo entry skips the composer focus so the
                    // keyboard doesn't pop up alongside the mic-permission
                    // prompt; the body's main `.onAppear` kicks off the
                    // recording itself.
                    guard viewModel.entryMode != .voiceMemo else { return }
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

    /// Swap point between the composer and the Remix carousel. While
    /// `isShowingRemixCarousel` is true the composer slides offscreen
    /// downward and the random-agent picker takes its place; tapping
    /// a card (sets `pickedRemixAgent`) or the X (clears
    /// `isInRemixMode`) flips this back to the composer.
    @ViewBuilder
    private func composerOrRemixCarousel(
        focusState: FocusState<MessagesViewInputFocus?>.Binding
    ) -> some View {
        ZStack {
            if viewModel.isShowingRemixCarousel {
                RemixAgentCarouselView(
                    viewModel: viewModel,
                    agents: RandomAgent.mocks
                )
                .transition(.move(edge: .bottom).combined(with: .opacity))
            } else {
                composerRect(focusState: focusState)
                    .transition(.move(edge: .bottom).combined(with: .opacity))
            }
        }
        .animation(.smooth(duration: 0.35), value: viewModel.isShowingRemixCarousel)
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
                    if dismissesOnCommit {
                        // Existing-conversation flow: fire the send + join
                        // (they survive teardown) and dismiss straight back to
                        // the chat the builder was triggered from. No in-sheet
                        // morph.
                        viewModel.commit(focusCoordinator: focusCoordinator)
                        dismiss()
                        return
                    }
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
            // Cap the card at its original height but let it shrink below
            // that when the keyboard constrains the available space. With a
            // fixed `height:` the card stayed 375 even when the keyboard
            // covered its lower content (media row + Make button); with a
            // plain `maxHeight: .infinity` it ballooned to fill the whole
            // iPad canvas. `maxHeight: composerHeight` gives both: 375 when
            // there's room, less when the keyboard pushes up (SwiftUI's
            // keyboard safe-area inset shrinks the proposed height and the
            // card follows).
            .frame(maxHeight: Constant.composerHeight)
            .padding(.horizontal, DesignConstants.Spacing.step4x)
            .padding(.top, DesignConstants.Spacing.step4x)

            // Hidden (not removed) when recording, so the layout below the
            // composer doesn't reflow when the user taps the voice-memo
            // button. Without this, the recording-controls' Spacer-centered
            // position would jump on entry.
            Text(composerHintText)
                .font(.caption)
                .foregroundStyle(.colorTextSecondary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: .infinity)
                .padding(.horizontal, DesignConstants.Spacing.step4x)
                .padding(.top, DesignConstants.Spacing.step2x)
                .padding(.bottom, DesignConstants.Spacing.step3x)
                .opacity(viewModel.isRecordingVoiceMemo ? 0 : 1)

            if viewModel.isRecordingVoiceMemo {
                Spacer(minLength: 0)
                recordingControls(focusState: focusState)
                    // Delay the appearance by `keyboardDismissDelay` so the
                    // keyboard dismissal animation triggered by the
                    // voice-memo tap (`focusState = nil`) finishes before
                    // the controls fade in.
                    .transition(.blurReplace.animation(
                        .easeInOut(duration: Constant.recordingControlsFadeDuration)
                            .delay(Constant.keyboardDismissDelay)
                    ))
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
        /// Cap for the composer card height. The card grows up to this
        /// (its original fixed size) and shrinks below it when the keyboard
        /// constrains the available space.
        static let composerHeight: CGFloat = 375.0
        /// iOS keyboard dismissal animation duration. Recording controls
        /// hold for this long before fading in so their position settles
        /// after the keyboard collapses rather than sliding through the
        /// transition.
        static let keyboardDismissDelay: TimeInterval = 0.25
        static let recordingControlsFadeDuration: TimeInterval = 0.25
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
