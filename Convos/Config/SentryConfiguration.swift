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
        let sentryEnvironment = environmentName(for: environment)
        Log.info("Initializing Sentry for environment: \(envName)")

        SentrySDK.start { options in
            options.dsn = dsn
            options.debug = !isProduction
            // The OS sends SIGTERM as a routine prelude to termination, including
            // when it replaces the app on install. SentryCrash's handler
            // symbolicates through dladdr while the other threads are suspended,
            // which deadlocks on dyld's loader lock, so the process never exits
            // and the next launch re-foregrounds the frozen one.
            options.enableSigtermReporting = false
            options.attachStacktrace = true
            options.environment = sentryEnvironment

            if isProduction {
                // Crash and error reporting only. Screenshots, view hierarchy,
                // and default PII can carry message content and user identifiers,
                // so they never leave a production device.
                options.attachScreenshot = false
                options.attachViewHierarchy = false
                options.sendDefaultPii = false
            } else {
                // Richer context (screenshots, view hierarchy, IP addresses,
                // user IDs, request data) for internal team debugging.
                // Safe because .dev builds are only distributed to the internal
                // team via TestFlight.
                options.attachScreenshot = true
                options.attachViewHierarchy = true
                options.sendDefaultPii = true
            }
        }

        Log.info("Sentry initialized successfully")
    }

    /// The environment events report under. Non-production builds get a
    /// `-debug` suffix so their richer, PII-carrying events stay separable from
    /// production. Shared with `LibxmtpSentry` so libxmtp's telemetry lands in
    /// the same environment as the Swift SDK's events.
    static func environmentName(for environment: AppEnvironment) -> String {
        environment.isProduction ? environment.name : "\(environment.name)-debug"
    }

    /// Also gates libxmtp's telemetry, so the two event sources are never
    /// enabled independently of each other.
    static func shouldEnableSentry(for environment: AppEnvironment) -> Bool {
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
