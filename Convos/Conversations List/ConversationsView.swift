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
    @State private var conversationPendingDeletion: Conversation?
    @State private var scrollOffset: CGFloat = 0
    @State private var pinnedSectionHeight: CGFloat = 0

    private var pinnedSectionOffset: CGFloat {
        guard pinnedSectionHeight > 0 else { return 0 }

        // With adjusted scroll offset (accounting for safe area):
        // - At rest with spacer: scrollOffset ≈ -pinnedSectionHeight
        // - Calculate movement relative to natural position
        return -scrollOffset
    }

    private var pinnedSectionProgress: CGFloat {
        guard pinnedSectionHeight > 0 else { return 0 }
        let progress = min(max(-pinnedSectionOffset / pinnedSectionHeight, 0), 1)
        return progress * progress
    }

    private var pinnedSectionScale: CGFloat {
        1.0 - (pinnedSectionProgress * 0.15)
    }

    private var pinnedSectionOpacity: Double {
        1.0 - (pinnedSectionProgress * 0.5)
    }

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

    var conversationsList: some View {
        List(selection: $viewModel.selectedConversationId) {
            if !viewModel.pinnedConversations.isEmpty {
                Color.clear.frame(height: pinnedSectionHeight)
                    .listRowInsets(.init(top: 0, leading: 0, bottom: 0, trailing: 0))
                    .listRowSeparator(.hidden)
            }

            if viewModel.isFilteredResultEmpty {
                filteredEmptyStateView
                    .listRowInsets(.init(top: 0, leading: 0, bottom: 0, trailing: 0))
                    .listRowSeparator(.hidden)
                    .listRowBackground(Color.clear)
            }

            ForEach(viewModel.unpinnedConversations, id: \.id) { conversation in
                let isFirstAndOnly = viewModel.unpinnedConversations.first == conversation &&
                                     viewModel.unpinnedConversations.count == 1
                let shouldShowEmptyCTA = isFirstAndOnly &&
                                         !viewModel.hasCreatedMoreThanOneConvo &&
                                         horizontalSizeClass == .compact

                if shouldShowEmptyCTA {
                    emptyConversationsView
                        .listRowInsets(.init(top: 0, leading: 0, bottom: 0, trailing: 0))
                        .listRowSeparator(.hidden)
                }

                conversationListItem(conversation)
            }
        }
        .listStyle(.plain)
        .onScrollGeometryChange(for: CGFloat.self) { geometry in
            geometry.contentOffset.y + geometry.contentInsets.top
        } action: { _, newValue in
            withAnimation(.interactiveSpring) {
                scrollOffset = newValue
            }
        }
    }

    @ViewBuilder
    func conversationListItem(_ conversation: Conversation) -> some View {
        ConversationsListItem(conversation: conversation)
            .contextMenu {
                conversationContextMenuContent(
                    conversation: conversation,
                    viewModel: viewModel,
                    onDelete: { conversationPendingDeletion = conversation }
                )
            }
            .swipeActions(edge: .leading, allowsFullSwipe: false) {
                let deleteAction = { conversationPendingDeletion = conversation }
                Button(action: deleteAction) {
                    Image(systemName: "trash")
                }
                .tint(.colorCaution)
            }
            .swipeActions(edge: .trailing, allowsFullSwipe: false) {
                let toggleReadAction = { viewModel.toggleReadState(conversation: conversation) }
                Button(action: toggleReadAction) {
                    Image(systemName: conversation.isUnread ? "checkmark.message.fill" : "message.badge.fill")
                }
                .tint(.colorFillSecondary)

                let toggleMuteAction = { viewModel.toggleMute(conversation: conversation) }
                Button(action: toggleMuteAction) {
                    Image(systemName: conversation.isMuted ? "bell.fill" : "bell.slash.fill")
                }
                .tint(.colorPurpleMute)
            }
            .confirmationDialog(
                "This convo will be deleted immediately.",
                isPresented: Binding(
                    get: { conversationPendingDeletion?.id == conversation.id },
                    set: { if !$0 { conversationPendingDeletion = nil } }
                ),
                titleVisibility: .visible
            ) {
                Button("Delete", role: .destructive) {
                    viewModel.leave(conversation: conversation)
                    conversationPendingDeletion = nil
                }
                Button("Cancel", role: .cancel) {
                    conversationPendingDeletion = nil
                }
            }
            .listRowSeparator(.hidden)
            .listRowBackground(
                RoundedRectangle(cornerRadius: DesignConstants.CornerRadius.mediumLarge)
                    .fill(
                        conversation.id == viewModel.selectedConversationId ||
                        conversationPendingDeletion?.id == conversation.id
                        ? .colorFillMinimal : .clear
                    )
                    .padding(.horizontal, DesignConstants.Spacing.step3x)
            )
            .listRowInsets(
                .init(
                    top: 0,
                    leading: 0,
                    bottom: 0,
                    trailing: 0
                )
            )
    }

    var body: some View {
        ConversationPresenter(
            viewModel: viewModel.selectedConversationViewModel,
            focusCoordinator: focusCoordinator,
            insetsTopSafeArea: true,
            sidebarColumnWidth: $sidebarWidth
        ) { focusState, coordinator in
            NavigationSplitView {
                ZStack(alignment: .top) {
                    Group {
                        if viewModel.unpinnedConversations.isEmpty && viewModel.pinnedConversations.isEmpty && viewModel.activeFilter == .all && horizontalSizeClass == .compact {
                            emptyConversationsViewScrollable
                        } else if viewModel.isFilteredResultEmpty && viewModel.pinnedConversations.isEmpty && horizontalSizeClass == .compact {
                            ScrollView {
                                filteredEmptyStateView
                            }
                        } else {
                            conversationsList
                        }
                    }

                    if !viewModel.pinnedConversations.isEmpty {
                        PinnedConversationsSection(
                            pinnedConversations: viewModel.pinnedConversations,
                            viewModel: viewModel,
                            conversationPendingDeletion: $conversationPendingDeletion,
                            onSelectConversation: { conversation in
                                viewModel.selectedConversationId = conversation.id
                            }
                        )
                        .padding(.vertical, DesignConstants.Spacing.step3x)
                        .onGeometryChange(for: CGFloat.self) { geometry in
                            geometry.size.height
                        } action: { oldHeight, newHeight in
                            guard oldHeight != 0 else {
                                pinnedSectionHeight = newHeight
                                return
                            }
                            withAnimation(.spring(response: 0.5, dampingFraction: 0.8)) {
                                pinnedSectionHeight = newHeight
                            }
                        }
                        .scaleEffect(pinnedSectionScale)
                        .opacity(pinnedSectionOpacity)
                        .offset(y: pinnedSectionOffset)
                    }
                }
                .onGeometryChange(for: CGSize.self) {
                    $0.size
                } action: { newValue in
                    sidebarWidth = newValue.width
                }
                .background(.colorBackgroundPrimary)
                .toolbarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .topBarLeading) {
                        ConvosToolbarButton(padding: false) {
                            presentingAppSettings = true
                        }
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
                        } label: {
                            Image(systemName: "line.3.horizontal.decrease")
                                .foregroundStyle(viewModel.activeFilter == .unread ? .colorTextPrimaryInverted : .colorFillPrimary)
                                .frame(width: 32, height: 32)
                                .background(viewModel.activeFilter == .unread ? .colorFillPrimary : .clear)
                                .mask(Circle())
                                .overlay(Circle().stroke(viewModel.activeFilter == .unread ? .colorFillPrimary : .clear, lineWidth: 2))
                                .accessibilityLabel("Filter")
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
                    }
                    .matchedTransitionSource(
                        id: "composer-transition-source",
                        in: namespace
                    )

                    ToolbarItem(placement: .bottomBar) {
                        Button("Compose", systemImage: "square.and.pencil") {
                            viewModel.onStartConvo()
                        }
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
                        messagesTopBarTrailingItemEnabled: true,
                        messagesTextFieldEnabled: true,
                        bottomBarContent: { EmptyView() }
                    )
                } else if horizontalSizeClass != .compact {
                    emptyConversationsViewScrollable
                } else {
                    EmptyView()
                }
            }
        }
        .focusable(false)
        .focusEffectDisabled()
        .sheet(isPresented: $presentingAppSettings) {
            AppSettingsView(
                viewModel: viewModel.appSettingsViewModel,
                quicknameViewModel: quicknameViewModel,
                onDeleteAllData: viewModel.deleteAllData
            )
            .navigationTransition(
                .zoom(
                    sourceID: "app-settings-transition-source",
                    in: namespace
                )
            )
            .interactiveDismissDisabled(viewModel.appSettingsViewModel.isDeleting)
        }
        .sheet(item: $viewModel.newConversationViewModel) { newConvoViewModel in
            NewConversationView(
                viewModel: newConvoViewModel,
                quicknameViewModel: quicknameViewModel
            )
            .background(.colorBackgroundPrimary)
            .interactiveDismissDisabled(newConvoViewModel.conversationViewModel.onboardingCoordinator.isWaitingForInviteAcceptance)
            .navigationTransition(
                .zoom(
                    sourceID: "composer-transition-source",
                    in: namespace
                )
            )
        }
        .selfSizingSheet(isPresented: $viewModel.presentingExplodeInfo) {
            ExplodeInfoView()
                .background(.colorBackgroundRaised)
        }
        .selfSizingSheet(isPresented: $viewModel.presentingPinLimitInfo) {
            PinLimitInfoView()
                .background(.colorBackgroundRaised)
        }
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
            Conversation.mock(id: "convo-10", name: "Random Chat", isUnread: false)
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
