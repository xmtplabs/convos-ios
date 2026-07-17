import ConvosCore
import Foundation
import Sentry

enum SentryConfiguration {
    static func configure() {
        let environment = ConfigManager.shared.currentEnvironment
        guard shouldEnableSentry(for: environment) else {
            Log.info("Sentry disabled for environment: \(environment.name)")
            return
        }

        let dsn = Secrets.SENTRY_DSN
        guard !dsn.isEmpty else {
            Log.warning("Sentry DSN is empty, skipping initialization")
            return
        }

        let envName = environment.name
        let isProduction = environment.isProduction
        Log.info("Initializing Sentry for environment: \(envName)")

        SentrySDK.start { options in
            options.dsn = dsn
            options.debug = !isProduction
            options.enableSigtermReporting = true
            options.attachStacktrace = true

            if isProduction {
                // Crash and error reporting only. Screenshots, view hierarchy,
                // and default PII can carry message content and user identifiers,
                // so they never leave a production device.
                options.attachScreenshot = false
                options.attachViewHierarchy = false
                options.sendDefaultPii = false
                options.environment = envName
            } else {
                // Richer context (screenshots, view hierarchy, IP addresses,
                // user IDs, request data) for internal team debugging.
                // Safe because .dev builds are only distributed to the internal
                // team via TestFlight.
                options.attachScreenshot = true
                options.attachViewHierarchy = true
                options.sendDefaultPii = true
                options.environment = "\(envName)-debug"
            }
        }

        Log.info("Sentry initialized successfully")
    }

    private static func shouldEnableSentry(for environment: AppEnvironment) -> Bool {
        switch environment {
        case .local, .tests:
            // Local builds and test runs never report to Sentry
            return false
        case .dev, .production:
            // Dev (TestFlight) and production builds report to Sentry.
            // Dev stays enabled even with the DEBUG flag: Dev.xcconfig defines
            // DEBUG for debugging Swift packages, and that is intentional.
            return true
        }
    }
}
