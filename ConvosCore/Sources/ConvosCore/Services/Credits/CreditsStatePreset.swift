import Foundation

/// A set of canned credit + subscription states used by mocks and the debug
/// menu state picker. Lets designers and QA dogfood every UI permutation
/// without touching the backend or the App Store sandbox.
public enum CreditsStatePreset: String, CaseIterable, Identifiable, Sendable {
    case builderAmple
    case builderLow
    case builderDepleted
    case proAmple
    case trialActive
    case trialExpired
    case billingRetry
    case gracePeriod
    case noSubNoTrial

    public var id: String { rawValue }

    public var displayName: String {
        switch self {
        case .builderAmple: return "Builder — ample"
        case .builderLow: return "Builder — low"
        case .builderDepleted: return "Builder — depleted"
        case .proAmple: return "Pro — ample"
        case .trialActive: return "Trial — active"
        case .trialExpired: return "Trial — expired"
        case .billingRetry: return "Pro — billing retry"
        case .gracePeriod: return "Builder — grace period"
        case .noSubNoTrial: return "No sub / no trial"
        }
    }

    public func balance() -> CreditBalance {
        let now = Date()
        let nextRefresh = Calendar.current.date(byAdding: .day, value: 14, to: now) ?? now
        let trialEnd = Calendar.current.date(byAdding: .day, value: 4, to: now) ?? now
        let periodLabel = Self.periodLabelFormatter.string(from: now)

        switch self {
        case .builderAmple:
            return CreditBalance(
                balance: 1_400,
                monthlyGrant: 1_500,
                monthlyGrantUsed: 100,
                nextRefreshAt: nextRefresh,
                periodLabel: periodLabel
            )
        case .builderLow:
            return CreditBalance(
                balance: 180,
                monthlyGrant: 1_500,
                monthlyGrantUsed: 1_320,
                nextRefreshAt: nextRefresh,
                periodLabel: periodLabel
            )
        case .builderDepleted, .gracePeriod:
            return CreditBalance(
                balance: 0,
                monthlyGrant: 1_500,
                monthlyGrantUsed: 1_500,
                nextRefreshAt: nextRefresh,
                periodLabel: periodLabel
            )
        case .proAmple:
            return CreditBalance(
                balance: 4_500,
                monthlyGrant: 5_000,
                monthlyGrantUsed: 500,
                nextRefreshAt: nextRefresh,
                periodLabel: periodLabel
            )
        case .billingRetry:
            return CreditBalance(
                balance: 0,
                monthlyGrant: 5_000,
                monthlyGrantUsed: 5_000,
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

    public func subscription() -> Subscription? {
        let now = Date()
        let monthEnd = Calendar.current.date(byAdding: .day, value: 14, to: now) ?? now
        let trialEnd = Calendar.current.date(byAdding: .day, value: 4, to: now) ?? now
        let graceEnd = Calendar.current.date(byAdding: .day, value: 2, to: now) ?? now

        switch self {
        case .builderAmple, .builderLow, .builderDepleted:
            return Subscription(
                tier: .builder,
                period: .monthly,
                status: .active,
                productId: "app.convos.subs.builder.monthly",
                currentPeriodEnd: monthEnd,
                willRenew: true,
                isInTrial: false
            )
        case .proAmple:
            return Subscription(
                tier: .pro,
                period: .monthly,
                status: .active,
                productId: "app.convos.subs.pro.monthly",
                currentPeriodEnd: monthEnd,
                willRenew: true,
                isInTrial: false
            )
        case .trialActive:
            return Subscription(
                tier: .builder,
                period: .monthly,
                status: .trial,
                productId: "app.convos.subs.builder.monthly",
                currentPeriodEnd: trialEnd,
                willRenew: false,
                isInTrial: true
            )
        case .billingRetry:
            return Subscription(
                tier: .pro,
                period: .monthly,
                status: .billingRetry,
                productId: "app.convos.subs.pro.monthly",
                currentPeriodEnd: monthEnd,
                willRenew: false,
                isInTrial: false
            )
        case .gracePeriod:
            return Subscription(
                tier: .builder,
                period: .monthly,
                status: .grace,
                productId: "app.convos.subs.builder.monthly",
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
