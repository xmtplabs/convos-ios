import ConvosCore
import SwiftUI

struct ConversationsView: View {
    @State var viewModel: ConversationsViewModel
    @Bindable var profileSettingsViewModel: ProfileSettingsViewModel
    /// App-level indicator context plumbed from `MainTabView`. Carries the
    /// shared namespace + transition id used for the pill -> app settings
    /// sheet zoom; passed through to `ConversationPresenter` so the pill
    /// overlay renders with the right matched-transition source.
    let appIndicatorContext: AppIndicatorContext
    /// Optional inset rendered above the NavigationSplitView's sidebar
    /// — used by `MainTabView` to attach the `AssistantBuilderBar` only
    /// to the conversation list, not the conversation detail. Putting
    /// the inset on the sidebar means pushing a conversation detail
    /// doesn't inherit the bar's safe-area inset, so the detail's bottom
    /// bar can't briefly jump to "above" the (about-to-disappear) bar.
    var sidebarBottomAccessory: AnyView?

    @Namespace private var namespace: Namespace.ID
    @Environment(\.dismiss) private var dismiss: DismissAction
    @State private var sidebarWidth: CGFloat = 0.0
    @Environment(\.horizontalSizeClass) private var horizontalSizeClass: UserInterfaceSizeClass?
    @Environment(\.colorScheme) private var colorScheme: ColorScheme
    @State private var conversationPendingExplosion: Conversation?
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
    private var contactNameOverride: @Sendable (String) -> String? {
        viewModel.session.messagingServiceSync().contactsRepository().contactName(for:)
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
            onStartConvo: viewModel.onStartConvo,
            onJoinConvo: viewModel.onJoinConvo
        )
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
            selectedConversationId: viewModel.selectedConversationId,
            isFilteredResultEmpty: viewModel.isFilteredResultEmpty,
            filterEmptyMessage: viewModel.activeFilter.emptyStateMessage,
            hasCreatedMoreThanOneConvo: viewModel.hasCreatedMoreThanOneConvo,
            onSelectConversation: { conversation in
                viewModel.selectedConversationId = conversation.id
            },
            onConfirmedDeleteConversation: { conversation in
                viewModel.leave(conversation: conversation)
            },
            onExplodeConversation: { conversation in
                conversationPendingExplosion = conversation
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
            onStartConvo: viewModel.onStartConvo,
            onJoinConvo: viewModel.onJoinConvo,
            onShowAllFilter: { viewModel.activeFilter = .all }
        )
        .ignoresSafeArea(edges: [.top, .bottom])
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
        // The top-leading slot used to hold a settings button; that surface
        // is now owned by `AppIndicatorPill`, which renders as an overlay
        // from `ConversationPresenter` and routes its tap to the same
        // settings sheet via `onAppInfoTap`. Keeping the toolbar slot empty
        // preserves the navigation-bar height the indicator overlay sits
        // on top of.
        ToolbarItem(placement: .topBarTrailing) {
            composeToolbarButton(
                viewModel: viewModel,
                transitionNamespace: appIndicatorContext.transitionNamespace,
                fallbackNamespace: namespace
            )
        }
    }

    var body: some View {
        let nameOverride = contactNameOverride
        return ConversationPresenter(
            viewModel: viewModel.selectedConversationViewModel,
            focusCoordinator: focusCoordinator,
            insetsTopSafeArea: true,
            sidebarColumnWidth: $sidebarWidth,
            appIndicatorContext: appIndicatorContext
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
                .overlay(alignment: .bottom) {
                    if let sidebarBottomAccessory {
                        sidebarBottomAccessory
                    }
                }
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
                if viewModel.selectedConversationViewModel != nil {
                    preferredColumn = .detail
                }
                viewModel.onAppear()
            }
            .onDisappear {
                viewModel.onDisappear()
            }
            .onChange(of: viewModel.selectedConversationViewModel == nil) { _, isNil in
                preferredColumn = isNil ? .sidebar : .detail
            }
            .onChange(of: viewModel.selectedConversationViewModel?.explodeState) { _, newState in
                guard let newState, case .exploded = newState else { return }
                viewModel.selectedConversationId = nil
                preferredColumn = .sidebar
            }
            .onChange(of: preferredColumn) { _, newColumn in
                if newColumn == .sidebar && horizontalSizeClass == .compact {
                    viewModel.selectedConversationId = nil
                }
            }
        }
        .focusable(false)
        .focusEffectDisabled()
        .memberNameOverride(nameOverride)
        .modifier(ConversationsSheetModifier(
            viewModel: viewModel,
            profileSettingsViewModel: profileSettingsViewModel,
            conversationPendingExplosion: $conversationPendingExplosion,
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
    let profileSettingsViewModel: ProfileSettingsViewModel
    @Binding var conversationPendingExplosion: Conversation?
    var namespace: Namespace.ID

    func body(content: Content) -> some View {
        content
            // The `NewConversationView` and `AssistantBuilderView` sheets
            // are both presented from `MainTabView` so the compose
            // button (top-trailing on every tab) and the assistant
            // builder bar can zoom into them with a shared namespace.
            .sheet(item: $viewModel.pendingGrantRequest) { request in
                let dismissAction = { viewModel.pendingGrantRequest = nil }
                CloudConnectionGrantRequestSheet(
                    viewModel: viewModel.makeGrantRequestSheetViewModel(for: request),
                    onDismiss: dismissAction
                )
                .presentationDetents([.medium])
            }
            .selfSizingSheet(isPresented: $viewModel.presentingExplodeInfo) {
                ExplodeInfoView()
            }
            .selfSizingSheet(isPresented: $viewModel.presentingPinLimitInfo) {
                PinLimitInfoView()
            }
            .background {
                Color.clear
                    .fullScreenCover(item: $conversationPendingExplosion) { conversation in
                        ExplodeConvoSheet(
                            isScheduled: conversation.scheduledExplosionDate != nil,
                            onSchedule: { date in
                                viewModel.scheduleConversationExplosion(conversation, at: date)
                                conversationPendingExplosion = nil
                            },
                            onExplodeNow: {
                                viewModel.explodeConversation(conversation)
                                conversationPendingExplosion = nil
                            },
                            onDismiss: {
                                conversationPendingExplosion = nil
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
        profileSettingsViewModel: profileSettingsViewModel,
        appIndicatorContext: AppIndicatorContext(
            profileImage: profileSettingsViewModel.profileImage
        )
    )
}

#Preview("Original") {
    let convos = ConvosClient.mock()
    let viewModel = ConversationsViewModel(session: convos.session)
    let profileSettingsViewModel = ProfileSettingsViewModel.shared
    ConversationsView(
        viewModel: viewModel,
        profileSettingsViewModel: profileSettingsViewModel,
        appIndicatorContext: AppIndicatorContext(
            profileImage: profileSettingsViewModel.profileImage
        )
    )
}
