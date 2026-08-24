/*
 THESIS: Your Space is a private context home with three fast routes back into recent Convos, a personal library, and personal agents that remain separate from every group.
 OWN-WORLD: Native Convos neutrals, circular identity, glass reserved for persistent controls, and open editorial spacing between flat lists and one expressive Me card.
 STORY: On launch the user learns what changed, jumps into a recent Convo, sees what they own, and works privately with an agent before choosing what to save or share.
 FIRST VIEWPORT: Profile, anchored Your Space switcher, and the add control sit above the briefing, three recent Convos, and the beginning of Me & My Stuff.
 FORM: A living cross-conversation digest using the pinned shell recorded as YS-SHELL-2026-08-18; no generated concept seed was used.
 FINISH: unreviewed and undocumented is unfinished; this build ends with the finish review, the verdict, and DESIGN.md
 */

import Combine
import ConvosComposer
import ConvosCore
import ConvosCoreiOS
import SwiftUI

private struct PersonalAgentHarness: Identifiable {
    let provider: ExternalAgentProvider
    let grokBotAgent: GrokBotAgent?

    var id: String {
        if let grokBotAgent {
            return "grokbot:\(grokBotAgent.id)"
        }
        return "provider:\(provider.rawValue)"
    }

    var name: String {
        grokBotAgent?.harnessName ?? provider.displayName
    }
}

struct YourSpaceView: View {
    @Bindable var viewModel: ConversationsViewModel
    @Bindable var profileSettingsViewModel: ProfileSettingsViewModel
    let appIndicatorContext: AppIndicatorContext
    let transitionNamespace: Namespace.ID
    let onOpenSettings: () -> Void

    @State private var presentingSwitcher: Bool = false
    @State private var toolDestination: YourSpaceToolDestination?
    @State private var inputMode: YourSpaceInputMode?
    @State private var presentingPersonalAgentOnboarding: Bool = false
    @State private var onboardingInitialProvider: ExternalAgentProvider?
    @State private var personalAgentState: AgentChatPrototypeState = .init()
    @State private var mockAgentProvider: ExternalAgentProvider?
    @State private var dockRecorder: VoiceMemoRecorder = .init()
    @State private var dockRecordingActive: Bool = false
    @State private var dockInvertedTheme: Bool = false
    @State private var dockTranscribing: Bool = false
    @State private var pendingChatDraft: String = ""
    @State private var presentingFileImporter: Bool = false
    @State private var fileImportNotice: YourSpaceFileImportNotice?
    @State private var localContextFiles: [YourSpaceStoredFile] = YourSpaceFileStore.storedFiles()
    @State private var conversationContextItems: [ContextLibraryItem] = []
    @State private var rememberedFields: [YourSpaceRememberedField] = YourSpaceRememberedFieldStore.fields()
    @State private var browsingContextKind: YourSpaceContextKind?
    @State private var presentingAddContext: Bool = false
    @State private var presentingPersonalCard: Bool = false
    @State private var presentingMeAndMyStuff: Bool = false
    @State private var presentingManageAgents: Bool = false
    @State private var showsAllAgentsAcrossConvos: Bool = false
    @State private var sharingItem: YourSpaceContextItem?
    @State private var shareNotice: YourSpaceShareNotice?
    @State private var sidebarWidth: CGFloat = 0.0
    @State private var conversationPendingExplosion: Conversation?
    @State private var staleDeviceSheetDismissed: Bool = false
    @Environment(\.scenePhase) private var scenePhase: ScenePhase
    @Environment(\.accessibilityReduceMotion) private var reduceMotion: Bool
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize: DynamicTypeSize
    @AccessibilityFocusState private var switcherButtonAccessibilityFocused: Bool
    @AppStorage("your-space-people-widget") private var showsPeopleWidget: Bool = false
    @AppStorage("your-space-footprint-widget") private var showsFootprintWidget: Bool = false
    @AppStorage("your-space-agents-widget") private var showsAgentsWidget: Bool = false
    @AppStorage("your-space-personal-agent-provider") private var personalAgentProviderRawValue: String = ""
    @AppStorage("your-space-grokbot-agent-id") private var personalGrokBotAgentId: String = ""
    private let dockTranscriber: VoiceMemoTranscriber = .init()

    private var conversations: [Conversation] {
#if DEBUG
        if usesVisualFixture {
            return Self.visualFixtureConversations
        }
#endif
        var seen: Set<String> = []
        return (viewModel.pinnedConversations + viewModel.unpinnedConversations)
            .filter { seen.insert($0.id).inserted }
    }

    private var hasLoadedConversations: Bool {
        viewModel.hasLoadedInitialConversations || usesVisualFixture
    }

    private var usesVisualFixture: Bool {
#if DEBUG
        ProcessInfo.processInfo.environment["YOUR_SPACE_VISUAL_FIXTURE"] == "1"
#else
        false
#endif
    }

    private var contactNameOverride: @Sendable (String) -> String? {
        let repository = viewModel.session.messagingServiceSync().contactsRepository()
        return { repository.contact(for: $0)?.displayName }
    }

    private var contactOverride: @Sendable (String) -> Contact? {
        viewModel.session.messagingServiceSync().contactsRepository().contact(for:)
    }

    private var briefing: YourSpaceBriefing {
        YourSpaceBriefingBuilder.make(
            conversations: conversations,
            memberNameOverride: contactNameOverride
        )
    }

    private var contextObservationID: String {
        conversations.map(\.id).sorted().joined(separator: "|")
    }

    private var allContextItems: [YourSpaceContextItem] {
#if DEBUG
        if usesVisualFixture, localContextFiles.isEmpty, conversationContextItems.isEmpty {
            return Self.visualFixtureContextItems
        }
#endif
        return (
            localContextFiles.map(YourSpaceContextItem.init(local:))
                + conversationContextItems.map(YourSpaceContextItem.init(conversation:))
                + rememberedFields.map(YourSpaceContextItem.init(rememberedField:))
        )
        .sorted { $0.date > $1.date }
    }

    private var isMockAgentActive: Bool {
        mockAgentProvider != nil
    }

    private var activePersonalAgent: ExternalAgentProvider? {
        if let mockAgentProvider {
            return mockAgentProvider
        }
        return ExternalAgentProvider(rawValue: personalAgentProviderRawValue)
    }

    private var activeGrokBotAgent: GrokBotAgent? {
        guard activePersonalAgent == .grokBot else { return nil }
        let enabledAgents = GrokBotConnectionStore.configuration()?.enabledAgents ?? []
        return enabledAgents.first(where: { $0.id == personalGrokBotAgentId }) ?? enabledAgents.first
    }

    private var activePersonalAgentName: String? {
        activeGrokBotAgent?.harnessName ?? activePersonalAgent?.displayName
    }

    private var codexConnectionConfiguration: CodexConnectionConfiguration? {
        guard activePersonalAgent == .codex else { return nil }
        return CodexConnectionStore.configuration()
    }

    private var codexYourSpaceSnapshot: CodexYourSpaceSnapshot? {
        guard codexConnectionConfiguration?.sharesYourSpaceContext == true else { return nil }
        return CodexYourSpaceSnapshot(
            briefing: briefing,
            contextItems: allContextItems,
            conversationTitle: conversationTitle,
            senderName: senderName
        )
    }

    private var activeAgentRequest: ((String) async throws -> String)? {
        switch activePersonalAgent {
        case .town:
            return { prompt in
                try await askTownAgent(prompt)
            }
        case .tasklet:
            return { prompt in
                try await askTaskletAgent(prompt)
            }
        case .grokBot:
            guard let activeGrokBotAgent else { return nil }
            return { prompt in
                try await askGrokBotAgent(prompt, agent: activeGrokBotAgent)
            }
        default:
            return nil
        }
    }

    private var selectedConversationBinding: Binding<ConversationViewModel?> {
        Binding(
            get: { viewModel.selectedConversationViewModel },
            set: { newValue in
                if newValue == nil {
                    viewModel.endHostedInviteSessionOnPop()
                }
                viewModel.selectedConversationId = newValue?.conversation.id
            }
        )
    }

    var body: some View {
        content
            .accessibilityHidden(presentingSwitcher)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .overlay(alignment: .topTrailing) {
                if presentingSwitcher {
                    switcherOverlay
                }
            }
            .background(.colorBackgroundSurfaceless)
            .safeAreaInset(edge: .top, spacing: 0) {
                topBar.accessibilityHidden(presentingSwitcher)
            }
            .safeAreaInset(edge: .bottom, spacing: 0) {
                if !dynamicTypeSize.isAccessibilitySize {
                    bottomBar.accessibilityHidden(presentingSwitcher)
                }
            }
            .navigationDestination(item: selectedConversationBinding) { convoViewModel in
                pushedConversationDestination(viewModel: convoViewModel)
            }
            .navigationDestination(isPresented: $presentingMeAndMyStuff) {
                meAndMyStuffDestination
            }
            .navigationDestination(isPresented: $presentingManageAgents) {
                ManageAgentsView(agents: manageAgents)
            }
            .sheet(item: $toolDestination) { destination in
                YourSpaceToolDestinationSheet(
                    destination: destination,
                    conversations: conversations,
                    memberNameOverride: contactNameOverride,
                    connectionsViewModel: viewModel.appSettingsViewModel.connectionsListViewModel,
                    showsPeopleWidget: $showsPeopleWidget,
                    showsFootprintWidget: $showsFootprintWidget,
                    showsAgentsWidget: $showsAgentsWidget
                )
                .presentationDetents([.medium, .large])
                .presentationDragIndicator(.visible)
            }
            .fullScreenCover(item: $inputMode) { mode in
                YourSpaceInputSheet(
                    mode: mode,
                    briefing: briefing,
                    contextItems: allContextItems,
                    agentName: activePersonalAgentName,
                    agentSubtitle: activePersonalAgent.map { $0.switcherSubtitle } ?? "Personal agent",
                    agentProvider: activePersonalAgent,
                    initialChatText: pendingChatDraft,
                    codexConfiguration: codexConnectionConfiguration,
                    codexSnapshot: codexYourSpaceSnapshot,
                    onAskAgent: isMockAgentActive ? nil : activeAgentRequest,
                    onSaveOutput: saveAgentOutput,
                    onSaveLink: saveAgentLink,
                    onShareOutput: shareAgentOutput,
                    manageAgents: manageAgents,
                    onSelectAgent: selectPersonalAgent(id:),
                    onAddAgent: addAgentFromChat
                )
                .navigationTransition(.zoom(sourceID: Constant.agentDockTransitionId, in: transitionNamespace))
            }
            .fullScreenCover(isPresented: $presentingPersonalAgentOnboarding) {
                ExternalAgentOnboardingView(
                    prototypeState: personalAgentState,
                    initialProvider: onboardingInitialProvider,
                    onConnected: connectPersonalAgent
                )
            }
            .sheet(item: $browsingContextKind) { kind in
                YourSpaceContextBrowser(
                    items: allContextItems,
                    initialFilter: kind,
                    conversationTitle: conversationTitle,
                    senderName: senderName,
                    onShare: shareFromContextBrowser,
                    onOpenConversation: openConversationFromContextBrowser,
                    onMessageSender: messageSenderFromContextBrowser,
                    onAddContext: addFromContextBrowser
                )
                .presentationDetents([.large])
                .presentationDragIndicator(.visible)
            }
            .sheet(isPresented: $presentingAddContext) {
                YourSpaceAddContextSheet { file in
                    refreshLocalContext(selecting: file)
                }
                .presentationDetents([.large])
                .presentationDragIndicator(.visible)
            }
            .sheet(isPresented: $presentingPersonalCard) {
                YourSpacePersonalCardEditor(
                    profile: profileSettingsViewModel.profile,
                    profileImage: profileSettingsViewModel.profileImage,
                    recentContext: briefing.recentUpdates,
                    rememberedFields: $rememberedFields,
                    onShareField: shareRememberedField
                )
                .presentationDetents([.large])
                .presentationDragIndicator(.visible)
            }
            .sheet(item: $sharingItem) { item in
                YourSpaceShareDestinationSheet(
                    item: item,
                    conversations: conversations,
                    memberNameOverride: contactNameOverride,
                    onSelect: { conversation in
                        stage(item, in: conversation)
                    }
                )
                .presentationDetents([.medium, .large])
                .presentationDragIndicator(.visible)
            }
            .fileImporter(
                isPresented: $presentingFileImporter,
                allowedContentTypes: [.item],
                allowsMultipleSelection: true,
                onCompletion: handleFileImport
            )
            .alert(item: $fileImportNotice) { notice in
                Alert(
                    title: Text(notice.title),
                    message: Text(notice.message),
                    dismissButton: .default(Text("OK"))
                )
            }
            .alert(item: $shareNotice) { notice in
                Alert(
                    title: Text(notice.title),
                    message: Text(notice.message),
                    dismissButton: .default(Text("OK"))
                )
            }
            .modifier(ConversationsSheetModifier(
                viewModel: viewModel,
                profileSettingsViewModel: profileSettingsViewModel,
                conversationPendingExplosion: $conversationPendingExplosion,
                staleDeviceSheetDismissed: $staleDeviceSheetDismissed,
                namespace: transitionNamespace
            ))
            .onAppear {
                refreshLocalContext()
                restorePersonalAgentIfNeeded()
#if DEBUG
                if ProcessInfo.processInfo.environment["YOUR_SPACE_SWITCHER_FIXTURE"] == "1" {
                    presentingSwitcher = true
                }
                if ProcessInfo.processInfo.environment["YOUR_SPACE_CONTEXT_BROWSER_FIXTURE"] == "1" {
                    browsingContextKind = .address
                }
                if ProcessInfo.processInfo.environment["YOUR_SPACE_EXTERNAL_AGENT_FIXTURE"] == "1" {
                    presentingPersonalAgentOnboarding = true
                }
#endif
                guard !usesVisualFixture else { return }
                viewModel.activeFilter = .all
                viewModel.onAppear()
            }
            .task(id: contextObservationID) {
                guard !usesVisualFixture else { return }
                let ids = conversations.map(\.id)
                let publisher = viewModel.session.contextLibraryRepository().itemsPublisher(conversationIds: ids)
                for await items in publisher.values {
                    guard !Task.isCancelled else { return }
                    conversationContextItems = items
                }
            }
            .onDisappear {
                cancelDockRecording()
                if !usesVisualFixture { viewModel.onDisappear() }
            }
            .onChange(of: viewModel.staleDeviceObserver.isDeviceRemoved) { _, isRemoved in
                if isRemoved { staleDeviceSheetDismissed = false }
            }
            .onChange(of: scenePhase) { _, newPhase in
                if newPhase == .active { staleDeviceSheetDismissed = false }
            }
            .onChange(of: rememberedFields) { _, fields in
                YourSpaceRememberedFieldStore.save(fields)
            }
            .onContinueUserActivity(NSUserActivityTypeBrowsingWeb) { activity in
                if let url = activity.webpageURL { viewModel.handleURL(url) }
            }
            .onOpenURL { viewModel.handleURL($0) }
            .memberContactOverride(contactOverride)
    }
}

private extension YourSpaceView {
    @ViewBuilder
    private var content: some View {
        if !hasLoadedConversations {
            YourSpaceLoadingView()
        } else {
            ScrollView {
                LazyVStack(alignment: .leading, spacing: DesignConstants.Spacing.step10x) {
                    recentConvosSection

                    if conversations.isEmpty {
                        emptyActions
                    }

                    contextSection

                    bringYourOwnAgentCallout

                    if dynamicTypeSize.isAccessibilitySize {
                        accessibilityActions
                    }

                    if showsPeopleWidget, !activePeople.isEmpty {
                        peopleWidget
                    }

                    if !agentsAcrossConvos.isEmpty {
                        agentsWidget
                    }

                    contextPromise

                    if showsFootprintWidget, briefing.sourceCount > 0 {
                        footprintWidget
                    }

                    briefingHero
                }
                .padding(.horizontal, DesignConstants.Spacing.step6x)
                .padding(.top, DesignConstants.Spacing.step8x)
                .padding(.bottom, DesignConstants.Spacing.step16x)
                .frame(maxWidth: 720, alignment: .leading)
                .frame(maxWidth: .infinity)
            }
            .scrollIndicators(.hidden)
            .accessibilityIdentifier("your-space-home-scroll")
        }
    }

    private var topBar: some View {
        HStack(spacing: DesignConstants.Spacing.step3x) {
            profileButton
            spaceSwitcherButton
            addMenu
        }
        .padding(.horizontal, DesignConstants.Spacing.step4x)
        .padding(.vertical, DesignConstants.Spacing.step2x)
        .frame(maxWidth: .infinity)
        .background(.bar.opacity(0.94))
        .dynamicTypeSize(...DynamicTypeSize.xxxLarge)
    }

    private var switcherOverlay: some View {
        GeometryReader { proxy in
            ZStack(alignment: .topTrailing) {
                Button {
                    dismissSwitcher()
                } label: {
                    Color.black.opacity(0.12)
                        .contentShape(.rect)
                }
                .buttonStyle(.plain)
                .accessibilityHidden(true)

                YourSpaceConversationSwitcher(
                    conversations: conversations,
                    memberNameOverride: contactNameOverride,
                    onDismiss: dismissSwitcher,
                    onSelectConversation: selectConversation
                )
                .frame(
                    width: min(max(proxy.size.width - 24, 0), 560),
                    height: min(max(proxy.size.height * 0.74, 0), 680)
                )
                .background(.colorBackgroundRaisedSecondary)
                .clipShape(.rect(
                    topLeadingRadius: 0,
                    bottomLeadingRadius: DesignConstants.CornerRadius.large,
                    bottomTrailingRadius: DesignConstants.CornerRadius.large,
                    topTrailingRadius: 0
                ))
                .shadow(color: Color.black.opacity(0.16), radius: 24, y: 12)
                .padding(.trailing, DesignConstants.Spacing.step3x)
                .transition(.move(edge: .top).combined(with: .opacity))
                .accessibilityElement(children: .contain)
                .accessibilityIdentifier("your-space-switcher-panel")
            }
        }
    }

    private var profileButton: some View {
        Button {
            presentingMeAndMyStuff = true
        } label: {
            ProfileAvatarView(
                profile: profileSettingsViewModel.profile,
                profileImage: profileSettingsViewModel.profileImage,
                useSystemPlaceholder: true,
                size: 40
            )
            .frame(width: 40, height: 40)
            .overlay {
                Circle().stroke(Color.colorBorderSubtle, lineWidth: 0.5)
            }
        }
        .buttonStyle(.plain)
        .frame(width: 44, height: 44)
        .contentShape(.circle)
        .accessibilityLabel("Open Me & My Stuff")
        .accessibilityIdentifier("your-space-profile-button")
    }

    private var spaceSwitcherButton: some View {
        Button {
            let willPresent = !presentingSwitcher
            withAnimation(reduceMotion ? nil : .snappy(duration: 0.28)) {
                presentingSwitcher = willPresent
            }
            switcherButtonAccessibilityFocused = !willPresent
        } label: {
            HStack(spacing: DesignConstants.Spacing.step2x) {
                Text("Your Space")
                    .font(.body.weight(.semibold))
                    .foregroundStyle(.colorTextPrimary)
                    .lineLimit(1)
                Image(systemName: "chevron.down")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.colorTextSecondary)
                    .rotationEffect(.degrees(presentingSwitcher ? 180 : 0))
            }
            .padding(.horizontal, DesignConstants.Spacing.step5x)
            .frame(maxWidth: .infinity, minHeight: 44)
            .contentShape(.capsule)
        }
        .buttonStyle(.plain)
        .glassEffect(.regular.interactive(), in: .capsule)
        .accessibilityFocused($switcherButtonAccessibilityFocused)
        .accessibilityLabel("Your Space. Show all convos")
        .accessibilityIdentifier("your-space-switcher-button")
    }

    private var addMenu: some View {
        Menu {
            Button("Start a new convo", systemImage: "square.and.pencil") {
                viewModel.onStartConvo()
            }
            Button("Join a convo", systemImage: "qrcode.viewfinder") {
                viewModel.onJoinConvo()
            }

            Divider()

            toolsMenuContent
        } label: {
            Image(systemName: "plus")
                .font(.title3.weight(.semibold))
                .foregroundStyle(.colorTextPrimary)
                .frame(width: 44, height: 44)
                .contentShape(.circle)
        }
        .glassEffect(.regular.interactive(), in: .circle)
        .matchedTransitionSource(id: "composer-transition-source", in: transitionNamespace)
        .disabled(viewModel.staleDeviceObserver.isDeviceRemoved)
        .accessibilityLabel("Add a convo")
        .accessibilityIdentifier("your-space-add-menu")
    }

    private var briefingHero: some View {
        VStack(alignment: .leading, spacing: DesignConstants.Spacing.step4x) {
            Text(briefing.headline)
                .font(.system(.largeTitle, design: .serif, weight: .bold))
                .tracking(-0.6)
                .foregroundStyle(.colorTextPrimary)
                .fixedSize(horizontal: false, vertical: true)
                .contentTransition(.numericText())

            if briefing.sourceCount > 0 {
                Text(sourceSummary)
                    .font(.body)
                    .foregroundStyle(.colorTextSecondary)
            } else {
                Label("Only you can see this space", systemImage: "lock.fill")
                    .font(.body)
                    .foregroundStyle(.colorTextSecondary)
            }
        }
        .accessibilityElement(children: .combine)
    }

    private var sourceSummary: String {
        let convoWord = briefing.sourceCount == 1 ? "convo" : "convos"
        let peopleWord = briefing.peopleCount == 1 ? "person" : "people"
        return "Private briefing across \(briefing.sourceCount) \(convoWord) and \(briefing.peopleCount) \(peopleWord)."
    }

    private var recentConversations: [Conversation] {
        Array(conversations
            .sorted { ($0.lastMessage?.createdAt ?? $0.createdAt) > ($1.lastMessage?.createdAt ?? $1.createdAt) }
            .prefix(3))
    }

    private var recentConvosSection: some View {
        VStack(alignment: .leading, spacing: DesignConstants.Spacing.step3x) {
            HStack(alignment: .firstTextBaseline) {
                Text("Recent Convos")
                    .font(.title2.weight(.bold))
                    .foregroundStyle(.colorTextPrimary)
                Spacer(minLength: DesignConstants.Spacing.step3x)
                if briefing.attentionCount > 0 {
                    Text("\(briefing.attentionCount) unread")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.colorTextSecondary)
                }
            }

            if recentConversations.isEmpty {
                Text("Your most recent Convos will stay close here.")
                    .font(.body)
                    .foregroundStyle(.colorTextSecondary)
                    .padding(.vertical, DesignConstants.Spacing.step3x)
            } else {
                VStack(spacing: 0) {
                    ForEach(Array(recentConversations.enumerated()), id: \.element.id) { index, conversation in
                        recentConversationRow(conversation)
                        if index < recentConversations.count - 1 {
                            Divider().padding(.leading, 64)
                        }
                    }
                }
            }
        }
        .accessibilityIdentifier("your-space-recent-convos")
    }

    private func recentConversationRow(_ conversation: Conversation) -> some View {
        Button {
            selectConversation(conversation)
        } label: {
            HStack(spacing: DesignConstants.Spacing.step3x) {
                ConversationAvatarView(
                    conversation: conversation,
                    conversationImage: nil,
                    size: 48
                )
                .frame(width: 48, height: 48)

                VStack(alignment: .leading, spacing: DesignConstants.Spacing.stepHalf) {
                    Text(conversation.computedDisplayName(memberNameOverride: contactNameOverride))
                        .font(conversationIsUnread(conversation) ? .body.weight(.semibold) : .body)
                        .foregroundStyle(.colorTextPrimary)
                        .lineLimit(1)
                    Text(recentConversationPreview(conversation))
                        .font(.subheadline)
                        .foregroundStyle(.colorTextSecondary)
                        .lineLimit(1)
                }

                Spacer(minLength: DesignConstants.Spacing.step2x)

                if conversationIsUnread(conversation) {
                    Circle()
                        .fill(Color.colorLava)
                        .frame(width: 8, height: 8)
                        .accessibilityHidden(true)
                }

                Image(systemName: "chevron.right")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.colorTextTertiary)
                    .accessibilityHidden(true)
            }
            .frame(minHeight: 72)
            .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .accessibilityLabel(conversation.computedDisplayName(memberNameOverride: contactNameOverride))
        .accessibilityValue(conversationIsUnread(conversation) ? "Unread" : recentConversationPreview(conversation))
    }

    private func recentConversationPreview(_ conversation: Conversation) -> String {
        if let preview = conversation.lastMessage?.text, !preview.isEmpty {
            return preview
        }
        return "Updated \(conversation.createdAt.formatted(.relative(presentation: .named)))"
    }

    private func conversationIsUnread(_ conversation: Conversation) -> Bool {
        conversation.isUnread || conversation.agentDm?.isUnread == true
    }

    private var contextSection: some View {
        YourSpaceMeSummaryCard(
            profile: profileSettingsViewModel.profile,
            profileImage: profileSettingsViewModel.profileImage,
            items: allContextItems,
            connectionCount: activeConnectionCount,
            onOpen: { presentingMeAndMyStuff = true }
        )
    }

    private var activeConnectionCount: Int {
        viewModel.appSettingsViewModel.connectionsListViewModel.rows.filter(\.isOn).count
    }

    private var meAndMyStuffDestination: some View {
        ScrollView {
            YourSpaceContextSection(
                profile: profileSettingsViewModel.profile,
                profileImage: profileSettingsViewModel.profileImage,
                items: allContextItems,
                connectionCount: activeConnectionCount,
                recentContext: briefing.recentUpdates,
                conversationTitle: conversationTitle,
                senderName: senderName,
                onEditCard: { presentingPersonalCard = true },
                onBrowse: { browsingContextKind = $0 },
                onShare: { sharingItem = $0 },
                onAddContext: { presentingAddContext = true },
                onAddConnections: { toolDestination = .connections }
            )
            .padding(.horizontal, DesignConstants.Spacing.step6x)
            .padding(.top, DesignConstants.Spacing.step6x)
            .padding(.bottom, DesignConstants.Spacing.step16x)
            .frame(maxWidth: 720, alignment: .leading)
            .frame(maxWidth: .infinity)
        }
        .background(.colorBackgroundSurfaceless)
        .navigationTitle("Me & My Stuff")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar(.visible, for: .navigationBar)
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Button("Edit") { presentingPersonalCard = true }
                    .accessibilityIdentifier("your-space-me-edit")
            }
            ToolbarItem(placement: .topBarTrailing) {
                Button(action: onOpenSettings) {
                    Image(systemName: "gearshape")
                }
                .accessibilityLabel("Open settings")
            }
        }
    }

    private var emptyActions: some View {
        VStack(alignment: .leading, spacing: DesignConstants.Spacing.step3x) {
            Button {
                viewModel.onStartConvo()
            } label: {
                Label("Start a new convo", systemImage: "square.and.pencil")
                    .font(.headline)
                    .frame(maxWidth: .infinity, minHeight: 52)
            }
            .buttonStyle(.borderedProminent)

            Button {
                viewModel.onJoinConvo()
            } label: {
                Label("Join with a QR code", systemImage: "qrcode.viewfinder")
                    .font(.headline)
                    .frame(maxWidth: .infinity, minHeight: 52)
            }
            .buttonStyle(.bordered)
        }
        .frame(maxWidth: 520)
    }

    private var activePeople: [ConversationMember] {
        var seen: Set<String> = []
        let members = conversations
            .sorted { ($0.lastMessage?.createdAt ?? $0.createdAt) > ($1.lastMessage?.createdAt ?? $1.createdAt) }
            .flatMap(\.membersWithoutCurrent)
            .filter { !$0.isAgent && seen.insert($0.profile.inboxId).inserted }
            .prefix(8)
        return Array(members)
    }

    private var peopleWidget: some View {
        VStack(alignment: .leading, spacing: DesignConstants.Spacing.step4x) {
            Text("People across your recent convos")
                .font(.title2.weight(.bold))
                .foregroundStyle(.colorTextPrimary)

            ScrollView(.horizontal) {
                HStack(spacing: DesignConstants.Spacing.step5x) {
                    ForEach(activePeople) { member in
                        VStack(spacing: DesignConstants.Spacing.step2x) {
                            ProfileAvatarView(
                                profile: member.profile,
                                profileImage: nil,
                                useSystemPlaceholder: false,
                                agentVerification: member.agentVerification,
                                size: 52
                            )
                            .frame(width: 52, height: 52)
                            Text(member.displayName(contactNameFallback: contactNameOverride))
                                .font(.caption)
                                .foregroundStyle(.colorTextSecondary)
                                .lineLimit(1)
                                .frame(width: 72)
                        }
                    }
                }
            }
            .scrollIndicators(.hidden)
        }
    }

    private var agentsAcrossConvos: [YourSpaceAgentConvoEntry] {
        var seen: Set<String> = []
        let entries = conversations
            .sorted { ($0.lastMessage?.createdAt ?? $0.createdAt) > ($1.lastMessage?.createdAt ?? $1.createdAt) }
            .flatMap { conversation in
                conversation.membersWithoutCurrent
                    .filter(\.isVerifiedAgent)
                    .map { YourSpaceAgentConvoEntry(conversation: conversation, agent: $0) }
            }
            .filter { seen.insert($0.id).inserted }
            .prefix(12)
        return Array(entries)
    }

    private var visibleAgentsAcrossConvos: [YourSpaceAgentConvoEntry] {
        showsAllAgentsAcrossConvos ? agentsAcrossConvos : Array(agentsAcrossConvos.prefix(3))
    }

    private var agentsWidget: some View {
        VStack(alignment: .leading, spacing: DesignConstants.Spacing.step4x) {
            HStack(alignment: .firstTextBaseline) {
                VStack(alignment: .leading, spacing: DesignConstants.Spacing.stepX) {
                    Text("Agents across your convos")
                        .font(.title2.weight(.bold))
                        .foregroundStyle(.colorTextPrimary)
                    Text("Jump straight into a private DM with an agent already in that group.")
                        .font(.subheadline)
                        .foregroundStyle(.colorTextSecondary)
                }

                Spacer(minLength: DesignConstants.Spacing.step3x)

                if agentsAcrossConvos.count > 3 {
                    Button(showsAllAgentsAcrossConvos ? "Show less" : "See all") {
                        withAnimation(reduceMotion ? nil : .smooth(duration: 0.25)) {
                            showsAllAgentsAcrossConvos.toggle()
                        }
                    }
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(.colorTextPrimary)
                    .accessibilityIdentifier("your-space-agents-see-all")
                }
            }

            VStack(spacing: 0) {
                ForEach(Array(visibleAgentsAcrossConvos.enumerated()), id: \.element.id) { index, entry in
                    Button {
                        viewModel.selectAgentDm(
                            in: entry.conversation,
                            agentInboxId: entry.agent.profile.inboxId
                        )
                    } label: {
                        HStack(spacing: DesignConstants.Spacing.step3x) {
                            ProfileAvatarView(
                                profile: entry.agent.profile,
                                profileImage: nil,
                                useSystemPlaceholder: false,
                                agentVerification: entry.agent.agentVerification,
                                size: 44
                            )
                            .frame(width: 44, height: 44)

                            VStack(alignment: .leading, spacing: DesignConstants.Spacing.stepHalf) {
                                Text(entry.agent.displayName(contactNameFallback: contactNameOverride))
                                    .font(.subheadline.weight(.semibold))
                                    .foregroundStyle(.colorTextPrimary)
                                    .lineLimit(1)
                                Text("in \(entry.conversation.computedDisplayName(memberNameOverride: contactNameOverride))")
                                    .font(.caption)
                                    .foregroundStyle(.colorTextSecondary)
                                    .lineLimit(1)
                            }

                            Spacer(minLength: DesignConstants.Spacing.step2x)

                            Image(systemName: "message.fill")
                                .font(.caption.weight(.semibold))
                                .foregroundStyle(.colorTextPrimary)
                                .frame(width: 32, height: 32)
                                .background(.colorFillMinimal, in: .circle)
                        }
                        .padding(.horizontal, DesignConstants.Spacing.step3x)
                        .frame(minHeight: 68)
                        .contentShape(.rect)
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("Message \(entry.agent.displayName) in \(entry.conversation.computedDisplayName(memberNameOverride: contactNameOverride))")

                    if index < visibleAgentsAcrossConvos.count - 1 {
                        Divider().padding(.leading, 68)
                    }
                }
            }
            .background(.colorBackgroundRaisedSecondary, in: .rect(cornerRadius: DesignConstants.CornerRadius.medium))
            .clipShape(.rect(cornerRadius: DesignConstants.CornerRadius.medium))
        }
        .accessibilityIdentifier("your-space-agents-widget")
    }

    private var bringYourOwnAgentCallout: some View {
        VStack(alignment: .leading, spacing: DesignConstants.Spacing.step5x) {
            HStack(spacing: -8) {
                ForEach([ExternalAgentProvider.codex, .town, .tasklet, .grokBot, .connectMCP]) { provider in
                    personalAgentBadge(provider, size: 42)
                        .overlay(Circle().stroke(Color.colorBackgroundRaisedSecondary, lineWidth: 3))
                }
                Spacer(minLength: DesignConstants.Spacing.step3x)
                Label("Private", systemImage: "lock.fill")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.colorTextSecondary)
            }

            VStack(alignment: .leading, spacing: DesignConstants.Spacing.step2x) {
                Text("Bring personal agents to Convos")
                    .font(.title2.weight(.bold))
                    .foregroundStyle(.colorTextPrimary)
                Text("Bring group context to an agent you already use, work with it in private, and control exactly what gets saved or shared back.")
                    .font(.body)
                    .foregroundStyle(.colorTextSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Label {
                Text("Only you can talk to this personal agent. It is not connected to a group, and no group member can message it.")
            } icon: {
                Image(systemName: "person.crop.circle.badge.checkmark")
            }
            .font(.subheadline.weight(.medium))
            .foregroundStyle(.colorTextPrimary)
            .fixedSize(horizontal: false, vertical: true)

            Button(action: handlePersonalAgentSectionAction) {
                HStack(spacing: DesignConstants.Spacing.step3x) {
                    if let activePersonalAgent {
                        personalAgentBadge(activePersonalAgent, size: 38)
                    } else {
                        Image(systemName: "plus")
                            .font(.subheadline.weight(.bold))
                            .foregroundStyle(.colorTextPrimaryInverted)
                            .frame(width: 38, height: 38)
                            .background(.colorFillPrimary, in: .circle)
                    }

                    VStack(alignment: .leading, spacing: DesignConstants.Spacing.stepHalf) {
                        Text(personalAgentSectionActionTitle)
                            .font(.subheadline.weight(.semibold))
                            .foregroundStyle(.colorTextPrimary)
                        Text(activePersonalAgent == nil
                            ? "Codex, Town, Tasklet, and more"
                            : personalAgentConnectionSubtitle)
                            .font(.caption)
                            .foregroundStyle(.colorTextSecondary)
                            .lineLimit(1)
                    }

                    Spacer(minLength: 0)
                    Image(systemName: "chevron.right")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.colorTextTertiary)
                }
                .padding(.horizontal, DesignConstants.Spacing.step3x)
                .frame(minHeight: 60)
                .background(.colorFillMinimal, in: .rect(cornerRadius: DesignConstants.CornerRadius.medium))
                .contentShape(.rect)
            }
            .buttonStyle(.plain)
        }
        .padding(DesignConstants.Spacing.step5x)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.colorBackgroundRaisedSecondary, in: .rect(cornerRadius: DesignConstants.CornerRadius.large))
        .overlay {
            RoundedRectangle(cornerRadius: DesignConstants.CornerRadius.large)
                .stroke(Color.colorBorderSubtle, lineWidth: 0.5)
        }
        .accessibilityIdentifier("your-space-bring-agent-callout")
    }

    private var footprintWidget: some View {
        VStack(alignment: .leading, spacing: DesignConstants.Spacing.step4x) {
            Text("Your Space footprint")
                .font(.title2.weight(.bold))
                .foregroundStyle(.colorTextPrimary)

            HStack(spacing: 0) {
                footprintValue("\(briefing.sourceCount)", label: "Convos")
                Divider().frame(height: 44)
                footprintValue("\(briefing.peopleCount)", label: "People")
                Divider().frame(height: 44)
                footprintValue("\(briefing.attentionCount)", label: "Need a look")
            }
            .padding(.vertical, DesignConstants.Spacing.step4x)
            .background(Color.colorBackgroundRaisedSecondary, in: .rect(cornerRadius: DesignConstants.CornerRadius.medium))
        }
    }

    private func footprintValue(_ value: String, label: String) -> some View {
        VStack(spacing: DesignConstants.Spacing.stepX) {
            Text(value)
                .font(.title2.weight(.bold))
                .monospacedDigit()
            Text(label)
                .font(.caption)
                .foregroundStyle(.colorTextSecondary)
                .lineLimit(1)
        }
        .frame(maxWidth: .infinity)
        .accessibilityElement(children: .combine)
    }

    private var contextPromise: some View {
        VStack(alignment: .leading, spacing: DesignConstants.Spacing.step2x) {
            Label("Nothing leaves without you", systemImage: "hand.raised.fill")
                .font(.headline)
                .foregroundStyle(.colorTextPrimary)
            Text("Your Space connects context privately. Sharing opens the chosen convo with a draft for you to review; it never sends automatically.")
                .font(.body)
                .foregroundStyle(.colorTextSecondary)
        }
        .padding(.bottom, DesignConstants.Spacing.step8x)
    }

    private var bottomBar: some View {
        agentDock
            .padding(.horizontal, DesignConstants.Spacing.step4x)
            .padding(.bottom, DesignConstants.Spacing.step2x)
    }

    private var agentDock: some View {
        dockSurface(
            dockContent
                .padding(.horizontal, DesignConstants.Spacing.step4x)
                .padding(.vertical, DesignConstants.Spacing.step3x)
        )
        .contentShape(.capsule)
        .matchedTransitionSource(id: Constant.agentDockTransitionId, in: transitionNamespace)
        .simultaneousGesture(TapGesture(count: 2).onEnded { toggleDockTheme() })
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("your-space-agent-dock")
    }

    private func dockSurface(_ content: some View) -> some View {
        let glass: Glass = dockInvertedTheme ? .regular.tint(Color(white: 0.078)) : .regular
        return content.glassEffect(glass, in: .capsule)
    }

    private func toggleDockTheme() {
        withAnimation(.easeInOut(duration: 0.2)) {
            dockInvertedTheme.toggle()
        }
    }

    private var dockPrimaryTextColor: Color {
        dockInvertedTheme ? .white : .colorTextPrimary
    }

    private var dockSecondaryTextColor: Color {
        dockInvertedTheme ? Color(white: 0.6) : .colorTextSecondary
    }

    private var dockNeutralButtonColor: Color {
        dockInvertedTheme ? Color(white: 0.3) : .colorFillTertiary
    }

    private var dockNeutralButtonIconColor: Color {
        dockInvertedTheme ? .white : .colorTextPrimaryInverted
    }

    private var dockOnPrimaryColor: Color {
        dockInvertedTheme ? .black : .colorTextPrimaryInverted
    }

    @ViewBuilder
    private var dockContent: some View {
        if dockRecordingActive {
            dockRecordingBar
        } else {
            dockIdleContent
        }
    }

    private var dockIdleContent: some View {
        HStack(spacing: DesignConstants.Spacing.step2x) {
            agentDockIdentity

            dockIdentityText
                .frame(maxWidth: .infinity, alignment: .leading)

            dockChatButton
            dockVoiceButton
        }
    }

    private var dockRecordingBar: some View {
        HStack(spacing: DesignConstants.Spacing.step2x) {
            HStack(spacing: DesignConstants.Spacing.step3x) {
                Text(formattedRecordingDuration)
                    .font(.system(size: 17))
                    .monospacedDigit()
                    .foregroundStyle(dockSecondaryTextColor)

                dockWaveform
                    .frame(maxWidth: .infinity)
            }
            .padding(.leading, DesignConstants.Spacing.step2x)
            .frame(maxWidth: .infinity)

            Button {
                finishDockRecording(openChat: true)
            } label: {
                Image(systemName: "stop.fill")
                    .font(.body.weight(.semibold))
                    .foregroundStyle(dockNeutralButtonIconColor)
                    .frame(width: 44, height: 44)
                    .background(dockNeutralButtonColor, in: .circle)
            }
            .buttonStyle(.plain)
            .disabled(dockTranscribing)
            .accessibilityLabel("Stop and edit in chat")
            .accessibilityIdentifier("your-space-recording-stop-button")

            Button {
                finishDockRecording(openChat: false)
            } label: {
                Image(systemName: "arrow.up")
                    .font(.body.weight(.bold))
                    .foregroundStyle(dockOnPrimaryColor)
                    .frame(width: 44, height: 44)
                    .background(dockPrimaryTextColor, in: .circle)
            }
            .buttonStyle(.plain)
            .disabled(dockTranscribing)
            .accessibilityLabel("Send to your agent")
            .accessibilityIdentifier("your-space-recording-send-button")
        }
    }

    private var dockWaveform: some View {
        let barColor: Color = dockPrimaryTextColor
        return Canvas { context, size in
            let barWidth: CGFloat = 2
            let barSpacing: CGFloat = 1.5
            let totalBarWidth: CGFloat = barWidth + barSpacing
            let visibleBarCount: Int = max(Int(size.width / totalBarWidth), 1)
            let levels: [Float] = dockRecorder.audioLevels
            let placeholderHeight: CGFloat = 2
            let recordedCount: Int = min(levels.count, visibleBarCount)
            let startIndex: Int = max(levels.count - visibleBarCount, 0)

            for i in 0 ..< visibleBarCount {
                let x: CGFloat = CGFloat(i) * totalBarWidth
                let barIndex: Int = i - (visibleBarCount - recordedCount)
                if barIndex >= 0, barIndex + startIndex < levels.count {
                    let level: CGFloat = CGFloat(levels[startIndex + barIndex])
                    let height: CGFloat = max(size.height * level, placeholderHeight)
                    let rect = CGRect(x: x, y: (size.height - height) / 2, width: barWidth, height: height)
                    context.fill(Path(roundedRect: rect, cornerRadius: barWidth / 2), with: .color(barColor))
                } else {
                    let rect = CGRect(x: x, y: (size.height - placeholderHeight) / 2, width: barWidth, height: placeholderHeight)
                    context.fill(Path(roundedRect: rect, cornerRadius: barWidth / 2), with: .color(barColor.opacity(0.3)))
                }
            }
        }
        .frame(height: 24)
    }

    private var formattedRecordingDuration: String {
        let total: Int = Int(dockRecorder.duration)
        return String(format: "%02d:%02d", total / 60, total % 60)
    }

    @ViewBuilder
    private var agentDockIdentity: some View {
        if activePersonalAgent != nil {
            Menu {
                agentSwitcherMenuContent
            } label: {
                agentDockAvatar
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Switch personal agent")
            .accessibilityIdentifier("your-space-agent-switcher")
        } else {
            Button {
                presentPersonalAgentOnboarding()
            } label: {
                agentDockAvatar
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Connect a personal agent")
        }
    }

    private var dockIdentityText: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text(dockTitle)
                .font(.system(size: 17, weight: .medium))
                .foregroundStyle(dockPrimaryTextColor)
                .lineLimit(1)
            Text(dockSubtitle)
                .font(.system(size: 13))
                .foregroundStyle(dockSecondaryTextColor)
                .lineLimit(1)
        }
        .accessibilityElement(children: .combine)
    }

    @ViewBuilder
    private var agentDockAvatar: some View {
        agentDockAvatarBadge
            .simultaneousGesture(
                LongPressGesture(minimumDuration: 0.5).onEnded { _ in
                    toggleMockAgent()
                }
            )
    }

    @ViewBuilder
    private var agentDockAvatarBadge: some View {
        if let provider = activePersonalAgent {
            personalAgentBadge(provider, size: 44)
        } else {
            Image(systemName: "powerplug.fill")
                .font(.body.weight(.semibold))
                .foregroundStyle(.colorTextPrimaryInverted)
                .frame(width: 44, height: 44)
                .background(.colorTextPrimary, in: .circle)
        }
    }

    private func toggleMockAgent() {
        guard FeatureFlags.shared.isMockConnectedAgentEnabled else { return }
        mockAgentProvider = isMockAgentActive ? nil : .town
    }

    private var dockChatButton: some View {
        Button {
            openPersonalAgent(mode: .chat)
        } label: {
            Image(systemName: "message.fill")
                .font(.body.weight(.semibold))
                .foregroundStyle(dockNeutralButtonIconColor)
                .frame(width: 44, height: 44)
                .background(dockNeutralButtonColor, in: .circle)
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Chat with \(activePersonalAgentName ?? "your agent")")
        .accessibilityIdentifier("your-space-chat-button")
    }

    private var dockVoiceButton: some View {
        Button {
            startDockRecording()
        } label: {
            Image(systemName: "microphone.fill")
                .font(.body.weight(.semibold))
                .foregroundStyle(.colorTextPrimaryInverted)
                .frame(width: 44, height: 44)
                .background(.colorLava, in: .circle)
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Talk to \(activePersonalAgentName ?? "your agent")")
        .accessibilityIdentifier("your-space-voice-button")
    }

    @ViewBuilder
    private var agentSwitcherMenuContent: some View {
        ForEach(personalAgentSelectorHarnesses) { harness in
            Button {
                selectPersonalAgent(harness)
            } label: {
                Text(harness.name)
                Text(harness.provider.switcherSubtitle)
            }
        }

        Divider()

        Button("Manage") {
            presentingManageAgents = true
        }

        Button("Add an agent") {
            presentPersonalAgentOnboarding()
        }
    }

    private var manageAgents: [ManageAgentsView.Agent] {
        personalAgentSelectorHarnesses.map { harness in
            ManageAgentsView.Agent(
                id: harness.id,
                name: harness.name,
                subtitle: harness.provider.switcherSubtitle,
                symbolName: harness.provider.symbolName,
                tint: harness.provider.tint
            )
        }
    }

    private var dockTitle: String {
        activePersonalAgentName ?? "Bring your agent"
    }

    private var dockSubtitle: String {
        guard let activePersonalAgent else { return "Use the AI you choose" }
        return activePersonalAgent.switcherSubtitle
    }

    private func selectPersonalAgent(_ harness: PersonalAgentHarness) {
        if isMockAgentActive {
            mockAgentProvider = harness.provider
            return
        }
        personalAgentProviderRawValue = harness.provider.rawValue
        if let grokBotAgent = harness.grokBotAgent {
            personalGrokBotAgentId = grokBotAgent.id
        }
        if !harness.provider.hasStoredConnection || (harness.provider == .grokBot && harness.grokBotAgent == nil) {
            presentPersonalAgentOnboarding(for: harness.provider)
        }
    }

    private func selectPersonalAgent(id: String) {
        guard let harness = personalAgentSelectorHarnesses.first(where: { $0.id == id }) else { return }
        selectPersonalAgent(harness)
    }

    private func addAgentFromChat() {
        inputMode = nil
        Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(350))
            presentPersonalAgentOnboarding()
        }
    }

    private var accessibilityActions: some View {
        VStack(spacing: DesignConstants.Spacing.step3x) {
            Menu {
                toolsMenuContent
            } label: {
                Label("More in Your Space", systemImage: "ellipsis.circle")
                    .font(.headline)
                    .frame(maxWidth: .infinity, minHeight: 52)
            }
            .buttonStyle(.bordered)
            .accessibilityIdentifier("your-space-tools-menu")

            Button {
                openPersonalAgent(mode: .voice)
            } label: {
                HStack(spacing: DesignConstants.Spacing.step3x) {
                    Image(systemName: "waveform")
                        .font(.headline.weight(.semibold))
                    VStack(alignment: .leading, spacing: DesignConstants.Spacing.stepHalf) {
                        Text("Ask your agent")
                            .font(.headline)
                        Text("Make, edit, or find anything")
                            .font(.caption)
                            .foregroundStyle(Color.colorTextPrimaryInverted.opacity(0.78))
                    }
                    Spacer()
                }
                .padding(.horizontal, DesignConstants.Spacing.step4x)
                .frame(maxWidth: .infinity, minHeight: 60)
            }
            .buttonStyle(.borderedProminent)
            .tint(.colorLava)
            .accessibilityLabel("Ask your agent to make, edit, or find anything")
            .accessibilityIdentifier("your-space-voice-button")

            Button {
                openPersonalAgent(mode: .chat)
            } label: {
                Label("Chat with Your Space", systemImage: "message.fill")
                    .font(.headline)
                    .frame(maxWidth: .infinity, minHeight: 52)
            }
            .buttonStyle(.bordered)
            .accessibilityIdentifier("your-space-chat-button")
        }
        .frame(maxWidth: 520)
    }

    @ViewBuilder
    private var toolsMenuContent: some View {
        Button("Bring personal agents", systemImage: "sparkles") {
            presentPersonalAgentOnboarding()
        }

        Divider()

        Button("Connections", systemImage: "link") {
            toolDestination = .connections
        }
        Button("Upload files", systemImage: "doc.badge.plus") {
            presentingFileImporter = true
        }
        Button("Files", systemImage: "folder") {
            toolDestination = .files
        }

        Divider()

        Button("Add a widget", systemImage: "rectangle.stack.badge.plus") {
            toolDestination = .widgets
        }
        Button("Connected convos", systemImage: "bubble.left.and.bubble.right.fill") {
            toolDestination = .connectedConvos
        }
    }

    private func personalAgentBadge(_ provider: ExternalAgentProvider, size: CGFloat) -> some View {
        Image(systemName: provider.symbolName)
            .font(.system(size: size * 0.36, weight: .semibold))
            .foregroundStyle(Color.white)
            .frame(width: size, height: size)
            .background(provider.tint, in: .circle)
            .accessibilityHidden(true)
    }

    private var personalAgentConnectionSubtitle: String {
        guard let activePersonalAgent else { return "Make, edit, or find anything" }
        if activePersonalAgent == .codex {
            return codexConnectionConfiguration == nil
                ? "Reconnect Codex to your Mac"
                : "Connected to your Mac · Your Space context"
        }
        if activePersonalAgent == .town {
            return TownConnectionStore.configuration() == nil
                ? "Reconnect your Town routine"
                : "Live · Town memory and tools"
        }
        if activePersonalAgent == .tasklet {
            return TaskletConnectionStore.configuration() == nil
                ? "Reconnect your Tasklet agent"
                : "Live · Tasklet memory and tools"
        }
        if activePersonalAgent == .grokBot {
            guard GrokBotConnectionStore.configuration() != nil else {
                return "Reconnect your Grok Bot computer"
            }
            return activeGrokBotAgent == nil
                ? "Choose a Grokbot to add"
                : "Live · Private agent on your computer"
        }
        return "Connection preview"
    }

    private var personalAgentSelectorProviders: [ExternalAgentProvider] {
        if isMockAgentActive {
            return [.town, .tasklet, .claudeCode]
        }
        var providers = personalAgentState.connectedExternalProviders
        for provider in AddedExternalAgentStore.providers() where !providers.contains(provider) {
            providers.append(provider)
        }
        if let activePersonalAgent,
           activePersonalAgent.connectionAvailability == .live,
           !providers.contains(activePersonalAgent) {
            providers.append(activePersonalAgent)
        }
        return providers.sorted { lhs, rhs in
            (ExternalAgentProvider.allCases.firstIndex(of: lhs) ?? .max)
                < (ExternalAgentProvider.allCases.firstIndex(of: rhs) ?? .max)
        }
    }

    private var personalAgentSelectorHarnesses: [PersonalAgentHarness] {
        personalAgentSelectorProviders.flatMap { provider in
            guard provider == .grokBot else {
                return [PersonalAgentHarness(provider: provider, grokBotAgent: nil)]
            }
            let agents = GrokBotConnectionStore.configuration()?.enabledAgents ?? []
            if agents.isEmpty {
                return [PersonalAgentHarness(provider: provider, grokBotAgent: nil)]
            }
            return agents.map { PersonalAgentHarness(provider: provider, grokBotAgent: $0) }
        }
    }

    private var personalAgentSectionActionTitle: String {
        guard let activePersonalAgent else { return "Connect a personal agent" }
        let name = activePersonalAgentName ?? activePersonalAgent.displayName
        return activePersonalAgent.hasStoredConnection && (activePersonalAgent != .grokBot || activeGrokBotAgent != nil)
            ? "Talk to \(name) privately"
            : "Reconnect \(name)"
    }

    @ViewBuilder
    private func pushedConversationDestination(viewModel convoViewModel: ConversationViewModel) -> some View {
        let isReadOnly = viewModel.staleDeviceObserver.isDeviceRemoved
        ConversationPresenter(
            viewModel: convoViewModel,
            focusCoordinator: viewModel.focusCoordinator,
            insetsTopSafeArea: true,
            isReadOnly: isReadOnly,
            sidebarColumnWidth: $sidebarWidth,
            appIndicatorContext: nil,
            sharedIndicatorNamespace: appIndicatorContext.sharedIndicatorNamespace,
            rendersConversationIndicator: false
        ) { focusBinding, coordinator in
            ConversationView(
                viewModel: convoViewModel,
                profileSettingsViewModel: profileSettingsViewModel,
                focusState: focusBinding,
                focusCoordinator: coordinator,
                onScanInviteCode: {},
                onDeleteConversation: {},
                messagesTopBarTrailingItem: .share,
                messagesTopBarTrailingItemEnabled: !convoViewModel.conversation.isPendingInvite,
                messagesTextFieldEnabled: !convoViewModel.conversation.isPendingInvite,
                isReadOnly: isReadOnly,
                initialAgentDmInboxId: viewModel.selectedInitialAgentDmInboxId,
                onStageTextInConversation: stageAgentText(_:in:),
                bottomBarContent: { EmptyView() }
            )
        }
    }

    private func stageAgentText(_ text: String, in conversation: Conversation) {
        selectConversation(conversation)
        guard let composer = viewModel.selectedConversationViewModel else { return }
        let current = composer.messageText.trimmingCharacters(in: .whitespacesAndNewlines)
        let incoming = text.trimmingCharacters(in: .whitespacesAndNewlines)
        composer.messageText = current.isEmpty ? incoming : "\(current)\n\n\(incoming)"
    }

    private func selectConversation(_ conversation: Conversation) {
        presentingSwitcher = false
        withAnimation(reduceMotion ? nil : .smooth(duration: 0.25)) {
            viewModel.select(conversation)
        }
    }

    private func handleFileImport(_ result: Result<[URL], Error>) {
        switch result {
        case let .success(urls):
            guard !urls.isEmpty else { return }
            Task {
                let outcome = await Task.detached(priority: .userInitiated) {
                    YourSpaceFileStore.importFiles(urls)
                }.value
                fileImportNotice = YourSpaceFileImportNotice(outcome: outcome)
                refreshLocalContext()
            }
        case let .failure(error):
            fileImportNotice = YourSpaceFileImportNotice(error: error)
        }
    }

    private func dismissSwitcher() {
        withAnimation(reduceMotion ? nil : .snappy(duration: 0.22)) {
            presentingSwitcher = false
        }
        switcherButtonAccessibilityFocused = true
    }

    private func refreshLocalContext(selecting _: YourSpaceStoredFile? = nil) {
        localContextFiles = YourSpaceFileStore.storedFiles()
    }

    private func connectPersonalAgent(_ provider: ExternalAgentProvider) {
        personalAgentState.connect(provider)
        AddedExternalAgentStore.remember(provider)
        personalAgentProviderRawValue = provider.rawValue
        if provider == .grokBot,
           let firstAgent = GrokBotConnectionStore.configuration()?.enabledAgents.first {
            personalGrokBotAgentId = firstAgent.id
        }
        onboardingInitialProvider = nil
        presentingPersonalAgentOnboarding = false
    }

    private func restorePersonalAgentIfNeeded() {
        personalAgentState.restoreExternalConnections()
        for provider in personalAgentState.connectedExternalProviders {
            AddedExternalAgentStore.remember(provider)
        }
        if let provider = activePersonalAgent,
           provider.connectionAvailability == .live {
            if provider.hasStoredConnection {
                personalAgentState.connect(provider)
            }
            if provider == .grokBot,
               activeGrokBotAgent == nil,
               let firstAgent = GrokBotConnectionStore.configuration()?.enabledAgents.first {
                personalGrokBotAgentId = firstAgent.id
            }
            return
        }
        if let firstConnected = personalAgentState.connectedExternalProviders.first {
            personalAgentProviderRawValue = firstConnected.rawValue
            if firstConnected == .grokBot,
               let firstAgent = GrokBotConnectionStore.configuration()?.enabledAgents.first {
                personalGrokBotAgentId = firstAgent.id
            }
        } else {
            personalAgentProviderRawValue = ""
        }
    }

    private func handlePersonalAgentSectionAction() {
        openPersonalAgent(mode: .chat)
    }

    private func openPersonalAgent(mode: YourSpaceInputMode) {
        if mode == .chat {
            pendingChatDraft = ""
        }
        if isMockAgentActive {
            inputMode = mode
            return
        }
        guard let activePersonalAgent else {
            presentPersonalAgentOnboarding()
            return
        }
        guard activePersonalAgent.hasStoredConnection else {
            presentPersonalAgentOnboarding(for: activePersonalAgent)
            return
        }
        if activePersonalAgent == .grokBot, activeGrokBotAgent == nil {
            presentPersonalAgentOnboarding(for: .grokBot)
            return
        }
        inputMode = mode
    }

    private var canUsePersonalAgent: Bool {
        if isMockAgentActive { return true }
        guard let activePersonalAgent, activePersonalAgent.hasStoredConnection else { return false }
        if activePersonalAgent == .grokBot, activeGrokBotAgent == nil { return false }
        return true
    }

    private func startDockRecording() {
        guard canUsePersonalAgent else {
            openPersonalAgent(mode: .voice)
            return
        }
        guard case .idle = dockRecorder.state else { return }
        Task {
            guard await VoiceMemoRecorder.ensureRecordPermission() else {
                shareNotice = YourSpaceShareNotice(
                    title: "Microphone access needed",
                    message: "Allow microphone access in Settings to talk to your agent. You can still use chat."
                )
                return
            }
            do {
                try dockRecorder.startRecording()
                dockRecordingActive = true
            } catch {
                shareNotice = YourSpaceShareNotice(title: "Couldn't start listening", message: error.localizedDescription)
            }
        }
    }

    private func finishDockRecording(openChat: Bool) {
        guard !dockTranscribing else { return }
        dockRecorder.stopRecording()
        guard case let .recorded(url, _) = dockRecorder.state else {
            cancelDockRecording()
            return
        }
        dockTranscribing = true
        let messageId: String = UUID().uuidString
        Task {
            do {
                let transcript: String = try await dockTranscriber.transcribe(messageId: messageId, fileURL: url)
                dockRecorder.cancelRecording()
                dockTranscribing = false
                dockRecordingActive = false
                handleDockTranscript(transcript, openChat: openChat)
            } catch {
                dockTranscribing = false
                cancelDockRecording()
                shareNotice = YourSpaceShareNotice(
                    title: "Couldn't understand that",
                    message: "Try recording again or use chat instead. \(error.localizedDescription)"
                )
            }
        }
    }

    private func cancelDockRecording() {
        dockRecorder.cancelRecording()
        dockRecordingActive = false
    }

    private func handleDockTranscript(_ transcript: String, openChat: Bool) {
        let trimmed: String = transcript.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        if openChat {
            pendingChatDraft = trimmed
            inputMode = .chat
        } else if let request = activeAgentRequest {
            Task { _ = try? await request(trimmed) }
        }
    }

    private func presentPersonalAgentOnboarding(for provider: ExternalAgentProvider? = nil) {
        onboardingInitialProvider = provider
        presentingPersonalAgentOnboarding = true
    }

    private func saveAgentOutput(_ output: String) throws -> YourSpaceContextItem {
        let agentName = activePersonalAgentName ?? "Your Space agent"
        let file = try YourSpaceFileStore.storeText(output, title: "\(agentName) output")
        refreshLocalContext(selecting: file)
        return YourSpaceContextItem(local: file)
    }

    private func saveAgentLink(_ url: URL) throws -> YourSpaceContextItem {
        let file = try YourSpaceFileStore.storeLink(url)
        refreshLocalContext(selecting: file)
        return YourSpaceContextItem(local: file)
    }

    private func askTownAgent(_ prompt: String) async throws -> String {
        guard let configuration = TownConnectionStore.configuration() else {
            throw TownConnectionError.notConnected
        }
        let snapshot = TownYourSpaceSnapshot(
            briefing: briefing,
            contextItems: allContextItems,
            conversationTitle: conversationTitle,
            senderName: senderName
        )
        return try await TownBridgeClient().send(
            prompt,
            configuration: configuration,
            yourSpaceSnapshot: snapshot
        ).shareText
    }

    private func askTaskletAgent(_ prompt: String) async throws -> String {
        guard let configuration = TaskletConnectionStore.configuration() else {
            throw TaskletConnectionError.notConnected
        }
        let snapshot = TaskletYourSpaceSnapshot(
            briefing: briefing,
            contextItems: allContextItems,
            conversationTitle: conversationTitle,
            senderName: senderName
        )
        return try await TaskletBridgeClient().send(
            prompt,
            configuration: configuration,
            yourSpaceSnapshot: snapshot
        ).shareText
    }

    private func askGrokBotAgent(_ prompt: String, agent: GrokBotAgent) async throws -> String {
        guard let configuration = GrokBotConnectionStore.configuration() else {
            throw GrokBotConnectionError.notConnected
        }
        let snapshot = GrokBotYourSpaceSnapshot(
            briefing: briefing,
            contextItems: allContextItems,
            conversationTitle: conversationTitle,
            senderName: senderName
        )
        return try await GrokBotBridgeClient().send(
            prompt,
            to: agent,
            configuration: configuration,
            yourSpaceSnapshot: snapshot
        ).shareText
    }

    private func shareAgentOutput(_ item: YourSpaceContextItem) {
        inputMode = nil
        Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(350))
            sharingItem = item
        }
    }

    private func conversationTitle(_ id: String) -> String? {
        conversations
            .first(where: { $0.id == id })?
            .computedDisplayName(memberNameOverride: contactNameOverride)
    }

    private func senderName(_ inboxId: String) -> String? {
        if let name = contactNameOverride(inboxId) { return name }
        return conversations
            .lazy
            .flatMap(\.membersWithoutCurrent)
            .first(where: { $0.profile.inboxId == inboxId })?
            .displayName(contactNameFallback: contactNameOverride)
    }

    private func shareFromContextBrowser(_ item: YourSpaceContextItem) {
        browsingContextKind = nil
        Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(350))
            sharingItem = item
        }
    }

    private func openConversationFromContextBrowser(_ conversationId: String) {
        guard let conversation = conversations.first(where: { $0.id == conversationId }) else { return }
        browsingContextKind = nil
        Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(350))
            viewModel.select(conversation)
        }
    }

    private func messageSenderFromContextBrowser(_ inboxId: String) {
        browsingContextKind = nil
        Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(350))
            viewModel.messagePerson(inboxId: inboxId)
        }
    }

    private func shareRememberedField(_ field: YourSpaceRememberedField) {
        presentingPersonalCard = false
        Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(350))
            sharingItem = YourSpaceContextItem(rememberedField: field)
        }
    }

    private func addFromContextBrowser() {
        browsingContextKind = nil
        Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(350))
            presentingAddContext = true
        }
    }

    private func stage(_ item: YourSpaceContextItem, in conversation: Conversation) {
        sharingItem = nil
        selectConversation(conversation)
        Task { @MainActor in
            do {
                guard let composer = viewModel.selectedConversationViewModel else {
                    throw YourSpaceShareError.composerUnavailable
                }
                try await YourSpaceShareStager.live.stage(item, in: composer)
            } catch {
                shareNotice = YourSpaceShareNotice(error: error)
            }
        }
    }

    private enum Constant {
        static let agentDockTransitionId: String = "your-space-agent-dock"
    }
}

private struct YourSpaceShareNotice: Identifiable {
    let id: UUID = UUID()
    let title: String
    let message: String

    init(error: Error) {
        title = "Couldn't prepare that share"
        message = error.localizedDescription
    }

    init(title: String, message: String) {
        self.title = title
        self.message = message
    }
}

private struct YourSpaceUpdateRow: View {
    let update: YourSpaceUpdate
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(alignment: .top, spacing: DesignConstants.Spacing.step4x) {
                ConversationAvatarView(
                    conversation: update.conversation,
                    conversationImage: nil,
                    size: 44
                )
                .frame(width: 44, height: 44)

                VStack(alignment: .leading, spacing: DesignConstants.Spacing.stepX) {
                    Text(update.personName ?? "New in \(update.conversationTitle)")
                        .font(.headline)
                        .foregroundStyle(.colorTextPrimary)
                    Text(update.detail)
                        .font(.body)
                        .foregroundStyle(.colorTextPrimary)
                        .lineLimit(3)
                        .multilineTextAlignment(.leading)
                    HStack(spacing: DesignConstants.Spacing.stepX) {
                        if update.personName != nil {
                            Text(update.conversationTitle)
                            Text("·")
                        }
                        Text(update.date, style: .relative)
                    }
                    .font(.caption)
                    .foregroundStyle(.colorTextSecondary)
                    .lineLimit(1)
                }
                .frame(maxWidth: .infinity, alignment: .leading)

                if update.needsAttention {
                    Circle()
                        .fill(Color.colorLava)
                        .frame(width: 8, height: 8)
                        .padding(.top, DesignConstants.Spacing.step2x)
                        .accessibilityHidden(true)
                }
            }
            .padding(.vertical, DesignConstants.Spacing.step4x)
            .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(update.personName ?? update.conversationTitle), \(update.detail), in \(update.conversationTitle)")
        .accessibilityValue(update.needsAttention ? "Needs attention" : "")
    }
}

private struct YourSpaceAgentConvoEntry: Identifiable {
    let conversation: Conversation
    let agent: ConversationMember

    var id: String { "\(conversation.id):\(agent.profile.inboxId)" }
}

#if DEBUG
private extension YourSpaceView {
    static let visualFixtureConversations: [Conversation] = {
        let studio = Conversation.mock(
            id: "your-space-studio",
            name: "Studio",
            isUnread: true,
            lastMessageText: "Molly: The launch notes are ready"
        )
        let nash = Conversation.mock(
            id: "your-space-nash",
            name: "Nash",
            isUnread: true,
            lastMessageText: "Nick: Dropped his favorite restaurants"
        )
        let newYorkTrip = Conversation.mock(
            id: "your-space-new-york",
            name: "New York Trip",
            isUnread: true,
            lastMessageText: "Saul: Added 13 places for Saturday"
        )
        let family = Conversation.mock(
            id: "your-space-family",
            name: "Family",
            isUnread: false
        )
        return [newYorkTrip, nash, studio, family]
    }()

    static let visualFixtureContextItems: [YourSpaceContextItem] = [
        ContextLibraryItem(
            id: "fixture-address",
            kind: .address,
            title: "3728 Bear Hollow Rd, Joelton, TN 37080",
            date: Date().addingTimeInterval(-600),
            conversationId: "your-space-nash",
            senderInboxId: visualFixtureConversations
                .first(where: { $0.id == "your-space-nash" })?
                .membersWithoutCurrent.first?.profile.inboxId,
            isMine: false,
            attachmentKey: nil,
            filename: nil,
            mimeType: nil,
            thumbnailDataBase64: nil,
            destinationURLString: nil,
            imageURLString: nil,
            messageText: "This is the cabin address for the Nashville weekend. Use the gravel entrance after the bridge."
        ),
        ContextLibraryItem(
            id: "fixture-link",
            kind: .link,
            title: "Saturday in the Lower East Side",
            date: Date().addingTimeInterval(-900),
            conversationId: "your-space-new-york",
            senderInboxId: nil,
            isMine: false,
            attachmentKey: nil,
            filename: nil,
            mimeType: nil,
            thumbnailDataBase64: nil,
            destinationURLString: "https://example.com/new-york",
            imageURLString: nil
        ),
        ContextLibraryItem(
            id: "fixture-photo",
            kind: .photo,
            title: "menu-notes.jpg",
            date: Date().addingTimeInterval(-1_800),
            conversationId: "your-space-nash",
            senderInboxId: nil,
            isMine: false,
            attachmentKey: nil,
            filename: "menu-notes.jpg",
            mimeType: "image/jpeg",
            thumbnailDataBase64: nil,
            destinationURLString: nil,
            imageURLString: nil
        ),
        ContextLibraryItem(
            id: "fixture-document",
            kind: .file,
            title: "Launch notes.pdf",
            date: Date().addingTimeInterval(-3_600),
            conversationId: "your-space-studio",
            senderInboxId: nil,
            isMine: true,
            attachmentKey: nil,
            filename: "Launch notes.pdf",
            mimeType: "application/pdf",
            thumbnailDataBase64: nil,
            destinationURLString: nil,
            imageURLString: nil
        ),
    ].map(YourSpaceContextItem.init(conversation:))
}
#endif

private struct YourSpaceLoadingView: View {
    var body: some View {
        VStack(alignment: .leading, spacing: DesignConstants.Spacing.step6x) {
            ProgressView()
            Text("Connecting your private context…")
                .font(.title2.weight(.semibold))
                .foregroundStyle(.colorTextPrimary)
            Text("Your convos stay on this device while Your Space gets ready.")
                .font(.body)
                .foregroundStyle(.colorTextSecondary)
        }
        .frame(maxWidth: 560, maxHeight: .infinity, alignment: .leading)
        .padding(DesignConstants.Spacing.step6x)
        .accessibilityElement(children: .combine)
        .accessibilityLabel("Connecting your private context")
    }
}

#Preview("Your Space") {
    @Previewable @Namespace var namespace
    @Previewable @State var viewModel = ConversationsViewModel.preview(
        conversations: [
            .mock(id: "nyc", name: "New York Trip", isUnread: true, lastMessageText: "Saul: Added 13 places for Saturday"),
            .mock(id: "nash", name: "Nash", isUnread: true, lastMessageText: "Nick: Dropped his favorite restaurants"),
            .mock(id: "studio", name: "Studio", isUnread: true, lastMessageText: "Molly: The launch notes are ready"),
            .mock(id: "family", name: "Family", isUnread: false)
        ]
    )
    let profile = ProfileSettingsViewModel.shared

    NavigationStack {
        YourSpaceView(
            viewModel: viewModel,
            profileSettingsViewModel: profile,
            appIndicatorContext: AppIndicatorContext(profileImage: profile.profileImage),
            transitionNamespace: namespace,
            onOpenSettings: {}
        )
    }
}
