import Combine
import ConvosCore
import Foundation
import os
import StoreKit

public actor StoreKitSubscriptionService: SubscriptionServiceProtocol {
    nonisolated public static let shared: StoreKitSubscriptionService = StoreKitSubscriptionService(
        apiClient: ConvosAPIClientFactory.client(environment: ConfigManager.shared.currentEnvironment)
    )

    /// TTL for `refresh(force: false)`. `Transaction.currentEntitlements` is
    /// cheap but not free; debouncing collapses bursts when the user
    /// navigates between subscription-displaying surfaces.
    private static let refreshTTL: TimeInterval = 15

    private let apiClient: any ConvosAPIClientProtocol
    /// `CurrentValueSubject` is internally synchronized but not declared
    /// `Sendable`. `nonisolated(unsafe)` lets the actor expose the
    /// publisher + current value synchronously without bridging through
    /// `@preconcurrency import Combine`.
    nonisolated(unsafe) private let subscriptionSubject: CurrentValueSubject<UserSubscription?, Never>
    /// Set once during init, cancelled in deinit. `nonisolated(unsafe)`
    /// keeps deinit able to reach it under Swift 6 actor-deinit isolation
    /// rules; no concurrent mutation happens past init.
    nonisolated(unsafe) private var updateListenerTask: Task<Void, Never>?
    private var lastFetchedAt: Date?
    /// Transaction IDs we've already forwarded to `POST /subscription/verify`
    /// in this process. See `refreshFromEntitlements()` for why per-launch
    /// forwarding (not persisted) is the right granularity.
    private var forwardedTransactionIds: Set<UInt64> = []
    /// Entitlement whose verify most recently rejected with a claimable
    /// ownership mismatch (the provider key belongs to a deleted or
    /// transferable account). Carries the subscription lineage ID
    /// (`Transaction.originalID`) alongside the JWS so verify outcomes for
    /// unrelated entitlements can't wipe it, while any transaction in the
    /// same lineage (renewals included) can. Lock-backed so the protocol's
    /// synchronous `reclaimCandidateAvailable` can read it without an
    /// actor hop.
    private nonisolated let claimCandidate: OSAllocatedUnfairLock<ClaimCandidate?> = .init(initialState: nil)
    /// Timer that re-verifies once a pending claim's contest window ends
    /// (no push comes to the claimant). Rescheduled on every pending
    /// outcome and on launch when a persisted marker is still in the
    /// future; cancelled in deinit.
    nonisolated(unsafe) private var pendingClaimReverifyTask: Task<Void, Never>?

    public init(apiClient: any ConvosAPIClientProtocol) {
        self.apiClient = apiClient
        // Seed the subject with the last persisted snapshot so the first
        // UI render after launch shows the user's actual tier (the common
        // case) instead of flashing "Basic" for the few hundred ms it
        // takes `refreshFromEntitlements()` to round-trip Apple +
        // backend. `BackendCreditsService` already has this behavior for
        // credits via its GRDB-backed read; subscriptions had no
        // equivalent cache, which is why the HOME pill flickered Basic →
        // Plus at every cold start. The cache is corrected by every
        // subsequent publish (refresh / purchase / Apple update).
        self.subscriptionSubject = CurrentValueSubject(Self.loadCachedSubscription())
        let listenerTask = Task.detached { [weak self] in
            guard let self else { return }
            // A pending-claim marker whose window already ended reconciles
            // through this first refresh; one still in the future re-arms
            // the re-verify timer.
            await self.reconcileExpiredPendingClaim()
            await self.schedulePendingClaimReverifyIfNeeded()
            await self.refreshFromEntitlements()
            await self.listenForTransactionUpdates()
        }
        self.updateListenerTask = listenerTask
    }

    deinit {
        updateListenerTask?.cancel()
        pendingClaimReverifyTask?.cancel()
    }

    /// Single funnel for every subscription-state publish. Sends on the
    /// in-memory subject (drives `subscriptionPublisher` / UI bindings)
    /// AND writes through to UserDefaults so the next cold start can
    /// seed the subject without flickering through nil. Use everywhere
    /// instead of touching `subscriptionSubject` directly.
    private func publish(_ subscription: UserSubscription?) {
        subscriptionSubject.send(subscription)
        Self.saveCachedSubscription(subscription)
    }

    nonisolated public var subscriptionPublisher: AnyPublisher<UserSubscription?, Never> {
        subscriptionSubject.eraseToAnyPublisher()
    }

    nonisolated public var currentSubscription: UserSubscription? {
        subscriptionSubject.value
    }

    public func availableProducts() async throws -> [PaywallProduct] {
        let storeProducts = try await Product.products(for: SubscriptionProductIDs.all)
        await logStorefrontDiagnostics(for: storeProducts)
        return storeProducts.compactMap { paywallProduct(from: $0) }
            .sorted { lhs, rhs in lhs.id < rhs.id }
    }

    /// Diagnostic logging for the "paywall shows USD on a EUR account" class of
    /// bug. In StoreKit 2, `Product.displayPrice` and
    /// `priceFormatStyle.currencyCode` are pure renders of whatever storefront
    /// StoreKit currently resolves for the App Store account in
    /// Settings ▸ [name] ▸ Media & Purchases — they ignore device region and
    /// the iCloud account. So when the wrong currency shows, the answer is
    /// always "what storefront did StoreKit hand us?", which only
    /// `Storefront.current` can tell us. We log it alongside each product's
    /// currency so a TestFlight/prod log capture settles whether the cause is a
    /// US storefront (wrong/stale Media & Purchases account) vs. anything in our
    /// own formatting (it isn't — we pass StoreKit's values straight through).
    private func logStorefrontDiagnostics(for products: [Product]) async {
        if let storefront = await Storefront.current {
            Log.info("StoreKit storefront: \(storefront.countryCode) (id=\(storefront.id))")
        } else {
            Log.info("StoreKit storefront: nil — no App Store account signed in, or not yet loaded")
        }
        for product in products {
            Log.info(
                "StoreKit product \(product.id): displayPrice=\(product.displayPrice) " +
                "currency=\(product.priceFormatStyle.currencyCode) price=\(product.price)"
            )
        }
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
            await sendToBackendVerify(jwsRepresentation: verification.jwsRepresentation, transaction: transaction)
            // The verified transaction from `.success` IS the authoritative
            // new entitlement. Publish it directly and skip the
            // `refreshFromEntitlements()` reconciliation that used to follow.
            // Apple's local `Transaction.currentEntitlements` cache lags by
            // seconds after a successful purchase, and for an upgrade
            // (e.g. Monthly -> Annual) the cache still holds the
            // just-superseded old entitlement. Iterating it would emit the
            // stale tier and overwrite the fresh one we just published —
            // surfacing as a brief "Current plan" flash on the new tier card
            // before reverting to the old. `Transaction.updates` (the listener
            // in `listenForTransactionUpdates()`) re-emits when Apple's view
            // catches up; periodic foreground `refresh()` calls reconcile
            // beyond that.
            if let sub = await userSubscription(from: transaction) {
                publish(sub)
            }
            // Force a credits refresh: the tier just changed (or was set for
            // the first time), so `monthlyGrant` derived from
            // PAYMENTS_GRANT_<TIER>_MONTHLY changed too. Skip the TTL so
            // the HOME pill + paywall reflect the new bucket immediately.
            await CreditsServices.shared.refresh(force: true)
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

    public func restorePurchases() async throws {
        try await AppStore.sync()
        await refreshFromEntitlements()
    }

    private func listenForTransactionUpdates() async {
        for await result in Transaction.updates {
            guard let transaction = try? verifiedTransaction(result) else { continue }
            await sendToBackendVerify(jwsRepresentation: result.jwsRepresentation, transaction: transaction)
            // Publish from the verified transaction directly, for the same
            // reason as in `purchase()`: re-querying
            // `Transaction.currentEntitlements` here races with Apple's
            // local cache update for plan changes initiated through the
            // system "Manage Subscriptions" sheet. The cache may still hold
            // the just-superseded entitlement when the listener fires,
            // overwriting the new one. The verified transaction in hand
            // is authoritative for this update — including refunds /
            // revocations, where `userSubscription(from:)` returns a
            // non-nil snapshot with status `.revoked` or `.expired`.
            if let sub = await userSubscription(from: transaction) {
                publish(sub)
            }
            // Apple-side transition (renew, refund, tier change) → tier or
            // status may have changed → credits need to re-derive from the
            // new Subscription row. Force-refresh to bypass TTL.
            await CreditsServices.shared.refresh(force: true)
            await transaction.finish()
        }
    }

    /// Best-effort relay of a verified StoreKit transaction to the backend so it
    /// can credit the account ledger. The backend extracts both the
    /// `appAccountToken` and the `originalTransactionId` from the signed JWS
    /// payload itself, authenticates the caller via JWT, and refuses cross-
    /// account binding attempts — so the iOS side only needs to pass the JWS.
    ///
    /// Returns `true` on success so callers that track forwarded transactions
    /// (`refreshFromEntitlements`) can retry on the next refresh after a
    /// transient failure instead of waiting for an app relaunch. Failures
    /// are logged but never propagate — `Transaction.currentEntitlements`
    /// is still authoritative for local UI state.
    @discardableResult
    private func sendToBackendVerify(jwsRepresentation: String, transaction: Transaction) async -> Bool {
        let transactionId: UInt64 = transaction.id
        let lineageId: UInt64 = transaction.originalID
        do {
            _ = try await apiClient.verifySubscription(jwsRepresentation: jwsRepresentation)
            // Clear only a candidate from this same subscription lineage:
            // `refreshFromEntitlements()` verifies every entitlement in
            // sequence, and a later entitlement's success must not wipe a
            // claimable candidate captured for an earlier one. Matching on
            // `originalID` rather than `id` lets a renewal (new transaction
            // ID, same lineage) clear its own lineage's stale candidate.
            claimCandidate.withLock { candidate in
                if candidate?.originalTransactionId == lineageId {
                    candidate = nil
                }
            }
            return true
        } catch APIError.conflict(let details) where details.code == BackendErrorCode.subscriptionAccountMismatch {
            // Ownership mismatch. When the backend signals the claim may
            // succeed for this caller (deleted prior owner, no cooldown
            // block), remember the proof so an explicit Restore act can
            // offer the reclaim. Informative only - the claim endpoint
            // re-evaluates authoritatively.
            let claimable = details.claimable == true
            claimCandidate.withLock { candidate in
                if claimable {
                    candidate = ClaimCandidate(jws: jwsRepresentation, originalTransactionId: lineageId)
                } else if candidate?.originalTransactionId == lineageId {
                    candidate = nil
                }
            }
            Log.warning("Backend verify 409 subscription_account_mismatch for transaction \(transactionId) (claimable: \(claimable))")
            return false
        } catch {
            Log.error("Backend verify failed for transaction \(transactionId): \(error)")
            return false
        }
    }

    // MARK: - Reclaim (explicit user act)

    nonisolated public var reclaimCandidateAvailable: Bool {
        claimCandidate.withLock { $0 != nil }
    }

    nonisolated public var pendingClaimContestEndsAt: Date? {
        UserDefaults.standard.object(forKey: Constant.pendingClaimContestEndsAtKey) as? Date
    }

    public func reclaimSubscription() async throws -> SubscriptionClaimOutcome {
        guard let jws = claimCandidate.withLock({ $0?.jws }) else {
            throw SubscriptionClaimError.noCandidate
        }
        // Fresh limited-use attestation per attempt: the server consumes
        // it, so a retried claim must never reuse a token.
        let appCheckToken = try await FirebaseHelperCore.getLimitedUseAppCheckToken()
        do {
            let outcome = try await apiClient.claimSubscription(jwsRepresentation: jws, appCheckToken: appCheckToken)
            clearClaimCandidate(ifStillSubmitted: jws)
            switch outcome {
            case .transferred(let subscription):
                UserDefaults.standard.removeObject(forKey: Constant.pendingClaimContestEndsAtKey)
                publish(subscription)
                await CreditsServices.shared.refresh(force: true)
            case .pending(let contestEndsAt):
                if let contestEndsAt {
                    UserDefaults.standard.set(contestEndsAt, forKey: Constant.pendingClaimContestEndsAtKey)
                    scheduleClaimReverify(at: contestEndsAt)
                }
            }
            return outcome
        } catch SubscriptionClaimError.rejected(.pendingContest(let contestEndsAt)) {
            if let contestEndsAt {
                UserDefaults.standard.set(contestEndsAt, forKey: Constant.pendingClaimContestEndsAtKey)
                scheduleClaimReverify(at: contestEndsAt)
            }
            throw SubscriptionClaimError.rejected(.pendingContest(contestEndsAt: contestEndsAt))
        } catch let error as SubscriptionClaimError where Self.isTerminalClaimRejection(error) {
            // Definitive backend rejection: this candidate can never
            // succeed as-is, so drop it instead of re-offering a reclaim
            // that will keep failing. If the entitlement is still claimable
            // later, the verify path's 409 re-installs a fresh candidate.
            // Transient failures (network, 5xx, rate limit, attestation
            // retry) fall through and keep the candidate for retry.
            clearClaimCandidate(ifStillSubmitted: jws)
            throw error
        }
    }

    /// Clears the candidate only if it is still the proof this reclaim
    /// submitted. The claim round-trip suspends the actor, so `purchase()`
    /// or `Transaction.updates` can install a newer candidate mid-flight;
    /// an outcome for the old proof must not wipe that newer one.
    private func clearClaimCandidate(ifStillSubmitted jws: String) {
        claimCandidate.withLock { candidate in
            guard candidate?.jws == jws else { return }
            candidate = nil
        }
    }

    /// Claim errors that the backend decided authoritatively against this
    /// proof, as opposed to failures worth retrying with the same
    /// candidate. `.pendingContest` is excluded because it has its own
    /// contest-window handling; `.unknown` and `.lineageUnresolved` are
    /// excluded as potentially retryable.
    private static func isTerminalClaimRejection(_ error: SubscriptionClaimError) -> Bool {
        switch error {
        case .invalidProof, .notFound:
            return true
        case .rejected(let reason):
            switch reason {
            case .notEntitled, .cooldown, .undoConsumed, .transferFrozen:
                return true
            case .lineageUnresolved, .pendingContest, .unknown:
                return false
            }
        case .noCandidate, .appAttestationRequired, .rateLimited, .serverError:
            return false
        }
    }

    /// Clears an expired pending-claim marker so the normal verify path
    /// reconciles the outcome (no push comes to the claimant).
    private func reconcileExpiredPendingClaim() {
        guard let deadline = pendingClaimContestEndsAt, deadline <= Date() else { return }
        UserDefaults.standard.removeObject(forKey: Constant.pendingClaimContestEndsAtKey)
        // Force re-forwarding of entitlements so verify reflects the
        // transfer outcome.
        forwardedTransactionIds.removeAll()
    }

    /// Launch-time half of the contest-window contract: a persisted marker
    /// still in the future re-arms the re-verify timer (the process that
    /// created it is usually gone by the time the window ends).
    private func schedulePendingClaimReverifyIfNeeded() {
        guard let deadline = pendingClaimContestEndsAt, deadline > Date() else { return }
        scheduleClaimReverify(at: deadline)
    }

    private func scheduleClaimReverify(at deadline: Date) {
        pendingClaimReverifyTask?.cancel()
        let interval: TimeInterval = deadline.timeIntervalSinceNow + Constant.claimReverifyGrace
        guard interval > 0 else { return }
        pendingClaimReverifyTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(interval * 1_000_000_000))
            guard let self, !Task.isCancelled else { return }
            await self.refresh(force: true)
        }
    }

    public func refresh(force: Bool) async {
        if !force, let last = lastFetchedAt,
           Date().timeIntervalSince(last) < Self.refreshTTL {
            return
        }
        reconcileExpiredPendingClaim()
        await refreshFromEntitlements()
        lastFetchedAt = Date()
    }

    private func refreshFromEntitlements() async {
        var latest: UserSubscription?
        var forwardedAnyEntitlement: Bool = false
        var seenLineageIds: Set<UInt64> = []
        for await result in Transaction.currentEntitlements {
            guard let transaction = try? verifiedTransaction(result) else { continue }
            seenLineageIds.insert(transaction.originalID)
            // Forward each entitlement to the backend at most once per
            // process. Covers entitlements iOS reads locally that the
            // backend doesn't know about yet:
            //   - App Store install carried over into TestFlight (different
            //     backend than the original purchase landed against).
            //   - `restorePurchases()`.
            //   - Family Sharing / parental purchase flows.
            //   - Fresh install signing in to an account that bought Plus
            //     elsewhere.
            //   - Any past purchase whose verify roundtrip lost the race
            //     with a network blip or backend error.
            // The verify endpoint is idempotent on `originalTransactionId`,
            // so the server already deduplicates; the in-memory set just
            // avoids hammering it every refresh (TTL is 15s).
            if !forwardedTransactionIds.contains(transaction.id) {
                let succeeded = await sendToBackendVerify(
                    jwsRepresentation: result.jwsRepresentation,
                    transaction: transaction
                )
                // Only mark forwarded on success so a transient failure
                // (network blip, transient 5xx, backend deploy in flight)
                // retries on the next refresh tick rather than waiting for
                // an app relaunch.
                if succeeded {
                    forwardedTransactionIds.insert(transaction.id)
                    forwardedAnyEntitlement = true
                }
            }
            guard let sub = await userSubscription(from: transaction) else { continue }
            latest = sub
        }
        // A candidate whose lineage no longer appears in
        // `currentEntitlements` (expired, refunded, revoked) is never
        // verified again, so it can't clear itself through the 409 path;
        // drop it here so the reclaim affordance doesn't outlive the
        // entitlement. A candidate captured moments ago from `purchase()` /
        // `Transaction.updates` can be wiped by Apple's cache lag, but the
        // still-unforwarded transaction re-verifies on the next refresh and
        // re-installs it.
        let observedLineageIds: Set<UInt64> = seenLineageIds
        claimCandidate.withLock { candidate in
            guard let current = candidate, !observedLineageIds.contains(current.originalTransactionId) else { return }
            candidate = nil
        }
        publish(latest)
        // If the backend just learned about an entitlement it didn't
        // previously have, its `GET /credits` answer changes (tier-based
        // grant kicks in). Force-refresh credits so the local depleted
        // state flips without waiting for the next TTL window or pull-to-
        // refresh. Without this, App Store -> TestFlight users see Plus
        // in the UI but agents stuck in "No Power" until they manually
        // refresh.
        if forwardedAnyEntitlement {
            await CreditsServices.shared.refresh(force: true)
        }
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
            price: product.price,
            pricePerMonthDisplay: perMonthDisplay,
            currencyCode: currencyCode
        )
    }

    private func userSubscription(from transaction: Transaction) async -> UserSubscription? {
        guard let tier = SubscriptionProductIDs.tier(for: transaction.productID),
              let period = SubscriptionProductIDs.period(for: transaction.productID) else {
            return nil
        }
        let snapshot: StoreKitSubscriptionSnapshot = await storeKitSubscriptionSnapshot(for: transaction)
        let isInTrial: Bool = transaction.offer?.type == .introductory
        return UserSubscription(
            tier: tier,
            period: period,
            status: snapshot.status,
            productId: transaction.productID,
            currentPeriodEnd: transaction.expirationDate ?? Date(),
            willRenew: snapshot.willRenew,
            isInTrial: isInTrial
        )
    }

    /// Combines what we can derive from the Transaction alone with what only
    /// StoreKit's subscription-status APIs can tell us:
    ///
    ///   - `RenewalInfo.willAutoRenew` is the only reliable signal for "did
    ///     the user cancel auto-renewal?". `Transaction.revocationDate` is
    ///     unrelated — it only fires on a refund / Family Sharing revoke.
    ///   - `Product.SubscriptionInfo.RenewalState` distinguishes
    ///     in-grace-period and in-billing-retry from plain active, neither
    ///     of which the bare Transaction surfaces.
    ///
    /// Falls back to the transaction-only derivation if the status lookup
    /// fails (network hiccup, product gone from ASC, verified transaction
    /// without a matching status row).
    private func storeKitSubscriptionSnapshot(for transaction: Transaction) async -> StoreKitSubscriptionSnapshot {
        let fallback: StoreKitSubscriptionSnapshot = StoreKitSubscriptionSnapshot(
            status: subscriptionStatus(from: transaction),
            // Conservative fallback: at purchase time auto-renew is on by
            // default. If the user cancelled since and we can't read the
            // renewal info, we'll be wrong until the next successful status
            // read — preferable to silently flipping non-renewing users to
            // "Expires" while their plan is still active.
            willRenew: transaction.revocationDate == nil
        )

        do {
            let products = try await Product.products(for: [transaction.productID])
            guard let subscription = products.first?.subscription else {
                return fallback
            }
            let statuses: [Product.SubscriptionInfo.Status] = try await subscription.status
            guard let status = statuses.first(where: { status in
                guard let statusTransaction = try? verifiedTransaction(status.transaction) else { return false }
                return statusTransaction.originalID == transaction.originalID
            }) else {
                return fallback
            }
            let renewalInfo: Product.SubscriptionInfo.RenewalInfo = try verifiedTransaction(status.renewalInfo)
            return StoreKitSubscriptionSnapshot(
                status: subscriptionStatus(from: status.state, transaction: transaction),
                willRenew: renewalInfo.willAutoRenew
            )
        } catch {
            Log.error("Failed reading StoreKit renewal info for \(transaction.productID): \(error)")
            return fallback
        }
    }

    private func subscriptionStatus(from transaction: Transaction) -> ConvosCore.SubscriptionStatus {
        if transaction.revocationDate != nil { return .revoked }
        if let expiration = transaction.expirationDate, expiration < Date() {
            return .expired
        }
        return transaction.offer?.type == .introductory ? .trial : .active
    }

    /// Maps StoreKit's authoritative `RenewalState` onto our local
    /// `SubscriptionStatus`. Preferred over the Transaction-only derivation
    /// because it surfaces grace-period and billing-retry states.
    private func subscriptionStatus(
        from renewalState: Product.SubscriptionInfo.RenewalState,
        transaction: Transaction
    ) -> ConvosCore.SubscriptionStatus {
        switch renewalState {
        case .subscribed:
            return transaction.offer?.type == .introductory ? .trial : .active
        case .inGracePeriod:
            return .grace
        case .inBillingRetryPeriod:
            return .billingRetry
        case .expired:
            return .expired
        case .revoked:
            return .revoked
        default:
            return subscriptionStatus(from: transaction)
        }
    }

    private func perMonthString(for product: Product) -> String? {
        let monthly: Decimal = product.price / 12
        let formatted: String = monthly.formatted(product.priceFormatStyle)
        return "\(formatted)/mo"
    }

    private struct StoreKitSubscriptionSnapshot {
        let status: ConvosCore.SubscriptionStatus
        let willRenew: Bool
    }

    private struct ClaimCandidate: Sendable {
        let jws: String
        let originalTransactionId: UInt64
    }

    private enum Constant {
        static let appAccountTokenKey: String = "storeKit.appAccountToken"
        static let lastKnownSubscriptionKey: String = "storeKit.lastKnownSubscription"
        static let pendingClaimContestEndsAtKey: String = "storeKit.pendingClaimContestEndsAt"
        /// Slack past `contestEndsAt` before re-verifying, so the backend's
        /// window-end transfer job has run.
        static let claimReverifyGrace: TimeInterval = 60
    }

    /// Account-deletion wipe step: removes every StoreKit binding tying
    /// this install to the deleted account. The `appAccountToken` in
    /// particular is bound to the deleted account's Apple buyer record;
    /// a later account on this install must mint a fresh one. Also resets
    /// the singleton's in-memory state (published subscription, reclaim
    /// candidate, forwarded-transaction memo) so a newly provisioned
    /// identity in the same process doesn't inherit account-scoped
    /// subscription or reclaim state.
    public func wipeAccountScopedState() async {
        let defaults = UserDefaults.standard
        defaults.removeObject(forKey: Constant.appAccountTokenKey)
        defaults.removeObject(forKey: Constant.lastKnownSubscriptionKey)
        defaults.removeObject(forKey: Constant.pendingClaimContestEndsAtKey)
        // The re-verify timer is bound to the deleted account's contest
        // window; left alive it would wake under whatever identity is
        // provisioned next and refresh subscription state in that session.
        pendingClaimReverifyTask?.cancel()
        pendingClaimReverifyTask = nil
        claimCandidate.withLock { $0 = nil }
        forwardedTransactionIds.removeAll()
        lastFetchedAt = nil
        publish(nil)
    }

    /// Persist the most recently published subscription snapshot so the next
    /// app launch can seed its initial UI state without waiting for the
    /// async `refreshFromEntitlements()` round-trip. Cleared (set to nil)
    /// when the user no longer has an entitlement so the cached "Plus"
    /// doesn't outlive the actual subscription.
    ///
    /// `internal` rather than `private` so unit tests can exercise the
    /// cache round-trip directly without driving a full StoreKit purchase
    /// flow. The type as a whole is `internal` so this doesn't widen the
    /// public surface.
    static func saveCachedSubscription(_ subscription: UserSubscription?) {
        let defaults = UserDefaults.standard
        guard let subscription else {
            defaults.removeObject(forKey: Constant.lastKnownSubscriptionKey)
            return
        }
        guard let data = try? JSONEncoder().encode(subscription) else {
            defaults.removeObject(forKey: Constant.lastKnownSubscriptionKey)
            return
        }
        defaults.set(data, forKey: Constant.lastKnownSubscriptionKey)
    }

    static func loadCachedSubscription() -> UserSubscription? {
        guard let data = UserDefaults.standard.data(forKey: Constant.lastKnownSubscriptionKey) else {
            return nil
        }
        return try? JSONDecoder().decode(UserSubscription.self, from: data)
    }
}
