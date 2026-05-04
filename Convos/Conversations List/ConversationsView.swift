import ConvosCore
import NavigationMetrics
import SwiftUI

struct ConversationsView: View {
    @State var viewModel: ConversationsViewModel
    @Bindable var navState: ConversationsNavigatorImpl
    let navigator: any ConversationsNavigator
    @Bindable var profileSettingsViewModel: ProfileSettingsViewModel

    @Namespace private var namespace: Namespace.ID
    @Environment(\.dismiss) private var dismiss: DismissAction
    @State private var sidebarWidth: CGFloat = 0.0
    @Environment(\.horizontalSizeClass) private var horizontalSizeClass: UserInterfaceSizeClass?
    @Environment(\.colorScheme) private var colorScheme: ColorScheme
    @State private var preferredColumn: NavigationSplitViewColumn = .sidebar

    var focusCoordinator: FocusCoordinator {
        viewModel.focusCoordinator
    }

    /// Inbox-to-contact-name override applied across the whole
    /// conversation list view tree (cells, pinned tiles, accessibility
    /// labels). Built once per `ConversationsView` body recompute so
    /// cells share the same closure. Reads through the messaging
    /// service's contacts repository; uses `messagingServiceSync()`
    /// because cell rendering is synchronous.
    private var contactOverride: @Sendable (String) -> Contact? {
        viewModel.session.messagingServiceSync().contactsRepository().contact(for:)
    }

    var emptyConversationsViewScrollable: some View {
        ScrollView {
            LazyVStack(spacing: 0.0) {
                emptyConversationsView
            }
        }
    }

    var emptyConversationsView: some View {
        ConversationsListEmptyCTA(
            onStartConvo: onStartConvo,
            onJoinConvo: onJoinConvo
        )
    }

    private func onStartConvo() {
        navigator.present(newConversation: NewConversationNavigatorArgs(mode: .create))
    }

    private func onJoinConvo() {
        navigator.present(newConversation: NewConversationNavigatorArgs(mode: .scanner))
    }

    var filteredEmptyStateView: some View {
        FilteredEmptyStateView(
            message: viewModel.activeFilter.emptyStateMessage,
            onShowAll: { viewModel.activeFilter = .all }
        )
        .frame(maxWidth: .infinity)
        .padding(.horizontal, DesignConstants.Spacing.step6x)
        .padding(.top, DesignConstants.Spacing.step6x)
    }

    var conversationsCollectionView: some View {
        ConversationsViewRepresentable(
            pinnedConversations: viewModel.pinnedConversations,
            unpinnedConversations: viewModel.unpinnedConversations,
            selectedConversationId: navState.selectedConversationId,
            isFilteredResultEmpty: viewModel.isFilteredResultEmpty,
            filterEmptyMessage: viewModel.activeFilter.emptyStateMessage,
            hasCreatedMoreThanOneConvo: viewModel.hasCreatedMoreThanOneConvo,
            onSelectConversation: { conversation in
                navigator.navigateTo(conversation: ConversationNavigatorArgs(conversationId: conversation.id))
            },
            onConfirmedDeleteConversation: { conversation in
                viewModel.leave(conversation: conversation)
            },
            onExplodeConversation: { conversation in
                navigator.present(explodeConfirmation: ExplodeConfirmationNavigatorArgs(conversationId: conversation.id))
            },
            onToggleMute: { conversation in
                viewModel.toggleMute(conversation: conversation)
            },
            onToggleReadState: { conversation in
                viewModel.toggleReadState(conversation: conversation)
            },
            onTogglePin: { conversation in
                viewModel.togglePin(conversation: conversation)
            },
            onStartConvo: onStartConvo,
            onJoinConvo: onJoinConvo,
            onShowAllFilter: { viewModel.activeFilter = .all }
        )
        .ignoresSafeArea(edges: [.top, .bottom])
    }

    private var filterMenu: some View {
        let isFiltered: Bool = viewModel.activeFilter != .all
        return Menu {
            let allAction = { viewModel.activeFilter = .all }
            Button(action: allAction) {
                if viewModel.activeFilter == .all {
                    Label("All", systemImage: "checkmark")
                } else {
                    Text("All")
                }
            }

            let unreadAction = {
                viewModel.activeFilter = viewModel.activeFilter == .unread ? .all : .unread
            }
            Button(action: unreadAction) {
                if viewModel.activeFilter == .unread {
                    Label("Unread", systemImage: "checkmark")
                } else {
                    Text("Unread")
                }
            }

            let explodingAction = {
                viewModel.activeFilter = viewModel.activeFilter == .exploding ? .all : .exploding
            }
            Button(action: explodingAction) {
                if viewModel.activeFilter == .exploding {
                    Label("Exploding", systemImage: "checkmark")
                } else {
                    Text("Exploding")
                }
            }
        } label: {
            Image(systemName: "line.3.horizontal.decrease")
                .foregroundStyle(isFiltered ? .colorTextPrimaryInverted : .colorFillPrimary)
                .frame(width: 32, height: 32)
                .background(isFiltered ? .colorFillPrimary : .clear)
                .mask(Circle())
                .overlay(Circle().stroke(isFiltered ? .colorFillPrimary : .clear, lineWidth: 2))
                .accessibilityLabel(isFiltered ? "Filter active" : "Filter conversations")
                .accessibilityIdentifier("filter-button")
        }
        .disabled(!viewModel.hasUnpinnedConversations)
    }

    @ViewBuilder
    private var sidebarContent: some View {
        if viewModel.unpinnedConversations.isEmpty && viewModel.pinnedConversations.isEmpty && viewModel.activeFilter == .all && horizontalSizeClass == .compact {
            emptyConversationsViewScrollable
        } else if viewModel.isFilteredResultEmpty && viewModel.pinnedConversations.isEmpty && horizontalSizeClass == .compact {
            ScrollView {
                filteredEmptyStateView
            }
        } else {
            conversationsCollectionView
        }
    }

    @ToolbarContentBuilder
    private var sidebarToolbar: some ToolbarContent {
        ToolbarItem(placement: .topBarLeading) {
            ConvosToolbarButton(padding: false) {
                navigator.present(appSettings: AppSettingsNavigatorArgs())
            }
            .accessibilityLabel("Convos settings")
            .accessibilityIdentifier("app-settings-button")
        }
        .matchedTransitionSource(id: "app-settings-transition-source", in: namespace)

        ToolbarItem(placement: .topBarTrailing) {
            CreditsBadge()
        }

        ToolbarItem(placement: .topBarTrailing) {
            filterMenu
        }
        .matchedTransitionSource(id: "filter-view-transition-source", in: namespace)

        ToolbarItem(placement: .bottomBar) {
            Spacer()
        }

        ToolbarItem(placement: .bottomBar) {
            Button("Scan", systemImage: "viewfinder") {
                onJoinConvo()
            }
            .accessibilityLabel("Scan to join a conversation")
            .accessibilityIdentifier("scan-button")
        }
        .matchedTransitionSource(id: "composer-transition-source", in: namespace)

        ToolbarItem(placement: .bottomBar) {
            Button("Compose", systemImage: "square.and.pencil") {
                onStartConvo()
            }
            .accessibilityLabel("Start a new conversation")
            .accessibilityIdentifier("compose-button")
        }
        .matchedTransitionSource(id: "composer-transition-source", in: namespace)
    }

    var body: some View {
        let resolver = contactOverride
        return ConversationPresenter(
            viewModel: viewModel.selectedConversationViewModel,
            focusCoordinator: focusCoordinator,
            insetsTopSafeArea: true,
            sidebarColumnWidth: $sidebarWidth
        ) { focusState, coordinator in
            NavigationSplitView(preferredCompactColumn: $preferredColumn) {
                sidebarContent
                    .onGeometryChange(for: CGSize.self) {
                        $0.size
                    } action: { newValue in
                        sidebarWidth = newValue.width
                    }
                .background(.colorBackgroundSurfaceless)
                .toolbarTitleDisplayMode(.inline)
                .toolbar { sidebarToolbar }
                .toolbar(removing: .sidebarToggle)
            } detail: {
                if let conversationViewModel = viewModel.selectedConversationViewModel {
                    ConversationView(
                        viewModel: conversationViewModel,
                        profileSettingsViewModel: profileSettingsViewModel,
                        focusState: focusState,
                        focusCoordinator: coordinator,
                        onScanInviteCode: {},
                        onDeleteConversation: {},
                        messagesTopBarTrailingItem: .share,
                        messagesTopBarTrailingItemEnabled: !conversationViewModel.conversation.isPendingInvite,
                        messagesTextFieldEnabled: !conversationViewModel.conversation.isPendingInvite,
                        bottomBarContent: { EmptyView() }
                    )
                } else if horizontalSizeClass != .compact {
                    emptyConversationsViewScrollable
                } else {
                    EmptyView()
                }
            }
            .onAppear {
                viewModel.updateSelectionState()
                if viewModel.selectedConversationViewModel != nil {
                    preferredColumn = .detail
                }
                viewModel.onAppear()
            }
            .task {
                // Refresh credits + subscription on every conversations-list
                // appearance. TTL-debounced inside the services (15s), so
                // safe to fire here without storming the API on rapid nav.
                await CreditsServices.shared.refresh()
                await SubscriptionServices.shared.refresh()
            }
            .onDisappear {
                viewModel.onDisappear()
            }
            .onChange(of: navState.selectedConversationId) { _, _ in
                viewModel.updateSelectionState()
            }
            .onChange(of: viewModel.selectedConversationViewModel == nil) { _, isNil in
                preferredColumn = isNil ? .sidebar : .detail
            }
            .onChange(of: viewModel.selectedConversationViewModel?.explodeState) { _, newState in
                guard let newState, case .exploded = newState else { return }
                navState.selectedConversationId = nil
                preferredColumn = .sidebar
            }
            .onChange(of: preferredColumn) { _, newColumn in
                if newColumn == .sidebar && horizontalSizeClass == .compact {
                    navState.selectedConversationId = nil
                }
            }
        }
        .focusable(false)
        .focusEffectDisabled()
        .memberContactOverride(resolver)
        .modifier(ConversationsSheetModifier(
            viewModel: viewModel,
            navState: navState,
            profileSettingsViewModel: profileSettingsViewModel,
            namespace: namespace
        ))
        .onContinueUserActivity(NSUserActivityTypeBrowsingWeb) { activity in
            if let url = activity.webpageURL {
                viewModel.handleURL(url)
            }
        }
        .onOpenURL { url in
            viewModel.handleURL(url)
        }
    }
}

private struct ConversationsSheetModifier: ViewModifier {
    @Bindable var viewModel: ConversationsViewModel
    @Bindable var navState: ConversationsNavigatorImpl
    let profileSettingsViewModel: ProfileSettingsViewModel
    var namespace: Namespace.ID

    func body(content: Content) -> some View {
        content
            .sheet(isPresented: $navState.presentingAppSettings) {
                AppSettingsView(
                    viewModel: viewModel.appSettingsViewModel,
                    navState: navState.appSettingsNavState,
                    navigator: navState.appSettingsNavigator,
                    profileSettingsViewModel: profileSettingsViewModel,
                    session: viewModel.session,
                    onDeleteAllData: viewModel.deleteAllData
                )
                .navigationTransition(
                    .zoom(sourceID: "app-settings-transition-source", in: namespace)
                )
                .interactiveDismissDisabled(viewModel.appSettingsViewModel.isDeleting)
            }
            .sheet(item: $navState.newConversationViewModel) { newConvoViewModel in
                NewConversationView(
                    viewModel: newConvoViewModel,
                    profileSettingsViewModel: profileSettingsViewModel
                )
                .background(.colorBackgroundSurfaceless)
                .presentationSizing(.page)
                .navigationTransition(
                    .zoom(sourceID: "composer-transition-source", in: namespace)
                )
            }
            .sheet(item: $viewModel.pendingGrantRequest) { request in
                let dismissAction = { viewModel.pendingGrantRequest = nil }
                CloudConnectionGrantRequestSheet(
                    viewModel: viewModel.makeGrantRequestSheetViewModel(for: request),
                    onDismiss: dismissAction
                )
                .presentationDetents([.medium])
            }
            .selfSizingSheet(isPresented: $navState.presentingExplodeInfo) {
                ExplodeInfoView()
            }
            .selfSizingSheet(isPresented: $navState.presentingPinLimitInfo) {
                PinLimitInfoView()
            }
            .background {
                Color.clear
                    .fullScreenCover(item: $navState.conversationPendingExplosion) { conversation in
                        ExplodeConvoSheet(
                            isScheduled: conversation.scheduledExplosionDate != nil,
                            onSchedule: { date in
                                viewModel.scheduleConversationExplosion(conversation, at: date)
                                navState.conversationPendingExplosion = nil
                            },
                            onExplodeNow: {
                                viewModel.explodeConversation(conversation)
                                navState.conversationPendingExplosion = nil
                            },
                            onDismiss: {
                                navState.conversationPendingExplosion = nil
                            }
                        )
                        .presentationBackground(.clear)
                    }
                    .transaction { transaction in
                        transaction.disablesAnimations = true
                    }
            }
    }
}

#Preview("With Many Conversations") {
    @Previewable @State var viewModel = ConversationsViewModel.preview(
        conversations: [
            Conversation.mock(id: "pinned-1", name: "Ephemeral", isUnread: true, isPinned: true),
            Conversation.mock(id: "pinned-2", name: "Shane", isUnread: false, isPinned: true),
            Conversation.mock(id: "pinned-3", name: "Fam", isUnread: true, isPinned: true),
            Conversation.mock(id: "convo-1", name: "Convo 84B", isUnread: true),
            Conversation.mock(id: "convo-2", name: "NYC June 2025", isUnread: false),
            Conversation.mock(id: "convo-3", name: "Convo 75X", isUnread: false),
            Conversation.mock(id: "convo-4", name: "Goonies Soccer", isUnread: false),
            Conversation.mock(id: "convo-5", name: "darick@bluesky.social", isUnread: true),
            Conversation.mock(id: "convo-6", name: "Saul", isUnread: false),
            Conversation.mock(id: "convo-7", name: "Convo 21Z", isUnread: false),
            Conversation.mock(id: "convo-8", name: "Weekend Plans", isUnread: true),
            Conversation.mock(id: "convo-9", name: "Project Team", isUnread: false),
            Conversation.mock(id: "convo-10", name: "Random Chat", isUnread: false),
            Conversation.mockPendingInvite(id: "draft-pending-1", name: "Secret Club")
        ]
    )
    let profileSettingsViewModel = ProfileSettingsViewModel.shared

    ConversationsView(
        viewModel: viewModel,
        navState: viewModel.navState,
        navigator: viewModel.navigator,
        profileSettingsViewModel: profileSettingsViewModel
    )
}

#Preview("Original") {
    let viewModel = ConversationsViewModel.mock
    let profileSettingsViewModel = ProfileSettingsViewModel.shared
    ConversationsView(
        viewModel: viewModel,
        navState: viewModel.navState,
        navigator: viewModel.navigator,
        profileSettingsViewModel: profileSettingsViewModel
    )
}
