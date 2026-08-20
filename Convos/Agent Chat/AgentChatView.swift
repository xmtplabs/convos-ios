import ConvosCore
import SwiftUI

struct AgentChatView: View {
    let provider: ExternalAgentProvider
    let dependencies: AgentRelayDependencies
    let session: any SessionManagerProtocol
    @State private var viewModel: AgentChatViewModel
    @State private var selectedLink: AgentRelayLink?
    @State private var copyText: AgentConversationCopy?
    @State private var showingDisconnectConfirmation: Bool = false
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
            initialText: initialText
        ))
    }

    var body: some View {
        VStack(spacing: 0) {
            providerSwitcher
            transcript
            composer
        }
        .background(.colorBackgroundSurfaceless)
        .navigationTitle(provider.displayName)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar { toolbarContent }
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
        .confirmationDialog("Disconnect \(provider.displayName)?", isPresented: $showingDisconnectConfirmation) {
            let action = { disconnect() }
            Button("Disconnect", role: .destructive, action: action)
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Your agent transcript stays on this iPhone.")
        }
        .onAppear { AgentChatVisibility.isVisible = true }
        .onDisappear { AgentChatVisibility.isVisible = false }
    }

    @ViewBuilder
    private var providerSwitcher: some View {
        let providers: [ExternalAgentProvider] = viewModel.connectedProviders
        if providers.count > 1 {
            HStack {
                Text("Using \(provider.displayName)")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
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
                        emptyState
                    }
                    ForEach(viewModel.turns) { turn in
                        turnPair(turn)
                            .id(turn.id)
                    }
                }
                .padding(DesignConstants.Spacing.step4x)
            }
            .onChange(of: viewModel.turns) { _, turns in
                guard let last = turns.last else { return }
                withAnimation { proxy.scrollTo(last.id, anchor: .bottom) }
            }
        }
    }

    private var emptyState: some View {
        ContentUnavailableView(
            "Chat with \(provider.displayName)",
            systemImage: provider.symbolName,
            description: Text("Work happens on its own platform. Finished answers return here.")
        )
        .padding(.top, DesignConstants.Spacing.step8x)
    }

    private func turnPair(_ turn: AgentTurn) -> some View {
        VStack(spacing: DesignConstants.Spacing.step2x) {
            userBubble(turn.prompt)
            agentBubble(turn)
        }
    }

    private func userBubble(_ text: String) -> some View {
        HStack {
            Spacer(minLength: DesignConstants.Spacing.step8x)
            Text(text)
                .foregroundStyle(.colorTextPrimaryInverted)
                .padding(.horizontal, DesignConstants.Spacing.step3x)
                .padding(.vertical, DesignConstants.Spacing.step2x)
                .background(.colorBackgroundInverted, in: RoundedRectangle(cornerRadius: 20))
        }
    }

    @ViewBuilder
    private func agentBubble(_ turn: AgentTurn) -> some View {
        HStack(alignment: .top) {
            agentBubbleContent(turn)
            Spacer(minLength: DesignConstants.Spacing.step8x)
        }
    }

    @ViewBuilder
    private func agentBubbleContent(_ turn: AgentTurn) -> some View {
        switch turn.status {
        case .pending:
            pendingBubble(turn)
        case .completed:
            completedBubble(turn)
        case .failed:
            retryBubble(message: viewModel.userFacingError(for: turn), turn: turn)
        case .expired:
            retryBubble(message: "This request expired; send it again.", turn: turn)
        case .collectedElsewhere:
            retryBubble(message: "This reply was collected on another device.", turn: turn)
        }
    }

    private func pendingBubble(_ turn: AgentTurn) -> some View {
        TimelineView(.periodic(from: .now, by: 1)) { context in
            let elapsed: Int = max(0, Int(context.date.timeIntervalSince(turn.createdAt)))
            let stillWorking: Bool = viewModel.isStillWorking(turn, now: context.date)
            let status: String = pendingStatus(elapsed: elapsed, stillWorking: stillWorking)
            let systemImage: String = stillWorking ? "clock.badge.exclamationmark" : "ellipsis"
            VStack(alignment: .leading, spacing: DesignConstants.Spacing.step2x) {
                Label(status, systemImage: systemImage)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                if stillWorking {
                    let action = { viewModel.checkAgain(turn: turn) }
                    Button("Check again", action: action)
                        .buttonStyle(.bordered)
                        .tint(.green)
                }
            }
            .padding(DesignConstants.Spacing.step3x)
            .background(.colorBackgroundRaisedSecondary, in: RoundedRectangle(cornerRadius: 20))
        }
    }

    private func pendingStatus(elapsed: Int, stillWorking: Bool) -> String {
        guard !ConfigManager.shared.isAgentRelayPreviewBuild else {
            return AgentSetupCopy.previewBackendNote
        }
        guard stillWorking else { return "Working on its own platform - \(elapsed)s" }
        return "Still working after ten minutes; you will get a notification when it replies."
    }

    private func completedBubble(_ turn: AgentTurn) -> some View {
        VStack(alignment: .leading, spacing: DesignConstants.Spacing.step2x) {
            if let message = turn.resultMessage {
                Text(message)
                    .textSelection(.enabled)
            }
            let secureLinks: [AgentRelayLink] = turn.resultLinks.filter { $0.url.scheme?.lowercased() == "https" }
            ForEach(Array(secureLinks.enumerated()), id: \.offset) { _, link in
                linkButton(link)
            }
        }
        .padding(DesignConstants.Spacing.step3x)
        .background(.colorBackgroundRaisedSecondary, in: RoundedRectangle(cornerRadius: 20))
        .contextMenu {
            let action = { copyText = AgentConversationCopy(text: copyableText(for: turn)) }
            Button("Copy to convo", systemImage: "bubble.left.and.text.bubble.right", action: action)
        }
    }

    private func linkButton(_ link: AgentRelayLink) -> some View {
        let host: String = link.url.host(percentEncoded: false) ?? link.url.absoluteString
        let action = { selectedLink = link }
        return Button(action: action) {
            Label(host, systemImage: "arrow.up.right.square")
                .font(.subheadline)
                .lineLimit(1)
        }
        .buttonStyle(.plain)
        .foregroundStyle(.green)
    }

    private func retryBubble(message: String, turn: AgentTurn) -> some View {
        VStack(alignment: .leading, spacing: DesignConstants.Spacing.step2x) {
            Text(message)
                .foregroundStyle(.secondary)
            let action = { viewModel.retry(turn: turn) }
            Button("Try again", action: action)
                .buttonStyle(.bordered)
                .tint(.green)
        }
        .padding(DesignConstants.Spacing.step3x)
        .background(.colorBackgroundRaisedSecondary, in: RoundedRectangle(cornerRadius: 20))
    }

    private var composer: some View {
        VStack(spacing: DesignConstants.Spacing.stepX) {
            if let error = viewModel.errorMessage {
                Text(error)
                    .font(.footnote)
                    .foregroundStyle(.red)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            HStack(alignment: .bottom, spacing: DesignConstants.Spacing.step2x) {
                TextField("Message \(provider.displayName)", text: $viewModel.composerText, axis: .vertical)
                    .lineLimit(1 ... 6)
                    .textFieldStyle(.plain)
                    .padding(.horizontal, DesignConstants.Spacing.step3x)
                    .padding(.vertical, DesignConstants.Spacing.step2x)
                    .background(.colorBackgroundRaisedSecondary, in: RoundedRectangle(cornerRadius: 20))
                submitButton
            }
            Text(boundaryLabel)
                .font(.caption)
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(.horizontal, DesignConstants.Spacing.step4x)
        .padding(.top, DesignConstants.Spacing.step2x)
        .padding(.bottom, DesignConstants.Spacing.stepX)
        .background(.ultraThinMaterial)
    }

    private var submitButton: some View {
        let action = { viewModel.submit() }
        return Button(action: action) {
            Image(systemName: "arrow.up")
                .font(.body.weight(.bold))
                .frame(width: 36, height: 36)
        }
        .buttonStyle(.borderedProminent)
        .buttonBorderShape(.circle)
        .tint(.green)
        .disabled(!viewModel.canSubmit)
        .accessibilityLabel("Send to \(provider.displayName)")
    }

    private var boundaryLabel: String {
        switch provider {
        case .town:
            return "Messages go to your Town routine with the last 10 turns as context."
        case .tasklet:
            return "Messages go to your Tasklet agent with the last 10 turns as context."
        }
    }

    @ToolbarContentBuilder
    private var toolbarContent: some ToolbarContent {
        ToolbarItem(placement: .topBarTrailing) {
            Menu {
                let action = { showingDisconnectConfirmation = true }
                Button("Disconnect", systemImage: "link.badge.minus", role: .destructive, action: action)
            } label: {
                Image(systemName: "ellipsis.circle")
            }
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
}

private struct AgentConversationCopy: Identifiable {
    let id: UUID = UUID()
    let text: String
}

extension AgentRelayLink: @retroactive Identifiable {
    public var id: String { url.absoluteString }
}
