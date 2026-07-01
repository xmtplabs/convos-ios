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
    /// Optional accessory rendered as an overlay at the bottom of the
    /// sidebar. Reserved for callers that want extra chrome scoped to
    /// the conversation list only; `MainTabView` no longer uses this
    /// (the builder bar moved into the global bottom chrome), but the
    /// hook stays in case downstream callers need it.
    var sidebarBottomAccessory: AnyView?
    /// Fired with the conversation list's current scroll content-offset Y
    /// on every scroll tick, forwarded from `ConversationsViewController`.
    /// `MainTabView` uses this to reveal the top agent builder bar at the
    /// top of the list and fade it out (revealing a nav-bar button) once
    /// the user scrolls down.
    var onScrollOffsetChange: ((CGFloat) -> Void)?
    /// Extra top inset (in points) for the conversation list to clear the
    /// SwiftUI top chrome (the agent builder bar rendered by `MainTabView`
    /// as a `safeAreaInset(.top)` under the nav bar). SwiftUI's safe-area
    /// chain doesn't reliably propagate that inset to the UIKit collection
    /// view, so we plumb it through explicitly. The list still scrolls
    /// *under* the bar (so it can blur/fade over the content); this inset
    /// just sets where the content rests at the top.
    var topChromeInset: CGFloat = 0
    /// Bottom counterpart to `topChromeInset`, used when the builder bar
    /// pins to the bottom edge (iPad, where the tab bar is at the top).
    var bottomChromeInset: CGFloat = 0
    /// Invoked when the user taps "Explore agents in Contacts" in the
    /// empty-state CTA. The shell switches to the Contacts tab and scrolls
    /// it to the "Suggested agents" section. Nil hides the link (previews).
    var onExploreAgents: (() -> Void)?

    @Namespace private var namespace: Namespace.ID
    @Environment(\.dismiss) private var dismiss: DismissAction
    @State private var sidebarWidth: CGFloat = 0.0
    @Environment(\.horizontalSizeClass) private var horizontalSizeClass: UserInterfaceSizeClass?
    @Environment(\.colorScheme) private var colorScheme: ColorScheme
    @Environment(\.scenePhase) private var scenePhase: ScenePhase
    @State private var conversationPendingExplosion: Conversation?
    @State private var preferredColumn: NavigationSplitViewColumn = .sidebar
    @State private var creditBalance: CreditBalance? = CreditsServices.shared.currentBalance
    @State private var currentSubscription: UserSubscription? = SubscriptionServices.shared.currentSubscription
    @State private var staleDeviceSheetDismissed: Bool = false

    var focusCoordinator: FocusCoordinator {
        viewModel.focusCoordinator
    }

    private var toolbarStatusLabel: String {
        if creditBalance?.isDepleted == true { return "No power" }
        if currentSubscription != nil { return "Plus" }
        return "Basic"
    }

    private var toolbarStatusColor: Color {
        if creditBalance?.isDepleted == true { return .colorLava }
        return .colorTextSecondary
    }

    private var toolbarShowsBolt: Bool {
        creditBalance?.isDepleted == true
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

    /// Empty chats state: the new-user CTA (animated mock conversations,
    /// headline, "Make an agent", "Explore agents in Contacts"). The Make
    /// button opens the same agent-builder sheet the builder bar opens.
    var emptyConversationsView: some View {
        ConversationsEmptyStateView(
            onMakeAgent: { viewModel.onStartAgent() },
            onExploreAgents: onExploreAgents
        )
    }

    /// Bridges `selectedConversationViewModel` (driven by the
    /// `selectedConversationId` setter) to a `navigationDestination(item:)`
    /// Binding so SwiftUI pushes / pops the `ConversationView` onto the
    /// outer `NavigationStack` whenever the user selects / deselects a
    /// conversation.
    private var chatsDetailBinding: Binding<ConversationViewModel?> {
        Binding(
            get: { viewModel.selectedConversationViewModel },
            set: { newValue in
                // A nil transition here is the unambiguous "popped back to
                // home" event: it fires only on an actual pop of the pushed
                // ConversationView, never on a tab switch, modal-sheet
                // dismiss, or app backgrounding. That is exactly when a host's
                // active invite session should end so the inline card collapses
                // to the regular top cell on re-entry.
                if newValue == nil {
                    viewModel.selectedConversationViewModel?.markInviteSessionEndedIfHosting()
                }
                viewModel.selectedConversationId = newValue?.conversation.id
            }
        )
    }

    @ViewBuilder
    private func pushedConversationDestination(viewModel convoVM: ConversationViewModel) -> some View {
        let isReadOnly: Bool = viewModel.staleDeviceObserver.isDeviceRemoved
        ConversationPresenter(
            viewModel: convoVM,
            focusCoordinator: focusCoordinator,
            insetsTopSafeArea: true,
            isReadOnly: isReadOnly,
            sidebarColumnWidth: $sidebarWidth,
            appIndicatorContext: nil,
            sharedIndicatorNamespace: appIndicatorContext.sharedIndicatorNamespace,
            rendersConversationIndicator: false
        ) { focusState, coordinator in
            ConversationView(
                viewModel: convoVM,
                profileSettingsViewModel: profileSettingsViewModel,
                focusState: focusState,
                focusCoordinator: coordinator,
                onScanInviteCode: {},
                onDeleteConversation: {},
                messagesTopBarTrailingItem: .share,
                messagesTopBarTrailingItemEnabled: !convoVM.conversation.isPendingInvite,
                messagesTextFieldEnabled: !convoVM.conversation.isPendingInvite,
                isReadOnly: isReadOnly,
                bottomBarContent: { EmptyView() }
            )
        }
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
        // The builder bar is rendered as a `safeAreaInset` by `MainTabView`
        // (reserving its edge) *and* its height is re-applied here as the
        // collection view's `additionalSafeAreaInsets`. To avoid counting it
        // twice we ignore the system safe area on the bar's edge: `.top` on
        // iPhone (bar pins to the top) and `.bottom` on iPad (bar pins to the
        // bottom, signalled by a non-zero bottom inset).
        //
        // We ignore `.bottom` unconditionally so the collection view's frame
        // reaches the physical screen bottom (under the floating tab bar)
        // rather than stopping at the bottom safe-area line. The list cell
        // hosting view has `clipsToBounds = false`, so cells render in the
        // band under the tab bar, but UICollectionView culls cells the moment
        // they leave its `bounds` regardless of clipping. If the frame stopped
        // at the safe-area line, cells would be removed the instant their
        // bottom crossed that line and visibly pop out mid-scroll instead of
        // sliding off the bottom. Extending the frame moves the cull boundary
        // to the screen edge; `contentInsetAdjustmentBehavior = .automatic`
        // re-applies the tab-bar inset so the last row still rests above it.
        let ignoredSafeAreaEdges: Edge.Set = [.top, .bottom]
        return ConversationsViewRepresentable(
            pinnedConversations: viewModel.pinnedConversations,
            unpinnedConversations: viewModel.unpinnedConversations,
            selectedConversationId: viewModel.selectedConversationId,
            isFilteredResultEmpty: viewModel.isFilteredResultEmpty,
            filterEmptyMessage: viewModel.activeFilter.emptyStateMessage,
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
            onShowAllFilter: { viewModel.activeFilter = .all },
            onScrollOffsetChange: onScrollOffsetChange,
            topChromeInset: topChromeInset,
            bottomChromeInset: bottomChromeInset
        )
        .ignoresSafeArea(edges: ignoredSafeAreaEdges)
    }

    @ViewBuilder
    private var sidebarContent: some View {
        if viewModel.isEmptyCTAActive {
            emptyConversationsView
        } else if viewModel.isFilteredResultEmpty && viewModel.pinnedConversations.isEmpty {
            ScrollView {
                filteredEmptyStateView
            }
        } else {
            conversationsCollectionView
        }
    }

    @ToolbarContentBuilder
    private var sidebarToolbar: some ToolbarContent {
        // The AppIndicatorPill and compose button are now rendered once
        // by `MainTabView.sharedTopBar` (a `safeAreaInset(.top)` custom
        // view) so they persist across tab swaps without flickering.
        // Empty slot kept here so the NavigationSplitView sidebar's
        // toolbar layout slot is still allocated.
        ToolbarItem(placement: .topBarTrailing) { EmptyView() }
    }

    var body: some View {
        let resolver = contactOverride
        return sidebarContent
            .onGeometryChange(for: CGSize.self) {
                $0.size
            } action: { newValue in
                sidebarWidth = newValue.width
            }
            .background(.colorBackgroundSurfaceless)
            .overlay(alignment: .bottom) {
                if let sidebarBottomAccessory {
                    sidebarBottomAccessory
                }
            }
            .navigationDestination(item: chatsDetailBinding) { vm in
                pushedConversationDestination(viewModel: vm)
            }
            .onAppear {
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
            .onReceive(CreditsServices.shared.balancePublisher) { creditBalance = $0 }
            .onReceive(SubscriptionServices.shared.subscriptionPublisher) { currentSubscription = $0 }
            .onChange(of: viewModel.selectedConversationViewModel?.explodeState) { _, newState in
                guard let newState, case .exploded = newState else { return }
                viewModel.selectedConversationId = nil
            }
        .focusable(false)
        .focusEffectDisabled()
        .memberContactOverride(resolver)
        .modifier(ConversationsSheetModifier(
            viewModel: viewModel,
            profileSettingsViewModel: profileSettingsViewModel,
            conversationPendingExplosion: $conversationPendingExplosion,
            staleDeviceSheetDismissed: $staleDeviceSheetDismissed,
            namespace: namespace
        ))
        .onChange(of: viewModel.staleDeviceObserver.isDeviceRemoved) { _, isRemoved in
            // If a fresh revoke arrives while the user has previously
            // dismissed the sheet (e.g. after a separate device re-revokes
            // them post-reset), clear the dismissal so the sheet returns.
            if isRemoved { staleDeviceSheetDismissed = false }
        }
        .onChange(of: scenePhase) { _, newPhase in
            // Re-present the stale-device sheet on each foreground entry so
            // a previously-dismissed banner doesn't permanently hide the
            // fact that the device is in a terminal state.
            if newPhase == .active { staleDeviceSheetDismissed = false }
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
    @Bindable var viewModel: ConversationsViewModel
    let profileSettingsViewModel: ProfileSettingsViewModel
    @Binding var conversationPendingExplosion: Conversation?
    @Binding var staleDeviceSheetDismissed: Bool
    var namespace: Namespace.ID

    private var staleDeviceSheetBinding: Binding<Bool> {
        Binding(
            get: { viewModel.staleDeviceObserver.isDeviceRemoved && !staleDeviceSheetDismissed },
            set: { newValue in
                if !newValue { staleDeviceSheetDismissed = true }
            }
        )
    }

    func body(content: Content) -> some View {
        content
            // The `NewConversationView` and `AgentBuilderView` sheets
            // are both presented from `MainTabView` so the compose
            // button (top-trailing on every tab) and the agent
            // builder bar can zoom into them with a shared namespace.
            .sheet(item: $viewModel.pendingGrantRequest) { request in
                let dismissAction = { viewModel.pendingGrantRequest = nil }
                CloudConnectionGrantRequestSheet(
                    viewModel: viewModel.makeGrantRequestSheetViewModel(for: request),
                    onDismiss: dismissAction
                )
                .presentationDetents([.medium])
            }
            .selfSizingSheet(
                item: $viewModel.pendingJoinerPairing,
                onDismiss: {
                    viewModel.pendingPairDevice = nil
                    viewModel.pendingJoinerPairing = nil
                },
                content: { pairingVM in
                    JoinerPairingSheetView(viewModel: pairingVM)
                        .padding(.top, DesignConstants.Spacing.step5x)
                }
            )
            .selfSizingSheet(isPresented: $viewModel.presentingExplodeInfo) {
                ExplodeInfoView()
            }
            .selfSizingSheet(isPresented: $viewModel.presentingPinLimitInfo) {
                PinLimitInfoView()
            }
            .selfSizingSheet(isPresented: staleDeviceSheetBinding) {
                StaleDeviceSheet(
                    onDelete: { viewModel.resetForStaleDevice() },
                    onContinue: { staleDeviceSheetDismissed = true },
                    isDeleting: viewModel.appSettingsViewModel.isDeleting
                )
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
