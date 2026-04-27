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
    let quicknameViewModel: QuicknameSettingsViewModel = .shared
    @MainActor let backupCoordinator: BackupCoordinator
    @MainActor let staleDeviceObserver: StaleDeviceObserver = .init()

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
            if let url = ConfigManager.shared.currentEnvironment.firebaseConfigURL {
                let debugToken: String? = environment.isProduction ? nil : Secrets.FIREBASE_APP_CHECK_DEBUG_TOKEN
                FirebaseHelperCore.configure(with: url, debugToken: debugToken)
            } else {
                Log.error("Missing Firebase plist URL for current environment")
            }
        }

        let agentKeyset = AgentKeyset(endpointURL: AgentKeyset.endpointURL(for: environment))
        AgentKeysetStore.instance.configure(agentKeyset)

        self.convos = .client(environment: environment, platformProviders: .iOS)

        // Register BGProcessingTask for daily backups. Must happen
        // during app init per BGTaskScheduler's contract. Factory
        // returns a fresh BackupManager each call so a restore that
        // rebuilds the cached service doesn't leave the scheduler
        // holding a stale client.
        let convosRef = convos
        BackupScheduler.shared.register(
            environment: { convosRef.environment },
            factory: { convosRef.makeBackupManager() }
        )

        let dbWriter = convos.databaseWriter
        Task {
            await agentKeyset.prefetch()
            try? await AgentVerificationWriter.reverifyUnverifiedAgents(in: dbWriter)
        }
        self.conversationsViewModel = .init(session: convos.session)
        let coordinator = BackupCoordinator(convos: convos)
        self.backupCoordinator = coordinator
        // Resolve the fresh-install bootstrap gate: if a compatible
        // backup is visible, leave the gate closed and show the prompt
        // card; otherwise release the gate so normal registration runs.
        Task { @MainActor in
            await coordinator.resolveBootstrapDecision()
        }
        appDelegate.session = convos.session
        appDelegate.pushNotificationRegistrar = convos.platformProviders.pushNotificationRegistrar
    }

    var body: some Scene {
        WindowGroup {
            ConversationsView(
                viewModel: conversationsViewModel,
                quicknameViewModel: quicknameViewModel,
                backupCoordinator: backupCoordinator
            )
            .additionalTopSafeArea(DesignConstants.Spacing.stepX)
            .withSafeAreaEnvironment()
            .overlay(alignment: .top) {
                if staleDeviceObserver.isDeviceReplaced {
                    let reset: () -> Void = {
                        Task { try? await convos.session.deleteAllInboxes() }
                    }
                    StaleDeviceBanner(onReset: reset)
                        .padding(.top, 12)
                        .transition(.move(edge: .top).combined(with: .opacity))
                }
            }
            .task(id: backupCoordinator.sessionObservationGeneration) { @MainActor in
                guard backupCoordinator.sessionObservationGeneration > 0 else { return }
                let service = convos.session.messagingService()
                staleDeviceObserver.bind(to: service.sessionStateManager)
                await BackupScheduler.shared.runForegroundCatchUpIfNeeded()
            }
        }
    }
}
