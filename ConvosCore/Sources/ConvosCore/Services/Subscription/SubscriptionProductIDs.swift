import Foundation

public enum SubscriptionProductIDs {
    public static let plusMonthly: String = "app.convos.subs.builder.monthly"
    public static let plusAnnual: String = "app.convos.subs.builder.annual"

    public static let all: Set<String> = [
        plusMonthly,
        plusAnnual,
    ]

    /// Legacy product ID from the pre-Plus era. Never returned by
    /// `availableProducts()` (removed from `all`) but still recognized so
    /// any existing entitlement migrates cleanly to Plus instead of being
    /// silently dropped. Same intent as `SubscriptionTier.init(from:)`
    /// mapping the backend "pro" string to `.plus`.
    private static let legacyProMonthly: String = "app.convos.subs.pro.monthly"

    public static func tier(for productID: String) -> SubscriptionTier? {
        switch productID {
        case plusMonthly, plusAnnual, legacyProMonthly: return .plus
        default: return nil
        }
    }

    public static func period(for productID: String) -> SubscriptionPeriod? {
        switch productID {
        case plusMonthly, legacyProMonthly: return .monthly
        case plusAnnual: return .annual
        default: return nil
        }
    }

    public static func productID(for tier: SubscriptionTier, period: SubscriptionPeriod) -> String? {
        switch (tier, period) {
        case (.plus, .monthly): return plusMonthly
        case (.plus, .annual): return plusAnnual
        }
    }
}
