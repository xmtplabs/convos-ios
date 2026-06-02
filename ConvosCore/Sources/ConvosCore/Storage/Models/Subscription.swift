import Foundation

public enum SubscriptionTier: String, Codable, Hashable, Sendable, CaseIterable {
    case plus

    public init(from decoder: Decoder) throws {
        let raw = try decoder.singleValueContainer().decode(String.self)
        switch raw {
        case "plus", "builder", "pro":
            self = .plus
        default:
            throw DecodingError.dataCorruptedError(
                in: try decoder.singleValueContainer(),
                debugDescription: "Unknown subscription tier: \(raw)"
            )
        }
    }
}

public enum SubscriptionPeriod: String, Codable, Hashable, Sendable, CaseIterable {
    case monthly
    case annual
}

public enum SubscriptionStatus: String, Codable, Hashable, Sendable {
    case trial
    case active
    case grace
    // swiftlint:disable:next raw_value_for_camel_cased_codable_enum
    case billingRetry
    case expired
    case revoked
}

/// User-facing subscription state. Named `UserSubscription` (not `Subscription`)
/// to avoid a name collision with `Combine.Subscription` in any file that
/// imports both ConvosCore and Combine.
public struct UserSubscription: Codable, Equatable, Hashable, Sendable {
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
