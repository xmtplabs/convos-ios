import Foundation

public enum SubscriptionProductIDs {
    public static let builderMonthly: String = "app.convos.subs.builder.monthly"
    public static let builderAnnual: String = "app.convos.subs.builder.annual"
    public static let proMonthly: String = "app.convos.subs.pro.monthly"
    public static let proAnnual: String = "app.convos.subs.pro.annual"

    public static let all: Set<String> = [
        builderMonthly,
        builderAnnual,
        proMonthly,
        proAnnual,
    ]

    public static func tier(for productID: String) -> SubscriptionTier? {
        switch productID {
        case builderMonthly, builderAnnual: return .builder
        case proMonthly, proAnnual: return .pro
        default: return nil
        }
    }

    public static func period(for productID: String) -> SubscriptionPeriod? {
        switch productID {
        case builderMonthly, proMonthly: return .monthly
        case builderAnnual, proAnnual: return .annual
        default: return nil
        }
    }

    public static func productID(for tier: SubscriptionTier, period: SubscriptionPeriod) -> String {
        switch (tier, period) {
        case (.builder, .monthly): return builderMonthly
        case (.builder, .annual): return builderAnnual
        case (.pro, .monthly): return proMonthly
        case (.pro, .annual): return proAnnual
        }
    }
}
