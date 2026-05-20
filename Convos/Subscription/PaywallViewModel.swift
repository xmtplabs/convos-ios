import Combine
import ConvosCore
import Foundation

@MainActor @Observable
final class PaywallViewModel {
    private let subscriptionService: any SubscriptionServiceProtocol
    @ObservationIgnored private var cancellables: Set<AnyCancellable> = []
    @ObservationIgnored var onPurchaseSucceeded: (() -> Void)?

    var selectedPeriod: SubscriptionPeriod = .monthly
    var purchasingProductId: String?
    var isShowingAlert: Bool = false
    var alertTitle: String = ""
    var alertMessage: String?
    private(set) var products: [PaywallProduct] = []
    private(set) var isLoadingProducts: Bool = false
    private(set) var currentSubscription: UserSubscription?

    init(subscriptionService: any SubscriptionServiceProtocol) {
        self.subscriptionService = subscriptionService
        let initial: UserSubscription? = subscriptionService.currentSubscription
        self.currentSubscription = initial
        // Default the picker to the period the user is currently subscribed to,
        // so the paywall opens on their plan (with "Current plan" visible on the
        // right card). Falls back to monthly for non-subscribers. Once the user
        // interacts with the picker, we don't reset it on subscription updates.
        self.selectedPeriod = initial?.period ?? .monthly
        subscriptionService.subscriptionPublisher
            .receive(on: DispatchQueue.main)
            .sink { [weak self] sub in
                Task { @MainActor [weak self] in
                    self?.currentSubscription = sub
                }
            }
            .store(in: &cancellables)
    }

    var currentTier: SubscriptionTier? {
        currentSubscription?.tier
    }

    var hasActiveSubscription: Bool {
        currentSubscription != nil
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
            let loaded = try await subscriptionService.availableProducts()
            products = loaded
            if loaded.isEmpty {
                Log.error("Paywall loaded 0 products — check the StoreKit configuration is wired in the scheme and that Convos.storekit is a member of the project")
                showAlert(
                    title: "No plans available",
                    message: "Couldn't load subscription plans. Check the StoreKit configuration."
                )
            } else {
                Log.info("Paywall loaded \(loaded.count) product(s)")
            }
        } catch {
            Log.error("Paywall failed to load products: \(error)")
            showAlert(title: "Something went wrong", message: "Couldn't load plans. Pull to retry or try again later.")
        }
    }

    func purchase(product: PaywallProduct) async {
        guard purchasingProductId == nil else { return }
        purchasingProductId = product.id
        defer { purchasingProductId = nil }
        do {
            try await subscriptionService.purchase(productId: product.id)
            onPurchaseSucceeded?()
        } catch SubscriptionServiceError.purchaseCancelled {
            // user cancelled — no-op, silently dismiss CTA spinner
        } catch SubscriptionServiceError.purchasePending {
            showAlert(
                title: "Awaiting approval",
                message: "Your subscription will activate once it's approved. You can close this and we'll let you know."
            )
        } catch SubscriptionServiceError.purchaseUnverified {
            Log.error("Paywall purchase verification failed for \(product.id)")
            showAlert(
                title: "Couldn't verify purchase",
                message: "Something didn't add up. Try again or tap Restore if you've already paid."
            )
        } catch {
            Log.error("Paywall purchase failed for \(product.id): \(error)")
            showAlert(title: "Something went wrong", message: "Purchase failed. Please try again.")
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
            showAlert(title: "Couldn't restore", message: "Restore failed. Please try again.")
        }
    }

    private func showAlert(title: String, message: String) {
        alertTitle = title
        alertMessage = message
        isShowingAlert = true
    }
}
