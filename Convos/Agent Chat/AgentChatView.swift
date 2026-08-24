import ConvosComposer
import ConvosCore
import SwiftUI

/// One provider's transcript. Reached from the Agents tab, from the App
/// Settings "Agents" row, and from a tapped agent notification.
///
/// The transcript speaks the app's own message vocabulary (`AgentChatBubbles`)
/// and the composer is the app's composer (`MessagesInputView` in the glass
/// capsule the conversation bar uses), so the only thing that distinguishes
/// this screen from a convo is what it honestly is: a chat with something that
/// works elsewhere and answers here.
struct AgentChatView: View {
    let provider: ExternalAgentProvider
    let dependencies: AgentRelayDependencies
    let session: any SessionManagerProtocol
    @State private var viewModel: AgentChatViewModel
    @State private var selectedLink: AgentRelayLink?
    @State private var copyText: AgentConversationCopy?
    @State private var showingDisconnectConfirmation: Bool = false
    @State private var showingClearHistoryConfirmation: Bool = false
    @FocusState private var composerFocus: MessagesViewInputFocus?
    @Environment(\.dismiss) private var dismiss: DismissAction

    init(
        provider: ExternalAgentProvider,
        dependencies: AgentRelayDependencies,
        session: any SessionManagerProtocol,
        initialText: String = ""
    ) {
        self.provider = provider
        self.dependencies = dependencies
        self.session = session
        _viewModel = State(initialValue: AgentChatViewModel(
            provider: provider,
            dependencies: dependencies,
            session: session,
            initialText: initialText
        ))
    }

    var body: some View {
        navigation(dialogs(sheets(chatStack)))
    }

    private var chatStack: some View {
        VStack(spacing: 0) {
            providerSwitcher
            transcript
            composer
        }
        .background(.colorBackgroundSurfaceless)
    }

    /// The bar carries its own background on purpose. `AgentsHomeView` hides
    /// the toolbar background for the tab root it owns, and without this the
    /// pushed transcript inherits a bare bar: messages scroll up behind the
    /// title unblurred and read as a second, ghost title. The tab bar goes for
    /// the same reason a pushed conversation hides it - a screen with a
    /// composer owns its own bottom edge.
    private func navigation(_ content: some View) -> some View {
        content
            .navigationTitle(provider.displayName)
            .navigationBarTitleDisplayMode(.inline)
            .toolbarBackground(.visible, for: .navigationBar)
            .toolbar(.hidden, for: .tabBar)
            .toolbar { toolbarContent }
            .onAppear { AgentChatVisibility.visibleProvider = provider }
            .onDisappear {
                guard AgentChatVisibility.visibleProvider == provider else { return }
                AgentChatVisibility.visibleProvider = nil
            }
    }

    private func sheets(_ content: some View) -> some View {
        content
            .sheet(item: $selectedLink) { link in
                AgentLinkConfirmationView(url: link.url)
                    .presentationDetents([.medium])
            }
            .sheet(item: $copyText) { copy in
                ConversationPickerView(
                    mode: .stageDraft(text: copy.text),
                    session: session,
                    draftStore: PendingComposerDraftStore(environment: ConfigManager.shared.currentEnvironment),
                    onPick: { dismiss() }
                )
            }
    }

    private func dialogs(_ content: some View) -> some View {
        content
            .agentClearHistoryDialog(
                isPresented: $showingClearHistoryConfirmation,
                providerName: provider.displayName,
                onClear: { viewModel.clearHistory() }
            )
            .confirmationDialog("Disconnect \(provider.displayName)?", isPresented: $showingDisconnectConfirmation) {
                let action = { disconnect() }
                Button("Disconnect", role: .destructive, action: action)
                Button("Cancel", role: .cancel) {}
            } message: {
                Text("Your agent chats stay on this iPhone.")
            }
    }

    @ViewBuilder
    private var providerSwitcher: some View {
        let providers: [ExternalAgentProvider] = viewModel.connectedProviders
        if providers.count > 1 {
            HStack {
                Text("Using \(provider.displayName)")
                    .font(.footnote)
                    .foregroundStyle(.colorTextSecondary)
                Spacer()
                Menu("Switch") {
                    ForEach(providers) { candidate in
                        Button(candidate.displayName) { switchProvider(candidate) }
                    }
                }
            }
            .padding(.horizontal, DesignConstants.Spacing.step4x)
            .padding(.vertical, DesignConstants.Spacing.step2x)
        }
    }

    private var transcript: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(spacing: DesignConstants.Spacing.step3x) {
                    if viewModel.turns.isEmpty {
                        AgentTranscriptEmptyState(provider: provider)
                    } else {
                        AgentTranscriptNote(text: AgentSetupCopy.contextBoundary(for: provider))
                    }
                    ForEach(viewModel.turns) { turn in
                        turnPair(turn)
                            .id(turn.id)
                    }
                }
                .padding(DesignConstants.Spacing.step4x)
            }
            .scrollDismissesKeyboard(.interactively)
            .onChange(of: viewModel.turns) { _, turns in
                guard let last = turns.last else { return }
                withAnimation { proxy.scrollTo(last.id, anchor: .bottom) }
            }
        }
    }

    private func turnPair(_ turn: AgentTurn) -> some View {
        VStack(spacing: DesignConstants.Spacing.step2x) {
            AgentUserBubble(text: turn.prompt)
            agentBubble(turn)
        }
        .animation(.snappy(duration: 0.25), value: turn.status)
    }

    @ViewBuilder
    private func agentBubble(_ turn: AgentTurn) -> some View {
        switch turn.status {
        case .pending:
            pendingBubble(turn)
        case .completed:
            completedBubble(turn)
        case .failed:
            retryBubble(message: viewModel.userFacingError(for: turn), symbol: "exclamationmark.triangle.fill", turn: turn)
        case .expired:
            retryBubble(
                message: AgentSetupCopy.errorMessage(.expired, provider: turn.provider),
                symbol: "hourglass",
                turn: turn
            )
        case .collectedElsewhere:
            retryBubble(
                message: AgentSetupCopy.collectedElsewhereNote,
                symbol: "iphone.gen3",
                glyphTint: .colorTextSecondary,
                turn: turn
            )
        case .superseded:
            supersededBubble(turn)
        }
    }

    /// The elapsed seconds are real and worth showing: these turns legitimately
    /// run for minutes, and the count is the only honest answer to "is anything
    /// happening". The bubble owns its own clock so the rest of the transcript
    /// is not redrawn each second.
    private func pendingBubble(_ turn: AgentTurn) -> some View {
        let isPreviewBackend: Bool = ConfigManager.shared.isAgentRelayPreviewBackend
        let working: String = isPreviewBackend ? AgentSetupCopy.previewBackendNote : AgentSetupCopy.workingNote
        let past: String = isPreviewBackend ? AgentSetupCopy.previewBackendNote : AgentSetupCopy.stillWorkingNote
        let checkAction: () -> Void = { viewModel.checkAgain(turn: turn) }
        return AgentPendingBubble(
            startedAt: turn.createdAt,
            deadline: viewModel.watchDeadline(for: turn),
            workingMessage: working,
            pastDeadlineMessage: past,
            onCheckAgain: checkAction
        )
    }

    private func supersededBubble(_ turn: AgentTurn) -> some View {
        AgentStatusBubble(
            systemImage: "clock.arrow.circlepath",
            message: AgentSetupCopy.stoppedWaitingNote
        ) {
            let action = { viewModel.checkAgain(turn: turn) }
            AgentBubbleAction(
                title: "Check again",
                accessibilityIdentifier: "agent-turn-check-again",
                action: action
            )
        }
    }

    private func completedBubble(_ turn: AgentTurn) -> some View {
        let links: [AgentRelayLink] = turn.resultLinks.filter { $0.url.scheme?.lowercased() == "https" }
        let openLink = { (link: AgentRelayLink) in selectedLink = link }
        return AgentReplyBubble(message: turn.resultMessage, links: links, onOpenLink: openLink)
            .contextMenu {
                let action = { copyText = AgentConversationCopy(text: copyableText(for: turn)) }
                Button("Copy to convo", systemImage: "bubble.left.and.text.bubble.right", action: action)
            }
    }

    private func retryBubble(
        message: String,
        symbol: String,
        glyphTint: Color = .colorCaution,
        turn: AgentTurn
    ) -> some View {
        AgentStatusBubble(systemImage: symbol, message: message, glyphTint: glyphTint) {
            let action = { viewModel.retry(turn: turn) }
            AgentBubbleAction(
                title: "Try again",
                accessibilityIdentifier: "agent-turn-try-again",
                action: action
            )
        }
    }

    /// The app's composer, in the app's glass capsule. The boundary note that
    /// used to sit under it now heads the transcript, so nothing competes with
    /// the field the user is typing in.
    private var composer: some View {
        VStack(spacing: DesignConstants.Spacing.step2x) {
            composerNotice
            inputCapsule
        }
        .padding(.horizontal, DesignConstants.Spacing.step4x)
        .padding(.top, DesignConstants.Spacing.step2x)
        .padding(.bottom, DesignConstants.Spacing.step4x)
    }

    @ViewBuilder
    private var composerNotice: some View {
        if let error = viewModel.errorMessage {
            let dismissNotice = { viewModel.errorMessage = nil }
            AgentComposerNotice(message: error, onDismiss: dismissNotice)
                .transition(.opacity)
        }
    }

    private var inputCapsule: some View {
        let sendAction: () -> Void = { viewModel.submit() }
        return MessagesInputView(
            displayName: .constant(""),
            emptyDisplayNamePlaceholder: "",
            messagePlaceholder: "Message \(provider.displayName)",
            messageText: $viewModel.composerText,
            pendingInviteConvoName: .constant(""),
            pendingInviteImage: .constant(nil),
            sendButtonEnabled: viewModel.canSubmit,
            focusState: $composerFocus,
            messagesTextFieldEnabled: true,
            onSendMessage: sendAction,
            onClearInvite: {},
            onStopWaitingWhenEmpty: composerStopWaitingAction,
            fileAttachmentPreview: { _ in EmptyView() },
            agentShareChip: { EmptyView() },
            attachmentsButton: { EmptyView() }
        )
        .fixedSize(horizontal: false, vertical: true)
        .clipShape(.rect(cornerRadius: Constant.composerCornerRadius))
        .glassEffect(.regular.interactive(), in: .rect(cornerRadius: Constant.composerCornerRadius))
    }

    private var composerStopWaitingAction: (() -> Void)? {
        guard let turn: AgentTurn = viewModel.inFlightTurn else { return nil }
        let action: () -> Void = { viewModel.stopWaiting(turn: turn) }
        return action
    }

    @ToolbarContentBuilder
    private var toolbarContent: some ToolbarContent {
        ToolbarItem(placement: .topBarTrailing) {
            Menu {
                let clearAction = { showingClearHistoryConfirmation = true }
                Button("Clear history", systemImage: "trash", role: .destructive, action: clearAction)
                    .disabled(!viewModel.hasClearableHistory)
                    .accessibilityIdentifier("agent-clear-history")
                let disconnectAction = { showingDisconnectConfirmation = true }
                Button("Disconnect", systemImage: "link.badge.minus", role: .destructive, action: disconnectAction)
            } label: {
                Image(systemName: "ellipsis")
            }
            .accessibilityLabel("More")
        }
    }

    private func copyableText(for turn: AgentTurn) -> String {
        var parts: [String] = []
        if let message = turn.resultMessage {
            parts.append(message)
        }
        let links: [String] = turn.resultLinks.compactMap { link in
            guard link.url.scheme?.lowercased() == "https" else { return nil }
            let host: String = link.url.host(percentEncoded: false) ?? link.url.absoluteString
            return "\(host): \(link.url.absoluteString)"
        }
        if !links.isEmpty {
            parts.append(links.joined(separator: "\n"))
        }
        return parts.joined(separator: "\n\n")
    }

    private func disconnect() {
        do {
            try dependencies.connectionStore.delete(provider: provider)
            if dependencies.connectionStore.activeProvider == provider {
                dependencies.connectionStore.activeProvider = nil
            }
            dismiss()
        } catch {
            viewModel.errorMessage = AgentSetupCopy.errorMessage(error, provider: provider)
        }
    }

    private func switchProvider(_ candidate: ExternalAgentProvider) {
        dependencies.connectionStore.activeProvider = candidate
        dismiss()
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
            NotificationCenter.default.post(
                name: .agentRelayNotificationTapped,
                object: nil,
                userInfo: ["provider": candidate.rawValue]
            )
        }
    }

    private enum Constant {
        /// The conversation composer's capsule radius, so the two bars are the
        /// same shape.
        static let composerCornerRadius: CGFloat = 26.0
    }
}

private struct AgentConversationCopy: Identifiable {
    let id: UUID = UUID()
    let text: String
}

extension AgentRelayLink: @retroactive Identifiable {
    public var id: String { url.absoluteString }
}
