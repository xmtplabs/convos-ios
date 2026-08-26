import ConvosComposer
import ConvosCore
import ConvosCoreiOS
import ConvosMetrics
import SwiftUI

struct DocRootView: View {
    @Bindable private var conversationsViewModel: ConversationsViewModel
    private let profileSettingsViewModel: ProfileSettingsViewModel
    private let coreActions: any CoreActions
    @State private var viewModel: DocExperienceViewModel
    @State private var navigationPath: [DocStatus]
    @State private var isPresentingSettings: Bool = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion: Bool

    init(
        conversationsViewModel: ConversationsViewModel,
        profileSettingsViewModel: ProfileSettingsViewModel,
        coreActions: any CoreActions
    ) {
        self.conversationsViewModel = conversationsViewModel
        self.profileSettingsViewModel = profileSettingsViewModel
        self.coreActions = coreActions
        let model = DocExperienceViewModel(
            session: conversationsViewModel.session,
            coreActions: coreActions
        )
        _viewModel = State(initialValue: model)
        _navigationPath = State(initialValue: model.previewInitialDoc.map { [$0] } ?? [])
    }

    var body: some View {
        Group {
            if viewModel.previewStage == .transcript {
                DocTranscriptChromePreview()
            } else if viewModel.previewStage == .welcome ||
                (viewModel.previewStage == nil && !viewModel.hasCompletedWelcome) {
                DocWelcomeView {
                    if reduceMotion {
                        viewModel.completeWelcome()
                    } else {
                        withAnimation(.easeInOut(duration: 0.25)) {
                            viewModel.completeWelcome()
                        }
                    }
                }
            } else {
                NavigationStack(path: $navigationPath) {
                    DocHomeView(
                        viewModel: viewModel,
                        onSettings: { isPresentingSettings = true },
                        onConnectGoogle: viewModel.connectGoogleDocs
                    )
                    .navigationDestination(for: DocStatus.self) { doc in
                        DocRoomView(viewModel: viewModel, initialDoc: doc)
                    }
                }
            }
        }
        .tint(.colorLava)
        .task {
            await viewModel.startAgentIfNeeded()
        }
        .task(id: viewModel.agentBindingKey) {
            await viewModel.synchronizeAgentDm()
        }
        .onChange(of: viewModel.dmViewModel?.conversation.id) { _, dmId in
            guard dmId != nil else { return }
            viewModel.showGoogleConnectIfNeeded()
        }
        .sheet(item: $viewModel.presentedDraftItem) { item in
            DocDraftSheet(
                item: item,
                startsEdited: [.draftSheet, .finishDraft].contains(viewModel.previewStage),
                isEnabled: viewModel.isDmReadyForDisplay && viewModel.sendState(for: item) == nil
            ) { answer in
                viewModel.sendAnswer(answer, for: item)
            }
        }
        .sheet(isPresented: $isPresentingSettings) {
            AppSettingsView(
                viewModel: conversationsViewModel.appSettingsViewModel,
                profileSettingsViewModel: profileSettingsViewModel,
                session: conversationsViewModel.session,
                coreActions: coreActions,
                onDeleteAllData: conversationsViewModel.deleteAllData
            )
        }
        .sheet(isPresented: $viewModel.isPresentingHistory) {
            if let conversationViewModel = viewModel.conversationViewModel {
                NewConversationView(
                    viewModel: conversationViewModel,
                    profileSettingsViewModel: profileSettingsViewModel,
                    initialAgentDmInboxId: viewModel.agentInboxId
                )
            } else {
                ContentUnavailableView(
                    "History is preparing",
                    systemImage: "clock.arrow.circlepath",
                    description: Text("Doc's private chat will appear here when it is ready.")
                )
            }
        }
        .shareSheet(
            isPresented: $viewModel.isPresentingShareNumber,
            items: viewModel.shareText.map { [$0] } ?? [],
            applicationActivities: viewModel.sharedDocNumber.map {
                [DocCopyNumberActivity(number: $0)]
            }
        )
        .shareSheet(
            isPresented: $viewModel.isPresentingShareDoc,
            items: viewModel.sharedDocText.map { [$0] } ?? []
        )
    }
}

private struct DocTranscriptChromePreview: View {
    @State private var conversationViewModel: ConversationViewModel = makeDocTranscriptPreviewViewModel()
    @State private var focusCoordinator: FocusCoordinator = FocusCoordinator(horizontalSizeClass: .compact)
    @State private var profileSettingsViewModel: ProfileSettingsViewModel = .shared
    @State private var sidebarColumnWidth: CGFloat = 0

    var body: some View {
        ConversationPresenter(
            viewModel: conversationViewModel,
            focusCoordinator: focusCoordinator,
            insetsTopSafeArea: true,
            sidebarColumnWidth: $sidebarColumnWidth
        ) { focusBinding, coordinator in
            ConversationView(
                viewModel: conversationViewModel,
                profileSettingsViewModel: profileSettingsViewModel,
                focusState: focusBinding,
                focusCoordinator: coordinator,
                onScanInviteCode: {},
                onDeleteConversation: {},
                messagesTopBarTrailingItem: .share,
                messagesTopBarTrailingItemEnabled: false,
                messagesTextFieldEnabled: false,
                bottomBarContent: { EmptyView() }
            )
        }
        .accessibilityIdentifier("doc-transcript-preview")
    }
}

@MainActor
private func makeDocTranscriptPreviewViewModel() -> ConversationViewModel {
    let conversation = Conversation.mock(
        name: "Preview group",
        members: [
            .mock(isCurrentUser: true),
            .mock(name: "Sara"),
            .mock(name: "Doc", isAgent: true, agentVerification: .verified(.convos)),
        ]
    )
    return ConversationViewModel(
        conversation: conversation,
        session: MockInboxesService(),
        messagingService: MockMessagingService()
    )
}

private struct DocWelcomeView: View {
    let onContinue: () -> Void

    var body: some View {
        GeometryReader { proxy in
            ScrollView {
                VStack(spacing: 0) {
                    Spacer(minLength: DesignConstants.Spacing.step8x)
                    Image(systemName: "doc.text.fill")
                        .font(.system(size: 56.0, weight: .medium))
                        .foregroundStyle(.colorLava)
                        .frame(width: 96.0, height: 96.0)
                        .background(.colorFillMinimal, in: RoundedRectangle(cornerRadius: DesignConstants.CornerRadius.large))
                        .accessibilityHidden(true)

                    Text("Doc")
                        .font(.largeTitle.bold())
                        .foregroundStyle(.colorTextPrimary)
                        .padding(.top, DesignConstants.Spacing.step6x)

                    Text("Doc turns your group's iMessage thread into a doc that stays up to date")
                        .font(.title3)
                        .foregroundStyle(.colorTextSecondary)
                        .multilineTextAlignment(.center)
                        .padding(.top, DesignConstants.Spacing.step3x)
                        .padding(.horizontal, DesignConstants.Spacing.step8x)

                    Spacer(minLength: DesignConstants.Spacing.step8x)

                    Button("Continue", action: onContinue)
                        .convosButtonStyle(.rounded(fullWidth: true, backgroundColor: .colorLava))
                        .frame(maxWidth: .infinity)
                        .frame(minHeight: 44.0)
                        .padding(.horizontal, DesignConstants.Spacing.step5x)
                        .padding(.bottom, DesignConstants.Spacing.step6x)
                        .accessibilityIdentifier("doc-welcome-continue")
                }
                .frame(minHeight: proxy.size.height)
            }
        }
        .background(Color.colorBackgroundSurfaceless)
        .accessibilityIdentifier("doc-welcome")
    }
}

private struct DocHomeView: View {
    @Bindable var viewModel: DocExperienceViewModel
    let onSettings: () -> Void
    let onConnectGoogle: () -> Void
    @Environment(\.accessibilityReduceMotion) private var reduceMotion: Bool

    var body: some View {
        List {
            if viewModel.shouldShowGoogleConnectCard {
                DocGoogleConnectCard(
                    isConnecting: viewModel.isConnectingGoogleDocs,
                    errorMessage: viewModel.googleConnectErrorMessage,
                    onConnect: onConnectGoogle
                )
                    .docHomeRow()
            }

            if viewModel.isShowingNotDocAgentNotice {
                DocWrongAgentNotice(onDismiss: viewModel.dismissNotDocAgentNotice)
                    .docHomeRow()
            }

            if let startupError = viewModel.agentStartupErrorMessage {
                DocAgentStartupErrorCard(
                    message: startupError,
                    onRetry: viewModel.retryAgentStartup
                )
                .docHomeRow()
            }

            if !viewModel.docs.isEmpty {
                DocContributionLine(number: viewModel.contributionLine, onShare: viewModel.presentContributionLine)
                    .docHomeRow()
            }

            if !viewModel.visiblePendingItems.isEmpty {
                DocForYouSection(
                    viewModel: viewModel,
                    items: viewModel.visiblePendingItems,
                    composerScope: .home
                )
            }

            if viewModel.docs.isEmpty {
                DocEmptyState(isPreparing: viewModel.isPreparingAgent)
                    .docHomeRow()
            } else {
                ForEach(viewModel.docs) { doc in
                    DocStatusCard(
                        doc: doc,
                        onShareNumber: { viewModel.presentShareNumber(for: doc) },
                        onShareDoc: {
                            Task { await viewModel.shareDoc(doc) }
                        }
                    )
                    .docHomeRow()
                    .transition(DocMotion.docArrival(reduceMotion: reduceMotion))
                }
            }

            if viewModel.docs.isEmpty {
                DocContributionLine(number: viewModel.contributionLine, onShare: viewModel.presentContributionLine)
                    .docHomeRow()
            }
        }
        .listStyle(.plain)
        .scrollDismissesKeyboard(.interactively)
        .scrollContentBackground(.hidden)
        .animation(
            DocMotion.arrival(reduceMotion: reduceMotion),
            value: viewModel.docs.map(\.id)
        )
        .background(Color.colorBackgroundSurfaceless)
        .navigationTitle("Doc")
        .navigationBarTitleDisplayMode(.large)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button(action: onSettings) {
                    Image(systemName: "gearshape")
                }
                .frame(minWidth: 44.0, minHeight: 44.0)
                .accessibilityLabel("Settings")
                .accessibilityIdentifier("doc-settings")
            }
        }
        .safeAreaInset(edge: .bottom, spacing: 0) {
            DocComposerBar(
                viewModel: viewModel,
                scope: .home,
                messagePlaceholder: "Add screenshots or tell Doc…",
                showsReadingProgress: true
            )
        }
        .accessibilityIdentifier("doc-home")
    }
}

private struct DocWrongAgentNotice: View {
    let onDismiss: () -> Void

    var body: some View {
        HStack(alignment: .top, spacing: DesignConstants.Spacing.step3x) {
            Image(systemName: "info.circle")
                .foregroundStyle(.secondary)
                .accessibilityHidden(true)
            Text("This agent isn't running the Doc preview. Reset it in Settings ▸ Debug.")
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, alignment: .leading)
            Button(action: onDismiss) {
                Image(systemName: "xmark")
                    .font(.footnote.weight(.semibold))
            }
            .frame(minWidth: 44.0, minHeight: 44.0)
            .contentShape(.rect)
            .accessibilityLabel("Dismiss")
        }
        .padding(DesignConstants.Spacing.step3x)
        .background(.colorFillMinimal, in: RoundedRectangle(cornerRadius: DesignConstants.CornerRadius.medium))
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("doc-wrong-agent-notice")
    }
}

private extension View {
    func docHomeRow() -> some View {
        listRowInsets(
            EdgeInsets(
                top: DesignConstants.Spacing.step2x,
                leading: DesignConstants.Spacing.step4x,
                bottom: DesignConstants.Spacing.step2x,
                trailing: DesignConstants.Spacing.step4x
            )
        )
        .listRowBackground(Color.clear)
        .listRowSeparator(.hidden)
    }
}

private struct DocGoogleConnectCard: View {
    let isConnecting: Bool
    let errorMessage: String?
    let onConnect: () -> Void
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize: DynamicTypeSize

    var body: some View {
        Group {
            if dynamicTypeSize.isAccessibilitySize {
                VStack(alignment: .leading, spacing: DesignConstants.Spacing.step3x) {
                    label
                    connectButton
                    errorLabel
                }
            } else {
                HStack(alignment: .center, spacing: DesignConstants.Spacing.step3x) {
                    label
                    connectButton
                }
                errorLabel
            }
        }
        .padding(DesignConstants.Spacing.step3x)
        .background(.colorBackgroundRaisedSecondary, in: RoundedRectangle(cornerRadius: DesignConstants.CornerRadius.medium))
        .accessibilityIdentifier("doc-google-connect-card")
    }

    private var label: some View {
        HStack(alignment: .center, spacing: DesignConstants.Spacing.step3x) {
            Image(systemName: "doc.text")
                .font(.title3)
                .foregroundStyle(.colorLava)
                .frame(width: 32.0, height: 32.0)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: DesignConstants.Spacing.step2x) {
                Text("Connect Google Docs")
                    .font(.subheadline.weight(.semibold))
                Text("Doc needs it to write your docs")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private var connectButton: some View {
        Button(action: onConnect) {
            if isConnecting {
                ProgressView().frame(minWidth: 60.0)
            } else {
                Text(errorMessage == nil ? "Connect" : "Retry")
            }
        }
            .convosButtonStyle(.outlineCapsule(fullWidth: false))
            .controlSize(.regular)
            .frame(minHeight: 44.0)
            .disabled(isConnecting)
    }

    @ViewBuilder
    private var errorLabel: some View {
        if let errorMessage {
            Text(errorMessage)
                .font(.footnote)
                .foregroundStyle(.red)
                .fixedSize(horizontal: false, vertical: true)
                .accessibilityIdentifier("doc-google-connect-error")
        }
    }
}

private struct DocContributionLine: View {
    let number: String
    let onShare: () -> Void

    var body: some View {
        HStack(spacing: DesignConstants.Spacing.step3x) {
            Image(systemName: "message.badge.waveform.fill")
                .foregroundStyle(.colorLava)
                .frame(width: 32.0, height: 32.0)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: DesignConstants.Spacing.stepX) {
                Text("I go by @doc")
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(.colorTextPrimary)
                Text(docDisplayPhoneNumber(number))
                    .font(.subheadline.monospacedDigit())
                    .foregroundStyle(.colorTextSecondary)
                    .textSelection(.enabled)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            Button("Share", systemImage: "square.and.arrow.up", action: onShare)
                .convosButtonStyle(.outlineCapsule(fullWidth: false))
                .labelStyle(.iconOnly)
                .frame(minWidth: 44.0, minHeight: 44.0)
                .accessibilityLabel("Share Doc's number")
        }
        .padding(DesignConstants.Spacing.step3x)
        .background(Color.colorFillMinimal, in: RoundedRectangle(cornerRadius: DesignConstants.CornerRadius.medium))
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("doc-contribution-line")
    }
}

private struct DocEmptyState: View {
    let isPreparing: Bool

    var body: some View {
        VStack(spacing: DesignConstants.Spacing.step4x) {
            Spacer(minLength: 72.0)
            Image(systemName: "photo.on.rectangle.angled")
                .font(.system(size: 42.0, weight: .medium))
                .foregroundStyle(.colorLava)
                .accessibilityHidden(true)
            Text("Screenshot your group's thread and send it here")
                .font(.title2.weight(.semibold))
                .foregroundStyle(.colorTextPrimary)
                .multilineTextAlignment(.center)
            Text(emptyStateDescription)
                .font(.body)
                .foregroundStyle(.colorTextSecondary)
                .multilineTextAlignment(.center)
            Spacer(minLength: 72.0)
        }
        .frame(maxWidth: 420.0)
        .padding(.horizontal, DesignConstants.Spacing.step5x)
        .frame(maxWidth: .infinity)
        .accessibilityIdentifier("doc-empty-state")
    }

    private var emptyStateDescription: String {
        if isPreparing {
            return "I'm getting ready. Share screenshots here to start, or add @doc to the group directly."
        }
        return "Share screenshots here to start, or add @doc to the group directly. Screenshots first works best: share the doc, then add me once it looks right."
    }
}

private struct DocAgentStartupErrorCard: View {
    let message: String
    let onRetry: () -> Void

    var body: some View {
        HStack(alignment: .center, spacing: DesignConstants.Spacing.step3x) {
            Image(systemName: "exclamationmark.circle")
                .foregroundStyle(.colorTextSecondary)
                .accessibilityHidden(true)
            Text(message)
                .font(.subheadline)
                .foregroundStyle(.colorTextSecondary)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 0)
            Button("Try again", action: onRetry)
                .convosButtonStyle(.outlineCapsule(fullWidth: false))
                .frame(minHeight: 44.0)
        }
        .padding(DesignConstants.Spacing.step4x)
        .background(
            Color.colorFillMinimal,
            in: RoundedRectangle(cornerRadius: DesignConstants.CornerRadius.medium)
        )
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("doc-agent-startup-error")
    }
}

private struct DocStatusCard: View {
    let doc: DocStatus
    let onShareNumber: () -> Void
    let onShareDoc: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: DesignConstants.Spacing.step3x) {
            NavigationLink(value: doc) {
                VStack(alignment: .leading, spacing: DesignConstants.Spacing.step3x) {
                    HStack(alignment: .firstTextBaseline, spacing: DesignConstants.Spacing.step2x) {
                        Circle()
                            .fill(freshnessColor)
                            .frame(width: 9.0, height: 9.0)
                            .accessibilityLabel(freshnessLabel)
                        Text(doc.name)
                            .font(.headline)
                            .foregroundStyle(.colorTextPrimary)
                            .frame(maxWidth: .infinity, alignment: .leading)
                        Image(systemName: "chevron.right")
                            .font(.footnote.weight(.semibold))
                            .foregroundStyle(.tertiary)
                            .accessibilityHidden(true)
                    }

                    Text("\(doc.lastChange.who) \(doc.lastChange.what) · \(compactRelativeTime(from: doc.lastChange.at))")
                        .font(.subheadline)
                        .foregroundStyle(.colorTextSecondary)
                        .lineLimit(2)
                }
                .contentShape(.rect)
            }
            .buttonStyle(.plain)

            ViewThatFits(in: .horizontal) {
                HStack(spacing: DesignConstants.Spacing.step2x) {
                    bindingPill
                    metadataPills
                }

                VStack(alignment: .leading, spacing: DesignConstants.Spacing.step2x) {
                    bindingPill
                    metadataPills
                }
            }

            if doc.shared != true {
                Button("Share doc", systemImage: "square.and.arrow.up", action: onShareDoc)
                    .convosButtonStyle(.outlineCapsule(fullWidth: false))
                    .frame(minHeight: 44.0)
                    .accessibilityIdentifier("doc-share-document")
            }
        }
        .padding(DesignConstants.Spacing.step4x)
        .background(.colorBackgroundRaisedSecondary, in: RoundedRectangle(cornerRadius: DesignConstants.CornerRadius.medium))
        .contentShape(.rect)
        .accessibilityIdentifier("doc-card-\(doc.id)")
    }

    @ViewBuilder
    private var metadataPills: some View {
        if let dates = doc.dates {
            metadataPill(systemImage: "calendar", text: dates)
        }
        if let people = doc.people {
            metadataPill(systemImage: "person.2", text: "\(people)")
        }
    }

    @ViewBuilder
    private var bindingPill: some View {
        if doc.binding.state == .live {
            Label("In the group", systemImage: "checkmark.circle.fill")
                .font(.caption.weight(.semibold))
                .foregroundStyle(.green)
                .padding(.horizontal, DesignConstants.Spacing.step3x)
                .frame(minHeight: 28.0)
                .background(Color.green.opacity(0.12), in: Capsule())
        } else {
            Button(action: onShareNumber) {
                Label("Share Doc's number", systemImage: "person.badge.plus")
            }
            .convosButtonStyle(.outlineCapsule(fullWidth: false))
            .frame(minHeight: 44.0)
            .accessibilityIdentifier("doc-share-number")
        }
    }

    private func metadataPill(systemImage: String, text: String) -> some View {
        Label(text, systemImage: systemImage)
            .font(.caption.weight(.medium))
            .foregroundStyle(.colorTextSecondary)
            .padding(.horizontal, DesignConstants.Spacing.step3x)
            .frame(minHeight: 28.0)
            .background(.colorFillMinimal, in: Capsule())
    }

    private var freshnessColor: Color {
        let age = Date().timeIntervalSince(doc.updatedAt)
        if age < 24 * 60 * 60 { return .colorLava }
        return Color(uiColor: .systemGray3)
    }

    private var freshnessLabel: String {
        let age = Date().timeIntervalSince(doc.updatedAt)
        if age < 60 * 60 { return "Updated recently" }
        if age < 24 * 60 * 60 { return "Updated today" }
        return "Not recently updated"
    }

    private func compactRelativeTime(from date: Date) -> String {
        let seconds = max(0, Int(Date().timeIntervalSince(date)))
        if seconds < 60 { return "now" }
        if seconds < 60 * 60 { return "\(seconds / 60)m" }
        if seconds < 24 * 60 * 60 { return "\(seconds / 3_600)h" }
        return "\(seconds / 86_400)d"
    }
}
