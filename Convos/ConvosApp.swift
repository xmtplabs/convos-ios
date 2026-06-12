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
    let profileSettingsViewModel: ProfileSettingsViewModel = .shared

    init() {
        FileDescriptorDiagnostics.raiseSoftLimit(to: 512)

        ConfigManager.configure(overrides: ConvosSecretOverrides(
            apiBaseURL: Secrets.CONVOS_API_BASE_URL,
            xmtpCustomHost: Secrets.XMTP_CUSTOM_HOST,
            gatewayURL: Secrets.GATEWAY_URL
        ))
        let environment = ConfigManager.shared.currentEnvironment
        ConvosLog.configure(environment: environment)

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
        Log.info("App starting with environment: \(environment)")
        let appVersion = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "unknown"
        let appBuild = Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? "unknown"
        Log.info("Launch: version=\(appVersion) build=\(appBuild) commit=\(Secrets.GIT_COMMIT_SHA) environment=\(environment.name)")
        QAEvent.emit(.app, "launched", ["environment": environment.name])

        // Firebase must be configured before ConvosClient is created so AppCheck is ready when auth begins
        switch environment {
        case .tests:
            Log.info("Running in test environment, skipping Firebase config...")
        default:
            let configManager = ConfigManager.shared
            let overrideURL: URL? = configManager.firebaseConfigOverride.flatMap {
                Bundle.main.url(forResource: $0, withExtension: "plist")
            }
            if let url = overrideURL ?? configManager.currentEnvironment.firebaseConfigURL {
                let debugToken: String? = environment.isProduction ? nil : Secrets.FIREBASE_APP_CHECK_DEBUG_TOKEN
                FirebaseHelperCore.configure(with: url, debugToken: debugToken)
            } else {
                Log.error("Missing Firebase plist URL for current environment")
            }
        }

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

        let dbWriter = convos.databaseWriter
        Task {
            await agentKeyset.prefetch()
            try? await AgentVerificationWriter.reverifyUnverifiedAgents(in: dbWriter)
        }
        self.coreActions = coreMetrics.actions
        self.conversationsViewModel = .init(session: convos.session, coreActions: coreMetrics.actions)
        appDelegate.session = convos.session
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

        let metricsSession = convos.session
        Task {
            do {
                let messagingService = metricsSession.messagingService()
                let inboxReady = try await messagingService.sessionStateManager.waitForInboxReadyResult()
                coreMetrics.identify(privateKey: Data(inboxReady.client.inboxId.utf8))
                let builder = UserPropertiesBuilder(
                    contactsRepository: messagingService.contactsRepository(),
                    conversationsRepository: metricsSession.conversationsRepository(for: .all)
                )
                metricsDelegate.userPropertiesCancellable = builder.publisher()
                    .sink { properties in
                        Task { await coreMetrics.updateUserProperties(properties: properties) }
                    }
            } catch {
                Log.warning("Metrics identify failed: \(error.localizedDescription)")
            }
        }

        Self.configureTabBarItemColors()
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

    var body: some Scene {
        WindowGroup {
            MainTabView(
                conversationsViewModel: conversationsViewModel,
                profileSettingsViewModel: profileSettingsViewModel,
                coreActions: coreActions
            )
            .additionalTopSafeArea(DesignConstants.Spacing.stepX)
            .withSafeAreaEnvironment()
            .onChange(of: scenePhase) { _, newPhase in
                guard newPhase == .active else { return }
                // Foreground refresh — TTL-debounced inside both services, so
                // this is a cheap no-op if we were just active. Catches the
                // case where credits changed server-side while the app was
                // backgrounded (agent runtime consume, Apple webhook, manual op).
                Task {
                    await CreditsServices.shared.refresh()
                    await SubscriptionServices.shared.refresh()
                }
            }
        }
    }
}
