import Foundation

/// A set of canned credit + subscription states used by mocks and the debug
/// menu state picker. Lets designers and QA dogfood every UI permutation
/// without touching the backend or the App Store sandbox.
public enum CreditsStatePreset: String, CaseIterable, Identifiable, Sendable {
    case plusAmple
    case plusLow
    case plusDepleted
    case trialActive
    case trialExpired
    case billingRetry
    case gracePeriod
    case noSubNoTrial

    public var id: String { rawValue }

    public init?(compatibleRawValue raw: String) {
        switch raw {
        case "plusAmple", "builderAmple": self = .plusAmple
        case "plusLow", "builderLow": self = .plusLow
        case "plusDepleted", "builderDepleted": self = .plusDepleted
        case "proAmple": self = .plusAmple
        default: self.init(rawValue: raw)
        }
    }

    public var displayName: String {
        switch self {
        case .plusAmple: return "Plus — ample"
        case .plusLow: return "Plus — low"
        case .plusDepleted: return "Plus — depleted"
        case .trialActive: return "Trial — active"
        case .trialExpired: return "Trial — expired"
        case .billingRetry: return "Plus — billing retry"
        case .gracePeriod: return "Plus — grace period"
        case .noSubNoTrial: return "No sub / no trial"
        }
    }

    public func balance() -> CreditBalance {
        let now = Date()
        let nextRefresh = Calendar.current.date(byAdding: .day, value: 14, to: now) ?? now
        let trialEnd = Calendar.current.date(byAdding: .day, value: 4, to: now) ?? now
        let periodLabel = Self.periodLabelFormatter.string(from: now)

        switch self {
        case .plusAmple:
            return CreditBalance(
                balance: 1_400,
                monthlyGrant: 1_500,
                monthlyGrantUsed: 100,
                nextRefreshAt: nextRefresh,
                periodLabel: periodLabel
            )
        case .plusLow:
            return CreditBalance(
                balance: 180,
                monthlyGrant: 1_500,
                monthlyGrantUsed: 1_320,
                nextRefreshAt: nextRefresh,
                periodLabel: periodLabel
            )
        case .plusDepleted, .gracePeriod:
            return CreditBalance(
                balance: 0,
                monthlyGrant: 1_500,
                monthlyGrantUsed: 1_500,
                nextRefreshAt: nextRefresh,
                periodLabel: periodLabel
            )
        case .billingRetry:
            return CreditBalance(
                balance: 0,
                monthlyGrant: 1_500,
                monthlyGrantUsed: 1_500,
                nextRefreshAt: nextRefresh,
                periodLabel: periodLabel
            )
        case .trialActive:
            return CreditBalance(
                balance: 350,
                monthlyGrant: 500,
                monthlyGrantUsed: 150,
                nextRefreshAt: trialEnd,
                periodLabel: "Trial"
            )
        case .trialExpired, .noSubNoTrial:
            return CreditBalance(
                balance: 0,
                monthlyGrant: 0,
                monthlyGrantUsed: 0,
                nextRefreshAt: now,
                periodLabel: "—"
            )
        }
    }

    public func subscription() -> UserSubscription? {
        let now = Date()
        let monthEnd = Calendar.current.date(byAdding: .day, value: 14, to: now) ?? now
        let trialEnd = Calendar.current.date(byAdding: .day, value: 4, to: now) ?? now
        let graceEnd = Calendar.current.date(byAdding: .day, value: 2, to: now) ?? now

        switch self {
        case .plusAmple, .plusLow, .plusDepleted:
            return UserSubscription(
                tier: .plus,
                period: .monthly,
                status: .active,
                productId: SubscriptionProductIDs.plusMonthly,
                currentPeriodEnd: monthEnd,
                willRenew: true,
                isInTrial: false
            )
        case .trialActive:
            return UserSubscription(
                tier: .plus,
                period: .monthly,
                status: .trial,
                productId: SubscriptionProductIDs.plusMonthly,
                currentPeriodEnd: trialEnd,
                willRenew: false,
                isInTrial: true
            )
        case .billingRetry:
            return UserSubscription(
                tier: .plus,
                period: .monthly,
                status: .billingRetry,
                productId: SubscriptionProductIDs.plusMonthly,
                currentPeriodEnd: monthEnd,
                willRenew: false,
                isInTrial: false
            )
        case .gracePeriod:
            return UserSubscription(
                tier: .plus,
                period: .monthly,
                status: .grace,
                productId: SubscriptionProductIDs.plusMonthly,
                currentPeriodEnd: graceEnd,
                willRenew: false,
                isInTrial: false
            )
        case .trialExpired, .noSubNoTrial:
            return nil
        }
    }

    private static let periodLabelFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "MMMM yyyy"
        return formatter
    }()
}
