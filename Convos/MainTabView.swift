import ConvosCore
import PhotosUI
import SwiftUI

/// Root tab shell for the app. Hosts the existing `ConversationsView` under
/// the "Chats" tab, a placeholder `StuffTabView` under "Stuff", and an
/// iOS 26 `Tab(role: .search)` for the search affordance that floats at
/// the bottom trailing edge.
///
/// The app indicator (leading) and compose button (trailing) live inside
/// each tab's own top bar — not on this shell — because each tab's chrome
/// is contextual (Chats has compose, Stuff and Search don't). See
/// `ConversationsView` for the Chats top-bar wiring.
struct MainTabView: View {
    @Bindable var conversationsViewModel: ConversationsViewModel
    let profileSettingsViewModel: ProfileSettingsViewModel

    /// Tracks which tab is currently active. The underlying SwiftUI
    /// `TabView` uses this for selection so its content / lifecycle
    /// machinery still works — we just hide its built-in tab bar via
    /// `.toolbarVisibility(.hidden, for: .tabBar)` and render
    /// `ConvosTabBar` ourselves so we control the show / hide animation
    /// when a conversation is selected (and can sit it in the same
    /// `GlassEffectContainer` chrome as the builder bar).
    @State private var activeTab: ConvosTab = .chats
    /// NavigationStack path for the Stuff tab. Lifted to this shell so
    /// the bottom chrome can hide when Stuff has a detail pushed, same
    /// way it hides when Chats has a conversation selected.
    @State private var stuffPushedItems: [StuffOverviewItem] = []
    /// Drives the `AgentBuilderBar` between expanded (capsule) and
    /// collapsed (glass circle) states. Held in state with hysteresis
    /// thresholds rather than derived purely from scroll offset so that
    /// a bouncy scroll near the boundary doesn't flicker the bar back
    /// and forth: once collapsed it stays collapsed until the list
    /// returns to the top; once expanded it stays expanded until the
    /// user has scrolled `Constant.collapseScrollThreshold` past the
    /// top.
    @State private var isBuilderBarExpanded: Bool = true
    /// Latest scroll content offset from each tab's primary scroll view.
    /// Tracked per-tab so swapping tabs can re-evaluate the builder bar
    /// state against the new tab's scroll position immediately, instead
    /// of waiting for the user to scroll.
    @State private var chatsScrollOffset: CGFloat = 0
    @State private var stuffScrollOffset: CGFloat = 0
    /// Measured height of the bottom chrome (builder bar + tab bar
    /// stack) published via a `PreferenceKey` from inside the chrome.
    /// Used to push an explicit additional bottom inset down into
    /// `ConversationsViewController`, because SwiftUI's safe-area inset
    /// chain doesn't reliably propagate to the UIKit collection view.
    @State private var bottomChromeHeight: CGFloat = 0
    /// Photo / camera / voice-memo entry points for the
    /// `AgentBuilderBar`. Tapping the photo or camera icon presents
    /// the matching picker first; only once the user has actually picked
    /// (or captured) media do we open the builder sheet, so abandoning
    /// the picker leaves the user where they were. Voice memo skips the
    /// picker and opens the builder directly in recording mode.
    @State private var isPhotoPickerPresented: Bool = false
    @State private var isCameraPresented: Bool = false
    @State private var selectedPhotos: [PhotosPickerItem] = []
    /// Drives the app-settings sheet that the `AppIndicatorPill` (in
    /// every tab that renders one) presents on tap. Lives at this shell
    /// level so both the Chats and Stuff tabs share a single sheet
    /// instance — the alternative (a sheet per tab) would mean tapping
    /// the pill on the wrong tab wouldn't work after a tab swap and
    /// would duplicate the `AppSettingsView` view-model wiring.
    @State private var presentingAppSettings: Bool = false
    /// Set when the inline builder (rendered inside the chats list's
    /// empty state) commits its first conversation. The shell presents
    /// the new conversation as a sheet, mirroring how the bottom-bar
    /// builder itself is presented over the tabs. The inline builder VM
    /// lives inside `ConversationsView` (so it's scoped to the chats tab);
    /// only the post-commit sheet has to bubble up to this level.
    @State private var presentingCommittedConversation: ConversationViewModel?
    @State private var committedConversationFocusCoordinator: FocusCoordinator = FocusCoordinator(horizontalSizeClass: nil)
    @State private var committedConversationSidebarWidth: CGFloat = 0
    /// Live credit balance + subscription drive the app-indicator subtitle.
    /// Seeded from the services' current values so the first render doesn't
    /// flicker, then kept in sync via `.onReceive` on their publishers.
    @State private var creditBalance: CreditBalance? = CreditsServices.shared.currentBalance
    @State private var userSubscription: UserSubscription? = SubscriptionServices.shared.currentSubscription
    /// Shared namespace for the agent-builder bar -> sheet zoom
    /// transition and the app-settings pill -> sheet zoom transition.
    /// The bar / pill apply
    /// `.matchedTransitionSource(id: ..., in: namespace)` and the
    /// matching sheet uses `.navigationTransition(.zoom(sourceID: ..., in: namespace))`
    /// to get the same source-to-sheet morph the compose button uses in
    /// `ConversationsView`.
    @Namespace private var namespace: Namespace.ID

    private var appIndicatorContext: AppIndicatorContext {
        AppIndicatorContext(
            profileImage: profileSettingsViewModel.profileImage,
            subtitle: indicatorSubtitle,
            transitionNamespace: namespace,
            transitionId: Constant.appSettingsTransitionId,
            onTap: { presentingAppSettings = true }
        )
    }

    private var indicatorSubtitle: AppIndicatorSubtitle {
        if let creditBalance, creditBalance.isDepleted {
            return .symbol(systemName: "battery.0percent", tint: .colorRed, accessibilityLabel: "Out of credits")
        }
        if let creditBalance, creditBalance.isLow {
            return .symbol(systemName: "battery.25percent", tint: .colorRed, accessibilityLabel: "Low credits")
        }
        if let userSubscription {
            return .text(SubscriptionCopy.displayName(for: userSubscription.tier))
        }
        return .text("Free")
    }

    /// `true` once a conversation has been pushed onto the Chats tab's
    /// navigation stack. Hides the builder bar (via the safe-area inset
    /// conditional) and the tab bar so the conversation detail can use
    /// the full screen. Bound to `conversationsViewModel` because the
    /// selection model lives there.
    private var isConversationSelected: Bool {
        conversationsViewModel.selectedConversationViewModel != nil
            || !stuffPushedItems.isEmpty
    }

    /// Mirrors [[ConversationsViewModel.isEmptyCTAActive]]. When true the
    /// chats list is empty and we render an inline agent builder as the
    /// primary content (instead of the tabs) so the user is guided
    /// straight into making their first agent.
    private var isInlineBuilderActive: Bool {
        conversationsViewModel.isEmptyCTAActive
    }

    /// Scroll offset for whichever tab is currently active.
    private var activeTabScrollOffset: CGFloat {
        switch activeTab {
        case .chats: chatsScrollOffset
        case .stuff: stuffScrollOffset
        case .search: 0
        }
    }

    /// Apply hysteresis to the bar expansion state in response to a
    /// scroll offset update from the active tab. Collapses once the
    /// user has scrolled `collapseScrollThreshold` past the top, and
    /// expands again once the list is back near the top (within
    /// `expandScrollThreshold`). The gap between the two thresholds
    /// prevents a bouncing scroll near the boundary from flickering the
    /// bar.
    private func updateBuilderBarExpansion(forOffset offset: CGFloat) {
        if isBuilderBarExpanded {
            if offset > Constant.collapseScrollThreshold {
                withAnimation(.smooth(duration: 0.25)) {
                    isBuilderBarExpanded = false
                }
            }
        } else {
            if offset <= Constant.expandScrollThreshold {
                withAnimation(.smooth(duration: 0.25)) {
                    isBuilderBarExpanded = true
                }
            }
        }
    }

    var body: some View {
        tabView
            .safeAreaInset(edge: .bottom, spacing: 0) {
                if !isConversationSelected && !isInlineBuilderActive {
                    bottomChrome
                        .transition(.blurReplace)
                }
            }
            .animation(.smooth(duration: 0.35), value: isConversationSelected)
            .animation(.smooth(duration: 0.35), value: isInlineBuilderActive)
            .onReceive(CreditsServices.shared.balancePublisher) { newBalance in
                creditBalance = newBalance
            }
            .onReceive(SubscriptionServices.shared.subscriptionPublisher) { newSubscription in
                userSubscription = newSubscription
            }
            .sheet(item: $presentingCommittedConversation) { convoVM in
                committedConversationSheetContent(viewModel: convoVM)
            }
            .modifier(MainTabSheetsModifier(
                conversationsViewModel: conversationsViewModel,
                profileSettingsViewModel: profileSettingsViewModel,
                presentingAppSettings: $presentingAppSettings,
                isPhotoPickerPresented: $isPhotoPickerPresented,
                isCameraPresented: $isCameraPresented,
                selectedPhotos: $selectedPhotos,
                namespace: namespace,
                onPhotosChanged: handleSelectedPhotosChanged(to:),
                onCameraImageCaptured: handleCameraImageCaptured,
                onCameraVideoCaptured: handleCameraVideoCaptured
            ))
    }

    @ViewBuilder
    private func committedConversationSheetContent(viewModel convoVM: ConversationViewModel) -> some View {
        ConversationPresenter(
            viewModel: convoVM,
            focusCoordinator: committedConversationFocusCoordinator,
            insetsTopSafeArea: false,
            sidebarColumnWidth: $committedConversationSidebarWidth
        ) { focusState, coordinator in
            NavigationStack {
                ConversationView(
                    viewModel: convoVM,
                    profileSettingsViewModel: profileSettingsViewModel,
                    focusState: focusState,
                    focusCoordinator: coordinator,
                    onScanInviteCode: {},
                    onDeleteConversation: { presentingCommittedConversation = nil },
                    messagesTopBarTrailingItem: .share,
                    messagesTopBarTrailingItemEnabled: true,
                    messagesTextFieldEnabled: true,
                    bottomBarContent: { EmptyView() }
                )
                .toolbar { committedConversationCloseToolbarItem }
            }
        }
        .presentationSizing(.page)
    }

    @ToolbarContentBuilder
    private var committedConversationCloseToolbarItem: some ToolbarContent {
        ToolbarItem(placement: .topBarLeading) {
            Button(role: .close) {
                presentingCommittedConversation = nil
            }
            .accessibilityIdentifier("close-committed-agent-conversation")
        }
    }

    @ViewBuilder
    private var tabView: some View {
        TabView(selection: $activeTab) {
            Tab(value: ConvosTab.chats) {
                ConversationsView(
                    viewModel: conversationsViewModel,
                    profileSettingsViewModel: profileSettingsViewModel,
                    appIndicatorContext: appIndicatorContext,
                    sidebarBottomAccessory: nil,
                    onScrollOffsetChange: { offset in
                        chatsScrollOffset = offset
                        if activeTab == .chats {
                            updateBuilderBarExpansion(forOffset: offset)
                        }
                    },
                    bottomChromeInset: bottomChromeHeight,
                    presentingCommittedConversation: $presentingCommittedConversation
                )
                .toolbarVisibility(.hidden, for: .tabBar)
            }

            Tab(value: ConvosTab.stuff) {
                StuffTabView(
                    appIndicatorContext: appIndicatorContext,
                    conversationsViewModel: conversationsViewModel,
                    pushedItems: $stuffPushedItems,
                    onScrollOffsetChange: { offset in
                        stuffScrollOffset = offset
                        if activeTab == .stuff {
                            updateBuilderBarExpansion(forOffset: offset)
                        }
                    }
                )
                .toolbarVisibility(.hidden, for: .tabBar)
            }

            Tab(value: ConvosTab.search) {
                SearchTabView()
                    .toolbarVisibility(.hidden, for: .tabBar)
            }
        }
        .onChange(of: activeTab) { _, _ in
            updateBuilderBarExpansion(forOffset: activeTabScrollOffset)
        }
    }

    /// The shared bottom chrome — agent builder bar stacked above the
    /// custom `ConvosTabBar`. Lives in one VStack so when the chrome
    /// hides (because a conversation got selected) the builder bar and
    /// the tab pills disappear together. The system tab bar is hidden
    /// in every tab via `.toolbarVisibility(.hidden, for: .tabBar)` so
    /// only this custom chrome shows up at the bottom.
    @ViewBuilder
    private var bottomChrome: some View {
        VStack(spacing: DesignConstants.Spacing.step3x) {
            agentBuilderBar
            ConvosTabBar(activeTab: $activeTab)
                .padding(.horizontal, DesignConstants.Spacing.step6x)
        }
        .background(
            GeometryReader { proxy in
                Color.clear
                    .preference(key: BottomChromeHeightKey.self, value: proxy.size.height)
            }
        )
        .onPreferenceChange(BottomChromeHeightKey.self) { value in
            bottomChromeHeight = value
        }
    }

    @ViewBuilder
    private var agentBuilderBar: some View {
        AgentBuilderBar(
            isExpanded: isBuilderBarExpanded,
            onTap: openBuilder,
            onTapPhotos: { isPhotoPickerPresented = true },
            onTapCamera: { isCameraPresented = true },
            onTapVoiceMemo: openBuilderInVoiceMemoMode,
            transitionSourceNamespace: namespace,
            transitionSourceId: Constant.builderTransitionId
        )
        .padding(.horizontal, DesignConstants.Spacing.step6x)
    }

    private func openBuilder() {
        conversationsViewModel.onStartAgent()
    }

    /// Open the builder and immediately start voice-memo recording. The
    /// builder's voice-memo recorder is created lazily inside its init
    /// path, so we schedule the start call on the next runloop tick to
    /// give the VM a moment to wire up before we call `startRecording`.
    private func openBuilderInVoiceMemoMode() {
        conversationsViewModel.onStartAgent()
        guard let builderViewModel = conversationsViewModel.agentBuilderViewModel else { return }
        Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(50))
            builderViewModel.startVoiceMemoRecording(restoreComposerFocusAfter: true)
        }
    }

    /// Camera capture (still image): open the builder and load the image
    /// into the inner conversation VM's attachment list. The fullScreenCover
    /// is dismissed by flipping `isCameraPresented` before opening the
    /// builder so the sheet sits on top of the (now-dismissing) camera
    /// cover with no visible flash.
    private func handleCameraImageCaptured(_ image: UIImage) {
        isCameraPresented = false
        conversationsViewModel.onStartAgent()
        guard let builderViewModel = conversationsViewModel.agentBuilderViewModel else { return }
        builderViewModel.addPhotoAttachment(image)
    }

    private func handleCameraVideoCaptured(_ url: URL) {
        isCameraPresented = false
        conversationsViewModel.onStartAgent()
        guard let builderViewModel = conversationsViewModel.agentBuilderViewModel else { return }
        builderViewModel.addVideoAttachment(url: url)
    }

    /// Photo / video library selection: load each picked item asynchronously
    /// (videos transferred as `VideoFile`, stills as `Data` -> `UIImage`)
    /// and add them to the freshly-created builder VM. The picker is
    /// dismissed and `selectedPhotos` is cleared synchronously so a
    /// subsequent tap on the photo icon opens the picker fresh.
    private func handleSelectedPhotosChanged(to newValue: [PhotosPickerItem]) {
        guard !newValue.isEmpty else { return }
        let items = newValue
        selectedPhotos = []
        isPhotoPickerPresented = false
        conversationsViewModel.onStartAgent()
        guard let builderViewModel = conversationsViewModel.agentBuilderViewModel else { return }
        Task {
            for item in items {
                if let videoFile = try? await item.loadTransferable(type: VideoFile.self) {
                    await MainActor.run { builderViewModel.addVideoAttachment(url: videoFile.url) }
                } else if let data = try? await item.loadTransferable(type: Data.self),
                          let image = UIImage(data: data) {
                    await MainActor.run { builderViewModel.addPhotoAttachment(image) }
                }
            }
        }
    }

    private enum Constant {
        static let builderTransitionId: String = "agent-builder-transition-source"
        static let appSettingsTransitionId: String = "app-settings-transition-source"
        static let composerTransitionId: String = "composer-transition-source"
        /// Hysteresis thresholds for the builder bar expansion. The gap
        /// between them eats overscroll bounce noise near the top so the
        /// bar doesn't flicker when the user is dragging back and forth
        /// at the boundary.
        static let collapseScrollThreshold: CGFloat = 20.0
        static let expandScrollThreshold: CGFloat = 4.0
    }
}

/// Carries the measured height of `MainTabView.bottomChrome` up via the
/// SwiftUI preference system so the host can plumb it into UIKit-hosted
/// scroll views that don't see SwiftUI's safe-area inset.
private struct BottomChromeHeightKey: PreferenceKey {
    static let defaultValue: CGFloat = 0
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) {
        value = max(value, nextValue())
    }
}

/// All the sheets / covers / pickers that the `MainTabView` shell hosts,
/// extracted into a `ViewModifier` so the host's `body` stays within the
/// `warn-long-expression-type-checking` budget.
private struct MainTabSheetsModifier: ViewModifier {
    @Bindable var conversationsViewModel: ConversationsViewModel
    let profileSettingsViewModel: ProfileSettingsViewModel
    @Binding var presentingAppSettings: Bool
    @Binding var isPhotoPickerPresented: Bool
    @Binding var isCameraPresented: Bool
    @Binding var selectedPhotos: [PhotosPickerItem]
    let namespace: Namespace.ID
    let onPhotosChanged: ([PhotosPickerItem]) -> Void
    let onCameraImageCaptured: (UIImage) -> Void
    let onCameraVideoCaptured: (URL) -> Void

    func body(content: Content) -> some View {
        content
            .sheet(item: $conversationsViewModel.agentBuilderViewModel) { builderViewModel in
                AgentBuilderView(
                    viewModel: builderViewModel,
                    profileSettingsViewModel: profileSettingsViewModel
                )
                .background(.colorBackgroundSurfaceless)
                .presentationSizing(.page)
                .navigationTransition(
                    .zoom(sourceID: "agent-builder-transition-source", in: namespace)
                )
            }
            .photosPicker(
                isPresented: $isPhotoPickerPresented,
                selection: $selectedPhotos,
                maxSelectionCount: maxPendingMediaAttachments,
                matching: .any(of: [.images, .videos])
            )
            .onChange(of: selectedPhotos) { _, newValue in
                onPhotosChanged(newValue)
            }
            .fullScreenCover(isPresented: $isCameraPresented) {
                CameraPickerView(
                    onImageCaptured: onCameraImageCaptured,
                    onVideoCaptured: onCameraVideoCaptured
                )
                .ignoresSafeArea()
            }
            .sheet(isPresented: $presentingAppSettings) {
                AppSettingsView(
                    viewModel: conversationsViewModel.appSettingsViewModel,
                    profileSettingsViewModel: profileSettingsViewModel,
                    session: conversationsViewModel.session,
                    onDeleteAllData: conversationsViewModel.deleteAllData
                )
                .navigationTransition(
                    .zoom(sourceID: "app-settings-transition-source", in: namespace)
                )
                .interactiveDismissDisabled(conversationsViewModel.appSettingsViewModel.isDeleting)
            }
            .sheet(item: $conversationsViewModel.newConversationViewModel) { newConvoViewModel in
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
    }
}
