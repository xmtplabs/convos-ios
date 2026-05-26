import ConvosCore
import ConvosMetrics
import Foundation
import PostHog

final class PostHogCollector: CollectorDelegate {
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
    }
}
