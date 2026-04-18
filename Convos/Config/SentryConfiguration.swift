import ConvosCore
import Foundation
import Sentry

enum SentryConfiguration {
    static func configure() {
        guard shouldEnableSentry() else {
            Log.info("Sentry disabled: not a Convos (Dev) distribution build")
            return
        }

        let dsn = Secrets.SENTRY_DSN
        guard !dsn.isEmpty else {
            Log.error("Sentry DSN is empty, skipping initialization")
            return
        }

        let envName = ConfigManager.shared.currentEnvironment.name
        Log.info("Initializing Sentry for environment: \(envName)")

        SentrySDK.start { options in
            options.dsn = dsn
            options.debug = true
            options.attachScreenshot = true
            options.enableSigtermReporting = true
            options.attachStacktrace = true
            options.attachViewHierarchy = true

            // Enable PII for internal team debugging in dev builds
            // This captures IP addresses, user IDs, and request data
            // Safe because .dev builds are only distributed to internal team via TestFlight
            options.sendDefaultPii = true

            options.environment = "\(envName)-debug"
        }

        Log.info("Sentry initialized successfully")
    }

    private static func shouldEnableSentry() -> Bool {
        let environment = ConfigManager.shared.currentEnvironment

        switch environment {
        case .local:
            // Local builds never use Sentry
            return false
        case .dev, .testnet:
            // Dev builds (TestFlight) use Sentry even with DEBUG flag
            // This is intentional: Dev.xcconfig defines DEBUG for debugging Swift packages
            return true
        case .production, .tests:
            return false
        }
    }
}
