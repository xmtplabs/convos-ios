import ConvosCore
@preconcurrency import ConvosMetrics
import Foundation
import PostHog

enum PostHogConfiguration {
    static let stableIdEncoder: MetricsStableIdEncoder = MetricsStableIdEncoder(
        salt: Data("convos-metrics".utf8),
        info: Data("inbox-stable-id".utf8)
    )

    nonisolated(unsafe) static var sharedMetricsDelegate: CollectorDelegate?

    static func configure() {
        guard shouldEnablePostHog() else {
            Log.info("PostHog disabled for current environment")
            return
        }

        let apiKey = Secrets.POSTHOG_API_KEY
        guard !apiKey.isEmpty else {
            Log.error("PostHog API key is empty, skipping initialization")
            return
        }

        guard let host = ConfigManager.shared.posthogHost, !host.isEmpty else {
            Log.error("PostHog host missing in config.json, skipping initialization")
            return
        }

        let envName = ConfigManager.shared.currentEnvironment.name
        Log.info("Initializing PostHog for environment: \(envName)")

        let config = PostHogConfig(projectToken: apiKey, host: host)
        config.captureApplicationLifecycleEvents = true
        config.captureScreenViews = false
        PostHogSDK.shared.setup(config)
        PostHogSDK.shared.register(["environment": envName])

        Log.info("PostHog initialized successfully")
    }

    private static func shouldEnablePostHog() -> Bool {
        switch ConfigManager.shared.currentEnvironment {
        case .local, .tests:
            return false
        case .dev, .production:
            return true
        }
    }
}
