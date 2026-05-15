import Combine
import Foundation

public protocol SubscriptionServiceProtocol: AnyObject, Sendable {
    var subscriptionPublisher: AnyPublisher<UserSubscription?, Never> { get }
    var currentSubscription: UserSubscription? { get }

    func availableProducts() async throws -> [PaywallProduct]
    func purchase(productId: String) async throws
    func restorePurchases() async throws
}

public enum SubscriptionServiceError: Error, Equatable, Sendable {
    case productNotFound
    case purchaseCancelled
    /// Ask-to-Buy / SCA challenges. The purchase isn't failed — it's waiting
    /// for an external approval that may resolve through `Transaction.updates`.
    case purchasePending
    /// `VerificationResult.unverified` — Apple's signature check didn't pass.
    /// Distinct from a generic failure because the recovery hint is different
    /// (retry / restore / contact support).
    case purchaseUnverified
    case purchaseFailed(reason: String)
    case notImplemented
}
