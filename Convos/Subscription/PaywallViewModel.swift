import Combine
import ConvosCore
import ConvosMetrics
import Foundation

@MainActor @Observable
final class PaywallViewModel {
    private let subscriptionService: any SubscriptionServiceProtocol
    private let paywallSource: PaywallSource
    private let coreActions: any CoreActions
    @ObservationIgnored private var cancellables: Set<AnyCancellable> = []
    @ObservationIgnored var onPurchaseSucceeded: (() -> Void)?

    var selectedPlan: PaywallPlan = .plus
    var selectedProduct: PaywallProduct?
    var purchasingProductId: String?
    var isShowingAlert: Bool = false
    var alertTitle: String = ""
    var alertMessage: String?
    /// Restore found a subscription tied to a deleted (or transferable)
    /// prior account; asks the user to confirm the explicit reclaim.
    var isShowingReclaimPrompt: Bool = false
    private(set) var isReclaiming: Bool = false
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

    init(
        subscriptionService: any SubscriptionServiceProtocol,
        paywallSource: PaywallSource,
        coreActions: any CoreActions = NoOpCoreActions()
    ) {
        self.subscriptionService = subscriptionService
        self.paywallSource = paywallSource
        self.coreActions = coreActions
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
                    let preferredPeriod: ConvosCore.SubscriptionPeriod = currentSubscription?.period ?? .monthly
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

        let metricsTier: ConvosMetrics.SubscriptionTier = .pro
        let metricsPeriod: ConvosMetrics.SubscriptionPeriod = (product.period == .annual) ? .annual : .monthly
        let source: PaywallSource = paywallSource
        let actions: any CoreActions = coreActions
        let startTime: CFAbsoluteTime = CFAbsoluteTimeGetCurrent()
        Task {
            await actions.purchaseInitiated(
                productId: product.id,
                tier: metricsTier,
                period: metricsPeriod,
                source: source
            )
        }

        do {
            try await subscriptionService.purchase(productId: product.id)
            selectedPlan = .plus
            let durationSecs: Float = Float(CFAbsoluteTimeGetCurrent() - startTime)
            Task {
                await actions.purchaseSucceeded(
                    productId: product.id,
                    tier: metricsTier,
                    period: metricsPeriod,
                    source: source,
                    durationSecs: durationSecs
                )
            }
            onPurchaseSucceeded?()
        } catch SubscriptionServiceError.purchaseCancelled {
            Task { await actions.purchaseCancelled(productId: product.id, source: source) }
        } catch SubscriptionServiceError.purchasePending {
            Task { await actions.purchaseFailed(productId: product.id, source: source, reason: .purchasePending) }
            showAlert(
                title: "Awaiting approval",
                message: "Your subscription will activate once it's approved. You can close this and we'll let you know."
            )
        } catch SubscriptionServiceError.purchaseUnverified {
            Log.error("Paywall purchase verification failed for \(product.id)")
            Task { await actions.purchaseFailed(productId: product.id, source: source, reason: .purchaseUnverified) }
            showAlert(
                title: "Couldn't verify purchase",
                message: "Something didn't add up. Try again or tap Restore if you've already paid."
            )
        } catch SubscriptionServiceError.productNotFound {
            Log.error("Paywall purchase product not found for \(product.id)")
            Task { await actions.purchaseFailed(productId: product.id, source: source, reason: .productNotFound) }
            showAlert(title: "Something went wrong", message: "Purchase failed. Please try again.")
        } catch {
            Log.error("Paywall purchase failed for \(product.id): \(error)")
            Task { await actions.purchaseFailed(productId: product.id, source: source, reason: .unknown) }
            showAlert(title: "Something went wrong", message: "Purchase failed. Please try again.")
        }
    }

    func restoreTapped() {
        Task { await restore() }
    }

    private func restore() async {
        let actions: any CoreActions = coreActions
        do {
            try await subscriptionService.restorePurchases()
            let restoredCount: Int = (subscriptionService.currentSubscription != nil) ? 1 : 0
            Task { await actions.purchasesRestored(restoredCount: restoredCount) }
            // Restore surfaced a subscription bound to a deleted prior
            // account. Offer the one-time reclaim; the claim itself only
            // ever runs from the user's explicit confirmation.
            if subscriptionService.reclaimCandidateAvailable {
                isShowingReclaimPrompt = true
            }
        } catch {
            Log.error("Paywall restore failed: \(error)")
            showAlert(title: "Couldn't restore", message: "Restore failed. Please try again.")
        }
    }

    func reclaimConfirmed() {
        Task { await reclaim() }
    }

    private func reclaim() async {
        guard !isReclaiming else { return }
        isReclaiming = true
        defer { isReclaiming = false }
        do {
            let outcome = try await subscriptionService.reclaimSubscription()
            switch outcome {
            case .transferred:
                showAlert(
                    title: "Subscription restored",
                    message: "Your subscription is now linked to this account."
                )
            case .pending(let contestEndsAt):
                showAlert(title: "Transfer pending", message: Self.pendingCopy(contestEndsAt: contestEndsAt))
            }
        } catch let error as SubscriptionClaimError {
            let content: (title: String, message: String) = Self.reclaimErrorCopy(for: error)
            Log.error("Subscription reclaim failed: \(error)")
            showAlert(title: content.title, message: content.message)
        } catch {
            Log.error("Subscription reclaim failed: \(error)")
            showAlert(title: "Couldn't reclaim", message: "Something went wrong. Please try again.")
        }
    }

    private static func pendingCopy(contestEndsAt: Date?) -> String {
        let deadline: String
        if let contestEndsAt {
            deadline = "around \(contestEndsAt.formatted(date: .abbreviated, time: .shortened))"
        } else {
            deadline = "in a few days"
        }
        return "The transfer completes \(deadline) unless the previous account objects. Check back after that - no notification is sent."
    }

    private static func reclaimErrorCopy(for error: SubscriptionClaimError) -> (title: String, message: String) {
        switch error {
        case .noCandidate:
            return ("Nothing to reclaim", "No transferable subscription was found for this account.")
        case .invalidProof:
            return ("Couldn't verify purchase", "The App Store couldn't confirm this subscription is active. Try again, or manage it in your App Store settings.")
        case .appAttestationRequired:
            return ("Couldn't verify this device", "Device verification failed. Please try again.")
        case .notFound:
            return ("No subscription found", "The App Store purchase couldn't be matched to a subscription.")
        case .rejected(let reason):
            return reclaimRejectionCopy(for: reason)
        case .rateLimited:
            return ("Too many attempts", "Please wait a moment and try again.")
        case .serverError:
            return ("Couldn't reclaim", "Something went wrong. Please try again later.")
        }
    }

    private static func reclaimRejectionCopy(for reason: SubscriptionClaimRejectionReason) -> (title: String, message: String) {
        switch reason {
        case .notEntitled:
            return ("Subscription not active", "The App Store reports this subscription is no longer active.")
        case .cooldown:
            return ("Recently transferred", "This subscription changed accounts within the last 30 days. Please contact support.")
        case .undoConsumed, .transferFrozen:
            return ("Can't transfer automatically", "This subscription can't be reclaimed automatically anymore. Please contact support.")
        case .lineageUnresolved:
            return ("Try again later", "We couldn't resolve this purchase yet. Please try again in a little while.")
        case .pendingContest(let contestEndsAt):
            return ("Transfer already pending", pendingCopy(contestEndsAt: contestEndsAt))
        case .unknown:
            return ("Couldn't reclaim", "This subscription can't be reclaimed right now. Please contact support.")
        }
    }

    private func showAlert(title: String, message: String) {
        alertTitle = title
        alertMessage = message
        isShowingAlert = true
    }
}
