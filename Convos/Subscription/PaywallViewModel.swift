import ConvosCore
import Foundation

@MainActor @Observable
final class PaywallViewModel {
    private let subscriptionService: any SubscriptionServiceProtocol

    var selectedPeriod: SubscriptionPeriod = .monthly
    var purchasingProductId: String?
    var isShowingError: Bool = false
    var errorMessage: String?
    private(set) var products: [PaywallProduct] = []
    private(set) var isLoadingProducts: Bool = false

    init(subscriptionService: any SubscriptionServiceProtocol) {
        self.subscriptionService = subscriptionService
    }

    var currentTier: SubscriptionTier? {
        subscriptionService.currentSubscription?.tier
    }

    var hasActiveSubscription: Bool {
        subscriptionService.currentSubscription != nil
    }

    var legalDisclaimer: String {
        SubscriptionCopy.legalDisclaimer
    }

    func product(for tier: SubscriptionTier, period: SubscriptionPeriod) -> PaywallProduct? {
        products.first { $0.tier == tier && $0.period == period }
    }

    func loadProducts() async {
        guard products.isEmpty else { return }
        isLoadingProducts = true
        defer { isLoadingProducts = false }
        do {
            products = try await subscriptionService.availableProducts()
        } catch {
            Log.error("Paywall failed to load products: \(error)")
            errorMessage = "Couldn't load plans. Pull to retry or try again later."
            isShowingError = true
        }
    }

    func purchase(product: PaywallProduct) async {
        guard purchasingProductId == nil else { return }
        purchasingProductId = product.id
        defer { purchasingProductId = nil }
        do {
            try await subscriptionService.purchase(productId: product.id)
        } catch SubscriptionServiceError.purchaseCancelled {
            // user cancelled — no-op, silently dismiss CTA spinner
        } catch {
            Log.error("Paywall purchase failed for \(product.id): \(error)")
            errorMessage = "Purchase failed. Please try again."
            isShowingError = true
        }
    }

    func restoreTapped() {
        Task { await restore() }
    }

    private func restore() async {
        do {
            try await subscriptionService.restorePurchases()
        } catch {
            Log.error("Paywall restore failed: \(error)")
            errorMessage = "Restore failed."
            isShowingError = true
        }
    }
}
