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
        rootContent
        .tint(.colorLava)
        .animation(firstRunAnimation, value: viewModel.firstRunStep)
        .task(id: viewModel.hasCompletedWelcome) {
            await viewModel.startAgentIfNeeded()
        }
        .task(id: viewModel.agentBindingKey) {
            await viewModel.synchronizeAgentDm()
        }
        .sheet(item: $viewModel.presentedDraftItem) { item in
            DocDraftSheet(
                item: item,
                startsEdited: [.draftSheet, .finishDraft].contains(viewModel.previewStage),
                isEnabled: viewModel.isDmReadyForDisplay && viewModel.sendState(for: item) == nil,
                onChatAboutThis: {
                    viewModel.prefillDraftFeedback(
                        for: item,
                        in: viewModel.presentedDraftComposerScope ?? .home
                    )
                },
                onAnswer: { answer in
                    viewModel.sendAnswer(answer, for: item)
                }
            )
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
            if let conversationViewModel = viewModel.conversationViewModel,
               let agentInboxId = viewModel.agentInboxId {
                NewConversationView(
                    viewModel: conversationViewModel,
                    profileSettingsViewModel: profileSettingsViewModel,
                    initialAgentDmInboxId: agentInboxId
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

    @ViewBuilder
    private var rootContent: some View {
        if viewModel.previewStage == .transcript {
            DocTranscriptChromePreview()
        } else {
            switch viewModel.firstRunStep {
            case .welcome:
                DocWelcomeView(onContinue: viewModel.completeWelcome)
            case .verify:
                DocVerifyFirstRunView(
                    flowState: viewModel.verificationFlowState,
                    verification: viewModel.verificationControl,
                    rememberedNumber: viewModel.rememberedVerificationNumber,
                    startupErrorMessage: viewModel.agentStartupErrorMessage,
                    transportErrorMessage: viewModel.verificationTransportErrorMessage,
                    onRequest: viewModel.requestPhoneVerification,
                    onSubmit: viewModel.submitPhoneVerification,
                    onShowFallback: viewModel.showPhoneVerificationFallback,
                    onEditNumber: viewModel.editPhoneNumber,
                    onRenew: viewModel.renewVerification,
                    onRetryStartup: viewModel.retryAgentStartup
                )
            case .sayHello:
                DocVerificationHelloView(
                    lineNumber: viewModel.verificationLineNumber,
                    onComplete: viewModel.completeVerificationHello
                )
            case .connectGoogle:
                DocGoogleFirstRunView(
                    isConnecting: viewModel.isConnectingGoogleDocs,
                    isWaitingForApproval: viewModel.isWaitingForGoogleApproval,
                    canConnect: viewModel.canConnectGoogleDocs,
                    isPreparing: viewModel.isPreparingGoogleConnect,
                    errorMessage: viewModel.googleConnectErrorMessage,
                    startupErrorMessage: viewModel.agentStartupErrorMessage,
                    onConnect: viewModel.connectGoogleDocs,
                    onRetryStartup: viewModel.retryAgentStartup
                )
            case .home:
                homeNavigation
            }
        }
    }

    private var homeNavigation: some View {
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

    private var firstRunAnimation: Animation? {
        reduceMotion ? nil : .easeInOut(duration: 0.25)
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
                    isWaitingForApproval: viewModel.isWaitingForGoogleApproval,
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

            if viewModel.verificationControl != nil || !viewModel.visiblePendingItems.isEmpty {
                DocForYouSection(
                    viewModel: viewModel,
                    verification: viewModel.verificationControl,
                    items: viewModel.visiblePendingItems,
                    composerScope: .home
                )
            }

            ForEach(viewModel.unmatchedGroupProgress) { progress in
                DocUnmatchedGroupProgressCard(progress: progress)
                    .docHomeRow()
            }

            if viewModel.docs.isEmpty {
                if viewModel.unmatchedGroupProgress.isEmpty {
                    DocEmptyState(lifecycle: viewModel.controlLifecycle)
                        .docHomeRow()
                }
            } else {
                Section {
                    ForEach(viewModel.docs) { doc in
                        DocStatusCard(
                            doc: doc,
                            relationship: viewModel.relationship(for: doc),
                            isStartingConnection: viewModel.isStartingGroupConnection(for: doc.id),
                            onConnectGroup: { viewModel.beginGroupConnection(for: doc) },
                            onShareNumber: { viewModel.presentShareNumber(for: doc) },
                            onShareDoc: {
                                Task { await viewModel.shareDoc(doc) }
                            }
                        )
                        .docHomeRow()
                        .transition(DocMotion.docArrival(reduceMotion: reduceMotion))
                    }
                } header: {
                    DocSectionHeader(title: "Docs")
                }
            }

            if viewModel.docs.isEmpty,
               viewModel.unmatchedGroupProgress.isEmpty,
               !viewModel.contributionLine.isEmpty {
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
    let isWaitingForApproval: Bool
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
                Text(isWaitingForApproval ? "Google Docs requested" : "Connect Google Docs")
                    .font(.subheadline.weight(.semibold))
                Text(isWaitingForApproval ? "Waiting for approval" : "Doc needs it to write your docs")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private var connectButton: some View {
        Button(action: onConnect) {
            if isWaitingForApproval {
                Text("Waiting…")
            } else if isConnecting {
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
    @State private var isPresentingAddContact: Bool = false
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize: DynamicTypeSize

    var body: some View {
        VStack(alignment: .leading, spacing: DesignConstants.Spacing.step4x) {
            identityHeader
            actionButtons
        }
        .padding(DesignConstants.Spacing.step4x)
        .background(Color.colorFillMinimal, in: RoundedRectangle(cornerRadius: DesignConstants.CornerRadius.medium))
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("doc-contribution-line")
        .sheet(isPresented: $isPresentingAddContact) {
            DocAddContactView(name: "@doc", phoneNumber: number)
        }
    }

    @ViewBuilder
    private var identityHeader: some View {
        if dynamicTypeSize.isAccessibilitySize {
            VStack(alignment: .leading, spacing: DesignConstants.Spacing.step3x) {
                avatar
                identityText
            }
        } else {
            HStack(spacing: DesignConstants.Spacing.step3x) {
                avatar
                identityText
            }
        }
    }

    private var avatar: some View {
        EmojiAvatarView(
            emoji: DocPreviewConfiguration.avatarEmoji,
            agentVerification: .verified(.convos),
            size: Constant.avatarSize
        )
    }

    private var identityText: some View {
        VStack(alignment: .leading, spacing: DesignConstants.Spacing.stepHalf) {
            Text("@doc")
                .font(.headline)
                .foregroundStyle(.colorTextPrimary)
            Text(docDisplayPhoneNumber(number))
                .font(.subheadline.monospacedDigit())
                .foregroundStyle(.colorTextSecondary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    @ViewBuilder
    private var actionButtons: some View {
        if dynamicTypeSize.isAccessibilitySize {
            VStack(spacing: DesignConstants.Spacing.step2x) {
                addToContactsButton(labelStyle: .titleOnly, fullWidth: true)
                copyButton(labelStyle: .titleOnly, fullWidth: true)
                shareButton(labelStyle: .titleOnly, fullWidth: true)
            }
        } else {
            HStack(spacing: DesignConstants.Spacing.step2x) {
                addToContactsButton(labelStyle: .titleAndIcon, fullWidth: true)
                copyButton(labelStyle: .iconOnly, fullWidth: false)
                shareButton(labelStyle: .iconOnly, fullWidth: false)
            }
        }
    }

    private func addToContactsButton(labelStyle: ButtonLabelStyle, fullWidth: Bool) -> some View {
        Button {
            isPresentingAddContact = true
        } label: {
            actionLabel("Add to Contacts", systemImage: "person.badge.plus", style: labelStyle)
        }
        .convosButtonStyle(.outlineCapsule(fullWidth: fullWidth))
        .frame(minHeight: Constant.minimumTouchTarget)
        .accessibilityIdentifier("doc-add-to-contacts")
    }

    private func copyButton(labelStyle: ButtonLabelStyle, fullWidth: Bool) -> some View {
        Button {
            DocCopyNumberActivity.copy(number: number)
        } label: {
            actionLabel("Copy Number", systemImage: "doc.on.doc", style: labelStyle)
        }
        .convosButtonStyle(.outlineCapsule(fullWidth: fullWidth))
        .frame(minWidth: Constant.minimumTouchTarget, minHeight: Constant.minimumTouchTarget)
        .accessibilityIdentifier("doc-copy-number")
    }

    private func shareButton(labelStyle: ButtonLabelStyle, fullWidth: Bool) -> some View {
        Button(action: onShare) {
            actionLabel("Share", systemImage: "square.and.arrow.up", style: labelStyle)
        }
        .convosButtonStyle(.outlineCapsule(fullWidth: fullWidth))
        .frame(minWidth: Constant.minimumTouchTarget, minHeight: Constant.minimumTouchTarget)
        .accessibilityLabel("Share Doc's number")
    }

    @ViewBuilder
    private func actionLabel(_ title: String, systemImage: String, style: ButtonLabelStyle) -> some View {
        if style == .iconOnly {
            Label(title, systemImage: systemImage)
                .labelStyle(.iconOnly)
        } else if style == .titleOnly {
            Label(title, systemImage: systemImage)
                .labelStyle(.titleOnly)
        } else {
            Label(title, systemImage: systemImage)
                .labelStyle(.titleAndIcon)
        }
    }

    private enum ButtonLabelStyle {
        case iconOnly
        case titleOnly
        case titleAndIcon
    }

    private enum Constant {
        static let avatarSize: CGFloat = 52.0
        static let minimumTouchTarget: CGFloat = 44.0
    }
}

private struct DocEmptyState: View {
    let lifecycle: DocControlLifecycle?

    var body: some View {
        VStack(spacing: DesignConstants.Spacing.step5x) {
            Spacer(minLength: 48.0)
            Image(systemName: "photo.on.rectangle.angled")
                .font(.system(size: 42.0, weight: .medium))
                .foregroundStyle(.colorLava)
                .accessibilityHidden(true)
            Text("Start a doc")
                .font(.title2.weight(.semibold))
                .foregroundStyle(.colorTextPrimary)
                .multilineTextAlignment(.center)
            Text(emptyStateDescription)
                .font(.body)
                .foregroundStyle(.colorTextSecondary)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
            VStack(alignment: .leading, spacing: DesignConstants.Spacing.step3x) {
                hint(
                    systemImage: "photo.on.rectangle.angled",
                    text: "Tap + below to choose screenshots."
                )
                hint(
                    systemImage: "person.badge.plus",
                    text: "Add @doc, then send a message in the group."
                )
            }
            Text("Screenshots make the first version. A connected group keeps it current with new texts.")
                .font(.footnote)
                .foregroundStyle(.colorTextSecondary)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 48.0)
        }
        .frame(maxWidth: 420.0)
        .padding(.horizontal, DesignConstants.Spacing.step5x)
        .frame(maxWidth: .infinity)
        .accessibilityIdentifier("doc-empty-state")
    }

    private func hint(systemImage: String, text: String) -> some View {
        Label {
            Text(text)
                .font(.subheadline)
                .foregroundStyle(.colorTextPrimary)
                .fixedSize(horizontal: false, vertical: true)
        } icon: {
            Image(systemName: systemImage)
                .foregroundStyle(.colorLava)
                .frame(width: 28.0)
        }
    }

    private var emptyStateDescription: String {
        switch lifecycle?.status {
        case .provisioned, .joined:
            return "I'm getting ready. Send group screenshots here, or add @doc to an iMessage group."
        case .failed:
            return "I couldn't get ready. Try again, or reset the Doc agent in Settings."
        case .destroyed:
            return "This Doc agent is no longer available. Reset it in Settings to start again."
        case .ready, nil:
            return "Send group screenshots here, or add @doc to an iMessage group."
        }
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
    let relationship: DocGroupRelationship
    let isStartingConnection: Bool
    let onConnectGroup: () -> Void
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
                    }

                    Text("\(doc.lastChange.who) \(doc.lastChange.what) · \(compactRelativeTime(from: doc.lastChange.at))")
                        .font(.subheadline)
                        .foregroundStyle(.colorTextSecondary)
                        .lineLimit(2)
                }
                .contentShape(.rect)
            }
            .buttonStyle(.plain)

            DocGroupRelationshipRow(
                relationship: relationship,
                isStarting: isStartingConnection,
                onConnect: onConnectGroup,
                onShareNumber: onShareNumber
            )

            ViewThatFits(in: .horizontal) {
                HStack(spacing: DesignConstants.Spacing.step2x) {
                    metadataPills
                }
                VStack(alignment: .leading, spacing: DesignConstants.Spacing.step2x) {
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
