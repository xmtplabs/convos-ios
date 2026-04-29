import ConvosCore
import SwiftUI

struct ConversationsView: View {
    @State var viewModel: ConversationsViewModel
    @Bindable var quicknameViewModel: QuicknameSettingsViewModel
    var backupCoordinator: BackupCoordinator?

    @Namespace private var namespace: Namespace.ID
    @State private var presentingAppSettings: Bool = false
    @Environment(\.dismiss) private var dismiss: DismissAction
    @State private var sidebarWidth: CGFloat = 0.0
    @Environment(\.horizontalSizeClass) private var horizontalSizeClass: UserInterfaceSizeClass?
    @Environment(\.colorScheme) private var colorScheme: ColorScheme
    @State private var conversationPendingExplosion: Conversation?
    @State private var preferredColumn: NavigationSplitViewColumn = .sidebar
    @State private var presentingRestoreChooser: Bool = false

    var focusCoordinator: FocusCoordinator {
        viewModel.focusCoordinator
    }

    /// True while the bootstrap gate is parked at `.restoreAvailable`
    /// or while the coordinator is still waiting for iCloud to settle —
    /// session construction is blocked in both cases, so anything that
    /// creates or joins a conversation will hang on
    /// `RestoreDecisionPendingError`.
    ///
    /// The `availableRestore != nil` guard avoids a UI dead-end: if the
    /// coordinator is in `showRestorePrompt = true` but the backup has
    /// since vanished (deleted from iCloud, or a refresh between gate
    /// resolution and render returned nothing), the prompt-card branch
    /// in `emptyConversationsViewScrollable` won't render and we'd hide
    /// the empty CTA too — leaving the user staring at a blank scroll
    /// view. In that state we let the empty CTA show; tapping "Start a
    /// convo" will still be gated server-side by the bootstrap decision.
    private var isRestorePromptBlocking: Bool {
        guard let coordinator = backupCoordinator else { return false }
        if coordinator.isAwaitingICloud { return true }
        return coordinator.showRestorePrompt && coordinator.viewModel.availableRestore != nil
    }

    var emptyConversationsViewScrollable: some View {
        ScrollView {
            LazyVStack(spacing: 0.0) {
                if let coordinator = backupCoordinator, coordinator.isAwaitingICloud {
                    AwaitingICloudCard(
                        secondsRemaining: coordinator.iCloudSettleSecondsRemaining
                    )
                    .padding(.top, DesignConstants.Spacing.step4x)
                } else if let coordinator = backupCoordinator,
                          coordinator.showRestorePrompt,
                          let available = coordinator.viewModel.availableRestore {
                    let restore = { coordinator.beginRestore(available) }
                    let dismiss = { coordinator.dismissRestorePrompt() }
                    let chooseBackup: (() -> Void)? = coordinator.viewModel.availableRestores.count > 1
                        ? { presentingRestoreChooser = true }
                        : nil
                    RestorePromptCard(
                        sidecar: available.sidecar,
                        backupCount: coordinator.viewModel.availableRestores.count,
                        isRestoring: coordinator.isRestoring,
                        onRestore: restore,
                        onChooseBackup: chooseBackup,
                        onSkip: dismiss
                    )
                    .padding(.top, DesignConstants.Spacing.step4x)
                }
                // Hide the "Pop-up private convos" CTA while the restore
                // prompt is blocking — its "Start a convo" button would
                // try to register a fresh identity, which is exactly what
                // the bootstrap gate is trying to prevent until the user
                // has chosen Restore vs Start fresh.
                if !isRestorePromptBlocking {
                    emptyConversationsView
                }
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
            .disabled(isRestorePromptBlocking)
        }
        .matchedTransitionSource(id: "composer-transition-source", in: namespace)

        ToolbarItem(placement: .bottomBar) {
            Button("Compose", systemImage: "square.and.pencil") {
                viewModel.onStartConvo()
            }
            .accessibilityLabel("Start a new conversation")
            .accessibilityIdentifier("compose-button")
            .disabled(isRestorePromptBlocking)
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
                .toolbar { sidebarToolbar }
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
        .modifier(ConversationsSheetModifier(
            presentingAppSettings: $presentingAppSettings,
            viewModel: viewModel,
            quicknameViewModel: quicknameViewModel,
            backupCoordinator: backupCoordinator,
            conversationPendingExplosion: $conversationPendingExplosion,
            namespace: namespace
        ))
        .modifier(RestoreErrorAlertModifier(coordinator: backupCoordinator))
        .sheet(isPresented: $presentingRestoreChooser) {
            if let coordinator = backupCoordinator {
                RestoreBackupChooserView(
                    backups: coordinator.viewModel.availableRestores,
                    onRestore: { backup in
                        coordinator.beginRestore(backup)
                    }
                )
            }
        }
        .onChange(of: backupCoordinator?.lastRestoreSuccessId) { _, newValue in
            // A restore initiated from the settings sheet leaves the
            // sheet stranded over the (now-restored) conversations list.
            // Drop both sheets so the user lands back on the list with
            // their just-restored data, not on the screen they kicked
            // the action off from.
            guard newValue != nil else { return }
            presentingAppSettings = false
            presentingRestoreChooser = false
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

private struct ConversationsSheetModifier: ViewModifier {
    @Binding var presentingAppSettings: Bool
    @Bindable var viewModel: ConversationsViewModel
    let quicknameViewModel: QuicknameSettingsViewModel
    var backupCoordinator: BackupCoordinator?
    @Binding var conversationPendingExplosion: Conversation?
    var namespace: Namespace.ID

    func body(content: Content) -> some View {
        content
            .sheet(isPresented: $presentingAppSettings) {
                AppSettingsView(
                    viewModel: viewModel.appSettingsViewModel,
                    quicknameViewModel: quicknameViewModel,
                    session: viewModel.session,
                    onDeleteAllData: viewModel.deleteAllData,
                    backupCoordinator: backupCoordinator
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
            .sheet(item: $viewModel.pendingGrantRequest) { request in
                let dismissAction = { viewModel.pendingGrantRequest = nil }
                ConnectionGrantRequestSheet(
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

/// Presents an alert when `BackupCoordinator.restoreErrorMessage` is
/// non-nil. Dismissing the alert writes `nil` back through the
/// two-way binding so the user can try again. Separate from the main
/// sheet modifier because restore failures can surface on the empty
/// conversations list (fresh install restoring a backup) as well as
/// on a populated list (a retry from settings), so it sits on the
/// view root.
private struct RestoreErrorAlertModifier: ViewModifier {
    var coordinator: BackupCoordinator?

    func body(content: Content) -> some View {
        if let coordinator {
            content.alert(
                "Restore failed",
                isPresented: Binding(
                    get: { coordinator.restoreErrorMessage != nil },
                    set: { isPresented in
                        if !isPresented {
                            coordinator.restoreErrorMessage = nil
                        }
                    }
                ),
                presenting: coordinator.restoreErrorMessage
            ) { _ in
                Button("OK", role: .cancel) {
                    coordinator.restoreErrorMessage = nil
                }
            } message: { message in
                Text(message)
            }
        } else {
            content
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
