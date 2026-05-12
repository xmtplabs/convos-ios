import Combine
import Foundation

public protocol SubscriptionServiceProtocol: AnyObject, Sendable {
    var subscriptionPublisher: AnyPublisher<Subscription?, Never> { get }
    var currentSubscription: Subscription? { get }

    func availableProducts() async throws -> [PaywallProduct]
    func purchase(productId: String) async throws
    func restorePurchases() async throws
}

public enum SubscriptionServiceError: Error, Equatable, Sendable {
    case productNotFound
    case purchaseCancelled
    case purchaseFailed(reason: String)
    case notImplemented
}
