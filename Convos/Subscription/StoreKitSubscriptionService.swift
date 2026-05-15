import Combine
import ConvosCore
import Foundation
import StoreKit

public final class StoreKitSubscriptionService: SubscriptionServiceProtocol, @unchecked Sendable {
    public static let shared: StoreKitSubscriptionService = StoreKitSubscriptionService(
        apiClient: ConvosAPIClientFactory.client(environment: ConfigManager.shared.currentEnvironment)
    )

    private let apiClient: any ConvosAPIClientProtocol
    private let subscriptionSubject: CurrentValueSubject<UserSubscription?, Never>
    private var updateListenerTask: Task<Void, Never>?

    public init(apiClient: any ConvosAPIClientProtocol) {
        self.apiClient = apiClient
        self.subscriptionSubject = CurrentValueSubject(nil)
        let listenerTask = Task.detached { [weak self] in
            guard let self else { return }
            await self.refreshFromEntitlements()
            await self.listenForTransactionUpdates()
        }
        self.updateListenerTask = listenerTask
    }

    deinit {
        updateListenerTask?.cancel()
    }

    public var subscriptionPublisher: AnyPublisher<UserSubscription?, Never> {
        subscriptionSubject.eraseToAnyPublisher()
    }

    public var currentSubscription: UserSubscription? {
        subscriptionSubject.value
    }

    public func availableProducts() async throws -> [PaywallProduct] {
        let storeProducts = try await Product.products(for: SubscriptionProductIDs.all)
        return storeProducts.compactMap { paywallProduct(from: $0) }
            .sorted { lhs, rhs in lhs.id < rhs.id }
    }

    public func purchase(productId: String) async throws {
        let products = try await Product.products(for: [productId])
        guard let product = products.first else {
            throw SubscriptionServiceError.productNotFound
        }

        let appAccountToken = UUID()
        let result = try await product.purchase(options: [.appAccountToken(appAccountToken)])

        switch result {
        case .success(let verification):
            let transaction = try verifiedTransaction(verification)
            await sendToBackendVerify(
                jwsRepresentation: verification.jwsRepresentation,
                transaction: transaction,
                fallbackToken: appAccountToken
            )
            await refreshFromEntitlements()
            await transaction.finish()
        case .userCancelled:
            throw SubscriptionServiceError.purchaseCancelled
        case .pending:
            throw SubscriptionServiceError.purchasePending
        @unknown default:
            throw SubscriptionServiceError.purchaseFailed(reason: "Unknown purchase result")
        }
    }

    public func restorePurchases() async throws {
        try await AppStore.sync()
        await refreshFromEntitlements()
    }

    private func listenForTransactionUpdates() async {
        for await result in Transaction.updates {
            guard let transaction = try? verifiedTransaction(result) else { continue }
            await sendToBackendVerify(
                jwsRepresentation: result.jwsRepresentation,
                transaction: transaction,
                fallbackToken: nil
            )
            await refreshFromEntitlements()
            await transaction.finish()
        }
    }

    /// Best-effort relay of a verified StoreKit transaction to the backend so it
    /// can credit the account ledger. Failures are logged but do not fail the
    /// local purchase — `Transaction.currentEntitlements` is still authoritative
    /// for UI state.
    ///
    /// `fallbackToken` is the UUID we passed to `product.purchase()` on the
    /// initial purchase. On a renewal transaction from `Transaction.updates`,
    /// Apple replays the original `appAccountToken` carried by the transaction;
    /// `fallbackToken` is nil in that path because we don't generate a new one.
    private func sendToBackendVerify(
        jwsRepresentation: String,
        transaction: Transaction,
        fallbackToken: UUID?
    ) async {
        let token: UUID? = transaction.appAccountToken ?? fallbackToken
        guard let token else {
            Log.warning("StoreKit verify skipped: no appAccountToken on transaction \(transaction.id)")
            return
        }
        do {
            _ = try await apiClient.verifySubscription(
                jwsRepresentation: jwsRepresentation,
                appAccountToken: token.uuidString
            )
        } catch {
            Log.error("Backend verify failed for transaction \(transaction.id): \(error)")
        }
    }

    private func refreshFromEntitlements() async {
        var latest: UserSubscription?
        for await result in Transaction.currentEntitlements {
            guard let transaction = try? verifiedTransaction(result) else { continue }
            guard let sub = userSubscription(from: transaction) else { continue }
            latest = sub
        }
        subscriptionSubject.send(latest)
    }

    private func verifiedTransaction<T>(_ result: VerificationResult<T>) throws -> T {
        switch result {
        case .verified(let safe):
            return safe
        case .unverified:
            throw SubscriptionServiceError.purchaseUnverified
        }
    }

    private func paywallProduct(from product: Product) -> PaywallProduct? {
        guard let tier = SubscriptionProductIDs.tier(for: product.id),
              let period = SubscriptionProductIDs.period(for: product.id) else {
            return nil
        }
        let currencyCode: String = product.priceFormatStyle.currencyCode
        let perMonthDisplay: String? = (period == .annual) ? perMonthString(for: product) : nil
        return PaywallProduct(
            id: product.id,
            tier: tier,
            period: period,
            displayPrice: product.displayPrice,
            pricePerMonthDisplay: perMonthDisplay,
            currencyCode: currencyCode
        )
    }

    private func userSubscription(from transaction: Transaction) -> UserSubscription? {
        guard let tier = SubscriptionProductIDs.tier(for: transaction.productID),
              let period = SubscriptionProductIDs.period(for: transaction.productID) else {
            return nil
        }
        let status: ConvosCore.SubscriptionStatus = subscriptionStatus(from: transaction)
        let willRenew: Bool = transaction.revocationDate == nil
        let isInTrial: Bool = transaction.offer?.type == .introductory
        return UserSubscription(
            tier: tier,
            period: period,
            status: status,
            productId: transaction.productID,
            currentPeriodEnd: transaction.expirationDate ?? Date(),
            willRenew: willRenew,
            isInTrial: isInTrial
        )
    }

    private func subscriptionStatus(from transaction: Transaction) -> ConvosCore.SubscriptionStatus {
        if transaction.revocationDate != nil { return .revoked }
        if let expiration = transaction.expirationDate, expiration < Date() {
            return .expired
        }
        return transaction.offer?.type == .introductory ? .trial : .active
    }

    private func perMonthString(for product: Product) -> String? {
        let monthly: Decimal = product.price / 12
        let formatted: String = monthly.formatted(product.priceFormatStyle)
        return "\(formatted)/mo"
    }
}
