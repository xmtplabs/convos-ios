import ConvosCore
@preconcurrency import ConvosMetrics
import Foundation
import PostHog

enum PostHogConfiguration {
    static let stableIdEncoder: MetricsStableIdEncoder = MetricsStableIdEncoder(
        salt: Data("convos-metrics".utf8),
        info: Data("inbox-stable-id".utf8)
    )

    /// Set exactly once during `ConvosApp.init()` via
    /// `register(metricsDelegate:)` and read from many SwiftUI view init sites
    /// thereafter. The write-once-at-launch + read-many invariant is what makes
    /// `nonisolated(unsafe)` safe here -- there is no concurrent mutation to
    /// race against. Don't introduce a second writer; if you need to clear or
    /// swap the delegate, add an explicit API and reason about the readers
    /// first.
    nonisolated(unsafe) private(set) static var sharedMetricsDelegate: CollectorDelegate?

    static func register(metricsDelegate: CollectorDelegate) {
        sharedMetricsDelegate = metricsDelegate
    }

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
        config.enableSwizzling = false
        PostHogSDK.shared.setup(config)
        PostHogSDK.shared.register(["environment": envName])

        Log.info("PostHog initialized successfully")
    }

    private static func shouldEnablePostHog() -> Bool {
        switch ConfigManager.shared.currentEnvironment {
        case .tests:
            return false
        case .local:
            return !Secrets.POSTHOG_API_KEY.isEmpty
        case .dev, .production:
            return true
        }
    }
}
