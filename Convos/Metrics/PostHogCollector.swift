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
    /// only landing in product analytics: a poll-rescued assistant join is
    /// direct evidence of a silently dead message stream. No-op when the
    /// SDK isn't started (local/test builds) and carries no PII - only the
    /// stream-staleness numbers from the metric.
    private func captureDiagnosticEventInSentry(name: String, properties: [String: Any?]) {
        guard name == MetricsCoreActions.eventAssistantJoinRescuedByPolling else { return }
        let event = Event(level: .warning)
        event.message = SentryMessage(formatted: "assistant join rescued by polling - message stream likely dead")
        event.extra = properties.compactMapValues { $0 }
        SentrySDK.capture(event: event)
    }
}
