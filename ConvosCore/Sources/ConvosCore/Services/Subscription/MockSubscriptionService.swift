import Combine
import Foundation

public final class MockSubscriptionService: SubscriptionServiceProtocol, @unchecked Sendable {
    /// Process-wide singleton — see `MockCreditsService.shared` for rationale.
    public static let shared: MockSubscriptionService = MockSubscriptionService()

    private let subscriptionSubject: CurrentValueSubject<UserSubscription?, Never>
    private let queue: DispatchQueue = DispatchQueue(label: "convos.mock-subscription-service")
    private var currentPreset: CreditsStatePreset
    private let mockProducts: [PaywallProduct]

    public init(initialPreset: CreditsStatePreset = .builderAmple) {
        self.currentPreset = initialPreset
        self.subscriptionSubject = CurrentValueSubject(initialPreset.subscription())
        self.mockProducts = Self.defaultMockProducts()
    }

    public var subscriptionPublisher: AnyPublisher<UserSubscription?, Never> {
        subscriptionSubject.eraseToAnyPublisher()
    }

    public var currentSubscription: UserSubscription? {
        subscriptionSubject.value
    }

    public func availableProducts() async throws -> [PaywallProduct] {
        try await Task.sleep(for: .milliseconds(150))
        return mockProducts
    }

    public func purchase(productId: String) async throws {
        guard let product = mockProducts.first(where: { $0.id == productId }) else {
            throw SubscriptionServiceError.productNotFound
        }
        try await Task.sleep(for: .milliseconds(600))
        let now = Date()
        let component: Calendar.Component = product.period == .monthly ? .month : .year
        let nextRenew = Calendar.current.date(byAdding: component, value: 1, to: now) ?? now
        let updated = UserSubscription(
            tier: product.tier,
            period: product.period,
            status: .active,
            productId: product.id,
            currentPeriodEnd: nextRenew,
            willRenew: true,
            isInTrial: false
        )
        subscriptionSubject.send(updated)
    }

    public func restorePurchases() async throws {
        try await Task.sleep(for: .milliseconds(300))
    }

    public func setPreset(_ preset: CreditsStatePreset) {
        queue.sync { currentPreset = preset }
        subscriptionSubject.send(preset.subscription())
    }

    private static func defaultMockProducts() -> [PaywallProduct] {
        [
            PaywallProduct(
                id: SubscriptionProductIDs.builderMonthly,
                tier: .builder,
                period: .monthly,
                displayPrice: "$9.99",
                pricePerMonthDisplay: nil,
                currencyCode: "USD"
            ),
            PaywallProduct(
                id: SubscriptionProductIDs.builderAnnual,
                tier: .builder,
                period: .annual,
                displayPrice: "$79.99",
                pricePerMonthDisplay: "$6.67/mo",
                currencyCode: "USD"
            ),
            PaywallProduct(
                id: SubscriptionProductIDs.proMonthly,
                tier: .pro,
                period: .monthly,
                displayPrice: "$29.99",
                pricePerMonthDisplay: nil,
                currencyCode: "USD"
            ),
            PaywallProduct(
                id: SubscriptionProductIDs.proAnnual,
                tier: .pro,
                period: .annual,
                displayPrice: "$239.99",
                pricePerMonthDisplay: "$20.00/mo",
                currencyCode: "USD"
            ),
        ]
    }
}
