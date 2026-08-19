/*
 THESIS: Your Space is a private briefing, not a chat inbox; context leads and conversation rows stay behind the title switcher.
 OWN-WORLD: Native Convos neutrals, one inverted attention surface, circular identity, glass reserved for persistent controls, and open editorial spacing.
 STORY: On launch the user learns what changed, sees which convo supplied it and who when verified, acts on attention, and shares only by choice.
 FIRST VIEWPORT: Profile, Your Space switcher, and add menu sit above a large live briefing sentence and one compact attention action.
 FORM: A living cross-conversation digest using the pinned shell recorded as YS-SHELL-2026-08-18; no generated concept seed was used.
 FINISH: unreviewed and undocumented is unfinished; this build ends with the finish review, the verdict, and DESIGN.md
 */

import ConvosComposer
import ConvosCore
import SwiftUI
import UIKit

struct YourSpaceView: View {
    @Bindable var viewModel: ConversationsViewModel
    @Bindable var profileSettingsViewModel: ProfileSettingsViewModel
    let appIndicatorContext: AppIndicatorContext
    let transitionNamespace: Namespace.ID
    let onOpenSettings: () -> Void

    @State private var presentingSwitcher: Bool = false
    @State private var presentingTools: Bool = false
    @State private var presentingShare: Bool = false
    @State private var sidebarWidth: CGFloat = 0.0
    @State private var conversationPendingExplosion: Conversation?
    @State private var staleDeviceSheetDismissed: Bool = false
    @Environment(\.scenePhase) private var scenePhase: ScenePhase
    @Environment(\.accessibilityReduceMotion) private var reduceMotion: Bool
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize: DynamicTypeSize
    @AppStorage("your-space-people-widget") private var showsPeopleWidget: Bool = true
    @AppStorage("your-space-footprint-widget") private var showsFootprintWidget: Bool = false

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
            .background(Color.colorBackgroundSurfaceless)
            .safeAreaInset(edge: .top, spacing: 0) { topBar }
            .safeAreaInset(edge: .bottom, spacing: 0) {
                if !dynamicTypeSize.isAccessibilitySize {
                    bottomBar
                }
            }
            .navigationDestination(item: selectedConversationBinding) { convoViewModel in
                pushedConversationDestination(viewModel: convoViewModel)
            }
            .sheet(isPresented: $presentingSwitcher) {
                YourSpaceConversationSwitcher(
                    conversations: conversations,
                    memberNameOverride: contactNameOverride,
                    onSelectConversation: selectConversation
                )
                .presentationDetents([.medium, .large])
                .presentationDragIndicator(.visible)
            }
            .sheet(isPresented: $presentingTools) {
                YourSpaceToolsSheet(
                    conversations: conversations,
                    memberNameOverride: contactNameOverride,
                    connectionsViewModel: viewModel.appSettingsViewModel.connectionsListViewModel,
                    showsPeopleWidget: $showsPeopleWidget,
                    showsFootprintWidget: $showsFootprintWidget
                )
                .presentationDetents([.medium, .large])
                .presentationDragIndicator(.visible)
            }
            .sheet(isPresented: $presentingShare) {
                YourSpaceShareSheet(
                    updates: briefing.recentUpdates,
                    conversations: conversations,
                    memberNameOverride: contactNameOverride,
                    onContinue: copyAndOpen
                )
                .presentationDetents([.large])
                .presentationDragIndicator(.visible)
            }
            .modifier(ConversationsSheetModifier(
                viewModel: viewModel,
                profileSettingsViewModel: profileSettingsViewModel,
                conversationPendingExplosion: $conversationPendingExplosion,
                staleDeviceSheetDismissed: $staleDeviceSheetDismissed,
                namespace: transitionNamespace
            ))
            .onAppear {
                guard !usesVisualFixture else { return }
                viewModel.activeFilter = .all
                viewModel.onAppear()
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
            .onContinueUserActivity(NSUserActivityTypeBrowsingWeb) { activity in
                if let url = activity.webpageURL { viewModel.handleURL(url) }
            }
            .onOpenURL { viewModel.handleURL($0) }
            .memberContactOverride(contactOverride)
    }

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

                    if briefing.recentUpdates.isEmpty {
                        emptyActions
                    } else {
                        updatesSection
                    }

                    if showsPeopleWidget, !activePeople.isEmpty {
                        peopleWidget
                    }

                    if showsFootprintWidget, briefing.sourceCount > 0 {
                        footprintWidget
                    }

                    if dynamicTypeSize.isAccessibilitySize {
                        accessibilityActions
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
            presentingSwitcher = true
        } label: {
            HStack(spacing: DesignConstants.Spacing.step2x) {
                Text("Your Space")
                    .font(.body.weight(.semibold))
                    .foregroundStyle(.colorTextPrimary)
                Image(systemName: "chevron.down")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.colorTextSecondary)
            }
            .padding(.horizontal, DesignConstants.Spacing.step5x)
            .frame(maxWidth: .infinity, minHeight: 44)
            .contentShape(.capsule)
        }
        .buttonStyle(.plain)
        .glassEffect(.regular.interactive(), in: .capsule)
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

    private var updatesSection: some View {
        VStack(alignment: .leading, spacing: DesignConstants.Spacing.step4x) {
            Text("Since you were here")
                .font(.title2.weight(.bold))
                .foregroundStyle(.colorTextPrimary)

            VStack(spacing: 0) {
                ForEach(Array(briefing.recentUpdates.enumerated()), id: \.element.id) { index, update in
                    YourSpaceUpdateRow(update: update) {
                        selectConversation(update.conversation)
                    }
                    if index < briefing.recentUpdates.count - 1 {
                        Divider().padding(.leading, 60)
                    }
                }
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
            Text("Your Space connects context privately. When something is useful elsewhere, you choose what to copy and which convo to open.")
                .font(.body)
                .foregroundStyle(.colorTextSecondary)
        }
        .padding(.bottom, DesignConstants.Spacing.step8x)
    }

    private var bottomBar: some View {
        HStack(spacing: DesignConstants.Spacing.step3x) {
            Button {
                presentingTools = true
            } label: {
                Image(systemName: "ellipsis")
                    .font(.headline)
                    .frame(width: 44, height: 44)
            }
            .buttonStyle(.plain)
            .glassEffect(.regular.interactive(), in: .circle)
            .accessibilityLabel("Your Space tools")
            .accessibilityIdentifier("your-space-tools-button")

            if !briefing.recentUpdates.isEmpty {
                Button {
                    presentingShare = true
                } label: {
                    Label("Share context", systemImage: "square.and.arrow.up")
                        .font(.body.weight(.semibold))
                        .frame(maxWidth: .infinity, minHeight: 44)
                        .padding(.horizontal, DesignConstants.Spacing.step4x)
                }
                .buttonStyle(.plain)
                .glassEffect(.regular.interactive(), in: .capsule)
                .accessibilityIdentifier("your-space-share-context-button")
            } else {
                Spacer(minLength: 0)
            }
        }
        .foregroundStyle(.colorTextPrimary)
        .padding(.horizontal, DesignConstants.Spacing.step6x)
        .padding(.vertical, DesignConstants.Spacing.step2x)
    }

    private var accessibilityActions: some View {
        VStack(spacing: DesignConstants.Spacing.step3x) {
            Button {
                presentingTools = true
            } label: {
                Label("Your Space tools", systemImage: "ellipsis.circle")
                    .font(.headline)
                    .frame(maxWidth: .infinity, minHeight: 52)
            }
            .buttonStyle(.bordered)
            .accessibilityIdentifier("your-space-tools-button")

            if !briefing.recentUpdates.isEmpty {
                Button {
                    presentingShare = true
                } label: {
                    Label("Share context", systemImage: "square.and.arrow.up")
                        .font(.headline)
                        .frame(maxWidth: .infinity, minHeight: 52)
                }
                .buttonStyle(.borderedProminent)
                .accessibilityIdentifier("your-space-share-context-button")
            }
        }
        .frame(maxWidth: 520)
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
        withAnimation(reduceMotion ? nil : .smooth(duration: 0.25)) {
            viewModel.select(conversation)
        }
    }

    private func copyAndOpen(_ update: YourSpaceUpdate, in conversation: Conversation) {
        UIPasteboard.general.string = update.shareText
        presentingShare = false
        Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(250))
            selectConversation(conversation)
        }
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
