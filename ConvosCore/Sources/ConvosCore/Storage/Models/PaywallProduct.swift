import Foundation

/// A catalog entry shown on the paywall. Decouples the UI from StoreKit's
/// `Product` so the same view can render mock products in dev/preview and real
/// products in production.
public struct PaywallProduct: Identifiable, Equatable, Hashable, Sendable {
    public let id: String
    public let tier: SubscriptionTier
    public let period: SubscriptionPeriod
    public let displayPrice: String
    public let price: Decimal
    public let pricePerMonthDisplay: String?
    public let currencyCode: String

    public init(
        id: String,
        tier: SubscriptionTier,
        period: SubscriptionPeriod,
        displayPrice: String,
        price: Decimal = 0,
        pricePerMonthDisplay: String?,
        currencyCode: String
    ) {
        self.id = id
        self.tier = tier
        self.period = period
        self.displayPrice = displayPrice
        self.price = price
        self.pricePerMonthDisplay = pricePerMonthDisplay
        self.currencyCode = currencyCode
    }
}
