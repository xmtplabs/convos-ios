import Combine
import ConvosCore
import Foundation

@MainActor @Observable
final class PaywallViewModel {
    private let subscriptionService: any SubscriptionServiceProtocol
    @ObservationIgnored private var cancellables: Set<AnyCancellable> = []
    @ObservationIgnored var onPurchaseSucceeded: (() -> Void)?

    var selectedPlan: PaywallPlan = .plus
    var selectedProduct: PaywallProduct?
    var purchasingProductId: String?
    var isShowingAlert: Bool = false
    var alertTitle: String = ""
    var alertMessage: String?
    private(set) var products: [PaywallProduct] = []
    private(set) var currentSubscription: UserSubscription?
    private(set) var isLoadingProducts: Bool = false
    @ObservationIgnored private var loadProductsTask: Task<Void, Never>?

    var isSubscribed: Bool { currentSubscription != nil }

    var isChangingPeriod: Bool {
        guard let current = currentSubscription,
              let selected = selectedProduct else { return false }
        return current.period != selected.period
    }

    var plusMonthlyProduct: PaywallProduct? {
        products.first { $0.tier == .plus && $0.period == .monthly }
    }

    var plusAnnualProduct: PaywallProduct? {
        products.first { $0.tier == .plus && $0.period == .annual }
    }

    var annualSavingsPercent: Int? {
        guard let monthly = plusMonthlyProduct,
              let annual = plusAnnualProduct else { return nil }
        let monthlyPrice: Decimal = monthly.price
        let annualPrice: Decimal = annual.price
        guard monthlyPrice > 0 else { return nil }
        let yearlyAtMonthly: Decimal = monthlyPrice * 12
        let fraction: Decimal = (yearlyAtMonthly - annualPrice) / yearlyAtMonthly * 100
        let savings: Int = NSDecimalNumber(decimal: fraction).intValue
        return savings > 0 ? savings : nil
    }

    init(subscriptionService: any SubscriptionServiceProtocol) {
        self.subscriptionService = subscriptionService
        let initial: UserSubscription? = subscriptionService.currentSubscription
        self.currentSubscription = initial
        if initial != nil {
            self.selectedPlan = .plus
        }
        subscriptionService.subscriptionPublisher
            .receive(on: DispatchQueue.main)
            .sink { [weak self] sub in
                Task { @MainActor [weak self] in
                    self?.currentSubscription = sub
                }
            }
            .store(in: &cancellables)
    }

    func selectProduct(_ product: PaywallProduct) {
        selectedProduct = product
    }

    func loadProducts() async {
        if products.isEmpty == false { return }
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
                Log.error("Paywall loaded 0 products — check StoreKit configuration in scheme OR App Store Connect product status (Missing Metadata -> Ready to Submit unblocks sandbox fetches)")
                showAlert(
                    title: "Plans unavailable",
                    message: "We couldn't load subscription plans right now. Please try again later."
                )
            } else {
                let ids: String = loaded.map(\.id).joined(separator: ", ")
                Log.info("Paywall loaded \(loaded.count) product(s): \(ids)")
                if selectedProduct == nil {
                    let preferredPeriod: SubscriptionPeriod = currentSubscription?.period ?? .monthly
                    selectedProduct = loaded.first { $0.tier == .plus && $0.period == preferredPeriod }
                        ?? loaded.first { $0.tier == .plus && $0.period == .monthly }
                }
            }
        } catch {
            Log.error("Paywall failed to load products: \(error)")
            showAlert(title: "Something went wrong", message: "Couldn't load plans. Pull to retry or try again later.")
        }
    }

    func purchase(product: PaywallProduct? = nil) async {
        guard let product = product ?? selectedProduct else { return }
        guard purchasingProductId == nil else { return }
        purchasingProductId = product.id
        defer { purchasingProductId = nil }
        do {
            try await subscriptionService.purchase(productId: product.id)
            selectedPlan = .plus
            onPurchaseSucceeded?()
        } catch SubscriptionServiceError.purchaseCancelled {
            // user cancelled
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
