import Combine
import ConvosCore
import ConvosMetrics
import Foundation
import PostHog
import Sentry

final class PostHogCollector: CollectorDelegate {
    var userPropertiesCancellable: AnyCancellable?

    override func navigatedTo(source: String, target: String) {
        Log.info("nav: \(source) -> \(target)")
        PostHogSDK.shared.capture("$screen", properties: [
            "source": source,
            "$screen_name": target,
        ])
    }

    override func presented(source: String, target: String) {
        Log.info("present: \(source) -> \(target)")
        PostHogSDK.shared.capture("$screen", properties: [
            "source": source,
            "$screen_name": target,
        ])
    }

    override func closed(screen: String, context: ScreenContext) {
        Log.info("closed: \(screen) durationSecs=\(context.durationSecs)")
        PostHogSDK.shared.capture("screen_closed", properties: [
            "$screen_name": screen,
            "duration_secs": context.durationSecs,
        ])
    }

    override func identify(userId: String) {
        Log.info("identifying as= \(userId)")
        PostHogSDK.shared.identify(userId)
    }

    override func updateUserProperties(properties: [String: Any?]) {
        Log.info("updating user props= \(properties)")
        PostHogSDK.shared.setPersonProperties(
            userPropertiesToSet: properties.compactMapValues { $0 }
        )
    }

    override func sendEvent(name: String, properties: [String: Any?]) {
        Log.info("sending event=\(name), \(properties)")
        PostHogSDK.shared.capture(
            name,
            properties: properties.compactMapValues { $0 }
        )
        captureDiagnosticEventInSentry(name: name, properties: properties)
    }

    /// Engineering diagnostics that should alert through Sentry rather than
    /// only landing in product analytics. No-op when the SDK isn't started
    /// (local/test builds).
    private func captureDiagnosticEventInSentry(name: String, properties: [String: Any?]) {
        guard let message = diagnosticMessage(for: name, properties: properties) else { return }
        let event = Event(level: .warning)
        event.message = SentryMessage(formatted: message)
        event.extra = properties.compactMapValues { $0 }
        SentrySDK.capture(event: event)
    }

    /// The message doubles as the Sentry grouping key, so each failure cause
    /// gets its own issue rather than one bucket of every failed join.
    ///
    /// Carries no PII: the join properties are the classified failure reason,
    /// timing numbers, and the creator device's own diagnostic string, which
    /// is hand-authored at each rejection site and bounded to 500 characters.
    private func diagnosticMessage(for name: String, properties: [String: Any?]) -> String? {
        switch name {
        case MetricsCoreActions.eventAssistantJoinRescuedByPolling:
            return "assistant join rescued by polling - message stream likely dead"
        case MetricsCoreActions.eventJoinedConversation:
            return failedJoinMessage(properties: properties)
        default:
            return nil
        }
    }

    /// Only the causes that mean something is broken on our side reach Sentry.
    /// An unapproved invite, an expired convo, or a dropped connection are
    /// expected outcomes with real volume - they belong in the funnel, not in
    /// an issue tracker, and routing them here would bury the rest.
    private func failedJoinMessage(properties: [String: Any?]) -> String? {
        let isSuccess: Bool? = properties[MetricsCoreActions.paramIsSuccess].flatMap { $0 } as? Bool
        guard isSuccess == false else { return nil }

        let rawReason: String? = properties[MetricsCoreActions.paramFailureReason].flatMap { $0 } as? String
        let reason: String = rawReason ?? JoinFailureReason.unknown.metricsString
        guard Self.sentryReportedJoinFailures.contains(reason) else { return nil }

        return "invite join failed - \(reason)"
    }

    private static let sentryReportedJoinFailures: Set<String> = [
        JoinFailureReason.inboxNeverReady.metricsString,
        JoinFailureReason.signatureVerificationFailed.metricsString,
        JoinFailureReason.internalStorageError.metricsString,
        JoinFailureReason.unknown.metricsString,
    ]
}
