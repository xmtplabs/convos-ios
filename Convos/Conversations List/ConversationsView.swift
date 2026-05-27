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
    /// `MainTabView` uses this to flip the agent builder bar between
    /// expanded and collapsed states.
    var onScrollOffsetChange: ((CGFloat) -> Void)?
    /// Extra bottom inset (in points) for the conversation list to clear
    /// the SwiftUI bottom chrome (builder bar + custom tab bar) rendered
    /// by `MainTabView` as a `safeAreaInset`. SwiftUI's safe-area chain
    /// doesn't reliably propagate that inset to the UIKit collection
    /// view, so we plumb it through explicitly.
    var bottomChromeInset: CGFloat = 0
    /// Binding into the shell's "present this conversation as a sheet"
    /// slot. Set by the inline agent builder (rendered in the chats
    /// list's empty state) right after `commit()` lands a brand-new
    /// conversation. `MainTabView` listens for non-nil here and shows
    /// the conversation in a sheet, mirroring how the bottom-bar
    /// builder is presented over the tabs.
    @Binding var presentingCommittedConversation: ConversationViewModel?

    /// Dedicated builder VM for the chats-list empty state. Created
    /// lazily once the user is in the no-convos-yet state and torn down
    /// the moment they ship their first convo (which also flips the
    /// empty state off, so the inline builder unmounts naturally).
    @State private var inlineBuilderViewModel: AgentBuilderViewModel?

    @Namespace private var namespace: Namespace.ID
    @Environment(\.dismiss) private var dismiss: DismissAction
    @State private var sidebarWidth: CGFloat = 0.0
    @Environment(\.horizontalSizeClass) private var horizontalSizeClass: UserInterfaceSizeClass?
    @Environment(\.colorScheme) private var colorScheme: ColorScheme
    @State private var conversationPendingExplosion: Conversation?
    @State private var preferredColumn: NavigationSplitViewColumn = .sidebar
    @State private var creditBalance: CreditBalance? = CreditsServices.shared.currentBalance
    @State private var currentSubscription: UserSubscription? = SubscriptionServices.shared.currentSubscription

    var focusCoordinator: FocusCoordinator {
        viewModel.focusCoordinator
    }

    private var toolbarStatusLabel: String {
        if creditBalance?.isDepleted == true { return "⚡ No power" }
        if currentSubscription != nil { return "Plus" }
        return "Basic"
    }

    private var toolbarStatusColor: Color {
        if creditBalance?.isDepleted == true { return .colorLava }
        return .colorTextSecondary
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
        emptyConversationsView
    }

    @ViewBuilder
    var emptyConversationsView: some View {
        if let inlineBuilderViewModel {
            AgentBuilderView(
                viewModel: inlineBuilderViewModel,
                profileSettingsViewModel: profileSettingsViewModel,
                mode: .inline,
                onCommitted: handleInlineBuilderCommit(_:)
            )
        }
        // Until the inline builder VM has been spun up by
        // `ensureInlineBuilder()`, the empty state renders nothing.
        // The previous "Pop-up private convo" fallback CTA caused a
        // visible flash on cold launch and has been removed in favor
        // of a blank empty state for that one frame.
    }

    private func ensureInlineBuilder() {
        // Recreate the VM when it's nil, when the previous one has
        // already committed, or when it's been discarded. A committed
        // VM renders `Color.clear` in `inlineBody`. A discarded VM had
        // `discard()` called on it (e.g. by `AgentBuilderView.onDisappear`
        // when the user left the chats tab without committing), so its
        // tasks are cancelled and its conversation has been torn down.
        // Either case leaves the empty state non-functional until we
        // spin up a fresh VM.
        let needsFresh: Bool = inlineBuilderViewModel == nil
            || inlineBuilderViewModel?.hasCommitted == true
            || inlineBuilderViewModel?.didDiscard == true
        if needsFresh {
            inlineBuilderViewModel = AgentBuilderViewModel(session: viewModel.session)
        }
    }

    private func handleInlineBuilderCommit(_ convoVM: ConversationViewModel) {
        presentingCommittedConversation = convoVM
        // Intentionally keep `inlineBuilderViewModel` around (in its
        // committed state). The chats list will update with the new
        // conversation shortly, at which point `isEmptyCTAActive` flips
        // false and `sidebarContent` swaps from the empty branch to the
        // collection view, unmounting the builder naturally. Clearing
        // here eagerly would leave a blank `Color` behind the sheet if
        // the user dismisses before the list catches up — see the
        // `onChange` below that recreates a fresh VM in that race.
    }

    /// Called whenever the post-commit conversation sheet dismisses.
    /// If the chats list is still in its empty state at that moment
    /// (DB sync race — the new convo hasn't landed in
    /// `conversations` yet), swap the committed inline builder VM out
    /// for a fresh one so the user sees an interactive composer
    /// instead of a stuck post-commit gray rect.
    /// Bridges `selectedConversationViewModel` (driven by the
    /// `selectedConversationId` setter) to a `navigationDestination(item:)`
    /// Binding so SwiftUI pushes / pops the `ConversationView` onto the
    /// outer `NavigationStack` whenever the user selects / deselects a
    /// conversation.
    private var chatsDetailBinding: Binding<ConversationViewModel?> {
        Binding(
            get: { viewModel.selectedConversationViewModel },
            set: { newValue in
                viewModel.selectedConversationId = newValue?.conversation.id
            }
        )
    }

    @ViewBuilder
    private func pushedConversationDestination(viewModel convoVM: ConversationViewModel) -> some View {
        ConversationPresenter(
            viewModel: convoVM,
            focusCoordinator: focusCoordinator,
            insetsTopSafeArea: true,
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
                bottomBarContent: { EmptyView() }
            )
        }
    }

    private func handleCommittedSheetDidDismiss() {
        guard viewModel.isEmptyCTAActive else { return }
        inlineBuilderViewModel = AgentBuilderViewModel(session: viewModel.session)
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
            onShowAllFilter: { viewModel.activeFilter = .all },
            onScrollOffsetChange: onScrollOffsetChange,
            bottomChromeInset: bottomChromeInset
        )
        .ignoresSafeArea(edges: .top)
    }

    @ViewBuilder
    private var sidebarContent: some View {
        if viewModel.isEmptyCTAActive {
            emptyConversationsViewScrollable
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
                if viewModel.isEmptyCTAActive {
                    ensureInlineBuilder()
                }
            }
            .onChange(of: viewModel.isEmptyCTAActive) { _, isActive in
                // Re-fire whenever the chats list flips back to empty
                // (e.g. user just deleted the last conversation, or a
                // post-commit sheet just dismissed and the new convo
                // hasn't landed in the list yet). `.task` attached to
                // the conditional empty view branch doesn't reliably
                // fire when the branch's `if let` body is empty
                // (committed VM or nil VM), so the trigger lives here
                // on the parent body where firing is deterministic.
                if isActive {
                    ensureInlineBuilder()
                }
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
            .onChange(of: presentingCommittedConversation == nil) { wasNil, isNil in
                guard !wasNil, isNil else { return }
                handleCommittedSheetDidDismiss()
            }
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
        ),
        presentingCommittedConversation: .constant(nil)
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
        ),
        presentingCommittedConversation: .constant(nil)
    )
}
