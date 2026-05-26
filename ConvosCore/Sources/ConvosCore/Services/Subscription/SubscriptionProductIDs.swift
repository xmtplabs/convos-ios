import Foundation

public enum SubscriptionProductIDs {
    public static let plusMonthly: String = "app.convos.subs.builder.monthly"
    public static let plusAnnual: String = "app.convos.subs.builder.annual"

    public static let all: Set<String> = [
        plusMonthly,
        plusAnnual,
    ]

    public static func tier(for productID: String) -> SubscriptionTier? {
        switch productID {
        case plusMonthly, plusAnnual: return .plus
        default: return nil
        }
    }

    public static func period(for productID: String) -> SubscriptionPeriod? {
        switch productID {
        case plusMonthly: return .monthly
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
