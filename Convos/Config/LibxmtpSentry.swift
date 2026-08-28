import ConvosCore
import Foundation
import XMTPiOS

/// Bridges the app onto libxmtp's Sentry telemetry, so the Rust layer's spans
/// and errors land in the same Sentry project as the app's own events.
///
/// Every reference to the telemetry surface (`enableSentryTelemetry`,
/// `setSentryUser`, `flushTelemetry`, `FfiSentryConfig`, `FfiSentryTag`) lives
/// in this one file on purpose. Those symbols are uniffi codegen output that
/// ships inside the `XMTPiOS` module, so their spelling, argument labels, and
/// throwing-ness are decided by libxmtp's bindings rather than by hand-written
/// SDK code. Keeping the whole surface here makes a codegen rename a one-file
/// fix instead of a scatter of call-site edits.
enum LibxmtpSentry {
    /// Production samples 5% of operations into Sentry performance traces;
    /// the internal-build soak showed the span set is worth keeping. Error
    /// events are never sampled — only the waterfalls are.
    private static let productionTracesSampleRate: Float = 0.05
    private static let internalTracesSampleRate: Float = 0.1

    /// Matches the Sentry SDK's own default, and bounds how much libxmtp
    /// buffers between events.
    private static let maxBreadcrumbs: UInt32 = 100

    /// Enables libxmtp telemetry wherever the Swift Sentry SDK is also enabled,
    /// reporting under the same DSN and environment name so both sources sit
    /// side by side. Never throws out to the caller: telemetry must not be able
    /// to take down launch.
    static func configure(environment: AppEnvironment) {
        guard SentryConfiguration.shouldEnableSentry(for: environment) else {
            Log.info("libxmtp Sentry telemetry disabled for environment: \(environment.name)")
            return
        }

        let dsn = Secrets.SENTRY_DSN
        guard !dsn.isEmpty else {
            Log.warning("Sentry DSN is empty, skipping libxmtp telemetry")
            return
        }

        let sentryEnvironment = SentryConfiguration.environmentName(for: environment)
        let tracesSampleRate = environment.isProduction ? productionTracesSampleRate : internalTracesSampleRate
        do {
            try enableSentryTelemetry(config: FfiSentryConfig(
                dsn: dsn,
                environment: sentryEnvironment,
                release: nil,
                tracesSampleRate: tracesSampleRate,
                maxBreadcrumbs: maxBreadcrumbs,
                userStableId: nil,
                tags: []
            ))
            Log.info("libxmtp Sentry telemetry enabled for environment: \(sentryEnvironment) (tracesSampleRate: \(tracesSampleRate))")
        } catch {
            Log.error("Failed to enable libxmtp Sentry telemetry: \(error.localizedDescription)")
        }
    }

    /// Tags libxmtp's telemetry with the id PostHog identifies the person by,
    /// so a Sentry issue and a product-analytics person resolve to the same
    /// user without either side carrying the raw inbox id.
    static func setUser(stableId: String) {
        setSentryUser(stableId: stableId)
    }

    /// Drains buffered telemetry before the system can suspend the process.
    static func flush() {
        flushTelemetry()
    }
}
