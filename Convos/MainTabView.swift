import ConvosCore
import ConvosMetrics
import PhotosUI
import SwiftUI

/// Root tab shell for the app. Hosts the existing `ConversationsView` under
/// the "Convos" tab, `ThingsTabView` under "Things", and `ContactsView` under
/// "Contacts", in a standard SwiftUI `TabView` with the system tab bar.
///
/// The agent builder bar is pinned via a `safeAreaInset` on the edge
/// opposite the tab bar (top on iPhone, where the tab bar is at the bottom;
/// bottom on iPad, where the standard tab bar is at the top), shared across
/// the Chats and Things tabs. It fades out on scroll and is replaced by a
/// compact "add agent" button in the nav bar. The Contacts tab never shows
/// the builder bar -- its search bar owns the top -- so the "add agent"
/// button stays in the nav bar there regardless of scroll. The compose
/// button lives in the shared toolbar; the app-indicator pill is a
/// top-leading overlay (see `sharedAppIndicatorOverlay`).
struct MainTabView: View {
    @Bindable var conversationsViewModel: ConversationsViewModel
    let profileSettingsViewModel: ProfileSettingsViewModel
    let coreActions: any CoreActions

    /// Tracks which tab is currently active and drives the standard
    /// `TabView` selection. The system tab bar is hidden only while a
    /// conversation / Things detail is pushed (so the detail owns the full
    /// screen) via `.toolbar(_:for: .tabBar)`. It stays visible during the
    /// empty-state CTA so the user can still switch tabs.
    @State private var activeTab: ConvosTab = .chats
    /// NavigationStack path for the Things tab. Lifted to this shell so
    /// the bottom chrome can hide when Things has a detail pushed, same
    /// way it hides when Chats has a conversation selected.
    @State private var thingsPushedItems: [ThingOverviewItem] = []
    /// Hydrated VM for the topmost pushed Things item, so the shared
    /// overlay can render the centered conversation indicator for it
    /// (same morph as a chats push). Synced via `.onChange` on
    /// `thingsPushedItems` — created lazily, cleared on pop.
    @State private var thingsPushedConvoVM: ConversationViewModel?
    /// Member whose contact card is presented when the user taps the
    /// centered conversation indicator while a Things detail is pushed:
    /// the agent that sent the pushed item's attachment.
    @State private var thingsAgentContactMember: ConversationMember?
    /// NavigationStack path for the Contacts tab, lifted here so the shared
    /// app-indicator overlay can tell when a contact detail is pushed and
    /// re-center the pill (mirrors how `thingsPushedItems` lifts the Things
    /// path). `ContactsView` pushes onto it via value-based `NavigationLink`s.
    @State private var contactsPath: [Contact] = []
    /// Section the Contacts tab should scroll to once it appears. Set when the
    /// user taps "See suggested agents" in the empty Things state; `ContactsView`
    /// consumes it (scrolling to the suggested-agents section once it has
    /// loaded) and clears it back to nil.
    @State private var contactsScrollTarget: String?
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
    @State private var thingsScrollOffset: CGFloat = 0
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
    /// level so both the Chats and Things tabs share a single sheet
    /// instance — the alternative (a sheet per tab) would mean tapping
    /// the pill on the wrong tab wouldn't work after a tab swap and
    /// would duplicate the `AppSettingsView` view-model wiring.
    @State private var presentingAppSettings: Bool = false
    /// Source tab captured at the moment the user taps the app-indicator
    /// pill, so the metrics `present(appSettings:)` event can be routed
    /// through the correct tab's overview navigator (preserving the
    /// `source` field on the emitted event). Read by the
    /// `presentingAppSettings` observer when the sheet opens; reset to
    /// `nil` after the event fires.
    @State var appSettingsSource: ConvosTab?
    /// Metrics-only state. The NavigatorImpls hold no behavior — every
    /// protocol method is an empty stub. The wrapping `<Screen>Collector`
    /// from the shared `ConvosMetrics` package intercepts each call and
    /// fires the matching event on the PostHog `CollectorDelegate`.
    /// `<State navigator>` boxes the collector so the weak refs the
    /// shared package holds (`weak var instance`, `weak var delegate`)
    /// stay valid for the lifetime of this view. Built lazily in
    /// `ensureNavigators()`.
    @State var tabRootNavState: TabRootNavigatorImpl = .init()
    @State var tabRootNavigator: TabRootCollector?
    @State var conversationsNavState: ConversationsNavigatorImpl = .init()
    @State var conversationsNavigator: ConversationsCollector?
    @State var stuffOverviewNavState: StuffOverviewNavigatorImpl = .init()
    @State var stuffOverviewNavigator: StuffOverviewCollector?
    @State var contactsNavState: ContactsNavigatorImpl = .init()
    @State var contactsNavigator: ContactsCollector?
    @Environment(\.scenePhase) private var scenePhase: ScenePhase
    /// Live subscription drives the app-indicator subtitle (plan name,
    /// or "Basic" when not subscribed). Seeded from the service's current
    /// value so the first render doesn't flicker, then kept in sync via
    /// `.onReceive` on the publisher.
    @State private var userSubscription: UserSubscription? = SubscriptionServices.shared.currentSubscription
    @State private var creditBalance: CreditBalance? = CreditsServices.shared.currentBalance
    /// Curated agent-builder prompt hints, hydrated from disk on init and
    /// refreshed once on launch (see `body`'s `.task`). Injected into the
    /// environment so the agent builder's dice control -- in this view's
    /// builder sheet and in builders presented from descendant conversation
    /// screens -- can read the cached hints.
    @State private var promptHints: PromptHintsModel = .live()
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
            onTap: {
                appSettingsSource = activeTab
                presentingAppSettings = true
            }
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
    /// navigation stack. Hides the nav bar and the tab bar so the
    /// conversation detail can use the full screen. The builder bar is not
    /// keyed to this: it stays in the tab root's safe-area inset and slides
    /// away with the root during the push. Bound to `conversationsViewModel`
    /// because the selection model lives there.
    private var isConversationSelected: Bool {
        conversationsViewModel.selectedConversationViewModel != nil
            || !thingsPushedItems.isEmpty
    }

    /// Mirrors [[ConversationsViewModel.isEmptyCTAActive]]. When true the
    /// chats list is empty and renders the new-user empty-state CTA
    /// (animated mocks + "Make an agent") instead of the conversation list.
    private var isEmptyChatsCTAActive: Bool {
        conversationsViewModel.isEmptyCTAActive
    }

    /// `true` when the Contacts tab is active and has a contact detail pushed
    /// onto its stack. Used to hide the app-indicator pill while a contact
    /// detail is on screen.
    private var isContactDetailPushed: Bool {
        activeTab == .contacts && !contactsPath.isEmpty
    }

    /// Scroll offset for whichever tab is currently active.
    private var activeTabScrollOffset: CGFloat {
        switch activeTab {
        case .chats: chatsScrollOffset
        case .things: thingsScrollOffset
        case .contacts: 0
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

    /// Tapping a message notification selects the conversation in
    /// `ConversationsViewModel`, but that conversation only lives under the
    /// Chats tab. Switch to Chats and dismiss any shell-level modal first so
    /// the user isn't left on the Things tab or behind the App Settings sheet
    /// looking at a corrupted hierarchy.
    private func handleConversationNotificationTapped() {
        activeTab = .chats
        presentingAppSettings = false
    }

    /// "Explore agents in Contacts" from either tab's empty-state CTA: jump to
    /// the Contacts tab and ask it to scroll to the suggested-agents section.
    /// `ContactsView` performs the scroll once the section has loaded, then
    /// clears the target.
    private func showSuggestedAgents() {
        activeTab = .contacts
        contactsScrollTarget = SuggestedAgentsSection.id
    }

    var body: some View {
        bodyCore
            .environment(promptHints)
            .task {
                await promptHints.loadOnLaunch()
            }
            .onAppear {
                ensureNavigators()
                tabRootNavState.markScreenAppeared()
                navStateForTab(activeTab).markScreenAppeared()
            }
            .modifier(metricsObserversModifier)
    }

    @ViewBuilder
    private var tabView: some View {
        TabView(selection: $activeTab) {
            Tab(ConvosTab.chats.title, systemImage: ConvosTab.chats.symbol, value: ConvosTab.chats) {
                tabContainer(for: .chats) {
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
                        onExploreAgents: showSuggestedAgents
                    )
                }
            }

            Tab(ConvosTab.things.title, systemImage: ConvosTab.things.symbol, value: ConvosTab.things) {
                tabContainer(for: .things) {
                    ThingsTabView(
                        appIndicatorContext: appIndicatorContext,
                        conversationsViewModel: conversationsViewModel,
                        pushedItems: $thingsPushedItems,
                        onScrollOffsetChange: { offset in
                            thingsScrollOffset = offset
                            if activeTab == .things {
                                updateBuilderBarReveal(forOffset: offset)
                            }
                        },
                        onSeeSuggestedAgents: showSuggestedAgents
                    )
                }
            }

            Tab(ConvosTab.contacts.title, systemImage: ConvosTab.contacts.symbol, value: ConvosTab.contacts) {
                tabContainer(for: .contacts) {
                    contactsTabContent
                }
            }
        }
        .tint(Color.colorTextPrimary)
        .onChange(of: activeTab) { _, _ in
            updateBuilderBarReveal(forOffset: activeTabScrollOffset)
        }
    }

    /// Builds the Contacts tab content from the live messaging service,
    /// mirroring the wiring the App Settings "Contacts" row used before it
    /// was promoted to a top-level tab.
    @ViewBuilder
    private var contactsTabContent: some View {
        let messagingService = conversationsViewModel.session.messagingService()
        ContactsView(
            contactsRepository: messagingService.contactsRepository(),
            contactsWriter: messagingService.contactsWriter(),
            session: conversationsViewModel.session,
            coreActions: coreActions,
            profileSettingsViewModel: profileSettingsViewModel,
            showsComposeButton: false,
            suggestedAgentsService: SuggestedAgentsService.live(),
            scrollTarget: $contactsScrollTarget,
            onMakeAgent: { conversationsViewModel.onStartAgent() }
        )
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
    private func tabContainer<Content: View>(for tab: ConvosTab, @ViewBuilder content: () -> Content) -> some View {
        // The Contacts tab binds its stack path to `contactsPath` so the
        // shared overlay can re-center the app-indicator pill when a contact
        // detail is pushed; the other tabs use an internally-managed stack.
        if tab == .contacts {
            NavigationStack(path: $contactsPath) {
                tabChrome(content(), for: tab)
            }
        } else {
            NavigationStack {
                tabChrome(content(), for: tab)
            }
        }
    }

    /// Shared chrome (builder bar + toolbars) wrapped around each tab's root
    /// content inside its `NavigationStack`.
    @ViewBuilder
    private func tabChrome(_ content: some View, for tab: ConvosTab) -> some View {
        content
            .safeAreaInset(edge: builderBarEdge, spacing: 0) {
                // Intentionally not keyed to `isConversationSelected`: the
                // inset belongs to the tab root's layout, so a pushed detail
                // covers it and the bar rides offscreen with the root during
                // the push. Removing it here instead collapsed the inset and
                // reflowed the list mid-transition. The bar also stays up
                // during the empty-state CTA (it is the same builder entry
                // point the CTA's "Make an agent" button opens).
                if tab != .contacts {
                    builderBar
                        .transition(.blurReplace)
                }
            }
            .toolbar { sharedToolbar(for: tab) }
            .toolbar(isConversationSelected ? .hidden : .visible, for: .navigationBar)
            // `.automatic`, not `.visible`, when no conversation is selected:
            // an explicit `.visible` at the stack root overrides the
            // `.toolbarVisibility(.hidden, for: .tabBar)` that pushed
            // destinations (ThingDetailView, the contact card's pushed
            // conversation) set for themselves, leaving the tab bar floating
            // over their bottom chrome. `.automatic` keeps the bar visible on
            // tab roots while letting those destinations hide it.
            .toolbar(isConversationSelected ? .hidden : .automatic, for: .tabBar)
    }

    /// Shared toolbar (compose + add-agent) applied to each tab's
    /// `NavigationStack`. The AppIndicatorPill is *not* a toolbar item —
    /// native toolbars clip the slot height (~44pt) and the pill is taller.
    /// It's rendered as a SwiftUI overlay anchored at top-leading instead
    /// (see `sharedAppIndicatorOverlay`).
    @ToolbarContentBuilder
    private func sharedToolbar(for tab: ConvosTab) -> some ToolbarContent {
        ToolbarItem(placement: .topBarTrailing) {
            let scanAction = {
                conversationsViewModel.onJoinConvo()
            }
            Button(action: scanAction) {
                Image(systemName: "qrcode.viewfinder")
            }
            .accessibilityLabel("Scan a code")
            .accessibilityIdentifier("scan-button")
            .disabled(conversationsViewModel.staleDeviceObserver.isDeviceRemoved)
        }
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
        if showsToolbarBuilderButton(for: tab) {
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
    /// hidden while the bar is revealed and while a conversation is pushed.
    ///
    /// The Contacts tab is the exception: it never shows the builder bar (the
    /// contacts search bar owns the top), so the "add agent" button lives in
    /// the nav bar permanently there, on every size class.
    private func showsToolbarBuilderButton(for tab: ConvosTab) -> Bool {
        if tab == .contacts {
            return !isConversationSelected
        }
        return horizontalSizeClass == .compact
            && !isBuilderBarRevealed
            && !isConversationSelected
    }

    /// AppIndicatorPill rendered as an overlay above the entire app
    /// (outside the `NavigationStack`) using the exact same structure
    /// `ConversationPresenter` uses: a `VStack` that ignores the
    /// safe area, with the pill padded down by `safeAreaInsets.top`
    /// so it sits flush with the leading edge of the nav-bar zone.
    /// Native toolbars clip ToolbarItem height to ~44pt; the pill is
    /// taller than that, so it must be an overlay rather than a
    /// ToolbarItem. Hidden when a conversation / Things detail is
    /// pushed onto the outer NavigationStack — the centered
    /// conversation indicator inside the pushed view's
    /// `ConversationPresenter` morphs into place via the
    /// `sharedIndicatorNamespace` matched-geometry pair.
    @ViewBuilder
    private var sharedAppIndicatorOverlay: some View {
        VStack(spacing: 0) {
            if let activeConvoVM = activeConvoVM {
                // Hide the lifted conversation indicator while the share
                // overlay is up. This pill renders above the presenter's
                // share overlay, so without this it sits on top of the
                // presented code card.
                if !activeConvoVM.presentingShareView {
                    centeredConversationIndicator(for: activeConvoVM)
                }
            } else if !isContactDetailPushed {
                leadingAppIndicatorPill
            }
            Spacer()
        }
        .animation(.bouncy(duration: 0.4, extraBounce: 0.15), value: activeConvoVM != nil)
        .animation(.bouncy(duration: 0.4, extraBounce: 0.15), value: isContactDetailPushed)
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
                action: {
                    appSettingsSource = activeTab
                    presentingAppSettings = true
                }
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
        .transition(.blurReplace.combined(with: .hitTestGate))
    }

    private var leadingAppIndicatorPadding: CGFloat {
        isInTrafficLightWindow
            ? Constant.iPadIndicatorLeadingPadding
            : DesignConstants.Spacing.step3x
    }

    /// Shared with `AttachmentPreviewSheet`'s sender pill so the Things
    /// detail indicator subtitle uses the same sent-date wording.
    private static let sentDateFormatter: SentDateFormatter = SentDateFormatter()

    @ViewBuilder
    private func centeredConversationIndicator(for convoVM: ConversationViewModel) -> some View {
        let pendingAgentOverride: AgentVerification? = convoVM.shouldRenderAsPendingAgent
            ? .verified(.convos)
            : nil
        let pendingAgentIdentity: PendingAgentAvatarIdentity? = convoVM.pendingAgentPresentation?.avatarIdentity
        let isReadOnly: Bool = conversationsViewModel.staleDeviceObserver.isDeviceRemoved || convoVM.conversation.wasRemoved
        // While a Things item is pushed (no chats selection), tapping the
        // indicator opens the contact card of the agent that made the thing
        // instead of the conversation quick editor / info sheet.
        let isThingsIndicator: Bool = conversationsViewModel.selectedConversationViewModel == nil
        let thingsAgentTapOverride: (() -> Void)? = isThingsIndicator ? { presentThingsAgentContact() } : nil
        // On a Things push the indicator subtitle shows when the thing was
        // sent (same label as the in-conversation preview sheet's sender
        // pill) instead of the member count.
        let thingsSentDateSubtitle: String? = isThingsIndicator
            ? thingsPushedItems.last.map { Self.sentDateFormatter.string(for: $0.date) }
            : nil
        HStack {
            ConversationIndicatorWrapper(
                viewModel: convoVM,
                placeholderOverride: nil,
                subtitleOverride: thingsSentDateSubtitle,
                allowsEditing: !isReadOnly,
                focusState: $liftedIndicatorFocus,
                focusCoordinator: liftedIndicatorFocusCoordinator,
                onTapOverride: thingsAgentTapOverride
            )
            .environment(\.forcedAgentVerification, pendingAgentOverride)
            .environment(\.pendingAgentIdentity, pendingAgentIdentity)
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
        .transition(.blurReplace.combined(with: .hitTestGate))
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
    /// a VM hydrated for the topmost Things push, else nil. Drives the
    /// shared overlay's morph between leading pill (when nil) and
    /// centered conversation indicator (when non-nil).
    private var activeConvoVM: ConversationViewModel? {
        conversationsViewModel.selectedConversationViewModel ?? thingsPushedConvoVM
    }

    /// Opens the contact card of the agent that sent the pushed Things
    /// item's attachment. Falls back to the default conversation-info tap
    /// if the sender is no longer a member of the convo.
    private func presentThingsAgentContact() {
        guard let convoVM = thingsPushedConvoVM else { return }
        let senderInboxId: String? = thingsPushedItems.last?.senderInboxId
        let senderMember: ConversationMember? = convoVM.conversation.members
            .first { $0.profile.inboxId == senderInboxId }
        guard let senderMember else {
            convoVM.onConversationInfoTap(focusCoordinator: liftedIndicatorFocusCoordinator)
            return
        }
        thingsAgentContactMember = senderMember
    }

    /// Keeps `thingsPushedConvoVM` aligned with `thingsPushedItems.last`
    /// so the shared indicator overlay can render its centered
    /// conversation pill for the pushed Things item.
    private func syncThingsPushedConvoVM(with items: [ThingOverviewItem]) {
        guard let item = items.last else {
            thingsPushedConvoVM = nil
            thingsAgentContactMember = nil
            return
        }
        guard thingsPushedConvoVM?.conversation.id != item.conversation.id else { return }
        thingsPushedConvoVM = ConversationViewModel.createSync(
            conversation: item.conversation,
            session: conversationsViewModel.session
        )
    }

    /// The agent builder bar, shared across the Chats and Things tabs, on the
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

/// Metrics dispatch helpers, defined as an extension so they sit outside
/// `MainTabView`'s primary declaration and don't push the struct over
/// SwiftLint's `type_body_length` ceiling. Same-file extensions retain
/// access to the struct's `private` `@State` properties.
extension MainTabView {
    /// Lazily build the four Collectors the moment they're first needed.
    /// Pulls the live PostHog delegate from `PostHogConfiguration`; falls
    /// back to a no-op `CollectorDelegate` when PostHog is disabled (local
    /// builds without an API key), which keeps the call sites identical
    /// across environments.
    func ensureNavigators() {
        let delegate = PostHogConfiguration.sharedMetricsDelegate ?? CollectorDelegate()
        if tabRootNavigator == nil {
            tabRootNavigator = TabRootCollector(instance: tabRootNavState, delegate: delegate)
        }
        if conversationsNavigator == nil {
            conversationsNavigator = ConversationsCollector(instance: conversationsNavState, delegate: delegate)
        }
        if stuffOverviewNavigator == nil {
            stuffOverviewNavigator = StuffOverviewCollector(instance: stuffOverviewNavState, delegate: delegate)
        }
        if contactsNavigator == nil {
            contactsNavigator = ContactsCollector(instance: contactsNavState, delegate: delegate)
        }
    }

    /// Returns the overview NavigatorImpl that owns the currently-active
    /// tab content. SwiftUI keeps both tab contents alive so
    /// `.onAppear` / `.onDisappear` don't fire on tab swap — the
    /// scenePhase and tab-change observers use this to dispatch
    /// `closed` / `markScreenAppeared` explicitly.
    func navStateForTab(_ tab: ConvosTab) -> any NavigatorLifecycle {
        switch tab {
        case .chats: return conversationsNavState
        case .things: return stuffOverviewNavState
        case .contacts: return contactsNavState
        }
    }

    func closeActiveTabNavigator(_ tab: ConvosTab, context: ScreenContext) {
        switch tab {
        case .chats: conversationsNavigator?.closed(context: context)
        case .things: stuffOverviewNavigator?.closed(context: context)
        case .contacts: contactsNavigator?.closed(context: context)
        }
    }

    func handleActiveTabChanged(from oldTab: ConvosTab, to newTab: ConvosTab) {
        guard oldTab != newTab else { return }
        let previous = navStateForTab(oldTab)
        closeActiveTabNavigator(oldTab, context: previous.closeContext())
        let next = navStateForTab(newTab)
        next.markScreenAppeared()
        switch newTab {
        case .chats:
            tabRootNavigator?.navigateTo(conversations: ConversationsNavigatorArgs())
        case .things:
            tabRootNavigator?.navigateTo(stuffOverview: StuffOverviewNavigatorArgs())
        case .contacts:
            tabRootNavigator?.navigateTo(contacts: ContactsNavigatorArgs())
        }
    }

    func handleScenePhaseChanged(to newPhase: ScenePhase) {
        let active = navStateForTab(activeTab)
        switch newPhase {
        case .background:
            closeActiveTabNavigator(activeTab, context: active.closeContext())
            tabRootNavigator?.closed(context: tabRootNavState.closeContext())
        case .active:
            tabRootNavState.markScreenAppeared()
            active.markScreenAppeared()
        case .inactive:
            break
        @unknown default:
            break
        }
    }

    func handleThingsPushChanged(from oldId: String?, to newId: String?) {
        guard oldId == nil, let newId, let item = thingsPushedItems.last, item.id == newId else { return }
        stuffOverviewNavigator?.navigateTo(stuffDetail: StuffDetailNavigatorArgs(itemId: newId))
    }

    func handleContactsPushChanged(from oldId: String?, to newId: String?) {
        guard oldId == nil, let newId else { return }
        contactsNavigator?.navigateTo(contactCard: ContactCardNavigatorArgs(inboxId: newId))
    }

    func handleAppSettingsPresented(_ isPresenting: Bool) {
        guard isPresenting else { return }
        let source = appSettingsSource ?? activeTab
        appSettingsSource = nil
        switch source {
        case .chats: conversationsNavigator?.present(appSettings: AppSettingsNavigatorArgs())
        case .things: stuffOverviewNavigator?.present(appSettings: AppSettingsNavigatorArgs())
        case .contacts: contactsNavigator?.present(appSettings: AppSettingsNavigatorArgs())
        }
    }

    func handleSelectedConversationChanged(from oldId: String?, to newId: String?) {
        guard oldId == nil, let newId else { return }
        conversationsNavigator?.navigateTo(conversation: ConversationNavigatorArgs(conversationId: newId))
    }

    func handleAgentBuilderPresented(_ isPresenting: Bool, wasPresenting: Bool) {
        guard !wasPresenting, isPresenting else { return }
        let conversationId: String = conversationsViewModel.agentBuilderViewModel?.newConversationViewModel.conversationViewModel?.conversation.id ?? ""
        conversationsNavigator?.present(agentBuilder: AgentBuilderNavigatorArgs(
            conversationId: conversationId,
            entryMode: .sheet
        ))
    }

    func handleNewConversationPresented(_ isPresenting: Bool, wasPresenting: Bool) {
        guard !wasPresenting, isPresenting else { return }
        let mode: ConvosMetrics.NewConversationMode = .create
        conversationsNavigator?.present(newConversation: NewConversationNavigatorArgs(mode: mode))
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
struct MainTabSheetsModifier: ViewModifier {
    @Bindable var conversationsViewModel: ConversationsViewModel
    let profileSettingsViewModel: ProfileSettingsViewModel
    let coreActions: any CoreActions
    @Binding var presentingAppSettings: Bool
    @Binding var isPhotoPickerPresented: Bool
    @Binding var isCameraPresented: Bool
    @Binding var selectedPhotos: [PhotosPickerItem]
    @Binding var thingsAgentContactMember: ConversationMember?
    let thingsPushedConvoVM: ConversationViewModel?
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
                    coreActions: coreActions,
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
            }, content: {
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
            })
            .sheet(item: $thingsAgentContactMember) { member in
                thingsAgentContactSheet(for: member)
            }
    }

    /// Contact card for the agent that made the pushed Things item,
    /// presented when the user taps the centered conversation indicator
    /// on the Things detail. Same content the member-avatar tap inside a
    /// chat presents.
    @ViewBuilder
    private func thingsAgentContactSheet(for member: ConversationMember) -> some View {
        if let thingsPushedConvoVM {
            MemberContactDetailSheetContent(
                viewModel: thingsPushedConvoVM,
                member: member,
                profileSettingsViewModel: profileSettingsViewModel
            )
        }
    }
}

extension MainTabView {
    @ViewBuilder
    var bodyCore: some View {
        ZStack {
            tabView

            sharedAppIndicatorOverlay
        }
        .animation(.smooth(duration: 0.35), value: isConversationSelected)
        .animation(.smooth(duration: 0.35), value: isEmptyChatsCTAActive)
        .onChange(of: thingsPushedItems) { _, newItems in
            syncThingsPushedConvoVM(with: newItems)
        }
        .onReceive(SubscriptionServices.shared.subscriptionPublisher) { newSubscription in
            userSubscription = newSubscription
        }
        .onReceive(CreditsServices.shared.balancePublisher) { newBalance in
            creditBalance = newBalance
        }
        .onReceive(NotificationCenter.default.publisher(for: .conversationNotificationTapped)) { _ in
            handleConversationNotificationTapped()
        }
        .modifier(mainTabSheetsModifier)
    }

    var metricsObserversModifier: MetricsObservers {
        MetricsObservers(
            activeTab: activeTab,
            scenePhase: scenePhase,
            thingsPushedItemId: thingsPushedItems.last?.id,
            contactsPushedItemId: contactsPath.last?.id,
            presentingAppSettings: presentingAppSettings,
            selectedConversationId: conversationsViewModel.selectedConversationId,
            agentBuilderPresenting: conversationsViewModel.agentBuilderViewModel != nil,
            newConversationPresenting: conversationsViewModel.newConversationViewModel != nil,
            onActiveTabChanged: handleActiveTabChanged(from:to:),
            onScenePhaseChanged: handleScenePhaseChanged(to:),
            onThingsPushChanged: handleThingsPushChanged(from:to:),
            onContactsPushChanged: handleContactsPushChanged(from:to:),
            onAppSettingsPresented: handleAppSettingsPresented(_:),
            onSelectedConversationChanged: handleSelectedConversationChanged(from:to:),
            onAgentBuilderPresented: handleAgentBuilderPresented(_:wasPresenting:),
            onNewConversationPresented: handleNewConversationPresented(_:wasPresenting:)
        )
    }
}

extension MainTabView {
    var mainTabSheetsModifier: MainTabSheetsModifier {
        MainTabSheetsModifier(
            conversationsViewModel: conversationsViewModel,
            profileSettingsViewModel: profileSettingsViewModel,
            coreActions: coreActions,
            presentingAppSettings: $presentingAppSettings,
            isPhotoPickerPresented: $isPhotoPickerPresented,
            isCameraPresented: $isCameraPresented,
            selectedPhotos: $selectedPhotos,
            thingsAgentContactMember: $thingsAgentContactMember,
            thingsPushedConvoVM: thingsPushedConvoVM,
            namespace: namespace,
            onPhotosChanged: handleSelectedPhotosChanged(to:),
            onCameraImageCaptured: handleCameraImageCaptured,
            onCameraVideoCaptured: handleCameraVideoCaptured
        )
    }
}
