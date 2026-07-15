import Combine
import Foundation

public protocol SubscriptionServiceProtocol: AnyObject, Sendable {
    var subscriptionPublisher: AnyPublisher<UserSubscription?, Never> { get }
    var currentSubscription: UserSubscription? { get }

    func availableProducts() async throws -> [PaywallProduct]
    func purchase(productId: String) async throws
    func restorePurchases() async throws

    /// Re-read subscription state. `force: false` is TTL-debounced (see the
    /// concrete service); pass `force: true` for explicit user-initiated
    /// freshness (pull-to-refresh) and post-purchase confirmation.
    func refresh(force: Bool) async

    /// True when the most recent backend verify rejected with a claimable
    /// ownership mismatch — the provider key belongs to a deleted (or
    /// transferable) account and an explicit reclaim may succeed.
    var reclaimCandidateAvailable: Bool { get }

    /// Claims the mismatched subscription into the caller's account. Only
    /// ever call from an explicit user act (Restore -> confirm); never in
    /// the background.
    func reclaimSubscription() async throws -> SubscriptionClaimOutcome

    /// Contest-window deadline of a pending live-tier claim, if one is
    /// awaiting resolution. No push comes to the claimant; the client
    /// re-verifies after this date.
    var pendingClaimContestEndsAt: Date? { get }
}

public extension SubscriptionServiceProtocol {
    func refresh() async {
        await refresh(force: false)
    }

    /// Defaults for conformers that don't participate in reclaim
    /// (previews, mocks).
    var reclaimCandidateAvailable: Bool { false }

    func reclaimSubscription() async throws -> SubscriptionClaimOutcome {
        throw SubscriptionClaimError.noCandidate
    }

    var pendingClaimContestEndsAt: Date? { nil }
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
