import ConvosCore
import PhotosUI
import SwiftUI

/// Root tab shell for the app. Hosts the existing `ConversationsView` under
/// the "Chats" tab and `StuffTabView` under "Stuff", in a standard SwiftUI
/// `TabView` with the system tab bar. (Search was a third tab that is
/// temporarily removed.)
///
/// The agent builder bar is pinned via a `safeAreaInset` on the edge
/// opposite the tab bar (top on iPhone, where the tab bar is at the bottom;
/// bottom on iPad, where the standard tab bar is at the top), shared across
/// both tabs. It fades out on scroll and is replaced by a compact "add
/// agent" button in the nav bar. The compose button lives in the shared
/// toolbar; the app-indicator pill is a top-leading overlay (see
/// `sharedAppIndicatorOverlay`).
struct MainTabView: View {
    @Bindable var conversationsViewModel: ConversationsViewModel
    let profileSettingsViewModel: ProfileSettingsViewModel

    /// Tracks which tab is currently active and drives the standard
    /// `TabView` selection. The system tab bar is hidden only while a
    /// conversation / Stuff detail is pushed (or the inline empty-state
    /// builder is up) via `.toolbar(_:for: .tabBar)`.
    @State private var activeTab: ConvosTab = .chats
    /// NavigationStack path for the Stuff tab. Lifted to this shell so
    /// the bottom chrome can hide when Stuff has a detail pushed, same
    /// way it hides when Chats has a conversation selected.
    @State private var stuffPushedItems: [StuffOverviewItem] = []
    /// Hydrated VM for the topmost pushed Stuff item, so the shared
    /// overlay can render the centered conversation indicator for it
    /// (same morph as a chats push). Synced via `.onChange` on
    /// `stuffPushedItems` — created lazily, cleared on pop.
    @State private var stuffPushedConvoVM: ConversationViewModel?
    /// Whether the top `AgentBuilderBar` is revealed (shown under the nav
    /// bar) versus faded out. Held in state with hysteresis thresholds
    /// rather than derived purely from scroll offset so a bouncy scroll
    /// near the boundary doesn't flicker the bar: once hidden it stays
    /// hidden until the list returns to the top; once revealed it stays
    /// revealed until the user has scrolled `Constant.hideScrollThreshold`
    /// past the top. While hidden, a compact "add agent" button takes its
    /// place in the nav bar.
    @State private var isBuilderBarRevealed: Bool = true
    /// Latest scroll content offset from each tab's primary scroll view.
    /// Tracked per-tab so swapping tabs can re-evaluate the builder bar
    /// state against the new tab's scroll position immediately, instead
    /// of waiting for the user to scroll.
    @State private var chatsScrollOffset: CGFloat = 0
    @State private var stuffScrollOffset: CGFloat = 0
    /// Measured height of the top chrome (the agent builder bar under the
    /// nav bar) published via a `PreferenceKey`. Used to push an explicit
    /// additional top inset down into `ConversationsViewController`,
    /// because SwiftUI's safe-area inset chain doesn't reliably propagate
    /// to the UIKit collection view.
    @State private var builderBarHeight: CGFloat = 0
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
    /// Live subscription drives the app-indicator subtitle (plan name,
    /// or "Basic" when not subscribed). Seeded from the service's current
    /// value so the first render doesn't flicker, then kept in sync via
    /// `.onReceive` on the publisher.
    @State private var userSubscription: UserSubscription? = SubscriptionServices.shared.currentSubscription
    @State private var creditBalance: CreditBalance? = CreditsServices.shared.currentBalance
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
    /// True when the iPad app is running in a windowed (non-fullscreen)
    /// state, where iPadOS 26 renders the "traffic light" controls
    /// (close / minimize / fullscreen) at the top-leading edge of the
    /// window. Drives extra leading inset on the app-indicator pill so
    /// it doesn't overlap the controls. Stays false on iPhone (no
    /// window chrome) and on iPad in fullscreen.
    @State private var isInTrafficLightWindow: Bool = false
    @Environment(\.horizontalSizeClass) private var horizontalSizeClass: UserInterfaceSizeClass?

    /// Which edge the agent builder bar pins to. The standard `TabView`
    /// puts the tab bar at the bottom in compact width (iPhone) and at the
    /// top in regular width (iPad); the builder bar goes on the opposite
    /// edge so the two never collide.
    private var builderBarEdge: VerticalEdge {
        horizontalSizeClass == .compact ? .top : .bottom
    }

    /// The measured builder-bar height applied to the conversation list as a
    /// top or bottom content inset, depending on which edge the bar pins to.
    private var chromeTopInset: CGFloat {
        builderBarEdge == .top ? builderBarHeight : 0
    }
    private var chromeBottomInset: CGFloat {
        builderBarEdge == .bottom ? builderBarHeight : 0
    }

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
        if creditBalance?.isDepleted == true {
            return .symbol(
                systemName: "bolt.fill",
                tint: .colorLava,
                accessibilityLabel: "No power"
            )
        }
        if let userSubscription {
            return .text(SubscriptionCopy.displayName(for: userSubscription.tier))
        }
        return .text("Basic")
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
        }
    }

    /// Apply hysteresis to the bar reveal state in response to a scroll
    /// offset update from the active tab. Hides the bar (fade on iPhone /
    /// collapse to the circle on iPad) only once the user has scrolled at
    /// least the full builder-bar height past the top, and reveals it again
    /// once the list is back near the top (within `revealScrollThreshold`).
    /// The gap between the two thresholds prevents a bouncing scroll near
    /// the boundary from flickering the bar.
    private func updateBuilderBarReveal(forOffset offset: CGFloat) {
        // Fall back to a small fixed threshold until the bar has been
        // measured (otherwise a zero height would hide it immediately).
        let hideThreshold = builderBarHeight > 0 ? builderBarHeight : Constant.hideScrollThreshold
        if isBuilderBarRevealed {
            if offset >= hideThreshold {
                withAnimation(.smooth(duration: 0.25)) {
                    isBuilderBarRevealed = false
                }
            }
        } else {
            if offset <= Constant.revealScrollThreshold {
                withAnimation(.smooth(duration: 0.25)) {
                    isBuilderBarRevealed = true
                }
            }
        }
    }

    var body: some View {
        ZStack {
            tabView

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
            .onReceive(CreditsServices.shared.balancePublisher) { newBalance in
                creditBalance = newBalance
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
            Tab(ConvosTab.chats.title, systemImage: ConvosTab.chats.symbol, value: ConvosTab.chats) {
                tabContainer {
                    ConversationsView(
                        viewModel: conversationsViewModel,
                        profileSettingsViewModel: profileSettingsViewModel,
                        appIndicatorContext: appIndicatorContext,
                        sidebarBottomAccessory: nil,
                        onScrollOffsetChange: { offset in
                            chatsScrollOffset = offset
                            if activeTab == .chats {
                                updateBuilderBarReveal(forOffset: offset)
                            }
                        },
                        topChromeInset: chromeTopInset,
                        bottomChromeInset: chromeBottomInset,
                        presentingCommittedConversation: $presentingCommittedConversation
                    )
                }
            }

            Tab(ConvosTab.stuff.title, systemImage: ConvosTab.stuff.symbol, value: ConvosTab.stuff) {
                tabContainer {
                    StuffTabView(
                        appIndicatorContext: appIndicatorContext,
                        conversationsViewModel: conversationsViewModel,
                        pushedItems: $stuffPushedItems,
                        onScrollOffsetChange: { offset in
                            stuffScrollOffset = offset
                            if activeTab == .stuff {
                                updateBuilderBarReveal(forOffset: offset)
                            }
                        }
                    )
                }
            }
        }
        .tint(Color.colorTextPrimary)
        .onChange(of: activeTab) { _, _ in
            updateBuilderBarReveal(forOffset: activeTabScrollOffset)
        }
    }

    /// Wraps each tab's content in its own `NavigationStack` carrying the
    /// shared chrome (compose toolbar + agent builder bar). Making the
    /// `TabView` the root and giving each tab its own stack is the native
    /// iPad pattern: iOS 26 renders the tab bar and the nav-bar toolbar in
    /// one merged top bar (tabs centered, toolbar items on the sides),
    /// instead of stacking the tab bar on a separate row below the nav bar.
    /// The conversation-detail push (via `ConversationsView`'s
    /// `navigationDestination`) lands on this per-tab stack.
    @ViewBuilder
    private func tabContainer<Content: View>(@ViewBuilder content: () -> Content) -> some View {
        NavigationStack {
            content()
                .safeAreaInset(edge: builderBarEdge, spacing: 0) {
                    if !isConversationSelected && !isInlineBuilderActive {
                        builderBar
                            .transition(.blurReplace)
                    }
                }
                .toolbar { sharedToolbar }
                .toolbar(isConversationSelected ? .hidden : .visible, for: .navigationBar)
                .toolbar((isConversationSelected || isInlineBuilderActive) ? .hidden : .visible, for: .tabBar)
        }
    }

    /// Shared toolbar (compose + add-agent) applied to each tab's
    /// `NavigationStack`. The AppIndicatorPill is *not* a toolbar item —
    /// native toolbars clip the slot height (~44pt) and the pill is taller.
    /// It's rendered as a SwiftUI overlay anchored at top-leading instead
    /// (see `sharedAppIndicatorOverlay`).
    @ToolbarContentBuilder
    private var sharedToolbar: some ToolbarContent {
        ToolbarItem(placement: .topBarTrailing) {
            Button("Compose", systemImage: "square.and.pencil") {
                conversationsViewModel.onStartConvo()
            }
            .matchedTransitionSource(id: Constant.composerTransitionId, in: namespace)
            .accessibilityIdentifier("compose-button")
            .disabled(conversationsViewModel.staleDeviceObserver.isDeviceRemoved)
        }
        // Declared after Compose so it sits at the trailing edge (to the
        // right of Compose) once the top builder bar has faded on scroll.
        if showsToolbarBuilderButton {
            ToolbarItem(placement: .topBarTrailing) {
                Button(action: openBuilder) {
                    Image("addAgentIcon")
                        .renderingMode(.template)
                        .resizable()
                        .scaledToFit()
                        .frame(width: 18, height: 18)
                }
                .accessibilityLabel("Make an agent")
                .accessibilityIdentifier("toolbar-add-agent-button")
                .disabled(conversationsViewModel.staleDeviceObserver.isDeviceRemoved)
            }
        }
    }

    /// The compact "add agent" nav-bar button replaces the builder bar once
    /// it has faded out on scroll. iPhone only (compact width): on iPad the
    /// bar collapses to its own circle instead, so no nav-bar button. Also
    /// hidden while the bar is revealed, while a conversation is pushed, and
    /// during the inline empty-state builder.
    private var showsToolbarBuilderButton: Bool {
        horizontalSizeClass == .compact
            && !isBuilderBarRevealed
            && !isConversationSelected
            && !isInlineBuilderActive
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
        .onGeometryChange(for: CGSize.self, of: { $0.size }, action: { _ in
            updateTrafficLightWindowState()
        })
        .task {
            // The geometry callback above fires once on first layout, often
            // before the scene's window has settled into its windowed frame --
            // so `updateTrafficLightWindowState()` hits its scene/window guard
            // and the flag stays `false`, leaving the indicator pill flush
            // against the traffic-light controls until a manual resize
            // re-triggers detection. Re-check across the launch window so the
            // settle can't be missed.
            for delayMilliseconds in [0, 150, 400, 800] {
                // Stop on cancellation (view disappeared) rather than letting
                // `try?` swallow it -- otherwise every remaining iteration runs
                // immediately, firing the state update several extra times.
                do {
                    try await Task.sleep(for: .milliseconds(delayMilliseconds))
                } catch {
                    return
                }
                updateTrafficLightWindowState()
            }
        }
    }

    /// Update the traffic-light-window flag by comparing the active
    /// window's frame to its screen's bounds. Fullscreen reports
    /// `window.frame == screen.bounds` (no chrome inset). Maximized and
    /// windowed both leave the frame offset/shrunk by the iPadOS 26
    /// title-bar strip even at full width, so they require the leading
    /// inset on the indicator pill to clear the traffic-light controls.
    /// iPhone (no window chrome) always reports `false`.
    private func updateTrafficLightWindowState() {
        guard UIDevice.current.userInterfaceIdiom == .pad else {
            if isInTrafficLightWindow { isInTrafficLightWindow = false }
            return
        }
        let scene = UIApplication.shared.connectedScenes
            .compactMap { $0 as? UIWindowScene }
            .first { $0.activationState == .foregroundActive }
        guard let window = scene?.windows.first(where: \.isKeyWindow) ?? scene?.windows.first,
              let screenBounds = scene?.screen.bounds else {
            return
        }
        let isFullScreen: Bool = window.frame == screenBounds
        let isWindowed: Bool = !isFullScreen
        if isWindowed != isInTrafficLightWindow {
            isInTrafficLightWindow = isWindowed
        }
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
        .padding(.leading, leadingAppIndicatorPadding)
        .padding(.trailing, DesignConstants.Spacing.step3x)
        .transition(.blurReplace)
    }

    private var leadingAppIndicatorPadding: CGFloat {
        isInTrafficLightWindow
            ? Constant.iPadIndicatorLeadingPadding
            : DesignConstants.Spacing.step3x
    }

    @ViewBuilder
    private func centeredConversationIndicator(for convoVM: ConversationViewModel) -> some View {
        let pendingAgentOverride: AgentVerification? = convoVM.shouldRenderAsPendingAgent
            ? .verified(.convos)
            : nil
        let isReadOnly: Bool = conversationsViewModel.staleDeviceObserver.isDeviceRemoved
        HStack {
            ConversationIndicatorWrapper(
                viewModel: convoVM,
                placeholderOverride: nil,
                subtitleOverride: nil,
                allowsEditing: !isReadOnly,
                focusState: $liftedIndicatorFocus,
                focusCoordinator: liftedIndicatorFocusCoordinator
            )
            .environment(\.forcedAgentVerification, pendingAgentOverride)
            .hoverEffect(.lift)
            .disabled(isReadOnly)
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
        // Keep the lifted indicator's coordinator current: unlike the
        // committed-conversation coordinator (updated by ConversationPresenter),
        // ConversationIndicatorWrapper doesn't, so its quick-editor focus would
        // resolve against a nil size class on iPad without this.
        .onAppear {
            liftedIndicatorFocusCoordinator.horizontalSizeClass = horizontalSizeClass
        }
        .onChange(of: horizontalSizeClass) { _, newValue in
            liftedIndicatorFocusCoordinator.horizontalSizeClass = newValue
        }
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

    /// The agent builder bar, shared across the Chats and Stuff tabs, on the
    /// edge opposite the tab bar. Its scroll behavior differs by platform:
    /// on iPhone (compact) the expanded bar blurs/fades out and a compact
    /// "add agent" button takes its place in the nav bar; on iPad (regular)
    /// the bar stays visible and morphs to the collapsed circle instead. Its
    /// measured height is published so the UIKit list can inset its content.
    @ViewBuilder
    private var builderBar: some View {
        let revealed = isBuilderBarRevealed
        let isCompactWidth = horizontalSizeClass == .compact
        // iPhone keeps the expanded bar and fades it out; iPad morphs between
        // the expanded capsule and the collapsed circle on scroll.
        let expanded = isCompactWidth ? true : revealed
        let faded = isCompactWidth && !revealed
        AgentBuilderBar(
            isExpanded: expanded,
            onTap: openBuilder,
            onTapPhotos: { isPhotoPickerPresented = true },
            onTapCamera: { isCameraPresented = true },
            onTapVoiceMemo: openBuilderInVoiceMemoMode,
            transitionSourceNamespace: namespace,
            transitionSourceId: Constant.builderTransitionId
        )
        .opacity(faded ? 0 : 1)
        .blur(radius: faded ? Constant.builderBarHiddenBlur : 0)
        .allowsHitTesting(!faded)
        .padding(.horizontal, DesignConstants.Spacing.step4x)
        .padding(.top, DesignConstants.Spacing.step2x)
        .padding(.bottom, DesignConstants.Spacing.step3x)
        .background(
            GeometryReader { proxy in
                Color.clear
                    .preference(key: BuilderBarHeightKey.self, value: proxy.size.height)
            }
        )
        .onPreferenceChange(BuilderBarHeightKey.self) { value in
            builderBarHeight = value
        }
    }

    private func openBuilder() {
        conversationsViewModel.onStartAgent()
    }

    /// Open the builder pre-configured to start a voice-memo recording.
    /// `AgentBuilderView` reads `viewModel.entryMode` on appear and skips
    /// the initial composer-focus (so the keyboard doesn't pop up
    /// alongside the mic-permission prompt) before calling
    /// `startVoiceMemoRecording`. The view also owns the timing of the
    /// `record()` call, so we don't need the previous racy 50ms sleep
    /// to wait for the inner conversation VM's recorder to materialize.
    private func openBuilderInVoiceMemoMode() {
        conversationsViewModel.onStartAgent(entryMode: .voiceMemo)
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
        /// Fallback hide threshold used only before the builder bar's
        /// height has been measured; once measured, the bar hides after
        /// scrolling past its full height. `revealScrollThreshold` brings
        /// it back near the top; the gap eats overscroll bounce noise so
        /// the bar doesn't flicker at the boundary.
        static let hideScrollThreshold: CGFloat = 20.0
        static let revealScrollThreshold: CGFloat = 4.0
        /// Blur radius applied to the top builder bar while it's hidden, so
        /// it dissolves rather than hard-cutting as the list scrolls.
        static let builderBarHiddenBlur: CGFloat = 8.0
        /// Leading inset on the app-indicator pill when the iPad app is
        /// in a windowed (non-fullscreen) state. iPadOS 26 renders
        /// window chrome ("traffic lights": close / minimize /
        /// fullscreen) at the top-leading edge of windows, so the pill
        /// needs extra leading room to clear them. Fullscreen and iPhone
        /// use the regular horizontal step (no window chrome).
        static let iPadIndicatorLeadingPadding: CGFloat = 88.0
    }
}

/// Carries the measured height of `MainTabView.builderBar` up via the
/// SwiftUI preference system so the host can plumb it into UIKit-hosted
/// scroll views that don't see SwiftUI's safe-area inset.
private struct BuilderBarHeightKey: PreferenceKey {
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
            .sheet(isPresented: $conversationsViewModel.presentingComposeFlow, onDismiss: {
                conversationsViewModel.endComposeFlow()
            }) {
                if let composeViewModel = conversationsViewModel.composeConversationViewModel {
                    ComposeFlowView(
                        conversationsViewModel: conversationsViewModel,
                        composeConversationViewModel: composeViewModel,
                        profileSettingsViewModel: profileSettingsViewModel,
                        contactsRepository: conversationsViewModel.session.messagingServiceSync().contactsRepository()
                    )
                    .background(.colorBackgroundSurfaceless)
                    .presentationSizing(.page)
                    .navigationTransition(
                        .zoom(sourceID: "composer-transition-source", in: namespace)
                    )
                }
            }
    }
}
