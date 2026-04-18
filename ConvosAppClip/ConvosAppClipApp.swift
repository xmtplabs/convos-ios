import ConvosCore
import ConvosCoreiOS
import SwiftUI

@main
struct ConvosAppClipApp: App {
    private let convos: ConvosClient

    init() {
        ConfigManager.configure(overrides: ConvosSecretOverrides(
            apiBaseURL: Secrets.CONVOS_API_BASE_URL,
            xmtpCustomHost: Secrets.XMTP_CUSTOM_HOST,
            gatewayURL: Secrets.GATEWAY_URL
        ))
        let environment = ConfigManager.shared.currentEnvironment
        ConvosLog.configure(environment: environment)
        ConvosLog.info("App Clip starting with environment: \(environment)", namespace: "ConvosAppClip")

        if let url = environment.firebaseConfigURL {
            let debugToken: String? = environment.isProduction ? nil : Secrets.FIREBASE_APP_CHECK_DEBUG_TOKEN
            FirebaseHelperCore.configure(with: url, debugToken: debugToken)
        } else {
            ConvosLog.error("Missing Firebase plist URL for current environment", namespace: "ConvosAppClip")
        }

        // Instantiating the client seeds the shared-app-group KeychainIdentityStore on first
        // launch. The main app picks up the same identity via the shared access group, so the
        // full app skips identity creation and lands on the conversation the clip joined.
        convos = .client(environment: environment, platformProviders: .iOS)
        _ = convos // keep alive for the app lifetime
    }

    var body: some Scene {
        WindowGroup {
            AppClipRootView()
        }
    }
}
