import ConvosCore
import ConvosCoreiOS
import SwiftUI
import UserNotifications
import XMTPiOS

@main
struct ConvosApp: App {
    @UIApplicationDelegateAdaptor(ConvosAppDelegate.self) private var appDelegate: ConvosAppDelegate
    @Environment(\.scenePhase) private var scenePhase: ScenePhase

    private let convos: ConvosClient
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

        Log.info("Activating LibXMTP file log writer at \(environment.defaultXMTPLogsDirectoryURL.path) (level=.debug, rotation=hourly, maxFiles=10)…")
        Client.activatePersistentLibXMTPLogWriter(
            logLevel: .debug,
            rotationSchedule: .hourly,
            maxFiles: 10,
            customLogDirectory: environment.defaultXMTPLogsDirectoryURL,
            processType: .main
        )
        Log.info("LibXMTP file log writer activated")
        Log.info("Setting LibXMTP native log level to .debug…")
        Client.setLibXMTPNativeLogLevel(.debug)
        Log.info("LibXMTP native log level set to .debug")
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

        self.convos = .client(environment: environment, platformProviders: .iOS)

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
        self.conversationsViewModel = .init(session: convos.session)
        appDelegate.session = convos.session
        // PushNotificationRegistrar.configure(...) ran inside `PlatformProviders.iOS`
        // above, so AppDelegate's APNS callback uses the static accessor directly
        // (see ConvosAppDelegate.didRegisterForRemoteNotificationsWithDeviceToken).
        profileSettingsViewModel.bind(session: convos.session)

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
                profileSettingsViewModel: profileSettingsViewModel
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
