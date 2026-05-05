import ConvosCore
import ConvosCoreiOS
import SwiftUI
import UserNotifications
import XMTPiOS

@main
struct ConvosApp: App {
    @UIApplicationDelegateAdaptor(ConvosAppDelegate.self) private var appDelegate: ConvosAppDelegate

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

        if !environment.isProduction {
            Log.info("Activating LibXMTP Log Writer...")
            Client.activatePersistentLibXMTPLogWriter(
                logLevel: .debug,
                rotationSchedule: .hourly,
                maxFiles: 10,
                customLogDirectory: environment.defaultXMTPLogsDirectoryURL,
                processType: .main
            )
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

        self.convos = .client(environment: environment, platformProviders: .iOS)

        let dbWriter = convos.databaseWriter
        Task {
            await agentKeyset.prefetch()
            try? await AgentVerificationWriter.reverifyUnverifiedAgents(in: dbWriter)
        }
        self.conversationsViewModel = .init(session: convos.session)
        appDelegate.session = convos.session
        appDelegate.pushNotificationRegistrar = convos.platformProviders.pushNotificationRegistrar
        profileSettingsViewModel.bind(session: convos.session)
    }

    var body: some Scene {
        WindowGroup {
            ConversationsView(
                viewModel: conversationsViewModel,
                profileSettingsViewModel: profileSettingsViewModel
            )
            .additionalTopSafeArea(DesignConstants.Spacing.stepX)
            .withSafeAreaEnvironment()
        }
    }
}
