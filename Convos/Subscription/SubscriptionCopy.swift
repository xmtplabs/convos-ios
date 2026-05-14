import ConvosCore
import Foundation

enum SubscriptionCopy {
    static let heroTitle: String = "Power your agents"
    static let heroSubtitle: String = "Subscribe to keep your agents working for you."
    static let outcomeIntro: String = "Enough credits each month to:"
    static let legalDisclaimer: String = """
        Auto-renewing subscription. You'll be charged at the rate shown until you cancel. \
        Manage in Settings → Apple ID → Subscriptions on your device.
        """

    static func displayName(for tier: SubscriptionTier) -> String {
        switch tier {
        case .builder: return "Builder"
        case .pro: return "Pro"
        }
    }

    static func bullets(for tier: SubscriptionTier) -> [String] {
        switch tier {
        case .builder:
            return [
                "Plan ~5 trips",
                "Run a daily agent for a month",
            ]
        case .pro:
            return [
                "Plan ~20 trips",
                "Power a team of agents",
                "Priority support",
            ]
        }
    }
}
