import Combine
import Foundation

public final class MockSubscriptionService: SubscriptionServiceProtocol, @unchecked Sendable {
    /// Process-wide singleton — see `MockCreditsService.shared` for rationale.
    public static let shared: MockSubscriptionService = MockSubscriptionService()

    private let subscriptionSubject: CurrentValueSubject<UserSubscription?, Never>
    private let queue: DispatchQueue = DispatchQueue(label: "convos.mock-subscription-service")
    private var currentPreset: CreditsStatePreset
    /// Source of truth for what `refresh()` should re-publish. Initially seeded
    /// from the preset, but `purchase()` and `setPreset()` overwrite it so the
    /// service can survive a refresh after a mock purchase without reverting
    /// to the preset's subscription.
    private var currentSubscriptionSnapshot: UserSubscription?
    private let mockProducts: [PaywallProduct]

    public init(initialPreset: CreditsStatePreset = .plusAmple) {
        let initialSubscription: UserSubscription? = initialPreset.subscription()
        self.currentPreset = initialPreset
        self.currentSubscriptionSnapshot = initialSubscription
        self.subscriptionSubject = CurrentValueSubject(initialSubscription)
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
        queue.sync {
            currentPreset = .plusAmple
            currentSubscriptionSnapshot = updated
        }
        subscriptionSubject.send(updated)
    }

    public func restorePurchases() async throws {
        try await Task.sleep(for: .milliseconds(300))
    }

    public func refresh(force: Bool) async {
        let snapshot = queue.sync { currentSubscriptionSnapshot }
        subscriptionSubject.send(snapshot)
    }

    public func setPreset(_ preset: CreditsStatePreset) {
        let presetSubscription: UserSubscription? = preset.subscription()
        queue.sync {
            currentPreset = preset
            currentSubscriptionSnapshot = presetSubscription
        }
        subscriptionSubject.send(presetSubscription)
    }

    private static func defaultMockProducts() -> [PaywallProduct] {
        [
            PaywallProduct(
                id: SubscriptionProductIDs.plusMonthly,
                tier: .plus,
                period: .monthly,
                displayPrice: "$19.99",
                pricePerMonthDisplay: nil,
                currencyCode: "USD"
            ),
            PaywallProduct(
                id: SubscriptionProductIDs.plusAnnual,
                tier: .plus,
                period: .annual,
                displayPrice: "$214.99",
                pricePerMonthDisplay: "$17.92/mo",
                currencyCode: "USD"
            ),
        ]
    }
}
