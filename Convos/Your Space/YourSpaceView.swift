/*
 THESIS: Your Space is a private context home, not a chat inbox; the personal library leads and conversation rows live in an anchored title switcher.
 OWN-WORLD: Native Convos neutrals, one inverted attention surface, circular identity, glass reserved for persistent controls, and open editorial spacing.
 STORY: On launch the user learns what changed, sees what they own across every convo, makes new context, and stages any item into a chosen convo only by choice.
 FIRST VIEWPORT: Profile, anchored Your Space switcher, and add menu sit above the live briefing, attention action, and the start of the personal context library.
 FORM: A living cross-conversation digest using the pinned shell recorded as YS-SHELL-2026-08-18; no generated concept seed was used.
 FINISH: unreviewed and undocumented is unfinished; this build ends with the finish review, the verdict, and DESIGN.md
 */

import Combine
import ConvosComposer
import ConvosCore
import SwiftUI

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
    @State private var personalAgentState: AgentChatPrototypeState = .init()
    @State private var presentingFileImporter: Bool = false
    @State private var fileImportNotice: YourSpaceFileImportNotice?
    @State private var localContextFiles: [YourSpaceStoredFile] = YourSpaceFileStore.storedFiles()
    @State private var conversationContextItems: [ContextLibraryItem] = []
    @State private var rememberedFields: [YourSpaceRememberedField] = YourSpaceRememberedFieldStore.fields()
    @State private var browsingContextKind: YourSpaceContextKind?
    @State private var presentingAddContext: Bool = false
    @State private var presentingPersonalCard: Bool = false
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
    @AppStorage("your-space-agent-callout-dismissed") private var agentCalloutDismissed: Bool = false

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

    private var activePersonalAgent: ExternalAgentProvider? {
        ExternalAgentProvider(rawValue: personalAgentProviderRawValue)
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
            .background(Color.colorBackgroundSurfaceless)
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
            .sheet(item: $inputMode) { mode in
                YourSpaceInputSheet(
                    mode: mode,
                    briefing: briefing,
                    contextItems: allContextItems,
                    agentName: activePersonalAgent?.displayName,
                    codexConfiguration: codexConnectionConfiguration,
                    codexSnapshot: codexYourSpaceSnapshot,
                    onSaveOutput: saveAgentOutput,
                    onSaveLink: saveAgentLink,
                    onShareOutput: shareAgentOutput
                )
                .presentationDetents([.large])
                .presentationDragIndicator(.visible)
            }
            .fullScreenCover(isPresented: $presentingPersonalAgentOnboarding) {
                ExternalAgentOnboardingView(
                    prototypeState: personalAgentState,
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
                    briefingHero

                    if briefing.attentionCount > 0 {
                        attentionAction
                    }

                    if dynamicTypeSize.isAccessibilitySize {
                        accessibilityActions
                    }

                    if activePersonalAgent == nil, !agentCalloutDismissed {
                        bringYourOwnAgentCallout
                    }

                    if conversations.isEmpty {
                        emptyActions
                    }

                    contextSection

                    if showsPeopleWidget, !activePeople.isEmpty {
                        peopleWidget
                    }

                    if showsAgentsWidget, !agentsAcrossConvos.isEmpty {
                        agentsWidget
                    }

                    if showsFootprintWidget, briefing.sourceCount > 0 {
                        footprintWidget
                    }

                    contextPromise
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
        Button(action: onOpenSettings) {
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
        .matchedTransitionSource(id: "app-settings-transition-source", in: transitionNamespace)
        .accessibilityLabel("Open settings")
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

    private var attentionAction: some View {
        Button {
            guard let first = briefing.attentionUpdates.first else { return }
            selectConversation(first.conversation)
        } label: {
            HStack(spacing: DesignConstants.Spacing.step4x) {
                ZStack {
                    Circle().fill(Color.colorFillInvertedSubtle)
                    Image(systemName: "arrow.up.right")
                        .font(.headline.weight(.semibold))
                }
                .frame(width: 44, height: 44)

                VStack(alignment: .leading, spacing: DesignConstants.Spacing.stepHalf) {
                    Text(attentionTitle)
                        .font(.headline)
                    Text("Start with \(briefing.attentionUpdates[0].conversationTitle)")
                        .font(.subheadline)
                        .foregroundStyle(Color.colorTextPrimaryInverted.opacity(0.72))
                        .lineLimit(1)
                }

                Spacer(minLength: 0)
            }
            .foregroundStyle(.colorTextPrimaryInverted)
            .padding(DesignConstants.Spacing.step4x)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Color.colorBackgroundInverted, in: .rect(cornerRadius: DesignConstants.CornerRadius.medium))
        }
        .buttonStyle(.plain)
        .accessibilityIdentifier("your-space-attention-action")
    }

    private var attentionTitle: String {
        let count = briefing.attentionCount
        return count == 1 ? "One convo needs a look" : "\(count) convos need a look"
    }

    private var contextSection: some View {
        YourSpaceContextSection(
            profile: profileSettingsViewModel.profile,
            profileImage: profileSettingsViewModel.profileImage,
            items: allContextItems,
            connectionCount: viewModel.appSettingsViewModel.connectionsListViewModel.rows.filter(\.isOn).count,
            recentContext: briefing.recentUpdates,
            conversationTitle: conversationTitle,
            senderName: senderName,
            onEditCard: { presentingPersonalCard = true },
            onBrowse: { browsingContextKind = $0 },
            onShare: { sharingItem = $0 },
            onAddContext: { presentingAddContext = true },
            onAddConnections: { toolDestination = .connections }
        )
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

    private var agentsWidget: some View {
        VStack(alignment: .leading, spacing: DesignConstants.Spacing.step4x) {
            VStack(alignment: .leading, spacing: DesignConstants.Spacing.stepX) {
                Text("Agents across your convos")
                    .font(.title2.weight(.bold))
                    .foregroundStyle(.colorTextPrimary)
                Text("Jump straight into a private DM with an agent.")
                    .font(.subheadline)
                    .foregroundStyle(.colorTextSecondary)
            }

            VStack(spacing: 0) {
                ForEach(Array(agentsAcrossConvos.enumerated()), id: \.element.id) { index, entry in
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

                    if index < agentsAcrossConvos.count - 1 {
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
        Button {
            presentingPersonalAgentOnboarding = true
        } label: {
            VStack(alignment: .leading, spacing: DesignConstants.Spacing.step5x) {
                ZStack {
                    RoundedRectangle(cornerRadius: DesignConstants.CornerRadius.medium)
                        .fill(Color.white.opacity(0.08))

                    HStack(spacing: -8) {
                        ForEach(ExternalAgentProvider.allCases) { provider in
                            personalAgentBadge(provider, size: 46)
                                .overlay(Circle().stroke(Color.colorBackgroundInverted, lineWidth: 3))
                        }
                    }
                    .padding(.horizontal, DesignConstants.Spacing.step4x)
                }
                .frame(height: 88)

                VStack(alignment: .leading, spacing: DesignConstants.Spacing.step2x) {
                    Text("Bring your own agent")
                        .font(.title2.weight(.bold))
                        .foregroundStyle(.colorTextPrimaryInverted)
                    Text("Connect the agent you already use to make, edit, find, or understand anything across Your Space—then save and share what it creates.")
                        .font(.subheadline)
                        .foregroundStyle(Color.colorTextPrimaryInverted.opacity(0.76))
                        .fixedSize(horizontal: false, vertical: true)
                }

                HStack {
                    Text("Connect an agent")
                        .font(.subheadline.weight(.semibold))
                    Spacer()
                    Image(systemName: "arrow.up.right")
                        .font(.subheadline.weight(.semibold))
                }
                .foregroundStyle(.colorTextPrimaryInverted)
            }
            .padding(DesignConstants.Spacing.step5x)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(.colorBackgroundInverted, in: .rect(cornerRadius: DesignConstants.CornerRadius.large))
            .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .overlay(alignment: .topTrailing) {
            Button {
                agentCalloutDismissed = true
            } label: {
                Image(systemName: "xmark")
                    .font(.caption.weight(.bold))
                    .foregroundStyle(Color.colorTextPrimaryInverted.opacity(0.82))
                    .frame(width: 44, height: 44)
                    .background(Color.white.opacity(0.08), in: .circle)
            }
            .buttonStyle(.plain)
            .padding(DesignConstants.Spacing.step2x)
            .accessibilityLabel("Hide bring your own agent")
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
        HStack(spacing: DesignConstants.Spacing.step3x) {
            toolsMenu

            agentCommandButton
                .frame(maxWidth: .infinity)

            chatButton
        }
        .foregroundStyle(.colorTextPrimary)
        .padding(.horizontal, DesignConstants.Spacing.step4x)
        .padding(.vertical, DesignConstants.Spacing.step2x)
        .background(.bar.opacity(0.96))
        .overlay(alignment: .top) {
            Divider()
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
                inputMode = .voice
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
                inputMode = .chat
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

    private var toolsMenu: some View {
        Menu {
            toolsMenuContent
        } label: {
            Image(systemName: "ellipsis")
                .font(.headline)
                .frame(width: 44, height: 44)
                .contentShape(.circle)
        }
        .glassEffect(.regular.interactive(), in: .circle)
        .accessibilityLabel("More in Your Space")
        .accessibilityIdentifier("your-space-tools-menu")
    }

    @ViewBuilder
    private var toolsMenuContent: some View {
        Button("Bring your own agent", systemImage: "sparkles") {
            presentingPersonalAgentOnboarding = true
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

    private var agentCommandButton: some View {
        HStack(spacing: DesignConstants.Spacing.stepX) {
            Button {
                inputMode = .voice
            } label: {
                HStack(spacing: DesignConstants.Spacing.step3x) {
                    if let provider = activePersonalAgent {
                        personalAgentBadge(provider, size: 40)
                    } else {
                        Image(systemName: "waveform")
                            .font(.body.weight(.semibold))
                            .foregroundStyle(.colorTextPrimaryInverted)
                            .frame(width: 40, height: 40)
                            .background(.colorLava, in: .circle)
                    }

                    VStack(alignment: .leading, spacing: DesignConstants.Spacing.stepHalf) {
                        Text(activePersonalAgent.map { "Ask \($0.displayName)" } ?? "Ask your agent")
                            .font(.subheadline.weight(.semibold))
                            .foregroundStyle(.colorTextPrimary)
                            .lineLimit(1)
                        Text(activePersonalAgent == nil
                            ? "Make, edit, or find anything"
                            : personalAgentConnectionSubtitle)
                            .font(.caption)
                            .foregroundStyle(.colorTextSecondary)
                            .lineLimit(1)
                            .minimumScaleFactor(0.82)
                    }

                    Spacer(minLength: 0)
                }
                .contentShape(.rect)
            }
            .buttonStyle(.plain)

            if activePersonalAgent != nil {
                Menu {
                    ForEach(personalAgentState.connectedExternalProviders) { provider in
                        Button {
                            personalAgentProviderRawValue = provider.rawValue
                        } label: {
                            Label(
                                provider.displayName,
                                systemImage: provider == activePersonalAgent ? "checkmark" : provider.symbolName
                            )
                        }
                    }

                    Divider()

                    Button("Connect another agent", systemImage: "plus") {
                        presentingPersonalAgentOnboarding = true
                    }
                } label: {
                    Image(systemName: "chevron.up.chevron.down")
                        .font(.caption2.weight(.bold))
                        .foregroundStyle(.colorTextSecondary)
                        .frame(width: 36, height: 44)
                        .contentShape(.rect)
                }
                .accessibilityLabel("Change personal agent")
            }
        }
        .padding(.horizontal, DesignConstants.Spacing.step2x)
        .frame(maxWidth: .infinity, minHeight: 56)
        .background(
            .colorBackgroundRaisedSecondary,
            in: .rect(cornerRadius: DesignConstants.CornerRadius.medium)
        )
        .shadow(color: Color.black.opacity(0.10), radius: 12, x: 0, y: 4)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("your-space-agent-command-bar")
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
        return "Connected demo · Your Space context"
    }

    private var chatButton: some View {
        Button {
            inputMode = .chat
        } label: {
            Image(systemName: "message.fill")
                .font(.body.weight(.semibold))
                .frame(width: 44, height: 44)
                .contentShape(.circle)
        }
        .buttonStyle(.plain)
        .glassEffect(.regular.interactive(), in: .circle)
        .accessibilityLabel("Chat with Your Space")
        .accessibilityIdentifier("your-space-chat-button")
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
        ) { _, coordinator in
            ConversationView(
                viewModel: convoViewModel,
                profileSettingsViewModel: profileSettingsViewModel,
                focusCoordinator: coordinator,
                onScanInviteCode: {},
                onDeleteConversation: {},
                messagesTopBarTrailingItem: .share,
                messagesTopBarTrailingItemEnabled: !convoViewModel.conversation.isPendingInvite,
                messagesTextFieldEnabled: !convoViewModel.conversation.isPendingInvite,
                isReadOnly: isReadOnly,
                initialAgentDmInboxId: viewModel.selectedInitialAgentDmInboxId,
                bottomBarContent: { EmptyView() }
            )
        }
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
        personalAgentProviderRawValue = provider.rawValue
        presentingPersonalAgentOnboarding = false
    }

    private func restorePersonalAgentIfNeeded() {
        guard let provider = activePersonalAgent else { return }
        personalAgentState.connect(provider)
    }

    private func saveAgentOutput(_ output: String) throws -> YourSpaceContextItem {
        let agentName = activePersonalAgent?.displayName ?? "Your Space agent"
        let file = try YourSpaceFileStore.storeText(output, title: "\(agentName) output")
        refreshLocalContext(selecting: file)
        return YourSpaceContextItem(local: file)
    }

    private func saveAgentLink(_ url: URL) throws -> YourSpaceContextItem {
        let file = try YourSpaceFileStore.storeLink(url)
        refreshLocalContext(selecting: file)
        return YourSpaceContextItem(local: file)
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
}

private struct YourSpaceShareNotice: Identifiable {
    let id: UUID = UUID()
    let title: String = "Couldn't prepare that share"
    let message: String

    init(error: Error) {
        message = error.localizedDescription
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
