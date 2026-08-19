import ConvosComposer
import ConvosCore
import ConvosMetrics
import SwiftUI

/// The app's front door: the user's Space, with every convo across the top.
///
/// The screen is a `ConversationView` wearing new chrome. That is not a
/// shortcut - it is what the Space *is*. A conversation already renders its
/// Space web surface as the permanent backing view and floats a resizable
/// sheet over it, and the personal Space is a conversation whose sheet has
/// only the agent lane in it. Rebuilding that stack would have meant a second
/// copy of the Home surface, the detents, the composer and the agent
/// transcript, all drifting away from the ones the conversation screen keeps
/// using.
///
/// What is new is the chrome above it: the top bar, the strip of convos, and
/// the sheet the Space capsule drops.
///
/// **Layering.** The agent sheet is a real presentation sheet, so it draws
/// above anything this view puts on screen - see the note on
/// `ConversationSheetPresentation`. The top bar and the strip sit high enough
/// that the sheet never reaches them at its resting size, and the Space sheet
/// is capped short of the sheet's collapsed top edge for the same reason.
struct SpaceHomeView: View {
    @Bindable var conversationsViewModel: ConversationsViewModel
    let profileSettingsViewModel: ProfileSettingsViewModel
    let coreActions: any CoreActions
    /// Plan name or the low-power bolt, resolved by the shell that owns the
    /// subscription and credit observers.
    let subtitle: AppIndicatorSubtitle
    let onProfile: () -> Void
    let onCompose: () -> Void

    @State private var spaceHome: SpaceHomeViewModel
    @State private var isSpaceSheetOpen: Bool = false
    @State private var conversationPendingExplosion: Conversation?
    @State private var sidebarWidth: CGFloat = 0.0
    @Namespace private var indicatorNamespace: Namespace.ID

    init(
        conversationsViewModel: ConversationsViewModel,
        profileSettingsViewModel: ProfileSettingsViewModel,
        coreActions: any CoreActions,
        subtitle: AppIndicatorSubtitle,
        onProfile: @escaping () -> Void,
        onCompose: @escaping () -> Void
    ) {
        self.conversationsViewModel = conversationsViewModel
        self.profileSettingsViewModel = profileSettingsViewModel
        self.coreActions = coreActions
        self.subtitle = subtitle
        self.onProfile = onProfile
        self.onCompose = onCompose
        _spaceHome = State(
            wrappedValue: SpaceHomeViewModel(
                session: conversationsViewModel.session,
                coreActions: coreActions
            )
        )
    }

    /// Every convo, most recent first. The Space itself never appears: it is an
    /// agent DM, and the conversations list has always filtered those out.
    ///
    /// Taken in the order the repository hands it over rather than re-sorted
    /// here. That order already accounts for something a local sort would miss:
    /// a reply in a group's folded agent-DM lane floats the group, so the
    /// freshest message in a row is not always the row's own. Re-deriving it
    /// would quietly disagree with the list in the Space sheet.
    private var recentConversations: [Conversation] {
        conversationsViewModel.conversations
    }

    private var spaceTitle: String {
        spaceHome.space?.name.flatMap { $0.isEmpty ? nil : $0 } ?? "Your Space"
    }

    var body: some View {
        ZStack(alignment: .top) {
            spaceSurface
            topChrome
            spaceSheetLayer
        }
        .background(Color.colorBackgroundSurfaceless)
        // The Space Home draws its own top bar, so the navigation bar would
        // only add a second empty one above it.
        .toolbar(.hidden, for: .navigationBar)
        .navigationDestination(item: pushedConversationBinding) { pushed in
            pushedConversation(pushed)
        }
        .task { await spaceHome.load() }
        .onAppear { conversationsViewModel.onAppear() }
        .onDisappear { conversationsViewModel.onDisappear() }
        .accessibilityIdentifier("space-home")
    }

    // MARK: - The Space itself

    @ViewBuilder
    private var spaceSurface: some View {
        if let spaceViewModel = spaceHome.spaceViewModel {
            ConversationPresenter(
                viewModel: spaceViewModel,
                focusCoordinator: conversationsViewModel.focusCoordinator,
                insetsTopSafeArea: true,
                isReadOnly: false,
                sidebarColumnWidth: $sidebarWidth,
                appIndicatorContext: nil,
                sharedIndicatorNamespace: indicatorNamespace,
                rendersConversationIndicator: false
            ) { _, coordinator in
                ConversationView(
                    viewModel: spaceViewModel,
                    profileSettingsViewModel: profileSettingsViewModel,
                    focusCoordinator: coordinator,
                    onScanInviteCode: {},
                    onDeleteConversation: {},
                    messagesTopBarTrailingItem: .share,
                    messagesTopBarTrailingItemEnabled: false,
                    messagesTextFieldEnabled: true,
                    isReadOnly: false,
                    initialAgentDmInboxId: nil,
                    bottomBarContent: { EmptyView() }
                )
            }
        } else {
            unresolvedSpace
        }
    }

    /// Before the Space exists. The chrome stays put, so the screen settles
    /// into itself rather than replacing one layout with another.
    private var unresolvedSpace: some View {
        VStack(spacing: DesignConstants.Spacing.step3x) {
            if let failure = spaceHome.failure {
                Text(failure)
                    .font(.callout)
                    .foregroundStyle(.colorTextSecondary)
                    .multilineTextAlignment(.center)
            } else {
                ProgressView()
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    // MARK: - Chrome

    private var topChrome: some View {
        VStack(spacing: 0) {
            SpaceHomeTopBar(
                profileImage: profileSettingsViewModel.profileImage,
                spaceTitle: spaceTitle,
                subtitle: subtitle,
                onProfile: onProfile,
                onSpace: { toggleSpaceSheet() },
                onCompose: onCompose
            )
            SpaceHomeConversationStrip(
                conversations: recentConversations,
                onSelect: { select($0) }
            )
            Spacer(minLength: 0)
        }
    }

    // MARK: - The convos list, dropped from the capsule

    @ViewBuilder
    private var spaceSheetLayer: some View {
        if isSpaceSheetOpen {
            Color.black.opacity(Constant.scrimOpacity)
                .ignoresSafeArea()
                .onTapGesture { toggleSpaceSheet() }
                .transition(.opacity)
                .zIndex(1)
        }
        if isSpaceSheetOpen {
            GeometryReader { proxy in
                SpaceSheet(
                    viewModel: conversationsViewModel,
                    conversations: recentConversations,
                    spaceTitle: spaceTitle,
                    onSelectSpace: { toggleSpaceSheet() },
                    onSelectConversation: { select($0) },
                    conversationPendingExplosion: $conversationPendingExplosion
                )
                .frame(height: sheetHeight(in: proxy))
                .clipShape(
                    .rect(
                        bottomLeadingRadius: Constant.sheetCornerRadius,
                        bottomTrailingRadius: Constant.sheetCornerRadius
                    )
                )
                .shadow(color: .black.opacity(Constant.sheetShadowOpacity), radius: 12, y: 2)
                .ignoresSafeArea(edges: .top)
            }
            .transition(.move(edge: .top))
            .zIndex(2)
        }
    }

    /// Short of the full screen on purpose: the agent sheet is a presentation
    /// and draws above this one, so the list stops before it reaches it.
    private func sheetHeight(in proxy: GeometryProxy) -> CGFloat {
        min(Constant.sheetHeight, proxy.size.height * Constant.sheetMaxScreenFraction)
    }

    // MARK: - Pushed conversations

    /// Mirrors the conversations list's binding: a nil transition is the
    /// unambiguous "popped back to the Space" event, and is where a host's
    /// active invite session ends.
    private var pushedConversationBinding: Binding<ConversationViewModel?> {
        Binding(
            get: { conversationsViewModel.selectedConversationViewModel },
            set: { newValue in
                if newValue == nil {
                    conversationsViewModel.endHostedInviteSessionOnPop()
                }
                conversationsViewModel.selectedConversationId = newValue?.conversation.id
            }
        )
    }

    @ViewBuilder
    private func pushedConversation(_ convoVM: ConversationViewModel) -> some View {
        let isReadOnly: Bool = conversationsViewModel.staleDeviceObserver.isDeviceRemoved
        ConversationPresenter(
            viewModel: convoVM,
            focusCoordinator: conversationsViewModel.focusCoordinator,
            insetsTopSafeArea: true,
            isReadOnly: isReadOnly,
            sidebarColumnWidth: $sidebarWidth,
            appIndicatorContext: nil,
            sharedIndicatorNamespace: indicatorNamespace,
            rendersConversationIndicator: false
        ) { _, coordinator in
            ConversationView(
                viewModel: convoVM,
                profileSettingsViewModel: profileSettingsViewModel,
                focusCoordinator: coordinator,
                onScanInviteCode: {},
                onDeleteConversation: {},
                messagesTopBarTrailingItem: .share,
                messagesTopBarTrailingItemEnabled: !convoVM.conversation.isPendingInvite,
                messagesTextFieldEnabled: !convoVM.conversation.isPendingInvite,
                isReadOnly: isReadOnly,
                initialAgentDmInboxId: conversationsViewModel.selectedInitialAgentDmInboxId,
                bottomBarContent: { EmptyView() }
            )
        }
    }

    // MARK: - Actions

    private func toggleSpaceSheet() {
        withAnimation(.spring(response: 0.34, dampingFraction: 0.86)) {
            isSpaceSheetOpen.toggle()
        }
    }

    /// Opening a convo closes the list behind it, so coming back lands on the
    /// Space rather than on a sheet nobody asked to still be there.
    private func select(_ conversation: Conversation) {
        if isSpaceSheetOpen {
            toggleSpaceSheet()
        }
        conversationsViewModel.select(conversation)
    }

    private enum Constant {
        static let sheetHeight: CGFloat = 520.0
        static let sheetMaxScreenFraction: CGFloat = 0.62
        static let sheetCornerRadius: CGFloat = 38.0
        static let scrimOpacity: CGFloat = 0.25
        static let sheetShadowOpacity: CGFloat = 0.12
    }
}
