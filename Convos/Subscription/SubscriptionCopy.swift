import ConvosCore
import Foundation

enum SubscriptionCopy {
    static let heroTitle: String = "Power your agents"
    static let heroSubtitle: String = "Subscribe to keep your assistants sharp."
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
                "1,500 credits / month",
                "Standard model on every reply",
                "Free slow-mode when credits run low",
            ]
        case .pro:
            return [
                "5,000 credits / month",
                "Standard + premium model access",
                "Free slow-mode when credits run low",
                "Priority support",
            ]
        }
    }
}
