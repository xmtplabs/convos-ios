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

    init() {
        FileDescriptorDiagnostics.raiseSoftLimit(to: 512)

        let environment = ConfigManager.shared.currentEnvironment
        // Configure logging (automatically disabled in production)
        ConvosLog.configure(environment: environment)

        // only enable LibXMTP logging in non-production environments
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

        // Configure Firebase before creating ConvosClient
        // This prevents SessionManager trying to use AppCheck before it's configured
        switch environment {
        case .tests:
            Log.info("Running in test environment, skipping Firebase config...")
        default:
            if let url = ConfigManager.shared.currentEnvironment.firebaseConfigURL {
                // Only pass debug token for non-production environments (safety check)
                let debugToken: String? = environment.isProduction ? nil : Secrets.FIREBASE_APP_CHECK_DEBUG_TOKEN
                FirebaseHelperCore.configure(with: url, debugToken: debugToken)
            } else {
                Log.error("Missing Firebase plist URL for current environment")
            }
        }

        self.convos = .client(environment: environment, platformProviders: .iOS)
        self.conversationsViewModel = .init(session: convos.session)
        appDelegate.session = convos.session
        appDelegate.pushNotificationRegistrar = convos.platformProviders.pushNotificationRegistrar
    }

    var body: some Scene {
        WindowGroup {
            ConversationsView(
                viewModel: conversationsViewModel,
                quicknameViewModel: quicknameViewModel
            )
            .additionalTopSafeArea(DesignConstants.Spacing.stepX)
            .withSafeAreaEnvironment()
        }
    }
}
