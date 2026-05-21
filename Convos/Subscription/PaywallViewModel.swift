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

    /// In-flight `loadProducts()` task, if any. A concurrent caller awaits this
    /// same task instead of bailing out early — otherwise a re-entrant call
    /// during the `availableProducts()` await would see `products` still empty
    /// and the caller's view would render without products even though the
    /// first fetch was about to complete.
    @ObservationIgnored private var loadProductsTask: Task<Void, Never>?

    init(subscriptionService: any SubscriptionServiceProtocol) {
        self.subscriptionService = subscriptionService
        let initial: UserSubscription? = subscriptionService.currentSubscription
        self.currentSubscription = initial
        // Default the picker to the period the user is currently subscribed to,
        // so the paywall opens on their plan (with "Current plan" visible on
        // the right card). Falls back to Monthly for non-subscribers — a
        // sensible default that keeps tier cards visible.
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
        if products.isEmpty == false { return }
        // Memoize the in-flight Task so concurrent callers await the same
        // fetch instead of returning early without products. PaywallViewModel
        // is @MainActor but actors are re-entrant at await suspension points,
        // so a Bool guard alone would let a second caller pass the
        // `products.isEmpty` check and silently exit while the first call
        // was mid-fetch.
        if let existing = loadProductsTask {
            await existing.value
            return
        }
        let task: Task<Void, Never> = Task { await performLoadProducts() }
        loadProductsTask = task
        isLoadingProducts = true
        defer {
            loadProductsTask = nil
            isLoadingProducts = false
        }
        await task.value
    }

    private func performLoadProducts() async {
        do {
            let loaded = try await subscriptionService.availableProducts()
            products = loaded
            if loaded.isEmpty {
                // StoreKit returned zero products. The cause depends on the
                // build path:
                //   - Sim with .storekit selected: file missing/misconfigured
                //   - Sim without .storekit / device on sandbox: ASC products
                //     not in a fetchable state yet (Missing Metadata → Ready
                //     to Submit / Approved unlocks fetching)
                //   - Device on prod: App Review hasn't approved the products
                // Keep the user-facing copy generic; the log line carries the
                // diagnostic detail.
                Log.error("Paywall loaded 0 products — check StoreKit configuration in scheme OR App Store Connect product status (Missing Metadata → Ready to Submit unblocks sandbox fetches)")
                showAlert(
                    title: "Plans unavailable",
                    message: "We couldn't load subscription plans right now. Please try again later."
                )
            } else {
                let ids: String = loaded.map(\.id).joined(separator: ", ")
                Log.info("Paywall loaded \(loaded.count) product(s): \(ids)")
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
            // Snap the period picker to the purchased product's period so the
            // "Current plan" badge is visible on the right card without the
            // user having to manually toggle the segmented control. Without
            // this, a Monthly -> Annual upgrade leaves the picker on Monthly
            // and the Annual card the user just bought stays hidden behind
            // the picker.
            selectedPeriod = product.period
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
