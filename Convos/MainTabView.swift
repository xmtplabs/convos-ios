import ConvosComposer
import ConvosCore
import ConvosMetrics
import SwiftUI

/// Root tab shell for the app. Hosts `ConversationsView` under the "Convos"
/// tab and `ContactsView` under "Contacts", in a standard SwiftUI `TabView`
/// with the system tab bar.
///
/// The compose button lives in the shared toolbar; the app-indicator pill is
/// a top-leading overlay (see `sharedAppIndicatorOverlay`).
struct MainTabView: View {
    @Bindable var conversationsViewModel: ConversationsViewModel
    let profileSettingsViewModel: ProfileSettingsViewModel
    let coreActions: any CoreActions

    /// Tracks which tab is currently active and drives the standard
    /// `TabView` selection. The system tab bar is hidden only while a
    /// conversation is pushed (so it owns the full screen) via
    /// `.toolbar(_:for: .tabBar)`. It stays visible during the
    /// empty-state CTA so the user can still switch tabs.
    @State private var activeTab: ConvosTab = .chats
    /// NavigationStack path for the Contacts tab, lifted here so the shared
    /// app-indicator overlay can tell when a contact detail is pushed and
    /// re-center the pill. `ContactsView` pushes onto it via value-based
    /// `NavigationLink`s.
    @State private var contactsPath: [Contact] = []
    /// Drives the app-settings sheet that the `AppIndicatorPill` (in
    /// every tab that renders one) presents on tap. Lives at this shell
    /// level so every tab shares a single sheet instance — the
    /// alternative (a sheet per tab) would mean tapping
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
    @State var contactsNavState: ContactsNavigatorImpl = .init()
    @State var contactsNavigator: ContactsCollector?
    @Environment(\.scenePhase) private var scenePhase: ScenePhase
    /// Live subscription drives the app-indicator subtitle (plan name,
    /// or "Basic" when not subscribed). Seeded from the service's current
    /// value so the first render doesn't flicker, then kept in sync via
    /// `.onReceive` on the publisher. Seeding is safe here because the
    /// subscription's current value is held in memory.
    @State private var userSubscription: UserSubscription? = SubscriptionServices.shared.currentSubscription
    /// Not seeded, unlike the subscription above: the balance's current value
    /// comes from a synchronous database read, and a `@State` default is
    /// evaluated on every init of this view - so seeding it blocks the main
    /// thread on the reader pool during body evaluation. See
    /// `CreditsServiceProtocol.currentBalance`. The publisher fills it in.
    @State private var creditBalance: CreditBalance?
    /// Shared namespace for the app-settings pill -> sheet zoom transition.
    /// The pill applies
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
    /// conversation detail can use the full screen. Bound to
    /// `conversationsViewModel` because the selection model lives there.
    private var isConversationSelected: Bool {
        conversationsViewModel.selectedConversationViewModel != nil
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

    /// Tapping a message notification selects the conversation in
    /// `ConversationsViewModel`, but that conversation only lives under the
    /// Chats tab. Switch to Chats and dismiss any shell-level modal first so
    /// the user isn't left on another tab or behind the App Settings sheet
    /// looking at a corrupted hierarchy.
    private func handleConversationNotificationTapped() {
        activeTab = .chats
        presentingAppSettings = false
    }

    var body: some View {
        bodyCore
            .profilesRepository(conversationsViewModel.session.messagingServiceSync().profilesRepository())
            .onAppear {
                ensureNavigators()
                tabRootNavState.markScreenAppeared()
                navStateForTab(activeTab).markScreenAppeared()
                conversationsViewModel.bringChatsTabToFront = { activeTab = .chats }
                conversationsViewModel.isChatsTabActive = activeTab == .chats
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
                        sidebarBottomAccessory: nil
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
        .onChange(of: activeTab) { _, newTab in
            // Fires after SwiftUI has applied the tab switch, so a parked
            // scan navigation gated on the Chats tab consumes only once the
            // switch has actually committed.
            conversationsViewModel.isChatsTabActive = newTab == .chats
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
            onScanJoinedConversation: handleContactsScanJoinedConversation,
            hasPushedContactDetail: !contactsPath.isEmpty
        )
    }

    /// A scan started from the Contacts tab joined a conversation. The joined
    /// convo lives under the Chats tab; `navigateToScannedConversation` asks
    /// the shell to switch there (via `bringChatsTabToFront`) and selects the
    /// conversation only once the switch has committed and the row is in the
    /// list, so the push can never land while Contacts is frontmost.
    private func handleContactsScanJoinedConversation(_ conversationId: String) {
        conversationsViewModel.navigateToScannedConversation(conversationId)
    }

    /// Wraps each tab's content in its own `NavigationStack` carrying the
    /// shared chrome (compose toolbar). Making the
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

    /// Shared chrome (toolbars) wrapped around each tab's root content inside
    /// its `NavigationStack`.
    @ViewBuilder
    private func tabChrome(_ content: some View, for tab: ConvosTab) -> some View {
        content
            .toolbar { sharedToolbar() }
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

    /// Shared toolbar (scan + compose) applied to each tab's
    /// `NavigationStack`. The AppIndicatorPill is *not* a toolbar item —
    /// native toolbars clip the slot height (~44pt) and the pill is taller.
    /// It's rendered as a SwiftUI overlay anchored at top-leading instead
    /// (see `sharedAppIndicatorOverlay`).
    @ToolbarContentBuilder
    private func sharedToolbar() -> some ToolbarContent {
        ToolbarItem(placement: .topBarTrailing) {
            let scanAction = {
                conversationsViewModel.onJoinConvo()
            }
            Button(action: scanAction) {
                Image(systemName: "viewfinder")
            }
            .accessibilityLabel("Scan a code")
            .accessibilityIdentifier("scan-button")
            .disabled(conversationsViewModel.staleDeviceObserver.isDeviceRemoved)
        }
        ToolbarItem(placement: .topBarTrailing) {
            Button("Compose", systemImage: "plus") {
                conversationsViewModel.onStartConvo()
            }
            .matchedTransitionSource(id: Constant.composerTransitionId, in: namespace)
            .accessibilityIdentifier("compose-button")
            .disabled(conversationsViewModel.staleDeviceObserver.isDeviceRemoved)
        }
    }

    /// AppIndicatorPill rendered as an overlay above the entire app
    /// (outside the `NavigationStack`) using the exact same structure
    /// `ConversationPresenter` uses: a `VStack` that ignores the
    /// safe area, with the pill padded down by `safeAreaInsets.top`
    /// so it sits flush with the leading edge of the nav-bar zone.
    /// Native toolbars clip ToolbarItem height to ~44pt; the pill is
    /// taller than that, so it must be an overlay rather than a
    /// ToolbarItem. Hidden when a conversation is
    /// pushed onto the outer NavigationStack — the centered
    /// conversation indicator inside the pushed view's
    /// `ConversationPresenter` morphs into place via the
    /// `sharedIndicatorNamespace` matched-geometry pair.
    @ViewBuilder
    private var sharedAppIndicatorOverlay: some View {
        VStack(spacing: 0) {
            if let activeConvoVM = activeConvoVM {
                centeredConversationIndicator(for: activeConvoVM)
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

    @ViewBuilder
    private func centeredConversationIndicator(for convoVM: ConversationViewModel) -> some View {
        let pendingAgentOverride: AgentVerification? = convoVM.shouldRenderAsPendingAgent
            ? .verified(.convos)
            : nil
        let pendingAgentIdentity: PendingAgentAvatarIdentity? = convoVM.pendingAgentPresentation?.avatarIdentity
        let isReadOnly: Bool = conversationsViewModel.staleDeviceObserver.isDeviceRemoved || convoVM.conversation.wasRemoved
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

    /// The conversation the shared overlay is showing, if any. Drives its
    /// morph between the leading pill (when nil) and the centered
    /// conversation indicator (when non-nil).
    private var activeConvoVM: ConversationViewModel? {
        conversationsViewModel.selectedConversationViewModel
    }

    private enum Constant {
        static let appSettingsTransitionId: String = "app-settings-transition-source"
        static let composerTransitionId: String = "composer-transition-source"
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
        case .contacts: return contactsNavState
        }
    }

    func closeActiveTabNavigator(_ tab: ConvosTab, context: ScreenContext) {
        switch tab {
        case .chats: conversationsNavigator?.closed(context: context)
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
        case .contacts: contactsNavigator?.present(appSettings: AppSettingsNavigatorArgs())
        }
    }

    func handleSelectedConversationChanged(from oldId: String?, to newId: String?) {
        guard oldId == nil, let newId else { return }
        conversationsNavigator?.navigateTo(conversation: ConversationNavigatorArgs(conversationId: newId))
    }

    func handleNewConversationPresented(_ isPresenting: Bool, wasPresenting: Bool) {
        guard !wasPresenting, isPresenting else { return }
        let mode: ConvosMetrics.NewConversationMode = .create
        conversationsNavigator?.present(newConversation: NewConversationNavigatorArgs(mode: mode))
    }
}

/// All the sheets / covers that the `MainTabView` shell hosts, extracted
/// into a `ViewModifier` so the host's `body` stays within the
/// `warn-long-expression-type-checking` budget.
struct MainTabSheetsModifier: ViewModifier {
    @Bindable var conversationsViewModel: ConversationsViewModel
    let profileSettingsViewModel: ProfileSettingsViewModel
    let coreActions: any CoreActions
    @Binding var presentingAppSettings: Bool
    let namespace: Namespace.ID

    /// Routes every dismissal of the incoming-pairing sheet through
    /// `dismissIncomingPairingRequest()` so the flow is cancelled before
    /// the view model reference is dropped. A plain item binding with an
    /// `onDismiss` can't do this for interactive (swipe) dismissal:
    /// SwiftUI nils the binding before `onDismiss` runs, so by then
    /// there's no view model left to cancel and the pairing service's
    /// stream keeps running. Cancelling is safe on every path - the view
    /// model only sends the joiner-facing cancellation error from
    /// mid-handshake states, and stopping the service after completion
    /// or failure is the same cleanup the QR flow does on sheet close.
    private var incomingPairingBinding: Binding<PairingSheetViewModel?> {
        Binding(
            get: { conversationsViewModel.incomingPairingRequest },
            set: { newValue in
                if newValue == nil {
                    conversationsViewModel.dismissIncomingPairingRequest()
                } else {
                    conversationsViewModel.incomingPairingRequest = newValue
                }
            }
        )
    }

    func body(content: Content) -> some View {
        content
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
            .selfSizingSheet(
                item: incomingPairingBinding,
                content: { pairingVM in
                    PairingSheetView(viewModel: pairingVM)
                        .padding(.top, DesignConstants.Spacing.step5x)
                }
            )
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
            // Scanning is its own screen, presented as its own sheet. It reads
            // someone else's code, so it needs no conversation behind it.
            .sheet(isPresented: $conversationsViewModel.presentingScanner) {
                JoinConversationView(
                    viewModel: conversationsViewModel.scannerViewModel,
                    allowsDismissal: true,
                    onScannedCode: { code in
                        conversationsViewModel.handleScannedCode(code)
                    }
                )
            }
            // Dev-only: pick the agent variant for the conversation the
            // compose button is about to create.
            .selfSizingSheet(isPresented: $conversationsViewModel.presentingVariantPicker) {
                AgentVariantPickerSheet(
                    onContinue: { slug in
                        conversationsViewModel.startNewConversation(agentVariantSlug: slug)
                    }
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
            contactsPushedItemId: contactsPath.last?.id,
            presentingAppSettings: presentingAppSettings,
            selectedConversationId: conversationsViewModel.selectedConversationId,
            newConversationPresenting: conversationsViewModel.newConversationViewModel != nil,
            onActiveTabChanged: handleActiveTabChanged(from:to:),
            onScenePhaseChanged: handleScenePhaseChanged(to:),
            onContactsPushChanged: handleContactsPushChanged(from:to:),
            onAppSettingsPresented: handleAppSettingsPresented(_:),
            onSelectedConversationChanged: handleSelectedConversationChanged(from:to:),
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
            namespace: namespace
        )
    }
}
