import Foundation

public enum SubscriptionTier: String, Codable, Hashable, Sendable, CaseIterable {
    case builder
    case pro
}

public enum SubscriptionPeriod: String, Codable, Hashable, Sendable, CaseIterable {
    case monthly
    case annual
}

public enum SubscriptionStatus: String, Codable, Hashable, Sendable {
    case trial
    case active
    case grace
    case billingRetry
    case expired
    case revoked
}

public struct Subscription: Codable, Equatable, Hashable, Sendable {
    public let tier: SubscriptionTier
    public let period: SubscriptionPeriod
    public let status: SubscriptionStatus
    public let productId: String
    public let currentPeriodEnd: Date
    public let willRenew: Bool
    public let isInTrial: Bool

    public init(
        tier: SubscriptionTier,
        period: SubscriptionPeriod,
        status: SubscriptionStatus,
        productId: String,
        currentPeriodEnd: Date,
        willRenew: Bool,
        isInTrial: Bool
    ) {
        self.tier = tier
        self.period = period
        self.status = status
        self.productId = productId
        self.currentPeriodEnd = currentPeriodEnd
        self.willRenew = willRenew
        self.isInTrial = isInTrial
    }
}
