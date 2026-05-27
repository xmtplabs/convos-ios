import ConvosCore
import Foundation

enum PaywallPlan: String, CaseIterable {
    case basic
    case plus
}

enum SubscriptionCopy {
    static let heroLabel: String = "Membership"
    static let heroTitle: String = "Power your agents"

    static let agentsHeadline: String = "Make unlimited agents"
    static let agentsSubheadline: String = "Connect unlimited apps"

    static func usageHeadline(for plan: PaywallPlan) -> String {
        switch plan {
        case .basic: return "Usage maximum"
        case .plus: return "Unlimited usage"
        }
    }

    static func usageSubheadline(for plan: PaywallPlan) -> String {
        switch plan {
        case .basic: return "Upgrade when you're ready"
        case .plus: return "Early bird offer. Abuse guardrails apply."
        }
    }

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
    static let upgradeAnytimeLabel: String = "Upgrade anytime"
    static let upgradeLabel: String = "Upgrade"
    static let manageSubscriptionLabel: String = "Manage subscription"

    static let legalDisclaimer: String = """
        Auto-renewing subscription. You'll be charged at the rate shown until you cancel. \
        Manage in Settings → Apple ID → Subscriptions on your device.
        """

    static func displayName(for tier: SubscriptionTier) -> String {
        switch tier {
        case .plus: return "Plus"
        }
    }
}
