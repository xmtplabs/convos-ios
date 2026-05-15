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

        let result = try await product.purchase(options: [.appAccountToken(Self.appAccountToken())])

        switch result {
        case .success(let verification):
            let transaction = try verifiedTransaction(verification)
            await sendToBackendVerify(jwsRepresentation: verification.jwsRepresentation, transactionId: transaction.id)
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

    /// Stable per-install `appAccountToken` so every purchase carries the same
    /// token across launches. The backend extracts the token from the signed
    /// Apple JWS on first `/verify` and binds it to the JWT-authenticated
    /// account, so consistent reuse keeps the binding stable. Subsequent
    /// purchases on the same install resolve to the same Apple buyer record.
    private static func appAccountToken() -> UUID {
        if let stored = UserDefaults.standard.string(forKey: Constant.appAccountTokenKey),
           let uuid = UUID(uuidString: stored) {
            return uuid
        }
        let new = UUID()
        UserDefaults.standard.set(new.uuidString, forKey: Constant.appAccountTokenKey)
        return new
    }

    private enum Constant {
        static let appAccountTokenKey: String = "storeKit.appAccountToken"
    }

    public func restorePurchases() async throws {
        try await AppStore.sync()
        await refreshFromEntitlements()
    }

    private func listenForTransactionUpdates() async {
        for await result in Transaction.updates {
            guard let transaction = try? verifiedTransaction(result) else { continue }
            await sendToBackendVerify(jwsRepresentation: result.jwsRepresentation, transactionId: transaction.id)
            await refreshFromEntitlements()
            await transaction.finish()
        }
    }

    /// Best-effort relay of a verified StoreKit transaction to the backend so it
    /// can credit the account ledger. The backend extracts both the
    /// `appAccountToken` and the `originalTransactionId` from the signed JWS
    /// payload itself, authenticates the caller via JWT, and refuses cross-
    /// account binding attempts — so the iOS side only needs to pass the JWS.
    ///
    /// Failures are logged but do not fail the local purchase —
    /// `Transaction.currentEntitlements` is still authoritative for UI state.
    private func sendToBackendVerify(jwsRepresentation: String, transactionId: UInt64) async {
        do {
            _ = try await apiClient.verifySubscription(jwsRepresentation: jwsRepresentation)
        } catch {
            Log.error("Backend verify failed for transaction \(transactionId): \(error)")
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
