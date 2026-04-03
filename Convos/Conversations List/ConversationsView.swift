import ConvosCore
import SwiftUI

struct ConversationsView: View {
    @State var viewModel: ConversationsViewModel
    @Bindable var quicknameViewModel: QuicknameSettingsViewModel

    @Namespace private var namespace: Namespace.ID
    @State private var presentingAppSettings: Bool = false
    @Environment(\.dismiss) private var dismiss: DismissAction
    @State private var sidebarWidth: CGFloat = 0.0
    @Environment(\.horizontalSizeClass) private var horizontalSizeClass: UserInterfaceSizeClass?
    @Environment(\.colorScheme) private var colorScheme: ColorScheme
    @State private var conversationPendingExplosion: Conversation?
    @State private var preferredColumn: NavigationSplitViewColumn = .sidebar

    var focusCoordinator: FocusCoordinator {
        viewModel.focusCoordinator
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
                presentingAppSettings = true
            }
            .accessibilityLabel("Convos settings")
            .accessibilityIdentifier("app-settings-button")
        }
        .matchedTransitionSource(id: "app-settings-transition-source", in: namespace)

        ToolbarItem(placement: .topBarTrailing) {
            filterMenu
        }
        .matchedTransitionSource(id: "filter-view-transition-source", in: namespace)

        ToolbarItem(placement: .bottomBar) {
            Spacer()
        }

        ToolbarItem(placement: .bottomBar) {
            Button("Scan", systemImage: "viewfinder") {
                viewModel.onJoinConvo()
            }
            .accessibilityLabel("Scan to join a conversation")
            .accessibilityIdentifier("scan-button")
        }
        .matchedTransitionSource(id: "composer-transition-source", in: namespace)

        ToolbarItem(placement: .bottomBar) {
            Button("Compose", systemImage: "square.and.pencil") {
                viewModel.onStartConvo()
            }
            .accessibilityLabel("Start a new conversation")
            .accessibilityIdentifier("compose-button")
        }
        .matchedTransitionSource(id: "composer-transition-source", in: namespace)
    }

    var body: some View {
        ConversationPresenter(
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
                .toolbar {
                    ToolbarItem(placement: .topBarLeading) {
                        ConvosToolbarButton(padding: false) {
                            presentingAppSettings = true
                        }
                        .accessibilityLabel("Convos settings")
                        .accessibilityIdentifier("app-settings-button")
                    }
                    .matchedTransitionSource(
                        id: "app-settings-transition-source",
                        in: namespace
                    )

                    ToolbarItem(placement: .topBarTrailing) {
                        Menu {
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
                                .foregroundStyle(viewModel.activeFilter != .all ? .colorTextPrimaryInverted : .colorFillPrimary)
                                .frame(width: 32, height: 32)
                                .background(viewModel.activeFilter != .all ? .colorFillPrimary : .clear)
                                .mask(Circle())
                                .overlay(Circle().stroke(viewModel.activeFilter != .all ? .colorFillPrimary : .clear, lineWidth: 2))
                                .accessibilityLabel(viewModel.activeFilter != .all ? "Filter active" : "Filter conversations")
                                .accessibilityIdentifier("filter-button")
                        }
                        .disabled(!viewModel.hasUnpinnedConversations)
                    }
                    .matchedTransitionSource(
                        id: "filter-view-transition-source",
                        in: namespace
                    )

                    ToolbarItem(placement: .bottomBar) {
                        Spacer()
                    }

                    ToolbarItem(placement: .bottomBar) {
                        Button("Scan", systemImage: "viewfinder") {
                            viewModel.onJoinConvo()
                        }
                        .accessibilityLabel("Scan to join a conversation")
                        .accessibilityIdentifier("scan-button")
                    }
                    .matchedTransitionSource(
                        id: "composer-transition-source",
                        in: namespace
                    )

                    ToolbarItem(placement: .bottomBar) {
                        Button("Compose", systemImage: "square.and.pencil") {
                            viewModel.onStartConvo()
                        }
                        .accessibilityLabel("Start a new conversation")
                        .accessibilityIdentifier("compose-button")
                    }
                    .matchedTransitionSource(
                        id: "composer-transition-source",
                        in: namespace
                    )
                }
                .toolbar(removing: .sidebarToggle)
            } detail: {
                if let conversationViewModel = viewModel.selectedConversationViewModel {
                    ConversationView(
                        viewModel: conversationViewModel,
                        quicknameViewModel: quicknameViewModel,
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
        .modifier(ConversationsSheetModifier(
            presentingAppSettings: $presentingAppSettings,
            viewModel: viewModel,
            quicknameViewModel: quicknameViewModel,
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
    @Binding var presentingAppSettings: Bool
    @Bindable var viewModel: ConversationsViewModel
    let quicknameViewModel: QuicknameSettingsViewModel
    @Binding var conversationPendingExplosion: Conversation?
    var namespace: Namespace.ID

    func body(content: Content) -> some View {
        content
            .sheet(isPresented: $presentingAppSettings) {
                AppSettingsView(
                    viewModel: viewModel.appSettingsViewModel,
                    quicknameViewModel: quicknameViewModel,
                    session: viewModel.session,
                    onDeleteAllData: viewModel.deleteAllData
                )
                .navigationTransition(
                    .zoom(sourceID: "app-settings-transition-source", in: namespace)
                )
                .interactiveDismissDisabled(viewModel.appSettingsViewModel.isDeleting)
            }
            .sheet(item: $viewModel.newConversationViewModel) { newConvoViewModel in
                NewConversationView(
                    viewModel: newConvoViewModel,
                    quicknameViewModel: quicknameViewModel
                )
                .background(.colorBackgroundSurfaceless)
                .presentationSizing(.page)
                .navigationTransition(
                    .zoom(sourceID: "composer-transition-source", in: namespace)
                )
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
    let quicknameViewModel = QuicknameSettingsViewModel.shared

    ConversationsView(
        viewModel: viewModel,
        quicknameViewModel: quicknameViewModel
    )
}

#Preview("Original") {
    let convos = ConvosClient.mock()
    let viewModel = ConversationsViewModel(session: convos.session)
    let quicknameViewModel = QuicknameSettingsViewModel.shared
    ConversationsView(
        viewModel: viewModel,
        quicknameViewModel: quicknameViewModel
    )
}
