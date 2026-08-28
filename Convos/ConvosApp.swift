import ConvosCore
import ConvosCoreiOS
import ConvosMetrics
import SwiftUI
import UserNotifications
import XMTPiOS

@main
struct ConvosApp: App {
    @UIApplicationDelegateAdaptor(ConvosAppDelegate.self) private var appDelegate: ConvosAppDelegate
    @Environment(\.scenePhase) private var scenePhase: ScenePhase

    private let convos: ConvosClient
    let metricsDelegate: PostHogCollector
    let coreActions: any CoreActions
    let conversationsViewModel: ConversationsViewModel
    let agentRelayDependencies: AgentRelayDependencies?
    let profileSettingsViewModel: ProfileSettingsViewModel = .shared
    /// Guards the opportunistic agent-timezone republish to once per foreground
    /// session, so background-foregrounding the app repeatedly does not re-run
    /// it. A reference type so the flag survives across `onChange` invocations
    /// of the value-type App.
    private let timezoneForegroundGuard: ForegroundOnceGuard = ForegroundOnceGuard()
    /// The launch task owns the initial recovery pass. Starting consumed keeps
    /// SwiftUI's first active transition from scheduling the same pass again.
    private let agentRelayForegroundGuard: ForegroundOnceGuard = ForegroundOnceGuard(initiallyConsumed: true)

    /// Deletes the cache the home's snapshot cover used to write.
    ///
    /// The feature is gone, so nothing reads these files and nothing else would
    /// ever delete them: one full-screen PNG per conversation ever opened,
    /// sitting in `Caches/` until the OS evicts it. Safe to delete this along
    /// with the directory it clears, a release or two after everyone has
    /// launched a build containing it.
    private static func removeHomeSnapshotCache() {
        guard let caches = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first else { return }
        try? FileManager.default.removeItem(at: caches.appendingPathComponent("HomeSnapshots", isDirectory: true))
    }

    init() {
        FileDescriptorDiagnostics.raiseSoftLimit(to: 512)
        Self.removeHomeSnapshotCache()

        ConfigManager.configure(overrides: ConvosSecretOverrides(
            apiBaseURL: Secrets.CONVOS_API_BASE_URL,
            xmtpCustomHost: Secrets.XMTP_CUSTOM_HOST,
            gatewayURL: Secrets.GATEWAY_URL
        ))
        let environment = ConfigManager.shared.currentEnvironment
        ConvosLog.configure(environment: environment)

        // Export the persisted bidi-streams opt-in while the process is still
        // effectively single-threaded (setenv racing a native getenv from a
        // spawned thread is undefined behavior) and before anything touches
        // libxmtp, which latches the gate env var once, before the first
        // stream -- so a Debug-menu flip takes effect here, on the next
        // launch. Runtime setenv works for the Rust layer because it reads
        // getenv, unlike the AppCheck case documented in FirebaseHelper.
        // Main-app process only, deliberately: the NotificationService
        // extension and App Clip run their own processes (with their own
        // defaults containers) and stay on the legacy stream path.
        if FeatureFlags.shared.isXMTPBidiStreamsEnabled {
            setenv("XMTP_BIDI_STREAMS_ENABLED", "1", 1)
            Log.info("XMTP bidi streams enabled for this launch")
        }

        // Start Sentry as early as possible so crashes during the rest of app
        // init (database setup, Firebase, client creation) are captured. The
        // SwiftUI App initializer runs before the app delegate's
        // didFinishLaunching, so starting it there would leave all of this
        // initialization as a crash-reporting blind spot.
        SentryConfiguration.configure()

        // Verbose libxmtp logs are invaluable in dev/local but too chatty (and too
        // revealing of protocol internals) to persist on every production device.
        // Activation does file I/O (and formats an internal error description on
        // its failure path), so it runs off the synchronous launch path; the
        // handful of libxmtp log lines emitted before it lands are an accepted
        // trade for ~20ms of pre-first-frame main-thread time.
        let libXMTPLogLevel: Client.LogLevel = environment.isProduction ? .warn : .debug
        Task.detached(priority: .utility) {
            Log.info("Activating LibXMTP file log writer at \(environment.defaultXMTPLogsDirectoryURL.path) (level=\(libXMTPLogLevel), rotation=hourly, maxFiles=10)…")
            Client.activatePersistentLibXMTPLogWriter(
                logLevel: libXMTPLogLevel,
                rotationSchedule: .hourly,
                maxFiles: 10,
                customLogDirectory: environment.defaultXMTPLogsDirectoryURL,
                processType: .main
            )
            Log.info("LibXMTP file log writer activated")
            Log.info("Setting LibXMTP native log level to \(libXMTPLogLevel)…")
            Client.setLibXMTPNativeLogLevel(libXMTPLogLevel)
            Log.info("LibXMTP native log level set to \(libXMTPLogLevel)")
        }

        // libxmtp reports its own errors and spans into the same Sentry project
        // as the app, so a protocol-layer failure shows up next to the app-side
        // event it caused. Enabled after the log writer is scheduled so both
        // native sinks are configured before any client work starts.
        LibxmtpSentry.configure(environment: environment)

        Log.info("App starting with environment: \(environment)")
        let appVersion = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "unknown"
        let appBuild = Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? "unknown"
        Log.info("Launch: version=\(appVersion) build=\(appBuild) commit=\(Secrets.GIT_COMMIT_SHA) environment=\(environment.name)")
        QAEvent.emit(.app, "launched", ["environment": environment.name])
        QALaunchHooks.run(environment: environment)

        Self.wireDefaultAgentVariantProvider()
        Self.configureFirebase(environment: environment)

        #if DEBUG
        let debugFallbackKey = DebugAgentKeysetOverride.parse(jwksJSON: Secrets.AGENT_DEBUG_JWKS)
        if let debugFallbackKey {
            Log.info("[AgentKeyset] DEBUG fallback key loaded from .env: kid=\(debugFallbackKey.kid)")
        }
        #else
        let debugFallbackKey: AgentKeysetEntry? = nil
        #endif
        let agentKeyset = AgentKeyset(
            endpointURL: AgentKeyset.endpointURL(for: environment),
            fallbackKey: debugFallbackKey
        )
        AgentKeysetStore.instance.configure(agentKeyset)

        let metricsDelegate = PostHogCollector()
        let coreMetrics = CoreMetrics(
            delegate: metricsDelegate,
            stableId: PostHogConfiguration.stableIdEncoder
        )
        PostHogConfiguration.register(metricsDelegate: metricsDelegate)
        self.metricsDelegate = metricsDelegate
        self.convos = .client(environment: environment, platformProviders: .iOS, coreActions: coreMetrics.actions)

        // Sync the mock credits/subscription state from the persisted picker
        // preset so HOME pill + paywall reflect the operator's last selection.
        // Non-production only; production builds will swap in real services.
        if !environment.isProduction {
            let persistedPreset = FeatureFlags.shared.mockCreditsPreset
            MockCreditsService.shared.setPreset(persistedPreset)
            MockSubscriptionService.shared.setPreset(persistedPreset)
        }

        Self.configureAbilities(session: convos.session, environment: environment)

        let dbWriter = convos.databaseWriter
        Task {
            await agentKeyset.prefetch()
            try? await AgentVerificationWriter.reverifyUnverifiedAgents(in: dbWriter)
        }
        self.coreActions = coreMetrics.actions
        self.conversationsViewModel = .init(session: convos.session, coreActions: coreMetrics.actions)
        let relayDependencies = try? AgentRelayDependencies(environment: environment)
        self.agentRelayDependencies = relayDependencies
        appDelegate.session = convos.session
        let relaySession = convos.session
        appDelegate.agentRelayPushCollector = { payload in
            await relayDependencies?.collectForegroundPush(payload, session: relaySession)
        }
        Task {
            await relayDependencies?.recoverOnLaunch(session: relaySession)
        }
        // Runs when a share-extension upload wakes the app in the background:
        // publish whatever the extension staged but never got to send.
        let drainWriter = convos.databaseWriter
        let drainSession = convos.session
        appDelegate.shareExtensionOutboxDrain = {
            await OutgoingMessageDrain.drainStuckOutgoingMessages(
                databaseWriter: drainWriter,
                messagingService: drainSession.messagingService(),
                backgroundUploadManager: BackgroundUploadManager.shared
            )
            await AgentBuildOutbox.drain(
                session: drainSession,
                backgroundUploadManager: BackgroundUploadManager.shared
            )
        }
        // PushNotificationRegistrar.configure(...) ran inside `PlatformProviders.iOS`
        // above, so AppDelegate's APNS callback uses the static accessor directly
        // (see ConvosAppDelegate.didRegisterForRemoteNotificationsWithDeviceToken).
        // Deferred one runloop turn: bind() synchronously constructs the
        // messaging service reader stack, which doesn't need to block the
        // first frame -- the profile UI is reactive and fills in as soon as
        // the binding lands.
        let profileViewModel = profileSettingsViewModel
        let profileSession = convos.session
        Task { @MainActor in
            profileViewModel.bind(session: profileSession)
        }

        Self.startMetricsIdentification(
            session: convos.session,
            environment: environment,
            coreMetrics: coreMetrics,
            metricsDelegate: metricsDelegate
        )

        HomeWebViewPrewarmer.prewarmIfNeeded(session: convos.session)

        Self.configureTabBarItemColors()
    }

    /// Identifies the metrics stack once the inbox is ready and streams
    /// user properties into it; runs entirely off the launch path.
    private static func startMetricsIdentification(
        session: any SessionManagerProtocol,
        environment: AppEnvironment,
        coreMetrics: CoreMetrics,
        metricsDelegate: PostHogCollector
    ) {
        Task {
            do {
                let messagingService = session.messagingService()
                let inboxReady = try await messagingService.sessionStateManager.waitForInboxReadyResult()
                let inboxKey = Data(inboxReady.client.inboxId.utf8)
                coreMetrics.identify(privateKey: inboxKey)
                // Deriving the id the same way PostHog does makes the Sentry
                // user and the product-analytics person the same identifier,
                // so an error and the session it broke can be lined up without
                // either side carrying the inbox id.
                LibxmtpSentry.setUser(
                    stableId: PostHogConfiguration.stableIdEncoder.derive(privateKey: inboxKey)
                )
                // The backend accountId (not the XMTP inbox id) lets product
                // analytics cross-link to backend records. Backend SIWE auth
                // caches it in the keychain before the session reaches inbox
                // ready, so this network-free keychain read has it by now.
                let identityStore = KeychainIdentityStore(accessGroup: environment.keychainAccessGroup)
                let accountId = await DeviceIdentitySnapshot.current(identityStore: identityStore).accountId
                let builder = UserPropertiesBuilder(
                    contactsRepository: messagingService.contactsRepository(),
                    conversationsRepository: session.conversationsRepository(for: .all),
                    accountId: accountId
                )
                metricsDelegate.userPropertiesCancellable = builder.publisher()
                    .sink { properties in
                        Task { await coreMetrics.updateUserProperties(properties: properties) }
                    }
            } catch {
                Log.warning("Metrics identify failed: \(error.localizedDescription)")
            }
        }
    }

    /// Configures Firebase before ConvosClient is created, so AppCheck is
    /// ready by the time auth begins.
    private static func configureFirebase(environment: AppEnvironment) {
        if case .tests = environment {
            Log.info("Running in test environment, skipping Firebase config...")
            return
        }
        let configManager = ConfigManager.shared
        let overrideURL: URL? = configManager.firebaseConfigOverride.flatMap {
            Bundle.main.url(forResource: $0, withExtension: "plist")
        }
        guard let url = overrideURL ?? configManager.currentEnvironment.firebaseConfigURL else {
            Log.error("Missing Firebase plist URL for current environment")
            return
        }
        let debugToken: String? = environment.isProduction ? nil : Secrets.FIREBASE_APP_CHECK_DEBUG_TOKEN
        FirebaseHelperCore.configure(with: url, debugToken: debugToken)
        // Extensions can't App Attest, so the main app hands them its current
        // App Check token via the shared app group (refreshed again on every
        // foreground in handleScenePhaseActive).
        let appGroupIdentifier = environment.appGroupIdentifier
        Task { await FirebaseHelperCore.mirrorTokenToAppGroup(appGroupIdentifier) }
    }

    /// Wires the live abilities service (mock/live selection happens per
    /// read via the Debug sub-toggle) and seeds the last-known catalog on
    /// cold launch; the scene-phase handler covers later foregrounds and
    /// the surfaces refresh again on appear.
    private static func configureAbilities(session: any SessionManagerProtocol, environment: AppEnvironment) {
        AbilitiesServices.configure(session: session, environment: environment)
        // Auto-enable was the v1 connections behavior; leaving the service
        // unconfigured keeps it disabled. Which services a conversation can
        // use is decided per environment by the backend and agent runtime,
        // not by the client enabling connections on every conversation.
        Task { await AbilitiesServices.refreshCatalogInBackground() }
    }

    /// Tints the unselected tab items tertiary. The selected color is
    /// driven by SwiftUI `.tint` (primary) on the `TabView`; the unselected
    /// color is set on the existing appearance's `normal` item state (we
    /// mutate the current appearance rather than build a fresh one so the
    /// Liquid Glass background is preserved). Only `.normal` is set so
    /// `.tint` keeps control of the selected item.
    private static func configureTabBarItemColors() {
        let inactive = UIColor(Color.colorTextTertiary)
        let bar = UITabBar.appearance()
        for appearance in [bar.standardAppearance, bar.scrollEdgeAppearance].compactMap({ $0 }) {
            for layout in [appearance.stackedLayoutAppearance, appearance.inlineLayoutAppearance, appearance.compactInlineLayoutAppearance] {
                layout.normal.iconColor = inactive
                layout.normal.titleTextAttributes = [.foregroundColor: inactive]
            }
        }
        bar.unselectedItemTintColor = inactive
    }

    /// Routes cache-time default-agent joins to the same variant as every other
    /// agent call: the conversation's own binding first, the global selector
    /// only as a fallback. Read live at join time; hops to the main actor
    /// because the resolution is main-actor-isolated.
    private static func wireDefaultAgentVariantProvider() {
        SessionManager.defaultAgentVariantIdProvider = { conversationId in
            await MainActor.run { AgentVariantResolution.slug(for: conversationId) }
        }
        // A build that can enter Doc holds the warm-cache join until a
        // conversation is adopted. Doc resolves and binds its labeled variant
        // before that claim-time provision can run.
        SessionManager.deferCacheTimeDefaultAgent = {
            await MainActor.run {
                DefaultAgentCacheProvisionPolicy.shouldDefer(
                    isDocExperienceEnabled: FeatureFlags.shared.isDocExperienceEnabled,
                    isDocExperienceAvailable: DebugMenuGate.showsFullDebugMenu(
                        for: ConfigManager.shared.currentEnvironment
                    ),
                    isAgentVariantSelectorEnabled: FeatureFlags.shared.isAgentVariantSelectorEnabled
                )
            }
        }
        // Records the pick against the conversation the claim actually handed
        // back, while that conversation's agent is still unprovisioned.
        SessionManager.claimedConversationVariantBinder = { conversationId, slug in
            await MainActor.run {
                AgentVariantAssignmentStore.shared.assign(slug: slug, to: conversationId)
            }
        }
    }

    var body: some Scene {
        WindowGroup {
            MainTabView(
                conversationsViewModel: conversationsViewModel,
                profileSettingsViewModel: profileSettingsViewModel,
                coreActions: coreActions
            )
            .additionalTopSafeArea(DesignConstants.Spacing.stepX)
            .withSafeAreaEnvironment()
            .environment(\.agentRelayDependencies, agentRelayDependencies)
            .onChange(of: scenePhase) { _, newPhase in
                switch newPhase {
                case .active:
                    handleScenePhaseActive()
                case .background:
                    // Push whatever libxmtp has buffered out now; a suspended
                    // process may never get another chance to send it.
                    LibxmtpSentry.flush()
                    // Re-arm once-per-foreground work for the next active session.
                    timezoneForegroundGuard.reset()
                    agentRelayForegroundGuard.reset()
                default:
                    break
                }
            }
        }
    }

    private func handleScenePhaseActive() {
        if agentRelayForegroundGuard.tryConsume() {
            let session = convos.session
            Task {
                await agentRelayDependencies?.recoverOnForeground(session: session)
            }
        }
        // Foreground refresh — TTL-debounced inside both services, so this is a
        // cheap no-op if we were just active. Catches the case where credits
        // changed server-side while the app was backgrounded (agent runtime
        // consume, Apple webhook, manual op).
        Task {
            await CreditsServices.shared.refresh()
            await SubscriptionServices.shared.refresh()
            // Keep the app-group App Check token fresh for extension
            // processes (share extension sends need it to authenticate).
            await FirebaseHelperCore.mirrorTokenToAppGroup(
                ConfigManager.shared.currentEnvironment.appGroupIdentifier
            )
        }

        // Abilities foreground refresh: updates the live service's
        // last-known catalog so the next screen-appear fetch merges against
        // fresh state. No-op in mock mode.
        Task { await AbilitiesServices.refreshCatalogInBackground() }

        // Messages the share extension wrote to the shared database from its
        // own process are invisible to this process's GRDB observation (it
        // only tracks in-process writes), so the conversation list and open
        // conversation would show them only after the next app-side write.
        // Nudge every observation to re-read on foreground, then republish
        // anything a dead process (share extension, force-quit app) staged
        // but never got to publish.
        let databaseWriter = convos.databaseWriter
        let drainSession = convos.session
        Task {
            try? await databaseWriter.write { db in
                try db.notifyChanges(in: .fullDatabase)
            }
            await OutgoingMessageDrain.drainStuckOutgoingMessages(
                databaseWriter: databaseWriter,
                messagingService: drainSession.messagingService(),
                backgroundUploadManager: BackgroundUploadManager.shared
            )
            await AgentBuildOutbox.drain(
                session: drainSession,
                backgroundUploadManager: BackgroundUploadManager.shared
            )
        }

        // Opportunistic agent-timezone republish (agent-timezone Channel B).
        // Once per foreground session, after a short settle delay, the session
        // republishes the device timezone for every agent conversation whose
        // last-published value differs from the current one. Throttling and
        // agent-scope gating live inside the session/publisher; this only
        // schedules the work from the foregrounded main app.
        guard timezoneForegroundGuard.tryConsume() else { return }
        let session = convos.session
        Task(priority: .utility) {
            try? await Task.sleep(nanoseconds: 5 * 1_000_000_000)
            await session.republishAgentTimezones()
        }
    }
}

/// Single-shot guard for once-per-foreground-session work.
/// `tryConsume()` returns true exactly once until `reset()` re-arms it on the
/// next background transition.
final class ForegroundOnceGuard: @unchecked Sendable {
    private let lock: NSLock = NSLock()
    private var consumed: Bool

    init(initiallyConsumed: Bool = false) {
        consumed = initiallyConsumed
    }

    func tryConsume() -> Bool {
        lock.lock()
        defer { lock.unlock() }
        guard !consumed else { return false }
        consumed = true
        return true
    }

    func reset() {
        lock.lock()
        defer { lock.unlock() }
        consumed = false
    }
}
