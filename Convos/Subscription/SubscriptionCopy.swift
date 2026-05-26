import ConvosCore
import Foundation

enum SubscriptionCopy {
    static let heroTitle: String = "Power your agents"
    static let heroSubtitle: String = "Subscribe to keep your agents working for you."
    static let examplesIntro: String = "For example, you could:"
    static let examplesDisclaimer: String = "Examples — actual usage varies by task."
    static let featuresIntro: String = "Includes:"
    static let legalDisclaimer: String = """
        Auto-renewing subscription. You'll be charged at the rate shown until you cancel. \
        Manage in Settings → Apple ID → Subscriptions on your device.
        """

    static func displayName(for tier: SubscriptionTier) -> String {
        switch tier {
        case .plus: return "Plus"
        }
    }

    static func outcomes(for tier: SubscriptionTier) -> [String] {
        switch tier {
        case .plus:
            return [
                "Plan ~5 trips",
                "Run a daily agent for a month",
                "Draft ~100 emails",
            ]
        }
    }

    static func features(for tier: SubscriptionTier) -> [String] {
        switch tier {
        case .plus:
            return []
        }
    }
}
