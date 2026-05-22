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
    /// Last tab the user was on before switching to `.search`. Tapping
    /// the cancel button in the search input bar restores this so the
    /// X-cancel returns the user to where they came from instead of
    /// always defaulting to Chats.
    @State private var lastNonSearchTab: ConvosTab = .chats
    /// NavigationStack path for the Stuff tab. Lifted to this shell so
    /// the bottom chrome can hide when Stuff has a detail pushed, same
    /// way it hides when Chats has a conversation selected.
    @State private var stuffPushedItems: [StuffOverviewItem] = []
    /// Hydrated VM for the topmost pushed Stuff item, so the shared
    /// overlay can render the centered conversation indicator for it
    /// (same morph as a chats push). Synced via `.onChange` on
    /// `stuffPushedItems` — created lazily, cleared on pop.
    @State private var stuffPushedConvoVM: ConversationViewModel?
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
    /// Current contents of the search input bar that replaces the agent
    /// builder bar when the Search tab is active. Owned by `MainTabView`
    /// (rather than the tab's own view) because the bar lives in
    /// `bottomChrome`, which the shell builds; reading it from the
    /// tab's view requires plumbing this binding down.
    @State private var searchQuery: String = ""
    @FocusState private var isSearchFieldFocused: Bool
    /// Set when the inline builder (rendered inside the chats list's
    /// empty state) commits its first conversation. The shell presents
    /// the new conversation as a sheet, mirroring how the bottom-bar
    /// builder itself is presented over the tabs. The inline builder VM
    /// lives inside `ConversationsView` (so it's scoped to the chats tab);
    /// only the post-commit sheet has to bubble up to this level.
    @State private var presentingCommittedConversation: ConversationViewModel?
    @State private var committedConversationFocusCoordinator: FocusCoordinator = FocusCoordinator(horizontalSizeClass: nil)
    @State private var committedConversationSidebarWidth: CGFloat = 0
    /// Live subscription drives the app-indicator subtitle (plan name,
    /// or "Free" when not subscribed). Seeded from the service's current
    /// value so the first render doesn't flicker, then kept in sync via
    /// `.onReceive` on the publisher.
    @State private var userSubscription: UserSubscription? = SubscriptionServices.shared.currentSubscription
    /// Shared namespace for the agent-builder bar -> sheet zoom
    /// transition and the app-settings pill -> sheet zoom transition.
    /// The bar / pill apply
    /// `.matchedTransitionSource(id: ..., in: namespace)` and the
    /// matching sheet uses `.navigationTransition(.zoom(sourceID: ..., in: namespace))`
    /// to get the same source-to-sheet morph the compose button uses in
    /// `ConversationsView`.
    @Namespace private var namespace: Namespace.ID
    /// Dedicated namespace for the AppIndicatorPill ↔ centered
    /// conversation indicator matched-geometry effect. The shared
    /// pill lives in `sharedTopBar` (above the TabView) while the
    /// centered conv pill lives inside a per-tab `ConversationPresenter`,
    /// so the morph needs a namespace that spans both surfaces.
    @Namespace private var sharedIndicatorNamespace: Namespace.ID
    @Environment(\.safeAreaInsets) private var safeAreaInsets: EdgeInsets
    /// Focus state for the lifted centered conversation indicator. The
    /// indicator's tap-to-edit-name action opens the quick editor via
    /// this binding; it's separate from the pushed conversation view's
    /// own focus chain (which still drives the message text field).
    @FocusState private var liftedIndicatorFocus: MessagesViewInputFocus?
    @State private var liftedIndicatorFocusCoordinator: FocusCoordinator = FocusCoordinator(horizontalSizeClass: nil)

    private var appIndicatorContext: AppIndicatorContext {
        AppIndicatorContext(
            profileImage: profileSettingsViewModel.profileImage,
            subtitle: indicatorSubtitle,
            transitionNamespace: namespace,
            transitionId: Constant.appSettingsTransitionId,
            sharedIndicatorNamespace: sharedIndicatorNamespace,
            onTap: { presentingAppSettings = true }
        )
    }

    private var indicatorSubtitle: AppIndicatorSubtitle {
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

    /// True while the user is on the search tab. Swaps the agent
    /// builder bar in `bottomChrome` for the search input bar.
    private var isOnSearchTab: Bool {
        activeTab == .search
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
        ZStack {
            NavigationStack {
                tabView
                    .safeAreaInset(edge: .bottom, spacing: 0) {
                        if !isConversationSelected && !isInlineBuilderActive {
                            bottomChrome
                                .transition(.blurReplace)
                        }
                    }
                    .toolbar { sharedToolbar }
                    .toolbar(isConversationSelected ? .hidden : .visible, for: .navigationBar)
            }

            sharedAppIndicatorOverlay
        }
        .animation(.smooth(duration: 0.35), value: isConversationSelected)
        .animation(.smooth(duration: 0.35), value: isInlineBuilderActive)
            .onChange(of: stuffPushedItems) { _, newItems in
                syncStuffPushedConvoVM(with: newItems)
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

    /// Shared toolbar rendered once by the outer `NavigationStack` so
    /// the compose button persists across Chats / Stuff / Search tab
    /// swaps with iOS 26 native nav-bar styling. The AppIndicatorPill
    /// is *not* a toolbar item — native toolbars clip the slot height
    /// (~44pt) and the pill is taller. It's rendered as a SwiftUI
    /// overlay anchored at top-leading instead (see `sharedAppIndicatorOverlay`).
    @ToolbarContentBuilder
    private var sharedToolbar: some ToolbarContent {
        ToolbarItem(placement: .topBarTrailing) {
            Button("Compose", systemImage: "square.and.pencil") {
                conversationsViewModel.onStartConvo()
            }
            .matchedTransitionSource(id: Constant.composerTransitionId, in: namespace)
            .accessibilityIdentifier("compose-button")
        }
    }

    /// AppIndicatorPill rendered as an overlay above the entire app
    /// (outside the `NavigationStack`) using the exact same structure
    /// `ConversationPresenter` uses: a `VStack` that ignores the
    /// safe area, with the pill padded down by `safeAreaInsets.top`
    /// so it sits flush with the leading edge of the nav-bar zone.
    /// Native toolbars clip ToolbarItem height to ~44pt; the pill is
    /// taller than that, so it must be an overlay rather than a
    /// ToolbarItem. Hidden when a conversation / Stuff detail is
    /// pushed onto the outer NavigationStack — the centered
    /// conversation indicator inside the pushed view's
    /// `ConversationPresenter` morphs into place via the
    /// `sharedIndicatorNamespace` matched-geometry pair.
    @ViewBuilder
    private var sharedAppIndicatorOverlay: some View {
        VStack(spacing: 0) {
            if let activeConvoVM = activeConvoVM {
                centeredConversationIndicator(for: activeConvoVM)
            } else {
                leadingAppIndicatorPill
            }
            Spacer()
        }
        .animation(.bouncy(duration: 0.4, extraBounce: 0.15), value: activeConvoVM != nil)
        .ignoresSafeArea()
        .allowsHitTesting(true)
        .zIndex(1000)
    }

    @ViewBuilder
    private var leadingAppIndicatorPill: some View {
        HStack {
            AppIndicatorPill(
                profileImage: profileSettingsViewModel.profileImage,
                subtitle: indicatorSubtitle,
                action: { presentingAppSettings = true }
            )
            .hoverEffect(.lift)
            .matchedTransitionSource(id: Constant.appSettingsTransitionId, in: namespace)
            .matchedGeometryEffect(
                id: AdaptiveAppIndicatorConstant.indicatorShellId,
                in: sharedIndicatorNamespace,
                properties: .position
            )
            Spacer(minLength: 0)
        }
        .padding(.top, safeAreaInsets.top)
        .padding(.horizontal, DesignConstants.Spacing.step3x)
        .transition(.blurReplace)
    }

    @ViewBuilder
    private func centeredConversationIndicator(for convoVM: ConversationViewModel) -> some View {
        let pendingAgentOverride: AgentVerification? = convoVM.shouldRenderAsPendingAgent
            ? .verified(.convos)
            : nil
        HStack {
            ConversationIndicatorWrapper(
                viewModel: convoVM,
                placeholderOverride: nil,
                subtitleOverride: nil,
                allowsEditing: true,
                focusState: $liftedIndicatorFocus,
                focusCoordinator: liftedIndicatorFocusCoordinator
            )
            .environment(\.forcedAgentVerification, pendingAgentOverride)
            .hoverEffect(.lift)
            .matchedGeometryEffect(
                id: AdaptiveAppIndicatorConstant.indicatorShellId,
                in: sharedIndicatorNamespace,
                properties: .position
            )
        }
        .frame(maxWidth: .infinity)
        .padding(.top, safeAreaInsets.top)
        .padding(.horizontal, DesignConstants.Spacing.step3x)
        .transition(.blurReplace)
    }

    /// Resolves the currently-displayed conversation across tabs: chats
    /// `selectedConversationViewModel` if a chat row is selected, else
    /// a VM hydrated for the topmost Stuff push, else nil. Drives the
    /// shared overlay's morph between leading pill (when nil) and
    /// centered conversation indicator (when non-nil).
    private var activeConvoVM: ConversationViewModel? {
        conversationsViewModel.selectedConversationViewModel ?? stuffPushedConvoVM
    }

    /// Keeps `stuffPushedConvoVM` aligned with `stuffPushedItems.last`
    /// so the shared indicator overlay can render its centered
    /// conversation pill for the pushed Stuff item.
    private func syncStuffPushedConvoVM(with items: [StuffOverviewItem]) {
        guard let item = items.last else {
            stuffPushedConvoVM = nil
            return
        }
        guard stuffPushedConvoVM?.conversation.id != item.conversation.id else { return }
        stuffPushedConvoVM = ConversationViewModel.createSync(
            conversation: item.conversation,
            session: conversationsViewModel.session
        )
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
            if !isOnSearchTab {
                agentBuilderBar
                    .transition(.blurReplace)
            }
            if isOnSearchTab {
                searchInputBar
                    .transition(.blurReplace)
            } else {
                ConvosTabBar(activeTab: $activeTab)
                    .padding(.horizontal, DesignConstants.Spacing.step6x)
                    .transition(.blurReplace)
            }
        }
        .animation(.smooth(duration: 0.25), value: isOnSearchTab)
        .background(
            GeometryReader { proxy in
                Color.clear
                    .preference(key: BottomChromeHeightKey.self, value: proxy.size.height)
            }
        )
        .onPreferenceChange(BottomChromeHeightKey.self) { value in
            bottomChromeHeight = value
        }
        .onChange(of: activeTab) { oldTab, newTab in
            if newTab != .search {
                lastNonSearchTab = newTab
            }
            if newTab == .search {
                isSearchFieldFocused = true
            } else if oldTab == .search {
                searchQuery = ""
                isSearchFieldFocused = false
            }
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

    /// Replaces the agent builder bar in `bottomChrome` while the
    /// Search tab is active. Renders a glass-pill text field with a
    /// trailing X that returns the user to the Chats tab and clears
    /// the query. The actual search results UI lives inside
    /// `SearchTabView` and reads `searchQuery` through the binding.
    private var searchInputBar: some View {
        HStack(spacing: DesignConstants.Spacing.step3x) {
            HStack(spacing: DesignConstants.Spacing.step2x) {
                Image(systemName: "magnifyingglass")
                    .font(.system(size: 18, weight: .regular))
                    .foregroundStyle(.colorTextSecondary)
                TextField("Search", text: $searchQuery)
                    .textFieldStyle(.plain)
                    .focused($isSearchFieldFocused)
                    .submitLabel(.search)
                    .autocorrectionDisabled()
                    .textInputAutocapitalization(.never)
                    .accessibilityIdentifier("search-input")
                if !searchQuery.isEmpty {
                    Button {
                        searchQuery = ""
                    } label: {
                        Image(systemName: "xmark.circle.fill")
                            .foregroundStyle(.colorTextTertiary)
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("Clear search")
                }
            }
            .padding(.horizontal, DesignConstants.Spacing.step4x)
            .padding(.vertical, DesignConstants.Spacing.step3x)
            .glassEffect(.regular.interactive(), in: .capsule)
            Button {
                withAnimation(.smooth(duration: 0.3)) {
                    activeTab = lastNonSearchTab
                }
            } label: {
                Image(systemName: "xmark")
                    .font(.system(size: 18, weight: .regular))
                    .foregroundStyle(.colorTextPrimary)
                    .frame(width: 44, height: 44)
                    .contentShape(.circle)
            }
            .buttonStyle(.plain)
            .glassEffect(.regular.interactive(), in: .circle)
            .accessibilityLabel("Cancel search")
            .accessibilityIdentifier("search-cancel")
        }
        .padding(.horizontal, DesignConstants.Spacing.step6x)
        .padding(.bottom, DesignConstants.Spacing.step3x)
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
