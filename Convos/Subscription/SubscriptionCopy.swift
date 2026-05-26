import ConvosCore
import Foundation

enum PaywallPlan: String, CaseIterable {
    case basic
    case plus
}

enum SubscriptionCopy {
    static let heroLabel: String = "Upgrade"
    static let heroTitle: String = "Power your\nagents"

    static let legalDisclaimer: String = """
        Auto-renewing subscription. You'll be charged at the rate shown until you cancel. \
        Manage in Settings → Apple ID → Subscriptions on your device.
        """

    static func displayName(for tier: SubscriptionTier) -> String {
        switch tier {
        case .plus: return "Plus"
        }
    }

    static func creditHeadline(for plan: PaywallPlan) -> String {
        switch plan {
        case .basic: return "No monthly credits"
        case .plus: return "100,000 credits/month"
        }
    }

    static let creditSubheadline: String = "Daily top-up to 100"

    static let agentsHeadline: String = "Make unlimited agents"
    static let agentsSubheadline: String = "Connect unlimited apps"

    static func outcomes(for plan: PaywallPlan) -> [String] {
        switch plan {
        case .basic:
            return [
                "Coordinate a group or team",
                "Plan a weekend",
                "Daily accountability check-ins",
            ]
        case .plus:
            return [
                "Manage multiple groups and teams",
                "Plan daily life and adventures",
                "Always-on accountability partner",
            ]
        }
    }

    static let basicPriceLabel: String = "Free"
    static let basicPriceSubtitle: String = "Great for getting started"
    static let stayBasicLabel: String = "Stay Basic"
    static let upgradeLabel: String = "Upgrade"
    static let manageSubscriptionLabel: String = "Manage subscription"
}
